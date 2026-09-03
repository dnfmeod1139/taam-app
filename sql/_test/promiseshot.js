// ═══════════════════════════════════════════════════════════════
// 파트너 제안 「우리의 약속」 — 3개 언어 검증
//   일본 매장 안내문(taam_goannai_ja.pdf)을 그대로 옮겼는지,
//   한국어·영어에 빠진 항목이 없는지 본다.
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 430, height: 1200 } });
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.route('**://fonts.g**', r => r.abort());
  // ⚠ 서버를 안 부른다 — 실패하면 render(generic) 로 떨어지는 경로를 쓴다
  await p.route('**/rest/v1/**', r => r.abort());
  await p.goto('file:///home/user/taam-app/partner/index.html?g=1', { waitUntil: 'commit' });
  await p.waitForTimeout(1500);

  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  for (const [lang, want] of [
    ['ja', { head:'予約サイトでは、ありません。', one:'客は、全員審査済み。',
             foot:'信頼できるお客様だけ', five:'窓口は、Woo 一人。' }],
    ['ko', { head:'예약 사이트가 아닙니다.', one:'손님은 전원 심사를 거칩니다.',
             foot:'한국의 파트너이고 싶습니다', five:'창구는 Woo 한 사람.' }],
    ['en', { head:'We are not a booking site.', one:'Every guest is screened.',
             foot:'partner in Korea', five:'One point of contact' }]
  ]) {
    await p.evaluate(l => window.pvSetLang(l), lang);
    await p.waitForTimeout(200);
    const g = await p.evaluate(() => ({
      head: document.getElementById('promiseTitle').textContent,
      lead: document.getElementById('promiseLead').textContent,
      items: [...document.querySelectorAll('#promiseList li')].map(li => ({
        no: li.querySelector('.no').textContent,
        t: li.querySelector('.t').textContent,
        d: li.querySelector('.d').textContent })),
      foot: document.getElementById('promiseFoot').textContent,
      footColor: getComputedStyle(document.getElementById('promiseFoot')).color
    }));
    ok(lang + ' — 제목', g.head === want.head);
    ok(lang + ' — 다섯 줄 ⭐', g.items.length === 5);
    ok(lang + ' — 첫째', g.items[0] && g.items[0].t === want.one);
    ok(lang + ' — 다섯째', g.items[4] && g.items[4].t.indexOf(want.five) >= 0);
    ok(lang + ' — 맺음말', g.foot.indexOf(want.foot) >= 0);
    // ⚠ 번호는 세로쓰기 한자 그대로 — 언어가 바뀌어도 유지된다
    ok(lang + ' — 번호가 壱〜伍', g.items.map(x=>x.no).join('') === '壱弐参肆伍');
    // 빈 칸이 하나라도 있으면 번역 누락이다
    ok(lang + ' — 빈 항목 없음 ⭐',
       g.lead.trim() && g.items.every(x => x.t.trim() && x.d.trim()) && g.foot.trim());
    // 다른 언어가 새어 나오지 않는가 (ko/en 화면에 일본어 가나)
    const all = g.head + g.lead + g.items.map(x=>x.t+x.d).join('') + g.foot;
    if (lang !== 'ja') ok(lang + ' — 일본어가 안 섞인다 ⭐', !/[ぁ-んァ-ヶ]/.test(all));
    if (lang === 'en') ok('en — 한글이 안 섞인다 ⭐', !/[가-힣]/.test(all));
    if (lang === 'ko') ok('ko — 한글로 적혔다', /[가-힣]/.test(all));
  }
  // 소개 바로 다음에 온다 (안내문의 흐름)
  const order = await p.evaluate(() => {
    const ids = [...document.querySelectorAll('section')].map(s =>
      (s.querySelector('h2') || {}).id || '');
    return { a: ids.indexOf('aboutTitle'), p: ids.indexOf('promiseTitle'), m: ids.indexOf('memTitle') };
  });
  ok('소개 → 약속 → 회원 순서 ⭐', order.a >= 0 && order.p === order.a + 1 && order.m === order.p + 1);

  out.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0,3).forEach(e => console.log('  ' + e)); }
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
