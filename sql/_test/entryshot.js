const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport:{width:390,height:844} });
  const errs=[]; p.on('pageerror', e => errs.push(String(e).slice(0,200)));
  await p.route('**', r => (r.request().url().startsWith('file:') ? r.continue() : r.abort()));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil:'domcontentloaded', timeout:60000 });
  await p.waitForTimeout(4500);
  const boot = (role) => p.evaluate((role) => {
    document.getElementById('appWrapper').classList.add('ready');
    const ms=document.getElementById('mainScreen'); if(ms) ms.style.display='block';
    ['splash','checkinModal','magSheet'].forEach(id=>{const e=document.getElementById(id); if(e) e.style.display='none';});
    window._currentRole=role; window._currentAdminRestId='aaaa'; window._currentAdminRestName='슈모쿠초';
    ['myPage','adminScreen','partnerAdminScreen'].forEach(id=>{const e=document.getElementById(id); if(e) e.style.display='none';});
    openAdminConsole(false);
  }, role);
  const r = {};
  r.fns = await p.evaluate(()=>['openAdminConsole','_acExitTo','exitPartnerAdmin']
    .map(n=>n+'='+(typeof window[n])));
  await boot('superadmin'); await p.waitForTimeout(400);
  Object.assign(r, await p.evaluate(()=>({
    superLandsOnDash: getComputedStyle(document.getElementById('todayBoardScreen')).display,
    superMyPageHidden: getComputedStyle(document.getElementById('myPage')).display,
    menuTitle: document.querySelector('#adminScreen .admin-title').textContent,
    acTabs: [].map.call(document.getElementById('acTabs').children, e=>e.textContent).join('·')
  })));
  Object.assign(r, await p.evaluate(()=>{ closeAdmin();
    return { superExitAdmin: getComputedStyle(document.getElementById('adminScreen')).display,
             superExitMyPage: getComputedStyle(document.getElementById('myPage')).display }; }));
  await boot('admin'); await p.waitForTimeout(400);
  Object.assign(r, await p.evaluate(()=>({
    partnerLandsOnDash: getComputedStyle(document.getElementById('todayBoardScreen')).display,
    paTabs: [].map.call(document.getElementById('paTabs').children, e=>e.textContent).join('·')
  })));
  console.log(JSON.stringify(r, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
