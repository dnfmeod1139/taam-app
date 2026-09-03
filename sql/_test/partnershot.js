// ═══════════════════════════════════════════════════════════════
// 파트너 계정 — 앱 화면 검증 (2026-09-03)
// ═══════════════════════════════════════════════════════════════
//   ① 로그인에 「파트너」 탭이 있고, 고르면 아이디·비번만 묻는가
//   ② 아이디만 넣는가 (도메인은 앱이 붙인다) · @ 를 붙여 넣어도 되는가
//   ③ 권한이 없으면 **로그아웃시키는가** ← 로그인만 되고 어드민이 아닌 상태를 남기면 안 된다
//   ④ 단일 기기 등록을 부르는가 (CLAUDE.md — 모든 로그인 경로 공통)
//   ⑤ 발급 화면 — 슈퍼어드민만 · 비번은 한 번만 · 권한 없음을 알려주는가
//   ⑥ SQL·함수를 안 올렸으면 무엇을 해야 하는지 말하는가
//
// 실행: node sql/_test/partnershot.js
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
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const $ = id => document.getElementById(id);
    document.getElementById('appWrapper').classList.add('ready');
    window.showToast = (a, b2, c) => { window.__toast = [a, b2, c]; };

    // ── ① 로그인 탭 ────────────────────────────────────────────
    ok('파트너 탭이 있다 ⭐', !!$('vpLoginMethodPartner'));
    ok('아이디 칸이 있다',   !!$('vpPartnerId'));
    ok('비밀번호 칸이 있다', !!$('vpPartnerPw'));
    // ⚠ 이메일 칸이 아니다. 매장은 앞부분만 받아 적는다.
    ok('아이디 칸은 email 타입이 아니다 ⭐', $('vpPartnerId').type === 'text');
    ok('자동 대문자를 끈다 ⭐', $('vpPartnerId').getAttribute('autocapitalize') === 'none');

    window.vpSwitchLoginMethod('partner'); await sleep(120);
    ok('고르면 파트너 칸이 열린다 ⭐', $('vpPartnerRow').style.display !== 'none');
    ok('비밀번호 로그인 칸은 닫힌다',  $('vpPasswordRow').style.display === 'none');
    ok('SMS 칸도 닫힌다',              $('vpPhoneRow').style.display === 'none');
    const vbtn = document.querySelector('.phone-verify-btn');
    ok('버튼이 파트너 로그인을 부른다 ⭐',
       (vbtn.getAttribute('onclick') || '').indexOf('vpPartnerLogin') >= 0);
    // OTP 는 없다 — 인증번호 칸이 보이면 안 된다
    ok('인증번호 칸을 안 보여준다 ⭐',
       $('vpCode').parentElement.style.display === 'none');
    window.vpSwitchLoginMethod('password'); await sleep(80);
    ok('다시 비밀번호로 돌아간다', $('vpPartnerRow').style.display === 'none');
    window.vpSwitchLoginMethod('partner'); await sleep(80);

    // ── ② 아이디 → 이메일 변환 ─────────────────────────────────
    let signInArg = null, signedOut = 0, claimed = null, touched = 0;
    window._claimDeviceSession = (u, role) => { claimed = role; return Promise.resolve(); };
    window._applyServerAdminGrant = async () => { window._currentRole = window.__grantRole; };
    const mkSb = (loginOk) => ({
      auth: {
        signInWithPassword: (a) => { signInArg = a;
          return Promise.resolve(loginOk
            ? { data: { user: { id: 'U1' } }, error: null }
            : { data: null, error: { message: 'Invalid login credentials' } }); },
        signOut: () => { signedOut++; return Promise.resolve({}); },
        getSession: () => Promise.resolve({ data: { session: { access_token: 'TOK' } } })
      },
      rpc: (fn) => { if (fn === 'taam_partner_touch') touched++;
                     return Promise.resolve({ data: null, error: null }); }
    });

    window.sb = mkSb(true); window.__grantRole = 'admin';
    window.adminDirectAccess = () => {};
    $('vpPartnerId').value = 'sushi-arai'; $('vpPartnerPw').value = 'ABCD-EFGH-JKMN';
    await window.vpPartnerLogin(); await sleep(300);
    ok('아이디에 도메인을 붙인다 ⭐',
       signInArg && signInArg.email === 'sushi-arai@partner.taam.kr');
    ok('비밀번호를 그대로 넘긴다', signInArg && signInArg.password === 'ABCD-EFGH-JKMN');
    // ⚠ 도메인이 서버(Edge Function)와 같아야 한다. 어긋나면 「비번이 틀렸다」로 보인다.
    ok('도메인 상수가 서버와 같다 ⭐', window.PARTNER_LOGIN_DOMAIN === 'partner.taam.kr');
    // 단일 기기 — 모든 로그인 경로가 이 함수 하나만 부른다 (CLAUDE.md)
    ok('기기 등록을 부른다 ⭐', claimed === 'admin');
    ok('로그인 기록을 남긴다', touched === 1);

    // 통째로 붙여넣어도 된다
    signInArg = null;
    $('vpPartnerId').value = 'Sushi-Arai@partner.taam.kr  ';
    await window.vpPartnerLogin(); await sleep(300);
    ok('@ 뒤를 떼고 소문자로 ⭐',
       signInArg && signInArg.email === 'sushi-arai@partner.taam.kr');

    // ── ③ 권한이 없으면 들여보내지 않는다 ⭐ ────────────────────
    //   로그인만 되고 어드민이 아닌 상태로 두면, 매장은 「됐다」고 생각한 채
    //   아무것도 못 하는 화면을 본다. 그럴 바엔 못 들어오게 한다.
    signedOut = 0; window.__grantRole = 'user'; window._currentRole = 'user';
    $('vpPartnerId').value = 'no-grant'; $('vpPartnerPw').value = 'x';
    await window.vpPartnerLogin(); await sleep(300);
    ok('권한 없으면 로그아웃시킨다 ⭐', signedOut === 1);
    ok('무엇이 문제인지 말한다 ⭐',
       $('vpHint').textContent.indexOf('권한') >= 0);

    // 비밀번호가 틀렸을 때 — 아이디 유무를 알려주지 않는다
    window.sb = mkSb(false);
    $('vpPartnerId').value = 'sushi-arai'; $('vpPartnerPw').value = 'nope';
    await window.vpPartnerLogin(); await sleep(200);
    const bad = $('vpHint').textContent;
    ok('틀리면 알려준다', bad.indexOf('올바르지') >= 0);
    ok('아이디 유무를 흘리지 않는다 ⭐',
       bad.indexOf('없는') < 0 && bad.indexOf('찾을 수') < 0);

    // 빈 칸은 서버를 안 부른다
    window.sb = mkSb(true); signInArg = null;
    $('vpPartnerId').value = ''; $('vpPartnerPw').value = 'x';
    await window.vpPartnerLogin(); await sleep(120);
    ok('아이디가 비면 서버를 안 부른다 ⭐', signInArg === null);
    $('vpPartnerId').value = 'a-b'; $('vpPartnerPw').value = '';
    await window.vpPartnerLogin(); await sleep(120);
    ok('비번이 비면 서버를 안 부른다 ⭐', signInArg === null);

    // ── ⑤ 발급 화면 ────────────────────────────────────────────
    window._currentRole = 'user';
    window.paOpen(); await sleep(120);
    ok('슈퍼어드민이 아니면 안 열린다 ⭐', $('paSheet').style.display === 'none');
    window._currentRole = 'superadmin';
    window.restaurantDB = [{ id: 'R1', name: '스시 아라이', name_en: 'Sushi Arai' }];

    const ROWS = [
      { login_id:'sushi-arai', label:'스시 아라이', has_grant:true,
        handed_at:'2026-09-01T00:00:00Z', last_login_at:null, disabled:false },
      { login_id:'no-grant', label:'타카미츠', has_grant:false,
        handed_at:null, last_login_at:null, disabled:false }
    ];
    let RPC = [];
    window.sb = { rpc: (fn, a) => { RPC.push([fn, a]);
      return Promise.resolve({ data: fn === 'taam_partner_accounts' ? ROWS : null, error: null }); },
      auth: { getSession: () => Promise.resolve({ data:{ session:{ access_token:'TOK' } } }) } };
    let CALLS = [];
    window.fetch = (url, opt) => { CALLS.push([url, JSON.parse(opt.body)]);
      return Promise.resolve({ status:200, json: () => Promise.resolve(
        { ok:true, login_id:'sushi-arai', password:'ABCD-EFGH-JKMN' }) }); };

    window.paOpen(); await sleep(300);
    ok('슈퍼어드민에게는 열린다', $('paSheet').style.display === 'flex');
    let t = $('paBody').textContent;
    ok('서버에 목록을 묻는다 ⭐', RPC.some(x => x[0] === 'taam_partner_accounts'));
    ok('미리 만들어 둔다고 적는다', t.indexOf('안 쓰면 그만') >= 0);
    ok('발급한 계정을 보여준다', t.indexOf('sushi-arai') >= 0);
    ok('건넸는지 보여준다',      t.indexOf('건넴') >= 0);
    ok('안 쓴 계정을 알려준다 ⭐', t.indexOf('한 번도 안 씀') >= 0);
    // ⚠ 「로그인은 되는데 어드민이 아니다」 — 가장 헷갈리는 고장이라 눈에 띄어야 한다
    ok('권한 없는 계정을 짚어준다 ⭐', t.indexOf('권한 없음') >= 0);
    ok('여러 기기 허용이 기본 ⭐', $('paMulti').checked === true);

    // 매장을 고르면 아이디를 지어 준다
    $('paRest').value = 'R1'; window._paSuggestId();
    ok('아이디를 지어 준다 ⭐', $('paId').value === 'sushi-arai');

    // 잘못된 아이디는 서버를 안 부른다
    CALLS = [];
    $('paId').value = 'AB';
    await window.paCreate(); await sleep(150);
    ok('짧은 아이디는 서버를 안 부른다 ⭐', CALLS.length === 0);
    ok('무엇이 틀렸는지 말한다', $('paErr').textContent.indexOf('아이디') >= 0);
    $('paId').value = '스시아라이';
    await window.paCreate(); await sleep(150);
    ok('한글 아이디도 막는다 ⭐', CALLS.length === 0);

    // 제대로 만들면 Edge Function 을 부른다
    $('paId').value = 'sushi-arai';
    await window.paCreate(); await sleep(300);
    ok('Edge Function 을 부른다 ⭐',
       CALLS.length === 1 && String(CALLS[0][0]).indexOf('/functions/v1/partner-account') >= 0);
    ok('만들기라고 보낸다', CALLS[0][1].action === 'create');
    ok('매장과 아이디를 넘긴다',
       CALLS[0][1].rest_id === 'R1' && CALLS[0][1].login_id === 'sushi-arai');
    ok('여러 기기 허용을 넘긴다 ⭐', CALLS[0][1].multi_device === true);

    // 비밀번호는 여기서만 보인다
    t = $('paBody').textContent;
    ok('비밀번호를 보여준다 ⭐', t.indexOf('ABCD-EFGH-JKMN') >= 0);
    ok('지금만 보인다고 적는다 ⭐', t.indexOf('지금만 보입니다') >= 0);
    ok('파트너 탭을 쓰라고 적는다', t.indexOf('파트너') >= 0);
    ok('아이디만 넣으라고 적는다 ⭐', t.indexOf('아이디만') >= 0);
    window.paDoneMade(); await sleep(120);
    ok('확인하면 비밀번호가 사라진다 ⭐',
       $('paBody').textContent.indexOf('ABCD-EFGH-JKMN') < 0);

    // ── ⑥ SQL 을 안 돌렸을 때 ──────────────────────────────────
    window.sb = { rpc: () => Promise.resolve({ data:null,
      error: { message: 'function public.taam_partner_accounts does not exist' } }),
      auth: { getSession: () => Promise.resolve({ data:{ session:{ access_token:'TOK' } } }) } };
    window.paOpen(); await sleep(300);
    ok('무엇을 해야 하는지 알려준다 ⭐',
       $('paBody').textContent.indexOf('partner_accounts.sql') >= 0);
    ok('만들 수 있는 버튼을 안 준다', $('paFoot').textContent.trim() === '');

    window.paClose(); await sleep(80);
    ok('닫힌다', $('paSheet').style.display === 'none');
    ok('세로 제스처만 받는다',
       getComputedStyle($('paSheet')).touchAction === 'pan-y');
    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
