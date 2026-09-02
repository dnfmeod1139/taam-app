// ═══════════════════════════════════════════════════════════════
// 계보도 줄바꿈 — 단어 중간에서 끊기지 않는가 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
// 브라우저 기본값은 한글을 **글자 단위**로 끊는다. 그래서 「니혼바시
// 카키가라쵸에서」가 「니혼바시 카키가라 / 쵸에서」처럼 잘렸다.
//
// 여기서 보는 것 — 「CSS 를 넣었다」가 아니라 **실제로 어디서 끊기는가**:
//   ① 계보도 글자 요소에 keep-all 이 다 걸렸는가
//   ② 실제 렌더에서 줄이 **띄어쓰기·문장부호에서만** 바뀌는가
//   ③ ⚠ 그런데 옆으로 넘치지는 않는가 (keep-all 만 걸면 넘친다)
//   ④ 긴 영문 상호·URL 도 갇히는가
//   ⑤ 계보도 밖 화면은 안 건드렸는가
//
// 실행: node sql/_test/wrapshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');

// 실제 설명은 DB 에서 온다. 대표 문장으로 CSS 를 잰다.
const KO = '스기타 타카아키는 니혼바시 카키가라쵸에서 자신의 이름을 건 가게를 열었다. '
  + '수련 시절부터 이어온 에도마에 전통을 지키면서도, 계절 재료의 성질에 따라 '
  + '숙성 시간을 달리하는 방식으로 자신만의 결을 만들어 왔다. '
  + '카운터 여덟 석, 하루 두 번의 자리만을 받는다.';
const LONG = '니혼바시카키가라쵸스기타에서수련한뒤독립한제자들의계보를한눈에보여줍니다';
const URL  = 'https://tabelog.com/tokyo/A1302/A130202/13141234/dtlrvwlst/';

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(({ KO, LONG, URL }) => {
    const out = [];
    const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    const lm = document.getElementById('lineageModule');

    // ── ① 적용 범위 ──────────────────────────────────────────
    const els = Array.from(lm.querySelectorAll('*'))
      .filter(e => e.children.length === 0 && /[가-힣]/.test(e.textContent || ''));
    const keep = els.filter(e => getComputedStyle(e).wordBreak === 'keep-all').length;
    const wrap = els.filter(e => {
      const w = getComputedStyle(e).overflowWrap;
      return w === 'break-word' || w === 'anywhere';
    }).length;
    ok('계보도 글자에 keep-all 이 빠짐없이 (' + keep + '/' + els.length + ') ⭐',
       els.length > 0 && keep === els.length);
    ok('넘침 대비도 빠짐없이 (' + wrap + '/' + els.length + ') ⭐',
       els.length > 0 && wrap === els.length);
    // ⚠ anywhere 는 min-content 폭까지 바꿔 칸 크기가 흔들린다
    ok('anywhere 가 아니라 break-word ⭐',
       els.every(e => getComputedStyle(e).overflowWrap !== 'anywhere'));

    // ── ②③④ 실제 렌더 ───────────────────────────────────────
    // 계보도 설명 칸과 같은 조건(폭·글꼴·크기)을 만들어 재운다.
    function measure(text, cls, width){
      const host = document.createElement('div');
      host.style.cssText = 'position:fixed;left:0;top:0;width:' + width + 'px;'
        + 'visibility:hidden;z-index:-1';
      const el = document.createElement('div');
      el.className = cls;
      el.textContent = text;
      host.appendChild(el);
      lm.appendChild(host);            // ← 계보도 안에 넣어야 그 CSS 를 받는다
      const n = el.firstChild;
      const rg = document.createRange();
      let prevTop = null, breaks = [], mid = [];
      for (let i = 0; i < text.length; i++) {
        rg.setStart(n, i); rg.setEnd(n, i + 1);
        const rc = rg.getClientRects()[0];
        if (!rc) continue;
        if (prevTop !== null && rc.top > prevTop + 2) {
          breaks.push(i);
          const before = text[i - 1] || '', at = text[i] || '';
          const spaceBreak = /\s/.test(before) || /\s/.test(at);
          const punct = /[.,·)\]」』…!?~\/]/.test(before);
          if (!spaceBreak && !punct) mid.push(text.slice(Math.max(0,i-8), i) + '↵' + text.slice(i, i+8));
        }
        prevTop = rc.top;
      }
      const over = el.scrollWidth > el.clientWidth + 1;
      host.remove();
      return { lines: breaks.length + 1, mid, over };
    }

    const m = measure(KO, 'is2-desc', 320);
    ok('여러 줄로 흐른다 (' + m.lines + '줄)', m.lines >= 3);
    ok('단어 중간에서 안 끊긴다 ⭐' + (m.mid.length ? ' — ' + m.mid[0] : ''), m.mid.length === 0);
    ok('옆으로 안 넘친다 ⭐', !m.over);

    // ④ 띄어쓰기 없는 긴 덩어리 — 넘치는 대신 안에서 끊겨야 한다
    const l = measure(LONG, 'is2-desc', 320);
    ok('띄어쓰기 없는 긴 글도 갇힌다 ⭐', !l.over && l.lines >= 2);
    const u = measure(URL, 'is2-desc', 320);
    ok('긴 URL 도 갇힌다 ⭐', !u.over);

    // 좁은 칸에서도
    const nm = measure(KO, 'is2-desc', 200);
    ok('좁은 칸에서도 단어를 안 자른다', nm.mid.length === 0 && !nm.over);

    // 다른 계보도 클래스에서도 같은가
    ['is2-name','is2-sub','lh-t','lge-mi-n','cnt-folder-sub'].forEach(function(c){
      const x = measure(KO, c, 300);
      ok(c + ' — 단어를 안 자른다', x.mid.length === 0);
    });

    // ── ⑤ 상속으로 건다 ──────────────────────────────────────
    //   word-break 는 상속 속성이다. body 한 줄이 아래로 다 내려간다 —
    //   클래스마다 적으면 다음에 새 규칙을 넣는 사람이 반드시 빠뜨린다.
    ok('body 한 곳에 걸었다 ⭐', getComputedStyle(document.body).wordBreak === 'keep-all');

    // ⚠ 그런데 **일부러 break-all 을 건 자리**는 그대로여야 한다.
    //   URL·주문번호·이메일은 단어 단위로 끊으면 통째로 넘친다.
    //   상속이라 자기 선언이 있는 곳은 그대로 이긴다 — 덮어쓰기 싸움이 없다.
    const url = document.getElementById('kqrUrl');
    ok('결제 QR URL 은 그대로 break-all ⭐',
       !!url && getComputedStyle(url).wordBreak === 'break-all');

    // ── ⑥ 계보도 밖에도 다 내려갔나 ──────────────────────────
    //   계보도만의 문제가 아니었다. 긴 한글 문장이 있는 화면이 다 같았다.
    let miss = [];
    Array.from(document.querySelectorAll('body > div[id], .sub-screen[id]'))
      .filter(e => e.id).forEach(root => {
        const es = Array.from(root.querySelectorAll('*')).filter(e => {
          if (e.children.length) return false;
          const t = (e.textContent || '').trim();
          return /[가-힣]/.test(t) && t.length >= 25;
        });
        const bad = es.filter(e => getComputedStyle(e).wordBreak !== 'keep-all').length;
        if (bad) miss.push(root.id + '(' + bad + ')');
      });
    ok('긴 한글 문장이 전부 keep-all ⭐' + (miss.length ? ' — 남음: ' + miss.slice(0,4).join(' ') : ''),
       miss.length === 0);

    // ── ⑦ 일본어 ─────────────────────────────────────────────
    //   일본어는 원래 아무 데서나 끊긴다. keep-all 이 걸리면 문장 전체가
    //   한 덩어리가 되는데, overflow-wrap 이 받아 결국 같은 자리에서 끊긴다.
    //   여기서 볼 것은 「넘치지 않는가」 하나다.
    const JA = '杉田孝明は日本橋蠣殻町に自らの名を冠した店を構えた。'
             + '修業時代から受け継いだ江戸前の伝統を守りながら、季節の素材の性質に応じて'
             + '熟成の時間を変える方法で自分の流儀を築いてきた。';
    const j = measure(JA, 'is2-desc', 320);
    ok('일본어도 옆으로 안 넘친다 ⭐', !j.over);
    ok('일본어도 여러 줄로 흐른다 (' + j.lines + '줄)', j.lines >= 3);
    // 일본어 화면에서는 keep-all 을 되돌린다 — 일본어는 원래 아무 데서나 끊는다
    const savedLang = document.documentElement.lang;
    document.documentElement.lang = 'ja';
    ok('일본어 화면에서는 keep-all 을 안 건다 ⭐',
       getComputedStyle(document.body).wordBreak === 'normal');
    document.documentElement.lang = 'ko';
    ok('한국어로 돌아오면 다시 keep-all ⭐',
       getComputedStyle(document.body).wordBreak === 'keep-all');
    document.documentElement.lang = savedLang;

    return out;
  }, { KO, LONG, URL });

  r.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const bad = r.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (bad ? `=== 실패 ${bad}건 ===` : `=== 전부 통과 (${r.length}건) ===`));
  await b.close();
  process.exit(bad ? 1 : 0);
})();
