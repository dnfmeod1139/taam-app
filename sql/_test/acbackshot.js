// ═══════════════════════════════════════════════════════════════
// 어드민 콘솔 — 뒤로가기는 「바로 전 단계」다 (2026-09-04)
// ═══════════════════════════════════════════════════════════════
//   슈퍼어드민이 메뉴 항목에 들어갔다 나오면 종종 「전체 메뉴」에 떨어졌다.
//   로그아웃 한 줄뿐인 빈 화면이라, 아무도 가려던 적 없는 곳이다.
//
//   원인은 하나가 아니라 **같은 실수 여덟 번**이었다. 화면을 닫는 함수가
//   그냥 숨기기만 하고 콘솔로 돌아가지 않았다. adminScreen 은 바탕이지
//   목적지가 아닌데, 위에 있던 것이 사라지면 그 바탕이 드러난다.
//
//   ⚠ 재보는 길이 실제 길과 같아야 한다. 「더보기」에서 항목을 누르면
//     moGo 가 **더보기를 닫고** 연다. 더보기를 열어 둔 채로 항목만 열면
//     밑에 더보기가 남아서 **전부 통과로 보인다** — 처음에 그렇게 재서
//     「문제 없음」이라는 답을 얻었다. 두 번 속지 않도록 여기 적어 둔다.
//
//   ① 메뉴 항목을 닫으면 「전체 메뉴」에 남지 않는다 ⭐
//   ② 더보기에서 들어갔으면 더보기로, 대시보드에서 들어갔으면 대시보드로 ⭐
//   ③ 코드로 만들어 붙이는 판은 _acOverlayClose 로 닫는다 (정적)
//
// 실행: node sql/_test/acbackshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const fs = require('fs');

// 콘솔에서 열리는 판 — [이름, 여는 식, 닫는 식]
const ITEMS = [
  ['예약 초대 발송',      'openReservationInviteScreen()', 'closeReservationInviteScreen()'],
  ['티켓 오픈 알림 발송',  'openTicketBroadcastScreen()',   'closeTicketBroadcastScreen()'],
  ['티켓 접근권한',       'openTicketAccessMgmt()',        'closeTicketAccessMgmt()'],
  ['메인 팝업 발행',      'popAdminOpen()',                "_acOverlayClose('popAdmin')"],
  ['이벤트 발행 내역',     'popHistoryOpen()',              "_acOverlayClose('popHistory')"],
  ['판매 오픈 관리',      'tkSaleMgrOpen()',               "_acOverlayClose('tkSaleMgr')"],
  ['계보도 관리',        'openLineageAdmin()',            'closeLineageAdmin()'],
  ['발송한 예약 초대 내역', 'openSentInvitesScreen()',       'closeSentInvitesScreen()'],
  ['사진 캘린더 편집',     'pcalAdminOpen()',               'pcalAdminClose()'],
  ['파트너 계정 발급',     'paOpen()',                      'paClose()'],
  ['회원 예치금 부여',     'openAdminDepositGrant()',       'closeAdminDepositGrant()'],
  ['멤버십 만료일 관리',   'openMembershipUntilMgmt()',     'closeMembershipUntilMgmt()'],
  ['셰프 사진 정리',      'chefPhotoFixOpen()',            'chefPhotoFixClose()'],
  ['자주 쓰는 메뉴 편집',  'qaOpenEdit()',                  'qaCloseEdit()'],
  ['로그인 비밀번호 변경',  'openMemberPwdModal()',          'closeMemberPwdModal()'],
  ['레스토랑 등록',       'openRestPage()',                'closeRestPage()'],
  ['티켓 업로드',        'openTU()',                      'closeTU()'],
  ['멤버십 · 게스트',     'msaOpen()',                     'msaBack()'],
  ['정산 링크',         'kskOpen()',                     'kskBack()'],
  ['방문 기록',         "openSubPage('visScreen')",      "closeSubPage('visScreen')"],
  ['노출 제어',         "openSubPage('visibilityMgmtScreen')", "closeSubPage('visibilityMgmtScreen')"],
  ['파트너십 관리',       "openSubPage('partnerMgmtScreen')",    "closeSubPage('partnerMgmtScreen')"],
];

(async () => {
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  // ── ③ 정적 — 코드로 만든 판을 손으로 지우지 않는가 ─────────────
  const src = fs.readFileSync('/home/user/taam-app/index.html', 'utf8');
  ok('_acOverlayClose 가 있다', src.indexOf('function _acOverlayClose') >= 0);
  // ⚠ 배경 클릭으로 닫히는 판이 `el.remove()` 로 끝나면 복귀가 빠진다.
  //   새 판을 만들 때 옛 줄을 베껴 오는 일이 잦아, 그 모양 자체를 막는다.
  const raw = (src.match(/if\(ev\.target === el\) el\.remove\(\);/g) || []).length;
  ok('배경 클릭이 그냥 지우지 않는다 ⭐ (' + raw + '곳)', raw <= 1);   // 회원앱 tierLockModal 하나만 예외

  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  p.on('dialog', d => d.dismiss().catch(() => {}));
  await p.route('**://fonts.g**', r => r.abort());
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  // ⚠ 부팅이 끝나야(#appWrapper.ready) adminScreen 이 보인다. 안 세우면
  //   CSS 가 !important 로 숨겨 모든 판정이 「콘솔 밖」이 된다.
  await p.evaluate(() => {
    window._currentRole = 'superadmin';
    document.getElementById('appWrapper').classList.add('ready');
    window._isSuperAdmin = () => true;
    window.confirm = () => false;      // 파괴적 항목은 취소로
    window.alert = () => {};
    openAdmin();
  });
  await p.waitForTimeout(500);

  const r = await p.evaluate(async (items) => {
    const res = [];
    const wait = ms => new Promise(r => setTimeout(r, ms));
    const cs = e => { try { return getComputedStyle(e).display; } catch (x) { return 'none'; } };
    const pages = () => [...document.querySelectorAll('.sub-screen,.restpage,.tu-screen,.mp-subpage')]
      .filter(e => cs(e) !== 'none').map(e => e.id);
    const admOn = () => cs(document.getElementById('adminScreen')) !== 'none';

    // 실제 길: 그 탭에 서 있다가 → 탭을 닫고 → 항목을 연다 (moGo 와 같다)
    const run = async (tab, openSrc, closeSrc) => {
      acGo(tab); await wait(280);
      _acNavHold(); closeSubPage(tab === 'mo' ? 'moScreen' : 'todayBoardScreen');
      await wait(120);
      try { eval(openSrc); } catch (e) { return { err: e.message }; }
      await wait(950);                                   // _acNavHold(700) 이 풀린 뒤
      try { eval(closeSrc); } catch (e) { return { err: e.message }; }
      await wait(800);
      return { bare: admOn() && pages().length === 0, back: pages()[0] || '(없음)' };
    };

    for (const [name, o, c] of items) {
      // ── ① 더보기에서 들어가면 더보기로 ──
      const a = await run('mo', o, c);
      if (a.err) { res.push('FAIL ' + name + ' — 실행 실패: ' + a.err); continue; }
      res.push((!a.bare && a.back === 'moScreen' ? 'OK   ' : 'FAIL ')
        + '더보기 → ' + name + ' → 더보기'
        + (a.bare ? '  ❌ 전체 메뉴에 남음' : (a.back === 'moScreen' ? '' : '  ← ' + a.back)));
    }

    // ── ② 대시보드에서 들어가면 대시보드로 ⭐ ──
    //   전 단계가 어디였는지를 실제로 기억하는지 본다. 늘 대시보드로
    //   보내면 ①이 통과해도 이건 떨어진다 (거꾸로도 마찬가지다).
    for (const [name, o, c] of items.slice(0, 6)) {
      const a = await run('today', o, c);
      if (a.err) { res.push('FAIL ' + name + ' — 실행 실패: ' + a.err); continue; }
      res.push((!a.bare && a.back === 'todayBoardScreen' ? 'OK   ' : 'FAIL ')
        + '대시보드 → ' + name + ' → 대시보드'
        + (a.bare ? '  ❌ 전체 메뉴에 남음' : (a.back === 'todayBoardScreen' ? '' : '  ← ' + a.back)));
    }
    return res;
  }, ITEMS);

  [...out, ...r].forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = [...out, ...r].filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===`
                          : `=== 전부 통과 (${out.length + r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
