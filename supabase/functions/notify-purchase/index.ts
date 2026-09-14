// ════════════════════════════════════════════════════════════════
// TAAM — notify-purchase
// 티켓 결제가 확정되면 **그 매장 파트너 어드민**에게 3채널 알림:
//   ① 앱 푸시 (send-push 재활용 — 항상 시도)
//   ② 카카오 알림톡 (Solapi — 시크릿 설정 시에만)
//   ③ LINE 푸시 (Messaging API — 시크릿 설정 시에만)
//
// 왜 Edge Function 이어야 하나
//   앱(회원 세션)은 파트너의 uid 로 푸시를 못 쏜다 — send-push 게이트가
//   「자기에게만 · 어드민 상향 통지만」으로 막는다(2026-08-31). 그게 맞다.
//   그래서 service role 을 쥔 이 함수가 대신 보낸다.
//
//   ⚠ 앱이 넘긴 값을 믿지 않는다. purchase_id 하나만 받고 **DB 를 다시 읽어서**
//     status='active' 인 실제 결제일 때만 보낸다. 회원이 아무 id 나 넘겨도
//     없는 건은 아무 일도 안 일어난다. 이게 위조 방지의 전부다.
//
// 입력:  { purchase_id: text }
// 시크릿(필수): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (자동 주입)
// 시크릿(선택 — 알림톡): SOLAPI_API_KEY, SOLAPI_API_SECRET, SOLAPI_SENDER,
//                        KAKAO_PF_ID, KAKAO_TEMPLATE_NEW_PURCHASE
// 시크릿(선택 — LINE):   LINE_CHANNEL_ACCESS_TOKEN
// 매장별 수신처: venue_partners.notify_phone / notify_line_id
// 배포: Supabase Dashboard → Edge Functions → New function `notify-purchase`
// ════════════════════════════════════════════════════════════════

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ── Supabase REST 헬퍼 (service role) ──
async function sbGet(path: string): Promise<any[]> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  if (!res.ok) return [];
  return await res.json();
}

// 🔒 2026-09-14 호출자 확인 — 회원 JWT 로 auth 사용자 id 를 얻는다 (service_role 키면 서버 호출)
//   09-13 에 형제 함수 notify-reservation 은 「자기 예약만」으로 조였는데 이 함수만 빠져 있었다.
//   종전엔 anon key 만으로 purchase_id 를 열거해 구매 상태·매장 어드민 수·알림톡 설정 여부를
//   읽을 수 있었고, 같은 id 를 동시에 여러 번 던지면 매장에 알림이 N 번 갔다.
async function callerId(req: Request): Promise<{ uid: string | null; service: boolean }> {
  const h = req.headers.get("Authorization") || "";
  const t = h.startsWith("Bearer ") ? h.substring(7) : "";
  if (!t) return { uid: null, service: false };
  if (SERVICE_KEY && t === SERVICE_KEY) return { uid: null, service: true };
  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${t}` },
    });
    if (!res.ok) return { uid: null, service: false };
    const u = await res.json();
    return { uid: u?.id || null, service: false };
  } catch (_) { return { uid: null, service: false }; }
}

// PATCH — 바뀐 행을 돌려받는다 (0 행이면 [])
async function sbPatchRows(path: string, body: unknown): Promise<{ ok: boolean; rows: any[]; status: number }> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method: "PATCH",
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", Prefer: "return=representation",
    },
    body: JSON.stringify(body),
  });
  const rows = res.ok ? await res.json().catch(() => []) : [];
  return { ok: res.ok, rows: Array.isArray(rows) ? rows : [], status: res.status };
}

async function sbPatch(path: string, body: unknown): Promise<boolean> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method: "PATCH",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify(body),
  });
  return res.ok;
}

// ── ① 앱 푸시 — 기존 send-push 함수 호출 ──
async function sendAppPush(userId: string, title: string, body: string): Promise<boolean> {
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/send-push`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${SERVICE_KEY}`,
        apikey: SERVICE_KEY,
      },
      body: JSON.stringify({
        to: `uid:${userId}`,
        payload: {
          title, body, url: "/",
          category: "purchase_confirmed",
          tag: "taam-buy-" + Date.now(),
        },
      }),
    });
    if (!res.ok) return false;
    // 🔒 2026-09-13: send-push 는 대상이 0 이어도 200 을 준다. 「한 기기라도 갔다」를 본다.
    //   종전엔 200 = 성공으로 읽어 partner_notified_at 을 찍고, 알림톡·LINE 실패는 영영 재시도되지 않았다.
    const j = await res.json().catch(() => null);
    const okN = Number(j?.summary?.ok ?? 0);
    return okN > 0;
  } catch (_) { return false; }
}

// ── ② 카카오 알림톡 (Solapi) — HMAC-SHA256 인증 ──
async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function sendKakao(phone: string, vars: Record<string, string>): Promise<string> {
  const apiKey    = Deno.env.get("SOLAPI_API_KEY");
  const apiSecret = Deno.env.get("SOLAPI_API_SECRET");
  const sender    = Deno.env.get("SOLAPI_SENDER");
  const pfId      = Deno.env.get("KAKAO_PF_ID");
  // ⚠ 예약 요청과 **다른 템플릿**이다. 같은 걸 쓰면 심사 문구와 안 맞는다.
  const template  = Deno.env.get("KAKAO_TEMPLATE_NEW_PURCHASE");
  if (!apiKey || !apiSecret || !sender || !pfId || !template) return "skip(미설정)";
  if (!phone) return "skip(수신번호없음)";
  try {
    const date = new Date().toISOString();
    const salt = crypto.randomUUID();
    const signature = await hmacHex(apiSecret, date + salt);
    const res = await fetch("https://api.solapi.com/messages/v4/send", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `HMAC-SHA256 apiKey=${apiKey}, date=${date}, salt=${salt}, signature=${signature}`,
      },
      body: JSON.stringify({
        message: {
          to: phone.replace(/-/g, ""),
          from: sender,
          kakaoOptions: { pfId, templateId: template, variables: vars },
        },
      }),
    });
    // ⚠ 솔라피는 **발송이 실패해도 HTTP 200** 을 준다. 실제 결과는 본문에 있다.
    //   res.ok 만 보면 템플릿 불일치·pfId 오류·수신거부까지 「ok」로 읽고,
    //   그러면 partner_notified_at 이 찍혀 **다시 시도하지도 않는다.**
    //   안 갔는데 갔다고 기록되고 아무도 모른다 — 그게 제일 나쁘다.
    if (!res.ok) return `fail(http ${res.status})`;
    let body: any = null;
    try { body = await res.json(); } catch (_) { /* 본문이 없으면 아래에서 걸린다 */ }
    if (!body) return "fail(응답 없음)";
    // 단건 전송은 statusCode 2000 이 정상. 그 밖은 전부 실패로 본다.
    const code = String(body.statusCode ?? body.groupInfo?.status ?? "");
    const failed = Number(body.groupInfo?.count?.registeredFailed ?? 0)
                 + Number(body.failedMessageList?.length ?? 0);
    if (failed > 0 || (code && code !== "2000")) {
      const why = body.failedMessageList?.[0]?.statusMessage
               || body.statusMessage || code || "알 수 없음";
      console.warn("[kakao] 발송 실패:", code, why, JSON.stringify(body).slice(0, 300));
      return `fail(${code || "?"}: ${String(why).slice(0, 40)})`;
    }
    return "ok";
  } catch (e) { return `fail(${(e as Error).message})`; }
}

// ── ③ LINE 푸시 (Messaging API · Flex Message) ──
const BURGUNDY = "#7B1E2B";
const APP_URL  = "https://taam-app.vercel.app";

function money(n: number | null | undefined): string {
  const v = Number(n || 0);
  return v > 0 ? "₩" + v.toLocaleString("ja-JP") : "-";
}

// 날짜 포맷 — 요일 로케일만 다름 (ko: 카카오/푸시, ja: LINE)
//   ⚠ tickets.reservation_date 는 실제로 '2026.04.22' 처럼 **점**이다.
//     처음에 'YYYY-MM-DD' 로 가정하고 split("-") 했다가, 쪼개지지 않아
//     「9/30 (수)」 대신 원문이 그대로 알림톡·LINE 으로 나갈 뻔했다.
//     형식을 짐작하지 않고 숫자만 뽑는다 — 점·하이픈·슬래시 다 받는다.
function fmtDate(date: string, time: string | null, lang: "ko" | "ja"): string {
  if (!date) return "-";
  const k = String(date).replace(/[^0-9]/g, "");
  if (k.length !== 8) return String(date);
  const y = Number(k.slice(0, 4)), m = Number(k.slice(4, 6)), d = Number(k.slice(6, 8));
  if (!y || !m || !d) return String(date);
  const dow = lang === "ja"
    ? ["日", "月", "火", "水", "木", "金", "土"]
    : ["일", "월", "화", "수", "목", "금", "토"];
  const wd = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  let s = `${m}/${d} (${dow[wd]})`;
  if (time) s += " " + String(time).slice(0, 5);
  return s;
}

function infoRow(icon: string, label: string, value: string): any {
  return {
    type: "box", layout: "baseline", spacing: "sm",
    contents: [
      { type: "text", text: icon, flex: 0, size: "sm" },
      { type: "text", text: label, color: "#9A9A9A", size: "sm", flex: 2 },
      { type: "text", text: value, color: "#1A1A1A", size: "sm", weight: "bold",
        flex: 6, wrap: true, align: "end" },
    ],
  };
}

// 결제 확정 카드 (예약 요청 카드와 같은 결 · 일본어)
function purchaseBubble(
  venue: string, date: string, party: string, guest: string, amount: string,
): any {
  return {
    type: "bubble", size: "kilo",
    header: {
      type: "box", layout: "vertical", paddingAll: "16px", backgroundColor: "#FFFFFF",
      contents: [
        { type: "text", text: "TAAM", size: "xs", color: BURGUNDY, weight: "bold" },
        { type: "text", text: "ご予約が確定しました", size: "lg", color: "#1A1A1A", weight: "bold", margin: "sm" },
        { type: "separator", margin: "md", color: BURGUNDY },
      ],
    },
    body: {
      type: "box", layout: "vertical", spacing: "md", paddingAll: "16px", paddingTop: "8px",
      contents: [
        infoRow("🍽", "店舗", venue),
        infoRow("📅", "日時", date),
        infoRow("👥", "人数", party),
        infoRow("🙍", "お客様", guest),
        infoRow("💰", "金額", amount),
      ],
    },
    footer: {
      type: "box", layout: "vertical", paddingAll: "12px",
      contents: [{
        type: "button", style: "primary", color: BURGUNDY, height: "sm",
        action: { type: "uri", label: "アプリで確認", uri: APP_URL },
      }],
    },
  };
}

async function sendLine(
  lineUserId: string,
  info: { venue: string; date: string; party: string; guest: string; amount: string; alt: string },
): Promise<string> {
  const token = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN");
  if (!token) return "skip(미설정)";
  if (!lineUserId) return "skip(수신ID없음)";
  try {
    const res = await fetch("https://api.line.me/v2/bot/message/push", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        to: lineUserId,
        messages: [{
          type: "flex",
          altText: info.alt,
          contents: purchaseBubble(info.venue, info.date, info.party, info.guest, info.amount),
        }],
      }),
    });
    return res.ok ? "ok" : `fail(${res.status})`;
  } catch (e) { return `fail(${(e as Error).message})`; }
}

// 연락처는 뒤 4자리만 — 매장이 손님을 알아보는 데는 그걸로 충분하고,
// 외부 채널(알림톡·LINE)로 전체 번호를 흘리지 않는다. 전체는 앱에서 본다.
function maskPhone(p: string | null | undefined): string {
  const d = String(p || "").replace(/[^0-9]/g, "");
  if (d.length < 4) return "-";
  return "…" + d.slice(-4);
}

// ════════════════ 메인 ════════════════
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { purchase_id } = await req.json();
    if (!purchase_id) return json({ error: "purchase_id 필요" }, 400);

    // 1) 그 구매를 **DB 에서 다시 읽는다.** 앱이 넘긴 건 id 뿐이다.
    const pid = encodeURIComponent(String(purchase_id));
    const tks = await sbGet(
      `tickets?purchase_id=eq.${pid}&select=purchase_id,user_id,restaurant_id,restaurant_name,` +
      `reservation_date,visit_time,party_size,price,status,buyer_name,buyer_phone,extra_data`);
    const tk = tks[0];

    // 🔒 자기 구매만. 회원이 아니면(익명·남의 구매) 존재 여부도 알려주지 않는다 — 응답을 하나로 뭉갠다.
    const who = await callerId(req);
    if (!who.service) {
      if (!who.uid) return json({ error: "forbidden" }, 403);
      if (!tk || who.uid !== tk.user_id) return json({ ok: true });
    }
    if (!tk) return json({ ok: true, skip: "구매 없음" });

    // 2) 실제로 결제된 건만. 홀드·취소는 아무것도 안 한다.
    if (String(tk.status || "") !== "active") {
      return json({ ok: true, skip: `상태 ${tk.status || "없음"}` });
    }

    // 3) 두 번 보내지 않는다 — 🔒 먼저 찍고 조건부로. 종전엔 「읽고 → 보내고 → 찍기」라
    //    같은 id 를 동시에 N 개 던지면 전부 통과해 매장에 알림이 N 번 갔다.
    //    partner_notified_at 이 비어 있을 때만 지금 시각으로 찍는다(0 행이면 남이 먼저 찍은 것).
    //    아무 데도 못 보냈으면 아래에서 다시 비운다 — 다음 호출이 재시도할 수 있게.
    const ex = tk.extra_data || {};
    if (ex.partner_notified_at) {
      return json({ ok: true, skip: "이미 보냄" });
    }
    const claimedAt = new Date().toISOString();
    const claim = await sbPatchRows(
      `tickets?purchase_id=eq.${pid}&extra_data->>partner_notified_at=is.null`,
      { extra_data: { ...ex, partner_notified_at: claimedAt, partner_notify_pending: true } });
    if (claim.ok && claim.rows.length === 0) {
      return json({ ok: true, skip: "이미 보냄" });
    }
    if (!claim.ok) console.warn("[notify-purchase] 선표시 실패", claim.status);

    // 4) 이 매장의 파트너 어드민 (admin_grants — rest_id 또는 venue_id 매칭)
    const rid = encodeURIComponent(String(tk.restaurant_id || ""));
    const grants = rid
      ? await sbGet(`admin_grants?or=(rest_id.eq.${rid},venue_id.eq.${rid})&select=user_id`)
      : [];
    const adminIds = [...new Set(grants.map((g: any) => g.user_id).filter(Boolean))];

    // 5) 매장 알림 수신처
    const vps = rid
      ? await sbGet(`venue_partners?venue_id=eq.${rid}&select=notify_phone,notify_line_id`)
      : [];
    const vp = vps[0] || {};

    // 6) 메시지
    const venueName = tk.restaurant_name || "매장";
    const dateKo = fmtDate(tk.reservation_date, tk.visit_time, "ko");
    const dateJa = fmtDate(tk.reservation_date, tk.visit_time, "ja");
    const guest  = tk.buyer_name || "회원";
    const party  = String(tk.party_size || 1);

    const title = "새 예약 확정";
    const body  = `${venueName} · ${dateKo} · ${party}명\n예약자 ${guest} ${maskPhone(tk.buyer_phone)}`;

    // 7) 발송
    let pushOk = 0;
    for (const uid of adminIds) {
      if (await sendAppPush(uid as string, title, body)) pushOk++;
    }

    const kakaoResult = await sendKakao(vp.notify_phone || "", {
      "#{shop}": venueName,
      "#{date}": dateKo,
      "#{party}": party,
      "#{guest}": guest,
    });

    const lineResult = await sendLine(vp.notify_line_id || "", {
      venue: venueName,
      date: dateJa,
      party: `${party}名`,
      guest,
      amount: money(tk.price),
      alt: `[TAAM] ご予約確定 — ${venueName} ${dateJa} ${party}名`,
    });

    // 8) 보낸 표시 — 하나라도 나갔으면 확정, 아무 데도 못 갔으면 표시를 비워 다음 호출이 재시도한다.
    const anySent = pushOk > 0 || kakaoResult === "ok" || lineResult === "ok";
    await sbPatch(`tickets?purchase_id=eq.${pid}`, {
      extra_data: anySent
        ? { ...ex, partner_notified_at: claimedAt }
        : { ...ex, partner_notified_at: null },
    });

    return json({
      ok: true, admins: adminIds.length, push: pushOk,
      kakao: kakaoResult, line: lineResult, marked: anySent,
    });
  } catch (e) {
    console.error("[notify-purchase] 예외", e);
    return json({ error: "server error" }, 500);
  }
});
