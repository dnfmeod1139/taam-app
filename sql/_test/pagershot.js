// ═══════════════════════════════════════════════════════════════
// 사진 캘린더 — 아이폰식 페이저 검증 (2026-09-01)
// ═══════════════════════════════════════════════════════════════
// 무엇을 보나
//   ① _pcalCalHtml 이 아무 달이나 그릴 수 있나 (앞·뒤 달을 같이 그려야 한다)
//   ② 칸이 늘 42개(6줄)인가 — 세 판 높이가 어긋나면 미는 중에 옆 달이 튄다
//   ③ 미는 동안 트랙이 **손끝을 따라오나** (종전엔 가만히 있다가 툭 바뀌었다)
//   ④ 놓았을 때 거리·속도로 넘어갈지 되돌아올지 정하나
//   ⑤ 세로 손짓은 목록 스크롤에 넘겨주나
//
// 실행: node sql/_test/pagershot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ hasTouch: true });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));

    ok('_pcalCalHtml 존재',   typeof window._pcalCalHtml === 'function');
    ok('_pcalBindPager 존재', typeof window._pcalBindPager === 'function');
    ok('_taamCalSwipeHold 존재', typeof window._taamCalSwipeHold === 'function');

    // ── ① · ② 한 판 그리기 ──────────────────────────────────
    const wrap = document.createElement('div');
    wrap.innerHTML = window._pcalCalHtml({}, 2026, 2);
    const cells = wrap.querySelectorAll('.pcal-days > .pcal-d').length;
    ok('칸이 42개(6줄) — 2026-02', cells === 42);

    const wrap2 = document.createElement('div');
    wrap2.innerHTML = window._pcalCalHtml({}, 2026, 8);
    ok('칸이 42개(6줄) — 2026-08',
       wrap2.querySelectorAll('.pcal-days > .pcal-d').length === 42);

    // 날짜가 제대로 들어갔나 (2026-02-01 은 일요일 → 앞 빈칸 0개)
    const nums = [].map.call(wrap.querySelectorAll('.pcal-days > .pcal-d'), d => d.textContent.trim());
    ok('2026-02 첫 칸이 1일 (앞 빈칸 없음)', nums[0] === '1');
    ok('2026-02 마지막 날이 28일', nums[27] === '28');
    ok('29번째 칸부터 빈칸', nums[28] === '');

    // 다른 달을 부르면 그 달의 onclick 이 박힌다 (종전엔 늘 이번 달이었다)
    const byDate = {}; byDate[2026*10000 + 3*100 + 10] = [{ id:'X', status:'active' }];
    const wrap3 = document.createElement('div');
    wrap3.innerHTML = window._pcalCalHtml(byDate, 2026, 3);
    ok('3월 칸의 onclick 이 3월을 가리킨다',
       /pcalOpenDay\(2026,3,10\)/.test(wrap3.innerHTML));

    // ── 가짜 호스트에 페이저를 건다 ─────────────────────────
    const host = document.createElement('div');
    host.style.cssText = 'position:fixed;left:0;top:0;width:320px;height:600px;z-index:99999;background:#000';
    host.innerHTML =
      '<div class="pcal-swipe"><div class="pcal-track">' +
        '<div class="pcal-pane">' + window._pcalCalHtml({}, 2026, 1) + '</div>' +
        '<div class="pcal-pane">' + window._pcalCalHtml({}, 2026, 2) + '</div>' +
        '<div class="pcal-pane">' + window._pcalCalHtml({}, 2026, 3) + '</div>' +
      '</div></div>' +
      '<div class="outside" style="height:80px">밖</div>';
    document.body.appendChild(host);
    window._pcalBindPager(host);
    window._pcalBindPager(host);   // 두 번 걸어도 한 번만 걸려야 한다

    const sw    = host.querySelector('.pcal-swipe');
    const track = host.querySelector('.pcal-track');
    const W     = sw.clientWidth;
    ok('스와이프 판의 폭이 잡힌다', W > 100);
    ok('트랙에 판이 셋', track.querySelectorAll('.pcal-pane').length === 3);

    // 판 셋의 높이가 같아야 한다 — 다르면 미는 중에 옆 달이 위아래로 어긋난다
    const hs = [].map.call(track.querySelectorAll('.pcal-pane'), e => e.getBoundingClientRect().height);
    ok('판 셋의 높이가 같다', hs[0] > 0 && Math.abs(hs[0]-hs[1]) < 1 && Math.abs(hs[1]-hs[2]) < 1);

    // 넘어간 달을 가로챈다 (진짜로 넘기면 화면이 통째로 다시 그려진다)
    const realStep = window.pcalStep;
    let steps = [];
    window.pcalStep = d => steps.push(d);

    const cell = track.querySelector('.pcal-pane .pcal-d');
    function mk(t, x, y){
      const e = new Event(t, { bubbles:true });
      const l = [{ clientX:x, clientY:y }];
      Object.defineProperty(e, 'touches',        { value: t === 'touchend' ? [] : l });
      Object.defineProperty(e, 'changedTouches', { value: l });
      return e;
    }
    const tx = () => {
      const m = /translate3d\(([-0-9.]+)px/.exec(track.style.transform || '');
      return m ? parseFloat(m[1]) : null;
    };

    // ── ③ 미는 동안 손끝을 따라오나 ─────────────────────────
    cell.dispatchEvent(mk('touchstart', 260, 300));
    host.dispatchEvent(mk('touchmove',  200, 302));
    const mid = tx();
    ok('미는 도중 트랙이 따라온다', mid !== null && Math.abs(mid - (-60 - W)) < 2);
    host.dispatchEvent(mk('touchmove', 160, 303));
    const mid2 = tx();
    ok('더 밀면 더 따라온다', mid2 !== null && mid2 < mid);
    host.dispatchEvent(mk('touchend', 160, 303));
    await sleep(600);
    ok('충분히 밀면 다음 달로 (+1)', JSON.stringify(steps) === '[1]');

    // ── ④-a 조금만 밀면 되돌아온다 ──────────────────────────
    steps = [];
    track.classList.remove('pcal-anim'); track.style.transform = '';
    cell.dispatchEvent(mk('touchstart', 260, 300));
    host.dispatchEvent(mk('touchmove',  240, 301));
    host.dispatchEvent(mk('touchend',   240, 301));
    await sleep(600);
    ok('조금만 밀면 안 넘어간다', steps.length === 0);
    ok('되돌아와 제자리(-W)', Math.abs(tx() - (-W)) < 2);

    // ── ④-b 짧아도 빠르게 튕기면 넘어간다 (플릭) ────────────
    steps = [];
    track.classList.remove('pcal-anim'); track.style.transform = '';
    cell.dispatchEvent(mk('touchstart', 100, 300));
    await sleep(16);
    host.dispatchEvent(mk('touchmove',  140, 301));
    host.dispatchEvent(mk('touchend',   140, 301));
    await sleep(600);
    ok('빠르게 튕기면 짧아도 이전 달로 (-1)', JSON.stringify(steps) === '[-1]');

    // ── ⑤ 세로 손짓은 넘겨준다 ──────────────────────────────
    steps = [];
    track.classList.remove('pcal-anim'); track.style.transform = '';
    cell.dispatchEvent(mk('touchstart', 260, 200));
    host.dispatchEvent(mk('touchmove',  254, 320));
    host.dispatchEvent(mk('touchend',   250, 400));
    await sleep(600);
    ok('세로로 끌면 달이 안 넘어간다', steps.length === 0);
    ok('세로일 때 트랙은 제자리', Math.abs(tx() - (-W)) < 2);

    // ── 달력 밖에서 끌면 무시 ───────────────────────────────
    steps = [];
    host.querySelector('.outside').dispatchEvent(mk('touchstart', 260, 300));
    host.dispatchEvent(mk('touchmove', 120, 302));
    host.dispatchEvent(mk('touchend',  120, 302));
    await sleep(400);
    ok('달력 밖에서 끌면 무시', steps.length === 0);

    // ── 민 직후의 클릭은 삼킨다 ─────────────────────────────
    steps = [];
    track.classList.remove('pcal-anim'); track.style.transform = '';
    cell.dispatchEvent(mk('touchstart', 260, 300));
    host.dispatchEvent(mk('touchmove',  150, 302));
    host.dispatchEvent(mk('touchend',   150, 302));
    ok('민 직후 _taamCalSwiped() true', window._taamCalSwiped() === true);
    await sleep(700);

    // ── 마우스(데스크톱)로도 넘어간다 ───────────────────────
    steps = [];
    track.classList.remove('pcal-anim'); track.style.transform = '';
    cell.dispatchEvent(new PointerEvent('pointerdown', { bubbles:true, clientX:260, clientY:300, pointerType:'mouse' }));
    host.dispatchEvent(new PointerEvent('pointermove', { bubbles:true, clientX:150, clientY:302, pointerType:'mouse' }));
    host.dispatchEvent(new PointerEvent('pointerup',   { bubbles:true, clientX:150, clientY:302, pointerType:'mouse' }));
    await sleep(600);
    ok('마우스로도 다음 달 (+1)', JSON.stringify(steps) === '[1]');

    // 터치 포인터는 중복으로 세지 않는다
    steps = [];
    track.classList.remove('pcal-anim'); track.style.transform = '';
    cell.dispatchEvent(new PointerEvent('pointerdown', { bubbles:true, clientX:260, clientY:300, pointerType:'touch' }));
    host.dispatchEvent(new PointerEvent('pointerup',   { bubbles:true, clientX:150, clientY:302, pointerType:'touch' }));
    await sleep(400);
    ok('touch 포인터는 무시(중복 방지)', steps.length === 0);

    window.pcalStep = realStep;
    host.remove();
    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : '=== 전부 통과 ==='));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
