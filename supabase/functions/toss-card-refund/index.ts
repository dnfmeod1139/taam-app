// ═════════════════════════════════════════════════
// toss-card-refund — 앱 카드 결제분 환불(토스 승인취소)을 슈퍼어드민이 앱에서 · 2026-10-22
// ═════════════════════════════════════════════════
// 왜: 회원이 카드가 섞인 티켓을 취소하면 앱은 예치금 몫만 돌려주고 카드 몫은 tickets.extra_data.card_refund_pending
//     {amount, order_id, status:'pending'} 로 남긴다. 지금까지는 슈퍼어드민이 토스 상점관리자에서 승인취소를 하고
//     앱의 「카드 환불 완료」(tkMarkCardRefundDone)를 눌렀다. 이 함수가 그 승인취소를 토스 API 로 직접 한다.
// 누가: 슈퍼어드민(JWT · verify_jwt=true + profiles.role 확인). 회원·매장 어드민은 403.
// ⚠ 2026-10-22 적대 리뷰: 대기(card_refund_pending)의 금액·주문번호는 회원이 쓸 수 있는 칸이다 → 믿지 않는다.
//   금액·주문은 서버 견적 taam_card_refund_quote(20261022_card_refund_quote.sql)가 이 구매의 주문(hold_purchase_id)·원장·서버 취소 시각으로 다시 센다.
// 무엇을:
//   ① 서버 견적(목표 = 회원이 적은 대기면 min(대기, 규정 카드 몫) · 슈퍼어드민이 적은 대기면 min(대기, 카드 결제액)) · 주문·결제키·paid_via.
//   ② 시크릿은 승인한 MID 의 것 —
//      승인한 MID 의 시크릿으로 취소해야 한다: 등록 카드 자동결제(paid_via billing_key)는 TOSS_BILLING_SECRET_KEY(없으면 TOSS_SECRET_KEY),
//      일반 결제창은 TOSS_SECRET_KEY. 외화 주문은 대기 금액이 원화라 단위가 다르다 → 막고 상점관리자로 안내.
//   ③ 이 구매에 앱이 이미 한 카드 취소(payment_orders.metadata.app_cancels · 견적의 done_for_purchase)를 빼고 토스 남은 금액 안에서만.
//      **토스에 앱 밖 취소(상점관리자 · 인원 줄임 부분취소)가 하나라도 있으면 자동으로 하지 않는다**(outside_cancel) — 그 취소가 이 환불을 이미 했는지 서버가 가릴 수 없다
//      (배포 전 2차 검증: 먼저 상점관리자에서 돌려준 대기를 두 번 돌려주던 길). 앱이 「이미 했으면 완료 표시 · 아니면 상점관리자에서」로 안내한다.
//      dry_run 이면 금액만 돌려준다(앱 확인창) · 실행은 expect_amount 가 지금 금액과 같아야 한다(amount_changed).
//   ④ POST /v1/payments/{paymentKey}/cancel {cancelReason, cancelAmount} · Idempotency-Key 'taam-crf-<구매>-<이 구매에 앱이 한 취소 누적>'
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

async function sbRpc(fn: string, args: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: SB_H(), body: JSON.stringify(args) });
  const b = await r.json().catch(() => null); if(!r.ok) throw new Error((b && (b.message || b.hint)) || ('rpc ' + fn + ' ' + r.status)); return b;
}

async function handle(req: Request){
  if(req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const by = await superCaller(req);
  if(!by) return json({ ok: false, error: 'forbidden' }, 403);
  try {
    const { purchase_id, reason, dry_run, expect_amount } = await req.json().catch(() => ({}));
    const pid = String(purchase_id || '');
    if(!pid || pid.length > 120 || !/^[A-Za-z0-9_\-:.]+$/.test(pid)) return json({ ok: false, error: 'bad_purchase_id' });

    // ① 서버 견적 — 이 구매의 주문(hold_purchase_id)·원장·서버 취소 시각으로 회원 규정 카드 몫을 다시 센다 (회원이 쓸 수 있는 금액·주문번호는 안 믿는다)
    const q = await sbRpc('taam_card_refund_quote', { p_purchase_id: pid });
    if(!q || !q.ok) return json({ ok: false, error: q?.error || 'quote_failed', status: q?.status, currency: q?.currency });
    const viaBilling = String(q.paid_via || '') === 'billing_key';
    const secret = viaBilling ? (Deno.env.get('TOSS_BILLING_SECRET_KEY') || Deno.env.get('TOSS_SECRET_KEY')) : Deno.env.get('TOSS_SECRET_KEY');
    if(!secret) return json({ ok: false, error: 'no_secret' }, 500);
    const auth = `Basic ${btoa(secret + ':')}`;
    const pk = encodeURIComponent(String(q.payment_key));

    // ② 이 구매에 앱이 이미 한 카드 취소(서버 기록 app_cancels)만 뺀다 — 같은 결제의 다른 취소(인원 줄임·상점관리자)는 막지 않고 경고로 보여 준다(2차 · 적대 검증)
    //    토스의 남은 금액(balanceAmount)은 언제나 상한이다.
    const gr = await fetch(`https://api.tosspayments.com/v1/payments/${pk}`, { headers: { Authorization: auth } });
    const pay = await gr.json().catch(() => null);
    if(!gr.ok || !pay) return json({ ok: false, error: 'toss_lookup_failed', toss: { code: pay?.code, message: pay?.message } });
    const tossTotal = Number(pay.totalAmount ?? q.card_paid ?? 0);
    const balance = Number(pay.balanceAmount ?? 0);
    const cancelled = Math.max(0, tossTotal - balance);                                   // 이 결제에서 토스가 취소한 전부
    const done = Math.max(0, Math.floor(Number(q.done_for_purchase || 0)));              // 그중 이 구매에 앱이 한 것
    const other = Math.max(0, cancelled - Math.max(0, Math.floor(Number(q.app_cancelled_order || 0))));   // 앱 밖(상점관리자·인원 줄임) 취소
    const target = Math.floor(Number(q.target || 0));
    const amount = Math.max(0, Math.min(target - done, balance));
    const info = { amount, target, done, cancelled, other_cancelled: other, balance, card_paid: q.card_paid, pending: q.pending, policy: q.policy, set_by_role: q.set_by_role,
                   order_id: q.order_id, order_note: (q.crp_order_id && q.crp_order_id !== q.order_id) ? 'pending_order_differs' : null };
    if(done >= target && done > 0) return json({ ok: false, error: 'already_done_by_app', ...info });
    if(other > 0) return json({ ok: false, error: 'outside_cancel', ...info });           // 앱 밖 취소가 있으면 사람이 상점관리자에서 본다
    if(!(amount > 0)) return json({ ok: false, error: !(balance > 0) ? 'nothing_left_at_toss' : 'nothing_to_refund', ...info });
    if(dry_run) return json({ ok: true, dry_run: true, ...info });
    if(Math.floor(Number(expect_amount)) !== amount) return json({ ok: false, error: 'amount_changed', ...info });   // 앱이 본 금액과 지금 금액이 다르면 다시 보여 준다

    // ③ 승인취소 — 키는 「구매 + 지금까지 취소된 금액」: 두 번 눌러도 같은 키(토스가 한 번만), 다음 취소는 새 키
    const cr = await fetch(`https://api.tosspayments.com/v1/payments/${pk}/cancel`, {
      method: 'POST',
      headers: { Authorization: auth, 'Content-Type': 'application/json', 'Idempotency-Key': `taam-crf-${pid}-${done}` },
      body: JSON.stringify({ cancelReason: String(reason || '예약 취소 (카드 결제분 환불)').slice(0, 200), cancelAmount: amount }),
    });
    const toss = await cr.json().catch(() => null);
    if(!cr.ok || !toss) return json({ ok: false, error: 'toss_cancel_failed', toss: { code: toss?.code, message: toss?.message }, ...info });
    const cancels = Array.isArray(toss.cancels) ? toss.cancels : [];
    const mine = cancels.filter((c: any) => Number(c?.cancelAmount) === amount).pop() || cancels[cancels.length - 1] || {};

    // ④ 기록 — 실패해도 토스 취소는 이미 됐다
    const now = new Date().toISOString();
    const rows = await sbGet(`tickets?purchase_id=eq.${encodeURIComponent(pid)}&select=id,extra_data&order=created_at.desc&limit=1`);
    const t = rows[0] || {};
    const ex = (t.extra_data && typeof t.extra_data === 'object') ? t.extra_data : {};
    const crp = (ex.card_refund_pending && typeof ex.card_refund_pending === 'object') ? ex.card_refund_pending : {};
    const newEx = { ...ex, card_refund_pending: { ...crp, status: 'done', refunded_at: now, done_by: by, via: 'toss_api', refunded_amount: amount,
      requested_amount: crp.requested_amount ?? crp.amount ?? null, amount,
      order_id: q.order_id, toss_tx: mine.transactionKey || null, toss_canceled_at: mine.canceledAt || null, toss_balance_after: toss.balanceAmount ?? null, policy: q.policy } };
    const up = t.id ? await sbPatch(`tickets?id=eq.${encodeURIComponent(String(t.id))}`, { extra_data: newEx }) : { ok: false };
    try {   // 주문 표에도 한 줄 (판매 현황·수수료 계산은 status 로 세므로 status 는 그대로 둔다)
      const pos = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(String(q.order_id))}&select=metadata`);
      const md = (pos[0]?.metadata && typeof pos[0].metadata === 'object') ? pos[0].metadata : {};
      const prev = Array.isArray(md.app_cancels) ? md.app_cancels : [];
      await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(String(q.order_id))}`, { metadata: { ...md, app_cancels: [...prev, { purchase_id: pid, amount, tx: mine.transactionKey || null, at: now, by, policy: q.policy }] } });
    } catch (_e) { /* 기록용 */ }
    return json({ ok: true, ...info, toss_status: toss.status, balance_after: toss.balanceAmount ?? null,
                  mark_failed: !up.ok, user_id: q.user_id, restaurant_name: q.restaurant_name || '' });
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
