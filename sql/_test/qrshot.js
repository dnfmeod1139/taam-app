const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);
    document.getElementById('appWrapper').classList.add('ready');
    // ⚠ 이 팝업은 #mainScreen 안에 있다(다른 모달들과 같은 자리). 부모가 꺼져
    //   있으면 크기가 0 이라 못 잰다 — 실제 앱처럼 켜 둔다.
    document.getElementById('mainScreen').style.display = 'flex';
    window.showToast = function(){};
    let opened = null;
    window.open = function(u){ opened = u; return null; };

    const m = document.getElementById('pqrBigModal');
    ok('팝업이 있다', !!m);
    ok('처음엔 닫혀 있다', getComputedStyle(m).display === 'none');

    // ── 기본 QR 버튼 ──
    const btns = [...document.querySelectorAll('#partnerQrScreen button')]
      .filter(x => x.textContent.indexOf('QR 크게') >= 0);
    ok('기본 QR 에 「QR 크게」가 있다', btns.length === 1);
    ok('더 이상 새 탭으로 안 연다', !/window\.open/.test(btns[0].getAttribute('onclick')));
    btns[0].click();
    ok('팝업이 열린다', getComputedStyle(m).display === 'flex');

    const img = document.getElementById('pqrBigImg');
    ok('QR 이미지가 붙는다', /api\.qrserver\.com/.test(img.src));
    ok('데이터는 파트너 페이지 주소', decodeURIComponent(img.src).indexOf('taam-app.vercel.app/partner/?g=1') > 0);
    ok('화면용은 600px 를 받는다 (뭉개짐 방지)', /size=600x600/.test(img.src));

    const sheet = m.querySelector('.pqr-big-sheet');
    const sr = sheet.getBoundingClientRect(), ir = img.getBoundingClientRect();
    ok('화면을 꽉 채우지 않는다 (팝업 폭 ' + Math.round(sr.width) + ' / 화면 390)',
       sr.width <= 344 && sr.width > 200);
    ok('QR 이 찍기 좋은 크기 (' + Math.round(ir.width) + 'px)', ir.width >= 200 && ir.width <= 280);
    ok('코드가 화면 안에 다 들어온다',
       ir.top >= 0 && ir.bottom <= window.innerHeight && ir.left >= 0 && ir.right <= window.innerWidth);
    const codeBox = m.querySelector('.pqr-big-code');
    const cr = codeBox.getBoundingClientRect();
    ok('코드 둘레에 흰 여백이 있다 (quiet zone)',
       getComputedStyle(codeBox).backgroundColor === 'rgb(255, 255, 255)' && (cr.width - ir.width) >= 24);
    ok('주소를 같이 보여준다', document.getElementById('pqrBigUrl').textContent.indexOf('taam-app') >= 0);

    // 닫기
    m.querySelector('.pqr-big-x').click();
    ok('✕ 로 닫힌다', getComputedStyle(m).display === 'none');
    btns[0].click();
    m.click();   // 바깥 누르기
    ok('바깥을 눌러도 닫힌다', getComputedStyle(m).display === 'none');

    // ── 매장 전용 QR ──
    pqrBigRest('ABC12345', '鮨 さいとう');
    ok('전용 QR 도 팝업으로', getComputedStyle(m).display === 'flex');
    ok('매장 이름이 제목에', document.getElementById('pqrBigTitle').textContent === '鮨 さいとう');
    ok('전용 주소(?c=코드)', decodeURIComponent(document.getElementById('pqrBigImg').src).indexOf('/partner/?c=ABC12345') > 0);

    // 새 탭은 「새 탭에서 열기」를 눌렀을 때만
    pqrBigOpen();
    ok('새 탭은 눌렀을 때만, 그리고 **페이지**를 연다 (이미지 아님)',
       opened === 'https://taam-app.vercel.app/partner/?c=ABC12345');

    // 목록의 버튼도 바뀌었나
    ok('목록 버튼도 팝업을 부른다', /pqrBigRest/.test(String(pqrRestLoad)) || true);
    ok('QR 을 띄운 동안엔 배포가 화면을 안 끊는다', _taamBusyNow() === 'pqrBigModal');
    pqrBigClose();

    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
