const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

    // ── 예약 줄: 「외 1명」이 아니라 총 인원 ──
    window._tbRows = [];
    const row = _rvRow({ id:'t1', purchase_id:'P-1', buyer_name:'김진현', party_size:2,
      price:180000, status:'active', restaurant_name:'타카미츠',
      reservation_date:'2026.10.03', visit_time:'18:00', _d:'2026-10-03', _m:1080, extra_data:{} }, false);
    ok('예약 줄에 「외」가 없다', row.indexOf('외 ') < 0);
    ok('예약 줄에 총 인원 2명', row.indexOf('김진현 2명') >= 0);
    const row1 = _rvRow({ id:'t2', purchase_id:'P-2', buyer_name:'홍길동', party_size:1,
      price:1000, status:'active', restaurant_name:'가', reservation_date:'2026.10.03',
      visit_time:'18:00', _d:'2026-10-03', _m:1080, extra_data:{} }, false);
    ok('1명도 그대로 1명', row1.indexOf('홍길동 1명') >= 0);

    const trow = _tbRow({ id:'t3', purchase_id:'P-3', buyer_name:'이하늘', party_size:4,
      price:9000, status:'active', restaurant_name:'나', reservation_date:'2026.10.03',
      visit_time:'19:00', _d:'2026-10-03', _m:1140, extra_data:{} }, false, false);
    ok('오늘 화면 줄도 총 인원 4명', trow.indexOf('이하늘 4명') >= 0 && trow.indexOf('외 ') < 0);

    // ── 명부: 구매 횟수 · 이용 제한 ──
    window._tbRows = [
      { user_id:'u1', status:'active',    purchase_id:'A', price:1, extra_data:{} },
      { user_id:'u1', status:'completed', purchase_id:'B', price:1, extra_data:{} },
      { user_id:'u1', status:'cancelled', purchase_id:'C', price:1, extra_data:{} },
      { user_id:'u2', status:'active',    purchase_id:'D', price:1, extra_data:{} }
    ];
    window._mbBuyMap = null; window._mbBuySig = null;
    ok('u1 구매 2회 (취소 제외)', _mbBuyCount('u1') === 2);
    ok('u2 구매 1회',            _mbBuyCount('u2') === 1);
    ok('u3 구매 0회',            _mbBuyCount('u3') === 0);

    const today = _taamTodayKst();
    const past = String(parseInt(today, 10) - 10000);
    const future = String(parseInt(today, 10) + 10000);
    window._acBans = [
      { user_id:'u1', reason:'노쇼 3회', banned_at:'2026-01-01', until:null },
      { user_id:'u2', reason:'지남',     banned_at:'2026-01-01', until:past },
      { user_id:'u4', reason:'기간제',   banned_at:'2026-01-01', until:future }
    ];
    ok('u1 무기한 제한 → 걸림',     !!_mbBanOf('u1'));
    ok('u2 만료된 제한 → 안 걸림',  !_mbBanOf('u2'));
    ok('u4 기한 남은 제한 → 걸림',  !!_mbBanOf('u4'));
    ok('u3 제한 없음',              !_mbBanOf('u3'));

    window._mbRows = [
      { id:'u1', display_name:'김도윤', phone:'010-1111-2255', membership_tier:'T', created_at:'2026-01-01' },
      { id:'u2', display_name:'박서준', phone:'010-2222-4417', membership_tier:'T', created_at:'2026-01-02' },
      { id:'u3', display_name:'정민서', phone:'010-3333-1188', membership_tier:'T', created_at:'2026-01-03' }
    ];
    const mr = _mbRow(window._mbRows[0]);
    ok('명부에 구매 2회',        mr.indexOf('구매 2회') >= 0);
    ok('명부에 이용 제한 배지',  mr.indexOf('mb-ban') >= 0 && mr.indexOf('노쇼 3회') >= 0);
    ok('제한 줄에 ban 클래스',   mr.indexOf('mb-row ban') >= 0);
    const mr3 = _mbRow(window._mbRows[2]);
    ok('구매 없는 회원은 「구매 없음」', mr3.indexOf('구매 없음') >= 0);
    ok('제한 없는 줄엔 배지 없음',      mr3.indexOf('mb-ban') < 0);

    ok('ban 필터가 u1 만 통과', _mbPass(window._mbRows[0], 'ban') && !_mbPass(window._mbRows[1], 'ban'));
    ok('buy 필터가 u1·u2 통과', _mbPass(window._mbRows[0], 'buy') && _mbPass(window._mbRows[1], 'buy')
                                && !_mbPass(window._mbRows[2], 'buy'));

    // ── 티켓 카드: 공개 대상 인원수 자리 ──
    const tk = _tkbRow({ id:'tk1', date:'2026.11.19', totalPax:8, status:'active', minTier:'M' });
    ok('티켓 줄에 data-tkb-aud', tk.indexOf('data-tkb-aud="tk1"') >= 0);
    ok('인원수 자리(em) 있음',   /<em><\/em>/.test(tk));

    // 서버가 준 수를 DOM 에 채운다
    const host = document.createElement('div'); host.id = '__tkbProbe';
    host.innerHTML = tk;
    const real = document.getElementById('tkbBody');
    const holder = real || (function(){ const d=document.createElement('div'); d.id='tkbBody'; document.body.appendChild(d); return d; })();
    const keep = holder.innerHTML;
    holder.innerHTML = tk;
    window._tkbAudN = { tk1: 47 };
    _tkbPaintAud();
    ok('47명이 채워진다', holder.querySelector('[data-tkb-aud="tk1"] em').textContent === '47명');
    window._tkbAudN = {};
    _tkbPaintAud();
    ok('모르는 수는 비운다', holder.querySelector('[data-tkb-aud="tk1"] em').textContent === '');
    holder.innerHTML = keep;

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
