const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport:{width:390,height:900} });
  const out=[], ok=(n,c)=>out.push((c?'OK   ':'FAIL ')+n); const errs=[];
  p.on('pageerror',e=>errs.push(String(e)));
  await p.route('**/rpc/taam_kashikiri_sheet_public', r => r.fulfill({
    status:200, contentType:'application/json', body: JSON.stringify({
      venue_name:'鮨 めい乃', event_date:'2027-01-01', event_time:'18:00:00',
      total_pax:9, escort:true,
      teams:[{ seq:1, pax:4, host_label:'K様', drink_note:'シャンパーニュ中心',
        guests:[{name:'K様',is_host:true,visit_count:3,allergy:null,memo:'のどぐろ',
                 last_spend:512000,last_visit:'2026-10-11'},
                {name:'P様',is_host:false,visit_count:0,allergy:'甲殻類'}]}]})}));
  await p.goto('file:///home/user/taam-app/sheet/index.html?t=' + 'a'.repeat(32));
  await p.waitForTimeout(1200);
  ok('시트가 그려진다', await p.locator('#body').isVisible());
  ok('매장', (await p.locator('#sVenue').textContent()).includes('めい乃'));
  ok('인솔 pill', (await p.locator('#sPills').textContent()).includes('同行あり'));
  ok('지난 회계', (await p.locator('#c0').textContent()).includes('¥512,000'));
  ok('알레르기', (await p.locator('#c0').textContent()).includes('甲殻類'));
  ok('상세 닫힘', !(await p.locator('#d0').isVisible()));
  await p.locator('#c0 .hit').click(); await p.waitForTimeout(300);
  ok('눌러서 열린다', await p.locator('#d0').isVisible());
  out.forEach(l=>console.log(l));
  if(errs.length){ console.log('오류:'); errs.slice(0,3).forEach(e=>console.log(' '+e)); }
  const bad=out.filter(l=>l.startsWith('FAIL')).length;
  console.log(bad ? `=== 실패 ${bad}건 ===` : '=== 전부 통과 ===');
  await b.close();
})();
