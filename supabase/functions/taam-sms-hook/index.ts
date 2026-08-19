// ════════════════════════════════════════════════════════════
// taam-sms-hook — Supabase Auth "Send SMS" 훅 (Solapi 발송)
// ════════════════════════════════════════════════════════════
// 작성일: 2026-08
//
// 왜 이 방식인가
//   Supabase 기본 phone auth 는 Twilio·MessageBird·Vonage 만 지원한다.
//   한국 번호는 국제 경로라 도달률이 떨어지고 단가도 5~10배다.
//   그렇다고 OTP 를 직접 만들면 코드 생성·해시 저장·만료·재발송 제한·
//   무차별 대입 방어를 전부 다시 구현해야 한다 — 인증 로직을 새로 짜는 셈이다.
//
//   Send SMS Hook 은 그 사이를 정확히 메운다.
//   · OTP 생성·검증·만료·시도 제한 → Supabase 가 그대로 담당 (검증된 로직)
//   · 문자 '발송' 만 이 함수가 가로채 Solapi 로 보낸다
//   앱 코드는 한 줄도 바뀌지 않는다 (signInWithOtp / verifyOtp 그대로).
//
// 필요한 시크릿 (Supabase Dashboard → Edge Functions → Secrets)
//   SEND_SMS_HOOK_SECRET = v1,whsec_...   ← 훅 등록 시 Supabase 가 발급
//   SOLAPI_API_KEY       = ...
//   SOLAPI_API_SECRET    = ...
//   SOLAPI_SENDER        = 0212345678     ← 사전 등록된 발신번호
//   (SOLAPI_* 는 notify-reservation 과 동일한 값을 재사용한다)
//
// ⚠ 이 함수는 문자를 실제로 발송한다. 서명 검증이 없으면 아무나 호출해
//   문자를 무한 발송시킬 수 있다. 그래서 시크릿이 없으면 아예 거부한다.
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// ── 훅의 오류는 HTTP 200 으로 돌려준다 ──
//   Supabase Auth 훅 규약은 「응답은 200, 오류는 본문의 error 객체로」다.
//   HTTP 상태로 4xx·5xx 를 돌려주면 GoTrue 는 본문을 읽지 않고
//   "Hook errored out" 한 줄만 남긴 채 회원에게 일반 500 을 준다.
//   그러면 무엇이 막았는지 앱에도, 로그에도 남지 않는다 — 원인을 찾을 길이 사라진다.
//   본문으로 주면 이 message 가 그대로 앱 화면까지 올라온다.
function hookErr(code: number, message: string) {
  console.error('[sms-hook] ' + message);
  return json({ error: { http_code: code, message: '[sms-hook] ' + message } }, 200);
}

// ── Standard Webhooks 서명 검증 ──
//   Supabase 는 webhook-id / webhook-timestamp / webhook-signature 를 보낸다.
//   서명 대상 문자열은 `${id}.${timestamp}.${body}` 이고,
//   secret 은 "v1,whsec_<base64>" 형태라 뒤쪽 base64 만 키로 쓴다.
async function verifySignature(
  secretRaw: string,
  id: string,
  timestamp: string,
  body: string,
  headerSig: string,
): Promise<boolean> {
  try {
    const b64 = secretRaw.replace(/^v1,\s*/, '').replace(/^whsec_/, '');
    const keyBytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );
    const signed = `${id}.${timestamp}.${body}`;
    const sigBuf = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signed));
    const expected = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));

    // 헤더는 "v1,<sig>" 이며 공백으로 여러 개가 올 수 있다 (키 로테이션 대비)
    const candidates = headerSig.split(' ').map((p) => p.split(',').pop() || '');
    // 타이밍 공격 방지를 위해 길이를 맞춘 뒤 전량 비교한다
    return candidates.some((c) => {
      if (c.length !== expected.length) return false;
      let diff = 0;
      for (let i = 0; i < c.length; i++) diff |= c.charCodeAt(i) ^ expected.charCodeAt(i);
      return diff === 0;
    });
  } catch (_e) {
    return false;
  }
}

// ── Solapi HMAC-SHA256 인증 (notify-reservation 과 동일 규약) ──
async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// E.164(+821012345678) → 국내 형식(01012345678). 국내번호가 아니면 그대로 둔다.
function toDomestic(phone: string): string {
  const p = String(phone || '').replace(/[^0-9+]/g, '');
  if (p.startsWith('+82')) return '0' + p.slice(3);
  if (p.startsWith('82') && !p.startsWith('820')) return '0' + p.slice(2);
  return p.replace(/^\+/, '');
}

serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  const hookSecret = Deno.env.get('SEND_SMS_HOOK_SECRET');
  if (!hookSecret) {
    // 시크릿 미설정 = 누구나 호출 가능 = 문자 폭탄. 열어두지 않는다.
    return hookErr(500, 'SEND_SMS_HOOK_SECRET 미설정');
  }

  const body = await req.text();
  const id = req.headers.get('webhook-id') || '';
  const ts = req.headers.get('webhook-timestamp') || '';
  const sig = req.headers.get('webhook-signature') || '';

  if (!id || !ts || !sig) {
    return hookErr(401, '서명 헤더 누락 (id=' + (id ? 'o' : 'x')
      + ' ts=' + (ts ? 'o' : 'x') + ' sig=' + (sig ? 'o' : 'x') + ')');
  }

  // 재전송 공격 방지 — 5분을 넘긴 요청은 받지 않는다
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum) || Math.abs(Date.now() / 1000 - tsNum) > 300) {
    return hookErr(401, 'timestamp 유효범위 밖: ' + ts);
  }

  if (!(await verifySignature(hookSecret, id, ts, body, sig))) {
    return hookErr(401, '서명 불일치 — SEND_SMS_HOOK_SECRET 값이 훅 발급값과 다릅니다');
  }

  // ── 페이로드 ──
  //   { user: { phone: "+8210...", ... }, sms: { otp: "123456" } }
  let payload: Record<string, unknown>;
  try { payload = JSON.parse(body); }
  catch { return hookErr(400, 'invalid json'); }

  const user = (payload.user || {}) as Record<string, unknown>;
  const smsIn = (payload.sms || {}) as Record<string, unknown>;
  const phone = String(user.phone || '');
  const otp = String(smsIn.otp || '');

  if (!phone || !otp) {
    return hookErr(400, 'phone/otp 없음');
  }

  const apiKey = Deno.env.get('SOLAPI_API_KEY');
  const apiSecret = Deno.env.get('SOLAPI_API_SECRET');
  const sender = Deno.env.get('SOLAPI_SENDER');
  if (!apiKey || !apiSecret || !sender) {
    return hookErr(500, 'SOLAPI 시크릿 미설정 (key=' + (apiKey ? 'o' : 'x')
      + ' secret=' + (apiSecret ? 'o' : 'x') + ' sender=' + (sender ? 'o' : 'x') + ')');
  }

  // 문자 본문 — 인증번호 외 정보는 넣지 않는다 (유출 시 피해 최소화)
  const text = `[TAAM] 인증번호 ${otp}\n3분 안에 입력해주세요.`;

  try {
    const date = new Date().toISOString();
    const salt = crypto.randomUUID();
    const signature = await hmacHex(apiSecret, date + salt);

    const res = await fetch('https://api.solapi.com/messages/v4/send', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `HMAC-SHA256 apiKey=${apiKey}, date=${date}, salt=${salt}, signature=${signature}`,
      },
      body: JSON.stringify({
        message: { to: toDomestic(phone), from: sender, text },
      }),
    });

    if (!res.ok) {
      const detail = await res.text().catch(() => '');
      // Solapi 가 준 사유를 그대로 실어 보낸다 — 발신번호 미등록·잔액 부족·번호 형식이
      // 여기서 갈린다. 이 문자열이 없으면 대시보드 세 군데를 다 뒤져야 한다.
      return hookErr(502, 'Solapi ' + res.status + ': ' + detail.slice(0, 160));
    }

    // 성공 — 인증번호는 절대 로그에 남기지 않는다
    console.log('[sms-hook] 발송 성공', toDomestic(phone).replace(/\d{4}$/, '****'));
    return json({});
  } catch (e) {
    return hookErr(500, '예외: ' + String((e as Error)?.message || e).slice(0, 160));
  }
});
