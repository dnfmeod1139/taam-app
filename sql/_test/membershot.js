const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const d = i => { const e = document.getElementById(i); return e ? getComputedStyle(e).display : '(없음)'; };
    document.getElementById('appWrapper').classList.add('ready');
    document.getElementById('mainScreen').style.display = 'flex';
    var sp = document.getElementById('splash-ov'); if(sp) sp.remove();
    [...document.body.children].forEach(n => { try{ if(getComputedStyle(n).zIndex==='99999') n.remove(); }catch(e){} });

    // ── 일반 회원 ──
    window._currentRole = 'user';
    window._isSuperAdmin = () => false;
    window.showToast = function(){};
    let toasted = null;
    window.showToast = function(a, t){ toasted = t; };

    ok('세 플래그가 다 켜져 있다 (회원도 캘린더 홈)',
       NEW_HOME_LIVE === true && MAGAZINE_LIVE === true && newHomeEnabled() === true && magEnabled() === true);

    // ── 옛 티켓 화면은 회원에게도 절대 안 뜬다 ──
    const tv = document.getElementById('ticketView');
    const paths = [
      ['showView 직접',        () => showView('ticket')],
      ['GNB Home',             () => gnbGo('home', document.getElementById('gnbHome'))],
      ['GNB Ticket(옛 탭)',    () => gnbGo('ticket', document.getElementById('gnbHome'))],
      ['Quest 되돌아오기',     () => gnbGo('quest', document.getElementById('gnbQuest'))],
      ['Market 되돌아오기',    () => gnbGo('market', document.getElementById('gnbMarket'))]
    ];
    let leak = [];
    for (const [name, fn] of paths) {
      tv.style.display = 'block';           // 억지로 열어 두고
      try { fn(); } catch(e) {}
      if (getComputedStyle(tv).display !== 'none') leak.push(name);
    }
    ok('다섯 경로 어디로도 옛 티켓 화면이 안 뜬다' + (leak.length ? ' — 샌 곳: ' + leak.join(', ') : ''),
       leak.length === 0);

    // ── 홈은 표지 ──
    gnbGo('home', document.getElementById('gnbHome'));
    ok('홈은 표지(매거진)', d('magView') === 'block');
    ok('표지에 📅 버튼이 있다', !!document.querySelector('#magHero .mag-sched'));
    ok('캘린더 시트는 접혀 있다', !document.getElementById('magSheet').classList.contains('on'));

    // ── My Page 는 마이페이지 (콘솔 아님) ──
    let opened = false;
    const realMy = window.openMyPage; window.openMyPage = function(){ opened = true; };
    gnbGo('my', document.getElementById('gnbMy'));
    ok('회원의 My Page 는 마이페이지', opened === true);
    ok('콘솔이 열리지 않는다', d('todayBoardScreen') === 'none' && d('adminScreen') === 'none');
    window.openMyPage = realMy;

    // ── 회원은 콘솔 탭에 못 들어간다 ──
    for (const [fn, id, name] of [[tbOpen,'todayBoardScreen','대시보드'], [mbOpen,'mbScreen','회원'],
                                  [tkbOpen,'tkbScreen','티켓'], [rvOpen,'rvScreen','예약']]) {
      toasted = null;
      try { await fn(); } catch(e) {}
      ok('회원은 ' + name + ' 탭을 못 연다', d(id) === 'none');
    }
    ok('막힐 때 안내가 뜬다 (' + (toasted || '없음') + ')', !!toasted);

    // ── 앱을 켜도 콘솔이 자동으로 안 열린다 ──
    ok('자동 진입은 어드민에게만',
       /_currentRole === 'superadmin' \|\| _currentRole === 'admin'/.test(String(openMain)));

    // ── 계보도를 닫고 나와도 표지 ──
    gnbGo('home', document.getElementById('gnbHome'));
    magOpenSheet();
    tv.style.display = 'block';
    try { window.LineageModule.close(); } catch(e) {}
    await new Promise(r => setTimeout(r, 120));
    ok('계보도 닫기 → 캘린더 접힘', !document.getElementById('magSheet').classList.contains('on'));
    ok('계보도 닫기 → 옛 티켓 화면 없음', getComputedStyle(tv).display === 'none');

    // ── 구매 경로는 살아 있다 ──
    ok('날짜에서 여는 길이 있다', typeof pcalOpenDay === 'function');
    ok('티켓 상세 화면이 있다', !!document.getElementById('ticketDetailScreen'));
    ok('구매 시트가 있다', !!document.getElementById('tdPurchaseSheet'));
    ok('옛 티켓 화면을 거치지 않는다',
       !/showView\('ticket'\)/.test(String(pcalOpenDay)));

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.slice(0,2).join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
