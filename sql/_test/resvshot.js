const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    window._currentRole = 'superadmin';
    window._isSuperAdmin = () => false;   // 예치금 조회는 건너뛴다

    const today = _taamTodayKst();
    const y = today.slice(0,4), md = today.slice(4);
    const past   = (parseInt(y,10) - 1) + '-' + md.slice(0,2) + '-' + md.slice(2);
    const future = (parseInt(y,10) + 1) + '-' + md.slice(0,2) + '-' + md.slice(2);
    const todayIso = y + '-' + md.slice(0,2) + '-' + md.slice(2);

    // 가짜 Supabase — 조회 결과만 흉내 낸다
    const mk = (rows, err) => ({
      from: () => ({
        select: () => ({
          eq: () => ({ limit: async () => ({ data: rows, error: err || null }) }),
          limit: async () => ({ data: rows, error: err || null })
        })
      })
    });

    window.sb = mk([
      { id:'a', reserve_date: past },      // 지난 요청 — 세지 않는다
      { id:'b', reserve_date: future },    // 앞으로의 요청
      { id:'c', reserve_date: todayIso },  // 오늘 — 아직 유효
      { id:'d', reserve_date: null }       // 날짜 없음 — 모르는 건 센다
    ]);
    window._dashExtra = { resvPending:null, deposit:null };
    await _dashLoad();
    ok('지난 요청은 안 센다 (4건 중 3건)', _dashExtra.resvPending === 3);

    window.sb = mk([{ id:'a', reserve_date: past }]);
    window._dashExtra = { resvPending:null, deposit:null };
    await _dashLoad();
    ok('지난 것만 있으면 0 (붉은 1이 사라진다)', _dashExtra.resvPending === 0);

    window.sb = mk([{ id:'b', reserve_date: future }]);
    window._dashExtra = { resvPending:null, deposit:null };
    await _dashLoad();
    ok('앞으로의 요청은 그대로 센다', _dashExtra.resvPending === 1);

    // 점(.) 형식도 같이 읽는다
    window.sb = mk([{ id:'e', reserve_date: future.replace(/-/g, '.') }]);
    window._dashExtra = { resvPending:null, deposit:null };
    await _dashLoad();
    ok('점 형식 날짜도 읽는다', _dashExtra.resvPending === 1);

    // 컬럼이 없으면 예전처럼 전부 센다
    let phase = 0;
    window.sb = { from: () => ({ select: (...a) => {
      phase++;
      const head = a.length > 1;
      return head
        ? { eq: () => ({ count: 7, error: null, then: undefined }) }
        : { eq: () => ({ limit: async () => ({ data:null, error:{ message:'column does not exist' } }) }) };
    } }) };
    // head:true 경로는 await 되는 thenable 이어야 한다 — 간단히 다시 만든다
    window.sb = { from: () => ({ select: (cols, opt) => (opt && opt.head)
      ? { eq: async () => ({ count: 7, error: null }) }
      : { eq: () => ({ limit: async () => ({ data:null, error:{ message:'column does not exist' } }) }) } }) };
    window._dashExtra = { resvPending:null, deposit:null };
    await _dashLoad();
    ok('컬럼이 없으면 예전처럼 전부 센다 (7)', _dashExtra.resvPending === 7);

    // 완전 실패해도 대시보드는 뜬다
    window.sb = { from: () => { throw new Error('boom'); } };
    window._dashExtra = { resvPending:0, deposit:0 };
    await _dashLoad();
    ok('완전 실패는 null (— 로 표시)', _dashExtra.resvPending === null);

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
