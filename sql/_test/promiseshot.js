// ═══════════════════════════════════════════════════════════════
// 파트너 제안 「우리의 약속」 — 3개 언어 검증
//   일본 매장 안내문(taam_goannai_ja.pdf)을 그대로 옮겼는지,
//   한국어·영어에 빠진 항목이 없는지 본다.
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 430, height: 1200 } });
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.route('**://fonts.g**', r => r.abort());
  // ⚠ 서버를 안 부른다 — 실패하면 render(generic) 로 떨어지는 경로를 쓴다
  await p.route('**/rest/v1/**', r => r.abort());
  await p.goto('file:///home/user/taam-app/partner/index.html?g=1', { waitUntil: 'commit' });
  await p.waitForTimeout(1500);

  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  for (const [lang, want] of [
    ['ja', { head:'予約サイトでは、ありません。', one:'客は、全員審査済み。',
             foot:'信頼できるお客様だけ', five:'窓口は、Woo 一人。' }],
    ['ko', { head:'예약 사이트가 아닙니다.', one:'손님은 전원 심사를 거칩니다.',
             foot:'한국의 파트너이고 싶습니다', five:'창구는 Woo 한 사람.' }],
    ['en', { head:'We are not a booking site.', one:'Every guest is screened.',
             foot:'partner in Korea', five:'One point of contact' }]
  ]) {
    await p.evaluate(l => window.pvSetLang(l), lang);
    await p.waitForTimeout(200);
    const g = await p.evaluate(() => ({
      head: document.getElementById('promiseTitle').textContent,
      lead: document.getElementById('promiseLead').textContent,
      items: [...document.querySelectorAll('#promiseList li')].map(li => ({
        no: li.querySelector('.no').textContent,
        t: li.querySelector('.t').textContent,
        d: li.querySelector('.d').textContent })),
      foot: document.getElementById('promiseFoot').textContent,
      footColor: getComputedStyle(document.getElementById('promiseFoot')).color
    }));
    ok(lang + ' — 제목', g.head === want.head);
    ok(lang + ' — 다섯 줄 ⭐', g.items.length === 5);
    ok(lang + ' — 첫째', g.items[0] && g.items[0].t === want.one);
    ok(lang + ' — 다섯째', g.items[4] && g.items[4].t.indexOf(want.five) >= 0);
    ok(lang + ' — 맺음말', g.foot.indexOf(want.foot) >= 0);
    // ⚠ 번호는 세로쓰기 한자 그대로 — 언어가 바뀌어도 유지된다
    ok(lang + ' — 번호가 壱〜伍', g.items.map(x=>x.no).join('') === '壱弐参肆伍');
    // 빈 칸이 하나라도 있으면 번역 누락이다
    ok(lang + ' — 빈 항목 없음 ⭐',
       g.lead.trim() && g.items.every(x => x.t.trim() && x.d.trim()) && g.foot.trim());
    // 다른 언어가 새어 나오지 않는가 (ko/en 화면에 일본어 가나)
    const all = g.head + g.lead + g.items.map(x=>x.t+x.d).join('') + g.foot;
    if (lang !== 'ja') ok(lang + ' — 일본어가 안 섞인다 ⭐', !/[ぁ-んァ-ヶ]/.test(all));
    if (lang === 'en') ok('en — 한글이 안 섞인다 ⭐', !/[가-힣]/.test(all));
    if (lang === 'ko') ok('ko — 한글로 적혔다', /[가-힣]/.test(all));
  }
  // 소개 바로 다음에 온다 (안내문의 흐름)
  const order = await p.evaluate(() => {
    const ids = [...document.querySelectorAll('section')].map(s =>
      (s.querySelector('h2') || {}).id || '');
    return { a: ids.indexOf('aboutTitle'), p: ids.indexOf('promiseTitle'),
             t: ids.indexOf('termsTitle'), mem: ids.indexOf('memTitle') };
  });
  ok('소개 → 약속 → 조건 순서 ⭐', order.a >= 0 && order.p === order.a + 1 && order.t === order.p + 1);
  // ⚠ 「모시는 고객」은 없앴다 — 약속 ① 과 같은 이야기였다
  ok('회원 섹션이 따로 안 남았다 ⭐', order.mem < 0);

  // ── 겹치던 내용이 약속 아래로 옮겨졌는가 ────────────────────
  for (const lang of ['ja','ko','en']) {
    await p.evaluate(l => window.pvSetLang(l), lang);
    await p.waitForTimeout(200);
    const g = await p.evaluate(() => {
      const li = [...document.querySelectorAll('#promiseList li')];
      return {
        sub: li.map(x => [...x.querySelectorAll('.sub .st')].map(e => e.textContent)),
        smplIn: li.findIndex(x => x.querySelector('.smpl')),
        smplCount: document.querySelectorAll('.smpl').length,
        terms: [...document.querySelectorAll('#termsRows h3')].map(e => e.textContent)
      };
    });
    ok(lang + ' — ① 아래 네 가지 자질 ⭐', g.sub[0].length === 4);
    ok(lang + ' — ② 아래 결제·취소 ⭐',   g.sub[1].length === 2);
    ok(lang + ' — ⑤ 아래 대관 동석 ⭐',   g.sub[4].length === 1);
    ok(lang + ' — ③·④ 는 군더더기 없음',  !g.sub[2].length && !g.sub[3].length);
    // 견본은 ③(정보는 미리) 아래 딱 하나
    ok(lang + ' — 견본이 ③ 아래 ⭐',      g.smplIn === 2);
    ok(lang + ' — 견본은 하나뿐',          g.smplCount === 1);
    // ⚠ 조건 섹션에는 매장이 정하는 값만. 결제·취소가 또 나오면 두 번 말하는 것이다
    ok(lang + ' — 조건에 결제가 안 겹친다 ⭐', g.terms.length <= 2);
    // ⚠ sb() 의 문장 span 이 블록이어야 한다 — 아니면 「…합니다.TAAM은…」 로 붙는다
    const inline = await p.evaluate(() => [...document.querySelectorAll('.qual .sub .sd .ln')]
      .filter(e => getComputedStyle(e).display !== 'block').length);
    ok(lang + ' — 문장이 안 붙는다 ⭐', inline === 0);

    // ── 지급 방식 ⭐ 돈 이야기라 문구가 흔들리면 안 된다 ──────────
    //   협의한 비용(식사비+미니멈 주류) = 현금 **선납**
    //   손님별 초과 주류·추가 차지     = 당일 현장, 현금 또는 카드(되도록 현금)
    //   ⚠ 「貸切은 선납 / 일반은 현장」이 아니다. 한때 그렇게 적었다가 고쳤다 —
    //     매장의 입금 예정이 어긋난다.
    const pay = await p.evaluate(() => {
      const li = document.querySelectorAll('#promiseList li')[1];
      return { d: li.querySelector('.d').textContent,
               sub: [...li.querySelectorAll('.sub .sd')].map(e => e.textContent).join(' ') };
    });
    const PAY = { ja:{ pre:'先払い', card:'クレジットカード', both:'現金' },
                  ko:{ pre:'선납',   card:'신용카드',        both:'현금' },
                  en:{ pre:'prepaid', card:'credit card',    both:'cash' } }[lang];
    ok(lang + ' — 협의분은 선납이라 적는다 ⭐', pay.d.indexOf(PAY.pre) >= 0);
    ok(lang + ' — 현금이라 적는다 ⭐',          pay.d.indexOf(PAY.both) >= 0);
    ok(lang + ' — 초과분은 카드도 된다 ⭐',     pay.d.indexOf(PAY.card) >= 0);
    // 「당일 현장에서 전부 낸다」로 되돌아가면 안 된다
    const OLD = { ja:'当日その場でお食事代', ko:'당일 현장에서 식사비',
                  en:'pay on site for only the meal' }[lang];
    ok(lang + ' — 옛 지급 문구가 안 남았다 ⭐', (pay.d + pay.sub).indexOf(OLD) < 0);
  }

  // ── 유일한 부탁 ─────────────────────────────────────────────
  //   매장에 드리는 단 하나의 부탁이라 반드시 세 언어 모두에 있어야 한다.
  for (const [lang, want] of [
    ['ja', { pre:'一つだけ', t:'ご予約は、TAAM を通じて。', key:'唯一のお願い' }],
    ['ko', { pre:'한 가지만', t:'예약은, TAAM 을 통해서.',   key:'단 하나의 부탁' }],
    ['en', { pre:'One request', t:'Bookings, through TAAM.', key:'our one request' }]
  ]) {
    await p.evaluate(l => window.pvSetLang(l), lang);
    await p.waitForTimeout(200);
    const a = await p.evaluate(() => {
      const e = document.getElementById('oneAsk');
      const box = e.getBoundingClientRect();
      const list = document.getElementById('promiseList').getBoundingClientRect();
      const foot = document.getElementById('promiseFoot').getBoundingClientRect();
      return { pre: e.querySelector('.pre').textContent, t: e.querySelector('.t').textContent,
               d: e.querySelector('.d').textContent, no: e.querySelector('.no').textContent,
               icon: !!e.querySelector('svg'),
               afterList: box.top >= list.bottom, beforeFoot: box.bottom <= foot.top };
    });
    ok(lang + ' — 부탁 앞줄', a.pre.indexOf(want.pre) >= 0);
    ok(lang + ' — 부탁 제목 ⭐', a.t === want.t);
    ok(lang + ' — 본문이 있다 ⭐', a.d.indexOf(want.key) >= 0);
    ok(lang + ' — 번호가 붙는다', a.no.trim().length > 0);
    ok(lang + ' — ↻ 아이콘', a.icon);
    // ⚠ 다섯 약속 안에 섞이면 여섯 번째 약속처럼 읽힌다 — 목록 **밖**, 맺음말 앞
    ok(lang + ' — 목록 밖 맨 끝에 ⭐', a.afterList && a.beforeFoot);
    ok(lang + ' — 목록은 다섯 줄 그대로',
       (await p.evaluate(() => document.querySelectorAll('#promiseList li').length)) === 5);
  }

  // ── 견본 내용 ───────────────────────────────────────────────
  for (const [lang, want] of [
    ['ja', { kind:'貸切ゲストシート', note:'アプリは不要' }],
    ['ko', { kind:'대관 게스트 시트', note:'앱은 필요 없습니다' }],
    ['en', { kind:'Private Hire Guest Sheet', note:'No app needed' }]
  ]) {
    await p.evaluate(l => window.pvSetLang(l), lang);
    await p.waitForTimeout(200);
    const s = await p.evaluate(() => {
      const e = document.querySelector('.smpl');
      return { kind: e.querySelector('.kind').textContent,
               cards: e.querySelectorAll('.card').length,
               note: e.querySelector('.note').textContent,
               warn: e.querySelectorAll('.ln.warn').length,
               txt: e.textContent };
    });
    ok(lang + ' — 견본 제목', s.kind === want.kind);
    ok(lang + ' — 세 팀', s.cards === 3);
    ok(lang + ' — 「앱 불필요」', s.note.indexOf(want.note) >= 0);
    ok(lang + ' — 알레르기가 눈에 띈다 ⭐', s.warn === 1);
    // ⚠ 실제 시트와 같은 원칙 — 나가는 금액은 「그 매장에서의 지난 회계」뿐
    ok(lang + ' — 지난 회계 두 건만', (s.txt.match(/¥/g) || []).length === 2);
  }

  out.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0,3).forEach(e => console.log('  ' + e)); }
  const bad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
