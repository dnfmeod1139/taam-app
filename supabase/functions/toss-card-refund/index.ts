// ═════════════════════════════════════════════════
// toss-card-refund — 앱 카드 결제분 환불(토스 승인취소)을 슈퍼어드민이 앱에서 · 2026-10-22
// ═════════════════════════════════════════════════
// 왜: 회원이 카드가 섞인 티켓을 취소하면 앱은 예치금 몫만 돌려주고 카드 몫은 tickets.extra_data.card_refund_pending
//     {amount, order_id, status:'pending'} 로 남긴다. 지금까지는 슈퍼어드민이 토스 상점관리자에서 승인취소를 하고
//     앱의 「카드 환불 완료」(tkMarkCardRefundDone)를 눌렀다. 이 함수가 그 승인취소를 토스 API 로 직접 한다.
// 누가: 슈퍼어드민(JWT · verify_jwt=true + profiles.role 확인). 회원·매장 어드민은 403.
// 무엇을:
//   ① 티켓의 card_refund_pending(대기 · 금액 · 주문번호)을 읽는다 — 금액은 회원 취소 때 앱이 규정대로 적은 값(카드 몫까지만).
//   ② payment_orders(주문번호 · paid · payment_key · 통화 · paid_via)로 결제키와 시크릿을 고른다 —
//      승인한 MID 의 시크릿으로 취소해야 한다: 등록 카드 자동결제(paid_via billing_key)는 TOSS_BILLING_SECRET_KEY(없으면 TOSS_SECRET_KEY),
//      일반 결제창은 TOSS_SECRET_KEY. 외화 주문은 대기 금액이 원화라 단위가 다르다 → 막고 상점관리자로 안내.
//   ③ 토스 GET /v1/payments/{paymentKey} 로 남은 취소 가능액(balanceAmount)을 본다 — 이미 상점관리자에서 취소됐으면 already_canceled_at_toss.
//   ④ POST /v1/payments/{paymentKey}/cancel {cancelReason, cancelAmount} · Idempotency-Key 'taam-crf-<구매>-<금액>'
//      (두 번 눌리거나 재시도해도 토스는 한 번만 취소하고 같은 결과를 돌려준다).
//   ⑤ 성공하면 card_refund_pending 을 done 으로(+ 토스 거래키 · 취소 시각 · 처리자 · via toss_api) — 회원 알림·푸시는 앱이 종전 함수로 보낸다.
//      기록이 실패해도 토스 취소는 이미 됐다 → { ok:true, mark_failed:true } 로 알려 앱이 「완료 표시」를 하게 한다(같은 키라 다시 불러도 이중 취소 없음).
// 오류는 HTTP 200 + { ok:false, error } 로 돌려준다(앱이 사유를 읽을 수 있게) — 권한만 403.
// 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY · TOSS_SECRET_KEY · TOSS_BILLING_SECRET_KEY(선택)
// ═════════════════════════════════════════════════
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
function json(b: unknown, s = 200){ return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
const SB_H = () => ({ apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' });

async function sbGet(path: string){ const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: SB_H() }); return r.ok ? await r.json().catch(() => []) : []; }
async function sbPatch(path: string, body: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'PATCH', headers: { ...SB_H(), Prefer: 'return=representation' }, body: JSON.stringify(body) });
  const b = await r.json().catch(() => null); return { ok: r.ok && Array.isArray(b) && b.length > 0, body: b, status: r.status };
}
async function superCaller(req: Request): Promise<string | null>{
  const h = req.headers.get('Authorization') || ''; const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  if(!t) return null;
  const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${t}` } });
  if(!u.ok) return null; const j = await u.json().catch(() => null); if(!j?.id) return null;
  const p = await sbGet(`profiles?id=eq.${encodeURIComponent(j.id)}&select=role`);
  return ['super_admin', 'superadmin'].includes(String(p[0]?.role || '')) ? String(j.id) : null;
}

async function handle(req: Request){
  if(req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const by = await superCaller(req);
  if(!by) return json({ ok: false, error: 'forbidden' }, 403);
  try {
    const { purchase_id, reason } = await req.json().catch(() => ({}));
    const pid = String(purchase_id || '');
    if(!pid || pid.length > 120 || !/^[A-Za-z0-9_\-:.]+$/.test(pid)) return json({ ok: false, error: 'bad_purchase_id' });

    // ① 티켓 · 카드 환불 대기
    const rows = await sbGet(`tickets?purchase_id=eq.${encodeURIComponent(pid)}&select=id,purchase_id,user_id,restaurant_name,status,extra_data&order=created_at.desc&limit=1`);
    const t = rows[0];
    if(!t) return json({ ok: false, error: 'ticket_not_found' });
    const ex = (t.extra_data && typeof t.extra_data === 'object') ? t.extra_data : {};
    const crp = ex.card_refund_pending;
    if(!crp || typeof crp !== 'object') return json({ ok: false, error: 'not_pending' });
    if(String(crp.status || '') === 'done') return json({ ok: false, error: 'already_done' });
    const amount = Math.floor(Number(crp.amount || 0));
    if(!(amount > 0)) return json({ ok: false, error: 'bad_amount' });
    if(['active', 'hold', 'pending_confirm'].includes(String(t.status || '').toLowerCase()))
      return json({ ok: false, error: 'ticket_active', status: t.status });   // 좌석이 살아 있는 티켓의 카드는 돌려주지 않는다

    // ② 주문 · 결제키 · 시크릿
    const orderId = String(crp.order_id || ex.order_id || '');
    if(!orderId) return json({ ok: false, error: 'no_order' });
    const pos = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=order_id,user_id,status,amount,currency,payment_key,metadata`);
    const po = pos[0];
    if(!po || String(po.status) !== 'paid' || !po.payment_key) return json({ ok: false, error: 'no_toss_payment', order_status: po?.status || null });
    if(po.user_id && t.user_id && String(po.user_id) !== String(t.user_id)) return json({ ok: false, error: 'owner_mismatch' });
    const cur = String(po.currency || 'KRW').toUpperCase();
    if(cur !== 'KRW') return json({ ok: false, error: 'currency_not_supported', currency: cur });
    const viaBilling = String(po.metadata?.paid_via || '') === 'billing_key';
    const secret = viaBilling ? (Deno.env.get('TOSS_BILLING_SECRET_KEY') || Deno.env.get('TOSS_SECRET_KEY')) : Deno.env.get('TOSS_SECRET_KEY');
    if(!secret) return json({ ok: false, error: 'no_secret' }, 500);
    const auth = `Basic ${btoa(secret + ':')}`;
    const pk = encodeURIComponent(String(po.payment_key));

    // ③ 남은 취소 가능액
    const gr = await fetch(`https://api.tosspayments.com/v1/payments/${pk}`, { headers: { Authorization: auth } });
    const pay = await gr.json().catch(() => null);
    if(!gr.ok || !pay) return json({ ok: false, error: 'toss_lookup_failed', toss: { code: pay?.code, message: pay?.message } });
    const balance = Number(pay.balanceAmount ?? 0);
    if(String(pay.status) === 'CANCELED' || !(balance > 0)) return json({ ok: false, error: 'already_canceled_at_toss', balance, toss_status: pay.status });
    if(amount > balance) return json({ ok: false, error: 'exceeds_balance', balance, amount });

    // ④ 승인취소
    const cr = await fetch(`https://api.tosspayments.com/v1/payments/${pk}/cancel`, {
      method: 'POST',
      headers: { Authorization: auth, 'Content-Type': 'application/json', 'Idempotency-Key': `taam-crf-${pid}-${amount}` },
      body: JSON.stringify({ cancelReason: String(reason || crp.reason || '예약 취소 (카드 결제분 환불)').slice(0, 200), cancelAmount: amount }),
    });
    const toss = await cr.json().catch(() => null);
    if(!cr.ok || !toss) return json({ ok: false, error: 'toss_cancel_failed', toss: { code: toss?.code, message: toss?.message } });
    const cancels = Array.isArray(toss.cancels) ? toss.cancels : [];
    const mine = cancels.filter((c: any) => Number(c?.cancelAmount) === amount).pop() || cancels[cancels.length - 1] || {};

    // ⑤ 기록 — 실패해도 토스 취소는 이미 됐다
    const now = new Date().toISOString();
    const newEx = { ...ex, card_refund_pending: { ...crp, status: 'done', refunded_at: now, done_by: by, via: 'toss_api',
      toss_tx: mine.transactionKey || null, toss_canceled_at: mine.canceledAt || null, toss_balance_after: toss.balanceAmount ?? null } };
    const up = await sbPatch(`tickets?id=eq.${encodeURIComponent(String(t.id))}`, { extra_data: newEx });
    try {   // 주문 표에도 한 줄 (판매 현황·수수료 계산은 status 로 세므로 status 는 그대로 둔다)
      const md = (po.metadata && typeof po.metadata === 'object') ? po.metadata : {};
      const prev = Array.isArray(md.app_cancels) ? md.app_cancels : [];
      await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}`, { metadata: { ...md, app_cancels: [...prev, { purchase_id: pid, amount, tx: mine.transactionKey || null, at: now, by }] } });
    } catch (_e) { /* 기록용 */ }
    return json({ ok: true, amount, order_id: orderId, toss_status: toss.status, balance_after: toss.balanceAmount ?? null,
                  mark_failed: !up.ok, user_id: t.user_id, restaurant_name: t.restaurant_name || '' });
  } catch (e) { console.error('[toss-card-refund]', e); return json({ ok: false, error: String((e as Error).message || e).slice(0, 200) }, 500); }
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
