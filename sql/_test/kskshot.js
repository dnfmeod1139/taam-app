// ═══════════════════════════════════════════════════════════════
// 대관 정산 어드민 — 화면 검증 (2026-09-01)
// ═══════════════════════════════════════════════════════════════
// 서버가 막는지는 t_kashikiri.sh 가 본다. 여기서는 **화면이 서버에
// 무엇을 넘기는지** 와 사람이 실수할 자리를 본다.
//   ① 슈퍼어드민만 열리나
//   ② SQL 이 아직 없으면 「실행 필요」 안내가 뜨나 (빈 화면이 아니라)
//   ③ 균등 분할이 1원도 안 흘리나 (나머지는 첫 행에)
//   ④ 합계가 어긋나면 버튼이 잠기나
//   ⑤ 이미 낸 사람이 있으면 다시 나누기를 막나
//   ⑥ 링크 주소가 /pay/?t=… 형태인가
//
// 실행: node sql/_test/kskshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(async () => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));

    document.getElementById('appWrapper').classList.add('ready');
    window.showToast = function(a, b2, c){ window.__toast = [a, b2, c]; };

    ok('kskOpen 존재',      typeof window.kskOpen === 'function');
    ok('kskSplitOpen 존재', typeof window.kskSplitOpen === 'function');
    ok('화면이 DOM 에 있다', !!document.getElementById('kskScreen'));
    ok('분할 시트가 DOM 에 있다', !!document.getElementById('kskSplit'));

    // ── 가짜 Supabase ────────────────────────────────────────
    // 실제 응답 모양(.data / .error)만 흉내낸다. 체이닝은 자기 자신을 돌려준다.
    let DB = { events: [], teams: [], charges: [], guests: [] };
    let RPC = [];
    let FAILTABLE = null;
    function q(rows){
      const o = {
        data: rows, error: null,
        select(){ return o; }, order(){ return o; }, limit(){ return o; },
        eq(){ return o; }, in(){ return o; },
        maybeSingle(){ return Promise.resolve({ data: rows[0] || null, error: null }); },
        then(res){ return Promise.resolve({ data: rows, error: null }).then(res); }
      };
      return o;
    }
    window.sb = {
      auth: { getUser: async () => ({ data: { user: { id: 'sup-1' } } }) },
      from(t){
        if (FAILTABLE === t) {
          const e = { data: null, error: { message: 'relation does not exist' } };
          const o = { select(){return o;}, order(){return o;}, limit(){return o;}, eq(){return o;},
                      in(){return o;}, maybeSingle(){return Promise.resolve(e);},
                      then(r){ return Promise.resolve(e).then(r); },
                      insert(){return o;}, update(){return o;}, delete(){return o;} };
          return o;
        }
        const key = t.replace('kashikiri_', '');
        const o = q(DB[key] || []);
        o.insert = (row) => { window.__ins = [t, row]; return q([{ id: 'new-1' }]); };
        o.update = (row) => { window.__upd = [t, row]; (window.__upds = window.__upds || []).push([t, row]); return q([]); };
        o.delete = () => q([]);
        return o;
      },
      rpc(fn, args){ RPC.push([fn, args]); return Promise.resolve({ data: 'tok-' + fn, error: null }); }
    };
    window.__rpc = () => RPC;

    // ── ① 권한 ───────────────────────────────────────────────
    window._isSuperAdmin = () => false;
    window.__toast = null;
    await window.kskOpen();
    ok('슈퍼어드민이 아니면 안 열린다',
       document.getElementById('kskScreen').style.display !== 'block'
       && window.__toast && window.__toast[1] === '권한 부족');

    window._isSuperAdmin = () => true;

    // ── ② SQL 이 아직 없을 때 ────────────────────────────────
    FAILTABLE = 'kashikiri_events';
    await window.kskOpen(); await sleep(150);
    ok('SQL 미적용이면 안내가 뜬다',
       document.getElementById('kskBody').textContent.indexOf('kashikiri.sql') >= 0);
    FAILTABLE = null;

    // ── 목록 · 상세 ──────────────────────────────────────────
    DB.events = [{ id:'e1', venue_id:'v1', venue_name:'鮨 めい乃', event_date:'2027-01-01',
                   event_time:'18:00:00', total_pax:9, escort:true, status:'settling',
                   fx_rate:'9.3500', fx_note:'1/1 매매기준율 + 2%', venue_paid_jpy:960000 }];
    await window.kskOpen(); await sleep(150);
    ok('회차가 목록에 뜬다', document.getElementById('kskBody').textContent.indexOf('めい乃') >= 0);
    ok('환율 꼬리 0 을 지운다', document.getElementById('kskBody').textContent.indexOf('9.35원') >= 0);
    ok('꼬리 0 이 남아 있지 않다', document.getElementById('kskBody').textContent.indexOf('9.3500') < 0);

    DB.teams = [
      { id:'t1', event_id:'e1', seq:1, host_label:'K様', pax:4, total_jpy:450000, total_krw:4207500 },
      { id:'t2', event_id:'e1', seq:2, host_label:'Y様', pax:2, total_jpy:240000, total_krw:2244000 }
    ];
    DB.guests = [
      { id:'g1', team_id:'t1', seq:1, display_name:'K様', is_host:true },
      { id:'g2', team_id:'t1', seq:2, display_name:'P様' },
      { id:'g3', team_id:'t1', seq:3, display_name:'L様' },
      { id:'g4', team_id:'t1', seq:4, display_name:'C様' }
    ];
    DB.charges = [
      { id:'c1', event_id:'e1', team_id:'t2', label:'Y様', amount_krw:1122000, status:'paid',  token:'aa'.repeat(16), user_id:'u1' },
      { id:'c2', event_id:'e1', team_id:'t2', label:'동행 1', amount_krw:1122000, status:'pending', token:'bb'.repeat(16) }
    ];
    await window.kskOpenEvent('e1'); await sleep(200);
    const bt = document.getElementById('kskBody').textContent;
    ok('제목이 매장 이름', document.getElementById('kskTitle').textContent.indexOf('めい乃') >= 0);
    ok('매장 지급액이 뜬다',  bt.indexOf('¥960,000') >= 0);
    ok('대표 동행 표시',      bt.indexOf('동행') >= 0);
    ok('조가 둘 다 뜬다',     bt.indexOf('1組') >= 0 && bt.indexOf('2組') >= 0);
    ok('회수 진행이 뜬다',    document.getElementById('kskCount').textContent === '1/2');
    ok('결제된 사람은 ✓',     bt.indexOf('✓') >= 0);
    ok('안 낸 사람은 ○',      bt.indexOf('○') >= 0);
    ok('회수 막대가 있다',    !!document.querySelector('#kskBody .ksk-bar i'));

    // ── ③ 균등 분할 ──────────────────────────────────────────
    window.kskSplitOpen('t1'); await sleep(120);
    ok('분할 시트가 열린다', document.getElementById('kskSplit').style.display === 'flex');
    ok('게스트 수(4)를 기본으로 잡는다',
       document.getElementById('kspBody').textContent.indexOf('4') >= 0);
    let inputs = [].map.call(document.querySelectorAll('#kspBody .ksp-line input'), e => e.value);
    ok('4행이 만들어진다', inputs.length === 4);
    let sum = inputs.reduce((a, v) => a + (parseInt(String(v).replace(/[^0-9]/g,''),10)||0), 0);
    ok('합계가 확정액과 같다 (4,207,500)', sum === 4207500);
    ok('균등이면 1원도 안 흘린다', inputs[0] === '1,051,875' && inputs[3] === '1,051,875');
    ok('게스트 이름을 그대로 쓴다',
       document.getElementById('kspBody').textContent.indexOf('P様') >= 0);
    ok('합계 표시가 「딱 맞음」',
       document.getElementById('kspSum').textContent.indexOf('딱 맞음') >= 0);
    ok('버튼이 열려 있다', document.getElementById('kspGo').disabled === false);

    // 나머지가 남는 금액 — 첫 행에 몰아준다
    DB.teams[0].total_krw = 4207502;
    window.kskSplitOpen('t1'); await sleep(120);
    inputs = [].map.call(document.querySelectorAll('#kspBody .ksp-line input'), e => e.value);
    sum = inputs.reduce((a, v) => a + (parseInt(String(v).replace(/[^0-9]/g,''),10)||0), 0);
    ok('나머지가 있어도 합계가 맞는다', sum === 4207502);
    ok('나머지는 첫 행에 몰아준다', inputs[0] === '1,051,877' && inputs[1] === '1,051,875');
    DB.teams[0].total_krw = 4207500;

    // ── ④ 합계가 어긋나면 잠긴다 ─────────────────────────────
    window.kskSplitOpen('t1'); await sleep(120);
    window.kskSplitMode('free'); await sleep(80);
    const first = document.querySelector('#kspBody .ksp-line input');
    first.value = '1'; window.kskSplitEdit(first);
    ok('어긋나면 버튼이 잠긴다', document.getElementById('kspGo').disabled === true);
    ok('얼마가 모자란지 보여준다',
       document.getElementById('kspSum').textContent.indexOf('-') >= 0);
    window.kskSplitMode('even'); await sleep(80);
    ok('균등으로 되돌리면 다시 열린다', document.getElementById('kspGo').disabled === false);

    // ── 서버에 넘기는 내용 ───────────────────────────────────
    RPC.length = 0;
    await window.kskSplitSave(); await sleep(200);
    const call = RPC.filter(x => x[0] === 'taam_kashikiri_split')[0];
    ok('split RPC 를 부른다', !!call);
    ok('팀 id 를 넘긴다', call && call[1].p_team_id === 't1');
    ok('4행을 넘긴다', call && call[1].p_rows.length === 4);
    ok('행 합계가 확정액과 같다',
       call && call[1].p_rows.reduce((a, r2) => a + r2.amount_krw, 0) === 4207500);
    ok('엔화도 같이 넘긴다', call && call[1].p_rows[0].amount_jpy === 112500);
    ok('게스트 id 를 물린다', call && call[1].p_rows[1].guest_id === 'g2');
    ok('시트가 닫힌다', document.getElementById('kskSplit').style.display === 'none');

    // ── ⑤ 이미 낸 사람이 있으면 막는다 ───────────────────────
    window.__toast = null;
    window.kskSplitOpen('t2'); await sleep(80);
    ok('결제된 조는 다시 못 나눈다',
       document.getElementById('kskSplit').style.display !== 'flex'
       && window.__toast && window.__toast[1] === '이미 결제됨');

    // 금액이 없는 조도 막는다
    DB.teams.push({ id:'t3', event_id:'e1', seq:3, pax:2, total_jpy:null, total_krw:null });
    await window.kskOpenEvent('e1'); await sleep(150);
    window.__toast = null;
    window.kskSplitOpen('t3'); await sleep(80);
    ok('금액이 없으면 못 나눈다', window.__toast && window.__toast[1] === '금액 먼저');

    // ── ⑥ 링크 주소 ─────────────────────────────────────────
    let copied = null;
    navigator.clipboard.writeText = (t) => { copied = t; return Promise.resolve(); };
    window.kskCopy('cc'.repeat(16)); await sleep(120);
    ok('결제 링크는 /pay/?t=', copied && /\/pay\/\?t=c{32}$/.test(copied));
    ok('링크가 https 로 시작', copied && copied.indexOf('https://') === 0);

    window.kskCopyAll('t2'); await sleep(120);
    ok('미결제만 모아 복사한다', copied && copied.indexOf('bb'.repeat(16)) >= 0
                                && copied.indexOf('aa'.repeat(16)) < 0);
    ok('보낼 문구가 붙는다', copied && copied.indexOf('앱 설치는 필요 없습니다') >= 0);

    RPC.length = 0;
    await window.kskSheetLink(); await sleep(150);
    ok('시트 링크 RPC 를 부른다',
       RPC.some(x => x[0] === 'taam_kashikiri_sheet_link' && x[1].p_event_id === 'e1'));
    ok('시트 링크는 /sheet/?t=', copied && copied.indexOf('/sheet/?t=') >= 0);

    // ── ⑦ 입력 시트 — prompt() 를 안 쓴다 ────────────────────
    let promptCalls = 0;
    window.prompt = function(){ promptCalls++; return null; };
    window.confirm = function(){ promptCalls++; return true; };

    await window.kskOpenEvent('e1'); await sleep(150);
    window.kskEditEvent(); await sleep(120);
    ok('회차 정보가 시트로 뜬다', document.getElementById('kskForm').style.display === 'flex');
    ok('prompt 를 쓰지 않는다', promptCalls === 0);
    const ff = document.getElementById('kskfBody');
    ok('매장 이름 칸에 현재 값',  document.getElementById('kskf_name').value === '鮨 めい乃');
    ok('날짜 칸에 현재 값',       document.getElementById('kskf_date').value === '2027-01-01');
    ok('시간 칸에 현재 값',       document.getElementById('kskf_time').value === '18:00');
    ok('환율 칸은 꼬리 0 없이',   document.getElementById('kskf_fx').value === '9.35');
    ok('환율 근거 칸',            document.getElementById('kskf_note').value.indexOf('매매기준율') >= 0);
    ok('매장 지급은 콤마로',      document.getElementById('kskf_paid').value === '960,000');
    ok('동행은 세그먼트',         document.getElementById('kskf_escort').getAttribute('data-v') === '1');
    ok('한 판에 10칸이 다 보인다', ff.querySelectorAll('.kskf-f').length === 10);
    ok('정산 총액 칸이 있다', !!document.getElementById('kskf_total'));
    ok('달러 환율 칸이 있다', !!document.getElementById('kskf_fxu'));

    // 세그먼트 전환
    window.kskFormSeg('escort', '0'); await sleep(40);
    ok('동행 없음으로 바뀐다', document.getElementById('kskf_escort').getAttribute('data-v') === '0');

    // 필수값 검사 — 저장하지 않고 시트에 머문다
    document.getElementById('kskf_name').value = '';
    await window.kskFormSave(); await sleep(120);
    ok('필수값이 비면 안 닫힌다', document.getElementById('kskForm').style.display === 'flex');
    ok('무엇이 빠졌는지 알려준다',
       document.getElementById('kskfErr').textContent.indexOf('매장 이름') >= 0);
    ok('저장 버튼이 다시 열린다', document.getElementById('kskfGo').disabled === false);

    // 제대로 채우면 저장된다
    document.getElementById('kskf_name').value = '鮨 あお';
    document.getElementById('kskf_fx').value = '9.4';
    window.__upds = [];
    await window.kskFormSave(); await sleep(250);
    ok('저장하면 닫힌다', document.getElementById('kskForm').style.display === 'none');
    // 회차 update 는 첫 호출. 그 뒤 조 원화 재계산 update 가 이어진다.
    const evUpd = (window.__upds || []).filter(x => x[0] === 'kashikiri_events')[0];
    ok('세그먼트 값이 boolean 으로 간다', !!evUpd && evUpd[1].escort === false);
    ok('환율이 숫자로 간다', !!evUpd && evUpd[1].fx_rate === 9.4);
    ok('환율이 바뀌면 조 원화도 다시 계산한다',
       (window.__upds || []).some(x => x[0] === 'kashikiri_teams' && x[1].total_krw === Math.round(450000 * 9.4)));

    // ── 조 추가 — 게스트 이름까지 한 판에 ────────────────────
    window.kskAddTeam(); await sleep(120);
    ok('조 추가도 시트',    document.getElementById('kskForm').style.display === 'flex');
    ok('게스트 이름 칸이 같이 있다', !!document.getElementById('kskf_names'));
    ok('주류·알레르기도 같이',
       !!document.getElementById('kskf_drink') && !!document.getElementById('kskf_allergy'));
    // 앞 테스트에서 3組(t3)을 이미 넣었으므로 다음은 4組 — seq 는 최대값 +1 이다
    ok('새 조는 4組 (seq 자동)', document.getElementById('kskfTitle').textContent.indexOf('4組') >= 0);
    document.getElementById('kskf_host').value = 'Z様';
    document.getElementById('kskf_pax').value = '2';
    document.getElementById('kskf_names').value = 'Z様*, W様';
    window.__ins = null;
    await window.kskFormSave(); await sleep(250);
    ok('조가 저장된다', window.__ins && window.__ins[0] === 'kashikiri_guests');

    // 조 수정 — 현재 게스트 이름이 채워져 온다
    window.kskEditTeam('t1'); await sleep(120);
    ok('조 수정 시트에 확정 엔화', document.getElementById('kskf_jpy').value === '450,000');
    ok('게스트 이름이 채워져 온다',
       document.getElementById('kskf_names').value === 'K様*, P様, L様, C様');
    window.kskFormClose(); await sleep(80);
    ok('취소하면 닫힌다', document.getElementById('kskForm').style.display === 'none');

    ok('끝까지 prompt 를 한 번도 안 썼다', promptCalls === 0);

    // ── ⑨ 판매 티켓 연결 ─────────────────────────────────────
    //   대관은 결국 그 날짜 티켓을 산 사람들이 오는 자리다.
    //   손으로 만든 회차는 venue_id 가 'manual-…' 이라 게스트 시트의
    //   「그 매장 지난 회계」가 영영 안 잡힌다 — 이걸 막는 게 요점이다.
    window.ticketDB = [
      { id:'TP_MEI', restId:'rest-1', rest:'鮨 めい乃', date:'01.01', dateYear:'2027',
        time:'18:00', totalPax:9 },
      { id:'TP_OLD', restId:'rest-2', rest:'鮨 あお', date:'12.20', dateYear:'2026',
        time:'19:00', totalPax:8 }
    ];
    window.restaurantDB = [{ id:'rest-1', name:'鮨 めい乃' }, { id:'rest-2', name:'鮨 あお' }];
    window._tkFullDate = t => (t.dateYear ? t.dateYear + '.' : '') + t.date;

    window.kskNewEvent(); await sleep(120);
    const sel = document.getElementById('kskf_ticket');
    ok('회차 만들 때 티켓을 고른다', !!sel && sel.tagName === 'SELECT');
    ok('「연결 안 함」이 맨 위', sel.options[0].value === '');
    ok('최근 티켓이 위로', sel.options[1].value === 'TP_MEI');
    ok('티켓 라벨에 매장·날짜·석수',
       sel.options[1].textContent.indexOf('めい乃') >= 0
       && sel.options[1].textContent.indexOf('2027-01-01') >= 0
       && sel.options[1].textContent.indexOf('9석') >= 0);

    // 고르면 아래 칸이 채워진다 — 사람이 다시 적지 않는다
    sel.value = 'TP_MEI'; window.kskFormPickTicket('TP_MEI'); await sleep(60);
    ok('매장 이름이 따라온다', document.getElementById('kskf_name').value === '鮨 めい乃');
    ok('날짜가 따라온다',     document.getElementById('kskf_date').value === '2027-01-01');
    ok('시간이 따라온다',     document.getElementById('kskf_time').value === '18:00');

    window.__ins = null; window.__upds = [];
    await window.kskFormSave(); await sleep(250);
    ok('venue_id 가 진짜 매장이 된다 (manual- 아님)',
       window.__ins && window.__ins[1].venue_id === 'rest-1');
    ok('ticket_product_id 는 INSERT 에 안 싣는다',
       window.__ins && window.__ins[1].ticket_product_id === undefined);
    ok('연결은 따로 UPDATE 한다 (컬럼 없는 DB 보호)',
       (window.__upds || []).some(x => x[0] === 'kashikiri_events'
                                    && x[1].ticket_product_id === 'TP_MEI'));

    // 연결된 회차에는 「구매자에서 조 불러오기」가 뜬다
    DB.events[0].ticket_product_id = 'TP_MEI';
    await window.kskOpenEvent('e1'); await sleep(180);
    ok('연결되면 불러오기 버튼이 뜬다',
       document.getElementById('kskBody').textContent.indexOf('구매자에서 불러오기') >= 0);
    ok('연결 상태가 보인다',
       document.getElementById('kskBody').textContent.indexOf('연결됨') >= 0);

    RPC.length = 0; window.__toast = null;
    await window.kskImportTeams(); await sleep(250);
    ok('import RPC 를 부른다',
       RPC.some(x => x[0] === 'taam_kashikiri_import_teams' && x[1].p_event_id === 'e1'));

    // 연결이 없으면 「지금 연결하기」를 권한다
    DB.events[0].ticket_product_id = null;
    await window.kskOpenEvent('e1'); await sleep(180);
    ok('연결 안 됐으면 티켓 연결 버튼이 뜬다',
       document.getElementById('kskBody').textContent.indexOf('티켓 연결') >= 0);
    ok('불러오기 버튼은 없다',
       document.getElementById('kskBody').textContent.indexOf('구매자에서 불러오기') < 0);

    window.kskLinkTicket(); await sleep(120);
    ok('뒤늦게 연결하는 시트가 열린다', !!document.getElementById('kskf_ticket'));
    document.getElementById('kskf_ticket').value = 'TP_MEI';
    window.__upds = [];
    await window.kskFormSave(); await sleep(250);
    const lk = (window.__upds || []).filter(x => x[0] === 'kashikiri_events')[0];
    ok('연결하면 venue_id 도 바로잡는다',
       !!lk && lk[1].venue_id === 'rest-1' && lk[1].ticket_product_id === 'TP_MEI');

    // ── ⑩ 정산 링크 보내기 ───────────────────────────────────
    //   티켓을 고르면 구매자가 그대로 목록이 되고, 거기에 사람을 더한다.
    //   티켓이 없는 자리는 「수동 입력」으로 전부 직접 적는다.
    DB.events[0].ticket_product_id = 'TP_MEI';
    DB.events[0].total_krw = null;
    DB.charges = [
      { id:'c1', event_id:'e1', team_id:'t2', label:'Y様', amount_krw:1122000,
        status:'paid', token:'aa'.repeat(16), user_id:'u1' }
    ];
    // 구매자 3명 — 그중 u1 은 이미 보냈다
    window.__buyers = [
      { ticket_id:'tk1', user_id:'u1', name:'윤태호', phone:'010-1111-2222', pax:2 },
      { ticket_id:'tk2', user_id:'u2', name:'김우종', phone:'01033334444', pax:4 },
      { ticket_id:'tk3', user_id:'u3', name:'박지연', phone:null, pax:2 }
    ];
    const realRpc = window.sb.rpc;
    window.sb.rpc = (fn, args) => {
      RPC.push([fn, args]);
      if (fn === 'taam_kashikiri_buyers') return Promise.resolve({ data: window.__buyers, error: null });
      return Promise.resolve({ data: { created: 1 }, error: null });
    };

    await window.kskOpenEvent('e1'); await sleep(180);
    ok('「정산 링크 보내기」 버튼이 중심에 있다',
       document.getElementById('kskBody').textContent.indexOf('정산 링크 보내기') >= 0);
    ok('회수 현황이 사람 단위로 편다',
       document.getElementById('kskBody').textContent.indexOf('회수 현황') >= 0);
    ok('정산 총액 미설정이면 그렇게 적는다',
       document.getElementById('kskBody').textContent.indexOf('합계를 대조하지 않습니다') >= 0);

    await window.kskSendOpen(); await sleep(300);
    ok('보내기 시트가 열린다', document.getElementById('kskSend').style.display === 'flex');
    ok('구매자를 불러온다',
       RPC.some(x => x[0] === 'taam_kashikiri_buyers' && x[1].p_ticket_product_id === 'TP_MEI'));
    let rows = document.querySelectorAll('#ksdBody .ksd-row[data-i]');
    ok('이미 보낸 사람은 다시 안 올린다 (2명)', rows.length === 2);
    ok('구매자 표시가 붙는다',
       document.getElementById('ksdBody').textContent.indexOf('구매자 · 4인') >= 0);
    ok('번호를 보기 좋게 끊어 준다',
       document.getElementById('ksdBody').textContent.indexOf('010-3333-4444') >= 0);
    ok('번호 없는 사람은 그렇게 적는다',
       document.getElementById('ksdBody').textContent.indexOf('번호 없음') >= 0);
    ok('이미 보낸 사람은 위에 따로 보인다',
       document.getElementById('ksdBody').textContent.indexOf('이미 보냄') >= 0);
    ok('금액 전에는 버튼이 잠긴다', document.getElementById('ksdGo').disabled === true);

    // 구매자 금액 입력
    let amts = document.querySelectorAll('#ksdBody .ksd-row input.amt');
    amts[0].value = '1,051,875'; window.kskSendSum();
    amts[1].value = '500,000';   window.kskSendSum();
    ok('합계가 붙는다', document.getElementById('ksdSum').textContent.indexOf('1,551,875') >= 0);
    ok('금액이 들어가면 버튼이 열린다', document.getElementById('ksdGo').disabled === false);

    // 구매자가 아닌 사람 추가 — 이름·번호·금액
    window.kskSendAdd(); await sleep(80);
    rows = document.querySelectorAll('#ksdBody .ksd-row[data-i]');
    ok('사람을 더할 수 있다', rows.length === 3);
    const last = rows[2];
    ok('추가한 줄은 이름·번호를 직접 적는다',
       !!last.querySelector('input.nm') && !!last.querySelector('input.ph'));
    last.querySelector('input.nm').value = '이상훈';
    last.querySelector('input.ph').value = '010-5555-6666';
    last.querySelector('input.amt').value = '300,000';
    window.kskSendSum();
    ok('추가한 사람도 합계에 든다',
       document.getElementById('ksdSum').textContent.indexOf('1,851,875') >= 0);
    ok('앞서 적은 금액이 안 날아간다',
       document.querySelectorAll('#ksdBody .ksd-row input.amt')[0].value === '1,051,875');

    // 한 줄 빼기
    window.kskSendDel(1); await sleep(80);
    ok('한 줄을 뺀다', document.querySelectorAll('#ksdBody .ksd-row[data-i]').length === 2);
    ok('뺀 만큼 합계가 준다',
       document.getElementById('ksdSum').textContent.indexOf('1,351,875') >= 0);

    // 보내기 — 서버에 무엇을 넘기나
    RPC.length = 0;
    await window.kskSendSave(); await sleep(300);
    const sendCall = RPC.filter(x => x[0] === 'taam_kashikiri_send')[0];
    ok('send RPC 를 부른다', !!sendCall);
    ok('회차 id 를 넘긴다', sendCall && sendCall[1].p_event_id === 'e1');
    ok('2명을 넘긴다', sendCall && sendCall[1].p_rows.length === 2);
    ok('구매자는 user_id 를 물고 간다',
       sendCall && sendCall[1].p_rows.some(r2 => r2.user_id === 'u2'));
    ok('추가한 사람은 user_id 가 없다',
       sendCall && sendCall[1].p_rows.some(r2 => r2.label === '이상훈' && !r2.user_id));
    ok('번호를 함께 넘긴다',
       sendCall && sendCall[1].p_rows.some(r2 => String(r2.phone).indexOf('5555') >= 0));
    // 외화 금액은 서버가 만든다 — 화면은 통화만 넘긴다
    ok('통화를 넘긴다 (기본 원화)',
       sendCall && sendCall[1].p_rows.every(r2 => r2.currency === 'KRW'));
    ok('외화 금액을 화면이 만들지 않는다',
       sendCall && sendCall[1].p_rows.every(r2 => r2.amount_jpy === undefined));
    ok('보내면 시트가 닫힌다', document.getElementById('kskSend').style.display === 'none');

    // ── ⑩-b 통화 — 달러·엔으로도 보낸다 ──────────────────────
    //   해외 손님 카드에 원화로 찍히면 카드사 환가료가 붙고, 명세서에
    //   얼마가 나올지 본인도 모른다.
    DB.events[0].fx_usd = '1360.5000';
    await window.kskSendOpen(); await sleep(300);
    ok('통화 고르는 칸이 줄마다 있다',
       document.querySelectorAll('#ksdBody .ksd-cur .seg').length ===
       document.querySelectorAll('#ksdBody .ksd-row[data-i]').length);
    ok('기본은 원화',
       document.querySelector('#ksdBody .ksd-cur .seg span.on').textContent === '₩');

    amts = document.querySelectorAll('#ksdBody .ksd-row input.amt');
    amts[0].value = '1,051,875'; window.kskSendSum();
    window.kskSendCur(0, 'JPY'); await sleep(120);
    ok('엔으로 바꾸면 환산이 보인다',
       document.getElementById('ksdBody').textContent.indexOf('≈ ¥112,500') >= 0);
    ok('원화 금액은 그대로',
       document.querySelectorAll('#ksdBody .ksd-row input.amt')[0].value === '1,051,875');
    window.kskSendCur(0, 'USD'); await sleep(120);
    ok('달러로 바꾸면 센트까지 환산',
       document.getElementById('ksdBody').textContent.indexOf('≈ $773.15') >= 0);

    // 환율이 없으면 그 통화를 못 고른다
    DB.events[0].fx_usd = null;
    await window.kskOpenEvent('e1'); await sleep(180);
    await window.kskSendOpen(); await sleep(300);
    amts = document.querySelectorAll('#ksdBody .ksd-row input.amt');
    amts[0].value = '1,000'; window.kskSendSum();
    window.__toast = null;
    window.kskSendCur(0, 'USD'); await sleep(100);
    ok('달러 환율이 없으면 막고 알려준다',
       window.__toast && window.__toast[1] === '달러 환율 먼저');
    ok('막혔으면 통화도 안 바뀐다',
       document.querySelector('#ksdBody .ksd-cur .seg span.on').textContent === '₩');
    DB.events[0].fx_usd = '1360.5000';
    await window.kskOpenEvent('e1'); await sleep(180);
    await window.kskSendOpen(); await sleep(300);

    // 통화를 섞어 보낸다
    amts = document.querySelectorAll('#ksdBody .ksd-row input.amt');
    amts[0].value = '1,051,875'; window.kskSendSum();
    amts[1].value = '500,000';   window.kskSendSum();
    window.kskSendCur(1, 'JPY'); await sleep(120);
    ok('통화가 섞이면 합계에 표시한다',
       document.getElementById('ksdSum').textContent.indexOf('₩1 ¥1') >= 0);
    ok('합계는 원화 기준 그대로',
       document.getElementById('ksdSum').textContent.indexOf('1,551,875') >= 0);
    RPC.length = 0;
    await window.kskSendSave(); await sleep(300);
    const mixCall = RPC.filter(x => x[0] === 'taam_kashikiri_send')[0];
    ok('통화를 줄마다 넘긴다',
       mixCall && mixCall[1].p_rows[0].currency === 'KRW'
               && mixCall[1].p_rows[1].currency === 'JPY');
    ok('금액은 언제나 원화로 넘긴다 (외화는 서버가 만든다)',
       mixCall && mixCall[1].p_rows.every(r2 => r2.amount_krw > 0 && r2.pay_amount === undefined));

    // 회수 현황에 외화 표기
    DB.charges.push({ id:'c8', event_id:'e1', team_id:null, label:'엔화손님',
                      amount_krw:1051875, pay_currency:'JPY', pay_amount:112500,
                      status:'pending', token:'dd'.repeat(16) });
    await window.kskOpenEvent('e1'); await sleep(180);
    ok('회수 현황에 엔화로 보인다',
       document.getElementById('kskBody').textContent.indexOf('¥112,500') >= 0);
    ok('원화 기준도 같이 보인다',
       document.getElementById('kskBody').textContent.indexOf('₩1,051,875') >= 0);

    // ── ⑩-c 회원 통화를 자동으로 잡는다 ──────────────────────
    //   해외 손님이 섞인 자리에서 「누가 해외였더라」를 기억해 누르는 건
    //   반드시 틀린다. profiles.currency 가 이미 답을 갖고 있다.
    DB.charges = [];
    window.__buyers = [
      { ticket_id:'tk1', user_id:'u1', name:'김우종', phone:'01011112222', pax:4, currency:'KRW' },
      { ticket_id:'tk2', user_id:'u2', name:'Tanaka', phone:'01033334444', pax:2, currency:'JPY' },
      { ticket_id:'tk3', user_id:'u3', name:'Smith',  phone:null,          pax:2, currency:'USD' }
    ];
    await window.kskOpenEvent('e1'); await sleep(180);
    await window.kskSendOpen(); await sleep(320);
    let segs = document.querySelectorAll('#ksdBody .ksd-row .ksd-cur .seg');
    let on = [].map.call(segs, sg => sg.querySelector('span.on').textContent);
    ok('회원 통화가 그대로 잡힌다 (₩ ¥ $)', on.join('') === '₩¥$');
    ok('해외 회원에 표시가 붙는다',
       document.getElementById('ksdBody').textContent.indexOf('해외 ¥') >= 0
       && document.getElementById('ksdBody').textContent.indexOf('해외 $') >= 0);
    ok('국내 회원에는 안 붙는다',
       (document.getElementById('ksdBody').textContent.match(/해외 /g) || []).length === 2);

    // 환율이 없으면 원화로 두고 알려준다 — 없는 환율로 금액을 지어내지 않는다
    DB.events[0].fx_usd = null;
    await window.kskOpenEvent('e1'); await sleep(180);
    window.__toast = null;
    await window.kskSendOpen(); await sleep(320);
    segs = document.querySelectorAll('#ksdBody .ksd-row .ksd-cur .seg');
    on = [].map.call(segs, sg => sg.querySelector('span.on').textContent);
    ok('환율 없는 통화는 원화로 둔다', on.join('') === '₩¥₩');
    ok('몇 명이 그랬는지 알려준다',
       window.__toast && String(window.__toast[1]).indexOf('원화로 잡았습니다') >= 0);
    ok('해외 표시는 그대로 (지정은 지정이다)',
       document.getElementById('ksdBody').textContent.indexOf('해외 $') >= 0);
    DB.events[0].fx_usd = '1360.5000';

    // 전부 한 통화로
    await window.kskOpenEvent('e1'); await sleep(180);
    await window.kskSendOpen(); await sleep(320);
    ok('일괄 전환 버튼이 있다', !!document.querySelector('#ksdBody .ksd-all'));
    window.kskSendCurAll('JPY'); await sleep(120);
    segs = document.querySelectorAll('#ksdBody .ksd-row .ksd-cur .seg');
    ok('전부 엔으로 바뀐다',
       [].every.call(segs, sg => sg.querySelector('span.on').textContent === '¥'));
    DB.events[0].fx_rate = null;
    await window.kskOpenEvent('e1'); await sleep(180);
    await window.kskSendOpen(); await sleep(320);
    window.__toast = null;
    window.kskSendCurAll('JPY'); await sleep(100);
    ok('환율 없으면 일괄 전환도 막는다',
       window.__toast && window.__toast[1] === '엔 환율 먼저');
    DB.events[0].fx_rate = '9.3500';
    window.__buyers = [
      { ticket_id:'tk1', user_id:'u1', name:'윤태호', phone:'010-1111-2222', pax:2 },
      { ticket_id:'tk2', user_id:'u2', name:'김우종', phone:'01033334444', pax:4 },
      { ticket_id:'tk3', user_id:'u3', name:'박지연', phone:null, pax:2 }
    ];
    DB.charges = [
      { id:'c1', event_id:'e1', team_id:'t2', label:'Y様', amount_krw:1122000,
        status:'paid', token:'aa'.repeat(16), user_id:'u1' }
    ];
    await window.kskOpenEvent('e1'); await sleep(180);
    await window.kskSendOpen(); await sleep(320);
    ok('통화 미지정 회원은 원화로 (모르면 원화)',
       [].every.call(document.querySelectorAll('#ksdBody .ksd-row .ksd-cur .seg'),
                     sg => sg.querySelector('span.on').textContent === '₩'));

    // ── ⑪ 수동 입력 전환 ─────────────────────────────────────
    await window.kskSendOpen(); await sleep(300);
    ok('처음엔 티켓 모드', document.getElementById('ksdBody').textContent.indexOf('판매 티켓') >= 0);
    window.kskSendManual(); await sleep(120);
    ok('수동으로 바꾸면 티켓 선택이 사라진다',
       document.getElementById('ksdBody').textContent.indexOf('판매 티켓') < 0);
    ok('구매자 줄이 걷힌다',
       document.getElementById('ksdBody').textContent.indexOf('구매자 ·') < 0);
    rows = document.querySelectorAll('#ksdBody .ksd-row[data-i]');
    ok('빈 줄 하나로 시작한다', rows.length === 1 && !!rows[0].querySelector('input.nm'));
    ok('체크박스가 켜져 보인다', !!document.querySelector('#ksdBody .ksd-chk.on'));
    window.kskSendManual(); await sleep(200);
    ok('다시 끄면 티켓 모드로 돌아온다',
       document.getElementById('ksdBody').textContent.indexOf('판매 티켓') >= 0);
    window.kskSendClose(); await sleep(80);

    // ── ⑫ 링크 끊기 ──────────────────────────────────────────
    DB.charges.push({ id:'c9', event_id:'e1', team_id:null, label:'잘못보냄',
                      amount_krw:1000, status:'pending', token:'cc'.repeat(16) });
    await window.kskOpenEvent('e1'); await sleep(180);
    ok('조 없는 청구도 회수 현황에 보인다',
       document.getElementById('kskBody').textContent.indexOf('잘못보냄') >= 0);
    window.confirm = () => true;
    RPC.length = 0;
    await window.kskCancelCharge('c9', '잘못보냄'); await sleep(250);
    ok('끊기 RPC 를 부른다',
       RPC.some(x => x[0] === 'taam_kashikiri_charge_cancel' && x[1].p_charge_id === 'c9'));
    window.sb.rpc = realRpc;

    // ── ⑧ 토스트가 아래로 새지 않는다 ────────────────────────
    //   배너는 top:20px 이고 그 아래에 콘솔 헤더의 ✕(앱으로 나가기)가 있다.
    //   pointer-events:none 이면 탭이 그대로 통과해 앱 밖으로 나갔다.
    const tb = document.getElementById('toastBanner');
    tb.classList.add('show'); tb.style.display = 'flex';
    ok('떠 있는 토스트는 탭을 삼킨다', getComputedStyle(tb).pointerEvents === 'auto');
    tb.classList.remove('show');
    ok('숨은 토스트는 화면을 막지 않는다', getComputedStyle(tb).pointerEvents === 'none');

    // ── 뒤로가기 ────────────────────────────────────────────
    await window.kskOpenEvent('e1'); await sleep(150);
    window.kskBack(); await sleep(120);
    ok('상세에서 뒤로 = 목록', document.getElementById('kskTitle').textContent === '정산 링크');

    return out;
  });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 6).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : '=== 전부 통과 ==='));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
