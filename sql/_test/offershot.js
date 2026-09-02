// ═══════════════════════════════════════════════════════════════
// 오퍼 페이지 — 화면 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
// 여기가 **가격이 처음 공개되는 곳**이다. 그래서 보는 것도 그쪽에 맞춘다.
//   ① 서버가 준 **박제된 금액**만 그리는가 (앱이 다시 계산하지 않는가)
//   ② 결제 수단을 바꾸면 총액이 따라가는가
//   ③ 만료·취소·완료 링크가 각각 다른 말을 하는가
//   ④ KO·EN·JA 가 다 나오는가
//   ⑤ [시작하기] 가 **결제하지 않는가** — 「하겠다」만 남긴다
//   ⑥ 전화번호가 화면에 없는가
//
// 실행: node sql/_test/offershot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const URL = 'file:///home/user/taam-app/offer/index.html';

const OK = {
  found: true, blocked: null, surname: '김', status: 'opened',
  expires_at: new Date(Date.now() + 7 * 86400000).toISOString(),
  deposit_amount: 10125000, annual_fee_cash: 1125000, annual_fee_card: 1270000,
  seats_left: 5
};

// ⚠ 화면 글자만 읽는다. body 를 읽으면 <script> 소스(한국어 주석)까지 딸려 와서
//   「영어 화면에 한국어가 섞였다」는 가짜 실패가 난다.
// ⚠ 이 환경의 navigator.language 는 영어다 — 한국어 검사에는 lang=ko 를 붙인다.
async function open(page, reply, q = '') {
  const calls = [];
  // ⚠ 폰트를 막지 않으면 goto 가 domcontentloaded 에서 안 끝난다 —
  //   이 환경은 fonts.googleapis.com 을 못 나간다. 검사가 통째로 멈춘다.
  await page.route('**://fonts.googleapis.com/**', r => r.abort());
  await page.route('**://fonts.gstatic.com/**', r => r.abort());
  await page.route('**/rest/v1/rpc/**', async route => {
    const fn = route.request().url().split('/').pop();
    let body = {};
    try { body = JSON.parse(route.request().postData() || '{}'); } catch (e) {}
    calls.push([fn, body]);
    const r = typeof reply === 'function' ? reply(fn, body) : reply;
    if (r && r.__fail) return route.fulfill({ status: 400, contentType: 'application/json',
      body: JSON.stringify({ message: 'boom' }) });
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(r) });
  });
  page.setDefaultTimeout(5000);   // 없는 요소를 30초씩 기다리면 검사가 통째로 멈춘다
  await page.goto(URL + '?t=' + 'a'.repeat(32) + (q || '&lang=ko'), { waitUntil: 'commit' });
  await page.waitForTimeout(700);
  return calls;
}

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const errs = [];

  // ── ① 기본 ────────────────────────────────────────────────
  let p = await b.newPage();
  p.on('pageerror', e => errs.push(String(e)));
  let calls = await open(p, (fn) => fn === 'taam_mship_offer_public' ? OK : { ok: true });
  let txt = await p.textContent('#wrap');
  ok('토큰으로 서버에 묻는다',
     calls.some(c => c[0] === 'taam_mship_offer_public' && c[1].p_token === 'a'.repeat(32)));
  ok('심사 결과라고 말한다', txt.indexOf('심사 결과') >= 0);
  ok('성으로 부른다',        txt.indexOf('김○') >= 0);
  ok('잔여석을 적는다',      txt.indexOf('잔여 5석') >= 0);
  // ⚠ 금액은 서버가 준 것만. 앱이 다시 계산하면 서버와 어긋난다.
  ok('이체 총액 (10,125,000 + 1,125,000)', txt.indexOf('₩11,250,000') >= 0);
  ok('카드 총액도 같이 보인다',            txt.indexOf('₩11,395,000') >= 0);
  ok('예치금을 금액으로 적는다',           txt.indexOf('₩10,125,000') >= 0);
  ok('퍼센트 문구가 없다 ⭐', !/9\s*0\s*%|1\s*0\s*%/.test(txt));
  ok('사용 기한이 없다고 말한다', txt.indexOf('사용 기한은 없습니다') >= 0);
  ok('12월 28일을 말한다',        txt.indexOf('12월 28일') >= 0);
  ok('전액 환불을 말한다',        txt.indexOf('전액 환불') >= 0);
  ok('만료일을 적는다', /유효합니다/.test(txt));
  // ⑥ 전화번호는 서버가 안 주고 화면에도 없다
  ok('전화번호가 화면에 없다 ⭐', !/01[016789]-?\d{3,4}-?\d{4}/.test(txt));

  // 레스토랑 — 상호명만, 기본은 접혀 있다
  ok('장르가 넷', (await p.$$('.acc .hd')).length === 4);
  ok('기본은 접혀 있다', (await p.$$('.acc .bd:not([hidden])')).length === 0);
  ok('개수를 미리 보여준다', txt.indexOf('19곳') >= 0 && txt.indexOf('7곳') >= 0);
  await p.click('.acc .hd');
  await p.waitForTimeout(120);
  txt = await p.textContent('#wrap');
  ok('누르면 열린다', txt.indexOf('스시 슌지') >= 0);
  ok('점수·가격은 안 나온다 ⭐', !/점|★|\d+\.\d\s*점/.test(txt.split('스시 슌지')[1] || ''));

  // ── ② 결제 수단 ───────────────────────────────────────────
  ok('기본은 이체', (await p.textContent('.seg button.on')).indexOf('계좌이체') >= 0);
  await p.click('.seg button:nth-child(2)');
  await p.waitForTimeout(150);
  ok('카드를 고르면 카드 총액이 커진다',
     (await p.textContent('.price .amt')) === '₩11,395,000');
  ok('다른 쪽 금액도 계속 보인다',
     (await p.textContent('.price .amt2')).indexOf('11,250,000') >= 0);

  // ── ⑤ 시작하기는 결제하지 않는다 ──────────────────────────
  calls.length = 0;
  await p.click('#go');
  await p.waitForTimeout(400);
  const acc = calls.filter(c => c[0] === 'taam_mship_offer_accept');
  ok('accept 만 부른다 ⭐', acc.length === 1 && acc[0][1].p_method === 'card');
  ok('결제창을 열지 않는다 ⭐',
     !calls.some(c => /toss|payment|confirm/i.test(c[0])));
  txt = await p.textContent('#wrap');
  ok('접수됐다고 말한다', txt.indexOf('접수되었습니다') >= 0);
  ok('담당자가 잇는다고 말한다', txt.indexOf('결제 안내') >= 0);
  await p.close();

  // ── ③ 막힌 링크들 ─────────────────────────────────────────
  const cases = [
    ['만료',   { found:true, blocked:'expired' },   '안내 기간이 종료'],
    ['취소',   { found:true, blocked:'cancelled' }, '종료된 안내'],
    ['완료',   { found:true, blocked:'paid' },      '이미 완료'],
    ['없는 링크', { found:false },                  '찾을 수 없습니다']
  ];
  for (const [name, reply, want] of cases) {
    p = await b.newPage();
    p.on('pageerror', e => errs.push(String(e)));
    await open(p, reply);
    const t2 = await p.textContent('#wrap');
    ok(name + ' 은 그렇게 말한다', t2.indexOf(want) >= 0);
    ok(name + ' 이면 금액을 안 보여준다 ⭐', t2.indexOf('11,250,000') < 0);
    await p.close();
  }

  // 이미 「하겠다」를 누른 사람
  p = await b.newPage();
  await open(p, Object.assign({}, OK, { status: 'accepted' }));
  ok('이미 누른 사람에게 같은 화면을 또 안 보여준다',
     (await p.textContent('#wrap')).indexOf('접수되었습니다') >= 0);
  await p.close();

  // 서버가 죽으면
  p = await b.newPage();
  await open(p, { __fail: true });
  ok('서버가 죽으면 조용히 안내한다',
     (await p.textContent('#wrap')).indexOf('잠시 문제가') >= 0);
  await p.close();

  // ── ④ 3개 국어 ────────────────────────────────────────────
  for (const [L, want] of [['en','we are able to invite'], ['ja','ご案内を差し上げます']]) {
    p = await b.newPage();
    p.on('pageerror', e => errs.push(String(e)));
    await open(p, (fn) => fn === 'taam_mship_offer_public' ? OK : { ok:true }, '&lang=' + L);
    const t3 = await p.textContent('#wrap');
    ok(L + ' — 본문이 그 언어다', t3.indexOf(want) >= 0);
    ok(L + ' — 금액은 그대로', t3.indexOf('11,250,000') >= 0);
    ok(L + ' — 한국어가 섞이지 않는다 ⭐', t3.indexOf('심사 결과 안내') < 0);
    await p.close();
  }
  // 언어 버튼으로도 바뀐다
  p = await b.newPage();
  await open(p, (fn) => fn === 'taam_mship_offer_public' ? OK : { ok:true });
  await p.click('.langs button:nth-child(3)');
  await p.waitForTimeout(200);
  ok('언어 버튼으로 일본어가 된다',
     (await p.textContent('#wrap')).indexOf('審査結果') >= 0);
  await p.close();

  out.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
