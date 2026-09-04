// ═══════════════════════════════════════════════════════════════
// 토스트 — 서버 원문을 회원에게 보여주지 않는다 (2026-09-04)
// ═══════════════════════════════════════════════════════════════
//   회원 화면에 이렇게 떴다.
//     예치금 차감 실패
//     column "payment_id" is of type uuid but expression is of type text
//
//   제목은 우리가 쓴 한국어라 번역되는데, 본문은 Postgres 가 준 문장이라
//   번역 대상이 아니다 — 한국어로 쓰는 회원에게도 그 줄만 영어로 나온다.
//   번역 상태와 무관하다. 그리고 저건 DB 내부 구조라 애초에 보일 것이 아니다.
//
//   ① 기계가 뱉은 문장은 회원에게 가린다 ⭐
//   ② 어드민에게는 원문 그대로 ⭐ 없으면 고칠 수가 없다
//   ③ 우리가 쓴 문장·매장 이름·구매ID 는 건드리지 않는다 ⭐
//      「영어면 감춘다」로 만들면 여기가 무너진다
//   ④ 가린 문장은 EN/JA 로 번역돼 나온다 (또 영어로 나오면 고친 의미가 없다)
//
// 실행: node sql/_test/toastshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

// 감춰야 하는 것 — 실제로 라이브에서 나온 모양들
const HIDE = [
  'column "payment_id" is of type uuid but expression is of type text',   // 2026-09-04 그 건
  'new row violates row-level security policy for table "tickets"',
  'Could not find the function public.taam_apply_deposit_delta in the schema cache',
  'duplicate key value violates unique constraint "tickets_purchase_id_key"',
  'permission denied for table profiles',
  'null value in column "user_id" violates not-null constraint',
  'invalid input syntax for type uuid: "taam-20260904"',
  'JWT expired',
  'Failed to fetch',
  "TypeError: Cannot read properties of null (reading 'id')",
];
// 그대로 둬야 하는 것
const KEEP = [
  '잔액이 부족합니다',
  '₩1,400,000 충전되었습니다',
  'Sushi Takamitsu',                 // 매장 이름은 영문일 수 있다
  'INV-abcd1234-1757000000000',      // 구매ID
  'BUILD 2026.09.04-c',
  '',
];

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  await p.route('**://fonts.g**', r => r.abort());
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(({ HIDE, KEEP }) => {
    const res = [];
    const ok = (n, c) => res.push((c ? 'OK   ' : 'FAIL ') + n);
    const GEN = '잠시 후 다시 시도해주세요 — 계속되면 문의해 주세요';
    const cut = s => (s.length > 46 ? s.slice(0, 46) + '…' : s);

    // ── ① 회원에게는 가린다 ──────────────────────────────────
    window._currentRole = 'user';
    HIDE.forEach(s => ok('회원에게 감춘다 ⭐ — ' + cut(s), window._toastSafeMsg(s) === GEN));

    // ── ③ 우리가 쓴 것은 건드리지 않는다 ─────────────────────
    KEEP.forEach(s => ok('그대로 둔다 ⭐ — ' + (cut(s) || '(빈 값)'), window._toastSafeMsg(s) === s));

    // ── ② 어드민에게는 원문 ─────────────────────────────────
    ['admin', 'superadmin'].forEach(role => {
      window._currentRole = role;
      ok(role + ' 은 원문을 본다 ⭐', window._toastSafeMsg(HIDE[0]) === HIDE[0]);
    });
    window._currentRole = 'user';

    // ── ④ 실제 토스트에 무엇이 찍히는가 ─────────────────────
    const body = () => document.getElementById('toastMsg').textContent;
    window._tkCurrentLang = 'ko';
    showToast('❌', '예치금 차감 실패', HIDE[0]);
    ok('토스트 본문이 바뀌었다 ⭐', body() === GEN);
    ok('DB 컬럼 이름이 안 보인다 ⭐', body().indexOf('payment_id') < 0);

    window._tkCurrentLang = 'en';
    showToast('❌', '예치금 차감 실패', HIDE[0]);
    ok('EN 이면 영어 안내문 ⭐ (' + cut(body()) + ')',
       body() !== GEN && /try again/i.test(body()));
    window._tkCurrentLang = 'ja';
    showToast('❌', '예치금 차감 실패', HIDE[0]);
    ok('JA 이면 일본어 안내문 ⭐', /[぀-ヿ]/.test(body()));

    // 우리가 쓴 문장은 지금까지처럼 번역된다 (막아 놓고 나머지를 깨면 안 된다)
    window._tkCurrentLang = 'en';
    showToast('⚠', '예치금 부족', '잔액이 부족합니다');
    ok('멀쩡한 문장은 그대로 번역된다 ⭐', /balance/i.test(body()));
    window._tkCurrentLang = 'ko';
    return res;
  }, { HIDE, KEEP });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
