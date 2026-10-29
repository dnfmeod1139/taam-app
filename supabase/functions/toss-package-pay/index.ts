// ═════════════════════════════════════════════════
// toss-package-pay — 티켓 패키지(연계 회차)의 카드 몫 결제 · 승인 · 환불 · 2026-10-29
// ═════════════════════════════════════════════════
// 왜 새 함수인가: 옛 toss-order / toss-confirm 은 「주문 1건 = 좌석 홀드 1건」이고 저장소 판을 대시보드 판과 대조한 적이 없어 덮어쓰지 않는다.
//   패키지는 회차 여러 줄을 한 번에 확정해야 한다 — 돈·좌석 판단은 전부 서버 함수(20261029_ticket_package.sql)가 **한 트랜잭션**으로 하고,
//   이 함수는 토스와 이야기하는 일만 한다(주문 만들기 · 결제창 승인 · 등록 카드 승인 · 실패면 승인 취소 · 슈퍼어드민 카드 환불).
// 동작(action):
//   order   — 회원 · {group_id} → taam_package_order_prepare(묶음·홀드·금액을 서버가 다시 센다 · 예치금 먼저 · 카드 몫만 주문) → {order_id, amount}
//             결제창은 앱이 이 orderId/amount 로 연다(successUrl ?toss_pay=success → 앱이 action confirm 으로).
//   confirm — 회원 · {orderId, paymentKey, amount} → 주문(package_topup · 본인 · pending) → 토스 승인(TOSS_SECRET_KEY) → 주문 paid → 확정
//   billing — 회원 · {group_id} → 주문 만들기 + 등록 카드(billing_keys) 승인(TOSS_BILLING_SECRET_KEY · 없으면 TOSS_SECRET_KEY) → 확정
//   refund  — 슈퍼어드민 · {group_id, dry_run | expect_amount} → 서버 견적(취소 때 정한 카드 몫) → 토스 남은 금액 확인 → 부분취소 → 완료 표시
// 확정 = taam_package_confirm_card(주문) — 예치금 차감 · 회차 줄 확정 · 줄마다 예치금·카드 몫을 한 트랜잭션으로. 실패하면(좌석 만료·예치금 변동·패키지 해제·늦게 온 옛 주문)
//   토스 승인을 **전액 취소**하고(Idempotency-Key taam-cancel-<paymentKey>) 주문 canceled · 묶음 failed(홀드 반납).
//   주문이 이미 paid 인데 확정이 안 된 상태(앞 호출이 중간에 끊김)면 confirm 을 다시 부르면 확정부터 다시 한다(확정은 멱등 · 취소 키도 같다).
// 토스 응답 원문은 저장하지 않는다(secret 칸) — 고른 칸만.
// 주문을 paid 로 잡을 때 metadata.pkg_claim = 'toss-package-pay' 를 적는다 — DB 가 이 표시 없는 패키지 주문의 paid 를 거절한다
//   (옛 toss-confirm/toss-billing-charge 가 패키지 주문번호로 불려도 좌석 없이 paid 로 끝나지 않게 · 20261029_ticket_package.sql B').
// 오류는 HTTP 200 + {ok:false, error} (앱이 사유를 읽는다) — 인증만 401/403.
// 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY · TOSS_SECRET_KEY · TOSS_BILLING_SECRET_KEY(선택)
// ═════════════════════════════════════════════════
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
function json(b: unknown, s = 200){ return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
const SB_H = () => ({ apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' });
const TOSS = 'https://api.tosspayments.com';

async function sbGet(path: string){ const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: SB_H() }); return r.ok ? await r.json().catch(() => []) : null; }
async function sbPatch(path: string, body: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'PATCH', headers: { ...SB_H(), Prefer: 'return=representation' }, body: JSON.stringify(body) });
  const b = await r.json().catch(() => null); return { ok: r.ok, rows: Array.isArray(b) ? b : [], status: r.status };
}
async function sbInsert(path: string, rows: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'POST', headers: { ...SB_H(), Prefer: 'return=minimal' }, body: JSON.stringify(rows) });
  return r.ok;
}
async function sbRpc(fn: string, args: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: SB_H(), body: JSON.stringify(args) });
  const b = await r.json().catch(() => null);
  if(!r.ok) throw new Error(String((b && (b.message || b.hint)) || ('rpc ' + fn + ' ' + r.status)));
  return b;
}
async function caller(req: Request): Promise<{ id: string; email: string; role: string } | null>{
  const h = req.headers.get('Authorization') || ''; const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  if(!t) return null;
  const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${t}` } });
  if(!u.ok) return null; const j = await u.json().catch(() => null); if(!j?.id) return null;
  const p = await sbGet(`profiles?id=eq.${encodeURIComponent(j.id)}&select=role`);
  return { id: String(j.id), email: String(j.email || ''), role: String((p && p[0]?.role) || '') };
}
const isSuper = (r: string) => r === 'superadmin' || r === 'super_admin';

// 서버 함수 오류 → 앱 코드
function sqlCode(m: string): string {
  const map: [RegExp, string][] = [
    [/HOLD_GONE|HOLDS_MISMATCH/, 'hold_gone'], [/PACKAGE_NOT_ACTIVE/, 'package_closed'], [/PACKAGE_CHANGED/, 'package_changed'],
    [/INSUFFICIENT_DEPOSIT/, 'deposit_short'], [/PRICE_CHANGED|PRICE_NOT_SET/, 'price_changed'], [/GROUP_CLOSED|GROUP_NOT_FOUND/, 'group_closed'],
    [/ORDER_SUPERSEDED/, 'superseded'], [/ORDER_NOT_PAID|ORDER_NOT_FOUND/, 'order_not_found'], [/FORBIDDEN|내 예약이 아닙니다/, 'forbidden'],
  ];
  for(const [re, c] of map) if(re.test(m)) return c;
  return 'confirm_failed';
}
// 토스 응답에서 남길 칸만(secret 등 원문 칸은 저장하지 않는다)
function pickToss(t: Record<string, any>){
  const c = t && t.card ? { company: t.card.company, issuerCode: t.card.issuerCode, number: t.card.number, approveNo: t.card.approveNo, cardType: t.card.cardType, installmentPlanMonths: t.card.installmentPlanMonths } : null;
  return { status: t?.status, method: t?.method, totalAmount: t?.totalAmount, balanceAmount: t?.balanceAmount, approvedAt: t?.approvedAt, mId: t?.mId,
           receiptUrl: t?.receipt?.url || null, card: c, easyPay: t?.easyPay ? { provider: t.easyPay.provider, amount: t.easyPay.amount } : null };
}
async function tossCall(secret: string, path: string, method: string, body?: unknown, idem?: string){
  const h: Record<string, string> = { Authorization: 'Basic ' + btoa(secret + ':'), 'Content-Type': 'application/json' };
  if(idem) h['Idempotency-Key'] = idem;
  const r = await fetch(TOSS + path, { method, headers: h, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body: j as Record<string, any> };
}
async function tossCancelAll(secret: string, paymentKey: string, reason: string): Promise<boolean>{
  if(!paymentKey) return false;
  try {
    const r = await tossCall(secret, `/v1/payments/${encodeURIComponent(paymentKey)}/cancel`, 'POST', { cancelReason: reason }, `taam-cancel-${paymentKey}`);
    return r.ok || String(r.body?.code || '') === 'ALREADY_CANCELED_PAYMENT';
  } catch(_e){ return false; }
}
const secretFor = (paidVia: string) => paidVia === 'billing_key'
  ? (Deno.env.get('TOSS_BILLING_SECRET_KEY') || Deno.env.get('TOSS_SECRET_KEY') || '')
  : (Deno.env.get('TOSS_SECRET_KEY') || '');

// ── 확정 — 주문이 paid 가 된 뒤. 실패면 전액 취소 + 묶음 실패 ──
async function finalize(order: Record<string, any>, paymentKey: string, secret: string, buyer: { id: string; email: string }){
  const gid = String(order.metadata?.group_id || '');
  try {
    const res = await sbRpc('taam_package_confirm_card', { p_order: order.order_id });
    notifyAll(order, res, buyer).catch(() => {});
    return json({ ok: true, already: !!res?.already, group_id: gid, total: res?.total, card_paid: res?.card_paid, deposit_used: res?.deposit_used,
                  rows: (res?.rows || []).map((r: any) => ({ purchase_id: r.purchase_id, rest_name: r.rest_name, date: r.date, time: r.time })) });
  } catch(e){
    const msg = String((e as Error).message || e);
    const code = sqlCode(msg);
    console.warn('[toss-package-pay] 확정 실패 — 승인 취소', order.order_id, msg.slice(0, 160));
    const canceled = await tossCancelAll(secret, paymentKey, code === 'deposit_short' ? '예치금 부족으로 구매 불가' : '좌석·패키지 변동으로 구매 불가');
    await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}`,
      { status: canceled ? 'canceled' : 'paid', fail_reason: code + (canceled ? '_refunded' : '_refund_failed') });
    if(gid && code !== 'superseded') { try { await sbRpc('taam_package_fail', { p_group: gid, p_reason: code }); } catch(_fe){ /* 홀드는 5분 뒤 풀린다 */ } }
    if(!canceled) notifyCancelFailed(order, code).catch(() => {});
    return json({ ok: false, error: code, refunded: canceled, orderId: order.order_id });
  }
}

// ── 알림 — 슈퍼어드민(벨 + 푸시) · 회차 매장 파트너(notify-purchase) ──
async function notifyAll(order: Record<string, any>, res: Record<string, any>, buyer: { id: string }){
  if(res?.already) return;
  const title0 = String(res?.title || order.metadata?.title || '패키지');
  let who = '회원';
  try { const p = await sbGet(`profiles?id=eq.${encodeURIComponent(buyer.id)}&select=display_name,phone`); const d = p && p[0];
        if(d?.display_name && String(d.display_name).trim()) who = String(d.display_name).trim();
        else if(d?.phone) who = '회원 ' + String(d.phone).replace(/[^0-9]/g, '').slice(-4); } catch(_e){ /* 이름은 장식 */ }
  const rows = (res?.rows || []) as any[];
  const title = '🎫 ' + who + '님이 패키지를 구매했습니다';
  const body = who + '님 · 「' + title0 + '」 ' + rows.length + '회차 · ' + Number(order.metadata?.pax || 0) + '인 · ₩' + Number(res?.total || 0).toLocaleString()
             + ' (카드 ₩' + Number(res?.card_paid || 0).toLocaleString() + ')\n'
             + rows.map((r) => String(r.rest_name || '') + ' ' + String(r.date || '') + ' ' + String(r.time || '')).join('\n');
  try {
    const sups = await sbGet(`profiles?role=in.(superadmin,super_admin)&select=id`) || [];
    const ins = sups.filter((p: any) => p.id !== buyer.id).map((p: any) => ({ user_id: p.id, type: 'ticket_purchased', title, body, url: '/',
      payload: { purchase_id: rows[0]?.purchase_id || null, package_order: order.metadata?.group_id, amount: res?.total, paid_by: 'card', buyer: who, via: 'toss-package-pay' } }));
    if(ins.length) await sbInsert('notifications', ins);
  } catch(_e){ /* 벨은 부가 */ }
  for(const role of ['superadmin', 'super_admin']){
    try { await fetch(`${SUPABASE_URL}/functions/v1/send-push`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ to: 'role:' + role, payload: { title, body, url: '/', category: 'ticket_purchased', tag: 'taam-pkg-' + order.metadata?.group_id } }) }); } catch(_e){ /* 다음 */ }
  }
  for(const r of rows){
    try { await fetch(`${SUPABASE_URL}/functions/v1/notify-purchase`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ purchase_id: r.purchase_id }) }); } catch(_e){ /* 매장 알림은 부가 */ }
  }
}
async function notifyCancelFailed(order: Record<string, any>, code: string){
  const sups = await sbGet(`profiles?role=in.(superadmin,super_admin)&select=id`) || [];
  const title = '⚠ 패키지 카드 결제 자동 취소 실패 — 상점관리자 확인 필요';
  const body = '주문 ' + order.order_id + ' · ₩' + Number(order.amount || 0).toLocaleString() + ' · 사유 ' + code + ' — 좌석은 확정되지 않았습니다. 토스 상점관리자에서 승인취소해 주세요.';
  if(sups.length) await sbInsert('notifications', sups.map((p: any) => ({ user_id: p.id, type: 'seat_hold_convert_failed', title, body, url: '/',
    payload: { order_id: order.order_id, package_order: order.metadata?.group_id, actor_id: order.user_id, via: 'toss-package-pay' } })));
}

async function prepare(groupId: string, uid: string){
  try { return { ok: true, data: await sbRpc('taam_package_order_prepare', { p_group: groupId, p_uid: uid }) }; }
  catch(e){ return { ok: false, code: sqlCode(String((e as Error).message || e)) }; }
}

async function handle(req: Request){
  if(req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const me = await caller(req);
  if(!me) return json({ ok: false, error: 'unauthorized' }, 401);
  try {
    const body = await req.json().catch(() => ({})) as Record<string, any>;
    const action = String(body.action || '');
    const gid = String(body.group_id || '');
    if(gid && (gid.length > 80 || !/^[A-Za-z0-9_\-:.]+$/.test(gid))) return json({ ok: false, error: 'bad_group' });

    if(action === 'order'){
      if(!gid) return json({ ok: false, error: 'bad_group' });
      const p = await prepare(gid, me.id);
      if(!p.ok) return json({ ok: false, error: p.code });
      const d = p.data as Record<string, any>;
      if(!d.need_payment) return json({ ok: true, need_payment: false, total: d.total });
      return json({ ok: true, need_payment: true, orderId: d.order_id, amount: d.amount, total: d.total, depositUsed: d.deposit_used, title: d.title, currency: 'KRW' });
    }

    if(action === 'confirm'){
      const orderId = String(body.orderId || ''), paymentKey = String(body.paymentKey || ''), clientAmount = Number(body.amount || 0);
      if(!/^taampkg_[0-9_]+$/.test(orderId) || !paymentKey || paymentKey.length > 200) return json({ ok: false, error: 'missing_params' });
      const rows = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=*`);
      if(rows === null) return json({ ok: false, error: 'order_lookup_failed' });
      const order = rows[0];
      if(!order || order.purpose !== 'package_topup') return json({ ok: false, error: 'order_not_found' });
      if(order.user_id !== me.id) return json({ ok: false, error: 'order_forbidden' }, 403);
      if(String(order.currency || 'KRW').toUpperCase() !== 'KRW') return json({ ok: false, error: 'currency_not_supported' });
      const secret = Deno.env.get('TOSS_SECRET_KEY') || '';
      if(!secret) return json({ ok: false, error: 'server_not_configured' });
      if(order.status === 'paid'){
        // 앞 호출이 승인 뒤에 끊겼다 — 확정부터 다시(멱등). 이미 확정이면 already.
        return await finalize(order, String(order.payment_key || paymentKey), secretFor(String(order.metadata?.paid_via || '')), me);
      }
      if(order.status !== 'pending') return json({ ok: false, error: 'order_not_pending', status: order.status });
      const expected = Number(order.amount);
      if(clientAmount && clientAmount !== expected){
        await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: 'amount_mismatch_client' });
        return json({ ok: false, error: 'amount_mismatch' });
      }
      const t = await tossCall(secret, '/v1/payments/confirm', 'POST', { paymentKey, orderId, amount: expected }, `taam-confirm-${orderId}`);
      if(!t.ok || t.body?.status !== 'DONE'){
        const reason = String(t.body?.message || t.body?.code || ('http_' + t.status)).slice(0, 300);
        await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: reason });
        try { await sbRpc('taam_package_fail', { p_group: String(order.metadata?.group_id || ''), p_reason: 'confirm_failed' }); } catch(_e){ /* 5분 뒤 풀린다 */ }
        return json({ ok: false, error: 'confirm_failed', reason });
      }
      const approved = Number(t.body.totalAmount ?? t.body.balanceAmount ?? 0);
      if(approved !== expected){
        const canceled = await tossCancelAll(secret, paymentKey, '금액 불일치');
        await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: canceled ? 'canceled' : 'failed', fail_reason: 'amount_mismatch_toss:' + approved });
        return json({ ok: false, error: 'amount_mismatch_toss', refunded: canceled });
      }
      const claim = await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, {
        status: 'paid', payment_key: paymentKey, method: t.body.method || null, receipt_url: t.body.receipt?.url || null,
        approved_at: t.body.approvedAt || new Date().toISOString(), metadata: { ...(order.metadata || {}), toss: pickToss(t.body), paid_via: 'window', pkg_claim: 'toss-package-pay' } });
      if(!claim.ok) return json({ ok: false, error: 'order_update_failed', paid: true });
      if(!claim.rows.length){
        const again = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=*`);
        return await finalize((again && again[0]) || order, paymentKey, secret, me);
      }
      return await finalize(claim.rows[0], paymentKey, secret, me);
    }

    if(action === 'billing'){
      if(!gid) return json({ ok: false, error: 'bad_group' });
      const secret = Deno.env.get('TOSS_BILLING_SECRET_KEY') || Deno.env.get('TOSS_SECRET_KEY') || '';
      if(!secret) return json({ ok: false, error: 'server_not_configured' });
      const cards = await sbGet(`billing_keys?user_id=eq.${encodeURIComponent(me.id)}&deleted_at=is.null&select=id,billing_key,card_company,card_number,is_default&order=is_default.desc,created_at.desc&limit=1`);
      if(cards === null) return json({ ok: false, error: 'card_lookup_failed' });
      const card = cards[0];
      if(!card) return json({ ok: false, error: 'no_billing_key' });
      const p = await prepare(gid, me.id);
      if(!p.ok) return json({ ok: false, error: p.code });
      const d = p.data as Record<string, any>;
      if(!d.need_payment) return json({ ok: true, need_payment: false, total: d.total });
      const orderId = String(d.order_id), amount = Number(d.amount);
      const t = await tossCall(secret, `/v1/billing/${encodeURIComponent(card.billing_key)}`, 'POST',
        { customerKey: me.id, amount, orderId, orderName: ('[TAAM] 패키지 ' + String(d.title || '')).slice(0, 100), customerEmail: me.email || undefined },
        `taam-billing-${orderId}`);
      if(!t.ok || t.body?.status !== 'DONE'){
        const reason = String(t.body?.message || t.body?.code || ('http_' + t.status)).slice(0, 300);
        await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: reason });
        return json({ ok: false, error: 'charge_failed', reason: reason.slice(0, 200) });
      }
      const pk = String(t.body.paymentKey || '');
      const approved = Number(t.body.totalAmount ?? t.body.balanceAmount ?? 0);
      if(approved !== amount){
        const canceled = await tossCancelAll(secret, pk, '금액 불일치');
        await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: canceled ? 'canceled' : 'failed', fail_reason: 'amount_mismatch_toss:' + approved });
        return json({ ok: false, error: 'amount_mismatch_toss', refunded: canceled });
      }
      const ordRows = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=metadata`);
      const meta0 = (ordRows && ordRows[0]?.metadata) || {};
      const claim = await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, {
        status: 'paid', payment_key: pk, method: t.body.method || 'billing', receipt_url: t.body.receipt?.url || null,
        approved_at: t.body.approvedAt || new Date().toISOString(),
        metadata: { ...meta0, toss: pickToss(t.body), paid_via: 'billing_key', billing_key_id: card.id, pkg_claim: 'toss-package-pay' } });
      if(!claim.ok || !claim.rows.length){
        // 그 사이 다른 호출이 주문을 바꿨다(새 주문으로 덮임 등) — 이 승인은 확정하지 않고 취소한다
        const canceled = await tossCancelAll(secret, pk, '주문 상태 변경');
        return json({ ok: false, error: 'superseded', refunded: canceled });
      }
      const r = await finalize(claim.rows[0], pk, secret, me);
      return r;
    }

    if(action === 'refund'){
      if(!isSuper(me.role)) return json({ ok: false, error: 'forbidden' }, 403);
      if(!gid) return json({ ok: false, error: 'bad_group' });
      let q: Record<string, any>;
      try { q = await sbRpc('taam_package_card_refund_quote', { p_group: gid }); } catch(e){ return json({ ok: false, error: sqlCode(String((e as Error).message || e)) }); }
      if(!q?.ok) return json({ ok: false, error: q?.error || 'no_pending' });
      const secret = secretFor(String(q.paid_via || ''));
      if(!secret) return json({ ok: false, error: 'server_not_configured' });
      const g = await tossCall(secret, `/v1/payments/${encodeURIComponent(q.payment_key)}`, 'GET');
      if(!g.ok) return json({ ok: false, error: 'toss_lookup_failed', status: g.status });
      const total = Number(g.body.totalAmount || 0), balance = Number(g.body.balanceAmount ?? total);
      const want = Number(q.amount || 0);
      if(total - balance > 0) return json({ ok: false, error: 'outside_cancel', cancelled: total - balance, amount: want, balance });
      if(want <= 0) return json({ ok: false, error: 'no_pending' });
      if(want > balance) return json({ ok: false, error: 'exceeds_balance', amount: want, balance });
      if(body.dry_run) return json({ ok: true, dry_run: true, amount: want, balance, card_paid: q.card_paid, order_id: q.order_id });
      if(Number(body.expect_amount) !== want) return json({ ok: false, error: 'amount_changed', amount: want });
      const c = await tossCall(secret, `/v1/payments/${encodeURIComponent(q.payment_key)}/cancel`, 'POST',
        { cancelReason: String(body.reason || '패키지 취소 환불').slice(0, 200), cancelAmount: want }, `taam-pkgrf-${gid}`);
      if(!c.ok) return json({ ok: false, error: 'cancel_failed', reason: String(c.body?.message || c.body?.code || c.status).slice(0, 200) });
      const cancels = Array.isArray(c.body?.cancels) ? c.body.cancels : [];
      const tx = String((cancels[cancels.length - 1] || {}).transactionKey || '');
      try {
        const m = await sbRpc('taam_package_card_refund_mark', { p_group: gid, p_amount: want, p_tx: tx || null, p_via: 'toss_api' });
        return json({ ok: true, refunded: want, first_purchase_id: m?.first_purchase_id || q.first_purchase_id, user_id: q.user_id });
      } catch(_e){
        return json({ ok: true, refunded: want, mark_failed: true, first_purchase_id: q.first_purchase_id, user_id: q.user_id });
      }
    }
    return json({ ok: false, error: 'bad_action' });
  } catch(e){
    console.error('[toss-package-pay] 예외', e);
    return json({ ok: false, error: 'exception' });
  }
}

// CORS — 우리 오리진만 (다른 결제 함수와 같다)
const TAAM_ORIGINS = ['https://taam-app.vercel.app', 'https://playtaam.com', 'https://www.playtaam.com'];
function taamOrigin(req: Request): string {
  const o = req.headers.get('Origin') || '';
  if(TAAM_ORIGINS.includes(o) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)) return o;
  return TAAM_ORIGINS[0];
}
Deno.serve(async (req: Request) => {
  const res = await handle(req);
  try { res.headers.set('Access-Control-Allow-Origin', taamOrigin(req)); res.headers.append('Vary', 'Origin'); } catch(_e){ /* 그대로 */ }
  return res;
});
