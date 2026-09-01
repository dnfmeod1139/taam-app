const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  await p.evaluate(() => {
    document.getElementById('appWrapper').classList.add('ready');
    window._currentRole = 'superadmin';
    window._isSuperAdmin = () => true;
    window._tbRows = []; window.ticketDB = [];
    window._qmCfg = []; window._qmCfgRole = 'superadmin'; window._qmPulled = true;
  });

  const d = async id => p.evaluate(i => {
    const e = document.getElementById(i); return e ? getComputedStyle(e).display : '(없음)';
  }, id);

  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  // ── 어떤 메뉴에 들어갔다 나와도 대시보드 ──
  for (const id of ['restListScreen','ticketListScreen','memberListScreen','depositMgmtScreen','partnerQrScreen']) {
    await p.evaluate(i => { openAdmin(); _acCloseOthers(null); openSubPage(i); }, id);
    await p.waitForTimeout(60);
    const opened = await d(id);
    await p.evaluate(i => closeSubPage(i), id);
    await p.waitForTimeout(120);
    ok(id + ' 에서 뒤로 → 대시보드',
       opened !== 'none' && (await d('todayBoardScreen')) !== 'none' && (await d(id)) === 'none');
  }

  // ── 겹쳐 열린 경우엔 한 겹만 벗긴다 ──
  await p.evaluate(() => { openAdmin(); _acCloseOthers(null);
    openSubPage('ticketListScreen'); openSubPage('ticketHistoryScreen'); });
  await p.waitForTimeout(60);
  await p.evaluate(() => closeSubPage('ticketHistoryScreen'));
  await p.waitForTimeout(120);
  // ⚠ closeSubPage → openAdmin → closeAllAdminScreens 가 아래 것까지 닫는다.
  //   이건 예전부터 그랬다(겹쳐 열기를 지원한 적이 없다). 그래서 위를 닫으면
  //   스택 전체가 걷히고 대시보드로 온다 — 「어디서든 대시보드」와 같은 결과다.
  ok('겹쳐 열려 있어도 뒤로 → 대시보드',
     (await d('ticketListScreen')) === 'none'
     && (await d('ticketHistoryScreen')) === 'none'
     && (await d('todayBoardScreen')) !== 'none');

  // ── openAdmin() 을 그냥 불러도 거기 안 남는다 ──
  await p.evaluate(() => { _acCloseOthers(null); openAdmin(); });
  await p.waitForTimeout(120);
  ok('openAdmin() 만 불러도 대시보드로', (await d('todayBoardScreen')) !== 'none');

  // ── ← 는 여전히 콘솔을 나간다 (되돌아오지 않는다) ──
  await p.evaluate(() => { window.openMain = function(){}; });
  await p.evaluate(() => acExit());
  await p.waitForTimeout(200);
  ok('✕ 로 콘솔이 닫히고 대시보드가 다시 안 열린다',
     (await d('todayBoardScreen')) === 'none' && (await d('adminScreen')) === 'none');

  // ── 처리할 일 줄이 눌린다 ──
  const todo = await p.evaluate(() => {
    window._dashExtra = { resvPending: 2, deposit: 0 };
    window.ticketDB = [{ status:'pending' }];
    window._tbRows = [];
    openAdmin(); _acCloseOthers(null);
    document.getElementById('todayBoardScreen').style.display = 'flex';
    _dashRender();
    const rows = [...document.querySelectorAll('#tbBody .todo > *')];
    return rows.map(r => ({ tag: r.tagName, on: r.getAttribute('onclick') || '', t: r.querySelector('.t').textContent }));
  });
  ok('처리할 일이 버튼이다', todo.length === 2 && todo.every(r => r.tag === 'BUTTON'));
  ok('티켓 승인 → 승인 대기 화면',
     todo.some(r => r.t === '티켓 업로드 승인' && r.on === "acOpenMenu('pendingApprovalScreen')"));
  ok('파트너 요청 → 예약 관리 화면',
     todo.some(r => r.t === '파트너 예약 요청' && r.on === "acOpenMenu('reservationAdminScreen')"));

  // 실제로 눌러 본다
  await p.evaluate(() => {
    [...document.querySelectorAll('#tbBody .todo > button')]
      .find(b => b.textContent.indexOf('파트너 예약 요청') === 0).click();
  });
  await p.waitForTimeout(150);
  ok('눌러서 예약 관리가 열린다', (await d('reservationAdminScreen')) !== 'none');
  await p.evaluate(() => closeSubPage('reservationAdminScreen'));
  await p.waitForTimeout(150);
  ok('거기서 뒤로 → 다시 대시보드', (await d('todayBoardScreen')) !== 'none');

  out.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(out.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
