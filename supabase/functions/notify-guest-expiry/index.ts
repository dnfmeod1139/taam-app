// ════════════════════════════════════════════════════════════
// notify-guest-expiry — 게스트 만료 임박 푸시 (2026-09-03)
// ════════════════════════════════════════════════════════════
// 무엇을
//   슈퍼어드민 — 만료 5일 전부터 **매일** (5·4·3·2·1일 남음)
//   게스트 본인 — **3일 전 · 1일 전** 두 번만
//
// 누가 정하나
//   ⚠ 「누구에게 무엇을」은 전부 SQL(taam_guest_expiry_notify)이 정한다.
//     이 함수는 그 결과를 받아 **쏘기만** 한다. 규칙을 두 곳에 두면
//     인앱 알림(종)과 푸시가 서로 다른 말을 하는 날이 온다.
//
//   구매하거나 어드민이 [+90일] 을 누르면 기한이 밀려 대상에서 빠진다 —
//   그래서 「멈춤」을 따로 만들지 않았다. 조건이 사라지면 안 나간다.
//
// 하루 한 번
//   SQL 이 **남은 일수를 열쇠로** 중복을 막는다. 이 함수를 하루에 여러 번
//   불러도 새로 들어간 것이 없으면 아무것도 안 쏜다.
//
// 배포: Supabase 대시보드 → Edge Functions → notify-guest-expiry
// 예약: 대시보드 Cron 에서 매일 한 번 (한국시간 오전 10시 권장)
// 필요 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY (기본 제공)
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });


// 🔒 2026-09-14 호출자 확인 — 서버(service_role)만 부른다.
//   종전엔 anon key 만 있으면 누구나 발송 시점을 정하고 무제한으로 부를 수 있었다.
//   cron 은 Vault 의 service_role(legacy JWT)로 부른다. 게이트웨이의 Verify JWT 가 서명을
//   확인하므로 여기서는 role 클레임만 본다. 시크릿 값과 같으면 바로 통과.
function isServiceCaller(req: Request, svc: string): boolean {
  const t = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!t) return false;
  if (t === svc) return true;
  try {
    const seg = t.split('.')[1] || '';
    const pad = seg.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - seg.length % 4) % 4);
    const claims = JSON.parse(atob(pad));
    return claims && claims.role === 'service_role';
  } catch (_e) { return false; }
}

async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const url = Deno.env.get('SUPABASE_URL')!;
  const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(url, svc, { auth: { persistSession: false } });
  if (!isServiceCaller(req, svc)) return json({ ok: false, error: 'forbidden' }, 403);

  try {
    // ① 오늘 보낼 것을 SQL 에게 물어본다 (인앱 알림도 여기서 들어간다)
    const { data, error } = await admin.rpc('taam_guest_expiry_notify');
    if (error) {
      // DB 오류 원문은 로그에만 — 호출자에게 스키마·함수 이름을 흘리지 않는다
      console.error('[notify-guest-expiry] rpc 실패', error.message);
      return json({ ok: false, error: 'rpc_failed' }, 500);
    }

    const rows = (data?.rows || []) as Array<
      { id: string; user_id: string; title: string; body: string; url: string }>;

    // ② 푸시로도 쏜다. 인앱만 두면 앱을 안 열어 본 사람에게는 안 닿는다.
    let sent = 0, failed = 0;
    for (const r of rows) {
      try {
        const res = await fetch(`${url}/functions/v1/send-push`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${svc}` },
          body: JSON.stringify({
            to: `uid:${r.user_id}`,
            payload: {
              title: r.title, body: r.body, url: r.url || '/',
              category: 'guest_expiry',
              // 같은 사람에게 여러 건이 쌓이지 않게 — 기기에서 하나로 합쳐진다
              tag: `guest-expiry-${r.user_id}`,
            },
          }),
        });
        res.ok ? sent++ : failed++;
      } catch (_e) {
        // ⚠ 한 건이 실패해도 멈추지 않는다. 한 사람의 기기 토큰이 죽었다고
        //   나머지 사람들이 알림을 못 받으면 안 된다.
        failed++;
      }
    }

    return json({ ok: true, admin: data?.admin ?? 0, self: data?.self ?? 0,
                  push_sent: sent, push_failed: failed });
  } catch (e) {
    console.error('[notify-guest-expiry] 예외', e);
    return json({ ok: false, error: 'exception' }, 500);
  }
}

// ── 🔒 2026-09-15 CORS 는 우리 출처만 · 메서드는 POST/OPTIONS 만 ──
//   (다른 10개 함수와 같은 마무리. Access-Control-Allow-Origin '*' 는 위 cors 상수에 남아 있지만 여기서 덮어쓴다)
const TAAM_ORIGINS = ['https://taam-app.vercel.app', 'https://playtaam.com', 'https://www.playtaam.com'];
function taamOrigin(req: Request): string {
  const o = req.headers.get('Origin') || '';
  if (TAAM_ORIGINS.includes(o) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)) return o;
  return TAAM_ORIGINS[0];
}
serve(async (req: Request) => {
  let res: Response;
  if (req.method !== 'OPTIONS' && req.method !== 'POST') {
    res = new Response(JSON.stringify({ error: 'method_not_allowed' }),
      { status: 405, headers: { ...cors, 'Content-Type': 'application/json' } });
  } else {
    res = await handle(req);
  }
  try { res.headers.set('Access-Control-Allow-Origin', taamOrigin(req)); res.headers.append('Vary', 'Origin'); } catch (_e) { /* 헤더 잠긴 응답이면 그대로 */ }
  return res;
});

