const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    window._currentRole = 'superadmin';
    const adm = document.getElementById('adminScreen');
    adm.style.display = 'flex'; adm.classList.remove('ac-lean');

    window._moRows = _moScan();
    window._moState = { q:'' };
    _moRenderBody();
    const el = document.getElementById('moBody');
    const btns = el.querySelectorAll('.mo-item');
    ok('더보기에 항목이 그려진다 (' + btns.length + ')', btns.length > 10);
    ok('훑은 개수와 그린 개수가 같다 (전부 남긴다)', btns.length === _moRows.length);

    // 화면의 i 번째 버튼이 moGo(i) 로 실제 i 번째 항목을 가리키는가
    //   (전에는 안 찾을 때만 목록을 더 걸러서 번호가 어긋났다)
    let mis = 0;
    Array.prototype.forEach.call(btns, (bt, i) => {
      const want = 'moGo(' + i + ')';
      if ((bt.getAttribute('onclick') || '') !== want) mis++;
      const t = bt.querySelector('.mo-t').textContent;
      if (t.indexOf(_moRows[i].title) !== 0) mis++;
    });
    ok('번호와 항목이 어긋나지 않는다', mis === 0);

    // 탭으로 간 항목도 남아 있고, 어디에 있는지 적힌다
    const tabOwned = _moRows.filter(x => _acMenuOf(x.title));
    ok('탭으로 간 항목도 목록에 있다 (' + tabOwned.length + ')', tabOwned.length > 0);
    const wh = el.querySelectorAll('.mo-where');
    ok('「티켓 탭」 같은 표시가 붙는다', wh.length >= tabOwned.length);

    // ── 접었을 때(ac-lean) ──
    adm.classList.add('ac-lean');
    const lbl = Array.prototype.find.call(
      adm.querySelectorAll('.admin-section-label'), e => e.textContent.indexOf('내 계정') >= 0);
    ok('접어도 「내 계정」 라벨은 남는다', lbl && getComputedStyle(lbl).display !== 'none');
    const lo = Array.prototype.find.call(
      adm.querySelectorAll('.admin-menu-item'), e => (e.getAttribute('onclick')||'').indexOf('confirmLogout') >= 0);
    ok('접어도 로그아웃은 남는다', lo && getComputedStyle(lo).display !== 'none');
    const pw = Array.prototype.find.call(
      adm.querySelectorAll('.admin-menu-item'), e => (e.getAttribute('onclick')||'').indexOf('openMemberPwdModal') >= 0);
    ok('접으면 비밀번호 변경은 숨는다', pw && getComputedStyle(pw).display === 'none');
    ok('접어도 훑기는 51개 그대로', _moScan().length === 51);
    adm.classList.remove('ac-lean');

    // 묶음이 아홉이고 이름이 새 것인가
    const grps = [...new Set(_moScan().map(r => r.grp))];
    ok('묶음이 아홉 (' + grps.join(' / ') + ')', grps.length === 9);
    ok('「Test · 실험·도구」가 사라졌다', !grps.some(g => g.indexOf('Test') >= 0));
    ok('「승인 대기0」이 아니라 「승인 대기」',
       _moScan().some(r => r.title === '승인 대기') && !_moScan().some(r => /승인 대기\d/.test(r.title)));

    adm.style.display = 'none';
    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
