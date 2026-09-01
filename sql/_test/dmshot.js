const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 780 } });
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    document.getElementById('appWrapper').classList.add('ready');
    // ⚠ 이 화면은 #mainScreen 안에 있다. 부모가 display:none 이면 position:fixed
    //   여도 높이가 0 이라 스크롤을 잴 수 없다 — 실제 앱처럼 켜 둔다.
    document.getElementById('mainScreen').style.display = 'flex';
    const sc = document.getElementById('depositMgmtScreen');
    sc.style.display = 'flex';

    const scroll = sc.querySelector('.dm-scroll');
    const sum = document.getElementById('dmMgmtSummary');
    const list = document.getElementById('dmMgmtList');
    ok('요약과 목록이 한 스크롤 안에 있다',
       !!scroll && scroll.contains(sum) && scroll.contains(list));
    ok('스크롤은 바깥이 맡는다', getComputedStyle(scroll).overflowY === 'auto');
    ok('목록은 더 이상 스스로 스크롤하지 않는다', getComputedStyle(list).flexGrow === '0');

    // 반환완료·환불 탭처럼 요약이 길어진 상황
    sum.innerHTML = '<div style="width:100%">'
      + '<div style="font-size:26px;font-weight:800">₩3,600,000</div>'
      + Array.from({length: 6}, (_, i) =>
          '<div style="display:flex;justify-content:space-between;padding:6px 0;">'
          + '<span>항목 ' + (i+1) + '</span><span>₩700,000</span></div>').join('')
      + '</div>';
    list.innerHTML = Array.from({length: 14}, (_, i) =>
      '<div class="dm-item" style="height:90px">내역 ' + (i+1) + '</div>').join('');

    ok('내용이 화면보다 길다', scroll.scrollHeight > scroll.clientHeight + 50);
    // 실제로 끝까지 내려가나
    scroll.scrollTop = scroll.scrollHeight;
    ok('맨 아래까지 스크롤된다',
       scroll.scrollTop > 0 && scroll.scrollTop + scroll.clientHeight >= scroll.scrollHeight - 2);
    const last = list.lastElementChild.getBoundingClientRect();
    ok('마지막 내역이 화면 안에 들어온다', last.bottom <= window.innerHeight + 2 && last.top >= 0);

    // 요약이 짧을 때(반환예정)도 그대로 된다
    sum.innerHTML = '<div>반환예정 3건</div>';
    scroll.scrollTop = 0;
    ok('요약이 짧아도 목록은 그대로', list.children.length === 14);

    // ── 티켓 업로드가 콘솔 탭 밑에 안 깔린다 ──
    const z = n => parseInt(getComputedStyle(document.getElementById(n)).zIndex, 10);
    ok('티켓 업로드가 콘솔 탭보다 위 (' + z('tuScreen') + ' > ' + z('todayBoardScreen') + ')',
       z('tuScreen') > z('todayBoardScreen'));
    ok('레스토랑 등록도 위 (' + z('restPage') + ')', z('restPage') > z('todayBoardScreen'));

    // 이동 잠금 — 메뉴로 가는 중에는 대시보드가 안 열린다
    ok('_acNavHold 가 있다', typeof _acNavHold === 'function');
    ok('네 경로가 모두 잠근다',
       /_acNavHold\(\)/.test(String(acOpenMenu)) && /_acNavHold\(\)/.test(String(acMenuGo))
       && /_acNavHold\(\)/.test(String(moGo)) && /_acNavHold\(\)/.test(String(qmGo)));
    ok('_acEnsureConsole 이 잠금을 본다', /_acNavUntil/.test(String(_acEnsureConsole)));

    sc.style.display = 'none';
    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
