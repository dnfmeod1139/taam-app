// ═════════════════════════════════════════════════
// toss-invite-pay — 예약 초대의 「예치금 + 카드」 결제에서 카드 몫 주문 · 승인 · 확정 · 2026-11-13
// ═════════════════════════════════════════════════
// 왜 새 함수인가: 초대 결제(riConfirmPay)는 예치금 전용이었다 — 잔액이 모자라면 계좌이체 안내뿐. 회원이 「예치금을 쓰고 모자란 만큼만 카드로」
//   내려면 카드 승인과 「예치금 차감 · 초대 결제됨 · 좌석 확정」이 한 덩어리로 묶여야 한다. 돈·좌석 판단은 전부 서버 함수
//   (20261113_invite_card_pay.sql)가 **한 트랜잭션**으로 하고, 이 함수는 토스와 이야기하는 일만 한다. 틀은 toss-package-pay 와 같다.
//   옛 toss-order / toss-confirm 은 저장소 판을 대시보드 판과 대조한 적이 없어 손대지 않는다.
// 동작(action):
//   order   — 회원 · {invite_id} → taam_invite_order_prepare(초대·홀드·금액을 서버가 다시 본다 · 예치금 먼저 · 카드 몫만 주문 · 좌석 확정을 미리 한 번 돌려 본다)
//             → {orderId, amount} · 결제창은 앱이 이 orderId/amount 로 연다(successUrl ?toss_pay=success → 앱이 action confirm 으로)
//   confirm — 회원 · {orderId, paymentKey, amount} → 주문(invite_topup · 본인 · pending) → 토스 승인(TOSS_SECRET_KEY) → 주문 paid → 확정
//   resume  — 회원(자기 초대) · 슈퍼어드민(누구든) · {invite_id} → 그 초대의 마지막 카드 주문: paid 면 확정부터 · pending 이면 토스에 주문 번호로 조회(새로 긁지 않는다)
//   sweep   — 서버만(service_role · 정리 크론 taam_invite_pay_reconcile_kick 10분) → 확정 안 된 paid · 승인 요청이 나간 pending(3분↑) ·
//             표시 없는 pending(40분↑) · 취소 실패 · 닫힌(failed) 주문에 남은 승인(orphan — 토스에 조회해 DONE 이면 취소)을 정리
// 확정 = taam_invite_confirm_card(주문) — 예치금 차감(원장) · 초대 「결제됨」 · 초대 홀드(INVH-) → 회원 소유 확정 좌석(INV-) · 결제 사실 칸을 한 트랜잭션으로.
//   서버가 **분명히** 거절하면(DB 가 오류를 돌려줬다 = 롤백됐다 — 초대 취소·만료 · 예치금 변동 · 좌석 홀드 없음 · 중복·시간대) 주문을 닫고 토스 승인을 **전액 취소**
//   (Idempotency-Key taam-cancel-<paymentKey>). 초대 홀드는 건드리지 않는다(초대는 「보냄」 그대로 — 다시 결제할 수 있다).
//   ⚠ 애매한 실패(네트워크 · 게이트웨이 5xx — DB 오류 코드가 없다)에는 취소하지 않는다 — 확정이 실제로는 됐을 수 있다. 주문을 다시 읽고 · 한 번 더 부르고 ·
//   그래도 모르면 주문은 paid 로 두고 {retry:true} + 슈퍼어드민 알림. 정리 크론이 10분마다 다시 확정한다(확정은 멱등 · 취소 키도 같다).
//   취소하기 전에는 주문을 닫는다(taam_invite_order_close — 주문 줄을 잠그고 이 주문으로 이미 확정됐으면 닫지 않는다) — 닫기 전에 취소하면 그 사이 다른 호출이 확정한다.
// 토스 승인 응답이 애매하면(5xx · 409 · ALREADY_PROCESSED · 처리 중 · 네트워크) 주문을 실패로 만들지 않는다 — 결제를 조회해 DONE 이면 잇고, 아니면 {retry:true}.
// 토스 응답 원문은 저장하지 않는다(secret 칸) — 고른 칸만.
// 주문을 paid 로 잡을 때 metadata.inv_claim = 'toss-invite-pay' 를 적는다 — DB 가 이 표시 없는 초대 주문의 paid 를 거절한다
//   (옛 toss-confirm 이 초대 주문번호로 불려도 좌석 없이 paid 로 끝나지 않게).
// 환불: 이 함수에 없다 — 확정된 초대 좌석(INV-)은 다른 카드+예치금 구매와 같은 모양(extra_data.order_id · cardPaid · depositUsed)이라
//   회원 취소 → 카드 환불 대기 → 슈퍼어드민 「💳 토스 승인취소 실행」(toss-card-refund · taam_card_refund_quote)이 그대로 돈다.
// 오류는 HTTP 200 + {ok:false, error} (앱이 사유를 읽는다) — 인증만 401/403.
// 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY · TOSS_SECRET_KEY
// ═════════════════════════════════════════════════
const VER = 'tip-2026-11-13b';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
function json(b: unknown, s = 200){ return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
const SB_H = () => ({ apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' });
const TOSS = 'https://api.tosspayments.com';
const PURPOSE = 'invite_topup';

async function sbGet(path: string){ const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: SB_H() }); return r.ok ? await r.json().catch(() => []) : null; }
async function sbPatch(path: string, body: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'PATCH', headers: { ...SB_H(), Prefer: 'return=representation' }, body: JSON.stringify(body) });
  const b = await r.json().catch(() => null); return { ok: r.ok, rows: Array.isArray(b) ? b : [], status: r.status };
}
async function sbInsert(path: string, rows: unknown){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'POST', headers: { ...SB_H(), Prefer: 'return=minimal' }, body: JSON.stringify(rows) });
  return r.ok;
}
// 서버 함수 오류 → 앱 코드
function sqlCode(m: string): string {
  const map: [RegExp, string][] = [
    [/HOLD_GONE/, 'hold_gone'], [/INVITE_PAID/, 'invite_paid'], [/INVITE_EXPIRED/, 'invite_expired'], [/INVITE_NOT_LINKED/, 'not_linked'],
    [/INVITE_DEPOSIT_PAID/, 'deposit_inflight'],
    [/INVITE_CLOSED|INVITE_NOT_FOUND|INVITE_NOT_PAID/, 'invite_closed'],
    [/INSUFFICIENT_DEPOSIT|LEDGER_INSUFFICIENT/, 'deposit_short'], [/PRICE_CHANGED|PRICE_NOT_SET/, 'price_changed'],
    [/ORDER_SUPERSEDED/, 'superseded'], [/ORDER_NOT_PAID|ORDER_NOT_FOUND/, 'order_not_found'],
    [/DUPLICATE_PURCHASE/, 'dup'], [/TIME_CONFLICT/, 'clash'],
    [/TICKET_NOT_OPEN|TICKET_NOT_APPROVED|PACKAGE_|ROUND_CLOSED/, 'round_closed'],
    [/RATE_LIMITED/, 'rate_limited'], [/PAYMENT_PENDING/, 'payment_pending'], [/FORBIDDEN|내 초대가 아닙니다/, 'forbidden'],
  ];
  for(const [re, c] of map) if(re.test(m)) return c;
  return 'confirm_failed';
}
// 실패는 {status, pgCode, ours} 를 단 Error.
//   db   = 본문에 SQLSTATE(5글자)가 있다 = DB 가 그 문장을 거절했다(트랜잭션은 롤백됐다 · 확정은 분명히 안 됐다).
//          ⚠ HTTP 상태로 가르지 않는다 — PostgREST 는 P0001 만 400 이고 그 밖의 P0*·22*·42* 일부를 500 으로 보낸다.
//   ours = 우리 서버 함수가 우리 코드로 거절했다(다시 불러도 같다). db 인데 ours 가 아니면(교착 · 시간 초과 · 모르는 트리거) 한 번 더 불러 본다.
//   게이트웨이 5xx · 네트워크 · PGRST* 는 애매 — 확정이 됐을 수도 있다.
class RpcError extends Error { status: number; db: boolean; ours: boolean; pgCode: string;
  constructor(m: string, status: number, pgCode?: string){ super(m); this.status = status; this.pgCode = String(pgCode || '');
    this.db = /^[0-9A-Z]{5}$/.test(this.pgCode);
    this.ours = this.db && sqlCode(m) !== 'confirm_failed'; } }
async function sbRpc(fn: string, args: unknown){
  let r: Response;
  try { r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: SB_H(), body: JSON.stringify(args) }); }
  catch(e){ throw new RpcError('network ' + String((e as Error)?.message || e).slice(0, 120), 0); }
  const b = await r.json().catch(() => null);
  if(!r.ok) throw new RpcError(String((b && (b.message || b.hint)) || ('rpc ' + fn + ' ' + r.status)), r.status, b && b.code);
  return b;
}
const isDb = (e: unknown) => !!(e && (e as RpcError).db);
const isOurs = (e: unknown) => !!(e && (e as RpcError).ours);
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
const isUuid = (s: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);

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
  if(g.ok && g.body?.status === 'DONE' && String(g.body?.orderId || '') === orderId) return { done: true, gone: false, body: g.body };
  // 결제가 없다(404) · 취소·실패 상태 — 분명히 승인 안 됨
  const gone = g.status === 404 || (g.ok && /^(CANCELED|ABORTED|EXPIRED)$/.test(String(g.body?.status || '')));
  return { done: false, gone, body: g.body };
}
async function tossCancelAll(secret: string, paymentKey: string, reason: string): Promise<boolean>{
  if(!paymentKey || !secret) return false;
  try {
    const r = await tossCall(secret, `/v1/payments/${encodeURIComponent(paymentKey)}/cancel`, 'POST', { cancelReason: reason }, `taam-cancel-${paymentKey}`);
    return r.ok || String(r.body?.code || '') === 'ALREADY_CANCELED_PAYMENT';
  } catch(_e){ return false; }
}
// 승인을 취소하고 주문에 사유를 적는다 — 취소가 안 되면 슈퍼어드민 알림. (주문이 아직 pending 인 갈래 — paid 주문은 finalize 가 닫고 취소한다)
async function cancelOrAlert(secret: string, paymentKey: string, order: Record<string, any>, reason: string, code: string): Promise<boolean>{
  const canceled = await tossCancelAll(secret, paymentKey, reason);
  // 취소 못 했으면 상태는 그대로(pending → paid 는 inv_claim 없이 DB 가 거절한다) · 사유만
  await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=in.(pending,failed)`,
    canceled ? { status: 'canceled', fail_reason: code + '_refunded', payment_key: paymentKey } : { fail_reason: code + '_refund_failed', payment_key: paymentKey }).catch(() => null);
  if(!canceled) await notifyAdmin(order, code, 'cancel_failed').catch(() => {});
  return canceled;
}
// 이 주문으로 이미 확정됐나(그 뒤 좌석이 취소됐어도) — 그렇다면 승인 취소는 절대 하지 않는다. null = 아님 · 'unknown' = 못 읽음
async function settledBy(orderId: string): Promise<string | null>{
  const g = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=status,metadata`);
  if(g === null) return 'unknown';
  const r = g[0];
  return r && String(r.metadata?.inv_settled || '') === 'true' ? 'settled' : null;
}
// 확정 응답을 잃었을 때 — 주문 메타로 응답 모양을 다시 만든다(알림·앱 안내용)
function resFromOrder(order: Record<string, any>): Record<string, any>{
  const m = order.metadata || {};
  return { already: true, invite_id: m.invite_id, purchase_id: m.purchase_id, total: Number(m.total || 0), deposit_used: Number(m.deposit_used || 0),
           card_paid: Number(order.settle_krw ?? order.amount ?? 0), rest_name: m.restaurant_name, date: m.visit_date, time: m.visit_time, pax: Number(m.pax || 0) };
}
// 결제 완료 알림은 주문마다 한 번 — 서버가 「알렸다」 표시를 붙였을 때만 보낸다(확정 응답을 잃어 다음 호출이 「이미」로 와도 빠지지 않고, 겹친 호출이 두 번 보내지도 않는다)
async function notifyOnce(order: Record<string, any>, res: Record<string, any>, buyer: { id: string }){
  try {
    const first = await sbRpc('taam_invite_order_notified', { p_order: order.order_id });
    if(first === true) await notifyPaid(order, res, buyer);
  } catch(_e){ /* 알림은 부가 — 결제를 깨뜨리지 않는다 */ }
}
// 알림이 함수 끝에 잘리지 않게 — 런타임이 주면 waitUntil, 아니면 기다린다
async function background(p: Promise<unknown>){
  const er = (globalThis as any).EdgeRuntime;
  if(er && typeof er.waitUntil === 'function'){ try { er.waitUntil(p.catch(() => {})); return; } catch(_e){ /* 아래 */ } }
  await p.catch(() => {});
}
const tossSecret = () => Deno.env.get('TOSS_SECRET_KEY') || '';

// ── 확정 — 주문이 paid 가 된 뒤. 분명한 거절이면 주문을 닫고 전액 취소 · 애매하면 취소하지 않는다 ──
async function finalize(order: Record<string, any>, paymentKey: string, secret: string, buyer: { id: string; email: string }){
  const iid = String(order.metadata?.invite_id || '');
  const okRes = (res: Record<string, any>) => json({ ok: true, already: !!res?.already, invite_id: iid, purchase_id: res?.purchase_id || order.metadata?.purchase_id || null,
                  total: res?.total, card_paid: res?.card_paid, deposit_used: res?.deposit_used, rest_name: res?.rest_name, date: res?.date, time: res?.time, pax: res?.pax });
  let lastErr: unknown = null;
  for(let i = 0; i < 2; i++){
    try {
      const res = await sbRpc('taam_invite_confirm_card', { p_order: order.order_id });
      await background(notifyOnce(order, res, buyer));
      return okRes(res);
    } catch(e){
      lastErr = e;
      if(isOurs(e)) break;                                    // 우리 코드로 거절 — 다시 불러도 같다
      // 애매(네트워크·게이트웨이) 또는 모르는 DB 오류 — 확정이 실제로 됐는지 주문을 읽어 본다
      const st = await settledBy(order.order_id);
      if(st === 'settled'){ await background(notifyOnce(order, resFromOrder(order), buyer)); return okRes(resFromOrder(order)); }
    }
  }
  const msg = String((lastErr as Error)?.message || lastErr);
  const code = sqlCode(msg);
  if(!isDb(lastErr)){
    console.warn('[toss-invite-pay] 확정 애매 — 취소하지 않음', order.order_id, msg.slice(0, 160));
    await markUnknown(order, 'paid', 'confirm_unknown');
    return json({ ok: false, error: 'confirm_pending', retry: true, paid: true, orderId: order.order_id });
  }
  // 분명한 거절(DB 가 두 번 다 거절) — **먼저 주문을 닫고**(서버가 주문을 잠근 채 이 주문으로 확정됐는지 본다) 닫혔을 때만 승인을 취소한다
  let cl: Record<string, any> | null = null;
  try { cl = await sbRpc('taam_invite_order_close', { p_order: order.order_id, p_reason: code }); } catch(_ce){ cl = null; }
  if(!cl){
    await markUnknown(order, 'paid', code + '_close_failed');
    return json({ ok: false, error: 'confirm_pending', retry: true, paid: true, orderId: order.order_id });
  }
  if(cl.settled){ await background(notifyOnce(order, resFromOrder(order), buyer)); return okRes(resFromOrder(order)); }
  if(!cl.closed) return json({ ok: false, error: code, refunded: cl.status === 'canceled' ? true : null, orderId: order.order_id });   // 다른 호출이 이미 닫았다
  console.warn('[toss-invite-pay] 확정 거절 — 주문 닫고 승인 취소', order.order_id, msg.slice(0, 160));
  const canceled = await tossCancelAll(secret, paymentKey, code === 'deposit_short' ? '예치금 부족으로 예약 불가' : '초대·좌석 변동으로 예약 불가');
  await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=eq.canceled`, { fail_reason: code + (canceled ? '_refunded' : '_refund_failed') }).catch(() => null);
  if(!canceled) await notifyAdmin(order, code, 'cancel_failed').catch(() => {});   // 정리 크론이 같은 키로 다시 취소한다
  return json({ ok: false, error: code, refunded: canceled, orderId: order.order_id, detail: code === 'dup' || code === 'clash' ? msg.slice(0, 200) : undefined });
}
// 결과를 모르는 주문 — 한 번만 알린다(사유 칸에 표시 · 앱 재시도·정리 크론이 같은 주문을 여러 번 본다)
async function markUnknown(order: Record<string, any>, status: string, code: string){
  if(String(order.fail_reason || '') === 'unknown:' + code) return;
  await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=eq.${status}`, { fail_reason: 'unknown:' + code }).catch(() => null);
  order.fail_reason = 'unknown:' + code;
  await notifyAdmin(order, code, 'pending').catch(() => {});
}

// ── 알림 — 슈퍼어드민(벨 + 푸시) · 초대를 보낸 사람(슈퍼어드민이 아니면 벨) ──
async function notifyPaid(order: Record<string, any>, res: Record<string, any>, buyer: { id: string }){
  let who = '회원';
  try { const p = await sbGet(`profiles?id=eq.${encodeURIComponent(buyer.id)}&select=display_name,phone`); const d = p && p[0];
        if(d?.display_name && String(d.display_name).trim()) who = String(d.display_name).trim();
        else if(d?.phone) who = '회원 ' + String(d.phone).replace(/[^0-9]/g, '').slice(-4); } catch(_e){ /* 이름은 장식 */ }
  const won = (n: unknown) => '₩' + Number(n || 0).toLocaleString('en-US');
  const title = '💳 ' + who + '님이 초대 결제를 완료했습니다';
  const body = who + '님 · ' + String(res?.rest_name || '') + ' · ' + String(res?.date || '') + ' ' + String(res?.time || '') + ' · ' + Number(res?.pax || 0) + '인 · ' + won(res?.total)
             + '\n예치금 ' + won(res?.deposit_used) + ' + 카드 ' + won(res?.card_paid);
  const payload = { invite_id: res?.invite_id || order.metadata?.invite_id, paid_by: buyer.id, amount: res?.total, pax: res?.pax, visit_date: res?.date,
                    purchase_id: res?.purchase_id || null, card_paid: res?.card_paid, deposit_used: res?.deposit_used, order_id: order.order_id, via: 'toss-invite-pay' };
  try {
    const sups = await sbGet(`profiles?role=in.(superadmin,super_admin)&select=id`) || [];
    const ids = new Set<string>(sups.map((p: any) => String(p.id)));
    let host = String(res?.host_user_id || '');
    if(!host && payload.invite_id){   // 「이미」 응답에는 보낸 사람이 없을 수 있다
      const hv = await sbGet(`reservation_invites?id=eq.${encodeURIComponent(String(payload.invite_id))}&select=host_user_id`);
      host = String((hv && hv[0]?.host_user_id) || '');
    }
    const ins = sups.filter((p: any) => p.id !== buyer.id).map((p: any) => ({ user_id: p.id, type: 'invite_paid', title, body, url: '/', payload }));
    if(host && !ids.has(host) && host !== buyer.id) ins.push({ user_id: host, type: 'invite_paid', title, body: String(res?.rest_name || '') + ' · ' + String(res?.date || '') + ' ' + String(res?.time || '') + ' · ' + Number(res?.pax || 0) + '인', url: '/?sent_invites=1',
                                                              payload: { invite_id: payload.invite_id, paid_by: buyer.id, visit_date: res?.date, via: 'toss-invite-pay' } });
    if(ins.length) await sbInsert('notifications', ins);
  } catch(_e){ /* 벨은 부가 */ }
  for(const role of ['superadmin', 'super_admin']){
    try { await fetch(`${SUPABASE_URL}/functions/v1/send-push`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ to: 'role:' + role, payload: { title, body, url: '/', category: 'invite_paid', tag: 'taam-paid-' + String(payload.invite_id || '') } }) }); } catch(_e){ /* 다음 */ }
  }
}
// 슈퍼어드민 알림 — cancel_failed: 자동 취소 실패(상점관리자에서 취소) · pending: 승인은 됐는데 확정 여부를 모름(확인)
async function notifyAdmin(order: Record<string, any>, code: string, kind: 'cancel_failed' | 'pending'){
  const sups = await sbGet(`profiles?role=in.(superadmin,super_admin)&select=id`) || [];
  const amt = '₩' + Number(order.amount || 0).toLocaleString('en-US');
  const what = String(order.metadata?.title || '초대');
  const title = kind === 'cancel_failed' ? '⚠ 초대 카드 결제 자동 취소 실패 — 상점관리자 확인 필요' : '⚠ 초대 카드 결제 확정 보류 — 확인 필요';
  const body = kind === 'cancel_failed'
    ? what + ' · 주문 ' + order.order_id + ' · ' + amt + ' · 사유 ' + code + ' — 좌석은 확정되지 않았습니다. 토스 상점관리자에서 승인취소해 주세요.'
    : what + ' · 주문 ' + order.order_id + ' · ' + amt + ' · ' + code + ' — 카드가 승인됐을 수 있는데 초대 확정 결과를 모릅니다. 서버가 10분마다 다시 확인해 확정하거나(초대·좌석이 살아 있으면) 승인을 취소합니다.';
  if(sups.length) await sbInsert('notifications', sups.map((p: any) => ({ user_id: p.id, type: 'seat_hold_convert_failed', title, body, url: '/',
    payload: { order_id: order.order_id, invite_id: order.metadata?.invite_id, actor_id: order.user_id, via: 'toss-invite-pay', kind } })));
}
// 승인된 결제로 주문을 paid 로 잡는다(서버 한 문장 · metadata 합침) — 결과: claimed | 지금 상태 | 애매
async function claimOrder(orderId: string, paymentKey: string, t: Record<string, any>){
  for(let i = 0; i < 2; i++){
    try {
      const r = await sbRpc('taam_invite_order_claim', { p_order: orderId, p_payment_key: paymentKey, p_method: t.method || null,
        p_receipt: t.receipt?.url || null, p_approved_at: t.approvedAt || new Date().toISOString(), p_toss: pickToss(t) });
      return { claimed: !!r?.claimed, status: String(r?.status || '') };
    } catch(e){ if(isOurs(e)) return { claimed: false, status: 'error' }; }
  }
  // 두 번 다 애매 — 주문을 읽어 본다(잡혔으면 paid)
  const o = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=status,payment_key`);
  if(o && o[0]) return { claimed: o[0].status === 'paid' && o[0].payment_key === paymentKey, status: String(o[0].status) };
  return { claimed: false, status: 'unknown' };
}
// 승인은 됐다 — 주문을 잡고 확정. 주문이 이미 다른 상태(새 주문으로 대체 등)면 이 승인을 취소한다.
//   ⚠ paymentKey 는 언제나 **토스가 이 주문번호로 알려 준 결제키**다(회원이 보낸 값이 아니다 — 적대 리뷰: 회원이 다른 결제의 키를 보내 그 결제를 취소시킬 수 있었다).
async function afterApproved(order: Record<string, any>, t: Record<string, any>, paymentKey: string, secret: string, me: { id: string; email: string }){
  const c = await claimOrder(order.order_id, paymentKey, t);
  if(c.claimed || c.status === 'paid'){
    const again = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&select=*`);
    const cur = (again && again[0]) || { ...order, status: 'paid', payment_key: paymentKey };
    // 주문에 적힌 결제키로 확정한다 — 이 호출의 키와 다르더라도(있을 수 없는 일) 어느 결제도 여기서 취소하지 않는다
    return await finalize(cur, String(cur.payment_key || paymentKey), secret, me);
  }
  if(c.status === 'pending'){
    // 잡기가 애매했고 주문은 아직 pending — 먼저 주문을 닫아(pending → failed) 다시는 잡히지 않게 한 뒤에만 승인을 취소한다.
    //   닫기 전에 취소하면, 늦게 커밋된 잡기로 주문이 paid 가 되고 다음 confirm 이 취소된 카드로 좌석을 확정할 수 있다.
    //   결제키를 함께 적는다 — 취소가 실패하면 정리 크론이 닫힌 주문(orphan)을 토스에 조회해 다시 취소한다
    const cl = await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=eq.pending`, { status: 'failed', fail_reason: 'claim_failed', payment_key: paymentKey }).catch(() => null);
    if(cl && cl.ok && cl.rows.length){
      const canceled = await cancelOrAlert(secret, paymentKey, order, '결제 기록 실패', 'claim_failed');
      return json({ ok: false, error: 'claim_failed', refunded: canceled });
    }
    const again = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&select=*`);
    if(again && again[0] && again[0].status === 'paid') return await finalize(again[0], String(again[0].payment_key || paymentKey), secret, me);
    c.status = 'unknown';
  }
  if(c.status === 'unknown' || c.status === 'error'){
    await markUnknown(order, 'pending', 'claim_unknown');
    return json({ ok: false, error: 'confirm_pending', retry: true, paid: true, orderId: order.order_id });
  }
  // pending 이 아니다(대체됨 · 실패 · 취소) — 이 주문의 승인(토스가 알려 준 키)은 확정하지 않고 취소
  const canceled = await cancelOrAlert(secret, paymentKey, order, '주문 상태 변경', 'superseded');
  return json({ ok: false, error: 'superseded', refunded: canceled });
}

// pending 주문 — 토스에 주문 번호로 조회. DONE 이면 잡고 확정 · 없으면 not_paid · 모르면 retry
async function reconcilePending(order: Record<string, any>, buyer: { id: string; email: string }){
  const sec = tossSecret(); if(!sec) return json({ ok: false, error: 'server_not_configured' });
  const lk = await tossLookup(sec, '', String(order.order_id));
  if(lk.done){
    const approved = Number(lk.body.totalAmount ?? lk.body.balanceAmount ?? 0);
    if(approved !== Number(order.amount)){
      const canceled = await cancelOrAlert(sec, String(lk.body.paymentKey || ''), order, '금액 불일치', 'amount_mismatch_toss:' + approved);
      return json({ ok: false, error: 'amount_mismatch_toss', refunded: canceled });
    }
    return await afterApproved(order, lk.body, String(lk.body.paymentKey || ''), sec, buyer);
  }
  return lk.gone ? json({ ok: false, error: 'not_paid' }) : json({ ok: false, error: 'confirm_retry', retry: true });
}

async function handle(req: Request){
  if(req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const me = await caller(req);
  if(!me) return json({ ok: false, error: 'unauthorized' }, 401);
  try {
    const body = await req.json().catch(() => ({})) as Record<string, any>;
    const action = String(body.action || '');
    if(me.role === 'service' && action !== 'sweep') return json({ ok: false, error: 'forbidden' }, 403);
    const iid = String(body.invite_id || '');
    if(iid && !isUuid(iid)) return json({ ok: false, error: 'bad_invite' });

    if(action === 'order'){
      if(!iid) return json({ ok: false, error: 'bad_invite' });
      let d: Record<string, any>;
      try { d = await sbRpc('taam_invite_order_prepare', { p_invite: iid, p_uid: me.id }); }
      catch(e){ const m = String((e as Error).message || e); const c = sqlCode(m);
                return json({ ok: false, error: isDb(e) ? c : 'order_failed', retry: !isDb(e), detail: c === 'dup' || c === 'clash' ? m.slice(0, 200) : undefined }); }
      if(!d.need_payment) return json({ ok: true, need_payment: false, total: d.total, balance: d.balance });
      return json({ ok: true, need_payment: true, orderId: d.order_id, amount: d.amount, total: d.total, depositUsed: d.deposit_used, title: d.title, currency: 'KRW', ver: VER });
    }

    if(action === 'confirm'){
      const orderId = String(body.orderId || ''), paymentKey = String(body.paymentKey || ''), clientAmount = Number(body.amount || 0);
      if(!/^taaminv_[0-9_]+$/.test(orderId) || !paymentKey || paymentKey.length > 200) return json({ ok: false, error: 'missing_params' });
      const rows = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=*`);
      if(rows === null) return json({ ok: false, error: 'order_lookup_failed', retry: true });
      const order = rows[0];
      if(!order || order.purpose !== PURPOSE) return json({ ok: false, error: 'order_not_found' });
      if(order.user_id !== me.id) return json({ ok: false, error: 'order_forbidden' }, 403);
      if(String(order.currency || 'KRW').toUpperCase() !== 'KRW') return json({ ok: false, error: 'currency_not_supported' });
      const secret = tossSecret();
      if(!secret) return json({ ok: false, error: 'server_not_configured' });
      if(order.status === 'paid'){
        // 앞 호출이 승인 뒤에 끊겼다 — 확정부터 다시(멱등). 이미 확정이면 already.
        //   취소가 필요해지면 **주문에 적힌 결제키**(서버가 토스에서 받아 적은 값)만 쓴다 — 회원이 보낸 키는 쓰지 않는다
        return await finalize(order, String(order.payment_key || ''), secret, me);
      }
      if(order.status !== 'pending') return json({ ok: false, error: 'order_not_pending', status: order.status });
      const expected = Number(order.amount);
      if(clientAmount && clientAmount !== expected){
        await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: 'amount_mismatch_client' });
        return json({ ok: false, error: 'amount_mismatch' });
      }
      // 승인을 요청하기 **전에** 「결과 모름」 표시를 붙인다(적대 리뷰) — 이 뒤로는 주문 만들기가 이 주문을 덮어 닫지 못하고(PAYMENT_PENDING),
      //   승인 뒤에 기록이 끊겨도(Edge 가 죽음 · DB 를 못 씀) 정리 크론이 3분 뒤부터 토스에 주문번호로 조회해 잇거나 닫는다. 조용한 표시다(알림 없음).
      if(!String(order.fail_reason || '').startsWith('unknown:')){
        const mk = await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { fail_reason: 'unknown:approving' }).catch(() => null);
        if(!mk || !mk.ok) return json({ ok: false, error: 'order_lookup_failed', retry: true });
        if(!mk.rows.length){
          // 그 사이 상태가 바뀌었다(다른 호출이 잡았거나 닫았다)
          const ag = await sbGet(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&select=*`);
          const cur = ag && ag[0];
          if(cur && cur.status === 'paid') return await finalize(cur, String(cur.payment_key || ''), secret, me);
          return json({ ok: false, error: 'order_not_pending', status: cur ? cur.status : null });
        }
        order.fail_reason = 'unknown:approving';
      }
      // 멱등 키는 이 함수만의 것 — 옛 toss-confirm(taam-confirm-<주문>)이 같은 주문번호로 불렸어도 그 응답이 여기로 되돌아오지 않게
      let t = await tossCall(secret, '/v1/payments/confirm', 'POST', { paymentKey, orderId, amount: expected }, `taam-inv-confirm-${orderId}`);
      if(!t.ok || t.body?.status !== 'DONE'){
        if(tossAmbiguous(t)){
          // 승인이 실제로 됐을 수 있다 — 조회해서 DONE 이면 잇고, 아니면 실패로 굳히지 않고 다시 해 보게
          const lk = await tossLookup(secret, paymentKey, orderId);
          if(!lk.done){
            if(!lk.gone){
              // 겹친 호출(같은 멱등 키가 처리 중)은 알리지 않는다 — 앞 호출이 곧 끝낸다. 그 밖의 애매함은 슈퍼어드민에게 한 번 알린다
              if(String(t.body?.code || '') !== 'IDEMPOTENT_REQUEST_PROCESSING') await markUnknown(order, 'pending', 'toss_confirm_' + String(t.body?.code || t.status).slice(0, 40));
              return json({ ok: false, error: 'confirm_retry', retry: true, reason: String(t.body?.code || ('http_' + t.status)).slice(0, 80) });
            }
          } else t = { ok: true, status: 200, body: lk.body };
        }
        if(!t.ok || t.body?.status !== 'DONE'){
          const reason = String(t.body?.message || t.body?.code || ('http_' + t.status)).slice(0, 300);
          await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: reason });
          return json({ ok: false, error: 'confirm_failed', reason: reason.slice(0, 200) });
        }
      }
      // 토스가 알려 준 주문번호·결제키로만 움직인다 — 회원이 보낸 paymentKey 는 승인 요청에만 쓰고, 잡기·취소에는 토스의 값을 쓴다.
      //   (토스가 다른 주문의 결제를 돌려줬다면 아무것도 잡지도 취소하지도 않는다 — 정리 크론이 주문번호로 다시 본다)
      const tk = String(t.body.paymentKey || '');
      if(String(t.body.orderId || '') !== orderId || !tk){
        console.warn('[toss-invite-pay] 토스 응답의 주문·결제키가 요청과 다르다 — 손대지 않음', orderId);
        await markUnknown(order, 'pending', 'toss_payment_mismatch');
        return json({ ok: false, error: 'confirm_retry', retry: true, reason: 'payment_mismatch' });
      }
      const approved = Number(t.body.totalAmount ?? t.body.balanceAmount ?? 0);
      if(approved !== expected){
        const canceled = await cancelOrAlert(secret, tk, order, '금액 불일치', 'amount_mismatch_toss:' + approved);
        return json({ ok: false, error: 'amount_mismatch_toss', refunded: canceled });
      }
      return await afterApproved(order, t.body, tk, secret, me);
    }

    // resume — 회원 · {invite_id} · 결제 결과가 애매하게 끝났을 때 앱이 다시 부른다:
    //   이 초대의 마지막 카드 주문을 읽어 paid 면 확정부터, pending 이면 토스에 주문 번호로 조회해 DONE 이면 잇는다(새로 긁지 않는다)
    if(action === 'resume'){
      if(!iid) return json({ ok: false, error: 'bad_invite' });
      const own = isSuper(me.role) ? '' : `&user_id=eq.${encodeURIComponent(me.id)}`;   // 슈퍼어드민은 회원의 초대도
      const rows = await sbGet(`payment_orders?purpose=eq.${PURPOSE}${own}&metadata->>invite_id=eq.${encodeURIComponent(iid)}&status=in.(pending,paid)&select=*&order=created_at.desc&limit=1`);
      if(rows === null) return json({ ok: false, error: 'order_lookup_failed', retry: true });
      const order = rows[0];
      if(!order){
        // 살아 있는 주문이 없다 — 서버가 승인 뒤에 닫고 카드를 취소한 주문이 최근(6시간)에 있으면 그 결과를 알려 준다
        //   (회원이 「결제가 완료되지 않았어요」만 보고, 카드가 승인됐다 취소된(또는 취소가 밀린) 사실을 모른 채 다시 결제하지 않게)
        const since = new Date(Date.now() - 6 * 3600e3).toISOString();
        const cx = await sbGet(`payment_orders?purpose=eq.${PURPOSE}${own}&metadata->>invite_id=eq.${encodeURIComponent(iid)}&status=eq.canceled&created_at=gte.${encodeURIComponent(since)}&select=order_id,fail_reason&order=created_at.desc&limit=1`);
        const c0 = cx && cx[0];
        if(c0){
          const fr = String(c0.fail_reason || '');
          const base = fr.replace(/_(refunded|refund_failed|canceling)$/, '').replace(/:.*$/, '') || 'confirm_failed';
          return json({ ok: false, error: base, refunded: !/_(refund_failed|canceling)$/.test(fr), orderId: c0.order_id });
        }
        return json({ ok: false, error: 'order_not_found' });
      }
      const buyer = order.user_id === me.id ? me : { id: String(order.user_id), email: '' };   // 슈퍼어드민이 회원 대신 확인
      if(order.status === 'paid') return await finalize(order, String(order.payment_key || ''), tossSecret(), buyer);
      const rr = await reconcilePending(order, buyer);
      // 「결과 모름」 표시(unknown:)가 붙은 pending 주문에 토스 승인이 없다고 확인되면 닫는다 — 안 닫으면 새 주문이 PAYMENT_PENDING 으로 막힌다(정리 크론은 10분 뒤에야 본다).
      //   결제창 흐름에서 not_paid = 그 주문번호의 결제가 없거나(404) 취소·만료 상태 — 승인 처리 중이면 조회에 보이므로(gone 아님) 여기로 오지 않는다
      try {
        const b = await rr.clone().json();
        if(b && b.error === 'not_paid' && String(order.fail_reason || '').startsWith('unknown:')){
          await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(order.order_id)}&status=eq.pending`, { status: 'failed', fail_reason: 'expired' });
        }
      } catch(_e){ /* 그대로 */ }
      return rr;
    }

    // sweep — 서버만(정리 크론) · 결과를 모르는 주문을 정리한다(목록은 서버 함수가 고른다)
    if(action === 'sweep'){
      if(me.role !== 'service') return json({ ok: false, error: 'forbidden' }, 403);
      let list: any[] = [];
      try { list = (await sbRpc('taam_invite_pay_reconcile_list', { p_limit: 15 })) || []; } catch(_le){ return json({ ok: false, error: 'list_failed' }); }
      const out = { n: 0, confirmed: 0, cancelled: 0, retried: 0, expired: 0, left: 0, clean: 0 };
      for(const o of list){
        out.n++;
        const buyer = { id: String(o.user_id || ''), email: '' };
        try {
          if(o.reconcile === 'orphan'){
            // 닫힌(failed) 주문에 토스 승인이 남아 있나 — 주문번호로 조회해 DONE 이면 그 결제를 전액 취소한다
            //   (잡기 실패 뒤 취소가 실패했거나 · 옛 함수가 이 주문번호로 승인만 한 경우 — 좌석 없이 카드만 승인된 채 남지 않게)
            const lk = await tossLookup(tossSecret(), '', String(o.order_id));
            if(!lk.done){ out.clean++; continue; }
            const ok2 = String(lk.body.paymentKey || '');
            const base = String(o.fail_reason || 'failed').replace(/_(refund_failed|canceling|refunded)$/, '');
            const okc = await tossCancelAll(tossSecret(), ok2, '초대 결제 정리');
            if(okc){
              await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(o.order_id)}&status=eq.failed`, { status: 'canceled', payment_key: ok2, fail_reason: base + '_refunded' }).catch(() => null);
              out.cancelled++;
            } else {
              await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(o.order_id)}&status=eq.failed`, { payment_key: ok2, fail_reason: base + '_refund_failed' }).catch(() => null);
              if(!/_refund_failed$/.test(String(o.fail_reason || ''))) await notifyAdmin(o, base, 'cancel_failed').catch(() => {});
              out.left++;
            }
            continue;
          }
          if(o.reconcile === 'cancel'){
            // 취소 실패 · 취소 도중 끊김 — 같은 멱등 키로 다시
            const base = String(o.fail_reason || '').replace(/_(refund_failed|canceling)$/, '');
            const ok = await tossCancelAll(tossSecret(), String(o.payment_key || ''), '초대 결제 정리');
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
          const r = o.reconcile === 'confirm' ? await finalize(o, String(o.payment_key || ''), tossSecret(), buyer) : await reconcilePending(o, buyer);
          const b = await r.json();
          if(b.ok) out.confirmed++;
          else if(b.refunded) out.cancelled++;
          else if(b.error === 'not_paid'){
            // 토스에 그 주문의 승인이 없다 — 결제창을 닫았다. 실패로 닫는다(다시 조회하지 않게)
            await sbPatch(`payment_orders?order_id=eq.${encodeURIComponent(o.order_id)}&status=eq.pending`, { status: 'failed', fail_reason: 'expired' }).catch(() => null);
            out.expired++;
          } else {
            if(o.reconcile === 'lookup' && Date.now() - Date.parse(String(o.created_at)) > 3600e3) await markUnknown(o, 'pending', 'sweep_unknown');
            out.left++;
          }
        } catch(_se){ out.left++; }
      }
      return json({ ok: true, ver: VER, ...out });
    }
    return json({ ok: false, error: 'bad_action' });
  } catch(e){
    console.error('[toss-invite-pay] 예외', e);
    return json({ ok: false, error: 'exception', retry: true });
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
