// ════════════════════════════════════════════════════════════
// toss-billing-charge — 등록된 카드로 즉시 결제 Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-08 · 2026-11-15 카드 후속(CARD_FAIL_V2_20261115) — 아래 「공통 블록」 머리말
//
// 결제창을 띄우지 않고, 회원이 미리 등록해 둔 빌링키로 바로 승인한다.
//   ① 브라우저가 toss-order 로 주문(payment_orders)을 만든다 — 금액은 서버가 정한다
//   ② 이 함수가 그 orderId 로 빌링 승인 + 티켓 확정까지 끝낸다  ← 왕복(리다이렉트) 없음
//
// 승인 후 처리(예치금 차감 · 좌석 홀드 → 구매 전환 · 실패 시 자동취소)는
// toss-confirm 과 완전히 같은 규칙이다 — 그 규칙은 두 파일에 글자 하나까지 같은 「공통 블록」에 있다.
// ⚠ 한쪽만 고치면 두 결제 경로의 정산이 어긋난다 — 반드시 함께 고칠 것(하네스가 블록을 대조한다).
//
// 이 함수가 지키는 것 (toss-confirm 과 동일)
//   · 금액 위변조 차단 — 브라우저 금액이 아니라 payment_orders.amount 를 신뢰
//   · 소유권 확인      — 주문·빌링키 모두 호출자 본인 것이어야 한다
//   · 멱등성           — 이미 처리된 주문은 다시 처리하지 않는다 · 실패한 주문을 「이미 처리됨 ✅」로 답하지 않는다
//   · 확정 실패 대응   — 승인 뒤 좌석·예치금이 안 맞으면 예치금을 원장 근거로 되돌리고 카드를 전액 취소 · 못 하면 슈퍼어드민 알림
//   · 애매한 청구 응답 — 같은 멱등 키로 한 번 더 · 그래도 모르면 주문 번호로 조회 · 끝내 모르면 실패로 굳히지 않는다(늦게 완료된 청구를 놓치지 않게)
//
// 필요한 시크릿
//   TOSS_BILLING_SECRET_KEY = live_sk_...  ← 자동결제 MID(bill_taam315) 시크릿
//   (없으면 TOSS_SECRET_KEY 로 폴백)     ⚠ 코드·커밋에 절대 넣지 말 것
// ════════════════════════════════════════════════════════════

const VER = 'tbc-2026-11-15';
const LOG = '[toss-billing-charge]';
const VIA = 'toss-billing-charge';

// ═══════════ CARD_FAIL_V2 공통 블록 시작 — toss-confirm/index.ts 와 toss-billing-charge/index.ts 가 글자 하나까지 같아야 한다(하네스가 대조한다) ═══════════
// 이 블록 밖(파일마다 다른 것): VER · LOG · VIA · 승인 호출(결제창 confirm / 등록 카드 billing) · MID 이름 · 승인 뒤 metadata 모양 · 성공 응답의 덧붙임.
// 왜 공통 블록인가(2026-11-15 카드 후속 · CARD_FAIL_V2_20261115):
//   승인 뒤 좌석 전환이 막히면 종전엔 무엇이든 「seat_lost(좌석 매진)」로 알렸고, 예치금 되돌림 실패·카드 취소 실패를 삼켰고(.catch(()=>{})),
//   같은 주문을 다시 열면 실패한 주문도 「✅ 이미 처리된 결제입니다」로 답했다. 두 함수가 같은 규칙이어야 해서(한쪽만 고치면 두 결제 경로가 어긋난다) 한 블록으로 묶었다.
//   _shared/ 에 두지 않는다 — 배포 고르기(supabase_pick.sh)가 _shared/ 를 고치면 그것을 import 하는 함수 전부를 다시 올린다.
// 규칙
//   · DB 거절과 애매함을 가른다 — 응답이 왔고(HTTP 상태 > 0) 본문에 SQLSTATE 5글자가 있으면 DB 가 그 문장을 거절했다(롤백됐다).
//     네트워크·시간 초과·게이트웨이 5xx(코드 없음)는 애매하다 — 실제로는 커밋됐을 수 있다. 애매하면 돈을 돌려주지도 취소하지도 않는다(공짜 티켓 방지).
//     ⚠ HTTP 상태로 가르지 않는다(PostgREST 는 P0001 만 400 이고 그 밖의 P0*·22* 일부를 500 으로 보낸다 — 패키지 2차 검증).
//     ⚠ supabase-js 를 쓰지 않는다 — CLI 배포가 esm.sh 의 @2 를 그때그때 새로 풀어 오류 모양이 바뀔 수 있다(적대 리뷰 H6). 모든 호출은 fetch + 시간 제한.
//   · 교착·직렬화·잠금 대기·문장 시간 초과(40001 · 40P01 · 55P03 · 57014)는 한 번 더 해 본다(롤백은 됐다).
//   · 예치금 되돌림은 서버 함수 taam_card_order_settle 이 원장을 근거로 센다(멱등) — 이번 호출이 「뺐다고 들은」 금액을 믿지 않는다.
//   · 카드 취소는 전액 · 최대 3번(다른 멱등 키) · 실패하면 결제를 조회해 CANCELED 인지 본다 · 그래도 안 되면 슈퍼어드민 알림(상점관리자에서 취소).
//   · 결과를 남긴다 — fail_reason = <코드>[_depfail]_(refunded|refund_failed) (판매 현황 card_captured_no_ticket · 결제 내역이 이 꼬리를 읽는다).
//     처리 중에는 unknown:* 표시를 단다(승인 요청 전 approving · 잡은 뒤 converting:<nonce> · 실패 정리 중 failing:<코드>) — 함수가 도중에 죽어도 다시 부른 호출이 알아본다.
//   · 회원이 읽는 주문 metadata 에는 코드와 정리된 값만 — DB 오류 원문·토스 응답 원문(secret 칸)은 넣지 않는다(적대 리뷰 M5).
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const TOSS = 'https://api.tosspayments.com';
const DB_MS = 10000;      // DB 호출 하나의 시간 제한
const TOSS_MS = 15000;    // 토스 호출 하나의 시간 제한
const MARK = 'CARD_FAIL_V2_20261115';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify({ ...body, ver: VER }), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const enc = (s: unknown) => encodeURIComponent(String(s ?? ''));
const SB_H = () => ({ apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' });

// DB 오류 — db: DB 가 거절했다(롤백) · transient: 다시 해 볼 만한 거절 · 둘 다 아니면 애매(커밋됐을 수도)
const SQLSTATE_RE = /^(0[0-9A-Z]|1[0-9]|2[0-9A-F]|3[0-9A-F]|4[0-9]|5[0-9]|72|F0|HV|P0|XX)[0-9A-Z]{3}$/;
class DbErr extends Error {
  status: number; pgCode: string; db: boolean; transient: boolean;
  constructor(m: string, status: number, pgCode?: string) {
    super(m); this.status = status; this.pgCode = String(pgCode || '');
    // SQLSTATE 는 정해진 분류(앞 두 글자)만 — 'EPIPE' 같은 네트워크 코드가 5글자라고 DB 거절로 보면 커밋됐을 수도 있는 것을 취소한다(적대 리뷰 H6).
    //   게이트웨이 502·503·504 는 본문이 무엇이든 애매하다(DB 가 답한 것이 아니다)
    this.db = status > 0 && status !== 502 && status !== 503 && status !== 504 && SQLSTATE_RE.test(this.pgCode);
    this.transient = this.db && /^(40001|40P01|55P03|57014)$/.test(this.pgCode);
  }
}
const isDb = (e: DbErr | null) => !!(e && e.db);
const isTransient = (e: DbErr | null) => !!(e && e.transient);
// PostgREST 한 번 — {data, err}. 본문을 끝까지 못 읽으면 애매(err.status 0)
async function sbReq(method: string, path: string, body?: unknown, prefer?: string): Promise<{ data: any; err: DbErr | null }> {
  let r: Response;
  try {
    r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
      method, headers: { ...SB_H(), ...(prefer ? { Prefer: prefer } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(DB_MS),
    });
  } catch (e) { return { data: null, err: new DbErr('network ' + String((e as Error)?.message || e).slice(0, 120), 0) }; }
  let txt = '';
  try { txt = await r.text(); } catch (_e) { return { data: null, err: new DbErr('body_cut', 0) }; }
  let b: any = null;
  try { b = txt ? JSON.parse(txt) : null; } catch (_e) { b = null; }
  if (!r.ok) return { data: null, err: new DbErr(String((b && (b.message || b.hint)) || ('http ' + r.status)).slice(0, 400), r.status, b && b.code) };
  return { data: b, err: null };
}
async function sbGet(path: string): Promise<any[] | null> { const r = await sbReq('GET', path); return (!r.err && Array.isArray(r.data)) ? r.data : null; }
async function sbPatch(path: string, body: unknown) { const r = await sbReq('PATCH', path, body, 'return=representation'); return { rows: (!r.err && Array.isArray(r.data)) ? r.data : [], err: r.err }; }
async function sbRpc(fn: string, args: unknown) { return await sbReq('POST', `rpc/${fn}`, args); }
// 알림이 함수 끝에 잘리지 않게 — 런타임이 주면 waitUntil, 아니면 기다린다
async function background(p: Promise<unknown>) {
  const er = (globalThis as any).EdgeRuntime;
  if (er && typeof er.waitUntil === 'function') { try { er.waitUntil(p.catch(() => {})); return; } catch (_e) { /* 아래 */ } }
  await p.catch(() => {});
}
// 호출자 — 회원 JWT 로 auth 에 묻는다
async function caller(req: Request): Promise<{ id: string; email: string } | null> {
  const h = req.headers.get('Authorization') || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!t) return null;
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${t}` }, signal: AbortSignal.timeout(DB_MS) });
    if (!u.ok) return null;
    const j = await u.json().catch(() => null);
    if (!j?.id) return null;
    return { id: String(j.id), email: String(j.email || '') };
  } catch (_e) { return null; }
}

// ── 토스 ──
// 응답에서 남길 칸만(원문의 secret 등은 저장하지 않는다) — 결제 내역(_taam_pl_toss)·카드 환불(mId)이 읽는 칸은 모두 남긴다
function pickToss(t: any): Record<string, unknown> | null {
  if (!t || typeof t !== 'object') return null;
  const s = (v: unknown, n: number) => (v === null || v === undefined) ? undefined : String(v).slice(0, n);
  const num = (v: unknown) => (v === null || v === undefined || !isFinite(Number(v))) ? undefined : Number(v);
  const c = t.card && typeof t.card === 'object' ? {
    issuerCode: s(t.card.issuerCode, 10), acquirerCode: s(t.card.acquirerCode, 10), company: s(t.card.company, 30), number: s(t.card.number, 30),
    installmentPlanMonths: num(t.card.installmentPlanMonths), isInterestFree: typeof t.card.isInterestFree === 'boolean' ? t.card.isInterestFree : undefined,
    interestPayer: s(t.card.interestPayer, 20), approveNo: s(t.card.approveNo, 20), useCardPoint: typeof t.card.useCardPoint === 'boolean' ? t.card.useCardPoint : undefined,
    cardType: s(t.card.cardType, 10), ownerType: s(t.card.ownerType, 10), acquireStatus: s(t.card.acquireStatus, 20), amount: num(t.card.amount),
  } : undefined;
  const o = {
    paymentKey: s(t.paymentKey, 200), orderId: s(t.orderId, 80), mId: s(t.mId, 40), status: s(t.status, 30), method: s(t.method, 30), currency: s(t.currency, 5),
    totalAmount: num(t.totalAmount), balanceAmount: num(t.balanceAmount), approvedAt: s(t.approvedAt, 40), requestedAt: s(t.requestedAt, 40),
    type: s(t.type, 20), country: s(t.country, 5), orderName: s(t.orderName, 100),
    receipt: t.receipt && t.receipt.url ? { url: s(t.receipt.url, 400) } : undefined, card: c,
    easyPay: t.easyPay && typeof t.easyPay === 'object' ? { provider: s(t.easyPay.provider, 30), amount: num(t.easyPay.amount), discountAmount: num(t.easyPay.discountAmount) } : undefined,
    cancels: Array.isArray(t.cancels) ? t.cancels.slice(0, 50).map((x: any) => ({ cancelAmount: num(x?.cancelAmount), cancelReason: s(x?.cancelReason, 200), canceledAt: s(x?.canceledAt, 40),
      transactionKey: s(x?.transactionKey, 80), cancelStatus: s(x?.cancelStatus, 20) })) : undefined,
  };
  return JSON.parse(JSON.stringify(o));
}
async function tossCall(secret: string, path: string, method: string, body?: unknown, idem?: string) {
  const h: Record<string, string> = { Authorization: 'Basic ' + btoa(secret + ':'), 'Content-Type': 'application/json' };
  if (idem) h['Idempotency-Key'] = idem;
  try {
    const r = await fetch(TOSS + path, { method, headers: h, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(TOSS_MS) });
    const j = await r.json().catch(() => ({}));
    return { ok: r.ok, status: r.status, body: (j || {}) as Record<string, any> };
  } catch (_e) { return { ok: false, status: 0, body: { code: 'NETWORK_ERROR' } as Record<string, any> }; }   // 네트워크·시간 초과 — 애매(승인됐을 수 있다)
}
// 토스 응답이 「다시 볼 일」인가(승인이 실제로 됐을 수 있다) — 분명한 거절(카드 거절·한도 등 4xx)만 실패로 굳힌다(적대 리뷰 H1)
const TOSS_RETRY = /^(ALREADY_PROCESSED_PAYMENT|PROVIDER_ERROR|FAILED_INTERNAL_SYSTEM_PROCESSING|FAILED_PAYMENT_INTERNAL_SYSTEM_PROCESSING|UNKNOWN_PAYMENT_ERROR|NETWORK_ERROR|IDEMPOTENT_REQUEST_PROCESSING)$/;
const tossAmbiguous = (t: { ok: boolean; status: number; body: Record<string, any> }) =>
  t.status === 0 || t.status >= 500 || t.status === 409 || TOSS_RETRY.test(String(t.body?.code || '')) || (t.ok && t.body?.status !== 'DONE');
// 애매하면 결제를 조회한다 — 결제키가 있으면 그것으로, 없으면 주문 번호로. 이 주문의 DONE 결제면 그 응답으로 잇는다
async function tossLookup(secret: string, paymentKey: string, orderId: string) {
  const g = paymentKey ? await tossCall(secret, `/v1/payments/${enc(paymentKey)}`, 'GET')
                       : await tossCall(secret, `/v1/payments/orders/${enc(orderId)}`, 'GET');
  if (g.ok && g.body?.status === 'DONE' && String(g.body?.orderId || '') === orderId) return { done: true, gone: false, body: g.body };
  // 결제가 없다(404) · 취소·중단·만료 — 분명히 승인 안 됨(또는 이미 끝남)
  const gone = g.status === 404 || !!(g.ok && /^(CANCELED|ABORTED|EXPIRED)$/.test(String(g.body?.status || '')));
  return { done: false, gone, body: g.body };
}
// 전액 취소 — 최대 3번(멱등 키를 바꿔 가며) · 실패하면 결제를 조회해 CANCELED 인지 본다. ⚠ 부분 취소에 쓰지 말 것(두 번째 키가 또 취소한다)
async function cancelTossFull(secret: string, paymentKey: string, reason: string): Promise<{ ok: boolean; code: string; tries: number }> {
  if (!secret || !paymentKey) return { ok: false, code: 'NO_KEY', tries: 0 };
  const keys = [`taam-cancel-${paymentKey}`, `taam-cancel-${paymentKey}-r1`, `taam-cancel-${paymentKey}-r2`];
  const waits = [0, 800, 2000];
  let code = '', i = 0;
  for (; i < 3; i++) {
    if (waits[i]) await sleep(waits[i]);
    const r = await tossCall(secret, `/v1/payments/${enc(paymentKey)}/cancel`, 'POST', { cancelReason: reason.slice(0, 200) }, keys[i]);
    code = String(r.body?.code || (r.ok ? 'OK' : ('http_' + r.status)));
    if (r.ok || code === 'ALREADY_CANCELED_PAYMENT') return { ok: true, code, tries: i + 1 };
    const g = await tossCall(secret, `/v1/payments/${enc(paymentKey)}`, 'GET');
    if (g.ok && String(g.body?.status || '') === 'CANCELED') return { ok: true, code: 'CANCELED', tries: i + 1 };
    // 분명한 4xx 거절(다시 해도 같다)이면 멈춘다 — 애매한 것(네트워크 · 5xx · 409 · 처리 중)만 다시
    if (r.status >= 400 && r.status < 500 && r.status !== 409 && !TOSS_RETRY.test(code)) { i++; break; }
  }
  return { ok: false, code: code.slice(0, 60), tries: i };
}

// ── 좌석 가드 문구 → 코드 (라이브 가드 문구 · 2026-11-15) ──
//   REPURCHASE_BLOCKED: 이 매장은 90 일 재구매 제한이 있습니다 (기존 방문일 2027.01.10)
//   DUPLICATE_PURCHASE: 이미 구매한 회차입니다 (기존 <구매 id> · <상태>)   ← 괄호는 넘기지 않는다(구매 id)
//   TIME_CONFLICT: 같은 날 같은 시간대에 이미 예약이 있습니다 (<매장> · <날짜> <시각>)
function guardCode(msg: string): { code: string; extra: Record<string, unknown> } {
  const m = String(msg || '');
  if (/REPURCHASE_BLOCKED/.test(m)) {
    const d = (m.match(/(\d+)\s*일 재구매/) || [])[1];
    const p = (m.match(/기존 방문일\s*([0-9]{4}[.\-\/][0-9]{1,2}[.\-\/][0-9]{1,2})/) || [])[1];
    const x: Record<string, unknown> = {};
    if (d) x.days = Number(d);
    if (p) x.prev = p;
    return { code: 'repurchase_blocked', extra: x };
  }
  if (/DUPLICATE_PURCHASE/.test(m)) return { code: 'dup', extra: {} };
  if (/TIME_CONFLICT/.test(m)) {
    const g = m.match(/\(([^()]*)\)\s*$/);
    return { code: 'clash', extra: g ? { prev_text: g[1].slice(0, 120) } : {} };
  }
  if (/TIER_BLOCKED|GUEST_BLOCKED/.test(m)) return { code: 'tier_blocked', extra: {} };
  if (/PACKAGE_ONLY|TICKET_NOT_OPEN|TICKET_NOT_APPROVED|TICKET_NOT_FOUND/.test(m)) return { code: 'round_closed', extra: {} };
  if (/PRICE_BELOW_TICKET/.test(m)) return { code: 'ticket_price_changed', extra: {} };
  if (/TICKET_SOLD_OUT|SLOT_SOLD_OUT|INVALID_PARTY_SIZE|SOLO_LIMIT|FRAGMENT_BLOCKED/.test(m)) return { code: 'seat_lost', extra: {} };
  return { code: 'convert_failed', extra: {} };
}
// 응답·주문에 실어도 되는 덧붙임만(회원이 읽는다)
function pickExtra(e: any): Record<string, unknown> {
  const o: Record<string, unknown> = {};
  if (!e || typeof e !== 'object') return o;
  if (Number.isFinite(Number(e.days)) && Number(e.days) > 0) o.days = Math.round(Number(e.days));
  if (typeof e.prev === 'string' && /^[0-9]{4}[.\-\/][0-9]{1,2}[.\-\/][0-9]{1,2}$/.test(e.prev)) o.prev = e.prev;
  if (typeof e.prev_text === 'string' && e.prev_text) o.prev_text = e.prev_text.slice(0, 120);
  if (Number.isFinite(Number(e.deducted))) o.deducted = Number(e.deducted);
  if (Number.isFinite(Number(e.needed))) o.needed = Number(e.needed);
  return o;
}
// 사유(회원 문구 · 세 벌) — 옛 앱은 응답의 reason(한국어)을 그대로 보여 준다
const WHY: Record<string, [string, string, string]> = {
  seat_lost: ['좌석이 매진되어', 'The seats sold out, so', '席が満席になったため'],
  repurchase_blocked: ['같은 매장 재구매 제한 때문에', "Because of the restaurant's repurchase limit,", '同じ店舗の再購入制限のため'],
  dup: ['이미 구매하신 회차라', 'You already hold this booking, so', 'すでにご購入済みの回のため'],
  clash: ['같은 날 같은 시간대에 다른 예약이 있어', 'You have another booking in the same time slot, so', '同じ日の同じ時間帯に別のご予約があるため'],
  tier_blocked: ['이용 등급이 맞지 않아', 'Your membership tier does not allow this ticket, so', 'ご利用等級が対象外のため'],
  round_closed: ['판매가 끝났거나 바뀐 일정이라', 'This date is no longer on sale, so', '販売が終了したか変更された日程のため'],
  ticket_price_changed: ['티켓 가격이 바뀌어', 'The ticket price changed, so', 'チケット価格が変更されたため'],
  deposit_short: ['결제 중 예치금 잔액이 바뀌어', 'Your deposit balance changed during payment, so', '決済中にデポジット残高が変わったため'],
  convert_failed: ['', '', ''],
  amount_mismatch_toss: ['결제 금액이 맞지 않아', 'The approved amount did not match, so', '決済金額が一致しなかったため'],
  order_closed: ['결제 주문이 이미 닫혀 있어', 'This payment order was already closed, so', '決済注文がすでに終了していたため'],
};
const why = (code: string, li: number) => (WHY[code] || WHY.convert_failed)[li];
function reasonText(code: string, refunded: boolean, depUsed: boolean, depOk: boolean, extra: any): string {
  const x = pickExtra(extra);
  const head = code === 'repurchase_blocked' && x.days ? `같은 매장 재구매 제한(${x.days}일) 때문에` : why(code, 0);
  return (head ? head + ' ' : '') + '구매를 확정하지 못했습니다 — '
    + (refunded ? '결제하신 카드 금액은 자동으로 전액 취소되었습니다' : '카드 자동 취소가 지연되어 TAAM 이 확인 후 처리해 드립니다')
    + (depUsed ? (depOk ? ' · 사용하신 예치금도 돌려드렸습니다' : ' · 예치금 반환이 지연되어 TAAM 이 확인 후 처리해 드립니다') : '');
}
const CANCEL_REASON: Record<string, string> = {
  seat_lost: '좌석 만료로 구매 불가', repurchase_blocked: '재구매 제한으로 구매 불가', dup: '이미 구매한 회차', clash: '같은 시간대 예약 있음',
  tier_blocked: '등급 제한으로 구매 불가', round_closed: '판매하지 않는 일정', ticket_price_changed: '티켓 가격 변경', deposit_short: '예치금 부족으로 구매 불가',
  convert_failed: '구매 확정 실패', amount_mismatch_toss: '금액 불일치', order_closed: '주문이 이미 닫힘',
};

// ── 결과 꼬리 · 닫힌 주문 보고 ──
const FR_RE = /^([a-z_]+?)(_depfail)?_(refunded|refund_failed)$/;
function closedReport(o: any): Record<string, unknown> | null {
  const fr = String(o?.fail_reason || '');
  const m = fr.match(FR_RE);
  if (!m || (o?.status !== 'paid' && o?.status !== 'canceled')) return null;
  const f = (o?.metadata && typeof o.metadata === 'object' && o.metadata.fail && typeof o.metadata.fail === 'object') ? o.metadata.fail : {};
  const refunded = m[3] === 'refunded', depOk = !m[2], depUsed = f.dep_used === true || !!m[2];
  return { ok: false, already: true, error: m[1], refunded, deposit_used: depUsed, deposit_refunded: depUsed ? depOk : undefined, hold_gone: f.hold_released !== false,
           orderId: o.order_id, ...pickExtra(f.extra), reason: reasonText(m[1], refunded, depUsed, depOk, f.extra) };
}

// ── 문맥 ──
type Ctx = {
  order: any; preMeta: Record<string, any>; uid: string; orderId: string; secret: string; tk: string; cur: string; expected: number;
  midLabel: string; holdId: string; depositUsed: number; claimMeta: Record<string, unknown>; nonce: string;
};
function ctxOf(order: any, uid: string, secret: string, midLabel: string): Ctx {
  const pre = (order?.metadata && typeof order.metadata === 'object') ? order.metadata : {};
  return { order, preMeta: pre, uid, orderId: String(order?.order_id || ''), secret, tk: String(order?.payment_key || ''),
           cur: String(order?.currency || 'KRW').toUpperCase(), expected: Number(order?.amount || 0), midLabel,
           holdId: String(pre.hold_purchase_id || ''), depositUsed: Math.max(0, Number(pre.deposit_used || 0)), claimMeta: {}, nonce: '' };
}

// ── 알림 ──
async function buyerName(uid: string): Promise<string> {
  try {
    const p = await sbGet(`profiles?id=eq.${enc(uid)}&select=display_name,phone`);
    const d = p && p[0];
    if (d?.display_name && String(d.display_name).trim()) return String(d.display_name).trim().slice(0, 40);
    const tail = String(d?.phone || '').replace(/[^0-9]/g, '').slice(-4);
    if (tail) return '회원 ' + tail;
  } catch (_e) { /* 이름은 장식 */ }
  return '회원';
}
async function pushSuper(title: string, body: string, category: string, tag: string) {
  for (const role of ['superadmin', 'super_admin']) {
    try {
      await fetch(`${SUPABASE_URL}/functions/v1/send-push`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${SERVICE_KEY}` },
        body: JSON.stringify({ to: 'role:' + role, payload: { title, body, url: '/', category, tag } }), signal: AbortSignal.timeout(DB_MS) });
    } catch (_e) { /* 한쪽 실패해도 다른 쪽은 보낸다 */ }
  }
}
// 슈퍼어드민 — cancel_failed: 카드 자동 취소 실패(상점관리자에서 취소) · deposit_failed: 예치금 되돌림 실패(「예치금 부여」) · pending: 결과를 모른다(확인)
async function alertAdmins(c: Ctx, kind: 'cancel_failed' | 'deposit_failed' | 'pending', code: string, info?: Record<string, unknown>) {
  try {
    const who = await buyerName(c.uid);
    const rest = String(c.preMeta.restaurant_name || c.preMeta.toss?.orderName || '티켓').slice(0, 60);
    const money = c.cur === 'KRW' ? '₩' + Number(c.expected || 0).toLocaleString('en-US')
                : (c.cur + ' ' + Number(c.expected || 0).toLocaleString('en-US') + (c.order?.settle_krw ? ' (≈₩' + Number(c.order.settle_krw).toLocaleString('en-US') + ')' : ''));
    const pk = String(c.tk || c.order?.payment_key || '');
    const where = who + '님 · ' + rest + ' · 카드 ' + money + ' · ' + c.midLabel + (pk ? ' · 결제키 …' + pk.slice(-8) : '') + ' · 주문 ' + c.orderId + ' · 사유 ' + code;
    let title = '', body = '', type = 'seat_hold_convert_failed';
    if (kind === 'cancel_failed') {
      title = '⚠ 카드 결제 자동 취소 실패 — 상점관리자 확인 필요';
      body = where + ' — 좌석은 확정되지 않았습니다. 토스 상점관리자(' + c.midLabel + ')에서 승인취소해 주세요.';
    } else if (kind === 'deposit_failed') {
      type = 'ledger_apply_failed';
      title = '🔴 예치금 환원 실패 — 수동 확인 필요';
      body = where + ' — 카드 결제 실패로 돌려줘야 할 예치금' + (info && Number(info.owed) > 0 ? ' ₩' + Number(info.owed).toLocaleString('en-US') : '') + ' 을(를) 돌려주지 못했습니다. 회원 원장에서 확인 후 「예치금 부여」로 돌려주세요.';
    } else {
      title = '⚠ 카드 결제 결과 확인 필요';
      body = where + ' — 카드 승인 또는 티켓 확정 결과를 모릅니다. 토스 상점관리자(승인 여부)와 결제 내역·회원 원장(티켓·예치금)을 확인해 주세요(자동으로 다시 처리하지 않습니다 — 회원이 결제를 다시 열면 같은 승인으로 이어집니다).';
    }
    const sups = await sbGet(`profiles?role=in.(superadmin,super_admin)&select=id`) || [];
    const rows = sups.filter((p: any) => p.id !== c.uid).map((p: any) => ({ user_id: p.id, type, title, body, url: '/',
      payload: { actor_id: c.uid, order_id: c.orderId, purchase_id: c.holdId || null, via: VIA, kind, code } }));
    if (rows.length) await sbReq('POST', 'notifications', rows, 'return=minimal');
    await pushSuper(title, body, type, 'taam-cardfail-' + c.orderId);
  } catch (e) { console.error(LOG, '슈퍼어드민 알림 실패', c.orderId, String((e as Error)?.message || e).slice(0, 120)); }
}
// 회원 알림함 — 카드가 승인됐다가 자동 취소된(또는 취소가 밀린) 사실은 토스트만으로는 앱을 닫으면 사라진다. 세 벌(payload.i18n)
async function notifyMemberCanceled(c: Ctx, code: string, refunded: boolean, depUsed: boolean, depOk: boolean) {
  try {
    let restEn = '', restJa = '';
    const restKo = String(c.preMeta.restaurant_name || '').slice(0, 60);
    if (c.preMeta.restaurant_id) {
      const r = await sbGet(`restaurants?id=eq.${enc(c.preMeta.restaurant_id)}&select=name_en,name_jp,i18n_jp_approved`);
      const d = r && r[0];
      if (d) { restEn = String(d.name_en || '').slice(0, 60); restJa = d.i18n_jp_approved === false ? '' : String(d.name_jp || '').slice(0, 60); }
    }
    const L = (li: number, rest: string) => {
      const T = [
        [refunded ? '카드 결제가 자동 취소되었습니다' : '카드 결제 취소가 지연되고 있습니다',
         refunded ? '결제하신 카드 금액은 전액 취소되었습니다' : '카드 자동 취소가 지연되어 TAAM 이 확인 후 처리해 드립니다',
         depOk ? '사용하신 예치금도 돌려드렸습니다' : '예치금 반환은 TAAM 이 확인 후 처리해 드립니다', '구매를 확정하지 못했습니다'],
        [refunded ? 'Your card payment was canceled' : 'Your card refund is delayed',
         refunded ? 'The card charge has been fully canceled' : 'The automatic card cancellation is delayed — TAAM will check and handle it',
         depOk ? 'The deposit you used has been returned' : 'TAAM will check and return the deposit you used', 'the purchase could not be completed'],
        [refunded ? 'カード決済は自動的に取り消されました' : 'カード決済の取消が遅れています',
         refunded ? 'カードのご請求は全額取り消されました' : 'カードの自動取消が遅れているため、TAAMが確認のうえ対応いたします',
         depOk ? 'ご利用のデポジットもお戻ししました' : 'デポジットの返還はTAAMが確認のうえ対応いたします', 'ご購入を確定できませんでした'],
      ][li];
      const w = why(code, li);
      const sent = w ? w + (li === 2 ? '' : ' ') + T[3] : (li === 1 ? 'The purchase could not be completed' : T[3]);
      const lead = (rest ? rest + ' · ' : '') + sent + (li === 2 ? '。' : '.');
      return { title: T[0], body: lead + '\n' + T[1] + (depUsed ? (li === 2 ? '。' : '. ') + T[2] : '') + (li === 2 ? '。' : '.') };
    };
    const ko = L(0, restKo), en = L(1, restEn || restKo), ja = L(2, restJa || restKo);
    await sbReq('POST', 'notifications', [{ user_id: c.uid, type: 'card_auto_canceled', title: ko.title, body: ko.body, url: '/',
      payload: { order_id: c.orderId, code, refunded, deposit_used: depUsed, deposit_refunded: depUsed ? depOk : null, via: VIA, i18n: { ko, en, ja } } }], 'return=minimal');
  } catch (_e) { /* 알림은 부가 */ }
}
// 결과를 모르는 주문 — 표시를 달고 한 번만 알린다
async function markUnknown(c: Ctx, status: string, code: string) {
  if (String(c.order?.fail_reason || '') === 'unknown:' + code) return;
  await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=eq.${status}`, { fail_reason: 'unknown:' + code });
  c.order.fail_reason = 'unknown:' + code;
  await alertAdmins(c, 'pending', code);
}

// ── 예치금 ──
// 차감(멤버십 먼저) — 잔액이 모자라면 아예 빼지 않는다(short). 응답을 잃으면 ambiguous(빠졌을 수 있다 — 되돌림은 원장으로 센다)
async function deductDeposit(uid: string, want: number, meta: Record<string, unknown>):
  Promise<{ deducted: number; fromMem: number; fromGen: number; short?: boolean; ambiguous?: boolean; failed?: boolean }> {
  const none = { deducted: 0, fromMem: 0, fromGen: 0 };
  for (let attempt = 0; attempt < 2; attempt++) {
    const p = await sbGet(`profiles?id=eq.${enc(uid)}&select=membership_deposit_balance,general_deposit_balance`);
    if (!p) return { ...none, failed: true };
    if (!p[0]) return { ...none, failed: true };
    const mem = Number(p[0].membership_deposit_balance || 0), gen = Number(p[0].general_deposit_balance || 0);
    if (mem + gen < want) return { ...none, short: true };
    const fromMem = Math.min(mem, want), fromGen = want - fromMem;
    const label = String(meta.restaurant_name || '티켓');
    const entries: Record<string, unknown>[] = [];
    if (fromMem > 0) entries.push({ deposit_type: 'membership', change_type: 'ticket_purchase', amount: -fromMem, description: label + ' 카드결제 · 멤버십 예치금 차감', metadata: { ...meta, portion: 'membership' } });
    if (fromGen > 0) entries.push({ deposit_type: 'general', change_type: 'ticket_purchase', amount: -fromGen, description: label + ' 카드결제 · 일반 예치금 차감', metadata: { ...meta, portion: 'general' } });
    const r = await sbRpc('taam_apply_deposit_delta', { p_user_id: uid, p_mem_delta: -fromMem, p_gen_delta: -fromGen, p_entries: entries });
    if (!r.err) {
      const d = (r.data || {}) as Record<string, number>;
      const realMem = (typeof d.prev_mem === 'number') ? Math.max(0, d.prev_mem - Number(d.mem || 0)) : fromMem;
      const realGen = (typeof d.prev_gen === 'number') ? Math.max(0, d.prev_gen - Number(d.gen || 0)) : fromGen;
      return { deducted: realMem + realGen, fromMem: realMem, fromGen: realGen };
    }
    if (isDb(r.err)) {
      if (attempt === 0 && (/LEDGER_INSUFFICIENT/.test(r.err!.message) || isTransient(r.err))) { console.warn(LOG, '예치금 차감 — 다시 읽어 재시도', r.err!.pgCode); continue; }
      if (/LEDGER_INSUFFICIENT/.test(r.err!.message)) return { ...none, short: true };
      console.error(LOG, '예치금 차감 거절', r.err!.pgCode, r.err!.message.slice(0, 160));
      return { ...none, failed: true };
    }
    console.error(LOG, '예치금 차감 응답 없음(빠졌을 수 있다)', r.err!.message.slice(0, 120));
    return { ...none, ambiguous: true };
  }
  return { ...none, short: true };
}
// 되돌림 — 서버 함수(원장 근거 · 멱등)를 최대 3번. 함수가 아직 없으면(SQL 미적용) 이번 호출이 뺀 몫을 옛 방식으로 한 번
async function settleDeposit(c: Ctx, code: string, known?: { fromMem: number; fromGen: number; ambiguous?: boolean }):
  Promise<{ ok: boolean; mem: number; gen: number; owed: number; err?: string }> {
  const waits = [0, 500, 1500];
  let last = '';
  for (let i = 0; i < 3; i++) {
    if (waits[i]) await sleep(waits[i]);
    const r = await sbRpc('taam_card_order_settle', { p_order: c.orderId, p_user: c.uid, p_cap: c.depositUsed, p_purchase_id: c.holdId || null,
      p_code: code, p_why: '카드 결제 취소(' + (CANCEL_REASON[code] || code) + ') · 예치금 환원' });
    if (!r.err) {
      const d = r.data || {};
      return { ok: true, mem: Number(d.refunded_mem || 0), gen: Number(d.refunded_gen || 0), owed: Number(d.owed_before || 0) };
    }
    last = r.err.pgCode || (r.err.status ? 'http_' + r.err.status : 'network');   // 코드만 — 회원이 읽는 주문 metadata 에 DB 오류 원문을 남기지 않는다(M5)
    if (r.err.pgCode === 'PGRST202' || r.err.pgCode === '42883') {
      // 서버 함수가 아직 없다 — 이번 호출이 분명히 뺀 몫만 옛 방식으로(응답을 잃은 차감은 모른다 → 알림)
      if (!known || known.ambiguous || (known.fromMem + known.fromGen) <= 0) return { ok: !known || (!known.ambiguous && (known.fromMem + known.fromGen) <= 0), mem: 0, gen: 0, owed: 0, err: 'settle_missing' };
      const md = { order_id: c.orderId, purchase_id: c.holdId || undefined, card_fail_code: code };
      const ent: Record<string, unknown>[] = [];
      if (known.fromMem > 0) ent.push({ deposit_type: 'membership', change_type: 'ticket_refund', amount: known.fromMem, description: '카드 결제 취소 · 예치금 환원', metadata: md });
      if (known.fromGen > 0) ent.push({ deposit_type: 'general', change_type: 'ticket_refund', amount: known.fromGen, description: '카드 결제 취소 · 예치금 환원', metadata: md });
      const o = await sbRpc('taam_apply_deposit_delta', { p_user_id: c.uid, p_mem_delta: known.fromMem, p_gen_delta: known.fromGen, p_entries: ent });
      return o.err ? { ok: false, mem: 0, gen: 0, owed: known.fromMem + known.fromGen, err: 'legacy_refund_failed' }
                   : { ok: true, mem: known.fromMem, gen: known.fromGen, owed: known.fromMem + known.fromGen };
    }
    if (isDb(r.err) && !isTransient(r.err)) break;   // 분명한 거절(주문·회원 불일치 등) — 다시 해도 같다
  }
  console.error(LOG, '예치금 되돌림 실패 — 수동 확인 필요', c.orderId, last);
  return { ok: false, mem: 0, gen: 0, owed: 0, err: last || 'settle_failed' };
}

// ── 좌석 ──
// 이 구매 id 의 지금 — mine(이 주문으로 확정) · other(다른 결제로 확정) · hold(살아 있는 홀드) · hold_mismatch(홀드인데 주문과 회차·인원이 다름) · gone · null(못 읽음)
async function holdState(uid: string, holdId: string, orderId: string, tid: string, pax: number): Promise<string | null> {
  const rows = await sbGet(`tickets?purchase_id=eq.${enc(holdId)}&user_id=eq.${enc(uid)}&select=status,ticket_product_id,party_size,order_id:extra_data->>order_id`);
  if (!rows) return null;
  const dead = (s: string) => /^(cancelled|canceled|expired|failed|refunded)$/.test(s);
  if (rows.some((r: any) => !dead(String(r.status || '')) && r.status !== 'hold' && String(r.order_id || '') === orderId)) return 'mine';
  if (rows.some((r: any) => !dead(String(r.status || '')) && r.status !== 'hold')) return 'other';
  const h = rows.find((r: any) => r.status === 'hold');
  if (h) return (String(h.ticket_product_id || '') === tid && Number(h.party_size) === pax) ? 'hold' : 'hold_mismatch';
  return 'gone';
}
// 이 주문으로 확정된 살아 있는 티켓 — true · false · null(못 읽음)
async function orderTicketLive(uid: string, orderId: string): Promise<boolean | null> {
  const rows = await sbGet(`tickets?user_id=eq.${enc(uid)}&extra_data->>order_id=eq.${enc(orderId)}&status=not.in.(cancelled,canceled,expired,failed,hold)&select=purchase_id&limit=1`);
  return rows === null ? null : rows.length > 0;
}
// 이 주문으로 확정된 적이 있나(그 뒤 취소됐어도) — 다시 부른 호출의 「이미 처리」 판단
async function orderTicketAny(uid: string, orderId: string): Promise<boolean | null> {
  const rows = await sbGet(`tickets?user_id=eq.${enc(uid)}&extra_data->>order_id=eq.${enc(orderId)}&status=neq.hold&select=purchase_id&limit=1`);
  return rows === null ? null : rows.length > 0;
}
type Conv = { ok: boolean; purchaseId?: string; ambiguous?: boolean; stage?: string; code?: string; extra?: Record<string, unknown>; holdAlive?: boolean; msg?: string };
// 좌석 홀드 → 구매. 홀드가 살아 있으면 UPDATE(그 주문의 회차·인원과 같을 때만 — 적대 리뷰 M1), 없으면 INSERT(좌석 가드가 다시 본다).
//   DB 가 거절하면 그 코드로 실패(UPDATE 가 거절됐는데 INSERT 로 넘어가지 않는다 — 넘어가면 회원 자기 홀드에 「중복」으로 걸렸다 · 적대 리뷰).
//   애매하면 같은 문장을 다시 한다(앞 문장이 아직 돌면 행·권고 잠금에서 기다렸다가 판정된다) · 그 뒤 거절이 와도 이 주문의 티켓이 생겼으면 성공이다.
async function convertHoldToActive(c: Ctx, total: number, cardPaid: number, deposited: number): Promise<Conv> {
  const meta = c.preMeta, tid = String(meta.ticket_id || ''), pax = Number(meta.pax || 0);
  const extra: Record<string, unknown> = {
    seatHold: false, cardPaid, depositUsed: deposited, buyerRole: 'user', agencyFee: Number(meta.agency_fee || 0),
    paidBy: 'card+deposit', order_id: c.orderId,
    // 외화 결제 흔적 — 환불(카드 원거래 취소)은 이 통화·이 금액 그대로 한다(cardPaid 는 원화 정산액 settle_krw)
    ...(c.cur !== 'KRW' ? { card_currency: c.cur, card_amount_fx: Number(c.order?.amount) || 0 } : {}),
  };
  const ok = (pid: string): Conv => ({ ok: true, purchaseId: pid });
  const fail = (msg: string, holdAlive: boolean): Conv => { const g = guardCode(msg); return { ok: false, code: g.code, extra: g.extra, holdAlive, msg: msg.slice(0, 300) }; };
  let goInsert = !c.holdId;
  if (c.holdId) {
    const st = await holdState(c.uid, c.holdId, c.orderId, tid, pax);
    if (st === 'mine') return ok(c.holdId);
    if (st === 'other') return { ok: false, code: 'dup', extra: {}, holdAlive: false, msg: 'hold_converted_by_other_payment' };   // 다른 결제가 이 홀드를 이미 확정했다(적대 리뷰 L2)
    if (st === 'hold_mismatch') return { ok: false, code: 'convert_failed', extra: {}, holdAlive: false, msg: 'hold_mismatch' };   // 주문과 다른 홀드는 건드리지 않는다
    if (st === 'gone') goInsert = true;
    else {
      // hold 또는 못 읽음 — UPDATE 를 해 본다(최대 3번)
      let amb = false;
      for (let i = 0; i < 3; i++) {
        const r = await sbReq('PATCH',
          `tickets?purchase_id=eq.${enc(c.holdId)}&user_id=eq.${enc(c.uid)}&status=eq.hold&ticket_product_id=eq.${enc(tid)}&party_size=eq.${enc(pax)}&select=purchase_id`,
          { status: 'active', price: total, extra_data: extra }, 'return=representation');
        if (!r.err && Array.isArray(r.data) && r.data.length) return ok(c.holdId);
        if (!r.err) break;                                       // 0 줄 — 아래에서 지금 상태를 본다
        if (isDb(r.err)) {
          if (isTransient(r.err) && i < 2) continue;
          if (amb) { const s2 = await holdState(c.uid, c.holdId, c.orderId, tid, pax); if (s2 === 'mine') return ok(c.holdId); }
          return fail(r.err!.message, true);
        }
        amb = true;
        if (i < 2) { await sleep(300 * (i + 1)); continue; }
        const s3 = await holdState(c.uid, c.holdId, c.orderId, tid, pax);
        if (s3 === 'mine') return ok(c.holdId);
        return { ok: false, ambiguous: true, stage: 'update' };
      }
      const s2 = await holdState(c.uid, c.holdId, c.orderId, tid, pax);
      if (s2 === 'mine') return ok(c.holdId);
      if (s2 === 'other') return { ok: false, code: 'dup', extra: {}, holdAlive: false, msg: 'hold_converted_by_other_payment' };
      if (s2 === 'gone') goInsert = true;
      else if (s2 === null) return amb ? { ok: false, ambiguous: true, stage: 'update_reread' } : { ok: false, code: 'convert_failed', extra: {}, holdAlive: true, msg: 'hold_reread_failed' };
      else return { ok: false, code: 'convert_failed', extra: {}, holdAlive: s2 === 'hold', msg: 'hold_update_no_rows' };
    }
  }
  if (!goInsert) return { ok: false, code: 'convert_failed', extra: {}, holdAlive: false, msg: 'unreachable' };
  // 홀드가 없다(만료) — 원화 주문이면 지금 정가와 대어 본다(가격이 올랐는데 옛 합계로 확정되지 않게 · 결정 9b — 가격 하한 가드는 UPDATE 에만 있다)
  if (c.cur === 'KRW' && !(meta.fx && typeof meta.fx === 'object')) {
    const pr = await sbRpc('taam_ticket_price_krw', { p_ticket_id: tid, p_pax: pax });
    const now = Number(pr.data);
    if (!pr.err && Number.isFinite(now) && now > 0 && now > total) return { ok: false, code: 'ticket_price_changed', extra: {}, holdAlive: false, msg: 'price_now_' + now };
  }
  const pid = c.holdId || ('PAYC-' + tid + '_' + Date.now());
  const row = {
    user_id: c.uid, restaurant_id: String(meta.restaurant_id || ''), restaurant_name: meta.restaurant_name || '', ticket_product_id: tid,
    reservation_date: null, party_size: pax, price: total, status: 'active', purchase_id: pid, extra_data: extra, created_at: new Date().toISOString(),
  };
  let amb = false;
  for (let i = 0; i < 3; i++) {
    const r = await sbReq('POST', 'tickets?select=purchase_id', row, 'return=representation');
    if (!r.err) return ok(pid);
    if (isDb(r.err)) {
      if (isTransient(r.err) && i < 2) continue;
      // 앞 시도가 애매했으면(실제로는 들어갔을 수 있다) 이 주문의 티켓이 있는지 먼저 본다 — 있으면 성공(그 뒤의 「매진」·「중복」은 자기 행 때문이다)
      if (amb || /DUPLICATE_PURCHASE/.test(r.err!.message)) { const f = await orderTicketLive(c.uid, c.orderId); if (f === true) return ok(pid); if (f === null && amb) return { ok: false, ambiguous: true, stage: 'insert_reread' }; }
      return fail(r.err!.message, false);
    }
    amb = true;
    const f = await orderTicketLive(c.uid, c.orderId);
    if (f === true) return ok(pid);
    if (i < 2) { await sleep(300 * (i + 1)); continue; }
    return { ok: false, ambiguous: true, stage: 'insert' };
  }
  return { ok: false, ambiguous: true, stage: 'insert' };
}
// 살아 있는 홀드 반납 — 'released' · 'not_hold'(이미 홀드가 아니다) · null(못 함)
async function releaseHold(uid: string, holdId: string): Promise<string | null> {
  if (!holdId) return 'not_hold';
  const r = await sbPatch(`tickets?purchase_id=eq.${enc(holdId)}&user_id=eq.${enc(uid)}&status=eq.hold&select=purchase_id`, { status: 'cancelled' });
  if (r.err) return null;
  return r.rows.length ? 'released' : 'not_hold';
}

// ── 승인 뒤 확정 실패 — 한 길 ──
//   ① 표시(failing) ② 예치금 되돌림(원장 근거) ③ 살아 있는 홀드 반납 ④ 카드 전액 취소 ⑤ (차감 응답을 잃었으면) 되돌림 한 번 더 ⑥ 주문에 결과 ⑦ 알림
async function failAfterApproval(c: Ctx, code: string, extra: Record<string, unknown>, o: { holdAlive: boolean; depAmbiguous?: boolean; known?: { fromMem: number; fromGen: number; ambiguous?: boolean } }) {
  console.warn(LOG, '승인 뒤 확정 실패', c.orderId, code);
  await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=eq.paid`, { fail_reason: 'unknown:failing:' + code });
  const depUsed = c.depositUsed > 0;
  let dep: { ok: boolean; mem: number; gen: number; owed: number; err?: string } = { ok: true, mem: 0, gen: 0, owed: 0 };
  if (depUsed) dep = await settleDeposit(c, code, o.known);
  let holdGone = !o.holdAlive;
  if (o.holdAlive && c.holdId) holdGone = (await releaseHold(c.uid, c.holdId)) !== null;
  const card = await cancelTossFull(c.secret, c.tk, CANCEL_REASON[code] || '구매 확정 실패');
  if (depUsed && o.depAmbiguous) {
    // 응답을 잃은 차감이 늦게 들어왔을 수 있다 — 카드 취소(수 초) 뒤 한 번 더 센다(멱등)
    const d2 = await settleDeposit(c, code);
    dep = { ok: d2.ok, mem: dep.mem + d2.mem, gen: dep.gen + d2.gen, owed: dep.owed + d2.owed, err: d2.err };
  }
  const fr = code + (dep.ok ? '' : '_depfail') + (card.ok ? '_refunded' : '_refund_failed');
  const fail = { code, at: new Date().toISOString(), extra: pickExtra(extra), hold_released: holdGone, dep_used: depUsed,
                 card: { ok: card.ok, code: card.code, tries: card.tries }, deposit: { ok: dep.ok, mem: dep.mem, gen: dep.gen, err: dep.err || undefined }, mark: MARK };
  const meta = { ...c.preMeta, ...c.claimMeta, fail: JSON.parse(JSON.stringify(fail)) };
  let rec = false;
  for (let i = 0; i < 2 && !rec; i++) {
    const r = await sbPatch(`payment_orders?order_id=eq.${enc(c.orderId)}&select=order_id`, { status: card.ok ? 'canceled' : 'paid', fail_reason: fr, metadata: meta });
    rec = !r.err && r.rows.length > 0;
  }
  if (!rec) console.error(LOG, '실패 결과 기록 실패 — 수동 확인', c.orderId, fr);
  if (!card.ok) await alertAdmins(c, 'cancel_failed', code + (rec ? '' : ' · 주문 기록 실패'));
  if (!dep.ok) await alertAdmins(c, 'deposit_failed', code, { owed: dep.owed || c.depositUsed });
  await notifyMemberCanceled(c, code, card.ok, depUsed, dep.ok);
  return json({ ok: false, error: code, refunded: card.ok, deposit_used: depUsed, deposit_refunded: depUsed ? dep.ok : undefined, hold_gone: holdGone,
                orderId: c.orderId, ...pickExtra(extra), reason: reasonText(code, card.ok, depUsed, dep.ok, extra) });
}

// ── 승인 뒤 공통 — 주문 잡기 → (티켓이면) 예치금 차감 · 좌석 전환 · 실패면 정리 ──
//   tb = 토스가 이 주문으로 돌려준 승인 응답(DONE). 결제키는 언제나 토스가 알려 준 값(요청 본문의 값을 믿지 않는다).
//   claimMetaOf(pick) = 주문을 paid 로 잡을 때의 metadata(파일마다 다르다). okExtra = 성공 응답에 덧붙일 것.
async function afterApproval(c: Ctx, tb: any, claimMetaOf: (pick: Record<string, unknown> | null) => Record<string, unknown>, defaultMethod: string | null, okExtra: Record<string, unknown>) {
  const tk = String(tb?.paymentKey || '');
  if (String(tb?.orderId || '') !== c.orderId || !tk) {
    console.warn(LOG, '토스 응답의 주문·결제키가 요청과 다르다 — 손대지 않음', c.orderId);
    await markUnknown(c, 'pending', 'toss_payment_mismatch');
    return json({ ok: false, error: 'processing', retry: true, orderId: c.orderId });
  }
  c.tk = tk;
  const approved = Number(tb.totalAmount ?? tb.balanceAmount ?? 0);
  if (approved !== c.expected) {
    // 결정 9a — 금액이 다르면 승인을 그대로 두지 않는다(종전 toss-confirm 은 취소하지 않고 failed 로 덮었다 — 돈이 결제 내역에서도 사라졌다)
    console.error(LOG, '승인 금액 불일치', c.orderId, approved, c.expected);
    const card = await cancelTossFull(c.secret, tk, CANCEL_REASON.amount_mismatch_toss);
    await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=in.(pending,failed)`, { status: card.ok ? 'canceled' : 'paid', payment_key: tk,
      fail_reason: 'amount_mismatch_toss' + (card.ok ? '_refunded' : '_refund_failed'),
      metadata: { ...c.preMeta, toss: pickToss(tb), fail: { code: 'amount_mismatch_toss', approved, at: new Date().toISOString(), card: { ok: card.ok, code: card.code, tries: card.tries }, mark: MARK } } });
    if (!card.ok) await alertAdmins(c, 'cancel_failed', 'amount_mismatch_toss');
    return json({ ok: false, error: 'amount_mismatch_toss', refunded: card.ok, orderId: c.orderId, reason: reasonText('amount_mismatch_toss', card.ok, false, true, {}) });
  }
  // ── 주문을 paid 로 잡는다(동시 요청 중 하나만 · 이 호출의 표시 nonce 로 「내가 잡았나」를 가린다) ──
  const isTk = c.order.purpose === 'ticket_topup';
  c.nonce = (globalThis.crypto && typeof crypto.randomUUID === 'function') ? crypto.randomUUID().slice(0, 12) : String(Date.now());
  c.claimMeta = { ...claimMetaOf(pickToss(tb)), claim_nonce: c.nonce };
  const claimBody: Record<string, unknown> = { status: 'paid', payment_key: tk, method: tb.method || defaultMethod, receipt_url: tb.receipt?.url || null,
    approved_at: tb.approvedAt || new Date().toISOString(), metadata: c.claimMeta, fail_reason: isTk ? 'unknown:converting:' + c.nonce : null };
  let state = '', dbFail = false;
  for (let i = 0; i < 3 && !state; i++) {
    if (i) await sleep(400 * i);
    const r = await sbPatch(`payment_orders?order_id=eq.${enc(c.orderId)}&status=eq.pending&select=order_id`, claimBody);
    if (!r.err) { state = r.rows.length ? 'claimed' : 'reread'; break; }
    if (isDb(r.err) && !isTransient(r.err)) dbFail = true;
  }
  if (state !== 'claimed') {
    const g = await sbGet(`payment_orders?order_id=eq.${enc(c.orderId)}&select=order_id,status,fail_reason,payment_key,metadata`);
    const o = g && g[0];
    if (!o) {
      await markUnknown(c, 'pending', 'claim_unknown');
      return json({ ok: false, error: 'processing', retry: true, paid: true, orderId: c.orderId });
    }
    if (o.status === 'paid') {
      if (String(o.metadata?.claim_nonce || '') === c.nonce) state = 'claimed';   // 응답만 잃었다 — 내가 잡았다
      else return json({ ok: false, error: 'processing', retry: true, paid: true, orderId: c.orderId });   // 다른 호출이 잡아 처리 중이다
    } else if (o.status === 'pending') {
      if (dbFail) return json({ ok: false, error: 'order_update_failed', retry: true, paid: true, orderId: c.orderId });   // 다시 부르면 같은 승인으로 다시 잡는다(멱등 키)
      await markUnknown(c, 'pending', 'claim_unknown');
      return json({ ok: false, error: 'processing', retry: true, paid: true, orderId: c.orderId });
    } else {
      // 이 승인의 주문이 이미 닫혔다(failed·canceled) — 승인을 그대로 두지 않는다(적대 리뷰 H1: 옛 판이 애매한 응답을 failed 로 굳혔다)
      const rep = closedReport(o);
      const card = await cancelTossFull(c.secret, tk, CANCEL_REASON.order_closed);
      if (rep && card.ok) return json(rep);
      await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=in.(failed,canceled)`, { status: card.ok ? 'canceled' : 'paid', payment_key: tk,
        fail_reason: 'order_closed' + (card.ok ? '_refunded' : '_refund_failed'),
        metadata: { ...(o.metadata || {}), fail: { code: 'order_closed', prev: String(o.fail_reason || '').slice(0, 60), at: new Date().toISOString(), card: { ok: card.ok, code: card.code, tries: card.tries }, mark: MARK } } });
      if (!card.ok) await alertAdmins(c, 'cancel_failed', 'order_closed');
      return json({ ok: false, error: 'order_closed', refunded: card.ok, orderId: c.orderId, reason: reasonText('order_closed', card.ok, false, true, {}) });
    }
  }
  if (!isTk) {
    if (c.order.purpose === 'deposit_charge') {
      await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}`, { fail_reason: 'deposit_charge_disabled' });
      return json({ ok: false, error: 'deposit_charge_disabled', paid: true, orderId: c.orderId });
    }
    return json({ ok: true, orderId: c.orderId, amount: c.expected, purpose: c.order.purpose });
  }
  // ── 티켓 부족분 — 예치금 차감 → 좌석 전환 ──
  const pre = c.preMeta, total = Number(pre.total || 0);
  const cardPaid = c.cur === 'KRW' ? c.expected : (Number(c.order.settle_krw) || 0);
  let known: { fromMem: number; fromGen: number; ambiguous?: boolean } | undefined;
  try {
    let deposited = 0;
    if (c.depositUsed > 0) {
      const ded = await deductDeposit(c.uid, c.depositUsed, { purchase_id: c.holdId, ticket_id: pre.ticket_id, restaurant_name: pre.restaurant_name, party_size: pre.pax, order_id: c.orderId });
      known = { fromMem: ded.fromMem, fromGen: ded.fromGen, ambiguous: !!ded.ambiguous };
      if (ded.ambiguous) return await failAfterApproval(c, 'convert_failed', {}, { holdAlive: true, depAmbiguous: true, known });
      if (ded.short) return await failAfterApproval(c, 'deposit_short', { deducted: 0, needed: c.depositUsed }, { holdAlive: true, known });
      if (ded.failed || ded.deducted < c.depositUsed) return await failAfterApproval(c, ded.failed ? 'convert_failed' : 'deposit_short', ded.failed ? {} : { deducted: ded.deducted, needed: c.depositUsed }, { holdAlive: true, known });
      deposited = ded.deducted;
    }
    const conv = await convertHoldToActive(c, total, cardPaid, deposited);
    if (conv.ok) {
      // 이 호출의 표시를 지운다(다른 값이 그 사이 적혔으면 손대지 않는다)
      await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&fail_reason=eq.${enc('unknown:converting:' + c.nonce)}`, { fail_reason: null });
      await background(notifyPurchase(c.uid, { rest: String(pre.restaurant_name || '티켓'), pax: Number(pre.pax || 0), amount: cardPaid, purchaseId: String(conv.purchaseId) }));
      return json({ ok: true, orderId: c.orderId, amount: c.expected, purpose: 'ticket_topup', total, depositUsed: deposited, cardPaid, purchaseId: conv.purchaseId, ...okExtra });
    }
    if (conv.ambiguous) {
      // 좌석이 붙었는지 모른다 — 돌려주지도 취소하지도 않는다(티켓이 있을 수 있다 · 공짜 티켓 방지)
      console.warn(LOG, '좌석 전환 결과 모름 — 취소하지 않음', c.orderId, conv.stage);
      await markUnknown(c, 'paid', 'convert');
      return json({ ok: false, error: 'processing', paid: true, orderId: c.orderId });
    }
    console.warn(LOG, '좌석 전환 거절', c.orderId, conv.code, String(conv.msg || '').slice(0, 160));
    return await failAfterApproval(c, conv.code || 'convert_failed', conv.extra || {}, { holdAlive: !!conv.holdAlive, known });
  } catch (e) {
    console.error(LOG, '승인 뒤 처리 예외', c.orderId, String((e as Error)?.message || e).slice(0, 160));
    await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=eq.paid`, { fail_reason: 'unknown:exception' });
    await alertAdmins(c, 'pending', 'exception');
    return json({ ok: false, error: 'processing', paid: true, orderId: c.orderId });
  }
}

// ── 다시 부른 호출 — 주문이 이미 pending 이 아니다(결제창 복귀 URL 은 새로고침·뒤로가기·앱 링크로 여러 번 열린다) ──
//   결과 꼬리가 있으면 그 결과 · 실패로 굳은 주문의 승인이 토스에 남았으면 취소(H1) · paid 면 티켓부터 본다(H5) · 결과 모름이면 「확인 중」(오래되면 한 번 알림)
async function onClosedOrder(c: Ctx) {
  const o = c.order;
  if (o.purpose !== 'ticket_topup') {
    if (o.status === 'paid') return json({ ok: true, already: true, orderId: c.orderId, amount: c.expected, purpose: o.purpose });
    return json({ ok: false, error: 'order_not_pending', status: o.status });
  }
  const rep = closedReport(o);
  if (rep) return json(rep);
  if (o.status === 'failed') {
    // 실패로 굳은 주문 — 승인이 실제로 됐는지 토스에 주문 번호로 묻는다. DONE 이면 그대로 둘 수 없다(전액 취소 + 알림)
    if (!/^unknown:|amount_mismatch_client/.test(String(o.fail_reason || ''))) {
      const lk = await tossLookup(c.secret, '', c.orderId);
      if (lk.done) {
        c.tk = String(lk.body.paymentKey || '');
        const card = await cancelTossFull(c.secret, c.tk, CANCEL_REASON.order_closed);
        await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=eq.failed`, { status: card.ok ? 'canceled' : 'paid', payment_key: c.tk,
          fail_reason: 'order_closed' + (card.ok ? '_refunded' : '_refund_failed'),
          metadata: { ...(o.metadata || {}), fail: { code: 'order_closed', prev: String(o.fail_reason || '').slice(0, 60), at: new Date().toISOString(), card: { ok: card.ok, code: card.code, tries: card.tries }, mark: MARK } } });
        if (!card.ok) await alertAdmins(c, 'cancel_failed', 'order_closed');
        return json({ ok: false, already: true, error: 'order_closed', refunded: card.ok, orderId: c.orderId, reason: reasonText('order_closed', card.ok, false, true, {}) });
      }
    }
    return json({ ok: false, error: 'order_not_pending', status: 'failed' });
  }
  if (o.status !== 'paid') return json({ ok: false, error: 'order_not_pending', status: o.status });
  const fr = String(o.fail_reason || '');
  const has = await orderTicketAny(c.uid, c.orderId);
  if (has === true) {
    if (fr.startsWith('unknown:')) await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&fail_reason=eq.${enc(fr)}`, { fail_reason: null });
    return json({ ok: true, already: true, orderId: c.orderId, amount: c.expected, purpose: o.purpose });
  }
  if (fr.startsWith('unknown:')) {
    const t0 = Date.parse(String(o.approved_at || o.updated_at || o.created_at || ''));
    if (has === false && Number.isFinite(t0) && Date.now() - t0 > 180000 && !/:alerted$/.test(fr)) {
      const r = await sbPatch(`payment_orders?order_id=eq.${enc(c.orderId)}&fail_reason=eq.${enc(fr)}&select=order_id`, { fail_reason: fr.slice(0, 200) + ':alerted' });
      if (r.rows.length) await alertAdmins(c, 'pending', fr.replace(/^unknown:/, '').replace(/:[0-9a-f-]{6,}$/, '').slice(0, 40));
    }
    return json({ ok: false, error: 'processing', paid: true, orderId: c.orderId });
  }
  if (fr) return json({ ok: false, error: fr.split(':')[0].slice(0, 60), paid: true, orderId: c.orderId });
  return json({ ok: false, error: 'processing', paid: true, orderId: c.orderId });
}

// ── 구매 성공 → 슈퍼어드민(벨 + 푸시) — 카드 결제는 승인이 서버에서 끝나므로 서버가 보낸다 ──
async function notifyPurchase(buyerId: string, info: { rest: string; pax: number; amount: number; purchaseId: string }) {
  let who = await buyerName(buyerId);
  if (who === '회원' || /^회원 \d{4}$/.test(who)) {
    try { const tk = await sbGet(`tickets?purchase_id=eq.${enc(info.purchaseId)}&select=buyer_name&limit=1`); if (tk && tk[0]?.buyer_name && String(tk[0].buyer_name).trim()) who = String(tk[0].buyer_name).trim().slice(0, 40); } catch (_e) { /* 장식 */ }
  }
  const body = who + '님 · ' + info.rest + (info.pax ? ' · ' + info.pax + '인' : '') + ' · ₩' + Number(info.amount || 0).toLocaleString('en-US') + ' (카드)';
  const title = '🎫 ' + who + '님이 티켓을 구매했습니다';
  try {
    const sups = await sbGet(`profiles?role=in.(superadmin,super_admin)&select=id`) || [];
    const rows = sups.filter((p: any) => p.id !== buyerId).map((p: any) => ({ user_id: p.id, type: 'ticket_purchased', title, body, url: '/',
      payload: { purchase_id: info.purchaseId, pax: info.pax, amount: info.amount, buyer: who, paid_by: 'card', actor_id: buyerId, via: VIA } }));
    if (rows.length) await sbReq('POST', 'notifications', rows, 'return=minimal');
  } catch (_e) { /* 이력은 부가 */ }
  await pushSuper(title, body, 'ticket_purchased', 'taam-tpurchase-' + info.purchaseId);
}

// CORS — 우리 오리진만 허용한다(Bearer 라 자격이 자동으로 실리진 않지만, 다른 오리진에서 회원 세션으로 부르는 것을 브라우저가 막게)
const TAAM_ORIGINS = ['https://taam-app.vercel.app', 'https://playtaam.com', 'https://www.playtaam.com'];
function taamOrigin(req: Request): string {
  const o = req.headers.get('Origin') || '';
  if (TAAM_ORIGINS.includes(o) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)) return o;
  return TAAM_ORIGINS[0];
}
// ═══════════ CARD_FAIL_V2 공통 블록 끝 ═══════════

const MID_BILLING = '등록 카드 MID(bill_taam315)';

async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    // 빌링은 자동결제 MID(bill_taam315) 전용 키를 쓴다 — 일반결제 MID 키로 빌링 API 를 부르면 「자동결제 계약이 없다」로 거절된다.
    //   두 MID 의 시크릿이 같은 환경도 있으므로 TOSS_SECRET_KEY 로 폴백한다.
    const secret = Deno.env.get('TOSS_BILLING_SECRET_KEY') || Deno.env.get('TOSS_SECRET_KEY') || '';
    if (!secret) {
      console.error(LOG, 'TOSS_BILLING_SECRET_KEY / TOSS_SECRET_KEY 둘 다 미설정');
      return json({ ok: false, error: 'server_not_configured' });
    }
    const body = await req.json().catch(() => ({})) as Record<string, any>;
    const orderId = String(body.orderId || '').trim();
    const orderName = String(body.orderName || '티켓 구매').slice(0, 100);
    if (!orderId || orderId.length > 80) return json({ ok: false, error: 'missing_params' });

    const me = await caller(req);
    if (!me) return json({ ok: false, error: 'unauthorized' }, 401);

    // ── 주문 ──
    const rows = await sbGet(`payment_orders?order_id=eq.${enc(orderId)}&select=*`);
    if (rows === null) { console.error(LOG, '주문 조회 실패', orderId); return json({ ok: false, error: 'order_lookup_failed', retry: true }); }
    const order = rows[0];
    if (!order) return json({ ok: false, error: 'order_not_found' });
    if (order.user_id !== me.id) {
      console.warn(LOG, '주문 소유자 불일치', orderId);
      return json({ ok: false, error: 'order_forbidden' }, 403);
    }
    const c = ctxOf(order, me.id, secret, MID_BILLING);
    if (order.status !== 'pending') return await onClosedOrder(c);

    const expected = Number(order.amount);
    if (!(expected > 0)) return json({ ok: false, error: 'amount_invalid' });
    // 🔒 2026-09-13: 빌링키는 국내(원화) 결제수단이다. 외화 주문(amount 가 $·¥)을 그대로 승인하면 ₩892 를 내고 $892 티켓이 확정된다.
    const orderCur = String(order.currency || 'KRW').toUpperCase();
    if (orderCur !== 'KRW') {
      console.warn(LOG, '외화 주문은 빌링 청구 불가', orderId, orderCur);
      return json({ ok: false, error: 'currency_not_supported', currency: orderCur });
    }

    // ── 결제수단(빌링키) — 기본카드 우선, 없으면 가장 최근 등록 카드 ──
    //   🔧 2026-10-13 customer_key 컬럼은 라이브 표에 없다(toss_customer_key 가 있다) — 읽으면 조회가 42703 으로 실패한다.
    //   customerKey 는 등록 때 toss-billing-issue 가 auth uid 와 같음을 강제하므로 user id 를 쓴다.
    const cards = await sbGet(`billing_keys?user_id=eq.${enc(me.id)}&deleted_at=is.null&select=id,billing_key,card_company,card_number,is_default&order=is_default.desc,created_at.desc&limit=1`);
    if (cards === null) { console.error(LOG, '카드 조회 실패'); return json({ ok: false, error: 'card_lookup_failed' }); }
    const card = cards[0];
    if (!card) return json({ ok: false, error: 'no_billing_key' });

    // ── 청구를 요청하기 **전에** 「결과 모름」 표시 ──
    if (!String(order.fail_reason || '').startsWith('unknown:')) {
      const mk = await sbPatch(`payment_orders?order_id=eq.${enc(orderId)}&status=eq.pending&select=order_id`, { fail_reason: 'unknown:approving' });
      if (mk.err) return json({ ok: false, error: 'order_lookup_failed', retry: true });
      if (!mk.rows.length) {
        const ag = await sbGet(`payment_orders?order_id=eq.${enc(orderId)}&select=*`);
        if (!ag || !ag[0]) return json({ ok: false, error: 'order_lookup_failed', retry: true });
        return await onClosedOrder(ctxOf(ag[0], me.id, secret, MID_BILLING));
      }
      order.fail_reason = 'unknown:approving';
    }

    // ── 빌링 승인 — Idempotency-Key 를 orderId 로 고정해 재시도해도 두 번 결제되지 않게 한다 ──
    const charge = () => tossCall(secret, `/v1/billing/${enc(card.billing_key)}`, 'POST',
      { customerKey: me.id, amount: expected, orderId, orderName, customerEmail: me.email || undefined }, `taam-billing-${orderId}`);
    let t = await charge();
    if (!t.ok || t.body?.status !== 'DONE') {
      let firstAmb = false;
      if (tossAmbiguous(t)) {
        // 같은 키로 한 번 더(토스가 같은 결과를 돌려준다) — 그래도 애매하거나, 이번엔 분명한 응답이어도 첫 청구가 애매했으면 주문 번호로 조회한다
        firstAmb = true;
        await sleep(800);
        t = await charge();
      }
      if (!t.ok || t.body?.status !== 'DONE') {
        if (firstAmb || tossAmbiguous(t)) {
          const lk = await tossLookup(secret, '', orderId);
          if (lk.done) t = { ok: true, status: 200, body: lk.body };
          else if (tossAmbiguous(t) || !lk.gone) {
            // 끝내 모른다 — 실패로 굳히지 않는다(늦게 완료된 청구가 있을 수 있다 · 패키지 3차 검증과 같은 교훈).
            //   다시 한 청구가 분명한 응답이어도(DUPLICATED_ORDER_ID 등) 첫 청구가 애매했고 조회도 답을 못 했으면 모르는 것이다.
            //   분명히 실패로 굳히는 것은 「다시 한 청구가 분명히 거절 + 조회가 그 주문의 결제가 없다(404·끝남)」뿐이다
            const code = String(t.body?.code || ('http_' + t.status)).slice(0, 40);
            if (code !== 'IDEMPOTENT_REQUEST_PROCESSING') await markUnknown(c, 'pending', 'toss_billing_' + code);
            return json({ ok: false, error: 'processing', retry: true, orderId });
          }
        }
      }
      if (!t.ok || t.body?.status !== 'DONE') {
        const reason = String(t.body?.message || t.body?.code || ('http_' + t.status)).slice(0, 300);
        console.warn(LOG, '승인 실패', orderId, reason.slice(0, 160));
        await sbReq('PATCH', `payment_orders?order_id=eq.${enc(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: reason });
        return json({ ok: false, error: 'charge_failed', reason: reason.slice(0, 200) });
      }
    }

    // ── 승인 뒤 — 주문 잡기 · 예치금 · 좌석 (공통 블록) ──
    //   주문 metadata 는 종전처럼 합친다(주문 때 서버가 적은 값 + 토스 응답 고른 칸 + 결제 경로)
    return await afterApproval(c, t.body, (pick) => ({ ...c.preMeta, toss: pick, paid_via: 'billing_key', billing_key_id: card.id }), 'billing',
      { card: { company: card.card_company, number: card.card_number } });
  } catch (e) {
    console.error(LOG, '예외', String((e as Error)?.message || e).slice(0, 200));
    return json({ ok: false, error: 'exception' });   // 원문은 로그에만 (2026-09-14)
  }
}

Deno.serve(async (req: Request) => {
  const res = await handle(req);
  try { res.headers.set('Access-Control-Allow-Origin', taamOrigin(req)); res.headers.append('Vary', 'Origin'); } catch (_e) { /* 헤더 잠긴 응답이면 그대로 */ }
  return res;
});
