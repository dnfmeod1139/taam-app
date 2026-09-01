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

    // 표지를 한 번 그려 둔다 (여기서부터가 「홈 안」) — 홈을 여는 자리라 force
    magRender(true);
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
    magRender(true);                 // 홈으로 돌아옴
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

    // ── 홈이 아닌 화면 위로 표지가 다시 올라오지 않는다 ──
    //   pcalRenderAll() 이 끝에서 magRender() 를 부른다. 종전엔 그 한 번에
    //   티켓 목록 위로 표지가 도로 올라오고 시트까지 열렸다.
    magRender(true);
    magOpenSheet();
    ok('홈에서는 표지가 뜨고 시트도 열린다', v.style.display === 'block' && open());

    // ⚠ showView('ticket') 은 이제 입구에서 'home' 으로 돌아간다(옛 티켓 화면 차단).
    //   홈을 실제로 떠나는 건 계보도·요청 탭이다.
    showView('contents');                     // 계보도 탭으로 이동
    ok('탭을 옮기면 표지가 내려간다', v.style.display === 'none');
    ok('그때 시트도 접힌다', !open() && _magDet === 0);

    // pcalRenderAll 이 끝에서 부르는 그 호출 — 이게 표지를 도로 올리고 있었다
    magRender();
    ok('내려둔 표지는 스스로 안 올라온다', v.style.display === 'none');
    ok('시트도 그대로 접혀 있다', !open());
    pcalRenderAll();
    ok('pcalRenderAll 로도 안 올라온다', v.style.display === 'none');

    // ── 표지가 뜰 때 옛 티켓 화면은 반드시 내려간다 ──
    const tv = document.getElementById('ticketView');
    tv.style.display = 'block';
    magRender(true);
    ok('표지가 뜨면 옛 티켓 목록은 내려간다',
       v.style.display === 'block' && getComputedStyle(tv).display === 'none');

    // ── 옛 티켓 화면은 아예 목적지가 아니다 ──
    tv.style.display = 'block';
    showView('ticket');
    ok("showView('ticket') 이 홈으로 돌아간다", getComputedStyle(tv).display === 'none');

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
