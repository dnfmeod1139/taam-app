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
    const ms = document.getElementById('mainScreen'); if (ms) ms.style.display='block';
    ['splash','checkinModal','magSheet'].forEach(id=>{const e=document.getElementById(id); if(e) e.style.display='none';});
    window._currentRole = 'superadmin';
    r.fns = ['mbSetSeg','acUnban','acBanPick','acEditRule','acAddRestRule','_acRenderAccess','_acLoadAccess']
      .map(n => n + '=' + (typeof window[n]));
    // 접근 제어 렌더 — SQL 이 아직 없는 DB 를 흉내
    window._mbRows = [{id:'u1', display_name:'김도윤', phone:'010-1111-2222'}];
    window._acBans = []; window._acRules = [];
    document.getElementById('mbScreen').style.display='flex';
    _mbState.seg='access'; _acRenderAccess();
    r.sqlMissing = document.getElementById('mbBody').innerText.slice(0,60);
    // SQL 이 있는 DB
    window._acRules = [{restaurant_id:'*', repeat_min:1, regular_min:3},
                       {restaurant_id:'aaaa', repeat_min:5, regular_min:9}];
    window._acBans = [{user_id:'u1', reason:'노쇼 3회', banned_at:'2026-08-01', until:null},
                      {user_id:'u2', reason:'만료됨', banned_at:'2026-07-01', until:'2026-08-01'}];
    window.restaurantDB = [{id:'aaaa', name:'스시 코바야시'}];
    _acRenderAccess();
    const t = document.getElementById('mbBody').innerText;
    r.hasBan     = t.includes('김도윤') && t.includes('노쇼 3회');
    r.expiredHid = !t.includes('만료됨');       // 기한 지난 제한은 안 보여야 함
    r.hasBase    = t.includes('재방문') && t.includes('단골');
    r.hasPerRest = t.includes('스시 코바야시') && t.includes('재방문 5+');
    r.segSwitch  = (function(){ mbSetSeg('list'); const a = _mbState.seg;
                                mbSetSeg('access'); return a + '→' + _mbState.seg; })();
    return r;
  });
  console.log(JSON.stringify(out, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
