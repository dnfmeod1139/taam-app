const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport:{width:390,height:844}, deviceScaleFactor:2 });
  const errs=[]; p.on('pageerror', e => errs.push(String(e).slice(0,160)));
  await p.route('**', r => (r.request().url().startsWith('file:') ? r.continue() : r.abort()));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil:'domcontentloaded', timeout:60000 });
  await p.waitForTimeout(4500);
  const out = await p.evaluate(() => {
    const r = {};
    r.fns = ['taamMarkVisit','_visActs','_visCanMark','_taamTodayKst']
      .map(n => n + '=' + (typeof window[n]));
    r.today = _taamTodayKst();
    r.keyDot = _visDateKey('2026.09.11'); r.keyDash = _visDateKey('2026-09-11'); r.keyMMDD = _visDateKey('09.11');
    const st = { s:'ok' }, cx = { s:'cx' };
    const past   = { id:'abc', reservation_date:'2026.08.01', visit_status:null };
    const future = { id:'abc', reservation_date:'2026.12.25', visit_status:null };
    const manual = { id:'abc', reservation_date:'수동입력',   visit_status:null };
    const noid   = { reservation_date:'2026.08.01' };
    const done   = { id:'abc', reservation_date:'2026.08.01', visit_status:'attended' };
    r.canPast   = _visCanMark(past, st);
    r.canFuture = _visCanMark(future, st);
    r.canManual = _visCanMark(manual, st);
    r.canCx     = _visCanMark(past, cx);
    r.canNoId   = _visCanMark(noid, st);
    r.htmlPast  = _visActs(past, st).replace(/</g,'‹').slice(0,150);
    r.htmlDone  = _visActs(done, st).replace(/</g,'‹').slice(0,150);
    r.htmlFuture= _visActs(future, st) === '' ? '(빈 문자열)' : '❌ 나옴';
    return r;
  });
  console.log(JSON.stringify(out, null, 1));
  console.log('pageerrors:', errs.slice(0,3));
  await b.close();
})();
