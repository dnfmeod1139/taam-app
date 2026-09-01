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
    window._currentRole = 'superadmin'; window._isSuperAdmin = () => true;
    window.showToast = function(){};
    window._tbNoVisitCol = false;
    window.ticketDB = []; window._mbRows = []; window._acBans = []; window._acRules = [{restaurant_id:'*'}];
    window._dashExtra = { resvPending:0, deposit:0 };
    window._qmCfg = []; window._qmCfgRole = 'superadmin'; window._qmPulled = true;

    // 지난 예약 7건 (두 날짜) — 하나는 이미 기록됨, 하나는 취소
    const mk = (id, day, name, vs, st) => ({
      id, purchase_id:'V-'+id, user_id:'u'+id, buyer_name:name, party_size:2, price:1,
      status: st || 'active', restaurant_name:'우리매장', reservation_date:'2026.08.'+day,
      visit_time:'19:00', _d:'2026-08-'+day, _m:1140, visit_status: vs || null, extra_data:{}
    });
    window._tbRows = [
      mk('1','10','가나',null), mk('2','10','다라',null), mk('3','10','마바',null),
      mk('4','11','사아',null), mk('5','11','자차',null),
      mk('6','11','이미기록','attended'),
      mk('7','11','취소된건',null,'cancelled')
    ];

    // 서버 흉내 — rpc 만 쓰지만 qaLoad 가 from() 도 부른다
    const noFrom = () => ({ select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({data:null,error:null}) }),
      order: () => ({ limit: () => Promise.resolve({data:[],error:null}) }),
      limit: () => Promise.resolve({data:[],error:null}),
      in: () => Promise.resolve({data:[],error:null}) }),
      upsert: () => Promise.resolve({error:null}) });
    let calls = [];
    window.sb = { from: noFrom, rpc: (fn, args) => { calls.push(args.p_ticket_id + ':' + args.p_status);
      return Promise.resolve({ data:null, error:null }); } };

    // ── 대시보드에서 들어가는 길 ──
    const nu = _dashUnmarked();
    ok('대시보드가 미기록 5건을 센다 (기록·취소 제외)', nu === 5);
    _dashRender();
    const row = [...document.querySelectorAll('#tbBody .todo > button')]
      .find(x => /방문 기록 안 함/.test(x.textContent));
    ok('처리할 일에 줄이 있다', !!row);
    ok('예약 탭이 아니라 전용 화면으로 간다', (row.getAttribute('onclick')||'') === 'visOpen()');

    // ── 화면 ──
    await visOpen();
    ok('방문 기록 화면이 열린다', d('visScreen') !== 'none');
    ok('남은 건수가 뜬다 (' + document.getElementById('visCount').textContent + ')',
       document.getElementById('visCount').textContent === '5건 남음');
    const body = document.getElementById('visBody');
    ok('날짜별로 묶인다', body.querySelectorAll('.vis-day').length === 2);
    ok('줄이 5개', body.querySelectorAll('.vis-row').length === 5);
    ok('이미 기록된 건은 안 나온다', !/이미기록/.test(body.innerText));
    ok('취소된 건도 안 나온다', !/취소된건/.test(body.innerText));
    ok('최근 날짜가 위 (8월 11일 먼저)',
       body.querySelector('.vis-day span').textContent.indexOf('8월 11일') === 0);
    ok('날짜마다 「전부 방문」이 있다',
       [...body.querySelectorAll('.vis-day button')].every(x => /전부 방문/.test(x.textContent)));

    // ── 한 건 ──
    calls = [];
    await visMark('1','attended');
    ok('한 건 기록 → 서버 호출', calls.length === 1 && calls[0] === '1:attended');
    ok('기록한 줄은 목록에서 빠진다', body.querySelectorAll('.vis-row').length === 4);
    ok('남은 건수도 준다', document.getElementById('visCount').textContent === '4건 남음');

    // ── 날짜 전부 ──
    calls = [];
    const day11 = [...body.querySelectorAll('.vis-day')]
      .find(x => /8월 11일/.test(x.textContent)).querySelector('button');
    await visDayAll('2026-08-11');
    ok('그 날 2건만 보낸다 (다른 날은 안 건드린다)',
       calls.length === 2 && calls.every(c => /:attended$/.test(c)));
    ok('그 날이 목록에서 사라진다', !/8월 11일/.test(body.innerText));
    ok('다른 날은 남는다', /8월 10일/.test(body.innerText));
    ok('남은 건수 2건', document.getElementById('visCount').textContent === '2건 남음');

    // ── 전부 끝내면 ──
    await visDayAll('2026-08-10');
    ok('다 하면 안내가 뜬다', /밀린 방문 기록이 없습니다/.test(body.innerText));
    ok('대시보드 처리할 일에서도 사라진다', _dashUnmarked() === 0);

    // ── 실패가 섞이면 ──
    window._tbRows = [mk('8','12','실패건',null)];
    window.sb = { from: noFrom, rpc: () => Promise.resolve({ data:null, error:{ message:'권한 없음' } }) };
    _visRender();
    await visDayAll('2026-08-12');
    ok('실패한 건은 목록에 남는다', body.querySelectorAll('.vis-row').length === 1);

    // ── 컬럼이 없으면 ──
    window._tbNoVisitCol = true;
    _visRender();
    ok('SQL 이 안 돌았으면 그렇게 말한다', /먼저 실행/.test(body.innerText));
    window._tbNoVisitCol = false;

    // ── 탭을 옮기면 같이 닫힌다 (안 닫으면 새 탭을 덮는다) ──
    ok('_acCloseOthers 가 이 화면도 닫는다', AC_EXTRA_SCREENS.indexOf('visScreen') >= 0);
    _acCloseOthers(null);
    ok('탭 이동 시 닫힌다', d('visScreen') === 'none');

    // ── 권한 ──
    window._currentRole = 'user'; window._isSuperAdmin = () => false;
    await visOpen();
    ok('회원은 못 연다', d('visScreen') === 'none');

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.slice(0,2).join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
