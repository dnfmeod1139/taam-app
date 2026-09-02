// ═══════════════════════════════════════════════════════════════
// 법인 안내(corp/) · 게스트 만료 로그아웃 — 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
//   ① 법인 페이지에 **금액이 없는가** ← 상담 전에 숫자가 굳으면 안 된다
//   ② 셀프 결제 버튼이 없는가
//   ③ 필수 칸을 안 채우면 못 보내는가
//   ④ 게스트가 만료되면 로그아웃되는가
//   ⑤ **조회가 실패하면 아무것도 안 하는가** ← 멀쩡한 게스트가 튕기면 안 된다
//   ⑥ 만료 안내가 「끝났습니다」로 끝나지 않는가 (돌아올 길)
//
// 실행: node sql/_test/corpshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const CORP = 'file:///home/user/taam-app/corp/index.html';
const PRICES = /11,250,000|11,395,000|10,125,000|1,125,000|1,270,000|만원|円|KRW/;

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const errs = [];

  async function mk(reply) {
    const p = await b.newPage({ viewport: { width: 390, height: 1100 } });
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
    p.on('pageerror', e => errs.push(String(e)));
    return { p, calls };
  }

  // ── ① 법인 안내 ───────────────────────────────────────────
  let { p, calls } = await mk((fn) => fn === 'taam_mship_settings'
    ? { corp_slots: 5, deposit_amount: 10125000, annual_fee_cash: 1125000 }
    : { ok: true });
  await p.goto(CORP + '?lang=ko', { waitUntil: 'commit' });
  await p.waitForTimeout(700);
  let txt = await p.textContent('#wrap');
  ok('법인 화면이 뜬다', txt.indexOf('코퍼레이트 멤버십') >= 0);
  ok('슬롯 수를 설정값에서 읽는다 ⭐', txt.indexOf('법인 5사 한정') >= 0);
  // ⚠ 개인 금액이 설정값에 같이 들어 있어도 화면에는 안 나와야 한다
  ok('금액이 한 글자도 없다 ⭐', !PRICES.test(txt));
  ok('연회비는 상담 후라고 적는다 ⭐', txt.indexOf('상담 후 개별 안내') >= 0);
  ok('혜택 다섯 줄', (await p.$$('.list .r')).length === 5);
  ok('법인카드 일괄 결제를 혜택으로 적는다', txt.indexOf('법인카드 일괄 결제') >= 0);
  ok('세금계산서를 말한다', txt.indexOf('세금계산서') >= 0);
  ok('임직원 2인을 말한다', txt.indexOf('2인') >= 0);
  // ② 셀프 결제가 없다
  ok('결제 버튼이 없다 ⭐',
     txt.indexOf('결제하기') < 0 && txt.indexOf('시작하기') < 0);
  ok('버튼은 문의 하나뿐', (await p.$$('button.go')).length === 1);

  // ③ 필수 칸
  calls.length = 0;
  await p.click('#go'); await p.waitForTimeout(250);
  ok('빈 채로는 서버를 안 부른다 ⭐', !calls.some(c => c[0] === 'taam_corp_inquire'));
  ok('무엇이 비었는지 알려준다', (await p.$('.err')) !== null);

  await p.fill('#i_co', '주식회사 탐');
  await p.fill('#i_ct', '김우종 대표');
  await p.fill('#i_ph', '010-3333-4444');
  await p.fill('#i_mm', '연 20회 정도 검토 중입니다');
  calls.length = 0;
  await p.click('#go'); await p.waitForTimeout(400);
  const call = calls.filter(c => c[0] === 'taam_corp_inquire')[0];
  ok('문의를 서버에 넘긴다', !!call);
  ok('회사·담당자·연락처를 넘긴다',
     call && call[1].p_company === '주식회사 탐'
          && call[1].p_contact === '김우종 대표'
          && call[1].p_phone === '010-3333-4444');
  ok('메모도 넘긴다', call && String(call[1].p_memo).indexOf('20회') >= 0);
  ok('이메일은 비어도 된다', call && call[1].p_email === null);
  ok('접수됐다고 말한다', (await p.textContent('#wrap')).indexOf('접수되었습니다') >= 0);
  await p.close();

  // 설정을 못 읽어도 화면은 뜬다
  ({ p, calls } = await mk({ __fail: true }));
  await p.goto(CORP + '?lang=ko', { waitUntil: 'commit' });
  await p.waitForTimeout(600);
  txt = await p.textContent('#wrap');
  ok('설정을 못 읽어도 열린다', txt.indexOf('코퍼레이트') >= 0);
  ok('숫자를 지어내지 않는다 ⭐', txt.indexOf('법인 한정') >= 0 && !/법인 \d+사/.test(txt));
  await p.close();

  // 3개 국어
  for (const [L, want] of [['en','Corporate membership'], ['ja','コーポレート']]) {
    const m = await mk((fn) => fn === 'taam_mship_settings' ? { corp_slots: 5 } : { ok:true });
    await m.p.goto(CORP + '?lang=' + L, { waitUntil: 'commit' });
    await m.p.waitForTimeout(600);
    const t2 = await m.p.textContent('#wrap');
    ok('법인 ' + L, t2.indexOf(want) >= 0);
    ok('법인 ' + L + ' — 금액 없음 ⭐', !PRICES.test(t2));
    await m.p.close();
  }

  // ── ④⑤⑥ 게스트 만료 ──────────────────────────────────────
  const q = await b.newPage({ viewport: { width: 390, height: 844 } });
  q.on('pageerror', e => errs.push(String(e)));
  await q.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await q.waitForTimeout(2500);
  const r2 = await q.evaluate(async () => {
    const o = [];
    const okk = (n, c) => o.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    document.getElementById('appWrapper').classList.add('ready');

    let signedOut = 0;
    const mkSb = (reply) => ({
      rpc: () => Promise.resolve(reply),
      auth: { signOut: () => { signedOut++; return Promise.resolve({}); } }
    });

    // 만료되지 않은 게스트 — 아무 일도 없어야 한다
    signedOut = 0;
    window.sb = mkSb({ data: { is_guest: true, expired: false, days_left: 40 }, error: null });
    okk('안 만료면 아무 일도 없다', (await window._checkGuestExpiry()) === false && signedOut === 0);

    // M 회원 — 게스트가 아니다
    signedOut = 0;
    window.sb = mkSb({ data: { is_guest: false }, error: null });
    okk('M 회원은 안 건드린다', (await window._checkGuestExpiry()) === false && signedOut === 0);

    // ⑤ 조회 실패 — **아무것도 하지 않는다**
    signedOut = 0;
    window.sb = mkSb({ data: null, error: { message: 'network' } });
    okk('조회가 실패하면 로그아웃 안 한다 ⭐',
        (await window._checkGuestExpiry()) === false && signedOut === 0);
    signedOut = 0;
    window.sb = mkSb({ data: null, error: null });
    okk('답이 비어도 로그아웃 안 한다 ⭐',
        (await window._checkGuestExpiry()) === false && signedOut === 0);

    // ④ 만료 — 내보낸다
    signedOut = 0;
    document.getElementById('guestExpiredModal')?.remove();
    window.sb = mkSb({ data: { is_guest: true, expired: true, days_left: 0 }, error: null });
    okk('만료면 내보낸다 ⭐', (await window._checkGuestExpiry()) === true && signedOut === 1);

    // ⑥ 안내가 「끝났습니다」로 끝나지 않는다
    await sleep(80);
    const m = document.getElementById('guestExpiredModal');
    okk('만료 안내가 뜬다', !!m);
    okk('종료됐다고 말한다', !!m && m.textContent.indexOf('종료되었습니다') >= 0);
    okk('돌아올 길을 준다 ⭐',
        !!m && m.textContent.indexOf('심사 신청') >= 0 && m.textContent.indexOf('추천') >= 0);
    okk('심사 신청 버튼이 있다', !!m && !!m.querySelector('#gxApply'));
    okk('닫을 수도 있다', !!m && !!m.querySelector('#gxClose'));
    m.querySelector('#gxClose').click(); await sleep(60);
    okk('닫힌다', !document.getElementById('guestExpiredModal'));
    return o;
  });
  out.push(...r2);
  await q.close();

  out.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
