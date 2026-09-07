// ═══════════════════════════════════════════════════════════════
// i18n 회귀 가드 — EN·JA 화면에 한글이 남아 있는지 본다
//
//   실행:  node sql/_test/i18nshot.js
//   기준선 갱신:  node sql/_test/i18nshot.js --update
//
// 왜 있나
//   번역은 몇 번을 전수 조사해도 새로 짠 화면에서 다시 샌다. 사람이
//   기억으로 막을 수 있는 종류가 아니다. 그래서 「지금보다 나빠지면
//   실패」하는 기준선을 코드로 박아 둔다.
//
//   지금 앱에는 아직 번역되지 않은 한글이 남아 있다(약관 본문, 어드민
//   토스트 등). 그래서 「0건」을 요구하면 첫 실행부터 실패해 아무도 안
//   쓰게 된다. 대신 화면별 잔여 건수를 기준선으로 잡고, 그 수가 늘면
//   실패시킨다. 새로 추가한 화면이 번역 없이 들어오는 순간 걸린다.
//
// 무엇을 안 세나 (의도적 한국어)
//   · data-lang-lock="ko" 하위 — 슈퍼어드민 화면. 한국어가 정답이다
//   · 회원이 입력한 값(이름 등) — 번역 대상이 아니다
//   · script / style / 숨은 요소
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const BASELINE = path.join(__dirname, 'i18n_baseline.json');
const UPDATE = process.argv.includes('--update');

// 회원 동선 화면 — 여기가 새면 회원이 바로 본다
const SCREENS = [
  { id: 'magView',            name: '홈(표지)' },
  { id: 'ticketView',         name: '티켓 목록' },
  { id: 'ticketDetailScreen', name: '티켓 상세' },
  { id: 'requestView',        name: '예약 요청' },
  { id: 'myPage',             name: '마이페이지' },
  { id: 'mshipScreen',        name: '멤버십' },
  { id: 'chargePage',         name: '예치금 충전' },
  { id: 'cardPage',           name: '카드 관리' },
  { id: 'profileEditPage',    name: '프로필 수정' },
  { id: 'taamChatScreen',     name: 'TAAM 챗' },
  { id: 'phoneScreen',        name: '가입/인증' }
];

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 430, height: 1200 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.route('**://fonts.g**', r => r.abort());
  // 서버를 안 부른다 — 정적 UI 와 TX 레이어만 본다
  await p.route('**/rest/v1/**', r => r.abort());
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const found = {};   // { "en/티켓 목록": ["문구", ...] }

  for (const lang of ['en', 'ja']) {
    await p.evaluate(l => {
      try { localStorage.setItem('tkLang', l); } catch (e) {}
      window._tkCurrentLang = l;
      if (typeof _tkCurrentLang !== 'undefined') _tkCurrentLang = l;
      if (typeof applyI18n === 'function') applyI18n(document);
      if (typeof txRestoreAll === 'function') txRestoreAll();
      if (typeof txSweep === 'function') txSweep(document.body);
    }, lang);
    await p.waitForTimeout(400);

    for (const s of SCREENS) {
      const hits = await p.evaluate((args) => {
        const { id } = args;
        const root = document.getElementById(id);
        if (!root) return null;
        // 화면을 강제로 띄운다 — 숨어 있으면 텍스트를 못 읽는다
        const prevDisp = root.style.display;
        root.style.display = 'block';

        const KO = /[가-힣]/;
        const SKIP_TAG = { SCRIPT: 1, STYLE: 1, TEMPLATE: 1, NOSCRIPT: 1 };
        const out = new Set();

        function locked(el) {
          for (let n = el; n && n !== document.body; n = n.parentElement) {
            if (n.getAttribute && n.getAttribute('data-lang-lock') === 'ko') return true;
          }
          return false;
        }

        const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
        let n;
        while ((n = w.nextNode())) {
          const v = (n.nodeValue || '').trim();
          if (!v || !KO.test(v)) continue;
          const pe = n.parentElement;
          if (!pe || SKIP_TAG[pe.tagName]) continue;
          if (locked(pe)) continue;
          out.add(v.slice(0, 80));
        }
        // 속성도 본다 (placeholder / title / aria-label)
        ['placeholder', 'title', 'aria-label'].forEach(a => {
          root.querySelectorAll('[' + a + ']').forEach(el => {
            const v = (el.getAttribute(a) || '').trim();
            if (v && KO.test(v) && !locked(el)) out.add('[' + a + '] ' + v.slice(0, 80));
          });
        });

        root.style.display = prevDisp;
        return [...out];
      }, { id: s.id });

      if (hits === null) continue;          // 그 화면이 이 빌드에 없다
      found[lang + '/' + s.name] = hits.sort();
    }
  }

  await b.close();

  // ── 기준선과 비교 ────────────────────────────────────────────
  const counts = {};
  Object.keys(found).forEach(k => { counts[k] = found[k].length; });

  if (UPDATE || !fs.existsSync(BASELINE)) {
    fs.writeFileSync(BASELINE, JSON.stringify(counts, null, 2) + '\n', 'utf8');
    console.log('기준선을 새로 적었습니다 →', path.relative(process.cwd(), BASELINE));
    Object.keys(counts).sort().forEach(k => console.log('  ' + k + ': ' + counts[k]));
    console.log('\n총 ' + Object.values(counts).reduce((a, c) => a + c, 0) + '건');
    process.exit(0);
  }

  const base = JSON.parse(fs.readFileSync(BASELINE, 'utf8'));
  const lines = [];
  let bad = 0, better = 0;

  Object.keys(counts).sort().forEach(k => {
    const now = counts[k], was = (k in base) ? base[k] : 0;
    if (now > was) {
      bad++;
      lines.push('FAIL ' + k + ' — ' + was + ' → ' + now + ' (한글 ' + (now - was) + '건 늘었다)');
      found[k].slice(0, 12).forEach(t => lines.push('       · ' + t));
    } else if (now < was) {
      better++;
      lines.push('OK   ' + k + ' — ' + was + ' → ' + now + ' (' + (was - now) + '건 줄었다)');
    }
  });

  console.log(lines.join('\n') || '변동 없음');
  if (errs.length) console.log('\npageerror:\n' + errs.slice(0, 5).join('\n'));

  if (bad) {
    console.log('\n❌ ' + bad + '개 화면에서 번역 안 된 한글이 늘었습니다.');
    console.log('   새 UI 를 넣었다면 TRANSLATIONS 에 키를 넣거나 TX_MAP 에 문구를 등록하세요.');
    console.log('   의도한 한국어(슈퍼어드민 화면)라면 data-lang-lock="ko" 를 답니다.');
    console.log('   정말 기준선을 올려야 한다면: node sql/_test/i18nshot.js --update');
    process.exit(1);
  }
  console.log('\n✅ 늘어난 곳 없음' + (better ? ' · ' + better + '개 화면이 좋아졌습니다(기준선을 --update 로 낮추세요)' : ''));
})();
