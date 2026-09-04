// ═══════════════════════════════════════════════════════════════
// 「예약 · 이번 달」 — 달력 말고 명단 (2026-09-04)
// ═══════════════════════════════════════════════════════════════
//   대시보드의 「예약 · 이번 달」을 누르면 달력이 떴다. 달력은 「언제 자리가
//   있나」에 답하는 그림이라, 「이번 달에 누가 어디에 몇 시에 몇 명 오나」에는
//   답하지 못한다. 날을 하나씩 눌러 서른 번 확인해야 했다.
//
//   ① 카드가 명단을 연다 ⭐ (달력이 아니라)
//   ② 누가 · 어디 · 몇 시 · 몇 명이 한 줄에 있다 ⭐
//   ③ 예약 · 초대 대기 · 초대 완료가 갈라진다 ⭐
//   ④ 초대 대기가 목록에 있다 ⭐ — tickets 에 없어서 여태 안 보이던 것
//   ⑤ 결제된 초대를 두 번 세지 않는다 ⭐ 한 사람이 두 번 오면 안 된다
//   ⑥ 이 달 것만 — 옆 달은 안 섞인다
//   ⑦ 초대 대기를 못 읽어도 명단은 뜬다 ⭐ 조회 하나가 화면을 통째로 죽이지 않게
//
// 실행: node sql/_test/rvlistshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).slice(0, 180)));
  await p.route('**://fonts.g**', r => r.abort());
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const res = [];
    const ok = (n, c) => res.push((c ? 'OK   ' : 'FAIL ') + n);
    const wait = ms => new Promise(r => setTimeout(r, ms));

    window._currentRole = 'superadmin';
    document.getElementById('appWrapper').classList.add('ready');
    window._isSuperAdmin = () => true;

    // ── 이 달의 가짜 예약 ─────────────────────────────────────
    //   ⚠ 이 앱은 날짜를 **'2026.09.20'** 으로 저장한다 (_dParseDate 는 '.' 로
    //     쪼갠다). ISO 의 '-' 로 픽스처를 만들면 파싱이 통째로 null 이 되어
    //     초대 대기가 한 건도 안 뜬다 — 짐작하지 말고 라이브 모양을 베낀다.
    const t = new Date();
    const ym = t.getFullYear() + '-' + String(t.getMonth() + 1).padStart(2, '0');   // 열쇠(_d)는 '-'
    const dot = ym.replace('-', '.');                                               // 저장값은 '.'
    const nextM = new Date(t.getFullYear(), t.getMonth() + 1, 1);
    const nym = nextM.getFullYear() + '-' + String(nextM.getMonth() + 1).padStart(2, '0');
    const tk = (pid, day, time, pax, who, rest, extra) => Object.assign({
      id: pid, purchase_id: pid, restaurant_id: 'R1', restaurant_name: rest,
      reservation_date: ym + '-' + day, visit_time: time, party_size: pax,
      price: 1400000, status: 'active', buyer_name: who, extra_data: {},
      _d: ym + '-' + day, _m: parseInt(time, 10) * 60
    }, extra || {});

    // ⑤ 결제된 초대는 tickets 에 INV- 로 이미 있다. reservation_invites 에서
    //    또 읽으면 두 번 세진다 — 그래서 status='sent' 만 읽는지 확인한다.
    //   ⚠ 가짜 sb 는 **콘솔을 연 뒤에** 끼운다. openAdmin 이 다른 조회를
    //     하는데, 그것까지 흉내 내려다 보면 테스트가 앱을 다시 짜게 된다.
    let askedStatus = null;
    const fakeSb = (rows, err) => ({ from: () => {
      const chain = {
        select: () => chain, order: () => chain, limit: () => Promise.resolve({ data: rows, error: err || null }),
        maybeSingle: () => Promise.resolve({ data: null, error: null }),
        single: () => Promise.resolve({ data: null, error: null }),
        eq: (col, v) => { askedStatus = col + '=' + v; return chain; },
        in: () => Promise.resolve({ data: [{ id:'U9', display_name:'최유진' }], error: null })
      };
      return chain;
    } });
    const INVITES = [
      { id:'e1e1e1e1-0000-4000-8000-000000000001', restaurant_id:'R1', restaurant_name:'키츠네',
        visit_date: dot + '.20', visit_time:'19:30', pax:3, status:'sent',
        invitee_user_id:'U9', total_amount:2100000,
        created_at:new Date(Date.now() - 6 * 3600 * 1000).toISOString(),
        ticket_product_id:'TP1' },
    ];

    // ── ① 카드가 명단을 연다 ⭐ ──────────────────────────────
    //   ⚠ 가짜 예약은 **콘솔이 다 열린 뒤에** 심는다. openAdmin 이 대시보드를
    //     띄우면서 _tbLoad() 를 돌리는데, 여기선 네트워크가 없어 _tbRows 가
    //     [] 로 덮인다. 먼저 심으면 통째로 지워져 「아무것도 안 나오는」
    //     테스트가 된다 — 처음에 그렇게 재서 13건이 거짓으로 실패했다.
    openAdmin(); await wait(600);
    window._tbRows = [
      tk('taam-1001',   '11', '20:00', 2, '이창훈', '슌지'),          // 직접 구매
      tk('INV-abcd1234-1', '18', '18:30', 4, '김민수', '스시사이토'),  // 초대 완료
      tk('taam-1002',   '25', '19:00', 2, '박지현', '나리사와', { status:'cancelled' }), // 취소
      tk('taam-9999',   '05', '12:00', 2, '옆달손님', '슌지', { _d: nym + '-05',
          reservation_date: nym + '-05' }),                            // 옆 달
    ];
    window.sb = fakeSb(INVITES);
    await rvOpenMonthList(); await wait(500);

    ok('예약 화면이 열렸다', getComputedStyle(document.getElementById('rvScreen')).display !== 'none');
    ok('명단 모드다 ⭐ (달력이 아니라)', window._rvState.view === 'list');
    const body = () => document.getElementById('rvBody').innerHTML;
    ok('달력이 안 그려졌다 ⭐', body().indexOf('rv-cal') < 0);
    ok('status=sent 만 읽는다 ⭐ (' + askedStatus + ')', askedStatus === 'status=sent');

    // ── ② 누가 · 어디 · 몇 시 · 몇 명 ⭐ ─────────────────────
    const txt = document.getElementById('rvBody').textContent;
    ok('누가 — 이름이 있다 ⭐', txt.indexOf('이창훈') >= 0);
    ok('어디 — 매장이 있다 ⭐', txt.indexOf('슌지') >= 0);
    ok('몇 시 — 시각이 있다 ⭐', txt.indexOf('20:00') >= 0);
    ok('몇 명 — 인원이 있다 ⭐', txt.indexOf('2명') >= 0);

    // ── ③④ 갈래 ⭐ ──────────────────────────────────────────
    ok('「예약」이 세어진다 ⭐',      /1[\s\S]{0,60}예약/.test(body()));
    ok('「초대 대기」가 세어진다 ⭐', txt.indexOf('초대 대기') >= 0);
    ok('「초대 완료」가 세어진다 ⭐', txt.indexOf('초대 완료') >= 0);
    ok('초대 대기 손님이 명단에 있다 ⭐ (tickets 에 없는 건)', txt.indexOf('최유진') >= 0);
    ok('그 손님의 매장·시각도 있다', txt.indexOf('키츠네') >= 0 && txt.indexOf('19:30') >= 0);
    ok('만료까지 남은 시간을 적는다 ⭐', /만료까지 \d+시간/.test(txt));

    // ── ⑤ 두 번 세지 않는다 ⭐ ──────────────────────────────
    const cnt = (s, w) => s.split(w).length - 1;
    ok('초대 완료 손님이 한 번만 ⭐', cnt(txt, '김민수') === 1);
    ok('전체 살아있는 예약은 3건 ⭐ (예약1 + 초대완료1 + 대기1)',
       /3건 · 9명/.test(document.getElementById('rvCount').textContent));
    // ⚠ 머리줄이 아래 타일과 **같은 것**을 세야 한다. 종전엔 티켓만 세서
    //   「3건」이라 써 놓고 카드가 다섯 장 보였다.
    ok('머리줄도 같은 숫자를 말한다 ⭐',
       /3건 · 9명/.test(document.getElementById('rvMon').textContent));

    // ── ⑥ 옆 달은 안 섞인다 ─────────────────────────────────
    ok('옆 달 예약은 안 나온다 ⭐', txt.indexOf('옆달손님') < 0);

    // ── 갈래로 걸러 보기 ────────────────────────────────────
    rvSetKind('wait'); await wait(120);
    const w = document.getElementById('rvBody').textContent;
    ok('「초대 대기」만 남는다 ⭐', w.indexOf('최유진') >= 0 && w.indexOf('이창훈') < 0);
    rvSetKind('buy'); await wait(120);
    const bt = document.getElementById('rvBody').textContent;
    ok('「예약」만 남는다 ⭐', bt.indexOf('이창훈') >= 0 && bt.indexOf('최유진') < 0);
    ok('초대 완료도 빠진다 ⭐ (예약과 다른 갈래다)', bt.indexOf('김민수') < 0);
    rvSetKind('all'); await wait(120);

    // ── 달력으로 돌아갈 수 있다 ─────────────────────────────
    await rvSetView('cal'); await wait(300);
    ok('달력으로 돌아간다 ⭐', document.getElementById('rvBody').innerHTML.indexOf('rv-cal') >= 0);
    await rvSetView('list'); await wait(300);
    ok('다시 명단으로', document.getElementById('rvBody').innerHTML.indexOf('rv-cal') < 0);

    // ── ⑦ 초대 조회가 실패해도 명단은 뜬다 ⭐ ────────────────
    window.sb = fakeSb(null, { message:'조회 실패' });
    window._rvPending = null;
    await rvSetView('list'); await wait(400);
    const f = document.getElementById('rvBody').textContent;
    ok('조회가 실패해도 티켓 예약은 보인다 ⭐', f.indexOf('이창훈') >= 0);
    ok('그때 화면이 비지 않는다 ⭐', f.indexOf('이 달에는 예약이 없습니다') < 0);
    return res;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
