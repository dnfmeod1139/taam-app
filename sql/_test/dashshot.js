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
    window._currentRole='superadmin';
    r.fns = ['_dashRender','_dashLoad','_dashPending','_dashUnmarked','_acTodoCount']
      .map(n => n + '=' + (typeof window[n]));
    r.tabsSuper   = AC_TABS_SUPER.map(t=>t[1]).join('·');
    r.tabsPartner = AC_TABS_PARTNER.map(t=>t[1]).join('·');

    // ── 아무것도 없는 상태: 처리할 일 카드가 없어야 한다 ──
    window.ticketDB = []; window._tbRows = [];
    window._dashExtra = { resvPending:0, deposit:null };
    document.getElementById('todayBoardScreen').style.display='flex';
    _dashRender();
    r.emptyNoTodo = !document.getElementById('tbBody').innerText.includes('처리할 일');

    // ── 있는 상태 ──
    window.ticketDB = [
      {id:'A', status:'pending',  date:'2026.10.09', totalPax:4, rest:'토리야바시'},
      {id:'B', status:'active',   date:'2026.11.19', totalPax:8, rest:'스시 코바야시'},
      {id:'C', status:'soldout',  date:'2026.09.30', totalPax:4, rest:'슈모쿠초'}
    ];
    window._tbRows = [
      {_d:'2026-09-11', reservation_date:'2026.09.11', party_size:2, status:'active', visit_status:null},
      {_d:'2026-08-20', reservation_date:'2026.08.20', party_size:4, status:'active', visit_status:null},
      {_d:'2026-09-30', reservation_date:'2026.09.30', party_size:2, status:'cancelled', visit_status:null}
    ];
    window._dashExtra = { resvPending:1, deposit:12480000 };
    _dashRender();
    const t = document.getElementById('tbBody').innerText;
    r.hasTodo    = t.includes('처리할 일');
    r.hasApprove = t.includes('티켓 업로드 승인');
    r.hasResv    = t.includes('파트너 예약 요청');
    r.hasUnmark  = t.includes('방문 기록 안 함');
    r.hasTicket  = t.includes('티켓') && t.includes('판매중');
    r.hasMonth   = t.includes('예약 · 이번 달');
    r.hasDeposit = t.includes('예치금') && t.includes('12,480,000');
    r.badge      = _acTodoCount();     // 승인1 + 요청1 + 미기록1 = 3
    r.body       = t.replace(/\n+/g,' | ').slice(0,300);
    return r;
  });
  await p.evaluate(() => {
    document.getElementById('todayBoardScreen').style.display='flex';
    _acRenderTabs('today');
    document.getElementById('tbStrip').style.display='none';
    document.querySelector('#todayBoardScreen .sub-title').textContent='대시보드';
    document.getElementById('tbFindBtn').style.display='none';
    document.querySelectorAll('body *').forEach(e => {
      const st = getComputedStyle(e);
      if (st.position === 'fixed' && +st.zIndex >= 1200) e.style.display = 'none';
    });
  });
  await p.waitForTimeout(300);
  await p.screenshot({ path: 'dash.png' });
  console.log(JSON.stringify(out, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
