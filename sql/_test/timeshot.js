const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    window.ticketDB = [
      { id: 'tp1', time: '20:00' },
      { id: 'tp2', time: '11:30' },
      { id: 'tp3' }                       // 시각이 없는 상품
    ];

    // ── _tbTime ──
    ok('일반 예약은 그대로', _tbTime({ visit_time:'20:00' }) === '20:00');
    ok('한 자리 시는 0 을 채운다', _tbTime({ visit_time:'9:05' }) === '09:05');
    ok('초 가 붙어 있어도 시:분만', _tbTime({ visit_time:'18:30:00' }) === '18:30');
    ok('초대 예약은 티켓 상품에서 가져온다',
       _tbTime({ visit_time:'', ticket_product_id:'tp1' }) === '20:00');
    ok('상품 시각이 우선순위 뒤 (직접 값이 있으면 그것)',
       _tbTime({ visit_time:'19:00', ticket_product_id:'tp1' }) === '19:00');
    ok('상품에도 시각이 없으면 빈 값',
       _tbTime({ visit_time:'', ticket_product_id:'tp3' }) === '');
    ok('상품 자체가 없으면 빈 값',
       _tbTime({ visit_time:'', ticket_product_id:'없음' }) === '');
    ok('아무것도 없으면 빈 값', _tbTime({}) === '');

    // ── 칸 렌더 ──
    const d = document.createElement('div');
    d.innerHTML = _tbTimeCell({ visit_time:'20:00' });
    ok('한 줄로 20:00', d.querySelector('.tm').textContent === '20:00');
    ok('두 줄로 쪼개던 <small> 이 없다', !d.querySelector('.tm small'));
    d.innerHTML = _tbTimeCell({ visit_time:'', ticket_product_id:'tp2' });
    ok('초대도 11:30 으로 나온다', d.querySelector('.tm').textContent === '11:30');
    d.innerHTML = _tbTimeCell({});
    ok('정말 모를 때만 「시간 미정」',
       d.querySelector('.tm.none') && d.querySelector('.tm').textContent.replace(/\s/g,'') === '시간미정');

    // ── 정렬도 같은 시각을 쓴다 (초대가 맨 뒤로 밀리지 않게) ──
    ok('초대 예약 정렬값이 20:00 기준',
       _tbMins(_tbTime({ visit_time:'', ticket_product_id:'tp1' })) === 20*60);
    ok('시각을 모르면 맨 뒤(9999)', _tbMins(_tbTime({})) === 9999);

    // ── 두 화면 모두 같은 칸을 쓴다 ──
    ok('예약·오늘 두 줄 렌더가 같은 카드를 쓴다',
       /_tbCard\(r/.test(String(_rvRow)) && /_tbCard\(r/.test(String(_tbRow)));
    ok('그 카드가 _tbTime 을 쓴다', /_tbTime\(r\)/.test(String(_tbCard)));

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
