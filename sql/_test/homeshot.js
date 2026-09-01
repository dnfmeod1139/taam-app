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
    window.newHomeEnabled = () => true;
    try { localStorage.removeItem('taamMagazine'); } catch(e){}
    ok('표지(매거진)가 홈이다', magEnabled() === true);

    const v = document.getElementById('magView');
    const sheet = document.getElementById('magSheet');
    const open = () => sheet.classList.contains('on');

    // 표지를 한 번 그려 둔다 (여기서부터가 「홈 안」)
    magRender();
    ok('처음엔 시트가 닫혀 있다', !open() && _magDet === 0);

    // 캘린더를 연다
    magOpenSheet();
    ok('📅 를 누르면 캘린더가 열린다', open() && _magDet === 2);

    // ── 홈 안에서 다시 그리는 건 단계를 지킨다 (월 넘기기 등) ──
    magRender();
    ok('홈 안 재렌더는 열린 단계를 지킨다', open() && _magDet === 2);

    // ── 밖에 나갔다 돌아오면 표지부터 ──
    magHide();                       // 계보도·마이페이지·콘솔로 나감
    ok('나가면 표지가 숨는다', v.style.display === 'none');
    magRender();                     // 돌아옴
    ok('돌아오면 캘린더가 접혀 있다', !open() && _magDet === 0);
    ok('📅 버튼이 다시 보인다', !!document.querySelector('#magHero .mag-sched'));

    // ── 계보도 닫기 경로도 시트를 접는다 ──
    magOpenSheet();
    ok('다시 열어 두고', open());
    try { window.LineageModule.close(); } catch(e){}
    ok('계보도를 닫으면 접힌다', !open() && _magDet === 0);

    // ── showView('home') 로 돌아오는 경로 ──
    magOpenSheet();
    showView('home');
    ok("showView('home') 로 와도 접힌다", !open() && _magDet === 0);

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
