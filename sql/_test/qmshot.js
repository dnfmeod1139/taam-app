const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);

  const r = await p.evaluate(() => {
    const out = []; const ok = (n, c) => out.push((c ? 'OK   ' : 'FAIL ') + n);

    // 어드민 화면을 열어 메뉴가 훑히게 한다
    window._currentRole = 'superadmin';
    const adm = document.getElementById('adminScreen');
    adm.style.display = 'flex';
    adm.classList.remove('ac-lean');
    const rows = _moScan();
    ok('어드민 메뉴를 훑는다 (' + rows.length + '개)', rows.length > 10);

    // 키는 동작으로 잡는다 — 같은 항목이면 같은 키
    const k1 = _qmKey(rows[0]), k2 = _qmKey(rows[0]);
    ok('같은 항목 → 같은 키', k1 === k2 && !!k1);
    const uniq = new Set(rows.map(_qmKey));
    ok('키가 대체로 유일 (' + uniq.size + '/' + rows.length + ')', uniq.size >= rows.length - 2);

    // 기본값 — 빈 칸을 주지 않는다
    localStorage.removeItem(_qmLsKey());
    window._qmCfg = null; window._qmCfgRole = null; window._qmPulled = true;
    const body = document.getElementById('tbBody');
    const keep = body ? body.innerHTML : null;
    const html = _qmHtml();
    ok('머리글 「자주 쓰는 메뉴」', html.indexOf('자주 쓰는 메뉴') >= 0);
    ok('편집 버튼이 있다',        html.indexOf('qmOpenEdit()') >= 0);
    ok('기본값이 비어 있지 않다 (' + _qmCfg.length + ')', _qmCfg.length > 0);
    ok('버튼이 그려진다',         html.indexOf('qm-b') >= 0 && html.indexOf('qmGo(0)') >= 0);
    ok('_qmRows 가 채워진다',     _qmRows.length === _qmCfg.length);

    // 없는 키는 조용히 버린다
    window._qmCfg = ['없는키1', _qmKey(rows[0]), '없는키2'];
    const h2 = _qmHtml();
    ok('못 찾은 키는 버린다', _qmRows.length === 1);

    // 하나도 못 찾으면 안내
    window._qmCfg = ['없는키1'];
    const h3 = _qmHtml();
    ok('전부 못 찾으면 안내 문구', h3.indexOf('qm-empty') >= 0 && _qmRows.length === 0);

    // ── 편집 시트 ──
    window._qmCfg = [_qmKey(rows[0])];
    qmOpenEdit();
    ok('시트가 열린다', getComputedStyle(document.getElementById('qmEditModal')).display === 'flex');
    ok('초안이 현재 설정을 복사', _qmDraft.length === 1 && _qmDraft[0] === _qmKey(rows[0]));
    const eb = document.getElementById('qmEditBody');
    ok('고른 메뉴 줄이 있다',   eb.querySelectorAll('.qm-e').length >= 2);
    ok('추가 버튼이 있다',      eb.querySelectorAll('.qm-e button.add').length > 0);

    // 추가 → 빼기 → 순서 바꾸기
    const before = _qmDraft.length;
    qmAdd(0);
    ok('＋ 로 추가된다', _qmDraft.length === before + 1);
    // 이미 고른 것은 「추가할 수 있는」 목록에서 빠지므로, 중복 방지는 직접 겨눠서 본다
    window._qmAvail = [_qmDraft[0]];
    const n0 = _qmDraft.length;
    qmAdd(0);
    ok('같은 걸 두 번 넣지 않는다', _qmDraft.length === n0);
    const a = _qmDraft[0], bb = _qmDraft[1];
    qmMove(0, 1);
    ok('↓ 로 순서가 바뀐다', _qmDraft[0] === bb && _qmDraft[1] === a);
    qmMove(0, -1);
    ok('맨 위에서 ↑ 는 아무 일 없음', _qmDraft[0] === bb);
    const n1 = _qmDraft.length;
    qmRemove(0);
    ok('✕ 로 빠진다', _qmDraft.length === n1 - 1 && _qmDraft[0] === a);

    // 검색
    _qmQ = 'zzzz없는말zzzz'; qmRenderEdit();
    ok('없는 말로 찾으면 안내', eb.innerHTML.indexOf('에 맞는 것이 없습니다') >= 0);
    _qmQ = ''; qmRenderEdit();

    // 저장 — 기기에 남는다 (서버는 없어도 된다)
    window.sb = null;
    const saved = _qmDraft.slice();
    qmSave();
    ok('시트가 닫힌다', getComputedStyle(document.getElementById('qmEditModal')).display === 'none');
    ok('localStorage 에 남는다',
       JSON.stringify(JSON.parse(localStorage.getItem(_qmLsKey()))) === JSON.stringify(saved));
    ok('_qmCfg 가 갱신된다', JSON.stringify(_qmCfg) === JSON.stringify(saved));

    // 다시 읽으면 그대로
    window._qmCfg = null; window._qmCfgRole = null;
    _qmHtml();
    ok('다시 열어도 그대로', JSON.stringify(_qmCfg) === JSON.stringify(saved));

    // 편집 중에는 배포가 화면을 끊지 않는다
    qmOpenEdit();
    ok('편집 중 _taamBusyNow', _taamBusyNow() === 'qmEditModal');
    qmCloseEdit();

    localStorage.removeItem(_qmLsKey());
    if(body && keep !== null) body.innerHTML = keep;
    adm.style.display = 'none';
    return out;
  });
  r.forEach(l => console.log(l));
  console.log('pageerror:', errs.length ? errs.join(' | ') : '없음');
  console.log(r.some(l => l.startsWith('FAIL')) || errs.length ? '\n=== 실패 있음 ===' : '\n=== 전부 통과 ===');
  await b.close();
})();
