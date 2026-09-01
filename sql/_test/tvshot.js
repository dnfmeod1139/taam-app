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
    document.getElementById('appWrapper').classList.add('ready');
    document.getElementById('mainScreen').style.display = 'flex';
    window.newHomeEnabled = () => true;
    window._isSuperAdmin = () => true;
    window._currentRole = 'superadmin';

    // ── 옛 티켓 화면은 어떤 경로로도 안 열린다 ──
    showView('ticket');
    ok("showView('ticket') → 티켓 화면이 안 열린다", d('ticketView') === 'none');
    ok('대신 홈이 열린다', d('homeView') !== 'none' || d('magView') === 'block');

    // 억지로 열어 두고 다시 불러도 닫힌다
    document.getElementById('ticketView').style.display = 'block';
    showView('ticket');
    ok('열려 있어도 다시 부르면 닫힌다', d('ticketView') === 'none');

    // GNB 의 Home
    document.getElementById('ticketView').style.display = 'block';
    gnbGo('home', document.getElementById('gnbHome'));
    ok('GNB Home → 티켓 화면 안 뜬다', d('ticketView') === 'none');

    // 매거진을 꺼도 옛 화면으로 안 간다
    document.getElementById('ticketView').style.display = 'block';
    try { toggleMagazine(); } catch(e){}
    ok('매거진 토글 → 티켓 화면 안 뜬다', d('ticketView') === 'none');
    try { toggleMagazine(); } catch(e){}   // 원래대로

    // 계보도 닫기 경로
    document.getElementById('ticketView').style.display = 'block';
    document.querySelectorAll('.gnb-btn').forEach(x => x.classList.remove('active'));
    document.getElementById('gnbHome').classList.add('active');
    try { window.LineageModule.close(); } catch(e){}
    return new Promise(res => setTimeout(() => {
      ok('계보도 닫기 → 티켓 화면 안 뜬다', d('ticketView') === 'none');
      ok('캘린더 시트도 접혀 있다', !document.getElementById('magSheet').classList.contains('on'));

      // ── 사진 캘린더를 끈 기기에서는 옛 화면이 유일한 홈이라 그대로 열린다 ──
      window.newHomeEnabled = () => false;
      showView('ticket');
      ok('사진 캘린더가 꺼져 있으면 옛 홈은 그대로 열린다', d('ticketView') !== 'none');
      window.newHomeEnabled = () => true;

      // ── showView 입구에 가드가 실제로 있는가 ──
      ok('가드가 showView 안에 있다',
         /view === 'ticket'[\s\S]{0,200}newHomeEnabled/.test(String(showView)));
      res(out);
    }, 200));
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
