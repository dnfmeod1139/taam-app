// 회원 원장 예치금 탭 — 원장 줄에 티켓 일정(매장·방문일·시간·인원)이 붙고, 시각이 진하게 나오는지.
//   실행: NODE_PATH=<scratch>/node_modules node sql/_test/ledgerrowshot.js
//   네트워크는 전부 막고 window.sb 를 픽스처로 갈아 끼운다.
var pw = require('playwright-core'), path = require('path');
(async function(){
  var br = await pw.chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  var pg = await br.newPage({ viewport: { width: 420, height: 900 } });
  await pg.route(function(u){ return !u.href.startsWith('file://'); }, function(r){ r.abort(); });
  pg.on('pageerror', function(e){ console.log('PAGEERR', String(e.message).slice(0,200)); });
  await pg.goto('file://' + path.resolve('index.html'), { waitUntil: 'domcontentloaded' });
  await pg.waitForTimeout(1500);
  var out = await pg.evaluate(async function(){
    window._currentRole = 'superadmin';
    var FX = {
      profiles: { id:'u1', name:'테스트', membership_tier:'M', membership_deposit_balance: 6925000, general_deposit_balance: 0, deposit_balance: 6925000 },
      deposit_transactions: [
        { created_at:'2026-09-10T06:24:00Z', deposit_type:'membership', change_type:'ticket_purchase', amount:-1075000, balance_after:6925000,
          description:'슌지 티켓 2인 구매 (멤버십 예치금)', metadata:{ purchase_id:'PAY-abc-1' } },
        { created_at:'2026-09-12T02:10:00Z', deposit_type:'membership', change_type:'ticket_refund', amount:1075000, balance_after:8000000,
          description:'슌지 티켓 환불', metadata:{ purchase_id:'PAY-abc-1' } },
        { created_at:'2026-09-13T02:10:00Z', deposit_type:'membership', change_type:'ticket_purchase', amount:-500000, balance_after:7500000,
          description:'초대 결제', metadata:{ invite_id:'11112222-3333-4444-5555-666677778888' } },
        { created_at:'2026-09-14T02:10:00Z', deposit_type:'membership', change_type:'ticket_purchase', amount:-100000, balance_after:7400000,
          description:'옛 구매 (티켓 행 없음)', metadata:{ purchase_id:'PAY-orphan' } },
        { created_at:'2026-09-01T02:10:00Z', deposit_type:'membership', change_type:'admin_grant', amount:8000000, balance_after:8000000,
          description:'연회비 예치금', metadata:{} }
      ],
      tickets: [
        { id:'t1', created_at:'2026-09-10T06:24:00Z', restaurant_name:'슌지', party_size:2, price:1075000, status:'active',
          reservation_date:'2027.01.23', visit_time:'18:00', purchase_id:'PAY-abc-1', extra_data:{} },
        { id:'t2', created_at:'2026-09-13T02:10:00Z', restaurant_name:'마츠카와', party_size:1, price:500000, status:'active',
          reservation_date:'05.01', visit_time:'12:00', purchase_id:'INV-11112222-77', extra_data:{} }
      ]
    };
    function q(tbl){
      var self = { _t: tbl };
      ['select','eq','order','limit','in','neq','gte','lte','is'].forEach(function(k){ self[k] = function(){ return self; }; });
      self.maybeSingle = function(){ return Promise.resolve({ data: FX[tbl] || null }); };
      self.then = function(res){ return Promise.resolve({ data: FX[tbl] || [] }).then(res); };
      return self;
    }
    window.sb = { from: q, rpc: function(){ return Promise.resolve({ data: null }); }, auth: { getUser: function(){ return Promise.resolve({ data: { user: { id:'admin' } } }); } } };
    await mlOpen('u1');
    var d = document.getElementById('mlDetail');
    // 예치금 탭으로
    var tabs = Array.prototype.slice.call(d.querySelectorAll('[onclick]')).filter(function(e){ return /예치금/.test(e.textContent); });
    if(tabs[0]) tabs[0].click();
    return d.innerText;
  });
  var checks = [
    ['일정 줄: 매장', /🎫 슌지 · 방문 2027\.01\.23 \(토\) 18:00 · 2인/],
    ['환불 줄에도 일정', /슌지 티켓 환불[\s\S]*🎫 슌지/],
    ['초대 결제 → invite_id 로 이어짐', /🎫 마츠카와 · 방문 05\.01 12:00 · 1인/],
    ['티켓 행 없음 표기', /티켓 행 없음 — 일정 미확인/],
    ['결제 시각 접두', /결제 2026\.09\.10 15:24/],
    ['반환 시각 접두', /반환 2026\.09\.12 11:10/],
    ['부여 줄엔 접두 없음', /연회비 예치금\s*2026\.09\.01 11:10/],
    ['부여 줄에 결제 접두가 붙지 않음', /^(?![\s\S]*결제 2026\.09\.01)/],
    ['잔액 분리', /잔액 ₩6,925,000/]
  ];
  var fail = 0;
  checks.forEach(function(c){ var ok = c[1].test(out); if(!ok) fail++; console.log((ok ? '✅ ' : '❌ ') + c[0]); });
  if(fail){ console.log('---- innerText ----'); console.log(out.slice(0, 3000)); }
  await br.close();
  process.exit(fail ? 1 : 0);
})();
