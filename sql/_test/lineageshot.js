// 계보 i18n 회귀 (2026-09-28) — KO/EN/JA 에서 트리 라벨·노드 이름·팝업·모달이 제 언어로 나오나
//   실행: cd sql/_test && NODE_PATH=<scratch>/node_modules node lineageshot.js
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const p = await b.newPage({ viewport:{width:390,height:900} });
  p.on('pageerror', e => console.log('PAGEERR', e.message.slice(0,160)));
  await p.route('**', r => (r.request().url().startsWith('file:') ? r.continue() : r.abort()));
  await p.goto('file:///home/user/taam-app/index.html', { waitUntil:'domcontentloaded', timeout:60000 });
  await p.waitForTimeout(1200);
  const r = await p.evaluate(async () => {
    const out=[]; const ok=(n,c)=>out.push((c?'OK   ':'FAIL ')+n);
    const rows=[{id:'kyubey1',name:'스시 큐베이 1대',name_en:'Sushi Kyubey 1st',name_jp:'鮨 久兵衛 1代',sub_title:'IMADA HISAJI',sub_en:'IMADA HISAJI',sub_jp:'今田壽治'}];
    window.sb = { from:(t)=>({ select:()=>({ eq:()=>Promise.resolve({data:rows}) }) }) };
    const svg = document.getElementById('loQ'); ok('큐베이 SVG 가 있다', !!svg);
    // 첫 노드의 onclick id 를 rows 에 맞춘다
    const g0 = svg.querySelector('g.nd[onclick]'); const m=(g0.getAttribute('onclick')||'').match(/['"]([^'"]+)['"]/); rows[0].id = m ? m[1] : 'x';
    const axis = () => Array.from(svg.querySelectorAll('text')).map(t=>t.textContent);
    // ── JA ──
    window._tkCurrentLang='ja'; await applyLineageNameOverrides('kyubey');
    let ts = g0.querySelectorAll('text');
    ok('JA: 노드 이름이 name_jp ⭐', ts[0].textContent==='鮨 久兵衛 1代');
    ok('JA: 세대 축 2代 유지', axis().includes('2代'));
    ok('JA: 배지 1935 · 1代 유지', axis().includes('1935 · 1代'));
    // ── EN ──
    window._tkCurrentLang='en'; await applyLineageNameOverrides('kyubey');
    ts = g0.querySelectorAll('text');
    ok('EN: 노드 이름이 name_en ⭐', ts[0].textContent==='Sushi Kyubey 1st');
    ok('EN: 세대 축 2代 → 2nd gen ⭐', axis().includes('2nd gen') && !axis().includes('2代'));
    ok('EN: 배지 → 1935 · 1st gen', axis().includes('1935 · 1st gen'));
    // ── KO ──
    window._tkCurrentLang='ko'; await applyLineageNameOverrides('kyubey');
    ts = g0.querySelectorAll('text');
    ok('KO: 노드 이름 원문 복원', ts[0].textContent==='이마다 히사지' || ts[0].textContent===ts[0].getAttribute('data-ko'));
    ok('KO: 세대 축 2代 → 2대 (한국어) ⭐', axis().includes('2대') && !axis().includes('2代'));
    ok('KO: 배지 → 1935 · 1대', axis().includes('1935 · 1대'));
    // 팝업 본문 마크다운
    ok('팝업 **굵게** → <strong> ⭐', _ndmInline('**秋田**から') === '<strong>秋田</strong>から' && _ndmInline('<b>x</b>').indexOf('&lt;b&gt;')===0);
    // 모달 문구
    window._tkCurrentLang='ja'; showSoldoutModal({name:'鮨 久兵衛'}); const sm=document.getElementById('ticketInfoModal').innerText; closeTicketModal();
    ok('JA: 솔드아웃 모달 일본어 ⭐', sm.indexOf('チケット完売')>=0 && sm.indexOf('通知設定')>=0 && sm.indexOf('솔드아웃')<0);
    window._tkCurrentLang='en'; showMembershipModal('Kyubey'); const mm=document.getElementById('ticketInfoModal').innerText; closeTicketModal();
    ok('EN: 멤버십 모달 영어', mm.indexOf('Members-only ticket')>=0 && mm.indexOf('멤버십')<0);
    window._tkCurrentLang='ja'; showInfoModal(_popL('예약 링크 없음','No reservation link','予約リンクなし'), _popL('a','b','c')); const im=document.getElementById('ticketInfoModal').innerText; closeTicketModal();
    ok('JA: 안내 모달 확인 버튼 → 確認', im.indexOf('確認')>=0);
    // 커스텀 노드 매핑 + 언어 전환 + 저장은 원문
    window._tkCurrentLang='ja';
    const crow={id:'c1',lineage_id:'kyubey',name:'스시 테스트',name_en:'Sushi Test',name_jp:'鮨 テスト',sub_title:'TEST',sub_en:'TEST',sub_jp:'テスト',geometry:{x:1,y:2},sec1_data:{title:'소개',title_jp:'紹介',desc:'본문',desc_jp:'本文'},sec2_data:{}};
    window.sb = { from:(t)=>({ select:()=>({ eq:()=>({ eq:()=>({ then:(f)=>f({data:[crow]}) }) }) }) }) };
    let nodes=null; loadCustomNodes('kyubey', n=>{ nodes=n; }); await new Promise(r=>setTimeout(r,50));
    ok('JA: 커스텀 노드 이름 name_jp ⭐', nodes && nodes[0].name==='鮨 テスト' && nodes[0].sec1Title==='紹介' && nodes[0]._nameKo==='스시 테스트');
    window._tkCurrentLang='en'; _lnCustomNodeLocalize(nodes[0]);
    ok('EN: 언어 전환 후 name_en', nodes[0].name==='Sushi Test');
    ok('EN: sec2 기본 제목 영어', nodes[0].sec2Title==='Signature');
    ok('저장용 원문은 그대로 (_nameKo)', nodes[0]._nameKo==='스시 테스트' && nodes[0]._s1TitleKo==='소개');
    return out;
  });
  console.log(r.join('\n')); const bad=r.filter(x=>x.startsWith('FAIL')).length;
  console.log(bad?('=== 실패 '+bad):'=== 전부 통과 ('+r.length+')');
  await b.close(); process.exit(bad?1:0);
})();
