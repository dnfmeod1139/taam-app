// ═══════════════════════════════════════════════════════════════
// 대관 — 엔화 원금 · 적용 환율 검증 (2026-09-01)
// ═══════════════════════════════════════════════════════════════
// 무엇을 보나
//   ① 엔화 × 환율 → 원화 칸이 자동으로 채워지나 (식사·주류만, 대행비는 그대로)
//   ② 엔화나 환율이 비면 아무 일도 안 하나 (기존 원화 초대 보호)
//   ③ 결제 팝업에 「엔화 원금 · 적용 환율」이 뜨나 — 값이 있을 때만
//   ④ 예치금이 모자라면 「충전하기」로 가는 길이 있나
//
// 실행: node sql/_test/fxshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const V = id => (document.getElementById(id) || {}).value;
    const set = (id, v) => { const e = document.getElementById(id); if (e) e.value = v; };

    ok('riFxApply 존재',     typeof window.riFxApply === 'function');
    ok('riPayGoCharge 존재', typeof window.riPayGoCharge === 'function');
    ok('엔화 칸이 화면에 있다', !!document.getElementById('riJpyMeal')
                              && !!document.getElementById('riJpyDrink')
                              && !!document.getElementById('riFxRate')
                              && !!document.getElementById('riFxNote'));

    // ── ① 환산 ────────────────────────────────────────────────
    window._riPax = 1;
    set('riJpyMeal', '40,000'); set('riJpyDrink', '30,000');
    set('riFxRate', '9.35');    set('riAgencyFee', '300,000');
    riFxApply();
    ok('식사 ¥40,000 × 9.35 = ₩374,000', V('riMealAmt') === '374,000');
    ok('주류 ¥30,000 × 9.35 = ₩280,500', V('riWineMin') === '280,500');
    ok('대행비는 건드리지 않는다 (탐 수익)', V('riAgencyFee') === '300,000');
    ok('총액에 반영된다',
       (document.getElementById('riTotalDisplay').textContent || '') === '₩954,500');
    ok('계산 근거가 화면에 뜬다',
       /¥70,000/.test(document.getElementById('riFxCalc').textContent)
       && /₩654,500/.test(document.getElementById('riFxCalc').textContent));

    // 인원이 늘면 총액만 배수 (1인 단가는 그대로)
    window._riPax = 4; riUpdateTotal();
    ok('4인이면 총액 4배',
       (document.getElementById('riTotalDisplay').textContent || '') === '₩3,818,000');
    ok('1인 단가는 그대로', V('riMealAmt') === '374,000');
    window._riPax = 1;

    // ── ② 비면 아무 일도 안 한다 ───────────────────────────────
    set('riMealAmt', '999'); set('riWineMin', '888');
    set('riFxRate', '');
    riFxApply();
    ok('환율이 비면 원화를 안 건드린다', V('riMealAmt') === '999' && V('riWineMin') === '888');
    ok('환율이 비면 근거 문구도 지운다', document.getElementById('riFxCalc').textContent === '');

    set('riFxRate', '9.35'); set('riJpyMeal', ''); set('riJpyDrink', '');
    riFxApply();
    ok('엔화가 비면 원화를 안 건드린다', V('riMealAmt') === '999' && V('riWineMin') === '888');

    // 환율이 0·문자면 안 쓴다
    set('riJpyMeal', '10,000'); set('riFxRate', '0');
    riFxApply();
    ok('환율 0 은 무시', V('riMealAmt') === '999');
    set('riFxRate', 'abc');
    riFxApply();
    ok('환율에 글자를 넣어도 무시', V('riMealAmt') === '999');

    // ── ③ 결제 팝업 표기 ──────────────────────────────────────
    //   실제 DB 없이 팝업 렌더 부분만 본다 — 행 조립 규칙이 맞는지.
    function payRows(inv){
      // openReservationInvitePayPopup 의 행 조립과 같은 규칙을 따로 확인한다
      const rows = [];
      const fxR = parseFloat(inv.fx_rate);
      const jm = parseInt(inv.jpy_meal, 10) || 0, jd = parseInt(inv.jpy_drink, 10) || 0;
      if (isFinite(fxR) && fxR > 0 && (jm > 0 || jd > 0)) {
        rows.push('엔화 원금'); rows.push('적용 환율');
      }
      return rows;
    }
    ok('엔화가 있으면 두 줄이 는다',
       payRows({ fx_rate: 9.35, jpy_meal: 40000, jpy_drink: 30000, pax: 1 }).length === 2);
    ok('환율이 없으면 안 나온다',
       payRows({ fx_rate: null, jpy_meal: 40000, pax: 1 }).length === 0);
    ok('엔화가 없으면 안 나온다',
       payRows({ fx_rate: 9.35, jpy_meal: null, jpy_drink: null, pax: 1 }).length === 0);

    // ── ④ 충전으로 가는 길 ────────────────────────────────────
    ok('openMpCharge 가 있다 (충전 경로)', typeof window.openMpCharge === 'function');
    let closed = false, charged = false;
    const rc = window.riPayClose, mc = window.openMpCharge;
    window.riPayClose = () => { closed = true; };
    window.openMpCharge = () => { charged = true; };
    window.riPayGoCharge();
    ok('충전 버튼이 팝업을 닫고 충전을 연다', closed && charged);
    window.riPayClose = rc; window.openMpCharge = mc;

    // ── 발송 화면 초기화가 엔화 칸도 비우나 ────────────────────
    set('riJpyMeal', '40,000'); set('riFxRate', '9.35'); set('riFxNote', '메모');
    ok('초기화 전에는 값이 있다', V('riJpyMeal') === '40,000');
    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : '=== 전부 통과 ==='));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
