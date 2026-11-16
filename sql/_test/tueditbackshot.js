// ═══════════════════════════════════════════════════════════════
// 티켓 「수정」 — 저장·← 뒤 「수정」을 누른 화면이 **맨 위**로 돌아온다 (2026-11-16)
// ═══════════════════════════════════════════════════════════════
//   「티켓 리스트에서 수정을 끝내면 전 단계가 아니라 슈퍼어드민 화면으로 간다」.
//   closeTU 가 언제나 openAdmin()/openPartnerAdmin() 으로 끝났고, 그 뒤
//   _acEnsureConsole 이 마지막 콘솔 탭(대시보드 · 「티켓」 탭)을 열었다.
//   고친 판(a9c8c3f · b319354): tuEditTicket 이 돌아갈 화면을 적고 closeTU 가 그리로.
//
//   ⚠ 이 검사를 처음 만든 두 하네스(스크래치 editret/er.js · tuback/edge.js)는
//     #appWrapper.ready 를 안 세워서, CSS 가 adminScreen 을 !important 로 숨기고
//     _acEnsureConsole 이 언제나 「콘솔 밖」으로 끝났다 — **사고를 낸 그 코드가 한 번도
//     안 돌았다**(콘솔 탭이 리스트를 덮는 모양을 못 본다 · 그 가드를 끈 변이도 9/9 통과).
//     그래서 여기서는 ① .ready 를 세우고 ② 사람이 가는 길(콘솔 → 「티켓」 탭 메뉴 →
//     「티켓 리스트」 · acMenuGo)로 들어가고 ③ display 가 아니라 **화면 가운데 점의 주인**
//     (elementFromPoint)으로 맨 위 화면을 본다 — 파트너 리스트는 DOM 에서 「티켓」 탭보다
//     앞이라 둘 다 보이면 탭이 리스트를 덮는다.
//
//   슈퍼어드민  A① 리스트 → 수정 → ← : 리스트가 맨 위 · 스크롤 그대로 ⭐
//              A② 수정하기 저장 : 리스트가 맨 위 · 스크롤 그대로 ⭐
//              A③ 매진 회차 정원 늘림(확인 시트) 저장 : 리스트 ⭐
//              A④ 날짜를 바꾼 수정(예약 옮기기 확인) 저장 : 리스트(+ 결과 창)
//              A⑤ 리스트 ← : 「티켓」 탭
//              B①② 「더보기」 길로 들어간 리스트 → 수정 저장 → 리스트 · ← → 더보기
//              C① 「티켓」 탭 필터·펼친 줄·스크롤 → 수정 저장 → 같은 상태로 탭이 맨 위 ⭐
//              C② 「티켓」 탭 → 판매 오픈 관리 → 수정 → ← → 그 창 · × → 「티켓」 탭
//              C③ 열리지 않은 수정(회차가 사라짐)의 표시가 다음 리스트 수정에 안 남는다
//              C④ 신규 업로드 ← 는 리스트로 안 간다(종전대로 콘솔)
//   파트너      D① 「티켓」 탭 메뉴 → 승인된 티켓 리스트 → 수정 저장 → 리스트 맨 위 · 스크롤 ⭐
//              D② 수정 신청 대기 회차(서버에서 다시 읽고 엶) → ← → 리스트
//              D③ 리스트 ← : 「티켓」 탭
//              E① 열리지 않은 수정(신청 값 못 읽음) 뒤 리스트 수정 → ← → 리스트
//              E② 앞 수정을 closeTU 없이 벗어난 뒤 새 업로드 ← 는 리스트로 안 감
//   각 페이지 오류 없음
//
// 실행: node sql/_test/tueditbackshot.js [index.html 경로]   (기본: 이 저장소의 index.html)
//   165dc7d(고치기 전) ❌ 12 — A①~④ · B① · C①②③ · D①② · E① (사용자가 본 그 증상).
//   a9c8c3f ❌ 3 — C③ · E① · E② (열리지 않은 수정의 표시 · 파트너 새 업로드).
//   _acEnsureConsole 의 「위에 화면이 있으면 그대로」 가드를 끈 변이 ❌ 12 · 복귀를 30ms 미룬 변이 ❌ 3.
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const path = require('path');
const ROOT = path.resolve(__dirname, '..', '..');
const HTML = path.resolve(process.argv[2] || (ROOT + '/index.html'));

(async () => {
  const out = [];
  let bad = 0;
  const ok = (n, c, info) => { out.push((c ? 'OK   ' : 'FAIL ') + n + (!c && info !== undefined ? '  ' + JSON.stringify(info).slice(0, 600) : '')); if (!c) bad++; };
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });

  async function fresh(role, n) {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, locale: 'ko-KR', timezoneId: 'Asia/Seoul' });
    const p = await ctx.newPage();
    await p.route(u => !u.href.startsWith('file://'), r => r.abort());
    p._errs = [];
    p.on('pageerror', e => p._errs.push(String(e.message).slice(0, 200)));
    p.on('dialog', d => d.accept().catch(() => {}));
    await p.goto('file://' + HTML, { waitUntil: 'domcontentloaded' });
    await p.waitForTimeout(1500);
    await p.evaluate(({ role, n }) => {
      // 네트워크를 막아 뜨는 「연결 실패」 전체 화면(z 99999)과 스플래시를 걷는다
      Array.prototype.slice.call(document.body.children).forEach(function (d) {
        if ((d.style && d.style.zIndex === '99999') || (d.classList && d.classList.contains('splash'))) d.remove();
      });
      var aw = document.getElementById('appWrapper');
      aw.style.display = 'block';
      aw.classList.add('ready');   // ⭐ 없으면 콘솔이 CSS 로 숨어 _acEnsureConsole 이 안 돈다
      var ms = document.getElementById('mainScreen'); if (ms) ms.style.display = 'block';
      window._isSuperAdmin = function () { return role === 'superadmin'; };
      _currentRole = role;
      window._currentAdminRestId = 'r1'; try { _currentAdminRestId = 'r1'; } catch (e) {}
      restaurantDB.length = 0; restaurantDB.push({ id: 'r1', name: '스시 테스트', zoneEn: 'Ginza' });
      ticketDB.length = 0;
      for (var i = 0; i < n; i++) {
        var d = ('0' + (1 + (i % 28))).slice(-2);
        ticketDB.push({ id: 'T' + i, restId: 'r1', rest: '스시 테스트', date: '2027.03.' + d, dateYear: '2027', time: (i % 2 ? '19:00' : '12:00'),
          status: (role === 'superadmin' && i % 3 === 0 ? 'soldout' : 'active'), totalPax: '8', saleState: (i === 7 ? 'draft' : 'open'),
          mealFee: 400000, agencyFee: 100000, typeClass: 'std', ticketGenre: '스시', slots: { mode: 'flex', allowed: [2, 3, 4], solo: 0, strict: false } });
      }
      var res = function () { return Promise.resolve({ data: [], error: null }); };
      var chain = function () {
        var q = {};
        ['select', 'in', 'eq', 'neq', 'gte', 'lte', 'lt', 'gt', 'order', 'limit', 'range', 'not', 'is', 'or', 'match', 'filter', 'single', 'maybeSingle', 'upsert', 'insert', 'update', 'delete', 'contains'].forEach(function (k) { q[k] = function () { return q; }; });
        q.then = function (f, g) { return res().then(f, g); };
        return q;
      };
      window.sb = {
        from: chain,
        rpc: function (name) {
          if (name === 'taam_round_move_preview') return Promise.resolve({ data: { ok: true, cur: { date: '2027-03-04', time: '19:00' }, rows: [{ action: 'move', kind: 'ticket', pid: 'PAYH-x', pax: 2 }] }, error: null });
          if (name === 'taam_round_reschedule') return Promise.resolve({ data: { ok: true, move: { moved: [{ kind: 'ticket' }], errors: [], conflicts: [], rest_name: '스시', old_date: '2027-03-04', new_date: '2027-03-27' } }, error: null });
          return Promise.resolve({ data: null, error: null });
        },
        channel: function () { return { on: function () { return this; }, subscribe: function () { return this; } }; },
        removeChannel: function () {},
        auth: { getUser: function () { return Promise.resolve({ data: { user: { id: 'u-admin' } } }); }, getSession: function () { return Promise.resolve({ data: { session: null } }); } },
        storage: { from: function () { return { upload: res, getPublicUrl: function () { return { data: { publicUrl: '' } }; } }; } },
      };
      // ── 도우미 ──
      window.__w = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
      // 맨 위 화면 = 화면 가운데 점이 속한 화면
      window.__top = function () {
        var el = document.elementFromPoint(195, 420);
        while (el && !(el.id && (/Screen$/.test(el.id) || el.id === 'tkSaleMgr'))) el = el.parentElement;
        return el ? el.id : null;
      };
      window.__vis = function (id) { var el = document.getElementById(id); return !!el && getComputedStyle(el).display !== 'none'; };
      window.__btn = function (sel, txt, i) {
        return Array.prototype.slice.call(document.querySelectorAll(sel + ' button')).filter(function (x) { return x.textContent.trim() === txt; })[i || 0];
      };
      // 사람이 가는 길: 콘솔 → 「티켓」 탭 → 메뉴 「…티켓 리스트」(acMenuGo)
      window.__openListViaTab = async function () {
        openAdminConsole(); await __w(300);
        acGo('tkb'); await __w(400);
        var mi = Array.prototype.slice.call(document.querySelectorAll('#tkbBody .mo-item')).filter(function (x) { return /티켓 리스트/.test(x.textContent); })[0];
        if (!mi) return false;
        mi.click(); await __w(900);
        return true;
      };
      window.__submit = async function () {
        try { _tuPolicy = Object.assign({}, _tuPolicy || {}, { p1: true, p2: true, p3: true }); } catch (e) {}
        document.getElementById('tuSubmitBtn').click(); await __w(400);
        var cp = document.getElementById('ticketConfirmPopup');
        if (cp && getComputedStyle(cp).display !== 'none') { document.getElementById('tcpSubmitBtn').click(); return 'final'; }
        return 'noconfirm';
      };
    }, { role, n });
    return p;
  }

  // ═══ A 슈퍼어드민 — 「티켓」 탭 메뉴로 들어간 티켓 리스트 ═══
  let p = await fresh('superadmin', 30);
  const a1 = await p.evaluate(async () => {
    if (!(await __openListViaTab())) return { err: 'no menu item' };
    var pre = __top();
    var sc = document.querySelector('#ticketListScreen .sub-content'); sc.scrollTop = 500; var y0 = sc.scrollTop;
    __btn('#ticketListContent', '수정', 5).click(); await __w(300);
    var inEdit = __top();
    document.querySelector('#tuScreen .page-back').click(); await __w(900);
    return { pre: pre, inEdit: inEdit, top: __top(), tu: __vis('tuScreen'), y0: y0, y1: sc.scrollTop };
  });
  ok('A① 리스트 → 수정 → ← : 티켓 리스트가 맨 위 · 스크롤 그대로 ⭐', a1.pre === 'ticketListScreen' && a1.inEdit === 'tuScreen' && a1.top === 'ticketListScreen' && !a1.tu && a1.y0 > 0 && Math.abs(a1.y1 - a1.y0) <= 2, a1);

  const a2 = await p.evaluate(async () => {
    var sc = document.querySelector('#ticketListScreen .sub-content'); sc.scrollTop = 500; var y0 = sc.scrollTop;
    __btn('#ticketListContent', '수정', 4).click(); await __w(300);
    var st = await __submit(); await __w(1200);
    return { st: st, top: __top(), tu: __vis('tuScreen'), y0: y0, y1: sc.scrollTop };
  });
  ok('A② 「수정하기」 저장 : 티켓 리스트가 맨 위 · 스크롤 그대로 ⭐', a2.st === 'final' && a2.top === 'ticketListScreen' && !a2.tu && Math.abs(a2.y1 - a2.y0) <= 2, a2);

  const a3 = await p.evaluate(async () => {
    tuListSetSub('sold'); await __w(200);   // 리스트 안의 「매진」 하위 탭
    var btn = __btn('#ticketListContent', '수정', 0);
    if (!btn) return { err: 'no soldout edit' };
    var id = (btn.getAttribute('onclick') || '').match(/'([^']+)'/)[1];
    btn.click(); await __w(300);
    document.getElementById('tuTotalPax').value = '10';
    var st = await __submit(); await __w(500);
    var sh = document.getElementById('tkAskWrap'); var sheet = !!sh && sh.classList.contains('on');
    if (sheet) document.getElementById('tkAskYes').click();
    await __w(1200);
    return { st: st, sheet: sheet, top: __top(), tu: __vis('tuScreen'), cap: String((ticketDB.find(function (t) { return t.id === id; }) || {}).totalPax) };
  });
  ok('A③ 매진 회차 정원 늘림(확인 시트) 저장 : 티켓 리스트 ⭐', a3.sheet && a3.top === 'ticketListScreen' && !a3.tu && a3.cap === '10', a3);

  const a4 = await p.evaluate(async () => {
    tuListSetSub('onsale'); await __w(200);
    __btn('#ticketListContent', '수정', 2).click(); await __w(300);
    _tuSelectedDate = '03.27'; _tuSelectedDateYear = '2027';
    var st = await __submit(); await __w(700);
    var ask = Array.prototype.slice.call(document.querySelectorAll('body > div')).filter(function (d) { return /옮기/.test(d.innerText || '') && getComputedStyle(d).position === 'fixed'; }).pop();
    var okb = ask ? Array.prototype.slice.call(ask.querySelectorAll('button')).filter(function (x) { return /옮기고 저장|저장|확인/.test(x.textContent); }).pop() : null;
    if (okb) okb.click();
    await __w(1500);
    var res = !!document.getElementById('rmResPopup');
    var rp = document.getElementById('rmResPopup'); if (rp) rp.remove();   // 결과 창을 걷고 그 밑을 본다
    await __w(100);
    return { st: st, ask: !!ask, okb: !!okb, res: res, top: __top(), tu: __vis('tuScreen') };
  });
  ok('A④ 날짜 바꾼 수정(예약 옮기기 확인) 저장 : 티켓 리스트(+ 결과 창)', a4.ask && a4.okb && a4.res && a4.top === 'ticketListScreen' && !a4.tu, a4);

  const a5 = await p.evaluate(async () => {
    document.querySelector('#ticketListScreen .sub-back').click(); await __w(800);
    return { top: __top(), list: __vis('ticketListScreen'), last: _acLastTab };
  });
  ok('A⑤ 리스트 ← : 「티켓」 탭', a5.top === 'tkbScreen' && !a5.list, a5);
  ok('A 페이지 오류 없음', p._errs.length === 0, p._errs);

  // ═══ B 슈퍼어드민 — 「더보기」 길 ═══
  p = await fresh('superadmin', 30);
  const b1 = await p.evaluate(async () => {
    openAdminConsole(); await __w(300);
    acGo('mo'); await __w(600);
    var mi = Array.prototype.slice.call(document.querySelectorAll('#moScreen .mo-item')).filter(function (x) { return /티켓 리스트/.test(x.textContent); })[0];
    if (!mi) return { err: 'no more item' };
    mi.click(); await __w(900);
    var pre = __top();
    __btn('#ticketListContent', '수정', 1).click(); await __w(300);
    var st = await __submit(); await __w(1200);
    var saved = __top();
    document.querySelector('#ticketListScreen .sub-back').click(); await __w(800);
    return { pre: pre, st: st, saved: saved, back: __top() };
  });
  ok('B① 더보기 → 티켓 리스트 → 수정 저장 : 티켓 리스트 ⭐', b1.pre === 'ticketListScreen' && b1.st === 'final' && b1.saved === 'ticketListScreen', b1);
  ok('B② 그 리스트 ← : 더보기', b1.back === 'moScreen', b1);
  ok('B 페이지 오류 없음', p._errs.length === 0, p._errs);

  // ═══ C 슈퍼어드민 — 「티켓」 탭에서 바로 수정 · 판매 오픈 관리 · 가장자리 ═══
  p = await fresh('superadmin', 30);
  const c1 = await p.evaluate(async () => {
    openAdminConsole(); await __w(300);
    acGo('tkb'); await __w(500);
    tkbSetFilter('sold'); await __w(50);
    var rows = _tkbSort(_tkbBase().filter(function (t) { return _tkbPass(t, 'sold'); }));
    var want = rows[3].id;
    tkbToggleRow(want); await __w(50);
    var body = document.getElementById('tkbBody'); body.scrollTop = 400; var y0 = body.scrollTop;
    var eb = Array.prototype.slice.call(document.querySelectorAll('#tkbBody button')).filter(function (x) { return (x.getAttribute('onclick') || '') === "tkbEdit('" + want + "')"; })[0];
    if (!eb) return { err: 'no row edit' };
    eb.click(); await __w(300);
    var inEdit = __top();
    var st = await __submit(); await __w(600);
    var sh = document.getElementById('tkAskWrap'); if (sh && sh.classList.contains('on')) document.getElementById('tkAskYes').click();
    await __w(1200);
    return { inEdit: inEdit, st: st, top: __top(), filter: _tkbState.filter, open: _tkbState.open, want: want, y0: y0, y1: document.getElementById('tkbBody').scrollTop };
  });
  ok('C① 「티켓」 탭 필터·펼친 줄·스크롤 → 수정 저장 : 같은 상태로 탭 ⭐', c1.inEdit === 'tuScreen' && c1.st === 'final' && c1.top === 'tkbScreen' && c1.filter === 'sold' && c1.open === c1.want && c1.y0 > 0 && Math.abs(c1.y1 - c1.y0) <= 2, c1);

  const c2 = await p.evaluate(async () => {
    tkbSetFilter('all'); await __w(50);
    tkbToggleRow('T1'); await __w(50);
    var sm = Array.prototype.slice.call(document.querySelectorAll('#tkbBody button')).filter(function (x) { return (x.getAttribute('onclick') || '') === 'tkbSaleMgr()'; })[0];
    if (!sm) return { err: 'no sale mgr button' };
    sm.click(); await __w(400);
    var mgr0 = __top();
    var eb = __btn('#tkSaleMgr', '수정', 0);
    if (!eb) return { err: 'no edit in sale mgr' };
    eb.click(); await __w(300);
    var inEdit = __top();
    document.querySelector('#tuScreen .page-back').click(); await __w(800);
    var back = __top();
    var x = __btn('#tkSaleMgr', '×', 0);
    if (x) { x.click(); await __w(700); }
    return { mgr0: mgr0, inEdit: inEdit, back: back, x: !!x, after: __top(), mgrGone: !document.getElementById('tkSaleMgr') };
  });
  ok('C② 판매 오픈 관리 → 수정 → ← : 그 창이 다시 맨 위', c2.mgr0 === 'tkSaleMgr' && c2.inEdit === 'tuScreen' && c2.back === 'tkSaleMgr', c2);
  ok('C② 그 창 × : 「티켓」 탭', c2.x && c2.mgrGone && c2.after === 'tkbScreen', c2);

  const c3 = await p.evaluate(async () => {
    tkbEdit('GONE'); await __w(500);   // 회차가 그 사이 지워졌다 — 수정이 안 열린다
    var opened = __vis('tuScreen');
    if (!(await __openListViaTab())) return { err: 'no menu item' };
    __btn('#ticketListContent', '수정', 2).click(); await __w(300);
    document.querySelector('#tuScreen .page-back').click(); await __w(900);
    return { opened: opened, top: __top() };
  });
  ok('C③ 열리지 않은 「티켓」 탭 수정의 표시가 다음 리스트 수정에 안 남는다', !c3.opened && c3.top === 'ticketListScreen', c3);

  const c4 = await p.evaluate(async () => {
    openAdminConsole(); await __w(300);
    acGo('tkb'); await __w(400);
    var mi = Array.prototype.slice.call(document.querySelectorAll('#tkbBody .mo-item')).filter(function (x) { return /티켓 업로드/.test(x.textContent); })[0];
    if (mi) mi.click(); else openTU();
    await __w(800);
    var inUp = __top();
    document.querySelector('#tuScreen .page-back').click(); await __w(900);
    return { viaMenu: !!mi, inUp: inUp, top: __top(), list: __vis('ticketListScreen'), tu: __vis('tuScreen') };
  });
  ok('C④ 신규 업로드 ← 는 티켓 리스트로 안 감(종전대로 콘솔)', c4.inUp === 'tuScreen' && !c4.list && !c4.tu && c4.top && c4.top !== 'ticketListScreen', c4);
  ok('C 페이지 오류 없음', p._errs.length === 0, p._errs);

  // ═══ D 파트너 — 「티켓」 탭 메뉴 → 승인된 티켓 리스트 ═══
  p = await fresh('admin', 20);
  const d1 = await p.evaluate(async () => {
    ticketDB[3].pendingEdit = { ticket_desc: 'q' };
    window._tkRefreshFromServer = function () { return new Promise(function (r) { setTimeout(function () { ticketDB[3]._pendingView = JSON.parse(JSON.stringify(ticketDB[3])); r(); }, 200); }); };
    if (!(await __openListViaTab())) return { err: 'no partner list menu' };
    var pre = __top();
    var sc = document.querySelector('#partnerTicketListScreen .sub-content'); sc.scrollTop = 300; var y0 = sc.scrollTop;
    __btn('#partnerTicketListContent', '수정', 5).click(); await __w(300);
    var st = await __submit(); await __w(1200);
    return { pre: pre, st: st, top: __top(), tu: __vis('tuScreen'), y0: y0, y1: sc.scrollTop };
  });
  ok('D① 승인된 티켓 리스트 → 수정 저장 : 그 리스트가 맨 위 · 스크롤 그대로 ⭐', d1.pre === 'partnerTicketListScreen' && d1.st === 'final' && d1.top === 'partnerTicketListScreen' && !d1.tu && d1.y0 > 0 && Math.abs(d1.y1 - d1.y0) <= 2, d1);

  const d2 = await p.evaluate(async () => {
    if (__top() !== 'partnerTicketListScreen' && !(await __openListViaTab())) return { err: 'no partner list menu' };
    var b3 =Array.prototype.slice.call(document.querySelectorAll('#partnerTicketListContent button')).filter(function (x) { return /tuEditTicket\('T3'\)/.test(x.getAttribute('onclick') || ''); })[0];
    if (!b3) return { err: 'no T3 edit' };
    b3.click(); await __w(700);   // 신청 값을 다시 읽고 연다(재시도 길)
    var inEdit = __top();
    document.querySelector('#tuScreen .page-back').click(); await __w(900);
    var top = __top();
    document.querySelector('#partnerTicketListScreen .sub-back').click(); await __w(900);
    return { inEdit: inEdit, top: top, back: __top() };
  });
  ok('D② 수정 신청 대기 회차(다시 읽고 엶) → ← : 승인된 티켓 리스트', d2.inEdit === 'tuScreen' && d2.top === 'partnerTicketListScreen', d2);
  ok('D③ 리스트 ← : 「티켓」 탭', d2.back === 'tkbScreen', d2);
  ok('D 페이지 오류 없음', p._errs.length === 0, p._errs);

  // ═══ E 파트너 — 가장자리 ═══
  p = await fresh('admin', 20);
  const e1 = await p.evaluate(async () => {
    ticketDB[1].pendingEdit = { ticket_desc: 'x' };      // 큐 표시만 있고 신청 값(_pendingView)을 못 읽는다
    window._tkRefreshFromServer = function () { return Promise.resolve(); };
    openAdminConsole(); await __w(300);
    acGo('tkb'); await __w(500);
    tkbEdit('T1'); await __w(600);
    var opened = __vis('tuScreen');
    if (!(await __openListViaTab())) return { err: 'no partner list menu' };
    __btn('#partnerTicketListContent', '수정', 3).click(); await __w(300);
    var inEdit = __top();
    document.querySelector('#tuScreen .page-back').click(); await __w(900);
    return { opened: opened, inEdit: inEdit, top: __top() };
  });
  ok('E① 열리지 않은 수정(신청 값 못 읽음) 뒤 리스트 수정 → ← : 승인된 티켓 리스트', !e1.opened && e1.inEdit === 'tuScreen' && e1.top === 'partnerTicketListScreen', e1);

  const e2 = await p.evaluate(async () => {
    // 앞 칸 결과에 기대지 않게 리스트를 새로 연다(E① 이 틀리면 리스트가 닫힌 채 와서 이 칸이 거저 통과한다)
    if (!(await __openListViaTab())) return { err: 'no partner list menu' };
    var pre = __top();
    __btn('#partnerTicketListContent', '수정', 4).click(); await __w(300);
    var inEdit = __top();
    // 알림 이동 같은 다른 길 — 수정 화면을 closeTU 없이 덮고 콘솔이 다시 열린다
    document.getElementById('tuScreen').style.display = 'none'; _tuEditId = null;
    openAdminConsole(); await __w(300);
    openPartnerTU(); await __w(300);
    var inUp = __top();
    document.querySelector('#tuScreen .page-back').click(); await __w(900);
    return { pre: pre, inEdit: inEdit, inUp: inUp, top: __top(), list: __vis('partnerTicketListScreen'), tu: __vis('tuScreen') };
  });
  ok('E② 새 업로드(openPartnerTU) ← 는 앞 수정의 리스트로 안 감', e2.pre === 'partnerTicketListScreen' && e2.inEdit === 'tuScreen' && e2.inUp === 'tuScreen' && !e2.tu && !e2.list && e2.top && e2.top !== 'partnerTicketListScreen', e2);
  ok('E 페이지 오류 없음', p._errs.length === 0, p._errs);

  out.forEach(l => console.log(l));
  console.log('\n' + (bad ? '=== 실패 ' + bad + '건 ===' : '=== 전부 통과 (' + out.length + '건) ==='));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
