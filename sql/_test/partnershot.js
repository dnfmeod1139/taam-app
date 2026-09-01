const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const d = id => p.evaluate(i => { const e = document.getElementById(i); return e ? getComputedStyle(e).display : '(없음)'; }, id);

  const setup = () => p.evaluate(() => {
    document.getElementById('appWrapper').classList.add('ready');
    document.getElementById('mainScreen').style.display = 'flex';
    var sp = document.getElementById('splash-ov'); if(sp) sp.remove();
    [...document.body.children].forEach(n => { try{ if(getComputedStyle(n).zIndex==='99999') n.remove(); }catch(e){} });
    // ── 파트너 계정 ──
    window._currentRole = 'admin';
    window._isSuperAdmin = () => false;
    window._currentAdminRestId = 'REST_MINE';
    window._currentAdminRestName = '우리매장';
    const iso = '2026.12.20';
    window.ticketDB = [
      { id:'tp1', rest:'우리매장', restId:'REST_MINE', time:'19:00', date:iso, totalPax:8, status:'active' },
      { id:'tp2', rest:'우리매장', restId:'REST_MINE', time:'12:00', date:iso, totalPax:6, status:'pending' }
    ];
    window._tbRows = [
      { id:'t1', purchase_id:'P-1', user_id:'u1', buyer_name:'홍길동', party_size:2, price:100000,
        status:'active', restaurant_id:'REST_MINE', restaurant_name:'우리매장', ticket_product_id:'tp1',
        reservation_date:iso, visit_time:'19:00', _d:'2026-12-20', _m:1140, extra_data:{} }
    ];
    window._mbRows = []; window._acBans = []; window._acRules = [{restaurant_id:'*'}];
    window._dashExtra = { resvPending:0, deposit:null };
    window._qmCfg = null; window._qmCfgRole = null; window._qmPulled = true;
    window.showToast = function(){};
    openAdminConsole(false);
  });

  await setup();
  await p.waitForTimeout(250);
  // ⚠ openAdminConsole → tbOpen → _tbLoad() 가 _tbRows 를 서버값(헤드리스에선 빈 값)
  //   으로 덮는다. 데이터는 **그 뒤에** 넣어야 한다 — 처음엔 이걸 몰라서
  //   「다음 영업이 안 뜬다」로 잘못 읽었다.
  await p.evaluate(() => {
    const iso = '2026.12.20';
    window.ticketDB = [
      { id:'tp1', rest:'우리매장', restId:'REST_MINE', time:'19:00', date:iso, totalPax:8, status:'active' },
      { id:'tp2', rest:'우리매장', restId:'REST_MINE', time:'12:00', date:iso, totalPax:6, status:'pending' }
    ];
    window._tbRows = [
      { id:'t1', purchase_id:'P-1', user_id:'u1', buyer_name:'홍길동', party_size:2, price:100000,
        status:'active', restaurant_id:'REST_MINE', restaurant_name:'우리매장', ticket_product_id:'tp1',
        reservation_date:iso, visit_time:'19:00', _d:'2026-12-20', _m:1140, extra_data:{} }
    ];
  });

  // ── 진입 ──
  ok('파트너도 앱을 켜면 대시보드', (await d('todayBoardScreen')) !== 'none');
  ok('파트너 어드민 화면이 바탕에 있다', (await d('partnerAdminScreen')) !== 'none');
  ok('슈퍼어드민 화면은 안 열린다', (await d('adminScreen')) === 'none');

  const tabs = await p.evaluate(() =>
    [...document.querySelectorAll('#tbTabs .ac-tab, #todayBoardScreen .ac-tabs > *')]
      .map(e => e.textContent.replace(/\d+$/,'').trim()).filter(Boolean));
  ok('탭이 넷 (' + tabs.join('·') + ')', tabs.length === 4);
  ok('회원·더보기 탭은 없다', !tabs.some(t => t === '회원' || t === '더보기'));
  ok('내 매장 탭이 있다', tabs.includes('내 매장'));

  // ── 대시보드 내용 ──
  const dash = await p.evaluate(() => {
    _dashRender();
    const body = document.getElementById('tbBody');
    return {
      text: body.innerText.replace(/\s+/g,' '),
      todo: [...body.querySelectorAll('.todo > button')].map(x => ({
        t: x.querySelector('.t').textContent, n: x.querySelector('.n').textContent,
        on: x.getAttribute('onclick') })),
      qm: [...body.querySelectorAll('.qm-b .t')].map(x => x.textContent),
      hasDeposit: /예치금/.test(body.innerText)
    };
  });
  ok('파트너에게 「다음 영업」이 뜬다', /다음 영업/.test(dash.text));
  ok('예치금 총 잔액은 파트너에게 안 보인다', !dash.hasDeposit);
  ok('자주 쓰는 메뉴가 파트너 메뉴로 채워진다 (' + dash.qm.join('·') + ')', dash.qm.length > 0);
  ok('파트너 메뉴에 슈퍼어드민 것이 안 섞인다',
     !dash.qm.some(t => /예치금|환율|회원 목록|계보|마켓/.test(t)));

  // 처리할 일 — 파트너가 자기 업로드를 스스로 승인하면 안 된다
  const approve = dash.todo.find(x => /승인/.test(x.t));
  ok('처리할 일에 「티켓 업로드 승인」이 파트너에게는 없다 (' +
     (dash.todo.map(x=>x.t).join(', ') || '없음') + ')', !approve);
  const badge = await p.evaluate(() => _acTodoCount());
  const sum = dash.todo.reduce((a,x) => a + parseInt(x.n||'0',10), 0);
  ok('탭 배지도 같은 값 (배지 ' + badge + ')', badge === 0);

  // ── 탭 이동 · ← · ✕ ──
  for (const [fn, id, name] of [['rv','rvScreen','예약'], ['tkb','tkbScreen','티켓'], ['shop','pshScreen','내 매장']]) {
    await p.evaluate(k => acGo(k), fn);
    await p.waitForTimeout(160);
    if ((await d(id)) === 'none') { ok(name + ' 탭이 열린다', false); continue; }
    ok(name + ' 탭이 열린다', true);
    await p.evaluate(() => acBack());
    await p.waitForTimeout(160);
    ok(name + ' 에서 ← → 대시보드',
       (await d('todayBoardScreen')) !== 'none' && (await d('partnerAdminScreen')) !== 'none');
  }

  // ── 범위: 남의 매장 것이 안 섞이나 ──
  const scope = await p.evaluate(() => {
    window._tbRows.push({ id:'t2', purchase_id:'P-2', user_id:'u2', buyer_name:'남의손님', party_size:2,
      price:1, status:'active', restaurant_id:'REST_OTHER', restaurant_name:'남의매장',
      reservation_date:'2026.12.20', visit_time:'18:00', _d:'2026-12-20', _m:1080, extra_data:{} });
    window.ticketDB.push({ id:'tp9', rest:'남의매장', restId:'REST_OTHER', date:'2026.12.20', status:'active' });
    const rv = (typeof _rvBase === 'function') ? _rvBase() : [];
    const tk = (typeof _tkbBase === 'function') ? _tkbBase() : [];
    return { rv: rv.map(r => r.restaurant_name), tk: tk.map(t => t.rest || t.restId) };
  });
  ok('예약에 남의 매장이 안 섞인다 (' + (scope.rv.join(',') || '없음') + ')',
     !scope.rv.includes('남의매장'));
  ok('티켓에 남의 매장이 안 섞인다 (' + (scope.tk.join(',') || '없음') + ')',
     !scope.tk.includes('남의매장'));

  // ── 메뉴 원본 ──
  const menu = await p.evaluate(() => _moScan().map(r => r.title));
  ok('파트너 메뉴는 자기 것만 (' + menu.length + '개)', menu.length >= 4 && menu.length <= 10);
  ok('예치금·환율·회원 목록이 없다', !menu.some(t => /예치금|환율|회원 목록|계보도 관리|마켓/.test(t)));
  ok('로그아웃은 있다', menu.some(t => /로그아웃/.test(t)));

  // ── ✕ 로 앱으로 ──
  let outMain = 0;
  await p.evaluate(() => { window.__om = 0; const r = window.openMain; window.openMain = function(){ window.__om++; }; });
  await p.evaluate(() => acExit());
  await p.waitForTimeout(200);
  outMain = await p.evaluate(() => window.__om);
  ok('✕ → 콘솔이 닫히고 앱으로',
     (await d('todayBoardScreen')) === 'none' && (await d('partnerAdminScreen')) === 'none' && outMain === 1);

  out.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.slice(0,2).join(' | ') : '없음');
  console.log(out.some(l => l.startsWith('FAIL')) ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
