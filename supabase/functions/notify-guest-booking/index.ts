// ═════════════════════════════════════════════════
// TAAM — notify-guest-booking (2026-09-28)
// 티켓 캘린더에서 **수동으로 넣은 예약(MAN- 행)** 의 손님에게 카카오 알림톡으로
// 예약 안내를 보낸다. 앱 회원이 아닌 국내 손님(전화로 받은 예약)이 대상이다.
//
//   보내는 것: 예약자명 · 매장명 · 방문 일시 · 인원 (+ 템플릿에 고정된 이용 규정)
//   누가 부르나: 슈퍼어드민, 또는 그 매장의 어드민(admin_grants)
//   언제: 수동 추가 직후 앱이 자동으로 한 번 · 캘린더 상세의 「재발송」
//
// 입력:  { purchase_id: 'MAN-…', force?: boolean }
//   force 가 없으면 이미 보낸 행(extra_data.kakao_sent_at)은 다시 보내지 않는다.
//
// 시크릿(필수): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (자동 주입)
// 시크릿(알림톡): SOLAPI_API_KEY, SOLAPI_API_SECRET, SOLAPI_SENDER, KAKAO_PF_ID
//                 KAKAO_TEMPLATE_GUEST_BOOKING  ← 이 함수 전용 템플릿. 없으면 skip(미설정)
//
// ⚠ 알림톡은 카카오가 **미리 승인한 템플릿**만 나간다. 본문을 여기서 지을 수 없다.
//   템플릿 변수는 #{name} #{shop} #{date} #{party} 네 개. 이용 규정은 템플릿 본문에 고정.
//   알림톡이 못 가면(카카오 미가입·차단) 솔라피가 같은 내용을 LMS 로 대체 발송한다
//   (계정의 대체발송 설정을 켜 둬야 한다). 그래서 text 를 같이 싣는다.
//
// 국내 번호만 보낸다. 010/011/016/017/018/019 (또는 +82) 가 아니면 skip(국내번호아님).
// ═════════════════════════════════════════════════

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ── 호출자 (회원 JWT → auth 사용자 id · service_role 이면 서버) ──
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

async function sbGet(path: string): Promise<any[]> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  if (!res.ok) return [];
  const j = await res.json().catch(() => []);
  return Array.isArray(j) ? j : [];
}

async function sbPatch(path: string, body: unknown): Promise<boolean> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method: "PATCH",
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", Prefer: "return=minimal",
    },
    body: JSON.stringify(body),
  });
  return res.ok;
}

// ── 국내 휴대폰 번호 정규화 — 아니면 '' ──
//   '010-1234-5678' · '01012345678' · '+82 10 1234 5678' · '82-10-…' 전부 '01012345678' 로.
function krMobile(raw: string): string {
  let d = String(raw || "").replace(/[^\d+]/g, "");
  if (d.startsWith("+82")) d = "0" + d.slice(3);
  else if (d.startsWith("82") && d.length >= 11) d = "0" + d.slice(2);
  d = d.replace(/\D/g, "");
  return /^01[016789]\d{7,8}$/.test(d) ? d : "";
}

// ── 날짜 표기 — '2027.03.16' → '2027년 3월 16일 (화) 12:00' ──
function fmtVisit(date: string, time: string | null): string {
  const p = String(date || "").split(/[.\-/]/).map((x) => parseInt(x, 10));
  if (p.length < 3 || p.some((n) => isNaN(n))) return String(date || "-");
  const [y, m, d] = p;
  const dow = ["일", "월", "화", "수", "목", "금", "토"][new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  let s = `${y}년 ${m}월 ${d}일 (${dow})`;
  if (time && String(time).trim()) s += " " + String(time).trim().slice(0, 5);
  return s;
}

// ── 솔라피 HMAC ──
async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ── 알림톡 (+ LMS 대체) ──
async function sendKakao(phone: string, vars: Record<string, string>, fallbackText: string): Promise<string> {
  const apiKey    = Deno.env.get("SOLAPI_API_KEY");
  const apiSecret = Deno.env.get("SOLAPI_API_SECRET");
  const sender    = Deno.env.get("SOLAPI_SENDER");
  const pfId      = Deno.env.get("KAKAO_PF_ID");
  const template  = Deno.env.get("KAKAO_TEMPLATE_GUEST_BOOKING");
  if (!apiKey || !apiSecret || !sender || !pfId) return "skip(솔라피 미설정)";
  if (!template) return "skip(템플릿 미설정 KAKAO_TEMPLATE_GUEST_BOOKING)";
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
          to: phone,
          from: sender,
          // 알림톡이 실패하면 이 text 가 LMS 로 나간다 (계정 대체발송 ON 일 때)
          subject: "[TAAM] 예약 안내",
          text: fallbackText,
          kakaoOptions: { pfId, templateId: template, variables: vars },
        },
      }),
    });
    // ⚠ 솔라피는 발송이 실패해도 HTTP 200 을 준다. 실제 결과는 본문에 있다.
    if (!res.ok) return `fail(http ${res.status})`;
    let body: any = null;
    try { body = await res.json(); } catch (_) { /* 아래에서 걸린다 */ }
    if (!body) return "fail(응답 없음)";
    const code = String(body.statusCode ?? body.groupInfo?.status ?? "");
    const failed = Number(body.groupInfo?.count?.registeredFailed ?? 0)
                 + Number(body.failedMessageList?.length ?? 0);
    if (failed > 0 || (code && code !== "2000")) {
      const why = body.failedMessageList?.[0]?.statusMessage || body.statusMessage || code || "알 수 없음";
      console.warn("[guest-booking] 발송 실패:", code, why, "to=…" + phone.slice(-4));
      return `fail(${code || "?"}: ${String(why).slice(0, 40)})`;
    }
    return "ok";
  } catch (e) { return `fail(${(e as Error).message})`; }
}

// ════════════════ 메인 ════════════════
async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { purchase_id, force } = await req.json().catch(() => ({}));
    const pid = String(purchase_id || "");
    if (!/^MAN-\d{6,}$/.test(pid)) return json({ error: "purchase_id 는 MAN- 행이어야 합니다" }, 400);

    // 1) 행 조회
    const rows = await sbGet(`tickets?purchase_id=eq.${encodeURIComponent(pid)}&select=id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,buyer_name,buyer_phone,status,extra_data`);
    const t = rows[0];
    if (!t) return json({ error: "행 없음" }, 404);
    if (String(t.status || "") === "cancelled") return json({ ok: false, skip: "취소된 예약" });

    // 2) 권한 — 슈퍼어드민 또는 그 매장 어드민
    const who = await callerId(req);
    if (!who.service) {
      if (!who.uid) return json({ error: "로그인 필요" }, 401);
      const prof = await sbGet(`profiles?id=eq.${who.uid}&select=role`);
      const role = String(prof[0]?.role || "");
      const isSuper = role === "superadmin" || role === "super_admin";
      if (!isSuper) {
        const g = await sbGet(`admin_grants?user_id=eq.${who.uid}&or=(rest_id.eq.${encodeURIComponent(t.restaurant_id)},venue_id.eq.${encodeURIComponent(t.restaurant_id)})&select=user_id`);
        if (!g.length) return json({ error: "forbidden" }, 403);
      }
    }

    // 3) 번호 — 국내 휴대폰만
    const phone = krMobile(t.buyer_phone || "");
    if (!phone) return json({ ok: false, skip: "국내번호아님", phone_tail: String(t.buyer_phone || "").slice(-4) });

    // 4) 중복 방지 — 이미 보냈으면 force 없이는 안 보낸다
    const ex = (t.extra_data && typeof t.extra_data === "object") ? t.extra_data : {};
    if (ex.kakao_sent_at && !force) return json({ ok: true, skip: "이미 보냄", sent_at: ex.kakao_sent_at });

    // 5) 내용
    const name  = String(t.buyer_name || "").trim() || "고객";
    const shop  = String(t.restaurant_name || "").trim() || "매장";
    const when  = fmtVisit(t.reservation_date, t.visit_time);
    const party = String(parseInt(t.party_size, 10) || 1);
    const vars  = { "#{name}": name, "#{shop}": shop, "#{date}": when, "#{party}": party };
    const fallback =
      `[TAAM 예약 안내]\n${name}님, 예약이 확정되었습니다.\n\n` +
      `▪ 매장: ${shop}\n▪ 일시: ${when}\n▪ 인원: ${party}명\n\n` +
      `[이용 규정]\n· 예약 시간 10분 전까지 도착해 주세요.\n` +
      `· 인원 변경·취소는 방문 31일 전까지 가능하며, 예약 대행비는 환불되지 않습니다.\n` +
      `· 방문 30일 이내에는 취소·변경이 불가합니다.\n` +
      `· 노쇼 시 이후 예약이 제한될 수 있습니다.`;

    // 6) 발송 → 결과를 행에 남긴다 (성공했을 때만 kakao_sent_at)
    const result = await sendKakao(phone, vars, fallback);
    const now = new Date().toISOString();
    const nextEx = result === "ok"
      ? { ...ex, kakao_sent_at: now, kakao_result: "ok", kakao_tries: (Number(ex.kakao_tries) || 0) + 1 }
      : { ...ex, kakao_result: result, kakao_last_try: now, kakao_tries: (Number(ex.kakao_tries) || 0) + 1 };
    await sbPatch(`tickets?id=eq.${t.id}`, { extra_data: nextEx });

    return json({ ok: result === "ok", kakao: result, to_tail: phone.slice(-4) });
  } catch (e) {
    console.error("[notify-guest-booking] 예외", e);
    return json({ error: "server error" }, 500);
  }
}

// ── 🔒 CORS 는 우리 출처만 · 메서드는 POST/OPTIONS 만 (다른 함수와 같은 마무리) ──
const TAAM_ORIGINS = ['https://taam-app.vercel.app', 'https://playtaam.com', 'https://www.playtaam.com'];
function taamOrigin(req: Request): string {
  const o = req.headers.get('Origin') || '';
  if (TAAM_ORIGINS.includes(o) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)) return o;
  return TAAM_ORIGINS[0];
}
Deno.serve(async (req: Request) => {
  let res: Response;
  if (req.method !== 'OPTIONS' && req.method !== 'POST') {
    res = new Response(JSON.stringify({ error: 'method_not_allowed' }),
      { status: 405, headers: { ...CORS, 'Content-Type': 'application/json' } });
  } else {
    res = await handle(req);
  }
  try { res.headers.set('Access-Control-Allow-Origin', taamOrigin(req)); res.headers.append('Vary', 'Origin'); } catch (_e) { /* 잠긴 응답 */ }
  return res;
});
