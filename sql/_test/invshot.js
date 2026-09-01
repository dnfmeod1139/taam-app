const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    window.ticketDB = [];
    window._dParseDate = s => { const m = String(s).match(/(\d{4})\.(\d{2})\.(\d{2})/);
      return m ? new Date(+m[1], +m[2]-1, +m[3]) : null; };

    const tickets = [
      // 상품 없이 보낸 초대 — 초대장에만 시각이 있다
      { id:'a', purchase_id:'INV-abcd1234-999', status:'active', visit_time:'',
        reservation_date:'2026.09.11', party_size:2, buyer_name:'이창훈', price:1700000, extra_data:{} },
      // 초대장에도 시각이 없는 건
      { id:'b', purchase_id:'INV-99999999-1', status:'active', visit_time:'',
        reservation_date:'2026.09.12', party_size:1, buyer_name:'홍길동', price:1, extra_data:{} },
      // 일반 구매 — 손대지 않는다
      { id:'c', purchase_id:'P-1', status:'active', visit_time:'18:30',
        reservation_date:'2026.09.13', party_size:2, buyer_name:'김철수', price:1, extra_data:{} }
    ];
    const invites = [{ id:'abcd1234-0000-0000', visit_time:'19:00' }];

    window.sb = { from: (t) => ({
      select: (cols, opt) => {
        const mk = (data) => ({ data, error: null });
        const chain = {
          order: () => chain, limit: async () => mk(t === 'tickets' ? tickets : invites),
          in: async () => mk([]),
          eq: () => chain, maybeSingle: async () => mk(null)
        };
        return chain;
      }
    })};

    window._tbRows = null;
    await _tbLoad();
    const by = {}; (_tbRows||[]).forEach(r => by[r.id] = r);
    ok('세 건 다 살아 있다', Object.keys(by).length === 3);
    ok('상품 없는 초대도 초대장 시각으로 채워진다 (19:00)', _tbTime(by.a) === '19:00');
    ok('그 건의 정렬값도 19:00 기준', by.a._m === 19*60);
    ok('초대장에도 없으면 그대로 빈 값', _tbTime(by.b) === '');
    ok('일반 구매는 손대지 않는다', _tbTime(by.c) === '18:30');

    // 조회가 실패해도 화면은 그대로
    window.sb = { from: (t) => ({ select: () => ({
      order: () => ({ limit: async () => ({ data: t === 'tickets' ? tickets : null,
                                            error: t === 'tickets' ? null : { message:'boom' } }) }),
      in: async () => ({ data: [], error: null })
    })})};
    window._tbRows = null;
    await _tbLoad();
    ok('초대장 조회가 실패해도 예약은 다 뜬다', (_tbRows||[]).length === 3);

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
