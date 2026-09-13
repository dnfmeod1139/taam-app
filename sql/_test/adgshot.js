// ═══════════════════════════════════════════════════════════════
// 슈퍼어드민 예치금 부여가 RPC 로 간다 (2026-09-14)
// ═══════════════════════════════════════════════════════════════
//   index.html 에서 adminGrantDeposit · _depApplyDelta 만 잘라 가짜 sb 위에서 돌린다.
//   ① 부여: profiles.update 도 deposit_transactions.insert 도 부르지 않는다 ⭐
//   ② RPC 인자: 델타 + admin_grant 원장 1건 (granted_by · fx 메타 포함)
//   ③ 새 잔액은 RPC 가 돌려준 값이다 (앱 계산값이 아니라)
//   ④ 차감은 admin_deduct · 음수 델타
//   ⑤ 서버 LEDGER_INSUFFICIENT → 사람이 읽는 문구
//   ⑥ 옛 3인자 함수(PGRST202) 폴백일 때만 앱이 원장을 한 줄 남긴다
// 실행: node sql/_test/adgshot.js
// ═══════════════════════════════════════════════════════════════
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(__dirname + '/../../index.html', 'utf8');
function cut(name){
  const i = src.indexOf('async function ' + name + '(');
  if (i < 0) throw new Error(name + ' 없음');
  // 최상위 닫는 중괄호(줄 첫 칸의 '}')까지
  const j = src.indexOf('\n}\n', i);
  return src.slice(i, j + 2);
}
let fail = 0, n = 0;
function ok(name, cond, d){ n++; if (cond) console.log('OK  ', name); else { fail++; console.log('FAIL', name, d !== undefined ? '— ' + JSON.stringify(d).slice(0, 200) : ''); } }

function mk(opts){
  opts = opts || {};
  const calls = { rpc: [], update: [], insert: [] };
  const table = (name) => ({
    select(){ return { eq(){ return { single: async () => ({ data: { membership_deposit_balance: 100000, general_deposit_balance: 5000, display_name: '회원' }, error: null }) }; } }; },
    update(obj){ calls.update.push({ name, obj }); return { eq(){ return { select: async () => ({ data: [obj], error: null }) }; } }; },
    insert(obj){ calls.insert.push({ name, obj }); return { select: async () => ({ data: [obj], error: null }), then(r){ return Promise.resolve({ data: null, error: null }).then(r); } }; },
  });
  const sb = {
    auth: { getUser: async () => ({ data: { user: { id: 'SUPER', user_metadata: { display_name: '슈퍼' } } } }) },
    from: table,
    rpc: async (fn, args) => { calls.rpc.push({ fn, args }); return opts.rpc ? opts.rpc(fn, args) : { data: { mem: 100000, gen: 5000 + (args.p_gen_delta||0), total: 0 }, error: null }; },
    functions: { invoke: async () => ({}) },
  };
  const ctx = { window: { sb, _adgFxMeta: opts.fx || null, taamReportError(){}, taamNotifyAdmins: null }, console: { log(){}, warn(){}, error(){} } };
  ctx.window.window = ctx.window;
  vm.createContext(ctx);
  vm.runInContext(cut('_depApplyDelta') + '\n' + cut('adminGrantDeposit') + '\nfunction _taamWhoName(p){ return (p && p.display_name) || "회원"; }\nthis.adminGrantDeposit = adminGrantDeposit;', ctx);
  return { ctx, calls };
}

(async () => {
  // ① ② ③ 부여
  {
    const { ctx, calls } = mk({ fx: { fx_note: 'x' } });
    const r = await ctx.adminGrantDeposit('U1', 30000, 'general', '테스트 부여');
    ok('① profiles.update 를 부르지 않는다 ⭐', calls.update.length === 0, calls.update);
    ok('① deposit_transactions.insert 를 부르지 않는다 ⭐', !calls.insert.some(c => c.name === 'deposit_transactions'), calls.insert.map(c => c.name));
    const rpc = calls.rpc.find(c => c.fn === 'taam_apply_deposit_delta');
    ok('② RPC 를 한 번 부른다', calls.rpc.filter(c => c.fn === 'taam_apply_deposit_delta').length === 1);
    ok('② 델타: 멤버십 0 · 일반 +30,000', rpc && rpc.args.p_mem_delta === 0 && rpc.args.p_gen_delta === 30000, rpc && rpc.args);
    const e = rpc && rpc.args.p_entries && rpc.args.p_entries[0];
    ok('② 원장 1건 admin_grant · 금액 일치', e && rpc.args.p_entries.length === 1 && e.change_type === 'admin_grant' && e.amount === 30000 && e.deposit_type === 'general', e);
    ok('② 메타에 granted_by + fx 메타', e && e.metadata.granted_by === 'SUPER' && e.metadata.fx_note === 'x', e && e.metadata);
    ok('③ 새 잔액은 서버 값 (5,000 + 30,000)', r.newBalance === 35000, r);
    ok('③ 회원 알림 INSERT 는 그대로 간다', calls.insert.some(c => c.name === 'notifications'));
  }
  // ④ 차감
  {
    const { ctx, calls } = mk();
    await ctx.adminGrantDeposit('U1', -2000, 'membership', '차감');
    const rpc = calls.rpc.find(c => c.fn === 'taam_apply_deposit_delta');
    ok('④ 차감: 멤버십 −2,000 · admin_deduct', rpc && rpc.args.p_mem_delta === -2000 && rpc.args.p_gen_delta === 0 && rpc.args.p_entries[0].change_type === 'admin_deduct', rpc && rpc.args);
    ok('④ 차감엔 회원 알림 없음', !calls.insert.some(c => c.name === 'notifications'));
  }
  // ⑤ 서버 거부
  {
    const { ctx, calls } = mk({ rpc: async () => ({ data: null, error: { message: 'LEDGER_INSUFFICIENT: 잔액(멤버십 0, 일반 0)이 요청(0, -9)에 못 미칩니다' } }) });
    let err = null; try { await ctx.adminGrantDeposit('U1', -1000, 'general', ''); } catch(e){ err = e; }
    ok('⑤ LEDGER_INSUFFICIENT → 읽을 수 있는 문구', err && /예치금이 부족해/.test(err.message), err && err.message);
    ok('⑤ 실패 시 원장·알림 아무것도 안 남김', calls.insert.length === 0, calls.insert);
  }
  // ⑥ 옛 함수 폴백
  {
    let k = 0;
    const { ctx, calls } = mk({ rpc: async (fn, args) => { k++; if (args.p_entries) return { data: null, error: { code: 'PGRST202', message: 'could not find the function' } }; return { data: { mem: 100000, gen: 6000 }, error: null }; } });
    const r = await ctx.adminGrantDeposit('U1', 1000, 'general', '');
    ok('⑥ 옛 함수면 두 번 부르고(원장 없이) 앱이 원장 한 줄', k === 2 && calls.insert.filter(c => c.name === 'deposit_transactions').length === 1, { k, ins: calls.insert.map(c => c.name) });
    ok('⑥ 그 줄의 balance_after 는 서버 잔액', calls.insert.find(c => c.name === 'deposit_transactions').obj.balance_after === 6000 && r.newBalance === 6000);
  }
  console.log('\n' + (fail ? `=== 실패 ${fail}/${n} ===` : `=== 전부 통과 (${n}건) ===`));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
