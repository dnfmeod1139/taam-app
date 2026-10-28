// ═════════════════════════════════════════════════
// toss-payment-info — 💳 결제 내역 화면이 토스에서 결제·정산을 다시 읽어 캐시에 적는다 (슈퍼어드민 · 2026-10-28)
// ═════════════════════════════════════════════════
// 왜: 카드 정보(카드사·번호·할부·승인번호)·지금 취소 상태·입금일(정산)은 우리 DB 에 다 있지 않다.
//     앱 티켓 카드 결제는 승인 시점 기록(metadata.toss)뿐이라 그 뒤 상점관리자에서 한 취소를 모르고,
//     결제 링크(kashikiri_charges)는 카드 정보가 아예 없고, 입금일은 어디에도 없다 → 토스가 정답이다.
// 누가: 슈퍼어드민(JWT · verify_jwt=true + profiles.role 확인). 그 밖은 403.
// 무엇을:
//   입력 { items: [{src:'order'|'charge', ref}] (60개까지), settle?: boolean(기본 true) }
//   ① 결제키는 앱이 보낸 것을 믿지 않는다 — ref 로 우리 표(payment_orders.order_id / kashikiri_charges.id)를 읽어 결제키·통화를 얻는다.
//   ② GET /v1/payments/{paymentKey} — 그 결제를 승인한 MID 의 시크릿으로(토스는 MID 마다 키가 다르다).
//      먼저 짐작한 키(승인 기록의 mId · 등록 카드 · 통화) → 안 되면 나머지 키를 차례로. 시크릿 이름만 다루고 값은 어디에도 남기지 않는다.
//   ③ GET /v1/settlements?dateType=soldDate — 그 MID 의 키로, 승인일 ~ +35일(오늘까지) 를 31일씩 끊어 읽고 결제키가 같은 줄만 고른다.
//      정산 줄은 승인 다음 날부터 생긴다(라이브 키만). 못 찾으면 빈 배열 + 조회 시각(「아직 정산 기록 없음」).
//   ④ toss_payment_cache 에 고른 칸만 upsert (service_role · 회원은 이 표를 못 읽는다). 토스 원문·secret 칸은 적지 않는다.
//   돌려주는 것은 건수와 오류 코드뿐 — 화면은 다시 taam_payment_ledger 를 부른다.
// 오류는 HTTP 200 + { ok:false, error } — 권한만 403.
// 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY · TOSS_SECRET_KEY · TOSS_BILLING_SECRET_KEY · TOSS_SECRET_KEY_USD · TOSS_SECRET_KEY_JPY (있는 것만 쓴다)
// ═════════════════════════════════════════════════
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
function json(b: unknown, s = 200){ return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
const SB_H = () => ({ apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' });
const TOSS = 'https://api.tosspayments.com';

async function sbGet(path: string){ const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: SB_H() }); return r.ok ? await r.json().catch(() => []) : []; }
async function sbUpsert(rows: Record<string, unknown>[]){
  if(!rows.length) return true;
  const r = await fetch(`${SUPABASE_URL}/rest/v1/toss_payment_cache?on_conflict=payment_key`, {
    method: 'POST', headers: { ...SB_H(), Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(rows) });
  if(!r.ok) console.error('[toss-payment-info] upsert', r.status, (await r.text().catch(() => '')).slice(0, 200));
  return r.ok;
}
async function superCaller(req: Request): Promise<string | null>{
  const h = req.headers.get('Authorization') || ''; const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  if(!t) return null;
  const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${t}` } });
  if(!u.ok) return null; const j = await u.json().catch(() => null); if(!j?.id) return null;
  const p = await sbGet(`profiles?id=eq.${encodeURIComponent(j.id)}&select=role`);
  return ['super_admin', 'superadmin'].includes(String(p[0]?.role || '')) ? String(j.id) : null;
}

// ── MID ↔ 시크릿 이름 (값은 Deno.env 에만) ──
const KEY_NAMES = ['TOSS_SECRET_KEY', 'TOSS_BILLING_SECRET_KEY', 'TOSS_SECRET_KEY_USD', 'TOSS_SECRET_KEY_JPY'];
const MID_KEY: Record<string, string> = { playtauif6: 'TOSS_SECRET_KEY', bill_taam315: 'TOSS_BILLING_SECRET_KEY', playtaamusd: 'TOSS_SECRET_KEY_USD', playtaamjpy: 'TOSS_SECRET_KEY_JPY' };
const KEY_LABEL: Record<string, string> = { TOSS_SECRET_KEY: 'KRW', TOSS_BILLING_SECRET_KEY: 'BILLING', TOSS_SECRET_KEY_USD: 'USD', TOSS_SECRET_KEY_JPY: 'JPY' };
function keyOf(name: string){ const v = Deno.env.get(name) || ''; return v ? `Basic ${btoa(v + ':')}` : ''; }
function guessKeys(mid: string, billing: boolean, cur: string){
  const first: string[] = [];
  if(mid && MID_KEY[mid]) first.push(MID_KEY[mid]);
  if(billing) first.push('TOSS_BILLING_SECRET_KEY');
  if(cur === 'USD') first.push('TOSS_SECRET_KEY_USD'); else if(cur === 'JPY') first.push('TOSS_SECRET_KEY_JPY'); else first.push('TOSS_SECRET_KEY');
  const out: string[] = [];
  [...first, ...KEY_NAMES].forEach((n) => { if(!out.includes(n) && keyOf(n)) out.push(n); });
  return out;
}

async function tfetch(url: string, auth: string, ms: number){
  const ac = new AbortController(); const tm = setTimeout(() => ac.abort(), ms);
  try { const r = await fetch(url, { headers: { Authorization: auth }, signal: ac.signal }); const b = await r.json().catch(() => null); return { ok: r.ok, status: r.status, body: b }; }
  catch (e) { return { ok: false, status: 0, body: { code: (e as Error)?.name === 'AbortError' ? 'TIMEOUT' : 'FETCH_FAILED' } }; }
  finally { clearTimeout(tm); }
}

// ── 고른 칸 (SQL _taam_pl_toss 와 같은 모양) ──
const S = (v: unknown, n: number) => (v == null || v === '') ? undefined : String(v).slice(0, n);
const N = (v: unknown) => { const x = Number(v); return (v == null || v === '' || !isFinite(x)) ? undefined : Math.round(x * 100) / 100; };
const B = (v: unknown) => typeof v === 'boolean' ? v : undefined;
function clean(o: Record<string, unknown>){ Object.keys(o).forEach((k) => { if(o[k] === undefined || o[k] === null) delete o[k]; }); return o; }
function pickPayment(p: any){
  const c = p && typeof p.card === 'object' && p.card ? p.card : null;
  const e = p && typeof p.easyPay === 'object' && p.easyPay ? p.easyPay : null;
  return clean({
    mId: S(p.mId, 40), status: S(p.status, 30), method: S(p.method, 30), currency: S(p.currency, 5),
    totalAmount: N(p.totalAmount), balanceAmount: N(p.balanceAmount), approvedAt: S(p.approvedAt, 40), requestedAt: S(p.requestedAt, 40),
    type: S(p.type, 20), country: S(p.country, 5), orderName: S(p.orderName, 100), receiptUrl: S(p.receipt?.url, 400),
    card: c ? clean({ issuerCode: S(c.issuerCode, 10), acquirerCode: S(c.acquirerCode, 10), company: S(c.company, 30), number: S(c.number, 30),
      installmentPlanMonths: N(c.installmentPlanMonths), isInterestFree: B(c.isInterestFree), interestPayer: S(c.interestPayer, 20),
      approveNo: S(c.approveNo, 20), useCardPoint: B(c.useCardPoint), cardType: S(c.cardType, 10), ownerType: S(c.ownerType, 10),
      acquireStatus: S(c.acquireStatus, 20), amount: N(c.amount) }) : undefined,
    easyPay: e ? clean({ provider: S(e.provider, 30), amount: N(e.amount), discountAmount: N(e.discountAmount) }) : undefined,
    cancels: Array.isArray(p.cancels) ? p.cancels.filter((x: any) => x && typeof x === 'object').slice(0, 50).map((x: any) => clean({
      cancelAmount: N(x.cancelAmount), cancelReason: S(x.cancelReason, 200), canceledAt: S(x.canceledAt, 40), transactionKey: S(x.transactionKey, 80),
      cancelStatus: S(x.cancelStatus, 20), refundableAmount: N(x.refundableAmount) })) : [],
  });
}
function pickSettle(s: any){
  const fees = Array.isArray(s.fees) ? s.fees.filter((f: any) => f && typeof f === 'object').slice(0, 10) : [];
  const fee = fees.reduce((a: number, f: any) => a + (Number(f.fee) || 0), 0);
  const cancel = !!(s.cancel && typeof s.cancel === 'object') || (Array.isArray(s.cancels) && s.cancels.length > 0) || Number(s.amount) < 0;
  return clean({ tx: S(s.transactionKey, 80), mId: S(s.mId, 40), cur: S(s.currency, 5), method: S(s.method, 30),
    amount: N(s.amount), fee: N(fee), fees: fees.map((f: any) => clean({ type: S(f.type, 30), fee: N(f.fee) })), interestFee: N(s.interestFee),
    supplyAmount: N(s.supplyAmount), vat: N(s.vat), payOutAmount: N(s.payOutAmount),
    soldDate: S(s.soldDate, 10), paidOutDate: S(s.paidOutDate, 10), approvedAt: S(s.approvedAt, 40), cancel: cancel || undefined,
    cancelAmount: N(s.cancel?.cancelAmount) });
}

// KST 날짜 'YYYY-MM-DD'
function kstYmd(ms: number){ return new Date(ms + 9 * 3600 * 1000).toISOString().slice(0, 10); }
function addDays(ymd: string, d: number){ const t = Date.parse(ymd + 'T00:00:00Z'); return new Date(t + d * 86400000).toISOString().slice(0, 10); }

async function handle(req: Request){
  if(req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const by = await superCaller(req);
  if(!by) return json({ ok: false, error: 'forbidden' }, 403);
  try {
    const body = await req.json().catch(() => ({}));
    const wantSettle = body?.settle !== false;
    const raw: any[] = Array.isArray(body?.items) ? body.items.slice(0, 60) : [];
    const orders = [...new Set(raw.filter((x) => x?.src === 'order').map((x) => String(x.ref || '')).filter((r) => r && r.length <= 120 && /^[A-Za-z0-9_\-:.]+$/.test(r)))];
    const charges = [...new Set(raw.filter((x) => x?.src === 'charge').map((x) => String(x.ref || '')).filter((r) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(r)))];
    if(!orders.length && !charges.length) return json({ ok: false, error: 'no_items' });

    // ① 우리 표에서 결제키·통화·승인 시각
    type It = { src: 'order' | 'charge', ref: string, pk: string, cur: string, billing: boolean, mid: string, at: number };
    const items: It[] = [];
    if(orders.length){
      const rows = await sbGet(`payment_orders?order_id=in.(${orders.map((o) => `"${o}"`).join(',')})&select=order_id,payment_key,currency,status,approved_at,created_at,paid_via:metadata->>paid_via,mid:metadata->toss->>mId`);
      for(const r of rows){ if(!r.payment_key) continue;
        items.push({ src: 'order', ref: String(r.order_id), pk: String(r.payment_key), cur: String(r.currency || 'KRW').toUpperCase(), billing: r.paid_via === 'billing_key',
                     mid: String(r.mid || ''), at: Date.parse(r.approved_at || r.created_at) || Date.now() }); }
    }
    if(charges.length){
      const rows = await sbGet(`kashikiri_charges?id=in.(${charges.join(',')})&select=id,payment_key,pay_currency,approved_at,created_at`);
      for(const r of rows){ if(!r.payment_key) continue;
        items.push({ src: 'charge', ref: String(r.id), pk: String(r.payment_key), cur: String(r.pay_currency || 'KRW').toUpperCase(), billing: false,
                     mid: '', at: Date.parse(r.approved_at || r.created_at) || Date.now() }); }
    }
    if(!items.length) return json({ ok: false, error: 'no_payment_key' });
    if(!KEY_NAMES.some((n) => keyOf(n))) return json({ ok: false, error: 'no_secret' });

    // ② 결제 조회 — 6개씩 동시에
    const now = new Date().toISOString();
    const okRows: Record<string, unknown>[] = [], failRows: Record<string, unknown>[] = [];
    const errors: { ref: string, code: string }[] = [];
    const keyUsed: Record<string, string> = {};   // 결제키 → 시크릿 이름
    const approvedYmd: Record<string, string> = {};
    for(let i = 0; i < items.length; i += 6){
      await Promise.all(items.slice(i, i + 6).map(async (it) => {
        let last = 'NOT_FOUND';
        for(const kn of guessKeys(it.mid, it.billing, it.cur)){
          const r = await tfetch(`${TOSS}/v1/payments/${encodeURIComponent(it.pk)}`, keyOf(kn), 15000);
          if(r.ok && r.body && typeof r.body === 'object' && String(r.body.paymentKey || '') === it.pk){
            const info = pickPayment(r.body);
            keyUsed[it.pk] = kn;
            const ap = Date.parse(String(r.body.approvedAt || '')) || it.at;
            approvedYmd[it.pk] = kstYmd(ap);
            okRows.push({ payment_key: it.pk, src: it.src, ref: it.ref, mid: info.mId || null, info, info_at: now, info_error: null, updated_at: now });
            return;
          }
          last = String(r.body?.code || ('HTTP_' + r.status)).slice(0, 60);
          if(r.status === 0) break;   // 시간 초과·연결 실패 — 다른 키로 바꿔도 같다
        }
        approvedYmd[it.pk] = kstYmd(it.at);
        failRows.push({ payment_key: it.pk, src: it.src, ref: it.ref, info_error: last, updated_at: now });
        errors.push({ ref: it.ref, code: last });
      }));
    }
    await sbUpsert(okRows); await sbUpsert(failRows);

    // ③ 정산 — 시크릿마다, 승인일 ~ +35일(오늘까지)을 31일씩
    const settle = { keys: 0, calls: 0, rows: 0, matched: 0, errors: [] as { key: string, code: string }[] };
    if(wantSettle){
      const today = kstYmd(Date.now());
      const byKey: Record<string, It[]> = {};
      for(const it of items){ const kn = keyUsed[it.pk] || guessKeys(it.mid, it.billing, it.cur)[0]; if(!kn) continue; (byKey[kn] = byKey[kn] || []).push(it); }
      const sOk: Record<string, unknown>[] = [], sFail: Record<string, unknown>[] = [];
      for(const kn of Object.keys(byKey)){
        settle.keys++;
        const list = byKey[kn];
        const want = new Set(list.map((it) => it.pk));
        const found: Record<string, any[]> = {};
        const days = list.map((it) => approvedYmd[it.pk]).sort();
        let start = addDays(days[0], -1), end = addDays(days[days.length - 1], 35); if(end > today) end = today;
        let err = '';
        if(start > end) start = end;
        let guard = 0;
        while(start <= end && guard++ < 16 && !err){
          const stop = addDays(start, 30) < end ? addDays(start, 30) : end;
          for(let page = 1; page <= 5; page++){
            settle.calls++;
            const r = await tfetch(`${TOSS}/v1/settlements?startDate=${start}&endDate=${stop}&dateType=soldDate&page=${page}&size=5000`, keyOf(kn), 60000);
            if(!r.ok || !Array.isArray(r.body)){ err = String(r.body?.code || ('HTTP_' + r.status)).slice(0, 60); break; }
            settle.rows += r.body.length;
            for(const s of r.body){ const pk = String(s?.paymentKey || ''); if(want.has(pk)) (found[pk] = found[pk] || []).push(pickSettle(s)); }
            if(r.body.length < 5000) break;
          }
          start = addDays(stop, 1);
        }
        for(const it of list){
          if(err){ sFail.push({ payment_key: it.pk, src: it.src, ref: it.ref, settle_error: err, updated_at: now }); continue; }
          const arr = (found[it.pk] || []).sort((a, b) => String(a.paidOutDate || '').localeCompare(String(b.paidOutDate || '')));
          if(arr.length) settle.matched++;
          sOk.push({ payment_key: it.pk, src: it.src, ref: it.ref, settle: arr, settle_at: now, settle_error: null, updated_at: now });
        }
        if(err) settle.errors.push({ key: KEY_LABEL[kn] || kn, code: err });
      }
      await sbUpsert(sOk); await sbUpsert(sFail);
    }
    return json({ ok: true, items: items.length, info_ok: okRows.length, info_fail: failRows.length, errors: errors.slice(0, 20), settle });
  } catch (e) { console.error('[toss-payment-info]', e); return json({ ok: false, error: String((e as Error).message || e).slice(0, 200) }, 500); }
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
