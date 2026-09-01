const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 780 } });
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const setup = () => p.evaluate(() => {
    document.getElementById('appWrapper').classList.add('ready');
    document.getElementById('mainScreen').style.display = 'flex';
    // ⚠ 헤드리스에는 Supabase 가 없어 「연결에 실패했습니다」 전체 덮개(z 99999)가
    //   뜬다. 실제 앱에는 없는 것이라 걷어내고 잰다.
    [...document.body.children].forEach(function(n){
      try{ if(getComputedStyle(n).zIndex === '99999') n.remove(); }catch(e){}
    });
    var _sp = document.getElementById('splash-ov'); if(_sp) _sp.remove();
    window._currentRole = 'superadmin';
    window._isSuperAdmin = () => true;
    window._tbRows = []; window.ticketDB = []; window._mbRows = [];
    window._acBans = []; window._acRules = [{restaurant_id:'*'}];
    window._dashExtra = { resvPending:0, deposit:0 };
    window._qmCfg = []; window._qmCfgRole = 'superadmin'; window._qmPulled = true;
    window.showToast = function(){};
    openAdminConsole(false);
  });

  const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const vis = id => p.evaluate(i => {
    const e = document.getElementById(i); return !!e && getComputedStyle(e).display !== 'none';
  }, id);
  // 앱의 전체화면 판들 중에서 이 화면이 맨 위인가.
  //   ⚠ elementFromPoint 로 재면 헤드리스에만 있는 스플래시·연결실패 덮개가 걸린다.
  //     그건 실제 앱에 없는 것이라, 앱 화면끼리만 z-order 를 비교한다.
  const top = id => p.evaluate(i => {
    const SEL = '.sub-screen, .restpage, .tu-screen, .admin-screen, .partner-screen';
    const me = document.getElementById(i);
    if(!me || getComputedStyle(me).display === 'none') return '안 열려 있음';
    const mz = parseInt(getComputedStyle(me).zIndex, 10) || 0;
    const over = [...document.querySelectorAll(SEL)].filter(function(n){
      if(n === me) return false;
      if(getComputedStyle(n).display === 'none') return false;
      const z = parseInt(getComputedStyle(n).zIndex, 10) || 0;
      // 같은 z 면 DOM 순서가 늦은 쪽이 위
      return z > mz || (z === mz &&
        (me.compareDocumentPosition(n) & Node.DOCUMENT_POSITION_FOLLOWING));
    });
    return over.length ? ('가린 것: ' + over.map(n => '#' + n.id).join(', ')) : true;
  }, id);

  // ── 「더보기」에서 티켓 업로드를 실제로 누른다 ──
  await setup();
  await p.waitForTimeout(120);
  const opened = await p.evaluate(async () => {
    await moOpen();                       // 실사용대로 「더보기」 탭을 연다
    const list = (_moRows || []).filter(r => _moHit(r, ''));
    const i = list.findIndex(r => r.title.indexOf('티켓 업로드') === 0);
    if(i < 0) return 'menu-not-found';
    moGo(i);
    return 'clicked';
  });
  ok('더보기에 「티켓 업로드」가 있다', opened === 'clicked');
  await p.waitForTimeout(400);
  ok('티켓 업로드 화면이 열린다', await vis('tuScreen'));
  const t1 = await top('tuScreen');
  ok('대시보드 밑에 안 깔린다 (맨 위에 보인다) ' + (t1===true?'':'— '+t1), t1 === true);
  ok('대시보드는 닫혀 있다', !(await vis('todayBoardScreen')));

  // 닫으면 대시보드로 돌아온다 (이동 잠금 700ms 가 풀린 뒤에 닫는다 — 실사용은 몇 초 뒤다)
  await p.waitForTimeout(800);
  await p.evaluate(() => { if(typeof closeTU === 'function') closeTU(); else closeSubPage('tuScreen'); });
  await p.waitForTimeout(300);
  ok('닫으면 대시보드로 돌아온다', await vis('todayBoardScreen') && !(await vis('tuScreen')));

  // ── 대시보드의 「자주 쓰는 메뉴」에서도 같다 ──
  await setup();
  await p.waitForTimeout(120);
  const q = await p.evaluate(() => {
    const rows = _moScan();
    const t = rows.find(r => r.title.indexOf('티켓 업로드') === 0);
    if(!t) return 'no';
    window._qmCfg = [_qmKey(t)]; window._qmCfgRole = 'superadmin';
    _dashRender();
    const btn = document.querySelector('#tbBody .qm-b');
    if(!btn) return 'no-btn';
    btn.click(); return 'ok';
  });
  ok('자주 쓰는 메뉴에 등록·표시된다', q === 'ok');
  await p.waitForTimeout(400);
  const t2 = await top('tuScreen');
  ok('거기서 눌러도 화면이 맨 위에 열린다 ' + (t2===true?'':'— '+t2),
     (await vis('tuScreen')) && t2 === true);

  out.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.slice(0,2).join(' | ') : '없음');
  console.log(out.some(l => l.startsWith('FAIL')) ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
