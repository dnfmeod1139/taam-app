// ═══════════════════════════════════════════════════════════════
// 회원 추천권 — 아직 열지 않는다 (2026-09-04)
// ═══════════════════════════════════════════════════════════════
//   회원이 추천 코드를 만들어 남에게 보내는 기능. 지우지 않고 플래그
//   뒤에 둔다 (CARD_PAY_LIVE·NEW_HOME_LIVE 와 같은 모양).
//
//   ⚠ 닫을 곳이 **세 곳**이다. 하나라도 열려 있으면 닫은 것이 아니다.
//     ① 마이페이지 「나의 추천권」 카드 — 발급이 여기서 시작된다
//     ② 슈퍼어드민 설정의 추천권 두 줄 — 닫아 둔 기능의 설정값
//     ③ /ref/ 초대장 — **이미 보낸 링크로 들어오는 길**.
//        ①만 막으면 새로 못 만들 뿐, 나간 링크는 그대로 살아 있다.
//
//   ① 카드가 안 뜬다 ⭐  ② 눌러도 발급 안 된다 ⭐
//   ③ 설정 두 줄이 없다 ⭐ (나머지 줄은 그대로)
//   ④ 플래그를 켜면 되돌아온다 ⭐ — 지운 것이 아니라 숨긴 것
//   ⑤ /ref/ 가 「준비 중」으로 멈춘다 ⭐ 세 언어 모두
//   ⑥ 서버를 부르기 **전에** 멈춘다 ⭐ taam_ref_public 은 「열어봄」을 기록한다
//
// 실행: node sql/_test/refhideshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const fs = require('fs');

(async () => {
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  // ── ⑥ 정적 — 부르기 전에 멈추는가 ────────────────────────────
  const ref = fs.readFileSync('/home/user/taam-app/ref/index.html', 'utf8');
  ok('/ref/ 에 스위치가 있다', /var REF_LIVE = false;/.test(ref));
  const iStop = ref.indexOf("if(!REF_LIVE)");
  const iRpc  = ref.indexOf("rpc('taam_ref_public'");
  ok('서버를 부르기 전에 멈춘다 ⭐ (열어봄이 기록되면 안 된다)', iStop > 0 && iRpc > iStop);
  ['ko', 'en', 'ja'].forEach((L, i) => {
    // 세 언어 블록 각각에 안내문이 있는지 — 순서대로 나타난다
    const n = (ref.match(/soon_t:/g) || []).length;
    if (i === 0) ok('세 언어에 안내문이 있다 ⭐ (' + n + '개)', n === 3);
  });

  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  await p.route('**://fonts.g**', r => r.abort());

  // ── ⑤ /ref/ 초대장 ──────────────────────────────────────────
  for (const [lang, want] of [['ko', '준비'], ['en', 'Not open'], ['ja', '準備']]) {
    await p.goto('file:///home/user/taam-app/ref/index.html?c=ABCD1234&lang=' + lang,
                 { waitUntil: 'domcontentloaded' });
    await p.waitForTimeout(400);
    const t = await p.evaluate(() => document.getElementById('wrap').textContent);
    ok('/ref/ ' + lang + ' — 「준비 중」으로 멈춘다 ⭐', t.indexOf(want) >= 0);
    // 코드도, 「심사 신청하기」 버튼도 보이면 안 된다
    ok('/ref/ ' + lang + ' — 코드를 안 보여준다', t.indexOf('ABCD1234') < 0);
    ok('/ref/ ' + lang + ' — 신청 버튼이 없다 ⭐',
       await p.evaluate(() => !document.querySelector('.go')));
  }

  // ── 앱 쪽 ───────────────────────────────────────────────────
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const res = [];
    const ok = (n, c) => res.push((c ? 'OK   ' : 'FAIL ') + n);
    const wait = ms => new Promise(r => setTimeout(r, ms));
    window._currentRole = 'superadmin';
    document.getElementById('appWrapper').classList.add('ready');

    ok('스위치가 꺼져 있다 ⭐', window.REFERRAL_LIVE === false && !referralEnabled());

    // ── ① 카드 ──────────────────────────────────────────────
    // ⚠ 서버가 추천권을 **가지고 있어도** 안 그려야 한다. 「데이터가 없어서
    //   안 보이는 것」과 「닫아서 안 보이는 것」은 다르다.
    let asked = 0;
    window.sb = { rpc: (fn) => { asked++; return Promise.resolve({ data:
      { left: 2, max: 2, items: [{ code:'ABCD1234', status:'sent' }] }, error: null }); } };
    const card = document.getElementById('mpRefCard');
    await _mpPaintRef('M'); await wait(150);
    ok('M 회원에게도 카드가 안 뜬다 ⭐', getComputedStyle(card).display === 'none');
    ok('카드가 비어 있다', card.innerHTML === '');
    ok('서버에 묻지도 않는다 ⭐ (' + asked + '회)', asked === 0);

    // ── ② 발급 ──────────────────────────────────────────────
    await mpRefIssue(); await wait(150);
    ok('발급을 불러도 서버를 안 부른다 ⭐', asked === 0);

    // ── ③ 설정 두 줄 ────────────────────────────────────────
    window._msa = { tab:'cfg', cfg:{ deposit_amount:9000000, annual_fee_cash:1150000,
      annual_fee_card:1270000, guest_days:90, offer_days:14,
      referral_days:60, referral_per_year:2, corp_slots:5 } };
    _msaRenderCfg(null); await wait(120);
    const cfg = document.getElementById('msaBody');
    ok('설정에 「추천권 유효」가 없다 ⭐', cfg.textContent.indexOf('추천권 유효') < 0);
    ok('설정에 「추천권 연 매수」가 없다 ⭐', cfg.textContent.indexOf('추천권 연 매수') < 0);
    ok('다른 설정은 그대로 ⭐ (오퍼 유효)', cfg.textContent.indexOf('오퍼 유효') >= 0);
    ok('저장 대상에서도 빠진다 ⭐',
       !cfg.querySelector('[data-k="referral_days"]') && !cfg.querySelector('[data-k="referral_per_year"]'));

    // ── ④ 켜면 되돌아온다 ⭐ 지운 것이 아니다 ────────────────
    window.REFERRAL_LIVE = true;
    _msaRenderCfg(null); await wait(120);
    ok('켜면 설정 두 줄이 돌아온다 ⭐', cfg.textContent.indexOf('추천권 유효') >= 0
       && cfg.textContent.indexOf('추천권 연 매수') >= 0);
    await _mpPaintRef('M'); await wait(200);
    ok('켜면 카드도 돌아온다 ⭐', getComputedStyle(card).display !== 'none'
       && card.textContent.indexOf('나의 추천권') >= 0);
    ok('그때는 서버에 묻는다', asked > 0);
    window.REFERRAL_LIVE = false;

    // ── 게스트·일반 회원에게는 원래도 안 보인다 (규칙이 안 바뀌었다) ──
    window.REFERRAL_LIVE = true;
    await _mpPaintRef('A'); await wait(120);
    ok('게스트(A)에게는 켜도 안 보인다 ⭐', getComputedStyle(card).display === 'none');
    window.REFERRAL_LIVE = false;
    return res;
  });

  [...out, ...r].forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = [...out, ...r].filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===`
                          : `=== 전부 통과 (${out.length + r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
