const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport:{width:390,height:844}, deviceScaleFactor:2 });
  const errs=[]; p.on('pageerror', e => errs.push(String(e).slice(0,200)));
  await p.route('**', r => (r.request().url().startsWith('file:') ? r.continue() : r.abort()));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil:'domcontentloaded', timeout:60000 });
  await p.waitForTimeout(4500);
  const out = await p.evaluate(() => {
    const r = {};
    document.getElementById('appWrapper').classList.add('ready');
    const ms=document.getElementById('mainScreen'); if(ms) ms.style.display='block';
    ['splash','checkinModal','magSheet'].forEach(id=>{const e=document.getElementById(id); if(e) e.style.display='none';});
    const key = off => { const d=_tbToday(); d.setDate(d.getDate()+off); return _tbKey(d); };
    window.ticketDB=[]; window._dashExtra={resvPending:0,deposit:null};
    window._tbRows=[
      {_d:key(-3), _m:12*60, party_size:2, status:'active', visit_status:'attended'},
      {_d:key(5),  _m:11*60+30, party_size:2, status:'active', visit_status:null},
      {_d:key(5),  _m:18*60,    party_size:4, status:'active', visit_status:null},
      {_d:key(9),  _m:12*60,    party_size:2, status:'active', visit_status:null}
    ];
    document.getElementById('todayBoardScreen').style.display='flex';
    // 파트너
    window._currentRole='admin'; _dashRender();
    let t = document.getElementById('tbBody').innerText.replace(/\n+/g,' | ');
    r.partnerHasNext = t.includes('다음 영업');
    r.partnerLine = (t.match(/다음 영업[\s\S]{0,60}/)||[''])[0];
    // 슈퍼어드민 — 다음 영업 없어야 함
    window._currentRole='superadmin'; _dashRender();
    r.superNoNext = !document.getElementById('tbBody').innerText.includes('다음 영업');
    return r;
  });
  console.log(JSON.stringify(out, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
