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
    r.fns = ['audOpen','audClose','audSave','audSetMode','_audToggle','_audLabel']
      .map(n => n + '=' + (typeof window[n]));
    // 라벨
    r.lbl_all   = _audLabel({});
    r.lbl_mt    = _audLabel({minTier:'M'});
    r.lbl_cond  = _audLabel({audience:{mode:'conditions',tiers:['M'],visit:['repeat','regular']}});
    r.lbl_visit = _audLabel({audience:{mode:'conditions',tiers:[],visit:['first']}});
    // 모달 렌더 (서버 없이 초안만)
    window._audT = { id:'TP1', minTier:'M', audience:null };
    window._audDraft = { mode:'conditions', tiers:['M'], visit:['repeat'] };
    document.getElementById('audModal').style.display='flex';
    _audRender();
    const t = document.getElementById('audBody').innerText;
    r.hasModes  = t.includes('전체 회원') && t.includes('조건으로 고르기');
    r.hasTiers  = t.includes('M') && t.includes('T');
    r.hasVisit  = t.includes('첫 방문') && t.includes('재방문') && t.includes('단골');
    r.minTierNote = t.includes('둘 다');
    r.onCount   = document.querySelectorAll('#audBody .pk.on').length;   // M + 재방문 = 2
    // 모드를 전체로 바꾸면 조건이 접힌다
    audSetMode('all');
    r.modeAfter = _audDraft.mode;
    const t2 = document.getElementById('audBody').innerText;
    r.allHidesCond = (document.querySelectorAll('#audBody .pk').length === 0);
    r.bodyAfter = t2.replace(/\n+/g,' | ').slice(0,220);
    r.busyIncludes = (function(){ document.getElementById('audModal').style.display='flex';
      return typeof _taamBusyNow === 'function' ? String(_taamBusyNow()||'') : '(함수없음)'; })();
    return r;
  });
  console.log(JSON.stringify(out, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
