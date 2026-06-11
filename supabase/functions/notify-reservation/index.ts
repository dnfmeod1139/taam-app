// ════════════════════════════════════════════════════════════════
// TAAM — notify-reservation
// 새 예약 요청이 들어오면 해당 매장 어드민에게 3채널 알림 발송:
//   ① 앱 푸시 (기존 send-push 재활용 — 항상 시도)
//   ② 카카오 알림톡 (Solapi — 시크릿 설정 시에만)
//   ③ LINE 푸시 (Messaging API — 시크릿 설정 시에만)
//
// 입력:  { reservation_id: uuid }
// 시크릿(필수): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (자동 주입)
// 시크릿(선택 — 알림톡): SOLAPI_API_KEY, SOLAPI_API_SECRET, SOLAPI_SENDER,
//                        KAKAO_PF_ID, KAKAO_TEMPLATE_NEW_REQUEST
// 시크릿(선택 — LINE):   LINE_CHANNEL_ACCESS_TOKEN
// 매장별 수신처: venue_partners.notify_phone / notify_line_id (어드민이 앱에서 설정)
// 배포: supabase functions deploy notify-reservation
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
        payload: { title, body, url: "/", category: "reservation_request", tag: "taam-resv-new" },
      }),
    });
    return res.ok;
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
  const sender    = Deno.env.get("SOLAPI_SENDER");          // 발신번호 (사전 등록)
  const pfId      = Deno.env.get("KAKAO_PF_ID");            // 카카오 채널 pfId
  const template  = Deno.env.get("KAKAO_TEMPLATE_NEW_REQUEST"); // 승인된 템플릿 ID
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
    return res.ok ? "ok" : `fail(${res.status})`;
  } catch (e) { return `fail(${(e as Error).message})`; }
}

// ── ③ LINE 푸시 (Messaging API) ──
async function sendLine(lineUserId: string, text: string): Promise<string> {
  const token = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN");
  if (!token) return "skip(미설정)";
  if (!lineUserId) return "skip(수신ID없음)";
  try {
    const res = await fetch("https://api.line.me/v2/bot/message/push", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ to: lineUserId, messages: [{ type: "text", text }] }),
    });
    return res.ok ? "ok" : `fail(${res.status})`;
  } catch (e) { return `fail(${(e as Error).message})`; }
}

// ════════════════ 메인 ════════════════
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { reservation_id } = await req.json();
    if (!reservation_id) return json({ error: "reservation_id 필요" }, 400);

    // 1) 예약 요청 조회
    const rrs = await sbGet(`reservation_requests?id=eq.${reservation_id}&select=*`);
    const rr = rrs[0];
    if (!rr) return json({ error: "요청 없음" }, 404);

    // 2) 매장명 (restaurants → venue_partners.label 폴백)
    let venueName = "매장";
    const rests = await sbGet(`restaurants?id=eq.${rr.venue_id}&select=name`);
    if (rests[0]?.name) venueName = rests[0].name;

    // 3) 수신처: 매장 어드민들 (admin_grants — venue_id 또는 rest_id 매칭)
    const grants = await sbGet(
      `admin_grants?or=(venue_id.eq.${rr.venue_id},rest_id.eq.${rr.venue_id})&select=user_id`);
    const adminIds = [...new Set(grants.map((g: any) => g.user_id).filter(Boolean))];

    // 매장 알림 설정 (알림톡 전화 / LINE ID)
    const vps = await sbGet(`venue_partners?venue_id=eq.${rr.venue_id}&select=notify_phone,notify_line_id`);
    const vp = vps[0] || {};

    // 4) 메시지 구성
    const dateStr = `${rr.reserve_date}${rr.reserve_time ? " " + String(rr.reserve_time).slice(0, 5) : ""}`;
    const title = "새 예약 요청";
    const body  = `${venueName} · ${dateStr} · ${rr.party_size}명 — 앱에서 수락/거절해주세요`;

    // 5) 발송
    let pushOk = 0;
    for (const uid of adminIds) {
      if (await sendAppPush(uid as string, title, body)) pushOk++;
    }
    const kakaoResult = await sendKakao(vp.notify_phone || "", {
      "#{shop}": venueName, "#{date}": dateStr, "#{party}": String(rr.party_size),
    });
    const lineResult = await sendLine(vp.notify_line_id || "", `[TAAM] ${title}\n${body}`);

    return json({ ok: true, admins: adminIds.length, push: pushOk, kakao: kakaoResult, line: lineResult });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
