// ═════════════════════════════════════════════════
// kashikiri-refund — 링크 초대(비회원 카드 결제) 환불 · 2026-09-29
// ═════════════════════════════════════════════════
// 누가: 슈퍼어드민(JWT). 무엇을: 결제된 링크 청구 하나를 회원과 같은 규정으로 환불한다.
//   견적은 SQL(taam_link_invite_refund_quote)이 낸다 — 30분 안 전액 · D-31 이상 총액−대행비 · 그 뒤 0.
//   이 함수는 그 금액으로 토스에 (부분)취소를 부르고, 성공하면 taam_link_invite_mark_refunded 로 기록한다.
//   기록 트리거가 좌석 행(LINK-)을 cancelled 로 돌려 잔여석이 복구된다.
// 통화: 승인에 쓴 MID 의 시크릿으로 취소해야 한다 — pay_currency 로 고른다 (kashikiri-confirm 과 같은 규칙).
// 입력: { charge_id, reason? }
// 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY · TOSS_SECRET_KEY · TOSS_SECRET_KEY_USD · TOSS_SECRET_KEY_JPY
// ═════════════════════════════════════════════════
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
function json(b: unknown, s = 200){ return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }

async function sbGet(path: string){ const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } }); return r.ok ? await r.json().catch(() => []) : []; }
async function sbRpc(fn: string, args: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const b = await r.json().catch(() => null); if(!r.ok) throw new Error((b && (b.message || b.hint)) || ('rpc ' + fn + ' ' + r.status)); return b;
}
async function callerIsSuper(req: Request){
  const h = req.headers.get('Authorization') || ''; const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  if(!t) return false;
  const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${t}` } });
  if(!u.ok) return false; const j = await u.json(); if(!j?.id) return false;
  const p = await sbGet(`profiles?id=eq.${j.id}&select=role`);
  return ['super_admin','superadmin'].includes(String(p[0]?.role || ''));
}

async function handle(req: Request){
  if(req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    if(!(await callerIsSuper(req))) return json({ error: 'forbidden' }, 403);
    const { charge_id, reason } = await req.json().catch(() => ({}));
    if(!charge_id || !/^[0-9a-f-]{36}$/i.test(String(charge_id))) return json({ error: 'charge_id 필요' }, 400);
    const q = await sbRpc('taam_link_invite_refund_quote', { p_charge_id: String(charge_id) });
    if(!q || q.status !== 'paid') return json({ ok: false, error: 'not_paid', quote: q }, 409);
    const cur = String(q.currency || 'KRW').toUpperCase();
    const refundKrw = Number(q.refund_krw || 0);
    const refundAmt = Number(q.refund_amount || 0);
    const paidAmt   = Number(q.paid_amount || 0);
    let toss: any = null;
    if(refundKrw > 0){
      const secret = cur === 'KRW' ? Deno.env.get('TOSS_SECRET_KEY') : Deno.env.get('TOSS_SECRET_KEY_' + cur);
      if(!secret) return json({ ok: false, error: 'no_secret_for_' + cur }, 500);
      if(!q.payment_key) return json({ ok: false, error: 'no_payment_key' }, 409);
      const body: Record<string, unknown> = { cancelReason: String(reason || '예약 취소 (링크 초대)').slice(0, 200) };
      // 전액이 아니면 부분취소 — 승인 통화 단위로 보낸다 (토스는 MID 통화로 받는다)
      if(refundAmt < paidAmt) body.cancelAmount = refundAmt;
      const r = await fetch(`https://api.tosspayments.com/v1/payments/${encodeURIComponent(q.payment_key)}/cancel`, {
        method: 'POST', headers: { Authorization: `Basic ${btoa(secret + ':')}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      toss = await r.json().catch(() => null);
      if(!r.ok) return json({ ok: false, error: 'toss_cancel_failed', toss: { code: toss?.code, message: toss?.message } }, 502);
    }
    const marked = await sbRpc('taam_link_invite_mark_refunded', { p_charge_id: String(charge_id), p_refund_krw: refundKrw, p_refund_amount: refundAmt, p_reason: String(reason || q.policy || '') });
    return json({ ok: true, refund_krw: refundKrw, refund_amount: refundAmt, currency: cur, policy: q.policy, toss_status: toss?.status || null, marked });
  } catch (e) { console.error('[kashikiri-refund]', e); return json({ error: String((e as Error).message || e).slice(0, 200) }, 500); }
}
const TAAM_ORIGINS = ['https://taam-app.vercel.app', 'https://playtaam.com', 'https://www.playtaam.com'];
function taamOrigin(req: Request){ const o = req.headers.get('Origin') || ''; return (TAAM_ORIGINS.includes(o) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)) ? o : TAAM_ORIGINS[0]; }
Deno.serve(async (req: Request) => {
  let res: Response;
  if(req.method !== 'OPTIONS' && req.method !== 'POST') res = new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: { ...CORS, 'Content-Type': 'application/json' } });
  else res = await handle(req);
  try { res.headers.set('Access-Control-Allow-Origin', taamOrigin(req)); res.headers.append('Vary', 'Origin'); } catch (_e) { /* */ }
  return res;
});
