const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ hasTouch: true });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

    ok('_taamBindCalSwipe 존재', typeof window._taamBindCalSwipe === 'function');
    ok('_taamCalSwiped 존재',   typeof window._taamCalSwiped === 'function');
    ok('pcalStep 존재',         typeof window.pcalStep === 'function');
    ok('_tcalBindSwipe 존재',   typeof _tcalBindSwipe === 'function');
    ok('_rvBindSwipe 존재',     typeof _rvBindSwipe === 'function');

    // 가짜 호스트로 바인더 자체를 시험한다
    const host = document.createElement('div');
    host.innerHTML = '<div class="zz"><span id="cell">1</span></div><div class="other">x</div>';
    document.body.appendChild(host);
    let calls = [];
    window._taamBindCalSwipe(host, '.zz', d => calls.push(d));
    ok('두 번 걸어도 한 번만', (function(){ window._taamBindCalSwipe(host, '.zz', d => calls.push(999)); return true; })());

    const cell = host.querySelector('#cell');
    const other = host.querySelector('.other');
    function drag(target, x0, y0, x1, y1, type){
      target.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, clientX:x0, clientY:y0, pointerType:type}));
      host.dispatchEvent(new PointerEvent('pointerup',   {bubbles:true, clientX:x1, clientY:y1, pointerType:type}));
    }
    calls = []; drag(cell, 200, 100, 100, 105, 'mouse');
    ok('마우스로 왼쪽 → +1', JSON.stringify(calls) === '[1]');

    calls = []; drag(cell, 100, 100, 220, 108, 'mouse');
    ok('마우스로 오른쪽 → -1', JSON.stringify(calls) === '[-1]');

    calls = []; drag(cell, 200, 100, 180, 100, 'mouse');
    ok('짧게 끌면 안 넘어감', calls.length === 0);

    calls = []; drag(cell, 200, 100, 140, 300, 'mouse');
    ok('세로가 크면 안 넘어감', calls.length === 0);

    calls = []; drag(other, 200, 100, 100, 100, 'mouse');
    ok('달력 밖에서 끌면 무시', calls.length === 0);

    // 터치
    function tdrag(target, x0, y0, x1, y1){
      const mk = (t, x, y) => { const e = new Event(t, {bubbles:true});
        const l = [{clientX:x, clientY:y}];
        Object.defineProperty(e, 'touches', {value: t==='touchend'?[]:l});
        Object.defineProperty(e, 'changedTouches', {value: l}); return e; };
      target.dispatchEvent(mk('touchstart', x0, y0));
      host.dispatchEvent(mk('touchend', x1, y1));
    }
    calls = []; tdrag(cell, 200, 100, 100, 100);
    ok('터치로 왼쪽 → +1', JSON.stringify(calls) === '[1]');

    // 민 직후의 클릭은 무시된다
    ok('민 직후 _taamCalSwiped() true', window._taamCalSwiped() === true);

    // pointerType touch 는 중복으로 안 센다
    calls = []; drag(cell, 200, 100, 100, 100, 'touch');
    ok('touch 포인터는 무시(중복 방지)', calls.length === 0);

    // pcalStep 월 계산
    window._pcalY = 2026; window._pcalM = 12;
    const realGo = window.pcalGo; let got = null;
    window.pcalGo = (y, m) => { got = y + '-' + m; };
    window.pcalStep(1);  ok('12월 → 다음 = 2027-1', got === '2027-1');
    window._pcalY = 2026; window._pcalM = 1;
    window.pcalStep(-1); ok('1월 → 이전 = 2025-12', got === '2025-12');
    window.pcalGo = realGo;

    host.remove();
    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
