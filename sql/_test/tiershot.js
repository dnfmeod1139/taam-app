// ═══════════════════════════════════════════════════════════════
// 일반 회원(A 등급) — 앱 화면 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
// 서버가 막는지는 t_tier.sh 가 본다. 여기서 보는 건
// **앱의 판정이 서버와 한 글자도 안 어긋나는가** 이다.
// 어긋나면 보이는데 사면 막히거나(또는 그 반대) — 둘 다 최악이다.
//
//   ① _tkTierAllowed 가 서버 규칙과 같은가
//   ② 일반공개는 하한이 아니라 개방인가 (등급 없는 옛 회원도 통과)
//   ③ 막힌 자리에서 멤버십으로 갈 길이 있는가
//   ④ 「멤버십 전용」 노출이 유료 회원에게는 열리는가
//
// 실행: node sql/_test/tiershot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));

    document.getElementById('appWrapper').classList.add('ready');
    const ms = document.getElementById('mainScreen'); if (ms) ms.style.display = 'flex';
    window._currentRole = 'user';

    const setTier = g => { window._currentUserGrade = g; };
    const T = m => ({ minTier: m });
    // 게스트 초대석 — 이유·수량까지 갖춰야 열린 것으로 친다 (서버와 같은 조건)
    const SEAT = { guestOpen: true, guestSeatQty: 2, guestOpenReason: '셰프의 요청으로' };
    const SEAT_NOWHY = { guestOpen: true, guestSeatQty: 2, guestOpenReason: '' };
    const SEAT_NOQTY = { guestOpen: true, guestSeatQty: 0, guestOpenReason: '셰프의 요청으로' };

    ok('_tkIsOpenTicket 존재',  typeof window._tkIsOpenTicket === 'function');
    ok('_tkIsFreeMember 존재',  typeof window._tkIsFreeMember === 'function');
    ok('_visMemberOk 존재',     typeof window._visMemberOk === 'function');

    // ── ① 게스트 초대석 판정 (2026-09) ──────────────────────
    //   ⚠ min_tier='A' 만으로는 아니다. 이유·수량까지 갖춰야 한다 —
    //     서버 가드와 같은 조건이어야 「보이는데 못 사는」 화면이 안 생긴다.
    ok('열고 이유·수량이 있으면 게스트석 ⭐', window._tkIsGuestSeat(SEAT) === true);
    ok('이유가 없으면 아니다 ⭐',            window._tkIsGuestSeat(SEAT_NOWHY) === false);
    ok('수량이 0이면 아니다 ⭐',             window._tkIsGuestSeat(SEAT_NOQTY) === false);
    ok('min_tier=A 만으로는 아니다 ⭐',      window._tkIsGuestSeat(T('A')) === false);
    ok('아무것도 없으면 아니다',             window._tkIsGuestSeat({}) === false);
    ok('이유를 꺼내 준다', window._tkGuestReason(SEAT) === '셰프의 요청으로');

    // ── ② 등급별 판정 — 서버 t_tier.sh 와 같은 표 ────────────
    //    행: 회원 등급 / 열: 티켓 min_tier
    const cases = [
      ['A', 'A',  false, '게스트 — min_tier=A 만으로는 못 산다 ⭐'],
      ['A', '',   false, '게스트 — 제한 없는 티켓은 못 산다 ⭐'],
      ['A', 'T',  false, '게스트 — T 전용은 못 산다'],
      ['A', 'M',  false, '게스트 — M 전용은 못 산다'],
      ['T', '',   true,  'T 회원 — 제한 없는 티켓'],
      ['T', 'A',  true,  'T 회원 — 일반공개'],
      ['T', 'T',  true,  'T 회원 — T 전용'],
      ['T', 'M',  false, 'T 회원 — M 전용은 막힘'],
      ['M', 'M',  true,  'M 회원 — M 전용'],
      ['M', '',   true,  'M 회원 — 제한 없는 티켓'],
      [null, '',  true,  '등급 없는 옛 회원 — 제한 없는 티켓'],
      [null, 'A', true,  '등급 없는 옛 회원 — 일반공개 ⭐'],
      [null, 'T', false, '등급 없는 옛 회원 — T 전용은 막힘']
    ];
    cases.forEach(([mine, need, want, name]) => {
      setTier(mine);
      ok(name, window._tkTierAllowed(T(need)) === want);
    });

    // 게스트는 **게스트석만** 산다
    setTier('A');
    ok('게스트 — 게스트석은 산다 ⭐',        window._tkTierAllowed(SEAT) === true);
    ok('게스트 — 이유 없는 자리는 못 산다 ⭐', window._tkTierAllowed(SEAT_NOWHY) === false);
    ok('게스트 — 수량 0인 자리는 못 산다 ⭐',  window._tkTierAllowed(SEAT_NOQTY) === false);
    setTier('M');
    ok('M 회원도 게스트석을 살 수 있다',       window._tkTierAllowed(SEAT) === true);

    // 슈퍼어드민은 전부 통과
    window._currentRole = 'superadmin';
    ok('슈퍼어드민은 M 전용도 통과', window._tkTierAllowed(T('M')) === true);
    ok('슈퍼어드민은 제한 없는 것도 통과', window._tkTierAllowed(T('')) === true);
    window._currentRole = 'user';

    // ── ③ 막힌 자리에서 갈 곳 ────────────────────────────────
    let opened = 0;
    const realOpen = window.openMshipScreen;
    window.openMshipScreen = () => { opened++; };

    setTier('A');
    document.getElementById('tierLockModal')?.remove();
    window.showTierLockPopup(T(''));
    await sleep(80);
    let el = document.getElementById('tierLockModal');
    ok('일반 회원 — 제한 없는 티켓에도 팝업이 뜬다 ⭐', !!el);
    // 통합 스펙(2026-09-02): 제목 「멤버십 전용입니다」 / 본문 「정원 33인 · 심사제」
    ok('「멤버십 전용입니다」라고 적는다',
       !!el && el.textContent.indexOf('멤버십 전용입니다') >= 0);
    ok('정원과 심사제를 적는다',
       !!el && el.textContent.indexOf('33인') >= 0 && el.textContent.indexOf('심사제') >= 0);
    ok('심사 신청 버튼이 있다 ⭐', !!el && !!el.querySelector('#tlkApply'));
    ok('멤버십 안내 버튼이 있다', !!el && !!el.querySelector('#tlkMship'));
    ok('멤버십이 주는 것을 적어 준다',
       !!el && el.textContent.indexOf('셰프 계보도') >= 0);
    el.querySelector('#tlkMship').click(); await sleep(80);
    ok('누르면 멤버십 화면으로 간다', opened === 1);
    ok('누르면 팝업이 닫힌다', !document.getElementById('tierLockModal'));

    // 닫기도 된다
    window.showTierLockPopup(T('')); await sleep(80);
    document.getElementById('tierLockModal').querySelector('#tlkClose').click(); await sleep(80);
    ok('닫기로도 닫힌다', !document.getElementById('tierLockModal'));

    // 유료 회원에게는 종전 팝업 그대로 (멤버십 버튼 없음)
    setTier('T');
    window.showTierLockPopup(T('M')); await sleep(80);
    el = document.getElementById('tierLockModal');
    ok('T 회원 — M 전용 팝업은 종전대로', !!el && !el.querySelector('#tlkMship'));
    ok('T 회원 — 「M 등급 전용」이라고 적는다',
       !!el && el.textContent.indexOf('M 등급') >= 0);
    el.remove();
    // 제한 없는 티켓에는 유료 회원에게 팝업이 안 뜬다
    window.showTierLockPopup(T('')); await sleep(60);
    ok('T 회원 — 제한 없는 티켓엔 팝업이 안 뜬다', !document.getElementById('tierLockModal'));

    window.openMshipScreen = realOpen;

    // ── ④ 「멤버십 전용」 노출 ───────────────────────────────
    //   종전엔 슈퍼어드민만 통과해서, 계보도를 멤버십 전용으로 걸면
    //   M 등급도 못 봤다 — 사실상 「슈퍼어드민 전용」이었다.
    setTier('M'); ok('M 회원은 멤버십 전용을 본다', window._visMemberOk() === true);
    setTier('T'); ok('T 회원도 본다',               window._visMemberOk() === true);
    setTier('A'); ok('일반 회원은 못 본다 ⭐',       window._visMemberOk() === false);
    setTier(null); ok('등급 없으면 못 본다',         window._visMemberOk() === false);

    window._visibilitySettings = { contents: 'membership', chat: 'public', x: 'maintenance' };
    window._isSuperAdmin = () => false;
    setTier('M');
    ok('멤버십 전용 계보도 — M 은 열린다', window.isVisible('contents') === true);
    setTier('A');
    ok('멤버십 전용 계보도 — A 는 막힌다', window.isVisible('contents') === false);
    ok('공개 항목은 A 도 열린다',          window.isVisible('chat') === true);
    ok('점검 중은 M 도 막힌다',
       (function(){ setTier('M'); return window.isVisible('x') === false; })());

    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : '=== 전부 통과 ==='));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
