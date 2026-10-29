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
//   resume  — 회원(자기 묶음) · 슈퍼어드민(누구든 — 「카드 결제 확인」) · {group_id} → 그 묶음의 마지막 카드 주문: paid 면 확정부터 · pending 이면 토스에 주문 번호로 조회(새로 긁지 않는다)
//   sweep   — 서버만(service_role · 정리 크론 taam_package_reconcile_kick 10분) → taam_package_reconcile_list 가 고른 주문(확정 안 된 paid · 10분 넘은 pending · 취소 실패)을 정리
//   refund  — 슈퍼어드민 · {group_id, dry_run | expect_amount} → 서버 견적(취소 때 정한 카드 몫) → 토스 남은 금액 확인 → 부분취소 → 완료 표시
// 확정 = taam_package_confirm_card(주문) — 예치금 차감 · 회차 줄 확정 · 줄마다 예치금·카드 몫을 한 트랜잭션으로. 서버가 **분명히** 거절하면(좌석 만료·예치금 변동·
//   패키지 해제·늦게 온 옛 주문 — 4xx + 우리 코드) 토스 승인을 **전액 취소**하고(Idempotency-Key taam-cancel-<paymentKey>) 주문 canceled · 묶음 failed(홀드 반납).
//   ⚠ 애매한 실패(네트워크 · 5xx · 모르는 오류)에는 취소하지 않는다 — 확정이 실제로는 됐을 수 있다(적대 리뷰). 묶음을 다시 읽고 · 한 번 더 부르고 ·
//   그래도 모르면 주문은 paid 로 두고 {retry:true} + 슈퍼어드민 알림. 앱이 confirm 을 다시 부르면 확정부터 다시 한다(확정은 멱등 · 취소 키도 같다).
//   취소하기 전에도 묶음을 다시 읽어 **이 주문으로 이미 확정(또는 그 뒤 취소)된 묶음이면 취소하지 않는다**(취소 규정을 비켜 가는 전액 환불이 된다).
// 토스 승인 응답이 애매하면(5xx · 409 · ALREADY_PROCESSED · 처리 중 · 네트워크) 주문·묶음을 실패로 만들지 않는다 — 결제를 조회해 DONE 이면 잇고, 아니면 {retry:true}.
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
// 실패는 {status, definite} 을 단 Error — definite = 서버 함수가 **우리 코드로** 거절했다(트랜잭션은 롤백됐다).
//   ⚠ HTTP 상태로 가르지 않는다 — PostgREST 는 P0001 만 400 이고 그 밖의 P0* (우리 HOLD_GONE · ORDER_SUPERSEDED · GROUP_CLOSED · PACKAGE_* 는 P0002)를
//   **500** 으로 보낸다(2차 검증). 본문에 SQLSTATE(code)가 있고 메시지가 우리 코드면 분명한 거절, 게이트웨이 5xx·네트워크·모르는 오류는 애매.
class RpcError extends Error { status: number; definite: boolean;
  constructor(m: string, status: number, pgCode?: string){ super(m); this.status = status;
    const ours = sqlCode(m) !== 'confirm_failed';
    this.definite = ours && ((status >= 400 && status < 500) || /^[0-9A-Z]{5}$/.test(String(pgCode || ''))); } }
async function sbRpc(fn: string, args: unknown){
  let r: Response;
  try { r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: SB_H(), body: JSON.stringify(args) }); }
  catch(e){ throw new RpcError('network ' + String((e as Error)?.message || e).slice(0, 120), 0); }
  const b = await r.json().catch(() => null);
  if(!r.ok) throw new RpcError(String((b && (b.message || b.hint)) || ('rpc ' + fn + ' ' + r.status)), r.status, b && b.code);
  return b;
}
const isDefinite = (e: unknown) => !!(e && (e as RpcError).definite);
// 서버 호출(정리 크론 · DB 의 pg_net)인가 — 토큰의 role 클레임이 service_role. 서명은 게이트웨이(verify_jwt=true)가 이미 확인했다(send-push 와 같은 방식)
function isServiceToken(t: string): boolean {
  try { const p = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); return p && p.role === 'service_role'; } catch(_e){ return false; }
}
async function caller(req: Request): Promise<{ id: string; email: string; role: string } | null>{
  const h = req.headers.get('Authorization') || ''; const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  if(!t) return null;
  if(isServiceToken(t)) return { id: '', email: '', role: 'service' };
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
    [/RATE_LIMITED/, 'rate_limited'], [/ROUND_CLOSED/, 'round_closed'],
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
  try {
    const r = await fetch(TOSS + path, { method, headers: h, body: body ? JSON.stringify(body) : undefined });
    const j = await r.json().catch(() => ({}));
    return { ok: r.ok, status: r.status, body: j as Record<string, any> };
  } catch(_e){ return { ok: false, status: 0, body: { code: 'NETWORK_ERROR' } as Record<string, any> }; }   // 네트워크 — 애매(승인됐을 수 있다)
}
// 토스 승인 실패가 「다시 해 볼 일」인가(승인이 실제로 됐을 수 있다) — 분명한 거절(카드 거절·한도 등 4xx)만 실패로 굳힌다
const TOSS_RETRY = /^(ALREADY_PROCESSED_PAYMENT|PROVIDER_ERROR|FAILED_INTERNAL_SYSTEM_PROCESSING|FAILED_PAYMENT_INTERNAL_SYSTEM_PROCESSING|UNKNOWN_PAYMENT_ERROR|NETWORK_ERROR|IDEMPOTENT_REQUEST_PROCESSING)$/;
const tossAmbiguous = (t: { ok: boolean; status: number; body: Record<string, any> }) =>
  t.status === 0 || t.status >= 500 || t.status === 409 || TOSS_RETRY.test(String(t.body?.code || '')) || (t.ok && t.body?.status !== 'DONE');
// 애매하면 결제를 조회해 본다 — 이 주문의 DONE 결제면 그 응답으로 잇는다
async function tossLookup(secret: string, paymentKey: string, orderId: string){
  const g = paymentKey ? await tossCall(secret, `/v1/payments/${encodeURIComponent(paymentKey)}`, 'GET')
                       : await tossCall(secret, `/v1/payments/orders/${encodeURIComponent(orderId)}`, 'GET');
  if(g.ok && g.body?.status === 'DONE' && String(g.body?.orderId || '') === orderId) return { done: true, body: g.body };
  // 결제가 없다(404) · 취소·실패 상태 — 분명히 승인 안 됨
  const gone = g.status === 404 || (g.ok && /^(CANCELED|ABORTED|EXPIRED)$/.test(String(g.body?.status || '')));
  return { done: false, gone, body: g.body };
}
async function tossCancelAll(secret: string, paymentKey: string, reason: string): Promise<boolean>{
  if(!paymentKey) return false;
  try {
    const r = await tossCall(secret, `/v1/payments/${encodeURIComponent(paymentKey)}/cancel`, 'POST', { cancelReason: reason }, `taam-cancel-${paymentKey}`);
    return r.ok || String(r.body?.code || '') === 'ALREADY_CANCELED_PAYMENT';
  } catch(_e){ return false; }
}
// 승인을 취소하고 주문을 닫는다 — 취소가 안 되면 슈퍼어드민 알림(모든 갈래 공통)
async function cancelOrAlert(secret: string, paymentKey: string, order: Record<string, any>, reason: string, code: string): Promise<boolean>{
  const canceled = await tossCancelAll(secret, paymentKey, reason);
  // 취소 못 했으면 상태는 그대로(pending → paid 는 pkg_claim 없이 DB 가 거절한다) · 사유만
  await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=in.(pending,paid)`,
    canceled ? { status: 'canceled', fail_reason: code + '_refunded' } : { fail_reason: code + '_refund_failed' }).catch(() => null);
  if(!canceled) await notifyAdmin(order, code, 'cancel_failed').catch(() => {});
  return canceled;
}
// 묶음이 이 주문으로 이미 확정됐나(그 뒤 취소됐어도) — 그렇다면 승인 취소는 절대 하지 않는다
async function groupSettledBy(gid: string, orderId: string): Promise<string | null>{
  if(!gid) return null;
  const g = await sbGet(`ticket_package_orders?id=eq.${encodeURIComponent(gid)}&select=status,order_id`);
  if(g === null) return 'unknown';
  const r = g[0];
  return r && (r.status === 'paid' || r.status === 'cancelled') && r.order_id === orderId ? String(r.status) : null;
}
// 알림이 함수 끝에 잘리지 않게 — 런타임이 주면 waitUntil, 아니면 기다린다
async function background(p: Promise<unknown>){
  const er = (globalThis as any).EdgeRuntime;
  if(er && typeof er.waitUntil === 'function'){ try { er.waitUntil(p.catch(() => {})); return; } catch(_e){ /* 아래 */ } }
  await p.catch(() => {});
}
const secretFor = (paidVia: string) => paidVia === 'billing_key'
  ? (Deno.env.get('TOSS_BILLING_SECRET_KEY') || Deno.env.get('TOSS_SECRET_KEY') || '')
  : (Deno.env.get('TOSS_SECRET_KEY') || '');

// ── 확정 — 주문이 paid 가 된 뒤. 분명한 거절이면 전액 취소 + 묶음 실패 · 애매하면 취소하지 않는다 ──
async function finalize(order: Record<string, any>, paymentKey: string, secret: string, buyer: { id: string; email: string }){
  const gid = String(order.metadata?.group_id || '');
  const okRes = (res: Record<string, any>) => json({ ok: true, already: !!res?.already, group_id: gid, total: res?.total, card_paid: res?.card_paid, deposit_used: res?.deposit_used,
                  rows: (res?.rows || []).map((r: any) => ({ purchase_id: r.purchase_id, rest_name: r.rest_name, date: r.date, time: r.time })) });
  let lastErr: unknown = null;
  for(let i = 0; i < 2; i++){
    try {
      const res = await sbRpc('taam_package_confirm_card', { p_order: order.order_id });
      await background(notifyAll(order, res, buyer));
      return okRes(res);
    } catch(e){
      lastErr = e;
      if(isDefinite(e)) break;
      // 애매 — 확정이 실제로 됐는지 묶음을 읽어 본다
      const st = await groupSettledBy(gid, order.order_id);
      if(st === 'paid' || st === 'cancelled') return okRes({ already: true });
    }
  }
  const msg = String((lastErr as Error)?.message || lastErr);
  const code = sqlCode(msg);
  if(!isDefinite(lastErr)){
    console.warn('[toss-package-pay] 확정 애매 — 취소하지 않음', order.order_id, msg.slice(0, 160));
    await markUnknown(order, 'paid', 'confirm_unknown');
    return json({ ok: false, error: 'confirm_pending', retry: true, paid: true, orderId: order.order_id });
  }
  // 분명한 거절 — **먼저 주문을 닫고**(서버가 주문을 잠근 채 묶음이 이 주문으로 확정됐는지 본다) 닫혔을 때만 승인을 취소한다.
  //   닫기 전에 취소하면 그 사이 다른 호출(resume · 정리 크론)이 확정해 좌석은 살고 카드는 환불되는 경주가 있었다(2차 검증)
  let cl: Record<string, any> | null = null;
  try { cl = await sbRpc('taam_package_order_close', { p_order: order.order_id, p_reason: code }); } catch(_ce){ cl = null; }
  if(!cl){
    await markUnknown(order, 'paid', code + '_close_failed');
    return json({ ok: false, error: 'confirm_pending', retry: true, paid: true, orderId: order.order_id });
  }
  if(cl.settled) return okRes({ already: true });
  if(!cl.closed) return json({ ok: false, error: code, refunded: cl.status === 'canceled' ? true : null, orderId: order.order_id });   // 다른 호출이 이미 닫았다
  console.warn('[toss-package-pay] 확정 거절 — 주문 닫고 승인 취소', order.order_id, msg.slice(0, 160));
  const canceled = await tossCancelAll(secret, paymentKey, code === 'deposit_short' ? '예치금 부족으로 구매 불가' : '좌석·패키지 변동으로 구매 불가');
  await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=eq.canceled`, { fail_reason: code + (canceled ? '_refunded' : '_refund_failed') }).catch(() => null);
  if(!canceled) await notifyAdmin(order, code, 'cancel_failed').catch(() => {});   // 정리 크론이 같은 키로 다시 취소한다
  if(gid && code !== 'superseded') { try { await sbRpc('taam_package_fail', { p_group: gid, p_reason: code }); } catch(_fe){ /* 홀드는 5분 뒤 풀린다 */ } }
  return json({ ok: false, error: code, refunded: canceled, orderId: order.order_id });
}
// 결과를 모르는 주문 — 한 번만 알린다(사유 칸에 표시 · 앱 재시도·정리 크론이 같은 주문을 여러 번 본다)
async function markUnknown(order: Record<string, any>, status: string, code: string){
  if(String(order.fail_reason || '') === 'unknown:' + code) return;
  await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=eq.${status}`, { fail_reason: 'unknown:' + code }).catch(() => null);
  order.fail_reason = 'unknown:' + code;
  await notifyAdmin(order, code, 'pending').catch(() => {});
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
// 슈퍼어드민 알림 — cancel_failed: 자동 취소 실패(상점관리자에서 취소) · pending: 승인은 됐는데 확정 여부를 모름(확인)
async function notifyAdmin(order: Record<string, any>, code: string, kind: 'cancel_failed' | 'pending'){
  const sups = await sbGet(`profiles?role=in.(superadmin,super_admin)&select=id`) || [];
  const amt = '₩' + Number(order.amount || 0).toLocaleString();
  const title = kind === 'cancel_failed' ? '⚠ 패키지 카드 결제 자동 취소 실패 — 상점관리자 확인 필요' : '⚠ 패키지 카드 결제 확정 보류 — 확인 필요';
  const body = kind === 'cancel_failed'
    ? '주문 ' + order.order_id + ' · ' + amt + ' · 사유 ' + code + ' — 좌석은 확정되지 않았습니다. 토스 상점관리자에서 승인취소해 주세요.'
    : '주문 ' + order.order_id + ' · ' + amt + ' · ' + code + ' — 카드가 승인됐을 수 있는데 좌석 확정 결과를 모릅니다. 서버가 10분마다 다시 확인해 확정하거나(좌석이 살아 있으면) 승인을 취소합니다 — 바로 확인하려면 패키지 관리 「구매자」의 「🔄 카드 결제 확인」.';
  if(sups.length) await sbInsert('notifications', sups.map((p: any) => ({ user_id: p.id, type: 'seat_hold_convert_failed', title, body, url: '/',
    payload: { order_id: order.order_id, package_order: order.metadata?.group_id, actor_id: order.user_id, via: 'toss-package-pay', kind } })));
}
// 승인된 결제로 주문을 paid 로 잡는다(서버 한 문장 · metadata 합침) — 결과: claimed | 지금 상태 | 애매
async function claimOrder(orderId: string, paymentKey: string, t: Record<string, any>, paidVia: string, billingKeyId?: string){
  for(let i = 0; i < 2; i++){
    try {
      const r = await sbRpc('taam_package_order_claim', { p_order: orderId, p_payment_key: paymentKey, p_method: t.method || (paidVia === 'billing_key' ? 'billing' : null),
        p_receipt: t.receipt?.url || null, p_approved_at: t.approvedAt || new Date().toISOString(), p_toss: pickToss(t), p_paid_via: paidVia,
        p_billing_key_id: billingKeyId || null });
      return { claimed: !!r?.claimed, status: String(r?.status || '') };
    } catch(e){ if(isDefinite(e)) return { claimed: false, status: 'error' }; }
  }
  // 두 번 다 애매 — 주문을 읽어 본다(잡혔으면 paid)
  const o = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=status,payment_key`);
  if(o && o[0]) return { claimed: o[0].status === 'paid' && o[0].payment_key === paymentKey, status: String(o[0].status) };
  return { claimed: false, status: 'unknown' };
}
// 승인은 됐다 — 주문을 잡고 확정. 주문이 이미 다른 상태(새 주문으로 대체 등)면 이 승인을 취소한다
async function afterApproved(order: Record<string, any>, t: Record<string, any>, paymentKey: string, secret: string, paidVia: string, me: { id: string; email: string }, billingKeyId?: string){
  const c = await claimOrder(order.order_id, paymentKey, t, paidVia, billingKeyId);
  if(c.claimed || c.status === 'paid'){
    const again = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&select=*`);
    const cur = (again && again[0]) || { ...order, status: 'paid', payment_key: paymentKey };
    if(cur.payment_key && cur.payment_key !== paymentKey){
      // 같은 주문에 다른 결제가 먼저 잡혔다 — 이 승인은 취소
      const canceled = await cancelOrAlert(secret, paymentKey, { ...order, order_id: order.order_id }, '중복 결제', 'duplicate_payment');
      return json({ ok: false, error: 'superseded', refunded: canceled });
    }
    return await finalize(cur, paymentKey, secret, me);
  }
  if(c.status === 'pending'){
    // 잡기가 애매했고 주문은 아직 pending — 먼저 주문을 닫아(pending → failed) 다시는 잡히지 않게 한 뒤에만 승인을 취소한다.
    //   닫기 전에 취소하면, 늦게 커밋된 잡기로 주문이 paid 가 되고 다음 confirm 이 취소된 카드로 좌석을 확정할 수 있다
    const cl = await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=eq.pending`, { status: 'failed', fail_reason: 'claim_failed' }).catch(() => null);
    if(cl && cl.ok && cl.rows.length){
      const canceled = await cancelOrAlert(secret, paymentKey, order, '결제 기록 실패', 'claim_failed');
      try { await sbRpc('taam_package_fail', { p_group: String(order.metadata?.group_id || ''), p_reason: 'claim_failed' }); } catch(_e){ /* 5분 뒤 풀린다 */ }
      return json({ ok: false, error: 'claim_failed', refunded: canceled });
    }
    const again = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&select=*`);
    if(again && again[0] && again[0].status === 'paid' && again[0].payment_key === paymentKey) return await finalize(again[0], paymentKey, secret, me);
    c.status = 'unknown';
  }
  if(c.status === 'unknown' || c.status === 'error'){
    await markUnknown(order, 'pending', 'claim_unknown');
    return json({ ok: false, error: 'confirm_pending', retry: true, paid: true, orderId: order.order_id });
  }
  // pending 이 아니다(대체됨 · 실패 · 취소) — 이 승인은 확정하지 않고 취소
  const canceled = await cancelOrAlert(secret, paymentKey, order, '주문 상태 변경', 'superseded');
  return json({ ok: false, error: 'superseded', refunded: canceled });
}

// pending 주문 — 토스에 주문 번호로 조회(두 MID). DONE 이면 잡고 확정 · 어디에도 없으면 not_paid · 모르면 retry
async function reconcilePending(order: Record<string, any>, buyer: { id: string; email: string }){
  let unknown = false; const tried: string[] = [];
  for(const v of ['billing_key', 'window']){
    const sec = secretFor(v); if(!sec || tried.indexOf(sec) >= 0) continue; tried.push(sec);
    const lk = await tossLookup(sec, '', String(order.order_id));
    if(lk.done){
      const approved = Number(lk.body.totalAmount ?? lk.body.balanceAmount ?? 0);
      if(approved !== Number(order.amount)){
        const canceled = await cancelOrAlert(sec, String(lk.body.paymentKey || ''), order, '금액 불일치', 'amount_mismatch_toss:' + approved);
        return json({ ok: false, error: 'amount_mismatch_toss', refunded: canceled });
      }
      return await afterApproved(order, lk.body, String(lk.body.paymentKey || ''), sec, v, buyer);
    }
    if(!lk.gone) unknown = true;
  }
  return unknown ? json({ ok: false, error: 'confirm_retry', retry: true }) : json({ ok: false, error: 'not_paid' });
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
    if(me.role === 'service' && action !== 'sweep') return json({ ok: false, error: 'forbidden' }, 403);
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
      let t = await tossCall(secret, '/v1/payments/confirm', 'POST', { paymentKey, orderId, amount: expected }, `taam-confirm-${orderId}`);
      if(!t.ok || t.body?.status !== 'DONE'){
        if(tossAmbiguous(t)){
          // 승인이 실제로 됐을 수 있다 — 조회해서 DONE 이면 잇고, 아니면 실패로 굳히지 않고 다시 해 보게
          const lk = await tossLookup(secret, paymentKey, orderId);
          if(!lk.done){
            if(!lk.gone){
              // 승인이 됐을 수 있다 — 슈퍼어드민에게 한 번 알리고(정리 크론이 10분 뒤 주문 번호로 다시 조회한다) 다시 해 보게
              await markUnknown(order, 'pending', 'toss_confirm_' + String(t.body?.code || t.status).slice(0, 40));
              return json({ ok: false, error: 'confirm_retry', retry: true, reason: String(t.body?.code || ('http_' + t.status)).slice(0, 80) });
            }
          } else t = { ok: true, status: 200, body: lk.body };
        }
        if(!t.ok || t.body?.status !== 'DONE'){
          const reason = String(t.body?.message || t.body?.code || ('http_' + t.status)).slice(0, 300);
          await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: reason });
          try { await sbRpc('taam_package_fail', { p_group: String(order.metadata?.group_id || ''), p_reason: 'confirm_failed' }); } catch(_e){ /* 5분 뒤 풀린다 */ }
          return json({ ok: false, error: 'confirm_failed', reason });
        }
      }
      const approved = Number(t.body.totalAmount ?? t.body.balanceAmount ?? 0);
      if(approved !== expected){
        const canceled = await cancelOrAlert(secret, paymentKey, order, '금액 불일치', 'amount_mismatch_toss:' + approved);
        return json({ ok: false, error: 'amount_mismatch_toss', refunded: canceled });
      }
      return await afterApproved(order, t.body, paymentKey, secret, 'window', me);
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
      const order = { order_id: orderId, user_id: me.id, amount, metadata: { group_id: gid, title: d.title, pax: d.pax } };
      const charge = () => tossCall(secret, `/v1/billing/${encodeURIComponent(card.billing_key)}`, 'POST',
        { customerKey: me.id, amount, orderId, orderName: ('[TAAM] 패키지 ' + String(d.title || '')).slice(0, 100), customerEmail: me.email || undefined },
        `taam-billing-${orderId}`);
      let t = await charge();
      if(!t.ok || t.body?.status !== 'DONE'){
        if(tossAmbiguous(t)){
          // 같은 멱등 키로 한 번 더 → 그래도 모르면 주문 번호로 조회. 승인이 됐을 수 있으니 새 주문으로 다시 긁지 않는다
          const t2 = await charge();
          if(t2.ok && t2.body?.status === 'DONE') t = t2;
          else {
            const lk = await tossLookup(secret, '', orderId);
            if(lk.done) t = { ok: true, status: 200, body: lk.body };
            else if(!lk.gone){
              await markUnknown(order, 'pending', 'billing_' + String(t.body?.code || t.status).slice(0, 40));
              return json({ ok: false, error: 'charge_unknown', retry: false, orderId });
            }
          }
        }
        if(!t.ok || t.body?.status !== 'DONE'){
          const reason = String(t.body?.message || t.body?.code || ('http_' + t.status)).slice(0, 300);
          await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: reason });
          return json({ ok: false, error: 'charge_failed', reason: reason.slice(0, 200) });
        }
      }
      const pk = String(t.body.paymentKey || '');
      const approved = Number(t.body.totalAmount ?? t.body.balanceAmount ?? 0);
      if(approved !== amount){
        const canceled = await cancelOrAlert(secret, pk, order, '금액 불일치', 'amount_mismatch_toss:' + approved);
        return json({ ok: false, error: 'amount_mismatch_toss', refunded: canceled });
      }
      return await afterApproved(order, t.body, pk, secret, 'billing_key', me, card.id);
    }

    // resume — 회원 · {group_id} · 등록 카드 결제가 애매하게 끝났을 때(charge_unknown) 앱이 다시 부른다:
    //   이 묶음의 마지막 카드 주문을 읽어 paid 면 확정부터, pending 이면 토스에 주문 번호로 조회해 DONE 이면 잇는다(새로 긁지 않는다)
    if(action === 'resume'){
      if(!gid) return json({ ok: false, error: 'bad_group' });
      const own = isSuper(me.role) ? '' : `&user_id=eq.${encodeURIComponent(me.id)}`;   // 슈퍼어드민은 회원의 묶음도(「카드 결제 확인」)
      const rows = await sbGet(`payment_orders?purpose=eq.package_topup${own}&metadata->>group_id=eq.${encodeURIComponent(gid)}&select=*&order=created_at.desc&limit=1`);
      if(rows === null) return json({ ok: false, error: 'order_lookup_failed', retry: true });
      const order = rows[0];
      if(!order) return json({ ok: false, error: 'order_not_found' });
      const via = String(order.metadata?.paid_via || '');
      const buyer = order.user_id === me.id ? me : { id: String(order.user_id), email: '' };   // 슈퍼어드민이 회원 대신 확인
      if(order.status === 'paid') return await finalize(order, String(order.payment_key || ''), secretFor(via), buyer);
      if(order.status !== 'pending') return json({ ok: false, error: 'order_not_pending', status: order.status });
      return await reconcilePending(order, buyer);
    }

    // sweep — 서버만(정리 크론 taam_package_reconcile_kick) · 결과를 모르는 주문을 정리한다(목록은 서버 함수가 고른다)
    if(action === 'sweep'){
      if(me.role !== 'service') return json({ ok: false, error: 'forbidden' }, 403);
      let list: any[] = [];
      try { list = (await sbRpc('taam_package_reconcile_list', { p_limit: 15 })) || []; } catch(_le){ return json({ ok: false, error: 'list_failed' }); }
      const out = { n: 0, confirmed: 0, cancelled: 0, retried: 0, expired: 0, left: 0 };
      for(const o of list){
        out.n++;
        const buyer = { id: String(o.user_id || ''), email: '' };
        const via = String(o.metadata?.paid_via || '');
        try {
          if(o.reconcile === 'cancel'){
            // 취소 실패 · 취소 도중 끊김 — 같은 멱등 키로 다시
            const base = String(o.fail_reason || '').replace(/_(refund_failed|canceling)$/, '');
            const ok = await tossCancelAll(secretFor(via), String(o.payment_key || ''), '패키지 결제 정리');
            if(ok){ await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(o.order_id)}&status=eq.canceled`, { fail_reason: base + '_refunded' }).catch(() => null); out.retried++; }
            else {
              if(/_canceling$/.test(String(o.fail_reason || ''))){
                await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(o.order_id)}&status=eq.canceled`, { fail_reason: base + '_refund_failed' }).catch(() => null);
                await notifyAdmin(o, base, 'cancel_failed').catch(() => {});
              }
              out.left++;
            }
            continue;
          }
          const r = o.reconcile === 'confirm' ? await finalize(o, String(o.payment_key || ''), secretFor(via), buyer) : await reconcilePending(o, buyer);
          const b = await r.json();
          if(b.ok) out.confirmed++;
          else if(b.refunded) out.cancelled++;
          else if(b.error === 'not_paid'){
            // 토스에 그 주문의 승인이 없다 — 결제창을 닫았거나 등록 카드 청구가 안 됐다. 실패로 닫는다(다시 조회하지 않게)
            await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(o.order_id)}&status=eq.pending`, { status: 'failed', fail_reason: 'expired' }).catch(() => null);
            out.expired++;
          } else {
            if(o.reconcile === 'lookup' && Date.now() - Date.parse(String(o.created_at)) > 3600e3) await markUnknown(o, 'pending', 'sweep_unknown');
            out.left++;
          }
        } catch(_se){ out.left++; }
      }
      return json({ ok: true, ...out });
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
