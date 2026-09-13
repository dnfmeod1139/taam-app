#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 회원은 돈을 만들지 못한다 (2026-09-13)
# ═══════════════════════════════════════════════════════════════
#   taam_apply_deposit_delta 가 「자기 것이거나 슈퍼어드민」만 보고 델타의
#   부호를 안 봐서, 회원이 자기 잔액에 +10,000,000 을 넣을 수 있었다.
#   로컬에서 재현: 원장 없이 +천만, 가짜 환불 원장으로 +오백만 — 둘 다 통과.
#
#   ① 원장 없이 양수 → 거부 ⭐ (사고의 그 모양)
#   ② 환불이 아닌 양수 원장(user_charge 등) → 거부 ⭐
#   ③ 낸 적 없는 구매의 환불 → 거부 ⭐
#   ④ 낸 돈 안의 환불 → 통과 (취소·정원초과·반환이 이 길이다)
#   ⑤ 두 번째 환불이 한도를 넘으면 → 거부 ⭐ (두 번 환불)
#   ⑥ 부분 환불 두 번이 합쳐서 한도 안이면 → 통과
#   ⑦ 회원의 차감(구매)은 종전대로 통과
#   ⑧ 슈퍼어드민의 임의 부여는 종전대로 통과 ⭐
#   ⑨ 주머니 사이 이동(합 0)도 회원은 못 한다
#
# 먼저: 로컬 pg. 실행: bash sql/_test/t_ledger_mint.sh
# ═══════════════════════════════════════════════════════════════
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
U=b1000000-0000-4000-8000-000000000001
S=b1000000-0000-4000-8000-0000000000ff
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0

$P -v ON_ERROR_STOP=1 -f sql/_test/fx_ledger.sql >/dev/null 2>/tmp/_m.err || { echo "❌ 픽스처"; head -3 /tmp/_m.err; exit 1; }
$P -v ON_ERROR_STOP=1 -f sql/ledger_server_side.sql >/dev/null 2>/tmp/_m.err || { echo "❌ 함수 적용"; head -5 /tmp/_m.err; exit 1; }
$P -c "insert into auth.users(id) values ('$U'),('$S');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance)
 values ('$U','member','회원',2000000,500000),('$S','super_admin','슈퍼',0,0);" >/dev/null

call(){ # uid, mem, gen, entries(JSON|null)  → stdout(오류 포함)
  $P -c "set role authenticated; select set_config('taam.uid','$1',false);
         select public.taam_apply_deposit_delta('$U'::uuid, $2::bigint, $3::bigint,
           $( [ "$4" = "null" ] && echo "null::jsonb" || echo "\$j\$$4\$j\$::jsonb" ));" 2>&1
}
bal(){ $P -c "select membership_deposit_balance||'/'||general_deposit_balance from public.profiles where id='$U';" | tail -1; }
has(){ echo "$1" | grep -q "$2" && echo 1 || echo 0; }

echo "── ① 원장 없이 양수 ── ⭐"
ok "회원 +10,000,000 은 거부" 1 "$(has "$(call $U 10000000 0 null)" LEDGER_CREDIT_DENIED)"
ok "잔액 그대로" "2000000/500000" "$(bal)"

echo "── ② 환불 아닌 양수 원장 ── ⭐"
E='[{"deposit_type":"general","change_type":"user_charge","amount":300000,"metadata":{}}]'
ok "user_charge +300,000 은 거부" 1 "$(has "$(call $U 0 300000 "$E")" LEDGER_CREDIT_DENIED)"
E='[{"deposit_type":"general","change_type":"ticket_refund","amount":300000,"metadata":{}}]'
ok "purchase_id 없는 환불도 거부" 1 "$(has "$(call $U 0 300000 "$E")" LEDGER_CREDIT_DENIED)"

echo "── ③ 낸 적 없는 구매의 환불 ── ⭐"
E='[{"deposit_type":"membership","change_type":"ticket_refund","amount":500000,"metadata":{"purchase_id":"FAKE-1"}}]'
ok "가짜 구매 환불은 거부" 1 "$(has "$(call $U 500000 0 "$E")" LEDGER_REFUND_EXCEEDS)"

echo "── ⑦ 먼저 정상 구매 (차감) ──"
E='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-1400000,"metadata":{"purchase_id":"taam-100"}}]'
call $U -1400000 0 "$E" >/dev/null
ok "구매 차감은 통과" "600000/500000" "$(bal)"

echo "── ④ 낸 돈 안의 환불 ──"
E='[{"deposit_type":"membership","change_type":"ticket_refund","amount":1000000,"metadata":{"purchase_id":"taam-100"}}]'
OUT=$(call $U 1000000 0 "$E")
ok "부분 환불 1,000,000 통과" 0 "$(has "$OUT" ERROR)"
ok "잔액 반영" "1600000/500000" "$(bal)"

echo "── ⑤ 두 번째 환불이 한도를 넘으면 ── ⭐"
E='[{"deposit_type":"membership","change_type":"ticket_refund","amount":500000,"metadata":{"purchase_id":"taam-100"}}]'
ok "남은 한도 400,000 인데 500,000 요청 → 거부" 1 "$(has "$(call $U 500000 0 "$E")" LEDGER_REFUND_EXCEEDS)"
ok "잔액 그대로" "1600000/500000" "$(bal)"

echo "── ⑥ 한도 안의 두 번째 환불 ──"
E='[{"deposit_type":"membership","change_type":"ticket_refund","amount":400000,"metadata":{"purchase_id":"taam-100"}}]'
ok "남은 400,000 은 통과" 0 "$(has "$(call $U 400000 0 "$E")" ERROR)"
ok "이제 전액 환불 완료" "2000000/500000" "$(bal)"
E='[{"deposit_type":"membership","change_type":"ticket_refund","amount":1,"metadata":{"purchase_id":"taam-100"}}]'
ok "그 뒤 1원도 거부 ⭐" 1 "$(has "$(call $U 1 0 "$E")" LEDGER_REFUND_EXCEEDS)"

echo "── ⑨ 주머니 이동 ──"
ok "합 0 이어도 한쪽을 늘리면 거부" 1 "$(has "$(call $U -100000 100000 null)" LEDGER_CREDIT_DENIED)"

echo "── ⑧ 슈퍼어드민 ── ⭐"
ok "슈퍼어드민 임의 부여 +777,777 통과" 0 "$(has "$(call $S 777777 0 null)" ERROR)"
ok "잔액 반영" "2777777/500000" "$(bal)"

echo; [ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
exit $FAIL
