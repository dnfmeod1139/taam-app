const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const out=[], ok=(n,c)=>out.push((c?'OK   ':'FAIL ')+n);
  const S='/tmp/claude-0/-home-user-taam-app/9fccb989-15eb-5a7c-bc50-7176c2fe905c/scratchpad';
  const errs=[];

  async function open(charge, lang){
    const p = await b.newPage({ viewport:{width:390,height:920}, deviceScaleFactor:2,
                                locale: lang==='ja'?'ja-JP':lang==='en'?'en-US':'ko-KR' });
    p.on('pageerror',e=>errs.push(String(e)));
    await p.route('**/rpc/taam_kashikiri_charge_public', r => r.fulfill({
      status:200, contentType:'application/json', body: JSON.stringify(charge)}));
    await p.goto('file:///home/user/taam-app/pay/index.html?t=' + 'b'.repeat(32)
                 + (lang ? '&lang='+lang : ''));
    await p.waitForTimeout(900);
    return p;
  }
  const base = { id:'x', label:'동행 1', amount_krw:1051875, status:'pending',
    expires_at:'2027-01-04T00:00:00Z', venue_name:'鮨 めい乃', event_date:'2027-01-01',
    event_time:'18:00:00', fx_note:'1/1 기준율 + 2%', team_seq:1, team_pax:4, split_count:4 };

  // ── 원화 ──
  let p = await open({...base, pay_currency:'KRW', pay_amount:1051875, pay_fx:1, amount_jpy:112500, fx_rate:'9.3500'}, 'ko');
  ok('원화 금액', (await p.locator('#vAmt').textContent()) === '₩1,051,875');
  ok('원화면 엔 원금을 보여준다', (await p.locator('#vJpy').textContent()) === '¥112,500');
  ok('원화면 원화 기준 줄은 없다', !(await p.locator('#rowKrw').isVisible()));
  ok('한국어', (await p.locator('#btn').textContent()).includes('카드로 결제'));
  await p.close();

  // ── 엔화 ──
  p = await open({...base, pay_currency:'JPY', pay_amount:112500, pay_fx:'9.3500'}, 'ja');
  ok('엔화 금액', (await p.locator('#vAmt').textContent()) === '¥112,500');
  ok('엔화면 환율 줄', (await p.locator('#vFx').textContent()).includes('1¥ = 9.35₩'));
  ok('엔화면 원화 기준을 같이', (await p.locator('#vKrw').textContent()) === '₩1,051,875');
  ok('엔 원금 줄은 중복 안 띄운다', !(await p.locator('#rowJpy').isVisible()));
  ok('일본어', (await p.locator('#btn').textContent()).includes('カードで'));
  ok('일본어 날짜', (await p.locator('#vWhen').textContent()).includes('年'));
  ok('일본어 라벨', (await p.locator('[data-t=tot]').textContent()) === 'お支払い金額');
  await p.screenshot({ path:S+'/pay-jpy.png', fullPage:true });
  await p.close();

  // ── 달러 ──
  p = await open({...base, pay_currency:'USD', pay_amount:773.15, pay_fx:'1360.5000'}, 'en');
  ok('달러 금액 (센트)', (await p.locator('#vAmt').textContent()) === '$773.15');
  ok('달러 환율', (await p.locator('#vFx').textContent()).includes('1$ = 1360.5₩'));
  ok('영어', (await p.locator('#btn').textContent()) === 'Pay by card');
  ok('영어 라벨', (await p.locator('[data-t=tot]').textContent()) === 'Amount due');
  ok('영어 날짜', (await p.locator('#vWhen').textContent()).includes('January'));
  ok('영어 몫 표기', (await p.locator('#vShare').textContent()).includes('1 of 4'));
  await p.screenshot({ path:S+'/pay-usd.png', fullPage:true });

  // 언어 전환
  await p.locator('#lang button[data-l=ja]').click(); await p.waitForTimeout(300);
  ok('전환하면 즉시 바뀐다', (await p.locator('#btn').textContent()).includes('カードで'));
  ok('전환해도 금액은 그대로', (await p.locator('#vAmt').textContent()) === '$773.15');
  await p.locator('#lang button[data-l=ko]').click(); await p.waitForTimeout(300);
  ok('한국어로 되돌아온다', (await p.locator('#btn').textContent()).includes('카드로'));
  await p.close();

  // ── 자동 감지 ──
  p = await open({...base, pay_currency:'KRW', pay_amount:1051875}, null);
  ok('lang 없으면 브라우저 언어(ko)', (await p.locator('#btn').textContent()).includes('카드로'));
  await p.close();
  const p2 = await b.newPage({ locale:'en-GB' });
  p2.on('pageerror',e=>errs.push(String(e)));
  await p2.route('**/rpc/taam_kashikiri_charge_public', r => r.fulfill({
    status:200, contentType:'application/json',
    body: JSON.stringify({...base, pay_currency:'USD', pay_amount:773.15, pay_fx:'1360.5000'})}));
  await p2.goto('file:///home/user/taam-app/pay/index.html?t=' + 'b'.repeat(32));
  await p2.waitForTimeout(900);
  ok('영어권 브라우저는 영어로', (await p2.locator('#btn').textContent()) === 'Pay by card');
  await p2.close();

  // ── 완료 · 오류 화면도 번역 ──
  p = await open({...base, status:'paid', pay_currency:'JPY', pay_amount:112500, receipt_url:'https://x'}, 'ja');
  ok('완료도 일본어', (await p.locator('#dTitle').textContent()) === 'お支払いが完了しました');
  ok('완료 금액이 엔화', (await p.locator('#dAmt').textContent()) === '¥112,500');
  ok('퍼널도 일본어', (await p.locator('#funnel').textContent()).includes('会員'));
  await p.close();
  p = await open({...base, status:'expired'}, 'en');
  ok('만료도 영어', (await p.locator('#dTitle').textContent()) === 'This link has expired');
  await p.close();

  out.forEach(l=>console.log(l));
  if(errs.length){ console.log('\n오류:'); errs.slice(0,5).forEach(e=>console.log('  '+e)); }
  const bad = out.filter(l=>l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : '=== 전부 통과 ==='));
  await b.close();
})();
