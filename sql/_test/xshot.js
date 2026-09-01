const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    document.getElementById('appWrapper').classList.add('ready');
    window._currentRole = 'superadmin';
    window._isSuperAdmin = () => true;
    window._tbRows = []; window.ticketDB = []; window._mbRows = [];
    window._qmCfg = []; window._qmCfgRole = 'superadmin'; window._qmPulled = true;
    const adm = document.getElementById('adminScreen');
    adm.style.display = 'flex';
    const d = id => { const e = document.getElementById(id); return e ? getComputedStyle(e).display : '(없음)'; };

    const IDS = ['todayBoardScreen','rvScreen','tkbScreen','mbScreen','pshScreen','moScreen'];

    // ── ✕ 가 여섯 화면 전부에 있다 ──
    const xs = IDS.map(id => document.querySelector('#' + id + ' .ac-x'));
    ok('여섯 화면 모두 ✕ 가 있다', xs.every(Boolean));
    ok('✕ 는 전부 acExit()', xs.every(x => (x.getAttribute('onclick')||'') === 'acExit()'));
    ok('✕ 가 헤더의 맨 오른쪽',
       IDS.every(id => {
         const hd = document.querySelector('#' + id + ' .sub-header');
         return hd.lastElementChild === hd.querySelector('.ac-x')
             || hd.querySelector('.ac-x').parentElement !== hd;   // 대시보드는 묶음 안
       }));

    // ── 대시보드의 ← 는 숨긴다 (뒤로 갈 위가 없다) ──
    ok('대시보드 ← 는 숨김',
       getComputedStyle(document.getElementById('tbBackBtn')).visibility === 'hidden');

    // ── ← 는 어느 탭에서든 대시보드 ──
    for (const id of ['rvScreen','tkbScreen','mbScreen','moScreen']) {
      _acCloseOthers(null);
      document.getElementById(id).style.display = 'flex';
      acBack();
      if (d('todayBoardScreen') === 'none' || d(id) !== 'none') {
        ok(id + ' 에서 ← → 대시보드', false); break;
      }
      if (d('adminScreen') === 'none') { ok('← 가 콘솔을 닫지 않는다', false); break; }
    }
    ok('예약·티켓·회원·더보기에서 ← → 대시보드 (콘솔 유지)',
       d('todayBoardScreen') !== 'none' && d('adminScreen') !== 'none');

    // 대시보드에서 ← 를 눌러도 앱으로 나가지 않는다
    acBack();
    ok('대시보드 ← 는 앱으로 안 나간다', d('todayBoardScreen') !== 'none' && d('adminScreen') !== 'none');

    // ── ✕ 는 앱으로 ──
    let outMain = 0; const realMain = window.openMain; window.openMain = function(){ outMain++; };
    acExit();
    ok('✕ → 콘솔이 닫히고 앱으로', d('todayBoardScreen') === 'none' && d('adminScreen') === 'none' && outMain === 1);
    window.openMain = realMain;

    // ── 계보도 닫기 → 홈은 처음 상태 ──
    ok('LineageModule.close 가 시트를 닫는다',
       /magCloseSheet/.test(String(window.LineageModule.close))
       && /magScroll/.test(String(window.LineageModule.close)));
    // 실제로 시트를 열어 두고 닫아 본다
    const sheet = document.getElementById('magSheet');
    if (sheet) {
      sheet.classList.add('on','d1');
      try { window.LineageModule.close(); } catch(e){}
      ok('계보도를 닫으면 캘린더 시트가 접힌다', !sheet.classList.contains('on'));
    } else { ok('magSheet 가 있다', false); }

    adm.style.display = 'none';
    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
