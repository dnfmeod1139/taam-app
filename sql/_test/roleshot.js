// ═══════════════════════════════════════════════════════════════
// 권한이 조용히 내려가지 않는가 (2026-09-03)
// ═══════════════════════════════════════════════════════════════
//   「슈퍼 어드민인데 지금 나오는 화면은 일반 회원이야」
//
//   네트워크가 끊기면 getUser() 가 사용자 없이 돌아온다. 그걸 「슈퍼어드민이
//   아니다」로 읽어 권한을 내리고, saveRole() 로 **기기에 남겼다.**
//   네트워크가 돌아와도 일반 회원인 채였다 — 다시 로그인해야만 풀렸다.
//
//   ① 이메일을 못 읽으면 아무것도 하지 않는가 ⭐
//   ② 진짜 남의 계정이면 내리는가 (원래 목적은 지켜지는가)
//   ③ 기기 값이 잘못 낮아져 있으면 되올리는가 ⭐
//
// 실행: node sql/_test/roleshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.route('**://fonts.g**', r => r.abort());
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const SUPER = 'dnfmeod@playtaam.com';

    ok('슈퍼어드민 이메일 목록이 있다', Array.isArray(window.TAAM_SUPER_ADMIN_EMAILS)
       || typeof window._taamIsSuperEmail === 'function');
    ok('그 이메일을 슈퍼어드민으로 본다', window._taamIsSuperEmail(SUPER) === true);
    ok('남의 이메일은 아니다', window._taamIsSuperEmail('someone@else.com') === false);

    // ── ① 이메일을 못 읽었을 때 ⭐ ─────────────────────────────
    //   네트워크가 끊긴 동안이다. 여기서 내리면 기기에 남아 계속 일반 회원이 된다.
    const cases = [undefined, null, '', '   '];
    let demoted = 0;
    cases.forEach(v => {
      window._currentRole = 'superadmin';
      if (window._roleGuardByEmail(v)) demoted++;
    });
    ok('못 읽었으면 안 내린다 ⭐', demoted === 0);
    ok('권한이 그대로 남는다 ⭐', window._currentRole === 'superadmin');

    // ── ② 진짜 남의 계정이면 내린다 (원래 목적) ────────────────
    window._currentRole = 'superadmin';
    const did = window._roleGuardByEmail('someone@else.com');
    ok('남의 계정이면 내린다 ⭐', did === true && window._currentRole === 'user');

    // 슈퍼어드민 이메일이면 손대지 않는다
    window._currentRole = 'superadmin';
    ok('본인 계정은 안 건드린다',
       window._roleGuardByEmail(SUPER) === false && window._currentRole === 'superadmin');

    // 이미 슈퍼어드민이 아니면 할 일이 없다
    window._currentRole = 'user';
    ok('이미 일반 회원이면 아무 일 없음', window._roleGuardByEmail('x@y.com') === false);

    return out;
  });

  // ── ③ 잘못 내려간 뒤 되올리는가 ⭐ ───────────────────────────
  //   부팅에서 getUser() 가 슈퍼어드민 이메일을 주면, 기기 값이 낮아도 되돌린다.
  const r2 = await p.evaluate(async () => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    window._currentRole = 'user';            // 지난번에 잘못 내려간 상태
    window.saveRole = function(){};
    window.updateMpAdminBtn = function(){};
    window.openMain = function(){};
    window.loadRole = function(){};
    // adminDirectAccess 는 끝에서 콘솔 화면까지 연다. 여기서 보려는 것은
    // 권한 판정 하나뿐이라, 화면 여는 쪽은 막아 둔다.
    window.openAdmin = function(){};
    window.cardPayTestSync = window.newHomeSync = window.magSync =
      window.pcalApplyGnb = function(){};
    var mkSb = function(res){ return { auth: { getUser: function(){ return Promise.resolve(res); } },
      from: function(){ return { select: function(){ return Promise.resolve({ data: [], error: null }); } }; } }; };
    window.sb = mkSb({ data: { user: { email: 'dnfmeod@playtaam.com' } }, error: null });
    window.adminDirectAccess();
    await sleep(300);
    ok('슈퍼어드민 계정이면 되올린다 ⭐', window._currentRole === 'superadmin');

    // 네트워크가 끊긴 모양 — 오류가 오면 판단하지 않는다
    window._currentRole = 'superadmin';
    window.sb = mkSb({ data: { user: null }, error: { message: 'Failed to fetch' } });
    window.adminDirectAccess();
    await sleep(300);
    ok('오류가 오면 안 내린다 ⭐', window._currentRole === 'superadmin');

    // 사용자가 없이 조용히 돌아와도 마찬가지다
    window._currentRole = 'superadmin';
    window.sb = mkSb({ data: { user: null }, error: null });
    window.adminDirectAccess();
    await sleep(300);
    ok('사용자가 없어도 안 내린다 ⭐', window._currentRole === 'superadmin');
    return out;
  });

  [...r, ...r2].forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = [...r, ...r2].filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===`
                          : `=== 전부 통과 (${r.length + r2.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
