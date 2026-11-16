// ════════════════════════════════════════════════════════════
// toss-confirm — 토스페이먼츠 결제 승인 Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-08 · 2026-11-15 카드 후속(CARD_FAIL_V2_20261115) — 아래 「공통 블록」 머리말
//
// 토스 V2 결제는 2단계다.
//   ① 브라우저에서 결제창 인증 (클라이언트 키) → paymentKey 발급
//   ② 서버에서 승인 confirm (시크릿 키)  ← 이 함수
// ②가 없으면 회원이 카드 인증을 마쳐도 실제 승인이 일어나지 않고
// 미승인 건으로 자동 취소된다. 회원에게는 "결제했는데 아무것도 안 됨"이 된다.
//
// 이 함수가 지키는 것
//   · 금액 위변조 차단 — 브라우저가 보낸 금액이 아니라 payment_orders.amount 를 신뢰한다
//   · 소유권 확인    — 주문의 user_id 와 호출자 JWT 의 uid 가 같아야 한다
//   · 멱등성         — 이미 처리된 주문은 다시 처리하지 않는다 (새로고침·뒤로가기 대비) · 실패한 주문을 「이미 처리됨 ✅」로 답하지 않는다
//   · 부분 실패 방지 — 승인 뒤 확정에 실패하면 예치금을 원장 근거로 되돌리고 카드를 전액 취소하고, 못 하면 슈퍼어드민에게 알린다
//   · 애매한 승인 응답(5xx · 409 · 처리 중 · 네트워크)은 실패로 굳히지 않는다 — 결제를 조회해 DONE 이면 잇는다
//   · {action:'sweep'}(서버 토큰만 · DB 크론 taam_card_topup_reconcile_kick 10분) — 결과를 모르는 티켓 카드 주문(결제창·등록 카드 모두)을 토스에 조회해 잇거나 정리한다
//     (그래서 이 함수는 TOSS_BILLING_SECRET_KEY 도 읽는다 — 프로젝트 시크릿은 모든 함수가 같이 본다)
//
// 필요한 시크릿 (Supabase Dashboard → Edge Functions → Secrets)
//   TOSS_SECRET_KEY     = live_sk_...   국내 MID(playtauif6)
//   TOSS_SECRET_KEY_USD = live_sk_...   해외 MID(playtaamusd) — USD 승인 · KRW 정산
//   TOSS_SECRET_KEY_JPY = live_sk_...   해외 MID(playtaamjpy) — JPY 승인 · KRW 정산
//   ⚠ 코드·커밋에 절대 넣지 말 것
//
// 외화 주문(USD/JPY)의 원칙 — docs/TOSS_GOLIVE.md
//   승인은 주문의 통화·금액(amount·currency) 그대로, 원화 쪽 정산(예치금 차감·티켓
//   확정·기록)은 주문 생성 때 서버가 얼려둔 settle_krw 로 한다. 둘을 섞지 않는다.
// ⚠ toss-billing-charge/index.ts 와 공통 블록이 같아야 한다 — 한쪽만 고치지 말 것.
// ════════════════════════════════════════════════════════════

const VER = 'tc-2026-11-15';
const LOG = '[toss-confirm]';
const VIA = 'toss-confirm';

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
// 2026-11-16 적대 리뷰 반영(배포 전)
//   · 되돌림은 「이 호출이 실제로 뺀 금액」까지만(CF-1) — 차감이 분명히 0(예치금 부족·거절)이면 되돌림을 부르지 않는다 · 응답을 잃은 차감만 「낼 몫」이 상한.
//     뺀 금액은 주문 metadata.card_dep 에 서버가 적는다(payment_orders 는 회원이 못 쓴다) — 다시 부른 호출·정리 크론이 그 기록으로 잇는다.
//     서버 함수는 홀드 구매 id 한 통으로 센다(회원 환불 한도와 같은 통 · 위조 줄·회원 자기 환불을 두 번 돌려주지 않는다 · CF-2).
//   · 알림 금액을 지어내지 않는다(CF-3) — 모르면 「금액 확인 필요」 · 늦은 차감 재확인만 실패하면 「원장 확인」 알림(되돌린 몫은 그대로 되돌린 것).
//   · 함수가 없을 때(SQL 미적용)의 옛 되돌림은 이 호출이 분명히 뺀 몫에만 · 결과를 모르면 실패로(성공으로 덮지 않는다 · CF-4).
//   · 확정이 막혀 돈을 돌리기 전에 이 주문의 티켓이 늦게 생겼는지 다시 본다(CF-5 방어) · 애매하게 끝난 전환은 실패로 굳히지 않는다.
//   · 결과 모르는(unknown:*) 주문은 10분 정리(sweep — taam_card_topup_reconcile_kick → toss-confirm)가 토스에 조회해 잇거나 정리한다(CF-6 · TOSSRB-1).
//     실패 정리 중 끊긴 주문(unknown:failing:<코드>)은 다시 부른 호출도 이어 간다(TOSSRB-3) · 같은 홀드에 결과 모르는 주문이 있으면 새로 승인하지 않는다(TOSSRB-2).
//   · 응답에 mark(새 Edge 표시)를 싣는다 — 앱은 다시 물어 받은 「이미 처리」를 이 표시가 있을 때만 믿는다(CFAPP-2 · 옛 Edge 는 실패한 주문도 already 로 답했다).
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
  return new Response(JSON.stringify({ ...body, ver: VER, mark: MARK }), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
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
// 서버 호출(정리 크론 · DB 의 pg_net)인가 — 토큰의 role 클레임이 service_role. 서명은 게이트웨이(verify_jwt=true · config.toml)가 이미 확인했다(toss-invite-pay 와 같은 방식)
function isServiceToken(req: Request): boolean {
  const h = req.headers.get('Authorization') || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!t) return false;
  if (SERVICE_KEY && t === SERVICE_KEY) return true;
  try { const p = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); return !!p && p.role === 'service_role'; } catch (_e) { return false; }
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
  midLabel: string; holdId: string; depositUsed: number; claimMeta: Record<string, unknown>; nonce: string; cdep: Record<string, any>;
};
// 예치금 차감 결과 — taken: 이 호출(또는 서버 기록)이 뺀 금액 · null = 모른다(응답을 잃었다) · fresh: 이 호출이 방금 본 결과(서버 기록에서 되살린 것이 아님)
type Known = { taken: number | null; mem: number; gen: number; fresh?: boolean };
function ctxOf(order: any, uid: string, secret: string, midLabel: string): Ctx {
  const pre = (order?.metadata && typeof order.metadata === 'object') ? order.metadata : {};
  // card_dep — 잡을 때·차감 뒤 서버(이 함수)가 적는 기록. toss-confirm 은 잡을 때 metadata 를 {toss} 로 덮으므로 홀드·낼 몫도 여기서 되살린다
  const cd = (pre.card_dep && typeof pre.card_dep === 'object') ? pre.card_dep : {};
  const du = (pre.deposit_used !== undefined && pre.deposit_used !== null) ? pre.deposit_used : cd.plan;
  return { order, preMeta: pre, uid, orderId: String(order?.order_id || ''), secret, tk: String(order?.payment_key || ''),
           cur: String(order?.currency || 'KRW').toUpperCase(), expected: Number(order?.amount || 0), midLabel,
           holdId: String(pre.hold_purchase_id || cd.hold || ''), depositUsed: Math.max(0, Number(du || 0)), claimMeta: {}, nonce: '', cdep: cd };
}
// 서버 기록(card_dep)에서 차감 결과를 되살린다 — 다시 부른 호출·정리 크론용(이 호출이 뺀 것이 아니므로 fresh 아님)
function knownFromRecord(c: Ctx): Known {
  const cd = c.cdep || {};
  const n = (v: unknown) => (Number.isFinite(Number(v)) && Number(v) >= 0) ? Math.round(Number(v)) : 0;
  if (cd.state === 'taken') return { taken: n(cd.taken), mem: n(cd.mem), gen: n(cd.gen) };
  if (cd.state === 'none') return { taken: 0, mem: 0, gen: 0 };
  return { taken: null, mem: 0, gen: 0 };   // 'deducting' 또는 기록 없음 — 모른다(상한은 낼 몫)
}
// 차감 결과를 주문에 적는다(payment_orders — 회원은 못 쓴다) · 되돌림 상한의 서버 근거. 실패해도 진행한다(이 호출은 p_cap 으로 넘긴다)
async function recordDep(c: Ctx, k: Known) {
  if (!(c.claimMeta && typeof c.claimMeta === 'object')) return;
  const cd: Record<string, unknown> = { ...((c.claimMeta as any).card_dep || {}) };
  if (k.taken === null) cd.state = 'deducting';
  else { cd.state = k.taken > 0 ? 'taken' : 'none'; cd.taken = k.taken; cd.mem = k.mem; cd.gen = k.gen; cd.at = new Date().toISOString(); }
  c.claimMeta = { ...c.claimMeta, card_dep: cd };
  c.cdep = cd;
  const r = await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=eq.paid`, { metadata: c.claimMeta });
  if (r.err) console.warn(LOG, '차감 기록 실패(진행)', c.orderId, r.err.pgCode || r.err.status);
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
//   deposit_check: 되돌림은 했는데 「늦게 들어온 차감」 재확인만 실패(원장 확인 · 금액 없음) · record_failed: 정리는 끝났는데 주문에 결과를 못 적음
async function alertAdmins(c: Ctx, kind: 'cancel_failed' | 'deposit_failed' | 'pending' | 'deposit_check' | 'record_failed', code: string, info?: Record<string, unknown>) {
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
      // 금액은 이 호출이 분명히 뺀 것을 알 때만 적는다 — 결과를 모르는 차감·이미 돌려준 몫을 「못 돌려줬다」고 적으면 운영자가 한 번 더 준다(CF-3)
      type = 'ledger_apply_failed';
      title = '🔴 예치금 환원 실패 — 수동 확인 필요';
      body = where + ' — 카드 결제 실패로 돌려줘야 할 예치금' + (info && Number(info.owed) > 0 ? ' ₩' + Number(info.owed).toLocaleString('en-US') : '(금액은 회원 원장에서 확인)') + ' 을(를) 돌려주지 못했습니다. 회원 원장에서 이 구매(' + (c.holdId || '구매 id 없음') + ')의 차감·환원 줄을 확인한 뒤 「예치금 부여」로 돌려주세요.';
    } else if (kind === 'deposit_check') {
      type = 'card_deposit_check';
      title = '🟠 카드 결제 취소 — 예치금 원장 확인 필요';
      body = where + ' — 예치금은 되돌렸지만, 응답을 잃었던 차감이 늦게 들어왔는지 다시 세지 못했습니다. 회원 원장에서 이 구매(' + (c.holdId || '구매 id 없음') + ')의 차감·환원 줄이 같은지 확인해 주세요(다르면 그 차액만 「예치금 부여」).';
    } else if (kind === 'record_failed') {
      title = '⚠ 카드 결제 정리 결과 기록 실패';
      body = where + ' — 카드 취소·예치금 정리는 끝났지만 주문에 결과를 적지 못했습니다. 결제 내역에서 이 주문이 「결과 모름」으로 보이면 토스 상점관리자(취소 여부)와 회원 원장을 확인해 주세요.';
    } else {
      title = '⚠ 카드 결제 결과 확인 필요';
      body = where + ' — 카드 승인 또는 티켓 확정 결과를 모릅니다. 10분마다 서버가 토스에 다시 물어 승인됐으면 이어서 처리하고, 확정이 안 되면 카드를 취소하고 예치금을 되돌립니다. 그래도 남아 있으면 토스 상점관리자(승인 여부)와 결제 내역·회원 원장(티켓·예치금)을 확인해 주세요. 이 결과가 나기 전에는 같은 좌석으로 새 카드 결제를 받지 않습니다.';
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
// 회원 알림함 — 결과를 몰라 「확인 중」으로 안내했던 결제를 정리 크론이 이어서 확정했다(세 벌 · payload.i18n)
async function notifyMemberConfirmed(c: Ctx) {
  try {
    const rest = String(c.preMeta.restaurant_name || c.cdep?.rname || '').slice(0, 60);
    const ko = { title: '카드 결제가 확인되었습니다', body: (rest ? rest + ' · ' : '') + '확인 중이던 결제가 승인되어 예약이 확정되었습니다. 구매 내역에서 확인하실 수 있습니다.' };
    const en = { title: 'Your card payment was confirmed', body: (rest ? rest + ' · ' : '') + 'The payment we were checking went through and your booking is confirmed. You can see it in your purchase history.' };
    const ja = { title: 'カード決済が確認されました', body: (rest ? rest + ' · ' : '') + '確認中だった決済が承認され、ご予約が確定しました。購入履歴でご確認いただけます。' };
    await sbReq('POST', 'notifications', [{ user_id: c.uid, type: 'card_payment_confirmed', title: ko.title, body: ko.body, url: '/?open_ticket_hist=1',
      payload: { order_id: c.orderId, via: VIA, i18n: { ko, en, ja } } }], 'return=minimal');
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
// 되돌림 — 서버 함수(원장 근거 · 홀드 구매 id 한 통 · 멱등)를 최대 3번. cap = 이 호출이 뺀 금액(모르면 낼 몫) — 그 이상은 돌려주지 않는다(CF-1).
//   함수가 아직 없으면(SQL 미적용) 이 호출이 **방금 분명히** 뺀 몫만 옛 방식으로 한 번(결과를 모르면 실패 · 서버 기록에서 되살린 몫은 옛 방식으로 안 한다 — 두 번 줄 수 있다 · CF-4)
async function settleDeposit(c: Ctx, code: string, cap: number, known?: Known):
  Promise<{ ok: boolean; mem: number; gen: number; err?: string }> {
  const waits = [0, 500, 1500];
  let last = '';
  for (let i = 0; i < 3; i++) {
    if (waits[i]) await sleep(waits[i]);
    const r = await sbRpc('taam_card_order_settle', { p_order: c.orderId, p_user: c.uid, p_cap: Math.max(0, Math.round(cap)), p_purchase_id: c.holdId || null,
      p_code: code, p_why: '카드 결제 취소(' + (CANCEL_REASON[code] || code) + ') · 예치금 환원' });
    if (!r.err) {
      const d = r.data || {};
      return { ok: true, mem: Number(d.refunded_mem || 0), gen: Number(d.refunded_gen || 0) };
    }
    last = r.err.pgCode || (r.err.status ? 'http_' + r.err.status : 'network');   // 코드만 — 회원이 읽는 주문 metadata 에 DB 오류 원문을 남기지 않는다(M5)
    if (r.err.pgCode === 'PGRST202' || r.err.pgCode === '42883') {
      // 서버 함수가 아직 없다 — 이 호출이 방금 분명히 뺀 몫만 옛 방식으로
      if (!known || !known.fresh || known.taken === null) return { ok: false, mem: 0, gen: 0, err: 'settle_missing' };
      if (known.taken <= 0) return { ok: true, mem: 0, gen: 0 };
      const md = { order_id: c.orderId, purchase_id: c.holdId || undefined, card_fail_code: code };
      const ent: Record<string, unknown>[] = [];
      if (known.mem > 0) ent.push({ deposit_type: 'membership', change_type: 'ticket_refund', amount: known.mem, description: '카드 결제 취소 · 예치금 환원', metadata: md });
      if (known.gen > 0) ent.push({ deposit_type: 'general', change_type: 'ticket_refund', amount: known.gen, description: '카드 결제 취소 · 예치금 환원', metadata: md });
      const o = await sbRpc('taam_apply_deposit_delta', { p_user_id: c.uid, p_mem_delta: known.mem, p_gen_delta: known.gen, p_entries: ent });
      return o.err ? { ok: false, mem: 0, gen: 0, err: 'legacy_refund_failed' } : { ok: true, mem: known.mem, gen: known.gen };
    }
    if (isDb(r.err) && !isTransient(r.err)) break;   // 분명한 거절(주문·회원 불일치 · 이 주문의 티켓이 살아 있음 등) — 다시 해도 같다
  }
  console.error(LOG, '예치금 되돌림 실패 — 수동 확인 필요', c.orderId, last);
  return { ok: false, mem: 0, gen: 0, err: last || 'settle_failed' };
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
          if (amb) {
            const s2 = await holdState(c.uid, c.holdId, c.orderId, tid, pax);
            if (s2 === 'mine') return ok(c.holdId);
            // 앞 시도의 응답을 잃었는데 마지막도 일시 오류였거나 지금 상태를 못 읽었다 — 그 문장이 늦게 커밋될 수 있다(실패로 굳히지 않는다 · CF-5 방어)
            if (isTransient(r.err) || s2 === null) return { ok: false, ambiguous: true, stage: 'update_transient' };
          }
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
      if (amb && isTransient(r.err)) return { ok: false, ambiguous: true, stage: 'insert_transient' };   // CF-5 방어 — 응답을 잃은 앞 시도가 늦게 커밋될 수 있다
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
//   ① 표시(failing) ② 살아 있는 홀드 반납 ③ 이 주문의 티켓이 늦게 생겼는지 다시 본다(생겼으면 성공 · 못 읽으면 손대지 않는다 — CF-5 방어)
//   ④ 예치금 되돌림 — 이 호출이 뺀 만큼까지(차감이 분명히 0 이면 부르지 않는다 · 결과를 모르면 낼 몫까지 — CF-1) ⑤ 카드 전액 취소
//   ⑥ (차감 응답을 잃었으면) 되돌림 한 번 더 ⑦ 주문에 결과 ⑧ 알림(금액은 아는 것만 — CF-3).
//   다시 부른 호출·정리 크론은 known 없이 부른다 — 서버 기록(card_dep)에서 되살린다(TOSSRB-3).
async function failAfterApproval(c: Ctx, code: string, extra: Record<string, unknown>, o: { holdAlive: boolean; known?: Known }) {
  console.warn(LOG, '승인 뒤 확정 실패', c.orderId, code);
  await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&status=eq.paid`, { fail_reason: 'unknown:failing:' + code });
  if (c.order) c.order.fail_reason = 'unknown:failing:' + code;
  let holdGone = !o.holdAlive;
  if (o.holdAlive && c.holdId) holdGone = (await releaseHold(c.uid, c.holdId)) !== null;
  // ③ 돈을 돌리기 전에 — 응답을 잃은 전환이 늦게 커밋돼 이 주문의 티켓이 살아 있으면 구매는 된 것이다(돌려주고 취소하면 공짜 티켓)
  const live = await orderTicketLive(c.uid, c.orderId);
  if (live === true) {
    console.warn(LOG, '정리하려는데 이 주문의 티켓이 살아 있다 — 구매 성공으로 본다', c.orderId);
    await sbReq('PATCH', `payment_orders?order_id=eq.${enc(c.orderId)}&fail_reason=eq.${enc('unknown:failing:' + code)}`, { fail_reason: null });
    return json({ ok: true, already: true, orderId: c.orderId, amount: c.expected, purpose: 'ticket_topup' });
  }
  if (live === null) {
    // 지금 상태를 못 읽는다(DB 장애) — 돈을 움직이지 않는다. 표시(unknown:failing:<코드>)가 남아 다시 부른 호출·10분 정리가 이어 간다
    console.warn(LOG, '정리 전 티켓 확인 실패 — 손대지 않음', c.orderId);
    return json({ ok: false, error: 'processing', paid: true, orderId: c.orderId });
  }
  // ④ 예치금
  const k: Known = o.known || knownFromRecord(c);
  const depPlan = c.depositUsed > 0;
  let d1: { ok: boolean; mem: number; gen: number; err?: string } = { ok: true, mem: 0, gen: 0 };
  if (depPlan && k.taken !== 0) d1 = await settleDeposit(c, code, k.taken === null ? c.depositUsed : k.taken, k);
  const card = await cancelTossFull(c.secret, c.tk, CANCEL_REASON[code] || '구매 확정 실패');
  // ⑥ 응답을 잃은 차감이 늦게 들어왔을 수 있다 — 카드 취소(수 초) 뒤 한 번 더 센다(멱등 · 같은 상한)
  let depOk = d1.ok, mem = d1.mem, gen = d1.gen, depErr = d1.err, recheckFailed = false;
  if (depPlan && k.taken === null) {
    const d2 = await settleDeposit(c, code, c.depositUsed, k);
    mem += d2.mem; gen += d2.gen;
    // 서버 함수가 끝까지 돈 두 번째 정리는 그 자체로 완결이다(멱등 · 상한까지 전부) — 첫 실패를 덮어도 된다.
    //   함수가 없을 때(옛 방식)는 결과를 모르면 언제나 실패라 덮지 못한다(CF-4)
    if (d2.ok) { depOk = true; depErr = undefined; }
    else if (d1.ok) recheckFailed = true;   // 되돌린 몫은 되돌린 것 — 늦은 차감 재확인만 못 했다(알림 · 금액 없음 · CF-3)
    else depErr = d2.err || depErr;
  }
  // 회원에게 「예치금도 돌려드렸다」고 말할 수 있는가 — 실제로 빠졌거나 빠졌을 수 있을 때만(예치금 부족·거절은 아무것도 안 뺐다 · CFAPP-4)
  const depMoved = depPlan && (k.taken === null ? (mem + gen > 0 || !depOk) : k.taken > 0);
  const fr = code + (depOk ? '' : '_depfail') + (card.ok ? '_refunded' : '_refund_failed');
  const fail = { code, at: new Date().toISOString(), extra: pickExtra(extra), hold_released: holdGone, dep_used: depMoved,
                 card: { ok: card.ok, code: card.code, tries: card.tries },
                 deposit: { ok: depOk, mem, gen, err: depErr || undefined, taken: k.taken === null ? undefined : k.taken, recheck_failed: recheckFailed || undefined }, mark: MARK };
  const meta = { ...c.preMeta, ...c.claimMeta, fail: JSON.parse(JSON.stringify(fail)) };
  let rec = false;
  for (let i = 0; i < 2 && !rec; i++) {
    const r = await sbPatch(`payment_orders?order_id=eq.${enc(c.orderId)}&select=order_id`, { status: card.ok ? 'canceled' : 'paid', fail_reason: fr, metadata: meta });
    rec = !r.err && r.rows.length > 0;
  }
  if (!rec) console.error(LOG, '실패 결과 기록 실패 — 수동 확인', c.orderId, fr);
  if (!card.ok) await alertAdmins(c, 'cancel_failed', code + (rec ? '' : ' · 주문 기록 실패'));
  // 금액은 뺀 것을 알 때만(이 호출이 봤거나 서버 기록) — 결과를 모르는 차감은 「원장에서 확인」
  if (!depOk) await alertAdmins(c, 'deposit_failed', code, { owed: k.taken !== null ? Math.max(0, k.taken - (mem + gen)) : 0 });
  if (recheckFailed) await alertAdmins(c, 'deposit_check', code);
  if (!rec && card.ok && depOk) await alertAdmins(c, 'record_failed', code);   // 카드·예치금은 끝났는데 결과가 안 남았다(TOSSRB-3)
  await notifyMemberCanceled(c, code, card.ok, depMoved, depOk);
  return json({ ok: false, error: code, refunded: card.ok, deposit_used: depMoved, deposit_refunded: depMoved ? depOk : undefined, hold_gone: holdGone,
                orderId: c.orderId, ...pickExtra(extra), reason: reasonText(code, card.ok, depMoved, depOk, extra) });
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
  if (isTk) {
    // card_dep — 되돌림 상한·정리의 서버 근거(회원은 payment_orders 를 못 쓴다). toss-confirm 은 잡을 때 metadata 를 {toss} 로 덮으므로 홀드·낼 몫·회차도 여기 남긴다
    const pm = c.preMeta;
    c.claimMeta.card_dep = JSON.parse(JSON.stringify({ hold: c.holdId || null, plan: c.depositUsed, tid: pm.ticket_id || null, pax: Number(pm.pax || 0) || null,
      rid: pm.restaurant_id || null, rname: pm.restaurant_name ? String(pm.restaurant_name).slice(0, 60) : null,
      state: c.depositUsed > 0 ? 'deducting' : 'none', ...(c.depositUsed > 0 ? {} : { taken: 0 }) }));
    c.cdep = c.claimMeta.card_dep as Record<string, any>;
  }
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
  let known: Known | undefined;
  try {
    let deposited = 0;
    if (c.depositUsed > 0) {
      // 홀드 구매 id 없이는 예치금을 빼지 않는다 — 되돌림이 그 통으로 센다(SETTLE_BAD_ARGS). 옵션 B 뒤로 모든 주문에 홀드가 있다(옛 주문 대비)
      if (!c.holdId) return await failAfterApproval(c, 'convert_failed', {}, { holdAlive: false, known: { taken: 0, mem: 0, gen: 0, fresh: true } });
      const ded = await deductDeposit(c.uid, c.depositUsed, { purchase_id: c.holdId, ticket_id: pre.ticket_id, restaurant_name: pre.restaurant_name, party_size: pre.pax, order_id: c.orderId });
      // 이 호출이 뺀 금액 — 예치금 부족·거절은 분명히 0(되돌림을 부르지 않는다 · CF-1) · 응답을 잃으면 모른다(null)
      known = { taken: ded.ambiguous ? null : ((ded.short || ded.failed) ? 0 : ded.deducted), mem: ded.fromMem, gen: ded.fromGen, fresh: true };
      await recordDep(c, known);
      if (ded.ambiguous) return await failAfterApproval(c, 'convert_failed', {}, { holdAlive: true, known });
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
    // TOSSRB-3 — 실패 정리 중 함수가 끊긴 주문(unknown:failing:<코드>)은 3분 지나면 이어서 끝낸다(예치금 되돌림은 원장 근거 · 카드 취소는 같은 멱등 키 — 두 번 돌아도 한 번)
    const fm = fr.match(/^unknown:failing:([a-z_]+?)(?::alerted)?$/);
    if (fm && has === false && Number.isFinite(t0) && Date.now() - t0 > 180000 && c.tk) {
      return await failAfterApproval(c, fm[1], {}, { holdAlive: true });
    }
    if (has === false && Number.isFinite(t0) && Date.now() - t0 > 180000 && !/:alerted$/.test(fr)) {
      const r = await sbPatch(`payment_orders?order_id=eq.${enc(c.orderId)}&fail_reason=eq.${enc(fr)}&select=order_id`, { fail_reason: fr.slice(0, 200) + ':alerted' });
      if (r.rows.length) await alertAdmins(c, 'pending', fr.replace(/^unknown:/, '').replace(/:[0-9a-f-]{6,}$/, '').slice(0, 40));
    }
    return json({ ok: false, error: 'processing', paid: true, orderId: c.orderId });
  }
  if (fr) return json({ ok: false, error: fr.split(':')[0].slice(0, 60), paid: true, orderId: c.orderId });
  return json({ ok: false, error: 'processing', paid: true, orderId: c.orderId });
}

// ── 승인 전 — 같은 홀드(또는 승인된 같은 회차)에 결과를 모르는 다른 카드 주문이 있나 (TOSSRB-2) ──
//   있으면 이 주문을 승인하지 않는다 — 앞 주문이 토스에서 늦게 완료되면 두 번 청구된다. 앞 주문은 10분 정리가 잇거나 취소한다.
//   true · false · null(못 읽음 — 승인하지 않는다). 새 카드 주문은 DB 가드(trg_taam_guard_card_order_pending)도 막는다 — 이것은 그 전에 만들어진 주문 몫.
async function otherUnresolved(c: Ctx): Promise<boolean | null> {
  if (c.order?.purpose !== 'ticket_topup') return false;
  const rows = await sbGet(`payment_orders?user_id=eq.${enc(c.uid)}&purpose=eq.ticket_topup&status=in.(pending,paid)&select=order_id,status,fail_reason,metadata,created_at`);
  if (rows === null) return null;
  const tid = String(c.preMeta.ticket_id || ''), cut = Date.now() - 60 * 60000;
  return rows.some((o: any) => {
    if (String(o.order_id) === c.orderId || !/^unknown:/.test(String(o.fail_reason || ''))) return false;
    const t = Date.parse(String(o.created_at || '')); if (!(t > cut)) return false;
    const m = (o.metadata && typeof o.metadata === 'object') ? o.metadata : {}, cd = (m.card_dep && typeof m.card_dep === 'object') ? m.card_dep : {};
    if (c.holdId && (m.hold_purchase_id === c.holdId || cd.hold === c.holdId)) return true;
    return !!(tid && o.status === 'paid' && (m.ticket_id === tid || cd.tid === tid));
  });
}

// ── 10분 정리(sweep) — 결과를 모르는(unknown:*) 티켓 카드 주문 (CF-6 · TOSSRB-1) ──
//   부르는 곳: DB 크론 taam_card_topup_reconcile_kick → toss-confirm {action:'sweep'} (서버 토큰만). 목록은 서버 함수가 고른다.
//   lookup  (pending): 토스에 주문번호로 조회(통화·결제 경로에 맞는 MID 키를 차례로) — DONE 이면 같은 승인으로 잇는다(잡기 → 예치금 → 좌석 · 막히면 취소·환원),
//                      결제가 없으면(404) 닫는다(swept_no_payment — 3~45분 동안 다시 조회해 늦은 승인을 잡는다) · 끝난 결제(취소·중단·만료)는 닫는다 · 모르면 둔다(30분 뒤 알림 한 번)
//   resolve (paid)   : 이 주문의 티켓이 있으면 표시만 지운다 · 없으면 실패 정리를 이어 간다(되돌림은 서버 기록 card_dep 근거 · 카드 전액 취소 — 모두 멱등)
//   orphan  (failed swept_no_payment): 그 사이 승인이 생겼으면 전액 취소
const SWEEP_MID: Record<string, string> = { DOM: '국내 MID(playtauif6)', BILL: '등록 카드 MID(bill_taam315)', USD: '해외 USD MID(playtaamusd)', JPY: '해외 JPY MID(playtaamjpy)' };
function sweepSecrets(o: any): { key: string; secret: string; label: string }[] {
  const cur = String(o?.currency || 'KRW').toUpperCase();
  const dom = Deno.env.get('TOSS_SECRET_KEY') || '', bill = Deno.env.get('TOSS_BILLING_SECRET_KEY') || '';
  const out: { key: string; secret: string; label: string }[] = [];
  const add = (key: string, secret: string) => { if (secret && !out.some((x) => x.secret === secret)) out.push({ key, secret, label: SWEEP_MID[key] }); };
  if (cur === 'USD' || cur === 'JPY') { add(cur, Deno.env.get('TOSS_SECRET_KEY_' + cur) || ''); return out; }
  const m = (o?.metadata && typeof o.metadata === 'object') ? o.metadata : {};
  const mid = String(m.toss?.mId || '');
  const billFirst = m.paid_via === 'billing_key' || /^bill/.test(mid) || /^unknown:(approving_billing|toss_billing)/.test(String(o?.fail_reason || ''));
  if (billFirst) { add('BILL', bill); add('DOM', dom); } else { add('DOM', dom); add('BILL', bill); }
  return out;
}
// 주문번호로 토스에 묻는다 — 키마다(다른 MID 의 주문은 404) · done / gone(모든 키 404 또는 끝난 결제) / unknown(네트워크·5xx·진행 중)
async function sweepLookup(o: any): Promise<{ st: 'done' | 'gone' | 'ended' | 'unknown'; body?: any; key?: string; secret?: string; label?: string }> {
  const keys = sweepSecrets(o);
  if (!keys.length) return { st: 'unknown' };
  let all404 = true;
  for (const k of keys) {
    const g = await tossCall(k.secret, `/v1/payments/orders/${enc(o.order_id)}`, 'GET');
    if (g.ok && String(g.body?.orderId || '') === String(o.order_id)) {
      const s = String(g.body?.status || '');
      if (s === 'DONE') return { st: 'done', body: g.body, key: k.key, secret: k.secret, label: k.label };
      if (/^(CANCELED|ABORTED|EXPIRED)$/.test(s)) return { st: 'ended', body: g.body, key: k.key, secret: k.secret, label: k.label };
      all404 = false;   // 진행 중(IN_PROGRESS · READY · WAITING_FOR_DEPOSIT) · 부분 취소(PARTIAL_CANCELED — 남은 승인이 있다) — 닫지 않는다(30분 뒤 알림)
      continue;
    }
    if (g.status !== 404) all404 = false;   // 네트워크·5xx·권한 — 모른다
  }
  return { st: all404 ? 'gone' : 'unknown' };
}
async function sweepTopups(): Promise<Response> {
  const lr = await sbRpc('taam_card_topup_reconcile_list', { p_limit: 15 });
  if (lr.err || !Array.isArray(lr.data)) return json({ ok: false, error: 'list_failed', code: lr.err?.pgCode || '' });
  const out = { n: lr.data.length, resumed: 0, confirmed: 0, failed_closed: 0, cleared: 0, closed: 0, left: 0, orphan_canceled: 0, errors: 0 };
  for (const it of lr.data) {
    try {
      const g = await sbGet(`payment_orders?order_id=eq.${enc(it.order_id)}&select=*`);
      const o = g && g[0];
      if (!o || o.purpose !== 'ticket_topup' || String(o.status) !== String(it.status) || String(o.fail_reason || '') !== String(it.fail_reason || '')) { out.left++; continue; }   // 그 사이 바뀌었다
      const uid = String(o.user_id || ''), fr = String(o.fail_reason || '');
      if (it.reconcile === 'lookup') {
        const lk = await sweepLookup(o);
        if (lk.st === 'done') {
          const c = ctxOf(o, uid, lk.secret!, lk.label!);
          const isBill = lk.key === 'BILL';
          const res = await afterApproval(c, lk.body, isBill ? (pick) => ({ ...c.preMeta, toss: pick, paid_via: 'billing_key', resumed_by: 'sweep' }) : (pick) => ({ toss: pick, resumed_by: 'sweep' }),
                                          isBill ? 'billing' : null, {});
          const d = await res.json().catch(() => ({}));
          out.resumed++;
          if (d && d.ok) { out.confirmed++; await notifyMemberConfirmed(c); }
          else if (d && d.error && d.error !== 'processing') out.failed_closed++;
          continue;
        }
        if (lk.st === 'gone' || lk.st === 'ended') {
          // 결제가 없다(또는 토스에서 이미 끝났다) — 주문을 닫는다. 표시가 그대로일 때만(그 사이 다른 호출이 잡았으면 손대지 않는다)
          const why = (lk.st === 'gone' ? 'swept_no_payment:' : 'swept_toss_' + String(lk.body?.status || 'ended').toLowerCase() + ':') + fr.replace(/^unknown:/, '').replace(/:alerted$/, '').slice(0, 60);
          const r = await sbPatch(`payment_orders?order_id=eq.${enc(o.order_id)}&status=eq.pending&fail_reason=eq.${enc(fr)}&select=order_id`, { status: 'failed', fail_reason: why });
          if (!r.err && r.rows.length) out.closed++; else out.left++;
          continue;
        }
        // 모른다 — 두고 다음에 다시. 30분 넘게 모르면 한 번 알린다
        out.left++;
        const age = Date.now() - Date.parse(String(o.created_at || ''));
        if (age > 30 * 60000 && !/:alerted$/.test(fr)) {
          const r = await sbPatch(`payment_orders?order_id=eq.${enc(o.order_id)}&fail_reason=eq.${enc(fr)}&select=order_id`, { fail_reason: fr.slice(0, 200) + ':alerted' });
          if (!r.err && r.rows.length) { const ks = sweepSecrets(o); await alertAdmins(ctxOf(o, uid, ks[0]?.secret || '', ks[0]?.label || 'MID'), 'pending', 'sweep_' + fr.replace(/^unknown:/, '').slice(0, 30)); }
        }
        continue;
      }
      if (it.reconcile === 'resolve') {
        const ks = sweepSecrets(o);
        const c = ctxOf(o, uid, ks[0]?.secret || '', ks[0]?.label || 'MID');
        const has = await orderTicketAny(uid, o.order_id);
        if (has === null) { out.left++; continue; }
        if (has === true) {
          await sbReq('PATCH', `payment_orders?order_id=eq.${enc(o.order_id)}&fail_reason=eq.${enc(fr)}`, { fail_reason: null });
          out.cleared++;
          continue;
        }
        if (!c.tk) { out.left++; continue; }   // 결제키 없는 paid — 사람이 본다(이미 알림)
        const fm = fr.match(/^unknown:failing:([a-z_]+?)(?::alerted)?$/);
        const res = await failAfterApproval(c, fm ? fm[1] : 'convert_failed', {}, { holdAlive: true });
        const d = await res.json().catch(() => ({}));
        if (d && d.ok) out.cleared++; else if (d && d.error === 'processing') out.left++; else out.failed_closed++;
        continue;
      }
      if (it.reconcile === 'orphan') {
        const lk = await sweepLookup(o);
        if (lk.st !== 'done') continue;
        // 닫은 주문에 승인이 남았다 — 좌석·예치금은 손대지 않았다(잡지 않았다) · 카드만 전액 취소
        const c = ctxOf(o, uid, lk.secret!, lk.label!);
        c.tk = String(lk.body?.paymentKey || '');
        const card = await cancelTossFull(lk.secret!, c.tk, CANCEL_REASON.order_closed);
        await sbReq('PATCH', `payment_orders?order_id=eq.${enc(o.order_id)}&status=eq.failed`, { status: card.ok ? 'canceled' : 'paid', payment_key: c.tk,
          fail_reason: 'order_closed' + (card.ok ? '_refunded' : '_refund_failed'),
          metadata: { ...(o.metadata || {}), fail: { code: 'order_closed', prev: fr.slice(0, 60), at: new Date().toISOString(), card: { ok: card.ok, code: card.code, tries: card.tries }, mark: MARK } } });
        if (!card.ok) await alertAdmins(c, 'cancel_failed', 'order_closed');
        await notifyMemberCanceled(c, 'order_closed', card.ok, false, true);
        out.orphan_canceled++;
      }
    } catch (e) { out.errors++; console.error(LOG, 'sweep 한 건 실패', String((e as Error)?.message || e).slice(0, 120)); }
  }
  return json({ ok: true, ...out });
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

const MID_LABEL: Record<string, string> = { KRW: '국내 MID(playtauif6)', USD: '해외 USD MID(playtaamusd)', JPY: '해외 JPY MID(playtaamjpy)' };

async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const body = await req.json().catch(() => ({})) as Record<string, any>;
    // ── 10분 정리(서버만 — DB 크론 taam_card_topup_reconcile_kick) · 결과를 모르는 카드 주문을 토스에 조회해 잇거나 정리한다 ──
    if (body.action === 'sweep') {
      if (!isServiceToken(req)) return json({ ok: false, error: 'forbidden' }, 403);
      return await sweepTopups();
    }
    const orderId = String(body.orderId || '').trim();
    const paymentKey = String(body.paymentKey || '').trim();
    // 클라이언트가 보낸 금액은 참고만 한다. 신뢰 기준은 DB 의 amount 다.
    const clientAmount = Number(body.amount || 0);
    if (!orderId || !paymentKey || orderId.length > 80 || paymentKey.length > 200) return json({ ok: false, error: 'missing_params' });

    // ── 호출자 신원 확인 ──
    const me = await caller(req);
    if (!me) return json({ ok: false, error: 'unauthorized' }, 401);

    // ── 주문 조회 ──
    const rows = await sbGet(`payment_orders?order_id=eq.${enc(orderId)}&select=*`);
    if (rows === null) { console.error(LOG, '주문 조회 실패', orderId); return json({ ok: false, error: 'order_lookup_failed', retry: true }); }
    const order = rows[0];
    if (!order) return json({ ok: false, error: 'order_not_found' });
    if (order.user_id !== me.id) {
      console.warn(LOG, '주문 소유자 불일치', orderId);
      return json({ ok: false, error: 'order_forbidden' }, 403);
    }

    // ── 통화별 시크릿 — 토스는 MID 마다 키가 달라서, 국내 키로 외화 승인을 부르면 무조건 거절된다 ──
    const orderCur = String(order.currency || 'KRW').toUpperCase();
    const secret = orderCur === 'KRW' ? (Deno.env.get('TOSS_SECRET_KEY') || '') : (Deno.env.get('TOSS_SECRET_KEY_' + orderCur) || '');
    if (!secret) {
      console.error(LOG, '시크릿 미설정', orderCur);
      return json({ ok: false, error: 'server_not_configured', currency: orderCur });
    }
    const c = ctxOf(order, me.id, secret, MID_LABEL[orderCur] || ('MID(' + orderCur + ')'));

    // ── 이미 처리된 주문 — 결과를 그대로 알려 준다(실패를 ✅ 로 답하지 않는다) ──
    if (order.status !== 'pending') return await onClosedOrder(c);

    const expected = Number(order.amount);
    if (clientAmount && clientAmount !== expected) {
      // 브라우저가 다른 금액을 주장하고 있다. 승인을 시도하지 않는다.
      console.warn(LOG, '금액 불일치(클라이언트)', orderId, clientAmount, expected);
      await sbReq('PATCH', `payment_orders?order_id=eq.${enc(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: 'amount_mismatch_client' });
      return json({ ok: false, error: 'amount_mismatch' });
    }

    // ── 같은 좌석에 결과를 모르는 앞 카드 주문이 있으면 승인하지 않는다(늦게 완료되면 두 번 청구 · TOSSRB-2) — 앱은 좌석을 두고 「확인 중」 ──
    const ou = await otherUnresolved(c);
    if (ou === null) return json({ ok: false, error: 'order_lookup_failed', retry: true });
    if (ou) { console.warn(LOG, '앞 카드 주문 결과 모름 — 이 주문은 승인하지 않음', orderId); return json({ ok: false, error: 'payment_pending', orderId }); }

    // ── 승인을 요청하기 **전에** 「결과 모름」 표시 — 승인 뒤에 함수가 죽어도 다시 부른 호출·10분 정리가 알아본다(조용한 표시 · 알림 없음) ──
    if (!String(order.fail_reason || '').startsWith('unknown:')) {
      const mk = await sbPatch(`payment_orders?order_id=eq.${enc(orderId)}&status=eq.pending&select=order_id`, { fail_reason: 'unknown:approving' });
      if (mk.err) return json({ ok: false, error: 'order_lookup_failed', retry: true });
      if (!mk.rows.length) {
        // 그 사이 상태가 바뀌었다(다른 호출이 잡았거나 닫았다)
        const ag = await sbGet(`payment_orders?order_id=eq.${enc(orderId)}&select=*`);
        if (!ag || !ag[0]) return json({ ok: false, error: 'order_lookup_failed', retry: true });
        return await onClosedOrder(ctxOf(ag[0], me.id, secret, c.midLabel));
      }
      order.fail_reason = 'unknown:approving';
    }

    // ── 토스 승인 (Idempotency-Key 로 토스 쪽 중복 승인도 막는다 — 같은 주문은 같은 키) ──
    let t = await tossCall(secret, '/v1/payments/confirm', 'POST', { paymentKey, orderId, amount: expected }, `taam-confirm-${orderId}`);
    if (!t.ok || t.body?.status !== 'DONE') {
      if (tossAmbiguous(t)) {
        // 승인이 실제로 됐을 수 있다 — 조회해서 DONE 이면 잇고, 아니면 실패로 굳히지 않는다(적대 리뷰 H1)
        const lk = await tossLookup(secret, paymentKey, orderId);
        if (lk.done) t = { ok: true, status: 200, body: lk.body };
        else if (!lk.gone) {
          const code = String(t.body?.code || ('http_' + t.status)).slice(0, 40);
          // 겹친 호출(같은 멱등 키가 처리 중)은 알리지 않는다 — 앞 호출이 곧 끝낸다
          if (code !== 'IDEMPOTENT_REQUEST_PROCESSING') await markUnknown(c, 'pending', 'toss_confirm_' + code);
          return json({ ok: false, error: 'processing', retry: true, orderId });
        }
      }
      if (!t.ok || t.body?.status !== 'DONE') {
        const reason = String(t.body?.message || t.body?.code || ('http_' + t.status)).slice(0, 300);
        console.warn(LOG, '승인 실패', orderId, reason.slice(0, 160));
        await sbReq('PATCH', `payment_orders?order_id=eq.${enc(orderId)}&status=eq.pending`, { status: 'failed', fail_reason: reason });
        return json({ ok: false, error: 'confirm_failed', reason: reason.slice(0, 200) });
      }
    }

    // ── 승인 뒤 — 주문 잡기 · 예치금 · 좌석 (공통 블록) ──
    //   주문을 paid 로 잡을 때의 metadata 는 종전과 같은 모양({toss}) — 고른 칸만(원문 secret 칸을 남기지 않는다)
    return await afterApproval(c, t.body, (pick) => ({ toss: pick }), null, { ticket: c.preMeta });
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
