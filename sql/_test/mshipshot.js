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
        return Promise.resolve({ data: { ok: true, already: false, id: 'x' }, error: null }); },
      from: () => ({ select: () => ({ eq: () => ({ maybeSingle: () =>
        Promise.resolve({ data: { capacity: 33, taken: 28 }, error: null }) }) }) })
    };

    // ── ① 화면 ───────────────────────────────────────────────
    window.openMshipScreen(); await sleep(300);
    const scr = document.getElementById('mshipScreen');
    ok('멤버십 화면이 열린다', scr.style.display === 'flex');
    const txt = scr.textContent;
    ok('1,125만이 적혀 있다', txt.indexOf('11,250,000') >= 0);
    ok('예치금 90% 를 적는다',  txt.indexOf('10,125,000') >= 0);
    ok('연회비 10% 를 적는다',  txt.indexOf('1,125,000') >= 0);
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

    // ── ⑥ 3개 국어 ───────────────────────────────────────────
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
