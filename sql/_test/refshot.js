// ═══════════════════════════════════════════════════════════════
// 초대장(ref/) · 공개 심사 신청(apply/) — 화면 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
//   ① 초대장에 **가격이 없는가** ← 추천은 심사 기회이지 가입이 아니다
//   ② 「가입 보장이 아니다」를 적는가
//   ③ 추천인의 **성만** 나오는가
//   ④ 신청 페이지에도 가격이 없는가
//   ⑤ 추천 코드가 자동으로 붙는가 (다시 적게 하지 않는다)
//   ⑥ 안 채우면 못 보내는가 / 서버에 무엇을 넘기는가
//   ⑦ KO·EN·JA
//
// 실행: node sql/_test/refshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const REF_URL = 'file:///home/user/taam-app/ref/index.html';
const APP_URL = 'file:///home/user/taam-app/apply/index.html';

async function mk(b, reply) {
  const p = await b.newPage({ viewport: { width: 390, height: 1000 } });
  const calls = [];
  await p.route('**://fonts.g**', r => r.abort());
  await p.route('**/rest/v1/rpc/**', async route => {
    const fn = route.request().url().split('/').pop();
    let body = {}; try { body = JSON.parse(route.request().postData() || '{}'); } catch (e) {}
    calls.push([fn, body]);
    const r = typeof reply === 'function' ? reply(fn, body) : reply;
    if (r && r.__fail) return route.fulfill({ status: 400, contentType: 'application/json',
      body: JSON.stringify({ message: 'boom' }) });
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(r) });
  });
  p.setDefaultTimeout(6000);
  return { p, calls };
}
const PRICES = /11,250,000|11,395,000|10,125,000|1,125,000|1,270,000/;

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const errs = [];
  const REF_OK = { found:true, blocked:null, code:'TAAM-2026-AB12', surname:'김',
    expires_at: new Date(Date.now() + 14*86400000).toISOString() };

  // ── ① 초대장 ──────────────────────────────────────────────
  let { p, calls } = await mk(b, REF_OK);
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto(REF_URL + '?c=TAAM-2026-AB12&lang=ko', { waitUntil: 'commit' });
  await p.waitForTimeout(700);
  let txt = await p.textContent('#wrap');
  ok('코드로 서버에 묻는다',
     calls.some(c => c[0] === 'taam_ref_public' && c[1].p_code === 'TAAM-2026-AB12'));
  ok('추천인의 성으로 부른다', txt.indexOf('김○님의 추천') >= 0);
  ok('전체 이름이 안 나온다 ⭐', txt.indexOf('김추천') < 0);
  ok('코드를 보여준다', txt.indexOf('TAAM-2026-AB12') >= 0);
  ok('가격이 한 글자도 없다 ⭐', !PRICES.test(txt));
  ok('가입 보장이 아니라고 적는다 ⭐', txt.indexOf('보장하지 않습니다') >= 0);
  ok('유효기간을 적는다', /유효기간/.test(txt));
  ok('심사 신청으로 가는 버튼', (await p.textContent('.go')).indexOf('심사 신청') >= 0);
  await p.close();

  // 막힌 초대장
  for (const [name, reply, want] of [
    ['만료', { found:true, blocked:'expired' },  '기간이 지났습니다'],
    ['사용됨', { found:true, blocked:'applied' }, '이미 사용된'],
    ['없음', { found:false },                    '찾을 수 없습니다']
  ]) {
    const m = await mk(b, reply);
    await m.p.goto(REF_URL + '?c=X&lang=ko', { waitUntil: 'commit' });
    await m.p.waitForTimeout(500);
    const t2 = await m.p.textContent('#wrap');
    ok('초대장 — ' + name, t2.indexOf(want) >= 0);
    ok('초대장 — ' + name + ' 에도 가격 없음', !PRICES.test(t2));
    await m.p.close();
  }

  // 초대장 3개 국어
  for (const [L, want] of [['en','You have been referred'], ['ja','ご推薦いただきました']]) {
    const m = await mk(b, REF_OK);
    await m.p.goto(REF_URL + '?c=TAAM-2026-AB12&lang=' + L, { waitUntil: 'commit' });
    await m.p.waitForTimeout(600);
    const t3 = await m.p.textContent('#wrap');
    ok('초대장 ' + L, t3.indexOf(want) >= 0);
    ok('초대장 ' + L + ' — 가입 보장이 아니라고 적는다',
       /does not guarantee|お約束するものではございません/.test(t3));
    await m.p.close();
  }

  // ── ② 공개 심사 신청 ──────────────────────────────────────
  ({ p, calls } = await mk(b, { ok:true, already:false, id:'x' }));
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto(APP_URL + '?ref=TAAM-2026-AB12&lang=ko', { waitUntil: 'commit' });
  await p.waitForTimeout(600);
  txt = await p.textContent('#wrap');
  ok('신청 화면이 뜬다', txt.indexOf('멤버십 심사 신청') >= 0);
  ok('가격이 한 글자도 없다 ⭐', !PRICES.test(txt));
  ok('정원 33인을 말한다', txt.indexOf('33') >= 0);
  ok('추천 코드가 자동으로 붙는다 ⭐', txt.indexOf('TAAM-2026-AB12') >= 0);
  ok('코드를 다시 적게 하지 않는다 ⭐',
     (await p.$$('input')).length === 3);   // 이름 · 연령대·직업 · 연락처
  ok('질문 다섯 개 + 이름 + 연락처', (await p.$$('.f')).length === 7);

  // 안 채우고 보내기
  calls.length = 0;
  await p.click('#go');
  await p.waitForTimeout(300);
  ok('빈 채로는 서버를 안 부른다 ⭐', !calls.some(c => c[0] === 'taam_mship_apply'));
  ok('무엇이 비었는지 알려준다', (await p.$('.err')) !== null);

  // 채워서 보내기
  await p.fill('#nm', '이서연');
  await p.fill('#ph', '010-4444-5555');
  // ⚠ .f:nth-of-type 은 클래스가 아니라 **태그** 기준이라 엉뚱한 div 를 짚는다.
  //   질문 칸을 순서대로 잡아 첫 선택지를 누른다.
  const pickFirst = async (page, idx) => {
    const fs = await page.$$('.f');
    const o = await fs[idx].$('.opt');
    if (o) await o.click();
    await page.waitForTimeout(100);
  };
  await pickFirst(p, 1); await pickFirst(p, 2); await pickFirst(p, 3);
  ok('고른 답이 다시 그려도 남는다', (await p.$$('.opt.on')).length === 3);
  ok('이름도 남는다', (await p.inputValue('#nm')) === '이서연');
  await p.fill('#q_who', '30대 · 의사');
  await p.fill('#q_places', '스기타 / 사이토 / 아라이');
  calls.length = 0;
  await p.click('#go');
  await p.waitForTimeout(500);
  const call = calls.filter(c => c[0] === 'taam_mship_apply')[0];
  ok('서버에 신청을 넘긴다', !!call);
  ok('이름·연락처를 넘긴다',
     call && call[1].p_name === '이서연' && call[1].p_phone === '010-4444-5555');
  ok('추천 코드를 함께 넘긴다 ⭐', call && call[1].p_referral === 'TAAM-2026-AB12');
  ok('출처가 web', call && call[1].p_source === 'web');
  ok('그때의 질문을 함께 넘긴다 ⭐',
     call && call[1].p_answers.visits.q.indexOf('일본 방문') >= 0
          && call[1].p_answers.visits.label.indexOf('3회') >= 0);
  ok('직접 쓴 답도 넘긴다', call && call[1].p_answers.places.v.indexOf('스기타') >= 0);
  ok('접수됐다고 말한다', (await p.textContent('#wrap')).indexOf('접수되었습니다') >= 0);
  await p.close();

  // 추천 없이 들어온 경우
  ({ p, calls } = await mk(b, { ok:true }));
  await p.goto(APP_URL + '?lang=ko', { waitUntil: 'commit' });
  await p.waitForTimeout(500);
  ok('추천 없이도 열린다', (await p.textContent('#wrap')).indexOf('멤버십 심사 신청') >= 0);
  ok('추천 줄이 없다', (await p.$('.ref')) === null);
  await p.close();

  // 서버가 죽으면 — 적은 것이 안 날아가야 한다
  ({ p, calls } = await mk(b, (fn) => ({ __fail: true })));
  await p.goto(APP_URL + '?lang=ko', { waitUntil: 'commit' });
  await p.waitForTimeout(500);
  await p.fill('#nm', '홍길동');
  await p.fill('#ph', '01011112222');
  for (let i = 1; i <= 3; i++) {
    const fs = await p.$$('.f'); const o = await fs[i].$('.opt');
    if (o) await o.click();
    await p.waitForTimeout(80);
  }
  await p.fill('#q_who', 'x'); await p.fill('#q_places', 'y');
  await p.click('#go');
  await p.waitForTimeout(500);
  ok('서버가 죽으면 알려준다', (await p.$('.err')) !== null);
  ok('적은 것이 안 날아간다 ⭐', (await p.inputValue('#nm')) === '홍길동');
  ok('다시 누를 수 있다', !(await p.getAttribute('#go', 'disabled')));
  await p.close();

  // 신청 3개 국어
  for (const [L, want, no] of [
    ['en', 'Membership application', '멤버십 심사 신청'],
    ['ja', 'メンバーシップ審査', '멤버십 심사 신청']
  ]) {
    const m = await mk(b, { ok:true });
    await m.p.goto(APP_URL + '?lang=' + L, { waitUntil: 'commit' });
    await m.p.waitForTimeout(500);
    const t4 = await m.p.textContent('#wrap');
    ok('신청 ' + L, t4.indexOf(want) >= 0);
    ok('신청 ' + L + ' — 한국어가 안 섞인다 ⭐', t4.indexOf(no) < 0);
    ok('신청 ' + L + ' — 가격 없음 ⭐', !PRICES.test(t4));
    await m.p.close();
  }

  out.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
