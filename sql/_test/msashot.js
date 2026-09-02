// ═══════════════════════════════════════════════════════════════
// 멤버십 · 게스트 어드민 — 앱 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
// 심사 신청을 받기 시작했는데 볼 화면이 없었다. 여기서 보는 것:
//   ① 슈퍼어드민만 열리는가
//   ② 신청서를 답변 전문까지 읽는가 (그때 물은 질문과 함께)
//   ③ 「통과」 버튼이 여기 없는가  ← 상태만 바꾸면 「통과인데 보낼 게 없는」
//      사람이 생긴다. 통과는 오퍼 링크를 만드는 것이다
//   ④ 게스트 [+90일] · 만료 임박 필터
//   ⑤ 설정값을 고치면 총액이 따라 바뀌는가
//   ⑥ SQL 을 안 돌렸을 때 「무엇을 해야 하는지」 알려주는가
//
// 실행: node sql/_test/msashot.js
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

    const DAY = 86400000;
    let RPC = [];
    const APPS = [
      { id:'a1', name:'김우종', phone:'01033334444', status:'applied', source:'app',
        created_at:new Date(Date.now()-DAY).toISOString(), user_id:'u1', membership_tier:'A',
        answers:{ visits:{ v:'a', label:'연 3회 이상', q:'연간 일본 방문 횟수' },
                  spend:{ v:'a', label:'200만원 이상', q:'1회 디너 지출 규모' },
                  places:{ v:'스기타 / 사이토 / 아라이', q:'기억에 남는 레스토랑 세 곳' } } },
      { id:'a2', name:'비회원', phone:'01011112222', status:'screening', source:'web',
        created_at:new Date(Date.now()-3*DAY).toISOString(), answers:{}, referral_code:'TAAM-2026-AB12' },
      { id:'a3', name:'보류된분', phone:'01055556666', status:'declined', source:'app',
        created_at:new Date(Date.now()-9*DAY).toISOString(), answers:{} }
    ];
    const GUESTS = [
      { id:'g1', display_name:'만료된게스트', phone:'01011110000',
        guest_expires_at:new Date(Date.now()-2*DAY).toISOString(), expired:true,
        guest_extended_cnt:0, has_purchased:true, has_applied:false },
      { id:'g2', display_name:'임박한게스트', phone:'01022220000',
        guest_expires_at:new Date(Date.now()+4*DAY).toISOString(), expired:false,
        guest_extended_cnt:1, has_purchased:false, has_applied:true },
      { id:'g3', display_name:'여유있는게스트', phone:'01033330000',
        guest_expires_at:new Date(Date.now()+60*DAY).toISOString(), expired:false,
        guest_extended_cnt:0, has_purchased:false, has_applied:false }
    ];
    const CFG = { deposit_amount:10125000, annual_fee_cash:1125000, annual_fee_card:1270000,
                  guest_days:90, guest_extend_days:90, guest_warn_days:7,
                  offer_days:7, referral_days:14, referral_per_year:2 };
    window.sb = {
      rpc: (fn, a) => { RPC.push([fn, a]);
        if (fn === 'taam_mship_apply_list') return Promise.resolve({ data: APPS, error: null });
        if (fn === 'taam_guest_list') {
          const f = a.p_filter;
          const l = GUESTS.filter(g => f === 'all'
            || (f === 'dormant' && g.expired)
            || (f === 'active'  && !g.expired)
            || (f === 'warn'    && !g.expired
                && (new Date(g.guest_expires_at) - Date.now()) <= 7 * DAY));
          return Promise.resolve({ data: l, error: null });
        }
        if (fn === 'taam_mship_settings') return Promise.resolve({ data: CFG, error: null });
        if (fn === 'taam_guest_extend') return Promise.resolve({ data: {
          ok:true, expires_at:new Date(Date.now()+90*DAY).toISOString(), count:1 }, error: null });
        return Promise.resolve({ data: { ok: true }, error: null }); },
      from: () => ({ select: () => ({ eq: () => ({ maybeSingle: () =>
        Promise.resolve({ data: { capacity: 33, taken: 28 }, error: null }) }) }) })
    };

    // ── ① 권한 ───────────────────────────────────────────────
    window._isSuperAdmin = () => false;
    window.__toast = null;
    await window.msaOpen(); await sleep(120);
    ok('회원은 못 연다 ⭐',
       document.getElementById('msaScreen').style.display !== 'flex'
       && window.__toast && window.__toast[1] === '권한 부족');
    window._isSuperAdmin = () => true;

    // ── ② 심사 큐 ────────────────────────────────────────────
    RPC = [];
    await window.msaOpen(); await sleep(300);
    ok('슈퍼어드민은 열린다', document.getElementById('msaScreen').style.display === 'flex');
    ok('심사 큐를 부른다', RPC.some(x => x[0] === 'taam_mship_apply_list'));
    let bt = document.getElementById('msaBody').textContent;
    ok('신청자가 뜬다', bt.indexOf('김우종') >= 0);
    ok('회원 배지', bt.indexOf('회원') >= 0);
    ok('신규/심사 중/보류를 구분한다',
       bt.indexOf('신규') >= 0 && bt.indexOf('심사 중') >= 0 && bt.indexOf('보류') >= 0);
    ok('보류는 건수에서 뺀다 ⭐',
       document.getElementById('msaCount').textContent === '2건');
    ok('추천 코드를 보여준다', bt.indexOf('TAAM-2026-AB12') >= 0);

    // 신청서 전문
    window.msaDetail('a1'); await sleep(120);
    const det = document.getElementById('msaDetail');
    ok('신청서가 열린다', det.style.display === 'flex');
    const dt = document.getElementById('msdBody').textContent;
    ok('연락처를 보여준다', dt.indexOf('010-3333-4444') >= 0);
    // 답변은 「그때 물은 질문」과 함께 저장돼 있다 — 질문이 바뀌어도 읽힌다
    ok('그때의 질문을 같이 보여준다 ⭐', dt.indexOf('연간 일본 방문 횟수') >= 0);
    ok('고른 답을 문장으로 보여준다',   dt.indexOf('연 3회 이상') >= 0);
    ok('직접 쓴 답도 보여준다',         dt.indexOf('스기타') >= 0);

    // ③ 「통과」 버튼이 없어야 한다
    const acts = document.getElementById('msdActs').textContent;
    ok('심사 중으로 바꿀 수 있다', acts.indexOf('심사 중') >= 0);
    ok('보류할 수 있다',           acts.indexOf('보류') >= 0);
    ok('「통과」 버튼이 없다 ⭐ (통과는 오퍼 링크를 만드는 것)',
       acts.indexOf('통과') < 0 && acts.indexOf('승인') < 0);

    RPC = [];
    await window.msaSetStatus('screening'); await sleep(150);
    const call = RPC.filter(x => x[0] === 'taam_mship_apply_status')[0];
    ok('상태를 서버에 넘긴다',
       call && call[1].p_id === 'a1' && call[1].p_status === 'screening');
    ok('바꾸면 신청서가 닫힌다', document.getElementById('msaDetail').style.display === 'none');
    ok('목록이 갱신된다',
       document.getElementById('msaBody').textContent.indexOf('신규') < 0);

    // ── ④ 게스트 ─────────────────────────────────────────────
    window.msaTab('guest'); await sleep(300);
    bt = document.getElementById('msaBody').textContent;
    ok('게스트 목록이 뜬다', bt.indexOf('만료된게스트') >= 0);
    ok('만료를 표시한다',    bt.indexOf('만료') >= 0);
    ok('남은 날을 표시한다', /\d+일 남음/.test(bt));
    // [+90일] 을 누를지 판단하는 재료
    ok('구매 여부를 같이 보여준다 ⭐', bt.indexOf('구매 있음') >= 0 && bt.indexOf('구매 없음') >= 0);
    ok('심사 신청 여부도 보여준다',    bt.indexOf('심사 신청함') >= 0);
    ok('연장 횟수를 보여준다',         bt.indexOf('1회 연장') >= 0);

    RPC = [];
    window.msaGuestFilter('warn'); await sleep(250);
    ok('만료 임박만 거른다 ⭐',
       RPC.some(x => x[0] === 'taam_guest_list' && x[1].p_filter === 'warn')
       && document.getElementById('msaBody').textContent.indexOf('여유있는게스트') < 0);
    window.msaGuestFilter('all'); await sleep(250);

    RPC = []; window.__toast = null;
    await window.msaExtend('g1'); await sleep(250);
    ok('[+90일] 을 서버에 넘긴다',
       RPC.some(x => x[0] === 'taam_guest_extend' && x[1].p_uid === 'g1'));
    ok('연장 결과를 알려준다', window.__toast && window.__toast[1] === '연장했습니다');

    // ── ⑤ 설정값 ─────────────────────────────────────────────
    window.msaTab('cfg'); await sleep(300);
    bt = document.getElementById('msaBody').textContent;
    ok('이체 총액을 계산해 보여준다', bt.indexOf('11,250,000원') >= 0);
    ok('카드 총액도 보여준다',        bt.indexOf('11,395,000원') >= 0);
    ok('금액의 유일한 출처라고 적는다', bt.indexOf('유일한 출처') >= 0);
    ok('정원을 고칠 수 있다', !!document.getElementById('msaSeatCap'));
    ok('잔여석을 계산한다',   bt.indexOf('잔여 5석') >= 0);
    ok('연회비 두 칸이 따로 있다',
       !!document.querySelector('#msaBody input[data-k="annual_fee_cash"]')
       && !!document.querySelector('#msaBody input[data-k="annual_fee_card"]'));

    // 안 바뀐 값은 안 보낸다 — 눌렀다고 전부 다시 쓰면 감사 로그가 지저분해진다
    RPC = []; window.__toast = null;
    await window.msaCfgSave(); await sleep(200);
    ok('안 바뀐 값은 안 보낸다 ⭐', !RPC.some(x => x[0] === 'taam_mship_settings_set'));
    ok('바뀐 게 없다고 말해 준다', window.__toast && window.__toast[1] === '바뀐 값이 없습니다');

    document.querySelector('#msaBody input[data-k="annual_fee_card"]').value = '1,300,000';
    RPC = [];
    await window.msaCfgSave(); await sleep(250);
    const cs = RPC.filter(x => x[0] === 'taam_mship_settings_set');
    ok('바뀐 값만 보낸다 ⭐', cs.length === 1 && cs[0][1].p_k === 'annual_fee_card');
    ok('콤마를 떼고 숫자로 넘긴다', cs.length === 1 && cs[0][1].p_v === 1300000);

    // ── ⑥ SQL 을 안 돌렸을 때 ────────────────────────────────
    window.sb.rpc = () => Promise.resolve({ data: null,
      error: { message: 'relation "public.membership_applications" does not exist' } });
    window.msaTab('apply'); await sleep(250);
    bt = document.getElementById('msaBody').textContent;
    ok('무엇을 해야 하는지 알려준다 ⭐', bt.indexOf('membership_apply.sql') >= 0);
    ok('「없다」로 끝내지 않는다',       bt.indexOf('실행') >= 0);

    window.msaBack(); await sleep(120);
    ok('닫힌다', document.getElementById('msaScreen').style.display !== 'flex');

    // 가로 스크롤 금지 (어드민 콘솔 공통 규칙)
    ok('세로 제스처만 받는다',
       getComputedStyle(document.getElementById('msaScreen')).touchAction === 'pan-y');
    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 6).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
