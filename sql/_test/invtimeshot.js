// ═══════════════════════════════════════════════════════════════
// 초대 건의 방문 시각 — 화면마다 다르게 보이지 않는가 (2026-09-04)
// ═══════════════════════════════════════════════════════════════
//   「대시보드 예약에는 방문일·시간이 뜨는데 티켓 캘린더에는 안 뜬다」
//
//   초대(INV-·INVH-)로 나간 예약은 tickets.visit_time 이 비어 있는 일이
//   많다. 시각은 reservation_invites 에 있고, purchase_id 앞자리가 그
//   초대 id 의 앞 8글자다. 대시보드는 진작 이 보정을 하고 있었는데
//   티켓 캘린더에는 없었다 — 그래서 같은 예약이 화면마다 달라 보였다.
//
//   ① INV- · INVH- 의 열쇠를 제대로 뽑는가 ⭐ (자릿수가 다르다)
//   ② 초대가 아닌 건은 건드리지 않는가
//   ③ 없는 열쇠·빈 값에 무너지지 않는가
//   ④ 두 화면이 **같은 함수**를 쓰는가 ⭐ 갈라지면 이 버그가 다시 난다
//
// 실행: node sql/_test/invtimeshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const fs = require('fs');

(async () => {
  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  // ④ 소스에서 — 보정이 한 곳에만 있는가
  const src = fs.readFileSync('/home/user/taam-app/index.html', 'utf8');
  ok('보정 함수가 있다', src.indexOf('function taamInviteTimeMap') >= 0);
  // ⚠ 예전처럼 화면마다 따로 훑으면 또 갈라진다. 조회는 한 곳뿐이어야 한다.
  const scans = (src.match(/from\('reservation_invites'\)\s*\n?\s*\.select\('id, visit_time'/g) || []).length;
  ok('시각 조회가 한 곳뿐이다 ⭐ (' + scans + '곳)', scans === 1);
  // 캘린더와 대시보드가 둘 다 그 함수를 쓴다
  ok('캘린더가 그 함수를 쓴다 ⭐', /_tcalPurchases[\s\S]{0,600}taamInviteTimeMap/.test(src));
  ok('대시보드도 그 함수를 쓴다 ⭐', /_needT[\s\S]{0,400}taamInviteTimeMap/.test(src));

  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.route('**://fonts.g**', r => r.abort());
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const res = [];
    const ok = (n, c) => res.push((c ? 'OK   ' : 'FAIL ') + n);
    // 초대 id 가 'abcd1234-...' 라면 열쇠는 'abcd1234'
    const map = { 'abcd1234': '18:30', 'ffff0000': '12:00' };

    // ── ① 열쇠 뽑기 ⭐ INV- 는 4글자, INVH- 는 5글자 뒤부터다 ──
    ok('INV- 에서 뽑는다 ⭐',
       window.taamInviteTimeOf(map, 'INV-abcd1234-9999') === '18:30');
    ok('INVH- 에서 뽑는다 ⭐ (한 글자 더 길다)',
       window.taamInviteTimeOf(map, 'INVH-abcd1234-9999') === '18:30');
    ok('다른 초대는 다른 시각', window.taamInviteTimeOf(map, 'INV-ffff0000-1') === '12:00');

    // ── ② 초대가 아닌 건 ──
    ok('일반 구매는 건드리지 않는다', window.taamInviteTimeOf(map, 'taam-123456') === '');
    ok('수기(MAN-)도 아니다',        window.taamInviteTimeOf(map, 'MAN-abcd1234') === '');
    // ⚠ 「INV」로 시작만 하면 안 된다 — INVOICE- 같은 것이 섞이면 엉뚱한 시각이 붙는다
    ok('INVOICE- 는 초대가 아니다 ⭐', window.taamInviteTimeOf(map, 'INVOICE-abcd1234') === '');

    // ── ③ 무너지지 않는가 ──
    ok('없는 열쇠는 빈 값', window.taamInviteTimeOf(map, 'INV-00000000-1') === '');
    ok('빈 문자열도 안전', window.taamInviteTimeOf(map, '') === '');
    ok('null 도 안전',     window.taamInviteTimeOf(map, null) === '');
    ok('맵이 없어도 안전', window.taamInviteTimeOf(null, 'INV-abcd1234') === '');

    // ── ⑤ 매장 헤더의 시각 ⭐ ────────────────────────────────
    //   일정 없이 초대만 나간 날은 「시간 —」이었다. 정작 예약 줄에는
    //   시각이 적혀 있는데도 매장 시간을 모르는 것처럼 보였다 (9/11 슌지).
    window.restaurantDB = [{ id: 'R1', name: '슌지' }];
    window.ticketDB = [];
    window._tcalPurchases = [];
    window._tcalManual = [];
    window._tcalCapacity = [];
    // ⚠ _tcalDayGroups 는 **정규화된** 열쇠를 받는다 ('2026-9-11').
    //   원형('2026.09.11')을 그대로 넘기면 한 건도 안 걸린다.
    const RAW = '2026.09.11';
    const KEY = window._tcalDateKey(RAW);
    const inv = (t) => ({ restaurant_id:'R1', restaurant_name:'슌지', visit_date:RAW,
      visit_time:t, pax:2, status:'paid', invitee_user_id:'U1', total_amount:1700000, agency_fee:100000 });

    window._tcalInvites = [inv('20:00')];
    let g = window._tcalDayGroups(KEY)[0];
    ok('초대만 있어도 매장 시간이 뜬다 ⭐', g && g.time === '20:00');
    ok('예약 줄에도 그대로 있다', g && g.entries[0] && g.entries[0].time === '20:00');

    // ⚠ 시각이 여러 개면 하나로 뭉치지 않는다 — 없는 사실을 말하게 된다
    window._tcalInvites = [inv('18:00'), inv('20:00')];
    g = window._tcalDayGroups(KEY)[0];
    ok('시각이 여러 개면 안 적는다 ⭐', g && !g.time);
    ok('그때도 각 줄에는 남는다',
       g && g.entries.length === 2 && g.entries[0].time === '18:00');

    // 같은 시각이 여럿이면 그건 하나다
    window._tcalInvites = [inv('20:00'), inv('20:00')];
    g = window._tcalDayGroups(KEY)[0];
    ok('같은 시각 여러 건은 그 시각', g && g.time === '20:00');

    // 시각이 아예 없으면 비운다 (없는 것을 지어내지 않는다)
    window._tcalInvites = [inv('')];
    g = window._tcalDayGroups(KEY)[0];
    ok('시각이 없으면 비워 둔다 ⭐', g && !g.time);
    window._tcalInvites = [];

    // ── 조회 실패해도 화면이 죽지 않는다 ──
    window.sb = { from: () => ({ select: () => ({ limit: () =>
      Promise.resolve({ data: null, error: { message: '조회 실패' } }) }) }) };
    const m2 = await window.taamInviteTimeMap(true);
    ok('조회가 실패해도 빈 맵을 준다 ⭐', m2 && typeof m2 === 'object');
    ok('그래도 시각은 빈 값', window.taamInviteTimeOf(m2, 'INV-abcd1234') === '');
    return res;
  });

  [...out, ...r].forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = [...out, ...r].filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===`
                          : `=== 전부 통과 (${out.length + r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
