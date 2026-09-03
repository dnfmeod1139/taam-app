// ═══════════════════════════════════════════════════════════════
// 레스토랑 등록 — 주소 자동완성이 왜 안 되는지 말하는가 (2026-09-03)
// ═══════════════════════════════════════════════════════════════
//   「구글맵 로딩중이라고 뜨고 잡히지 않는다」
//   실패해도 화면에는 「로드 중」만 남았다. 스크립트가 막혔든, 키가
//   거부됐든, Places API (New) 가 안 켜져 있든 전부 같은 화면이라
//   영영 기다리게 된다. 셋은 고치는 방법이 서로 다르다.
//
//   ① 스크립트가 아예 안 열릴 때
//   ② ⭐ **매달려 있을 때** — onerror 도 안 온다. 실제 증상이 이것이었다
//   ③ 키가 거부될 때 (gm_authFailure)
//   ④ 내려왔는데 Places API (New) 가 없을 때
//   ⑤ 이유를 알고 나면 다시 기다리라고 하지 않는가
//   ⑥ 주소는 직접 입력해도 된다고 알려주는가
//
// 실행: node sql/_test/mapshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

async function fresh(b, route) {
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  await p.route('**://fonts.g**', r => r.abort());
  if (route) await p.route('**maps.googleapis.com**', route);
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2200);
  await p.evaluate(() => document.getElementById('appWrapper').classList.add('ready'));
  return p;
}
const dd = p => p.evaluate(() => {
  const d = document.getElementById('rpAddrDropdown');
  return d ? d.textContent.trim() : '';
});

(async () => {
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });

  // ── ① 스크립트가 아예 안 열릴 때 ───────────────────────────
  let p = await fresh(b, r => r.abort());
  await p.evaluate(() => window.rpAddrInput('스시'));
  await p.waitForTimeout(1200);
  let t = await dd(p);
  ok('못 불러오면 그렇게 말한다 ⭐', t.indexOf('못 불러왔습니다') >= 0);
  ok('무엇을 볼지 알려준다', /네트워크|광고차단/.test(t));
  ok('주소는 직접 입력해도 된다고 한다 ⭐', t.indexOf('직접 입력') >= 0);
  await p.close();

  // ── ② 매달려 있을 때 ⭐ 실제 증상 ──────────────────────────
  //   ⚠ 요청이 끝나지 않으면 onerror 가 **안 온다.** 시한이 없으면
  //     「불러오는 중」이 영영 남는다 — 이게 신고된 화면이었다.
  p = await fresh(b, () => {});   // 응답도 실패도 주지 않는다
  await p.evaluate(() => window.rpAddrInput('스시'));
  await p.waitForTimeout(800);
  t = await dd(p);
  ok('처음에는 불러오는 중이라고 한다', t.indexOf('불러오는 중') >= 0);
  await p.waitForTimeout(10500);
  t = await dd(p);
  ok('시한이 지나면 멈춘다 ⭐', t.indexOf('응답하지 않습니다') >= 0);
  ok('영영 「불러오는 중」에 안 남는다 ⭐', t.indexOf('불러오는 중') < 0);
  // 이유를 알고 나면 다시 기다리라고 하지 않는다
  await p.evaluate(() => window.rpAddrInput('스시집'));
  await p.waitForTimeout(600);
  t = await dd(p);
  ok('다시 쳐도 기다리라 안 한다 ⭐', t.indexOf('불러오는 중') < 0);
  await p.close();

  // ── ③ 키가 거부될 때 ───────────────────────────────────────
  p = await fresh(b, () => {});
  await p.evaluate(() => window.rpAddrInput('스시'));
  await p.waitForTimeout(500);
  // Google 은 키 문제를 이 함수로만 알려준다
  await p.evaluate(() => window.gm_authFailure());
  await p.waitForTimeout(200);
  t = await dd(p);
  ok('키가 거부되면 그렇게 말한다 ⭐', t.indexOf('키가 거부') >= 0);
  ok('무엇을 확인할지 알려준다', /키 제한|결제/.test(t));
  await p.close();

  // ── ④ 내려왔는데 Places API (New) 가 없을 때 ───────────────
  //   구버전 Places 만 켜져 있으면 google.maps.places 는 있는데
  //   AutocompleteSuggestion 이 없다. 「로드됐는데 안 잡히는」 상태다.
  p = await fresh(b, r => r.fulfill({ status: 200,
    contentType: 'application/javascript',
    body: 'window.google={maps:{places:{},importLibrary:function(){return Promise.resolve();}}};' }));
  await p.evaluate(() => window.rpAddrInput('스시'));
  await p.waitForTimeout(1500);
  t = await dd(p);
  ok('구버전이면 그렇게 말한다 ⭐', t.indexOf('Places API (New)') >= 0);
  ok('어디서 켜는지 알려준다', t.indexOf('Google Cloud') >= 0);
  await p.close();

  // ── ⑤ 정상일 때는 검색이 이어진다 ⭐ ───────────────────────
  //   로드가 끝나면 사용자가 **다시 타이핑하지 않아도** 이어서 찾는다.
  p = await fresh(b, r => r.fulfill({ status: 200,
    contentType: 'application/javascript',
    body: `window.__asked=[];
      function Sug(){}
      Sug.fetchAutocompleteSuggestions=function(o){ window.__asked.push(o.input);
        return Promise.resolve({suggestions:[{placePrediction:{
          mainText:'스시 아라이', secondaryText:'東京', text:'스시 아라이, 東京',
          toPlace:function(){return{fetchFields:function(){return Promise.resolve();}};} }}]}); };
      window.google={maps:{importLibrary:function(){return Promise.resolve();},
        places:{AutocompleteSuggestion:Sug, AutocompleteSessionToken:function(){}}}};` }));
  await p.evaluate(() => window.rpAddrInput('스시'));
  await p.waitForTimeout(1800);
  t = await dd(p);
  const asked = await p.evaluate(() => window.__asked || []);
  ok('로드 뒤 알아서 이어 검색한다 ⭐', asked.indexOf('스시') >= 0);
  ok('결과가 뜬다 ⭐', t.indexOf('스시 아라이') >= 0);
  ok('기다리라는 문구는 사라진다', t.indexOf('불러오는 중') < 0);
  await p.close();

  out.forEach(l => console.log(l));
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
