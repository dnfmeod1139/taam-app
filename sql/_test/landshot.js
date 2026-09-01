const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    window._currentRole = 'superadmin';
    const adm = document.getElementById('adminScreen');
    adm.style.display = 'flex';

    // ── 「전체 메뉴」 첫 화면이 접혔나 ──
    const land = document.getElementById('acLanding');
    ok('#acLanding 이 있다', !!land);
    ok('첫 화면 카드·Quick Access 가 안 보인다', getComputedStyle(land).display === 'none');
    const cards = ['tbOpen()','rvOpen()','tkbOpen()','moOpen()'].map(fn =>
      Array.prototype.find.call(adm.querySelectorAll('#acLanding button'),
        e => (e.getAttribute('onclick')||'') === fn));
    ok('카드 넷이 접힌 안쪽에 그대로 있다 (지우지 않았다)', cards.every(Boolean));
    // ⚠ getComputedStyle 은 부모가 display:none 이어도 자기 값을 그대로 돌려준다.
    //   「접혔나」는 접힌 상자 안에 있는지로 본다.
    const qa = document.getElementById('quickAccessRow');
    ok('옛 Quick Access 도 접힌 상자 안', qa && land.contains(qa) && qa.getClientRects().length === 0);
    const bt0 = document.getElementById('acBuildTag');
    ok('옛 BUILD 자리도 접힌 상자 안', bt0 && land.contains(bt0));
    const lb = document.getElementById('acLeanBtn');
    ok('「전체 메뉴 펴기」 버튼도 접혔다', lb && land.contains(lb));

    // ── 그래도 메뉴 원본은 살아 있나 ──
    _acApplyLean();
    ok('늘 접힘 (_acLeanOn 고정)', _acLeanOn() === true && adm.classList.contains('ac-lean'));
    const rows = _moScan();
    ok('메뉴 51개를 그대로 훑는다 (' + rows.length + ')', rows.length === 51);
    ok('자주 쓰는 메뉴 기본값도 잡힌다', _qmDefault(rows).length === 5);

    // ── ← 는 콘솔을 나간다 ──
    ok('acBack 존재', typeof acBack === 'function');
    const backs = ['todayBoardScreen','rvScreen','tkbScreen','mbScreen','moScreen','pshScreen']
      .map(id => document.querySelector('#' + id + ' .sub-back'));
    ok('여섯 화면 모두 ← 가 acBack()',
       backs.every(b => b && (b.getAttribute('onclick')||'') === 'acBack()'));

    // 실제로 눌러 본다 — 대시보드를 열고 ← 를 누르면 어드민 화면까지 닫혀야 한다
    const dash = document.getElementById('todayBoardScreen');
    dash.style.display = 'flex';
    document.querySelector('#todayBoardScreen .ac-x').click();
    ok('✕ 로 대시보드가 닫힌다', getComputedStyle(dash).display === 'none');
    ok('✕ 로 「전체 메뉴」가 드러나지 않는다', getComputedStyle(adm).display === 'none');

    // ── 빌드 번호가 대시보드로 옮겨졌나 ──
    window._tbRows = []; window._qmCfg = []; window._qmCfgRole = 'superadmin'; window._qmPulled = true;
    adm.style.display = 'flex';
    const body = document.getElementById('tbBody');
    _dashRender();
    const bt = body.querySelector('.dash-build');
    ok('대시보드 맨 아래에 BUILD', !!bt && bt.textContent.indexOf('BUILD ' + TAAM_WEB_BUILD) === 0);
    ok('눌러서 복사도 그대로', (bt.getAttribute('onclick')||'') === 'acCopyBuild()');
    ok('BUILD 가 맨 마지막', body.lastElementChild === bt);

    adm.style.display = 'none';

    // ── 파트너 화면도 같이 접혔나 ──
    window._currentRole = 'admin';
    const pa = document.getElementById('partnerAdminScreen');
    pa.style.display = 'flex';
    const paLand = document.getElementById('paLanding');
    ok('#paLanding 이 있다', !!paLand && getComputedStyle(paLand).display === 'none');
    ok('파트너 카드 셋도 접힌 안쪽에 그대로',
       ['tbOpen()','rvOpen()','tkbOpen()'].every(fn =>
         Array.prototype.some.call(paLand.querySelectorAll('button'),
           e => (e.getAttribute('onclick')||'') === fn)));
    ok('파트너 빌드 태그도 접혔다',
       paLand.contains(document.getElementById('paBuildTag')));
    const paRows = _moScan();
    ok('파트너 메뉴 원본은 살아 있다 (' + paRows.length + ')', paRows.length >= 5 && paRows.length <= 10);
    ok('파트너 메뉴에 슈퍼어드민 것이 안 섞인다',
       !paRows.some(r => r.title.indexOf('예치금') >= 0 || r.title.indexOf('환율') >= 0));
    pa.style.display = 'none';
    window._currentRole = 'superadmin';

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
