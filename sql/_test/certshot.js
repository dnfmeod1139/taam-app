// ═══════════════════════════════════════════════════════════════
// 파트너 증서 페이지 — 토큰 없이는 열리지 않는다 (2026-09-13)
// ═══════════════════════════════════════════════════════════════
//   ?cert=<id> 만으로 열리던 증서에 &t=<토큰> 이 붙었다 (sql/partner_cert_token.sql).
//   ① 토큰 없으면 서버를 부르지도 않는다 ⭐  ② 있으면 p_id + p_token 을 보낸다 ⭐
//   ③ 서버가 거부하면 증서가 안 뜬다
//   ⚠ Playwright 는 나중에 등록한 route 를 먼저 본다. 포괄 route 를 특정 route
//     뒤에 등록하면 특정 것이 영영 안 불려 「호출 0회」가 거짓으로 통과한다.
// 실행: node sql/_test/certshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
  const open = async (qs, rpcReply) => {
    const p = await b.newPage({ viewport: { width: 390, height: 900 } });
    const errs = []; p.on('pageerror', e => errs.push(String(e).slice(0, 120)));
    const calls = [];
    await p.route('**://fonts.g**', r => r.abort());
    // ⚠ Playwright 는 나중에 등록한 route 를 먼저 본다 — 포괄(catch-all)을 먼저, 특정 것을 뒤에
    await p.route('**/rest/v1/**', r => r.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":false}' }));
    await p.route('**/rest/v1/rpc/partner_agreement_get', async r => {
      calls.push(JSON.parse(r.request().postData() || '{}'));
      await r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(rpcReply) });
    });
    await p.goto('file:///home/user/taam-app/partner/index.html' + qs, { waitUntil: 'domcontentloaded' });
    await p.waitForTimeout(1200);
    const st = await p.evaluate(() => ({
      cert: getComputedStyle(document.getElementById('certPage')).display,
      gate: getComputedStyle(document.getElementById('gate')).display,
      text: (document.getElementById('certPage') || {}).textContent || ''
    }));
    await p.close();
    return { st, calls, errs };
  };
  // ① 토큰 없이 ?cert=1 → 서버를 부르지도 않고 「유효하지 않음」
  let r = await open('?cert=1', { ok: true });
  ok('토큰 없으면 서버를 안 부른다 ⭐ (' + r.calls.length + '회)', r.calls.length === 0);
  ok('토큰 없으면 증서가 안 뜬다 ⭐', r.st.cert === 'none');
  ok('JS 오류 없음', r.errs.length === 0);
  // ② 토큰 있으면 p_token 을 보낸다
  r = await open('?cert=7&t=abcdefabcdefabcdefabcdefabcdef12', { ok: true, restaurant_name: '슌지', chef_name: '春二', signer_name: '슌지',
    agreed_at: '2026-09-13T00:00:00Z', signature_data: 'data:image/png;base64,iVBORw0KGgo=', agreed_meal: '¥30,000', agreed_min: '¥6,000' });
  ok('p_id 와 p_token 을 같이 보낸다 ⭐', r.calls.length === 1 && r.calls[0].p_id === 7 && r.calls[0].p_token === 'abcdefabcdefabcdefabcdefabcdef12');
  ok('증서가 뜬다', r.st.cert !== 'none' && r.st.text.indexOf('슌지') >= 0);
  ok('JS 오류 없음', r.errs.length === 0);
  // ③ 서버가 거부하면 게이트
  r = await open('?cert=7&t=wrongtokenwrongtokenwrongtoken00', { ok: false });
  ok('거부되면 증서가 안 뜬다', r.st.cert === 'none');
  out.forEach(l => console.log(l));
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log(bad ? '=== 실패 ' + bad + '건 ===' : '=== 전부 통과 (' + out.length + '건) ===');
  await b.close();
  process.exit(bad ? 1 : 0);
})();
