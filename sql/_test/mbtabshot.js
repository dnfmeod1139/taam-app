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
    const adm = document.getElementById('adminScreen');
    adm.style.display = 'flex';

    // 회원 6명 — M 2, T 3, 탈퇴 1
    window._mbRows = [
      { id:'u1', display_name:'박서준', phone:'010-1111-1111', membership_tier:'M', membership_expires_at:'2027-12-31', created_at:'2026-01-06' },
      { id:'u2', display_name:'최유진', phone:'010-2222-2222', membership_tier:'M', membership_expires_at:'2027-12-31', created_at:'2026-01-05' },
      { id:'u3', display_name:'이하늘', phone:'010-3333-3333', membership_tier:'T', created_at:'2026-01-04' },
      { id:'u4', display_name:'정민서', phone:'010-4444-4444', membership_tier:'T', created_at:'2026-01-03' },
      { id:'u5', display_name:'김도윤', phone:'010-5555-5555', membership_tier:'T', created_at:'2026-01-02' },
      { id:'u6', display_name:'탈퇴자', phone:'010-6666-6666', membership_tier:'T', created_at:'2026-01-01', deleted_at:'2026-02-01' }
    ];
    window._tbRows = []; window._acBans = []; window._acRules = [{restaurant_id:'*'}];
    window._mbBuyMap = null; window._mbBuySig = null;
    window._mbState = { q:'', filter:'all', open:null, seg:'list' };

    document.getElementById('mbScreen').style.display = 'flex';
    _mbRender();

    // ── 칩 구성 ──
    const chips = [...document.querySelectorAll('#mbFilters .tb-chip')]
      .map(c => c.textContent.replace(/\d+$/, '').trim());
    ok('칩이 넷 (' + chips.join(' / ') + ')', chips.length === 4);
    ok('전체 · M 등급 · T 등급 · 탈퇴',
       JSON.stringify(chips) === JSON.stringify(['전체','M 등급','T 등급','탈퇴']));
    ok('구매 있음 · 예치금 보유 · 만료 임박 · 이용 제한 · 확인 필요가 없다',
       !chips.some(c => /구매|예치금|만료|제한|확인/.test(c)));

    // ── 도구는 명부 **아래** ──
    const body = document.getElementById('mbBody');
    const firstRow = body.querySelector('.mb-row');
    const tools = body.querySelector('.ac-tools');
    ok('도구 블록이 있다', !!tools);
    ok('명부가 먼저, 도구가 나중',
       !!firstRow && !!tools &&
       (firstRow.compareDocumentPosition(tools) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0);
    ok('도구 앞에 선으로 끊었다', getComputedStyle(tools).borderTopWidth !== '0px');

    // ── 칩을 누르면 맨 위로 ──
    body.scrollTop = 400;
    mbSetFilter('M');
    ok('칩을 누르면 목록 맨 위로', body.scrollTop === 0);
    ok('M 등급만 남는다', body.querySelectorAll('.mb-row').length === 2);
    mbSetFilter('gone');
    ok('탈퇴만 남는다', body.querySelectorAll('.mb-row').length === 1);
    mbSetFilter('all');
    ok('전체는 산 회원 5명', body.querySelectorAll('.mb-row').length === 5);

    // 없어진 칩이 골라져 있으면 전체로 되돌린다
    window._mbState.filter = 'bal';
    _mbRenderFilters();
    ok('옛 필터가 남아 있으면 전체로', _mbState.filter === 'all');

    // ── 티켓 탭도 도구가 아래 ──
    window.ticketDB = window.ticketDB || [];
    window._tkbState = { q:'', filter:'all', open:null };
    document.getElementById('tkbScreen').style.display = 'flex';
    _tkbRender();
    const tb = document.getElementById('tkbBody');
    const tk = tb.querySelector('.tkb-row'), tt = tb.querySelector('.ac-tools');
    ok('티켓 탭도 도구가 아래',
       !tt || !tk || (tk.compareDocumentPosition(tt) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0);

    // ── ← 는 대시보드로 ──
    _acCloseOthers(null);
    document.getElementById('mbScreen').style.display = 'flex';
    acBack();
    ok('회원 탭에서 ← → 대시보드',
       getComputedStyle(document.getElementById('todayBoardScreen')).display !== 'none'
       && getComputedStyle(document.getElementById('mbScreen')).display === 'none');
    ok('콘솔은 안 닫힌다', getComputedStyle(adm).display !== 'none');

    // 🆕 앱으로 나가는 문은 ✕ 다 (← 는 늘 대시보드)
    let out2 = 0;
    const realMain = window.openMain; window.openMain = function(){ out2++; };
    acExit();
    ok('✕ → 회원 앱',
       getComputedStyle(document.getElementById('todayBoardScreen')).display === 'none'
       && getComputedStyle(adm).display === 'none' && out2 === 1);
    window.openMain = realMain;

    adm.style.display = 'none';
    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
