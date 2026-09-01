const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });   // 폰 폭
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    window.ticketDB = [{ id:'tp1', time:'20:00' }];
    const R = { id:'t1', purchase_id:'P-1', buyer_name:'이창훈', party_size:2, price:1800000,
                status:'active', restaurant_name:'메이노', visit_time:'20:00',
                reservation_date:'2026.09.10', _d:'2026-09-10', _m:1200, extra_data:{} };

    // ⚠ 붙지 않은 노드는 getComputedStyle 이 빈 값을 준다 — 먼저 문서에 넣는다
    const d = document.createElement('div');
    d.style.cssText = 'width:390px;padding:0 14px;box-sizing:border-box';
    document.body.appendChild(d);
    d.innerHTML = _rvRow(R, false);
    const card = d.querySelector('.tb-rsv');

    // ── 두 층으로 나뉘었나 ──
    const op = card.querySelector('.rsv-op'), wh = card.querySelector('.rsv-when'), cu = card.querySelector('.rsv-cu');
    ok('운영 층이 있다 (매장 · 상태)', !!op && op.querySelector('.rest').textContent === '메이노');
    ok('시간·인원 줄이 있다', !!wh && wh.textContent.replace(/\s/g,'') === '20:00·2명');
    ok('정산 층이 있다 (이름 · 금액)', !!cu
       && cu.querySelector('.who').textContent === '이창훈'
       && /1,800,000/.test(cu.querySelector('.amt').textContent));
    ok('층 순서 = 운영 → 시간·인원 → 정산',
       (op.compareDocumentPosition(wh) & Node.DOCUMENT_POSITION_FOLLOWING) &&
       (wh.compareDocumentPosition(cu) & Node.DOCUMENT_POSITION_FOLLOWING));
    ok('정산 층은 선으로 끊었다', getComputedStyle(cu).borderTopWidth !== '0px');
    ok('상태 배지는 운영 층 오른쪽', op.querySelector('.tb-pill') === op.lastElementChild);
    ok('이름과 금액이 한 줄 좌우 끝', getComputedStyle(cu).justifyContent === 'space-between');

    // ── 시간이 없으면 ──
    const R2 = Object.assign({}, R, { visit_time:'', ticket_product_id:'' });
    d.innerHTML = _rvRow(R2, false);
    ok('시간 모르면 「시간 미정」', /시간 미정/.test(d.querySelector('.rsv-when').textContent));
    ok('그래도 인원은 나온다', /2명/.test(d.querySelector('.rsv-when').textContent));

    // ── 금액이 0 이면 ──
    const R3 = Object.assign({}, R, { price:0 });
    d.innerHTML = _rvRow(R3, false);
    ok('금액 0 이면 — 로', d.querySelector('.rsv-cu .amt.no').textContent === '—');

    // ── 취소는 매장에 줄 ──
    const R4 = Object.assign({}, R, { status:'cancelled' });
    d.innerHTML = _rvRow(R4, false);
    ok('취소는 매장 이름에 줄',
       getComputedStyle(d.querySelector('.tb-rsv.cx .rest')).textDecorationLine === 'line-through');

    // ── 오늘 화면도 같은 카드 + 날짜 ──
    window._tbState = { off:0, filter:'all', open:null, find:'', findOn:false };
    d.innerHTML = _tbRow(R, true, null);
    ok('오늘 화면도 같은 두 층', !!d.querySelector('.rsv-op') && !!d.querySelector('.rsv-cu'));
    ok('검색 결과엔 날짜가 붙는다', /9월 10일/.test(d.querySelector('.rsv-when').textContent));
    ok('두 화면이 같은 함수를 쓴다',
       /_tbCard\(r/.test(String(_rvRow)) && /_tbCard\(r/.test(String(_tbRow)));

    // ── 폰 폭에서 넘치지 않나 ──
    const host = document.createElement('div');
    host.style.cssText = 'width:390px;padding:0 14px;box-sizing:border-box';
    host.innerHTML = _rvRow(Object.assign({}, R, {
      restaurant_name:'아주 아주 긴 레스토랑 이름이 들어간 매장 이름',
      buyer_name:'이름이아주아주긴회원님입니다' }), false);
    document.body.appendChild(host);
    const c2 = host.querySelector('.tb-rsv');
    ok('긴 이름도 카드 밖으로 안 삐져나온다', c2.scrollWidth <= c2.clientWidth + 1);
    ok('매장 이름은 …으로 자른다', getComputedStyle(c2.querySelector('.rest')).textOverflow === 'ellipsis');
    host.remove(); d.remove();

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
