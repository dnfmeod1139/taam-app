// ═══════════════════════════════════════════════════════════════
// 멤버십 화면 · 심사 신청 — 앱 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
// 여기서 보는 것
//   ① 화면이 1,125만 단일 등급으로만 말하는가 (315만이 안 보이는가)
//   ② 바로 결제하는 길이 정말 없는가  ← 화면은 1,125만인데 버튼은 315만을
//      태우고 있었다. 그 버튼이 다시 살아나면 돈이 어긋난다
//   ③ 심사 신청에 **가격이 한 글자도 없는가**  ← 스펙의 핵심
//   ④ 안 채우고 보내지 못하는가 / 서버에 무엇을 넘기는가
//   ⑤ 이미 낸 사람에게 두 번 쓰게 하지 않는가
//   ⑥ KO·EN·JA 가 다 있는가
//
// 실행: node sql/_test/mshipshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    document.getElementById('appWrapper').classList.add('ready');

    let rpc = [];
    window.sb = {
      rpc: (fn, a) => { rpc.push([fn, a]);
        if (fn === 'taam_mship_my_application') return Promise.resolve({ data: null, error: null });
        if (fn === 'taam_mship_settings') return Promise.resolve({ data: {
          deposit_amount: 10125000, annual_fee: 1270000,
          annual_fee_note: '금액 확정 전', guest_days: 90 }, error: null });
        if (fn === 'taam_guest_state') return Promise.resolve({ data: null, error: null });
        return Promise.resolve({ data: { ok: true, already: false, id: 'x' }, error: null }); },
      from: () => ({ select: () => ({ eq: () => ({ maybeSingle: () =>
        Promise.resolve({ data: { capacity: 33, taken: 28 }, error: null }) }) }) })
    };

    // ── ① 화면 ───────────────────────────────────────────────
    window.openMshipScreen(); await sleep(300);
    const scr = document.getElementById('mshipScreen');
    ok('멤버십 화면이 열린다', scr.style.display === 'flex');
    const txt = scr.textContent;
    // ⚠ 금액은 설정값에서 온다. 연회비를 127만으로 넣었으니 총액은 1,139.5만이어야 한다.
    ok('예치금을 설정값에서 읽는다 ⭐', txt.indexOf('10,125,000원') >= 0);
    ok('연회비를 설정값에서 읽는다 ⭐', txt.indexOf('1,270,000원') >= 0);
    ok('총액을 서버 값으로 더한다 ⭐',  txt.indexOf('11,395,000원') >= 0);
    ok('미확정이라고 적어 준다',       txt.indexOf('금액 확정 전') >= 0);
    // 퍼센트 문구는 전면 금지 — 예치금은 적립이 아니라 맡아 두는 돈이다
    ok('90%·10% 가 없다 ⭐', !/9\s*0\s*%|1\s*0\s*%/.test(txt));
    ok('금액이 번역에 안 박혀 있다 ⭐',
       ['ko','en','ja'].every(L => !/11,250,000|10,125,000/.test(JSON.stringify(window.TRANSLATIONS[L].membership))));
    ok('연회비는 소멸이라고 말한다', txt.indexOf('환불되지 않습니다') >= 0);
    ok('사용 기한이 없다고 말한다',  txt.indexOf('사용 기한은 없습니다') >= 0);
    ok('12월 28일 연장을 말한다',    txt.indexOf('12월 28일') >= 0);
    ok('남은 예치금 전액 환불을 말한다', txt.indexOf('전액 환불') >= 0);
    ok('단일 등급이라고 말한다',     txt.indexOf('단일 등급') >= 0);
    // 315만은 T 등급 카드에만 남아 있고 그 카드는 숨어 있다
    const tCard = document.querySelector('.mship-card.t');
    ok('T 카드는 숨어 있다', !!tCard && getComputedStyle(tCard).display === 'none');
    ok('보이는 곳에 315만이 없다 ⭐',
       Array.from(scr.querySelectorAll('*')).filter(el =>
         el.children.length === 0 &&
         (el.textContent || '').indexOf('3,150,000') >= 0 &&
         el.offsetParent !== null).length === 0);

    // ── ② 바로 결제하는 길 ───────────────────────────────────
    const payBtn = document.getElementById('mshipCtaBtn');
    ok('결제 버튼이 숨어 있다 ⭐', !!payBtn && getComputedStyle(payBtn).display === 'none');
    ok('결제 코드는 남아 있다 (오퍼에서 쓴다)', typeof window.openMembershipPay === 'function');
    const applyBtn = document.getElementById('mshipApplyBtn');
    ok('대신 「심사 신청」이 있다', !!applyBtn && getComputedStyle(applyBtn).display !== 'none');

    // 잔여석 — 어드민이 정한 값을 읽어 적는다
    ok('잔여석을 읽어 적는다',
       document.getElementById('mshipSeatsLeft').textContent.indexOf('5') >= 0);

    // ── ③ 심사 신청 — 가격이 한 글자도 없어야 한다 ────────────
    rpc = [];
    await window.openMshipApply(); await sleep(200);
    const sheet = document.getElementById('mshipApply');
    ok('심사 신청 시트가 열린다', sheet.style.display === 'flex');
    const at = sheet.textContent;
    // ⚠ 「200만원 이상」은 손님 **본인의 지출**을 묻는 선택지다 — 우리 가격이 아니다.
    //   여기서 나오면 안 되는 건 멤버십 금액 그 자체다.
    ok('멤버십 금액이 한 글자도 없다 ⭐',
       !/11,250,000|10,125,000|1,125,000|3,150,000|1,?125만|1,?012\.5만|112\.5만/.test(at));
    ok('정원 33인을 말한다', at.indexOf('33') >= 0);
    ok('개별 심사를 말한다', at.indexOf('개별 심사') >= 0);
    ok('질문 다섯 개', sheet.querySelectorAll('.mapl-f').length === 7);   // 이름 + 5문항 + 연락처
    ok('일본 방문 횟수를 묻는다', at.indexOf('일본 방문') >= 0);
    ok('지출 규모를 묻는다',      at.indexOf('디너 지출') >= 0);
    ok('기억에 남는 곳을 묻는다', at.indexOf('기억에 남는') >= 0);
    ok('이미 낸 신청이 있는지 먼저 본다',
       rpc.some(x => x[0] === 'taam_mship_my_application'));

    // ── ④ 안 채우면 못 보낸다 ────────────────────────────────
    rpc = [];
    await window.mshipApplySubmit(); await sleep(120);
    ok('빈 채로는 서버를 안 부른다 ⭐',
       !rpc.some(x => x[0] === 'taam_mship_apply'));
    ok('무엇이 비었는지 알려준다',
       !!document.querySelector('#maplErr .mapl-err'));

    // 채워서 보낸다
    document.getElementById('maplName').value = '김우종';
    document.getElementById('maplPhone').value = '010-3333-4444';
    window.mshipApplyPick('visits', 'a'); await sleep(60);
    window.mshipApplyPick('plan', 'a');   await sleep(60);
    window.mshipApplyPick('spend', 'a');  await sleep(60);
    document.getElementById('mapl_who').value = '40대 · 사업가';
    document.getElementById('mapl_places').value = '스기타 / 사이토 / 아라이';
    // 고른 답이 다시 그려도 살아 있는가 (중간에 날아가면 다시 쓰게 된다)
    ok('고른 답이 다시 그려도 남는다',
       document.querySelectorAll('.mapl-opt.on').length === 3);

    rpc = [];
    await window.mshipApplySubmit(); await sleep(200);
    const call = rpc.filter(x => x[0] === 'taam_mship_apply')[0];
    ok('서버에 신청을 넘긴다', !!call);
    ok('이름·연락처를 넘긴다',
       call && call[1].p_name === '김우종' && call[1].p_phone === '010-3333-4444');
    ok('출처가 app', call && call[1].p_source === 'app');
    // 고른 값만이 아니라 **그때 보여준 문장**도 같이 — 나중에 선택지를 고쳐도
    // 옛 신청서가 무엇을 뜻했는지 읽힌다
    ok('답에 그때의 문장을 함께 넘긴다 ⭐',
       call && call[1].p_answers.visits.v === 'a'
            && call[1].p_answers.visits.label.indexOf('3회') >= 0
            && call[1].p_answers.visits.q.indexOf('일본 방문') >= 0);
    ok('직접 쓴 답도 넘긴다',
       call && call[1].p_answers.places.v.indexOf('스기타') >= 0);
    ok('보내고 나면 접수됐다고 말한다',
       document.querySelector('#maplBody .mapl-done'));
    ok('보내고 나면 버튼이 사라진다',
       document.getElementById('maplGo').style.display === 'none');

    // ── ⑤ 이미 낸 사람 ───────────────────────────────────────
    window.closeMshipApply(); await sleep(80);
    window.sb.rpc = (fn) => fn === 'taam_mship_my_application'
      ? Promise.resolve({ data: { status: 'screening' }, error: null })
      : Promise.resolve({ data: {}, error: null });
    await window.openMshipApply(); await sleep(250);
    ok('이미 심사 중이면 두 번 안 쓰게 한다 ⭐',
       !!document.querySelector('#maplBody .mapl-done'));
    window.closeMshipApply(); await sleep(60);
    ok('닫힌다', document.getElementById('mshipApply').style.display === 'none');

    // SQL 을 아직 안 돌렸을 때 — 조용히 실패하지 않는다
    window.sb.rpc = (fn) => fn === 'taam_mship_my_application'
      ? Promise.resolve({ data: null, error: null })
      : Promise.resolve({ data: null,
          error: { message: 'function public.taam_mship_apply does not exist' } });
    await window.openMshipApply(); await sleep(200);
    document.getElementById('maplName').value = '아무개';
    document.getElementById('maplPhone').value = '01011112222';
    ['visits','plan','spend'].forEach(k => window.mshipApplyPick(k, 'a'));
    await sleep(80);
    document.getElementById('mapl_who').value = 'x';
    document.getElementById('mapl_places').value = 'y';
    await window.mshipApplySubmit(); await sleep(200);
    ok('SQL 이 없으면 알려주고 다시 누를 수 있다',
       !!document.querySelector('#maplErr .mapl-err')
       && document.getElementById('maplGo').disabled === false);
    window.closeMshipApply();

    // ── ⑥ 게스트 — 90일 한정 초대 ────────────────────────────
    //   「일반 회원」이 아니라 「게스트」다. 무료지만 무기한이 아니다.
    ok('A 등급의 이름은 게스트 ⭐', window._tierLabel('A') === '게스트');
    ok('M·T 이름은 그대로', window._tierLabel('M') === 'M 등급' && window._tierLabel('T') === 'T 등급');

    // 잠금 팝업 — 닫기만 있는 팝업 금지. 심사 신청이 먼저다.
    window._currentUserGrade = 'A';
    window._currentRole = 'user';
    document.getElementById('tierLockModal')?.remove();
    window.showTierLockPopup({ minTier: '' }); await sleep(100);
    const lock = document.getElementById('tierLockModal');
    ok('게스트 잠금 팝업이 뜬다', !!lock);
    ok('「멤버십 전용입니다」라고 적는다', !!lock && lock.textContent.indexOf('멤버십 전용입니다') >= 0);
    ok('「정원 33인 · 심사제」를 적는다', !!lock && lock.textContent.indexOf('33인') >= 0
                                                  && lock.textContent.indexOf('심사제') >= 0);
    ok('심사 신청 버튼이 먼저다 ⭐', !!lock && !!lock.querySelector('#tlkApply'));
    ok('멤버십 안내도 갈 수 있다',   !!lock && !!lock.querySelector('#tlkMship'));
    ok('내 등급을 게스트라고 적는다', !!lock && lock.textContent.indexOf('게스트') >= 0);
    let applied = 0;
    const realApply = window.openMshipApply;
    window.openMshipApply = () => { applied++; };
    lock.querySelector('#tlkApply').click(); await sleep(80);
    ok('누르면 심사 신청으로 바로 간다 ⭐ (두 번 안 누른다)', applied === 1);
    ok('누르면 팝업이 닫힌다', !document.getElementById('tierLockModal'));
    window.openMshipApply = realApply;

    // My Page — 게스트에게 남은 기한과 갈 곳을 준다
    window.sb.rpc = (fn) => {
      if (fn === 'taam_guest_state') return Promise.resolve({ data: {
        is_guest: true, expired: false, warn: false, days_left: 42, status: 'active' }, error: null });
      return Promise.resolve({ data: null, error: null });
    };
    await window._mpPaintGuest('A'); await sleep(80);
    const gl = document.getElementById('mpGuestLine');
    ok('게스트 줄이 보인다', !!gl && gl.style.display !== 'none');
    ok('남은 날을 적는다 (서버 값)', !!gl && gl.textContent.indexOf('42') >= 0);

    window.sb.rpc = (fn) => fn === 'taam_guest_state'
      ? Promise.resolve({ data: { is_guest: true, expired: false, warn: true, days_left: 5 }, error: null })
      : Promise.resolve({ data: null, error: null });
    await window._mpPaintGuest('A'); await sleep(60);
    ok('D-7 이면 재촉한다', gl.textContent.indexOf('5일') >= 0 && gl.textContent.indexOf('심사') >= 0);

    window.sb.rpc = (fn) => fn === 'taam_guest_state'
      ? Promise.resolve({ data: { is_guest: true, expired: true, days_left: 0 }, error: null })
      : Promise.resolve({ data: null, error: null });
    await window._mpPaintGuest('A'); await sleep(60);
    ok('만료면 종료됐다고 말한다 ⭐', gl.textContent.indexOf('종료') >= 0);
    ok('만료돼도 갈 길을 준다',
       gl.textContent.indexOf('심사') >= 0 || gl.textContent.indexOf('추천') >= 0);

    // 서버가 답을 못 주면 날짜를 지어내지 않는다
    window.sb.rpc = () => Promise.resolve({ data: null, error: { message: 'x' } });
    await window._mpPaintGuest('A'); await sleep(60);
    ok('서버가 없으면 날짜를 지어내지 않는다 ⭐', !/\d+일/.test(gl.textContent));

    await window._mpPaintGuest('M'); await sleep(60);
    ok('M 회원에게는 게스트 줄이 없다', gl.style.display === 'none');

    // ── ⑦ 3개 국어 ───────────────────────────────────────────
    const T = window.TRANSLATIONS;
    ['ko','en','ja'].forEach(function(L){
      const m = T[L] && T[L].mapl, ms = T[L] && T[L].membership;
      ok(L + ' — 심사 신청 문구가 있다',
         !!m && !!m.title && !!m.q_visits && !!m.q_spend && !!m.done_t);
      ok(L + ' — 구성·규칙 문구가 있다',
         !!ms && !!ms.compose_dep && !!ms.rule_1 && !!ms.rule_3 && !!ms.cta_apply);
    });
    // 번역에도 가격이 새어 들어가면 안 된다
    ok('심사 신청 문구에 가격이 없다 ⭐',
       ['ko','en','ja'].every(L =>
         !/11,250,000|10,125,000|1,125,000|3,150,000/.test(JSON.stringify(T[L].mapl))));

    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 6).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
