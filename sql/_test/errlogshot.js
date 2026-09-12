// ═══════════════════════════════════════════════════════════════
// 오류 리포팅 — 회원 기기의 오류가 나에게 온다 (2026-09-12)
// ═══════════════════════════════════════════════════════════════
//   ① sb 가 생기기 전에 난 오류도 줄 서 있다가 간다 ⭐ (부팅 실패가 그렇다)
//   ② 같은 오류는 한 세션에 한 번만 ⭐ (무한 루프 하나가 60건을 못 먹는다)
//   ③ 이메일·전화·JWT 는 지워서 보낸다 ⭐
//   ④ 처리 안 된 Promise 도 잡는다
//   ⑤ 리포터 자체가 절대 던지지 않는다 ⭐
//   ⑥ 부팅 감시견이 발동하면 boot_stuck 이 간다
//   ⑦ 대시보드 카드 — 있으면 숫자, 함수가 없으면 「안 돌렸다」, 0건이면 「없다」
// 실행: node sql/_test/errlogshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const HERE = require('path').resolve(__dirname, '..', '..');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => { const t = String(e); if (t.indexOf('버려진 약속') < 0) errs.push(t.slice(0, 160)); });  // ④ 가 일부러 내는 것
  await p.route('**://fonts.g**', r => r.abort());
  await p.route('**unpkg.com**', r => r.abort());
  await p.route('**cdn.jsdelivr.net**', r => r.abort());
  await p.goto('file://' + HERE + '/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(1500);

  const r = await p.evaluate(async () => {
    const res = [];
    const ok = (n, c) => res.push((c ? 'OK   ' : 'FAIL ') + n);
    const wait = ms => new Promise(r => setTimeout(r, ms));
    ok('리포터가 있다', typeof window.taamReportError === 'function');

    // ── ① sb 없이 적는다 → 줄 선다 ─────────────────────────
    window.sb = undefined;
    window.taamReportError('js', 'before-sb 오류', 'stack1', {});
    const calls = [];
    window.sb = { rpc: (fn, args) => { calls.push({ fn, args }); return Promise.resolve({ data: null, error: null }); } };
    window.taamReportError('js', 'after-sb 오류', null, {});
    await wait(1200);
    // ⚠ 큐가 비어 있다고 가정하지 않는다 — 이 테스트는 CDN 을 막아 두므로
    //   페이지가 뜨자마자 cdn_dead 가 먼저 줄을 선다. 순서(먼저 난 것이 먼저)만 본다.
    const iB = calls.findIndex(c => c.args.p_message === 'before-sb 오류');
    const iA = calls.findIndex(c => c.args.p_message === 'after-sb 오류');
    ok('sb 가 생기면 줄 선 것부터 나간다 ⭐ (' + iB + ' < ' + iA + ')', iB >= 0 && iA > iB);
    ok('CDN 실패도 적혔다 (부팅 전 오류) ⭐', calls.some(c => c.args.p_kind === 'cdn_dead'));
    ok('taam_report_error 를 부른다', calls.every(c => c.fn === 'taam_report_error'));
    ok('빌드·플랫폼이 실린다', calls[0].args.p_build && calls[0].args.p_platform === 'web');

    // ── ② 같은 오류는 한 번만 ⭐ ────────────────────────────
    const n0 = calls.length;
    for (let i = 0; i < 20; i++) window.taamReportError('js', 'after-sb 오류', null, {});
    await wait(600);
    ok('같은 오류 20번 → 0번 추가 ⭐', calls.length === n0);

    // ── ③ 개인정보 지우기 ⭐ ────────────────────────────────
    window.taamReportError('js', 'fail for kim@example.com tel 010-1234-5678 tok eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9xxxx', null, {});
    await wait(600);
    const m = calls[calls.length - 1].args.p_message;
    ok('이메일이 지워진다 ⭐', m.indexOf('kim@') < 0 && m.indexOf('[email]') >= 0);
    ok('전화가 지워진다 ⭐', m.indexOf('1234-5678') < 0 && m.indexOf('[phone]') >= 0);
    ok('JWT 가 지워진다 ⭐', m.indexOf('eyJhbGci') < 0 && m.indexOf('[jwt]') >= 0);

    // ── ④ unhandledrejection ──────────────────────────────
    const n1 = calls.length;
    Promise.reject(new Error('버려진 약속'));
    await wait(800);
    ok('처리 안 된 Promise 가 잡힌다', calls.length === n1 + 1 && calls[n1].args.p_kind === 'promise'
       && calls[n1].args.p_message.indexOf('버려진 약속') >= 0);

    // ── ⑤ 리포터가 던지지 않는다 ⭐ ─────────────────────────
    let threw = false;
    try {
      window.taamReportError(null, null, null, null);
      window.taamReportError('js', { toString(){ throw new Error('x'); } }, null, {});
      window.sb = { rpc: () => { throw new Error('rpc 폭발'); } };
      window.taamReportError('js', '폭발 뒤', null, {});
    } catch (e) { threw = true; }
    ok('어떤 입력에도 던지지 않는다 ⭐', !threw);
    ok('rpc 가 던져도 앱은 산다', !threw);

    // ── ⑥ 감시견 → boot_stuck ──────────────────────────────
    window.sb = { rpc: (fn, args) => { calls.push({ fn, args }); return Promise.resolve({ data: null, error: null }); } };
    document.getElementById('appWrapper').classList.remove('ready');
    if (typeof window._bootWatchdog === 'function') window._bootWatchdog();
    await wait(800);
    ok('감시견 발동이 boot_stuck 으로 간다', calls.some(c => c.args.p_kind === 'boot_stuck'));

    // ── ⑦ 대시보드 카드 ────────────────────────────────────
    window._currentRole = 'superadmin'; window._isSuperAdmin = () => true;
    document.getElementById('appWrapper').classList.add('ready');
    const paint = (errors) => { window._dashExtra = { resvPending: 0, deposit: 0, errors }; _dashRender(); return document.getElementById('tbBody').textContent; };
    window._tbRows = []; window.ticketDB = [];
    // 함수가 없으면
    let t = paint({ missing: true });
    ok('SQL 안 돌렸으면 그렇게 말한다 ⭐', t.indexOf('app_errors.sql') >= 0);
    // 0건
    t = paint({ total: 0, users: 0, anon: 0, by_kind: {}, top: [] });
    ok('0건이면 「없다」', t.indexOf('올라온 오류가 없습니다') >= 0);
    // 있으면 숫자와 종류
    t = paint({ total: 7, users: 3, anon: 1, by_kind: { js: 5, boot_stuck: 2 }, top: [
      { kind: 'boot_stuck', message: '8초 안에 .ready 가 안 붙음', n: 2, last: '2026-09-12T01:00:00Z', platforms: ['android'] }] });
    ok('건수·명수가 뜬다 ⭐', /7/.test(t) && t.indexOf('3명') >= 0);
    ok('종류별로 보인다', t.indexOf('boot_stuck') >= 0);
    acErrOpen(); await wait(100);
    const pop = document.getElementById('acErrPop');
    ok('누르면 상세가 뜬다', !!pop && pop.textContent.indexOf('8초 안에') >= 0 && pop.textContent.indexOf('android') >= 0);
    _acOverlayClose('acErrPop');
    ok('닫힌다', !document.getElementById('acErrPop'));
    return res;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
