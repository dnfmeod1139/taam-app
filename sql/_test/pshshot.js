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
    window._currentRole='admin';
    window._currentAdminRestId='aaaa'; window._currentAdminRestName='슈모쿠초 시미즈';
    window._currentUserName='김셰프'; window._currentUserEmail='chef@example.com';
    window._currentUserGrade='T'; window.currentDepositBalance=120000;
    window._tbRows=[{_d:_tbKey(_tbToday()),party_size:2,status:'active',visit_status:null},
                    {_d:_tbKey(_tbToday()),party_size:4,status:'active',visit_status:null}];
    r.fns = ['pshOpen','pshMy','_pshRender','_pshLoadNotify'].map(n=>n+'='+(typeof window[n]));
    r.tabsPartner = AC_TABS_PARTNER.map(t=>t[1]).join('·');
    r.screenMap   = AC_SCREEN.shop;
    // 알림 수신처 없음
    window._pshNotify = {};
    document.getElementById('pshScreen').style.display='flex';
    _pshRender(); _acRenderTabs('shop');
    let t = document.getElementById('pshBody').innerText;
    r.hasRest   = t.includes('슈모쿠초 시미즈');
    r.hasMonth  = t.includes('2건 · 6명');
    r.monthLine = (t.match(/이번 달 확정[\s\S]{0,20}/)||[''])[0].replace(/\n/g,' ');
    r.stat = JSON.stringify(_tbStatus({_d:'2026-09-11',party_size:2,status:'active'}));
    r.notifyOff = t.includes('미설정') && t.includes('미연결');
    r.hasMe     = t.includes('김셰프') && t.includes('T 등급') && t.includes('₩120,000');
    r.hasTierNote = t.includes('상위 등급 전용 티켓은 보이지 않습니다');
    // 알림 수신처 있음
    window._pshNotify = { notify_phone:'010-1111-3388', notify_line_id:'U123' };
    _pshRender();
    t = document.getElementById('pshBody').innerText;
    r.notifyOn  = (t.match(/연결됨/g)||[]).length === 2;
    r.tabBar    = [].map.call(document.getElementById('pshTabs').children, e=>e.textContent).join('·');
    r.layerCss  = (function(){ const e=document.createElement('div'); e.className='mp-subpage mp-over-sub';
      document.body.appendChild(e); const z=getComputedStyle(e).zIndex; e.remove(); return z; })();
    return r;
  });
  console.log(JSON.stringify(out, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
