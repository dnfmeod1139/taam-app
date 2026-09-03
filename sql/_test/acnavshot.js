// ═══════════════════════════════════════════════════════════════
// 어드민 팝업을 닫으면 어디에 남는가 (2026-09-03)
// ═══════════════════════════════════════════════════════════════
//   종전에는 팝업만 사라지고 그 아래 화면에 그대로 남았다. 메뉴에서 바로
//   연 팝업을 닫으면 어느 판에 서 있는지 알 수 없는 상태가 됐다.
//
//   ① 팝업 닫기 함수가 _acPopupClosed 를 부르는가 (전수)
//   ② 콘솔 위에서 닫으면 대시보드로 돌아가는가
//   ③ ⭐ 목록(.sub-screen) 위에서 닫으면 **목록에 남는가**
//      — 무조건 튕기면 보던 자리를 잃는다. 그게 더 나쁘다.
//
// 실행: node sql/_test/acnavshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const fs = require('fs');

// 팝업 닫기 함수는 전부 이 한 줄을 불러야 한다. 하나라도 빠지면
// 그 팝업만 옛 동작으로 남아 「왜 이것만 다르지」를 겪게 된다.
const MUST_CALL = [
  'closeAdminPwdModal', 'closeMemberPwdModal', 'closeAdminDepositGrant',
  'chefPhotoFixClose', 'pcalAdminClose', 'closeMembershipUntilMgmt',
  'closeSentInvitesScreen', 'paClose', 'tuGuestSeatClose'
];

(async () => {
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  // ── ① 소스에서 전수 확인 ───────────────────────────────────
  const src = fs.readFileSync('/home/user/taam-app/index.html', 'utf8');
  MUST_CALL.forEach(fn => {
    const i = src.indexOf('function ' + fn + '(');
    // 함수 본문만 잘라 본다 (다음 함수 선언 전까지)
    const body = i < 0 ? '' : src.slice(i, i + 900);
    const end = body.indexOf('\n}');
    ok(fn + ' 이 대시보드 복귀를 부른다 ⭐',
       i >= 0 && end > 0 && body.slice(0, end).indexOf('_acPopupClosed()') >= 0);
  });
  // 환율 설정은 인라인으로 자기를 지운다 — 거기에도 붙어야 한다
  ok('환율 설정 닫기도 부른다 ⭐',
     /fxSettingsPopup\\'\);if\(p\)p\.remove\(\);_acPopupClosed\(\)/.test(src));

  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.route('**://fonts.g**', r => r.abort());
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r2 = await p.evaluate(async () => {
    const res = [];
    const ok = (n, c) => res.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const $ = id => document.getElementById(id);
    document.getElementById('appWrapper').classList.add('ready');
    window._currentRole = 'superadmin';

    ok('_acPopupClosed 가 있다', typeof window._acPopupClosed === 'function');

    // acGo 를 가로채 「대시보드로 갔는가」만 본다
    let went = [];
    const realGo = window.acGo;
    window.acGo = (t) => { went.push(t); };

    // ── ② 콘솔 위에서 닫으면 대시보드로 ────────────────────────
    $('adminScreen').style.display = 'flex';
    document.querySelectorAll('.sub-screen, .restpage, .tu-screen, .mp-subpage')
      .forEach(e => { e.style.display = 'none'; });
    went = [];
    window._acPopupClosed(); await sleep(60);
    ok('콘솔 위에서 닫으면 대시보드로 ⭐', went.indexOf('today') >= 0);

    // ── ③ 목록 위에서 닫으면 목록에 남는다 ⭐ ──────────────────
    //   무조건 튕기면 보던 자리를 잃는다 — 그게 더 나쁘다.
    const list = $('ticketListScreen');
    if (list) {
      list.style.display = 'flex';
      went = [];
      window._acPopupClosed(); await sleep(60);
      ok('목록 위에서 닫으면 안 튕긴다 ⭐', went.length === 0);
      ok('목록이 그대로 열려 있다', getComputedStyle(list).display !== 'none');
      list.style.display = 'none';
    }

    // 콘솔 밖(회원 화면)에서는 아예 관여하지 않는다
    $('adminScreen').style.display = 'none';
    went = [];
    window._acPopupClosed(); await sleep(60);
    ok('콘솔 밖에서는 관여 안 한다 ⭐', went.length === 0);

    // 어드민이 아닌 사람에게도 안 돈다
    $('adminScreen').style.display = 'flex';
    window._currentRole = 'user';
    went = [];
    window._acPopupClosed(); await sleep(60);
    ok('회원에게는 안 돈다', went.length === 0);

    window.acGo = realGo;
    return res;
  });

  [...out, ...r2].forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = [...out, ...r2].filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===`
                          : `=== 전부 통과 (${out.length + r2.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
