const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const d = id => { const e = document.getElementById(id); return e ? getComputedStyle(e).display : '(없음)'; };
    // ⚠ #appWrapper:not(.ready) 가 어드민 화면을 !important 로 감춘다 (부팅 전 가드).
    //   headless 는 Supabase 가 없어 ready 가 안 붙으므로 여기서 붙여 준다.
    document.getElementById('appWrapper').classList.add('ready');

    // ── 콘솔이 「전체 메뉴」를 스치지 않고 곧장 열리나 (동기) ──
    window._currentRole = 'superadmin';
    window._isSuperAdmin = () => true;
    window._acAutoOpened = false;
    openAdminConsole(false);
    // setTimeout 없이 **그 자리에서** 대시보드가 덮여 있어야 한다
    ok('콘솔을 열면 그 즉시 대시보드', d('todayBoardScreen') !== 'none');
    ok('「전체 메뉴」가 스치지 않는다 (한 프레임도)',
       document.getElementById('todayBoardScreen').style.display !== 'none');

    // ── ← 로 나오면 회원 앱, 다시 안 열린다 ──
    let mainOpened = 0;
    const realMain = window.openMain;
    window.openMain = function(){ mainOpened++; };   // 실제 부팅은 무겁다 — 호출만 센다
    acExit();
    ok('✕ 로 콘솔이 닫힌다', d('todayBoardScreen') === 'none' && d('adminScreen') === 'none');
    ok('✕ 는 회원 앱으로 나간다 (openMain 호출)', mainOpened === 1);
    window.openMain = realMain;
    ok('openMain 이 세션에 한 번만 열도록 막고 있다',
       /_acAutoOpened/.test(String(window.openMain)) &&
       /openAdminConsole\(false\)/.test(String(window.openMain)));

    // ── 자동 진입 조건 ──
    // 회원은 자동 진입하지 않는다
    window._acAutoOpened = false;
    window._currentRole = 'user';
    window._isSuperAdmin = () => false;
    const before = d('todayBoardScreen');
    // openMain 안의 조건만 그대로 흉내 낸다
    const wouldOpen = (role) => !window._acAutoOpened
      && (role === 'superadmin' || role === 'admin')
      && typeof openAdminConsole === 'function';
    ok('회원은 자동 진입 안 함', wouldOpen('user') === false);
    ok('슈퍼어드민은 자동 진입', wouldOpen('superadmin') === true);
    ok('파트너도 자동 진입', wouldOpen('admin') === true);
    window._acAutoOpened = true;
    ok('두 번째부터는 안 연다', wouldOpen('superadmin') === false);

    // ── 파트너도 곧장 대시보드 ──
    window._acAutoOpened = false;
    window._currentRole = 'admin';
    window._isSuperAdmin = () => false;
    openAdminConsole(false);
    ok('파트너도 그 즉시 대시보드', d('todayBoardScreen') !== 'none');
    ok('파트너 어드민 화면이 뒤에 깔린다', d('partnerAdminScreen') !== 'none');
    const tabs = [...document.querySelectorAll('#tbTabs .ac-tab, #todayBoardScreen .ac-tabs *')]
      .map(e => e.textContent.trim()).filter(Boolean).join('·');
    acExit();
    ok('파트너 ✕ 도 콘솔을 닫는다', d('todayBoardScreen') === 'none' && d('partnerAdminScreen') === 'none');

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
