// ═══════════════════════════════════════════════════════════════
// 회원이 적은 글자가 어드민 화면에서 실행되지 않는다 (2026-09-13)
// ═══════════════════════════════════════════════════════════════
//   감사에서 짚은 자리: 티켓 캘린더 명단(회원 이름) · 예약 관리 요청자 이름 ·
//   코드 부여 검색 드롭다운(이름·전화) · 컨시어지 챗(모델 출력 → taamMdToHtml).
//   회원이 이름에 <img onerror> 를 적으면 슈퍼어드민·매장어드민 화면에서 실행됐다.
//
//   ① taamMdToHtml 은 태그를 글자로 만든다 ⭐   ② 이미 이스케이프된 &gt; 는 두 번 감싸지 않는다
//   ③ 예약 관리 카드의 요청자 이름이 이스케이프된다 ⭐
//   ④ 코드 부여 드롭다운의 이름·전화가 이스케이프된다 ⭐
//   ⑤ _raEsc 자체
// 실행: node sql/_test/xssshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const FAKE_SDK = `window.supabase={createClient:function(){return {
  from:function(){return {select:function(){return Promise.resolve({data:[],error:null});}};},
  auth:{getUser:function(){return Promise.resolve({data:{user:null}});},
        getSession:function(){return Promise.resolve({data:{session:null}});},
        onAuthStateChange:function(){return {data:{subscription:{unsubscribe:function(){}}}};}},
  channel:function(){return {on:function(){return this;},subscribe:function(){return this;}};},
  removeChannel:function(){},rpc:function(){return Promise.resolve({data:null,error:null});} };}};`;
const EVIL = '<img src=x onerror="window.__pwned=1">';
let fail = 0, n = 0;
function ok(name, cond, detail){ n++; if (cond) console.log('OK  ', name); else { fail++; console.log('FAIL', name, detail ? '— ' + String(detail).slice(0, 200) : ''); } }

(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await p.route('**://fonts.g**', r => r.abort());
  await p.route('**://unpkg.com/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: FAKE_SDK }));
  await p.route('**://cdn.jsdelivr.net/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: FAKE_SDK }));
  await p.route('**://cdnjs.cloudflare.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'load' });
  await p.waitForTimeout(1500);

  const r = await p.evaluate((EVIL) => {
    const out = {};
    out.esc = _raEsc(EVIL);
    out.md = taamMdToHtml('안녕 ' + EVIL + ' **굵게**');
    out.mdQuote = taamMdToHtml('&gt; 인용');
    out.mdQuote2 = taamMdToHtml('> 인용');
    // 예약 관리 카드 — 요청자 이름
    try {
      const html = _raReqHtml({ id: 'r1', user_id: '11111111-2222', status: 'pending', reserve_date: '2026-10-01', reserve_time: '19:00',
                                party_size: 2, venue_id: 'V1', member_memo: '' }, EVIL);
      out.ra = html;
    } catch (e) { out.raErr = String(e); }
    // 코드 부여 드롭다운 — 검색 결과를 직접 만든다
    try {
      window.memberDB = [{ id: 'm1', name: EVIL, phone: '010-' + EVIL }];
      let dd = document.getElementById('acMemberDropdown');
      if (!dd) { dd = document.createElement('div'); dd.id = 'acMemberDropdown'; document.body.appendChild(dd); }
      const fnName = Object.keys(window).find(k => /^acSearchMember|^acMemberSearch/.test(k)) || null;
      out.ddFn = fnName;
      // 함수 이름을 모르면 소스에서 찾는다
      const src = document.documentElement.innerHTML;
      const m = src.match(/function (ac[A-Za-z]*)\(q\)[^]*?_acMemberResults = results;/);
      const fn = m && window[m[1]] ? window[m[1]] : (fnName ? window[fnName] : null);
      if (fn) { fn('img'); out.dd = dd.innerHTML; }
      else out.ddErr = 'dropdown 함수를 못 찾음';
    } catch (e) { out.ddErr = String(e); }
    return out;
  }, EVIL);

  ok('⑤ _raEsc 가 <> 를 글자로', !r.esc.includes('<img') && r.esc.includes('&lt;img'), r.esc);
  ok('① taamMdToHtml 이 태그를 글자로 ⭐', !r.md.includes('<img') && r.md.includes('&lt;img'), r.md);
  ok('① 마크다운(굵게)은 여전히 동작', r.md.includes('<strong>굵게</strong>'), r.md);
  ok('② &gt; 인용을 두 번 감싸지 않는다', r.mdQuote.includes('<blockquote>') && !r.mdQuote.includes('&amp;gt;'), r.mdQuote);
  ok('② 생 > 인용도 인용으로', r.mdQuote2.includes('<blockquote>'), r.mdQuote2);
  ok('③ 예약 관리 카드 요청자 이름 이스케이프 ⭐', !!r.ra && !r.ra.includes('<img') && r.ra.includes('&lt;img'), r.raErr || (r.ra || '').slice(0, 200));
  if (r.dd !== undefined) {
    ok('④ 드롭다운 이름·전화 이스케이프 ⭐', !r.dd.includes('<img') && r.dd.includes('&lt;img'), r.dd);
  } else {
    ok('④ 드롭다운 함수를 찾았다', false, r.ddErr);
  }
  const pwned = await p.evaluate(() => !!window.__pwned);
  ok('페이지에서 아무것도 실행되지 않았다 ⭐', !pwned);

  await browser.close();
  console.log('\n' + (fail ? `=== 실패 ${fail}/${n} ===` : `=== 전부 통과 (${n}건) ===`));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
