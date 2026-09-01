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

    // ── 매거진(표지)이 기본 ──
    window.newHomeEnabled = () => true;
    try { localStorage.removeItem('taamMagazine'); } catch(e){}
    ok('사진 캘린더가 켜져 있으면 표지가 기본', magEnabled() === true);
    try { localStorage.setItem('taamMagazine','0'); } catch(e){}
    ok("'0' 이면 꺼진다 (이 기기 토글)", magEnabled() === false);
    try { localStorage.setItem('taamMagazine','1'); } catch(e){}
    ok("옛 값 '1' 도 켜짐으로 읽힌다", magEnabled() === true);
    ok('MAGAZINE_LIVE 가 켜져 있어도 「이 기기」 끄기가 이긴다',
       (function(){ try{ localStorage.setItem('taamMagazine','0'); }catch(e){}
                    var v = magEnabled();
                    try{ localStorage.setItem('taamMagazine','1'); }catch(e){}
                    return v === false; })());
    try { localStorage.removeItem('taamMagazine'); } catch(e){}
    window.newHomeEnabled = () => false;
    ok('사진 캘린더가 꺼져 있으면 표지도 없다', magEnabled() === false);
    window.newHomeEnabled = () => true;

    // 토글이 끄는 스위치로 돈다
    window.showView = function(){}; window.magSync = magSync;
    toggleMagazine();
    ok('토글 한 번 → 꺼짐', magEnabled() === false && localStorage.getItem('taamMagazine') === '0');
    toggleMagazine();
    ok('토글 두 번 → 다시 켜짐', magEnabled() === true && localStorage.getItem('taamMagazine') === null);
    const lbl = document.getElementById('magLabel');
    ok('메뉴 라벨이 「켜짐」', lbl && lbl.textContent.indexOf('켜짐') > 0);

    // ── 티켓 카드: 이름 / 일자·시간·인원 ──
    window._paSeatsLeft = () => 3;
    window._pcalRestName = () => '스시 아리마';
    window._tkDateLabel = () => '2026.11.19 (수)';
    window._audLabel = () => 'M 등급 이상';
    const html = _tkbRow({ id:'tk1', date:'2026.11.19', time:'18:00', totalPax:8,
                           status:'active', minTier:'M', ticketGenre:'스시' });
    const d = document.createElement('div'); d.innerHTML = html;
    const top = d.querySelector('.tkb-top'), sub = d.querySelector('.tkb-sub');
    ok('첫 줄은 매장 이름', top.querySelector('.tkb-nm').textContent === '스시 아리마');
    ok('첫 줄 오른쪽은 상태 배지', top.querySelector('.tkb-st') === top.lastElementChild);
    ok('첫 줄에 날짜가 없다', top.textContent.indexOf('2026.11.19') < 0);
    ok('둘째 줄에 날짜 · 시간 · 인원이 모여 있다',
       sub.textContent === '2026.11.19 (수) · 18:00 · 8명 · 스시');

    // 좌석 수를 모르면 인원을 적지 않는다 (0명 이라고 쓰지 않는다)
    const h2 = _tkbRow({ id:'tk2', date:'2026.12.01', time:'19:00', status:'active' });
    const d2 = document.createElement('div'); d2.innerHTML = h2;
    ok('좌석을 모르면 인원을 안 적는다', d2.querySelector('.tkb-sub').textContent.indexOf('명') < 0);
    ok('그래도 날짜·시간은 나온다',
       d2.querySelector('.tkb-sub').textContent === '2026.11.19 (수) · 19:00');

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
