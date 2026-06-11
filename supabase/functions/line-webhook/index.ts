// ════════════════════════════════════════════════════════════════
// TAAM — line-webhook
// LINE OA(TAAM) 친구 추가/메시지 수신 시, 보낸 사람에게 본인 userId를 자동 회신.
//   → 매장 담당자가 이 userId를 복사해 앱(나의 레스토랑 → LINE ID)에 입력하면
//     notify-reservation 이 그 userId로 예약 알림을 보낼 수 있음.
//
// 이벤트:
//   · follow  (친구 추가)      → "연동용 ID" 안내 + userId 회신
//   · message (아무 메시지)    → 같은 안내 회신 (ID 다시 받기용)
//
// 시크릿(필수): LINE_CHANNEL_ACCESS_TOKEN        (발송용 — 이미 등록됨)
// 시크릿(권장): LINE_CHANNEL_SECRET              (서명검증용 — 콘솔 Basic settings)
// 배포: supabase functions deploy line-webhook --no-verify-jwt
//   ⚠ LINE은 인증 헤더 없이 호출하므로 반드시 --no-verify-jwt 로 배포할 것.
//
// 콘솔 설정: Messaging API 탭 → Webhook URL =
//   https://<project-ref>.supabase.co/functions/v1/line-webhook
//   → "Verify" 눌러 200 확인 → "Use webhook" ON
// ════════════════════════════════════════════════════════════════

const TOKEN  = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN") || "";
const SECRET = Deno.env.get("LINE_CHANNEL_SECRET") || "";

// ── LINE 서명 검증 (HMAC-SHA256, base64) ──
async function verifySignature(body: string, signature: string): Promise<boolean> {
  if (!SECRET) return true; // 시크릿 미설정이면 검증 생략(동작 우선)
  if (!signature) return false;
  try {
    const key = await crypto.subtle.importKey(
      "raw", new TextEncoder().encode(SECRET),
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
    const b64 = btoa(String.fromCharCode(...new Uint8Array(sig)));
    return b64 === signature;
  } catch (_) { return false; }
}

// ── 답장 (replyToken 사용 — 무료) ──
async function reply(replyToken: string, text: string): Promise<void> {
  try {
    await fetch("https://api.line.me/v2/bot/message/reply", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ replyToken, messages: [{ type: "text", text }] }),
    });
  } catch (_) { /* noop */ }
}

function idMessage(userId: string): string {
  return [
    "✅ TAAM 예약 알림 연동용 ID입니다.",
    "",
    userId,
    "",
    "이 ID를 복사해서",
    "앱 → 나의 레스토랑 → 'LINE ID' 에 붙여넣어 주세요.",
    "그러면 새 예약 요청이 들어올 때 여기로 알림이 옵니다.",
  ].join("\n");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok"); // GET/HEAD = 헬스체크

  const raw = await req.text();
  const sig = req.headers.get("x-line-signature") || "";
  if (!(await verifySignature(raw, sig))) {
    return new Response("bad signature", { status: 401 });
  }

  let payload: any = {};
  try { payload = JSON.parse(raw); } catch (_) { /* Verify 버튼은 빈 body */ }
  const events: any[] = payload.events || [];

  for (const ev of events) {
    const userId = ev?.source?.userId;
    const replyToken = ev?.replyToken;
    if (!userId || !replyToken) continue;
    if (ev.type === "follow" || ev.type === "message") {
      await reply(replyToken, idMessage(userId));
    }
  }

  // LINE은 항상 200 을 기대함
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
