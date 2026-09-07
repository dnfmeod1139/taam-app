// ═══════════════════════════════════════════════════════════════
// 부팅 — 검은 화면에 갇히지 않는다 (2026-09-06)
// ═══════════════════════════════════════════════════════════════
//   안드로이드에서 앱을 켜면 **까만 화면만** 나왔다. 오류도, 로그인 화면도,
//   빠져나갈 길도 없었다.
//
//   원인: Supabase SDK 의 CDN(unpkg)이 막히면
//     unpkg 실패 → 폴백(jsdelivr) 성공 → location.reload()
//     → 새로고침하면 다시 unpkg 부터 → 실패 → 폴백 → 새로고침 → …
//   이 고리가 끝없이 돈다. 실측 **14초에 44번**. 매번 부팅 첫 화면(검정)으로
//   되돌아가므로 회원 눈에는 그냥 까만 화면이다. 오류가 뜰 만큼 오래 살아
//   있질 못한다.
//
//   ⚠ 서비스워커 버전을 올린 직후가 특히 위험하다. activate 가 옛 캐시를
//     전부 지워서 SDK 를 네트워크에서 새로 받아야 한다 — 그 실행에 CDN 이
//     막혀 있으면 바로 이 고리에 빠진다.
//
//   ① CDN 이 막혀도 새로고침은 **한 번뿐** ⭐ (고리가 안 생긴다)
//   ② 그래도 화면은 뜬다 ⭐ 부팅 감시견이 8초에 로그인 화면으로 내린다
//   ③ 두 CDN 다 막히면 「연결에 실패했습니다」를 보여준다 (검정이 아니라)
//   ④ 정상일 때는 감시견이 끼어들지 않는다 ⭐ 이게 제일 중요하다
//
// 실행: node sql/_test/bootshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

// 폴백 CDN 이 내려주는 척하는 최소 SDK
const FAKE_SDK = `window.supabase={createClient:function(){return {
  from:function(){return {select:function(){return Promise.resolve({data:[],error:null});}};},
  auth:{getUser:function(){return Promise.resolve({data:{user:null}});},
        getSession:function(){return Promise.resolve({data:{session:null}});},
        onAuthStateChange:function(){return {data:{subscription:{unsubscribe:function(){}}}};}},
  channel:function(){return {on:function(){return this;},subscribe:function(){return this;}};},
  removeChannel:function(){},rpc:function(){return Promise.resolve({data:null,error:null});} };}};`;

const URL = 'file:///home/user/taam-app/index.html';

async function run(browser, opts) {
  const p = await browser.newPage({ viewport: { width: 390, height: 844 } });
  let navs = 0;
  p.on('framenavigated', f => { if (f === p.mainFrame()) navs++; });
  await p.route('**://fonts.g**', r => r.abort());
  // ⚠ 이 검증 환경은 바깥 CDN 이 통째로 막혀 있다. 「정상」을 재려면 주 CDN 이
  //   **되는** 상황을 직접 만들어 줘야 한다 — 안 그러면 정상 케이스도 폴백을
  //   타서, 멀쩡한 코드가 실패로 나온다(처음에 그렇게 재서 한 건이 틀렸다).
  if (opts.blockPrimary)  await p.route('**unpkg.com**', r => r.abort());
  else await p.route('**unpkg.com**', r =>
    r.fulfill({ status: 200, contentType: 'application/javascript', body: FAKE_SDK }));
  if (opts.blockFallback) await p.route('**cdn.jsdelivr.net**', r => r.abort());
  else await p.route('**cdn.jsdelivr.net**', r =>
    r.fulfill({ status: 200, contentType: 'application/javascript', body: FAKE_SDK }));
  await p.goto(URL, { waitUntil: 'domcontentloaded' });
  // 자동 로그인 상태 — 갇히는 것은 이 경로다 (codeScreen 이 !important 로 숨는다)
  if (opts.autoLogin) await p.evaluate(() => document.documentElement.classList.add('auto-login'));
  await p.waitForTimeout(opts.wait);
  const st = await p.evaluate(() => {
    const cs = e => { try { return e ? getComputedStyle(e).display : '(없음)'; } catch (x) { return '?'; } };
    return {
      ready: document.getElementById('appWrapper').classList.contains('ready'),
      wrapper: cs(document.getElementById('appWrapper')),
      code: cs(document.getElementById('codeScreen')),
      notice: (document.body.textContent || '').indexOf('연결에 실패했습니다') >= 0
    };
  });
  st.navs = navs;
  await p.close();
  return st;
}

(async () => {
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });

  // ── ①② 막힌 CDN + 살아 있는 폴백 = 고리가 생기던 자리 ──────
  const loop = await run(b, { blockPrimary: true, autoLogin: true, wait: 14000 });
  ok('새로고침이 한 번을 넘지 않는다 ⭐ (' + loop.navs + '회)', loop.navs <= 2);
  ok('그래도 화면이 뜬다 ⭐', loop.ready === true);
  ok('로그인 화면으로 내려준다 ⭐', loop.code !== 'none');

  // ── ③ 둘 다 막히면 ─────────────────────────────────────────
  const dead = await run(b, { blockPrimary: true, blockFallback: true, autoLogin: true, wait: 12000 });
  ok('두 CDN 다 막히면 안내를 보여준다 ⭐', dead.notice === true);
  ok('그때도 까만 화면은 아니다 ⭐', dead.ready === true || dead.notice === true);
  ok('그때도 새로고침을 반복하지 않는다 (' + dead.navs + '회)', dead.navs <= 2);

  // ── ④ 정상일 때 감시견이 끼어들지 않는다 ⭐ ──────────────────
  //   ⚠ 이게 제일 중요하다. 감시견이 멀쩡한 부팅을 로그인 화면으로 끌어내리면
  //     고치려던 것보다 나쁜 고장이 된다. auto-login 을 안 걸면 정상 경로다.
  const normal = await run(b, { autoLogin: false, wait: 3000 });
  ok('정상 부팅에서는 3초 안에 새로고침이 없다 ⭐ (' + normal.navs + '회)', normal.navs === 1);

  out.forEach(l => console.log(l));
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
