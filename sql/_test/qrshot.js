// ═══════════════════════════════════════════════════════════════
// 결제 QR — 앱이 그린 코드를 **되읽어서** 검증 (2026-09-02)
// ═══════════════════════════════════════════════════════════════
// 「QR 처럼 생겼다」는 검증이 아니다. 잘못 만든 QR 도 QR 처럼 생겼고,
// 그건 손님이 자리에서 폰을 들이대 봐야 알게 된다 — 제일 나쁜 순간이다.
// 그래서 앱이 만든 매트릭스를 픽셀로 펼쳐 jsQR 로 디코드하고,
// 원문 URL 과 한 글자도 안 어긋나는지 본다.
//
//   ① 인코더가 실제로 읽히는가 (무작위 토큰 200개 포함)
//   ② 시트가 통화별로 손님 언어를 고르는가
//   ③ 결제된 사람에게는 QR 을 안 내미는가  ← 두 번 받는 사고
//   ④ ‹ › 로 한 바퀴 도는가
//
// 실행: node sql/_test/qrshot.js
// ═══════════════════════════════════════════════════════════════
const { chromium } = require('playwright-core');
const jsQR = require('jsqr');

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const out = [];
  const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

  // ── ① 인코더 — 앱 안의 _qrMake 를 그대로 꺼내 되읽는다 ─────
  //   매트릭스를 흑백 픽셀로 펼치는 것까지가 앱 몫이고, 읽는 건 jsQR 이다.
  const decode = async (text) => {
    const q = await p.evaluate(t => {
      const r = window._qrMake(t);
      return r ? { n: r.n, m: r.m } : null;
    }, text);
    if (!q) return null;
    const scale = 6, quiet = 4, W = (q.n + quiet * 2) * scale;
    const buf = new Uint8ClampedArray(W * W * 4).fill(255);
    for (let y = 0; y < W; y++) for (let x = 0; x < W; x++) {
      const mx = Math.floor(x / scale) - quiet, my = Math.floor(y / scale) - quiet;
      if (mx >= 0 && mx < q.n && my >= 0 && my < q.n && q.m[my][mx]) {
        const o = (y * W + x) * 4; buf[o] = buf[o + 1] = buf[o + 2] = 0;
      }
    }
    const r = jsQR(buf, W, W);
    return r ? r.data : null;
  };

  const PAY = 'https://taam-app.vercel.app/pay/?t=';
  ok('결제 링크가 되읽힌다',   await decode(PAY + 'a'.repeat(32)) === PAY + 'a'.repeat(32));
  ok('시트 링크가 되읽힌다',
     await decode('https://taam-app.vercel.app/sheet/?t=' + '9c'.repeat(16))
       === 'https://taam-app.vercel.app/sheet/?t=' + '9c'.repeat(16));
  ok('짧은 것도',             await decode('https://playtaam.com') === 'https://playtaam.com');
  ok('한 글자도',             await decode('A') === 'A');
  ok('일본어도 (UTF-8)',      await decode('鮨 めい乃 ¥120,000') === '鮨 めい乃 ¥120,000');
  ok('한글도',                await decode('김우종 ₩1,122,000') === '김우종 ₩1,122,000');
  // 버전 경계 — 여기서 한 칸이 어긋나면 특정 길이에서만 조용히 깨진다
  for (const n of [62, 63, 84, 85, 106, 122, 213]) {
    ok('경계 ' + n + '자', await decode('x'.repeat(n)) === 'x'.repeat(n));
  }
  ok('너무 길면 null (깨진 QR 을 안 그린다)',
     await p.evaluate(() => window._qrMake('x'.repeat(400)) === null));

  // 어쩌다 한 번 깨지는 게 제일 무섭다 — 실제 토큰 모양으로 200개
  let bad = 0;
  for (let i = 0; i < 200; i++) {
    let tok = '';
    for (let k = 0; k < 32; k++) tok += '0123456789abcdef'[Math.floor(Math.random() * 16)];
    if (await decode(PAY + tok) !== PAY + tok) bad++;
  }
  ok('무작위 토큰 200개 전부 되읽힌다' + (bad ? ' (' + bad + '건 실패)' : ''), bad === 0);

  // ── ②③④ 시트 ───────────────────────────────────────────────
  const r2 = await p.evaluate(async () => {
    const o = [];
    const okk = (n, c) => o.push((c ? 'OK   ' : 'FAIL ') + n);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    document.getElementById('appWrapper').classList.add('ready');
    const ms = document.getElementById('mainScreen'); if (ms) ms.style.display = 'flex';
    window.showToast = (a, b2, c) => { window.__toast = [a, b2, c]; };

    window._kskCur = {
      ev: { id: 'e1', venue_name: '鮨 めい乃', event_date: '2027-01-01', total_krw: 4000000 },
      teams: [], guests: [],
      charges: [
        { id:'c1', label:'Y様',     token:'aa'.repeat(16), status:'pending',
          amount_krw:1122000, pay_currency:'JPY', pay_amount:120000 },
        { id:'c2', label:'Mr. Lee', token:'bb'.repeat(16), status:'pending',
          amount_krw:1400000, pay_currency:'USD', pay_amount:1015.94 },
        { id:'c3', label:'김우종',   token:'cc'.repeat(16), status:'pending',
          amount_krw:1122000, pay_currency:'KRW' },
        { id:'c4', label:'낸사람',   token:'dd'.repeat(16), status:'paid',    amount_krw:100000 },
        { id:'c5', label:'끊은건',   token:'ee'.repeat(16), status:'cancelled', amount_krw:100000 }
      ]
    };

    window.kskQrOpen('c1'); await sleep(120);
    const sheet = document.getElementById('kskQr');
    okk('QR 시트가 열린다', sheet.style.display === 'flex');
    okk('그 사람부터 보여준다', document.getElementById('kqrWho').textContent === 'Y様');
    okk('QR 이 그려졌다', !!document.querySelector('#kqrBox svg'));

    // ② 통화 = 손님. 금액도 안내도 그 사람 것으로.
    okk('엔화 손님 — ¥ 로 크게', document.getElementById('kqrAmt').textContent === '¥120,000');
    okk('엔화 손님 — 원화 기준을 작게',
        document.getElementById('kqrSub').textContent.indexOf('₩1,122,000') >= 0);
    let tip = document.getElementById('kqrTip');
    okk('엔화 손님 — 일본어가 맨 위 ⭐',
        tip.firstElementChild.textContent.indexOf('カメラ') >= 0);
    okk('엔화 손님 — 한국어·영어도 작게 남는다',
        tip.textContent.indexOf('카메라로') >= 0 && tip.textContent.indexOf('Point your') >= 0);

    window.kskQrStep(1); await sleep(80);
    okk('달러 손님 — $ 로', document.getElementById('kqrAmt').textContent === '$1,015.94');
    okk('달러 손님 — 영어가 맨 위',
        document.getElementById('kqrTip').firstElementChild.textContent.indexOf('Point your') >= 0);

    window.kskQrStep(1); await sleep(80);
    okk('원화 손님 — ₩ 로', document.getElementById('kqrAmt').textContent === '₩1,122,000');
    okk('원화 손님 — 환산 줄이 비어 있다',
        document.getElementById('kqrSub').textContent === '');
    okk('원화 손님 — 한국어가 맨 위',
        document.getElementById('kqrTip').firstElementChild.textContent.indexOf('카메라로') >= 0);

    // ③ 결제된 사람·끊은 링크는 아예 목록에 없다
    okk('미결제 3명만 순회한다 ⭐', document.getElementById('kqrNav').textContent === '3 / 3');
    okk('결제된 사람은 안 나온다',
        document.getElementById('kskQr').textContent.indexOf('낸사람') < 0);

    // ④ 한 바퀴
    window.kskQrStep(1); await sleep(80);
    okk('끝에서 처음으로 돌아온다', document.getElementById('kqrWho').textContent === 'Y様');
    window.kskQrStep(-1); await sleep(80);
    okk('뒤로도 돈다', document.getElementById('kqrWho').textContent === '김우종');

    // URL 이 화면에도 남는다 (카메라가 안 될 때 불러 줄 수 있어야 한다)
    okk('링크가 글자로도 보인다',
        /\/pay\/\?t=c{32}$/.test(document.getElementById('kqrUrl').textContent));

    // 복사
    let copied = null;
    navigator.clipboard.writeText = (t) => { copied = t; return Promise.resolve(); };
    window.kskQrCopy(); await sleep(120);
    okk('링크 복사가 그 사람 것', copied && /\/pay\/\?t=c{32}$/.test(copied));

    // 닫기
    window.kskQrClose(); await sleep(60);
    okk('닫힌다', sheet.style.display === 'none');
    okk('닫으면 QR 을 지운다 (다음 사람 것이 잠깐 비치지 않게)',
        document.getElementById('kqrBox').innerHTML === '');

    // 전부 결제된 회차에서는 열리지 않는다
    window._kskCur.charges.forEach(c => { c.status = 'paid'; });
    window.__toast = null;
    window.kskQrOpen(); await sleep(80);
    okk('전부 결제됐으면 안 열린다',
        sheet.style.display === 'none' && window.__toast && window.__toast[1] === '전부 결제됨');

    // 가로 스크롤 금지 (다른 시트와 같은 규칙)
    okk('세로 제스처만 받는다',
        getComputedStyle(sheet).touchAction === 'pan-y');
    return o;
  });

  // ── ⑤ 화면에 그려진 그림 자체를 되읽는다 ──────────────────
  //   매트릭스가 맞아도 여백(quiet zone)이 없거나 눌려 찌그러지면 안 읽힌다.
  //   그건 매트릭스 검사로는 안 잡히고, 손님이 폰을 들이대야 알게 된다.
  await p.addScriptTag({ path: require.resolve('jsqr/dist/jsQR.js') });
  const rendered = await p.evaluate(async () => {
    const url = 'https://taam-app.vercel.app/pay/?t=' + 'a1b2c3d4e5f60718293a4b5c6d7e8f90'.slice(0,32);
    // ⚠ 시트를 열어 둔 채로 재야 한다. 닫힌 상자는 폭이 0 이라 아무것도 검증하지 못한다.
    window._kskCur.charges[0].status = 'pending';
    window.kskQrOpen('c1');
    await new Promise(r => setTimeout(r, 120));
    const box = document.getElementById('kqrBox');
    box.innerHTML = window._qrSvg(url);
    const svg = new XMLSerializer().serializeToString(box.querySelector('svg'));
    const img = new Image();
    await new Promise((res, rej) => {
      img.onload = res; img.onerror = rej;
      img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
    });
    // 화면에 실제로 잡히는 크기 그대로 그린다 (236px 상자 - 8px 안여백)
    const W = Math.round(box.getBoundingClientRect().width) - 16;
    const cv = document.createElement('canvas');
    cv.width = cv.height = W;
    const cx = cv.getContext('2d');
    cx.fillStyle = '#fff'; cx.fillRect(0, 0, W, W);
    cx.drawImage(img, 0, 0, W, W);
    const d = cx.getImageData(0, 0, W, W);
    const r = window.jsQR(d.data, W, W);
    return { px: W, got: r ? r.data : null, want: url };
  });
  ok('화면에 그려진 QR 이 실제로 읽힌다 ⭐ (' + rendered.px + 'px)',
     rendered.got === rendered.want);

  out.push(...r2);
  out.forEach(l => console.log(l));
  if (errs.length) { console.log('\n페이지 오류:'); errs.slice(0, 5).forEach(e => console.log('  ' + e)); }
  const nbad = out.filter(l => l.startsWith('FAIL')).length;
  console.log('\n' + (nbad ? `=== 실패 ${nbad}건 ===` : `=== 전부 통과 (${out.length}건) ===`));
  await b.close();
  process.exit(nbad ? 1 : 0);
})();
