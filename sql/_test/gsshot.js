// ═══════════════════════════════════════════════════════════════
// 게스트 초대석 열기 — 어드민 화면 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
//   ① 상태를 **서버 값**으로 연다 (화면 캐시 아님)
//   ② 매장이 안 열렸으면 먼저 매장을 켜게 한다
//   ③ 이유·가격·수량 없이는 **서버를 안 부른다** ← 튕기면 다시 적어야 한다
//   ④ 「일반 판매」라고 안 적는가 · 이유가 손님에게 보인다고 적는가
//   ⑤ 닫아도 이미 산 사람의 자리는 그대로라고 말하는가
//   ⑥ SQL 을 안 돌렸으면 무엇을 해야 하는지 알려주는가
//
// 실행: node sql/_test/gsshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 900 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    document.getElementById('appWrapper').classList.add('ready');
    window.showToast = (a, b2, c) => { window.__toast = [a, b2, c]; };
    window.renderTicketList = () => {};
    window.restaurantDB = [{ id: 'R1', name: '스시 아라이' }];
    window.ticketDB = [{ id: 'TP1', rest: 'R1', date: '2027-06-06', time: '18:00', price: 250000 }];

    let RPC = [];
    const mk = (state) => ({
      rpc: (fn, a) => { RPC.push([fn, a]);
        if (state && state.__fail) return Promise.resolve({ data: null,
          error: { message: 'function public.taam_guest_seat_state does not exist' } });
        if (fn === 'taam_guest_seat_open')
          return Promise.resolve({ data: Object.assign({}, state, {
            open: true, reason: a.p_reason, price: a.p_price, qty: a.p_qty, sold: 0,
            left: a.p_qty }), error: null });
        if (fn === 'taam_guest_seat_close')
          return Promise.resolve({ data: Object.assign({}, state, { open: false }), error: null });
        return Promise.resolve({ data: state, error: null }); }
    });

    // ── ② 매장이 잠겨 있으면 ─────────────────────────────────
    window.sb = mk({ found: true, open: false, allowed: false, qty: 0, sold: 0 });
    RPC = [];
    await window.tuGuestSeat('TP1'); await sleep(250);
    ok('시트가 열린다', document.getElementById('gsSheet').style.display === 'flex');
    // ⚠ 화면 캐시가 아니라 서버 값으로 연다 — 다른 기기에서 바꿨을 수 있다
    ok('서버에 상태를 묻는다 ⭐',
       RPC.some(x => x[0] === 'taam_guest_seat_state' && x[1].p_ticket_product_id === 'TP1'));
    let bt = document.getElementById('gsBody').textContent;
    ok('매장이 잠겼다고 말한다', bt.indexOf('허용하지 않습니다') >= 0);
    ok('왜 기본이 잠김인지 적는다 ⭐', bt.indexOf('핵심 관계 매장') >= 0);
    ok('열 자리 입력칸을 안 보여준다 ⭐', !document.getElementById('gsReason'));
    ok('매장을 켜는 버튼이 있다',
       document.getElementById('gsFoot').textContent.indexOf('허용') >= 0);
    RPC = [];
    await window.gsAllow(true); await sleep(200);
    ok('매장 허용을 서버에 넘긴다',
       RPC.some(x => x[0] === 'taam_guest_seat_allow'
                  && x[1].p_rest_id === 'R1' && x[1].p_on === true));

    // ── ③ 열려 있는 매장, 닫힌 자리 ──────────────────────────
    window.sb = mk({ found: true, open: false, allowed: true, qty: 0, sold: 0, reason: null, price: null });
    await window.tuGuestSeat('TP1'); await sleep(250);
    bt = document.getElementById('gsBody').textContent;
    ok('닫혀 있다고 말한다', bt.indexOf('닫혀 있습니다') >= 0);
    ok('이유 칸이 있다', !!document.getElementById('gsReason'));
    ok('게스트가 칸이 있다', !!document.getElementById('gsPrice'));
    ok('수량 칸이 있다', !!document.getElementById('gsQty'));
    // ④ 서사가 화면에 적혀 있는가
    ok('이유가 손님에게 보인다고 적는다 ⭐', bt.indexOf('그대로 보입니다') >= 0);
    ok('이유 없으면 할인이 된다고 적는다 ⭐', bt.indexOf('그냥 할인') >= 0);
    ok('회원가를 참고로 보여준다', bt.indexOf('250,000원') >= 0);
    ok('두 가격을 나란히 안 보여준다고 적는다', bt.indexOf('멤버는 우대가') >= 0);
    ok('「일반 판매」라고 안 적는다 ⭐', bt.indexOf('일반 판매') < 0);

    // 빈 채로 누르면 서버를 안 부른다
    RPC = [];
    await window.gsOpen(); await sleep(150);
    ok('빈 채로는 서버를 안 부른다 ⭐', !RPC.some(x => x[0] === 'taam_guest_seat_open'));
    ok('무엇이 비었는지 알려준다', document.getElementById('gsErr').textContent.indexOf('이유') >= 0);

    // 이유만 채우면 여전히 막힌다
    document.getElementById('gsReason').value = '셰프의 요청으로';
    RPC = [];
    await window.gsOpen(); await sleep(150);
    ok('이유만으로는 안 된다', !RPC.some(x => x[0] === 'taam_guest_seat_open'));

    // 다 채우면 보낸다
    document.getElementById('gsPrice').value = '300,000';
    document.getElementById('gsQty').value = '2';
    RPC = [];
    await window.gsOpen(); await sleep(250);
    const call = RPC.filter(x => x[0] === 'taam_guest_seat_open')[0];
    ok('서버에 연다', !!call);
    ok('이유를 넘긴다', call && call[1].p_reason === '셰프의 요청으로');
    ok('콤마를 떼고 숫자로 넘긴다 ⭐', call && call[1].p_price === 300000);
    ok('수량을 넘긴다', call && call[1].p_qty === 2);
    ok('열렸다고 알려준다', window.__toast && window.__toast[1] === '게스트석을 열었습니다');
    bt = document.getElementById('gsBody').textContent;
    ok('열려 있다고 다시 그린다', bt.indexOf('열려 있습니다') >= 0);
    ok('몇 석 나갔는지 보여준다', bt.indexOf('0/2석') >= 0);

    // ── ⑤ 이미 산 사람이 있으면 ──────────────────────────────
    window.sb = mk({ found: true, open: true, allowed: true, qty: 2, sold: 1,
                     reason: '개점 10주년을 기념해', price: 300000 });
    await window.tuGuestSeat('TP1'); await sleep(250);
    bt = document.getElementById('gsBody').textContent;
    ok('이미 산 사람 수를 보여준다', bt.indexOf('1명') >= 0);
    ok('닫아도 그 자리는 그대로라고 말한다 ⭐', bt.indexOf('그대로입니다') >= 0);
    window.confirm = () => true;
    RPC = [];
    await window.gsClose(); await sleep(200);
    ok('닫기를 서버에 넘긴다', RPC.some(x => x[0] === 'taam_guest_seat_close'));
    ok('이유·가격은 안 지운다고 말한다 ⭐',
       window.__toast && String(window.__toast[2]).indexOf('그대로') >= 0);

    // ── ⑥ SQL 을 안 돌렸을 때 ────────────────────────────────
    window.sb = mk({ __fail: true });
    await window.tuGuestSeat('TP1'); await sleep(250);
    ok('무엇을 해야 하는지 알려준다 ⭐',
       document.getElementById('gsBody').textContent.indexOf('guest_seat.sql') >= 0);
    ok('열 수 있는 버튼을 안 준다', document.getElementById('gsFoot').textContent.trim() === '');

    window.tuGuestSeatClose(); await sleep(80);
    ok('닫힌다', document.getElementById('gsSheet').style.display === 'none');
    ok('세로 제스처만 받는다',
       getComputedStyle(document.getElementById('gsSheet')).touchAction === 'pan-y');
    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
