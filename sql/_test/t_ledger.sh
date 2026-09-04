#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 원장을 서버가 쓴다 — payment_id 사고 재발 방지 (2026-09-04)
# ═══════════════════════════════════════════════════════════════
#   2026-09-04, T등급 회원이 초대 티켓을 결제하지 못했다.
#     column "payment_id" is of type uuid but expression is of type text
#   함수 안의 INSERT 가 text 를 uuid 컬럼에 넣고 있었다. 값이 무엇이든
#   상관없다 — plpgsql 이 그 문장을 **짤 때** 걸리는 오류라, 앱이
#   payment_id 를 아예 안 보내도 똑같이 죽었다. 그래서 원장을 넘기는
#   결제가 **전부** 막혔는데, 앱에는 폴백이 「함수 없음」 하나뿐이라
#   그대로 「예치금 차감 실패」로 튀었다.
#
#   ① 원장 없이 부르면 잔액만 움직인다
#   ② 원장을 넘기면 잔액과 원장이 같이 쓰인다 ⭐ (이게 막혀 있었다)
#   ③ payment_id 를 안 보내도 된다 ⭐ 사고의 실제 모양
#   ④ uuid 를 보내면 컬럼에 들어간다
#   ⑤ uuid 가 아닌 값(PortOne 'taam-…')이 와도 죽지 않는다 ⭐
#      — 버리지 않고 metadata.payment_ref 로 남긴다
#   ⑥ 검산은 그대로 산다 — 합계가 다르면 거부
#   ⑦ 실패하면 잔액도 안 움직인다 ⭐ 반쪽으로 끝나지 않는다
#
# 준비: psql 이 붙는 로컬 pg
# 실행: bash sql/_test/t_ledger.sh
# ═══════════════════════════════════════════════════════════════
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
U=b1000000-0000-4000-8000-000000000001
S=b1000000-0000-4000-8000-0000000000ff
PUUID=11112222-3333-4444-5555-666677778888

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0

$P -v ON_ERROR_STOP=1 -f sql/_test/fx_ledger.sql >/dev/null 2>/tmp/_fx.err \
  || { echo "❌ 픽스처 적용 실패"; head -3 /tmp/_fx.err; exit 1; }
$P -v ON_ERROR_STOP=1 -f sql/ledger_server_side.sql >/dev/null 2>/tmp/_ld.err \
  || { echo "❌ 함수 적용 실패"; head -5 /tmp/_ld.err; exit 1; }

$P -c "
insert into auth.users(id) values ('$U'),('$S');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance)
 values ('$U','member','회원',2520000,0),('$S','super_admin','슈퍼',0,0);
" >/dev/null

# 회원 자신으로 함수를 부른다. 인자(JSON)는 셸에서 그대로 넘긴다.
call(){ # entries(JSON 또는 null), mem_delta, gen_delta
  $P -c "set role authenticated; select set_config('taam.uid','$U',false);
         select public.taam_apply_deposit_delta('$U'::uuid, $2::bigint, $3::bigint,
                $( [ "$1" = "null" ] && echo "null::jsonb" || echo "\$json\$$1\$json\$::jsonb" ));" 2>&1
}
bal(){ $P -c "select membership_deposit_balance||'/'||general_deposit_balance
              from public.profiles where id='$U';" | tail -1; }
rows(){ $P -c "select count(*) from public.deposit_transactions where user_id='$U';" | tail -1; }
reset(){ $P -c "delete from public.deposit_transactions where user_id='$U';
                update public.profiles set membership_deposit_balance=2520000,
                       general_deposit_balance=0 where id='$U';" >/dev/null; }

echo "── ① 원장 없이 ──"
call null -100000 0 >/dev/null
ok "잔액만 움직인다" "2420000/0" "$(bal)"
ok "원장은 안 쓴다"  0 "$(rows)"
reset

echo "── ② 원장을 넘기면 ── ⭐"
E='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-1400000,"description":"초대 결제 (멤버십) · 슌지","metadata":{"purchase_id":"INV-abcd1234-1"}}]'
OUT=$(call "$E" -1400000 0)
ok "실패하지 않는다 ⭐ (사고의 그 자리)" "" "$(echo "$OUT" | grep -i 'error' | head -1)"
ok "잔액이 빠졌다"     "1120000/0" "$(bal)"
ok "원장 한 줄이 남았다 ⭐" 1 "$(rows)"
ok "balance_after 는 서버가 센다" 1120000 \
   "$($P -c "select balance_after from public.deposit_transactions where user_id='$U';" | tail -1)"
ok "서버가 썼다고 표시된다" true \
   "$($P -c "select metadata->>'server_written' from public.deposit_transactions where user_id='$U';" | tail -1)"

echo "── ③ payment_id 를 안 보내도 ── ⭐"
# ⚠ 사고의 실제 모양이다. 앱은 이 값을 보낸 적이 **없다.** 그런데도 죽었다.
ok "payment_id 는 비어 있다" "" \
   "$($P -c "select coalesce(payment_id::text,'') from public.deposit_transactions where user_id='$U';" | tail -1)"
reset

echo "── ④ uuid 를 보내면 들어간다 ──"
E4='[{"deposit_type":"general","change_type":"membership_payment","amount":-500000,"payment_id":"'$PUUID'"}]'
call "$E4" 0 -500000 >/dev/null
ok "컬럼에 그대로" "$PUUID" \
   "$($P -c "select payment_id from public.deposit_transactions where user_id='$U';" | tail -1)"
reset

echo "── ⑤ uuid 가 아닌 값이 와도 ── ⭐"
# 티켓 구매 쪽은 PortOne 결제ID('taam-…')를 payment_id 라는 이름으로 들고 다닌다.
# 언젠가 섞여 들어와도 **결제 중에** 터지면 안 된다.
E5='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-300000,"payment_id":"taam-20260904-77"}]'
OUT5=$(call "$E5" -300000 0)
ok "죽지 않는다 ⭐" "" "$(echo "$OUT5" | grep -i 'error' | head -1)"
ok "컬럼은 비운다"  "" \
   "$($P -c "select coalesce(payment_id::text,'') from public.deposit_transactions where user_id='$U';" | tail -1)"
ok "값은 버리지 않는다 ⭐" "taam-20260904-77" \
   "$($P -c "select metadata->>'payment_ref' from public.deposit_transactions where user_id='$U';" | tail -1)"
reset
# 빈 문자열은 흔적도 안 남긴다 (없는 것을 있는 것처럼 적지 않는다)
E5b='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-100000,"payment_id":""}]'
call "$E5b" -100000 0 >/dev/null
ok "빈 값은 metadata 에도 안 남는다" "" \
   "$($P -c "select coalesce(metadata->>'payment_ref','') from public.deposit_transactions where user_id='$U';" | tail -1)"
reset

echo "── ⑥ 검산은 그대로 ──"
E6='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-100000}]'
ok "합계가 다르면 거부" 1 \
   "$(call "$E6" -200000 0 | grep -c 'LEDGER_MISMATCH')"
E6b='[{"deposit_type":"savings","change_type":"ticket_purchase","amount":-100000}]'
ok "모르는 주머니는 거부" 1 "$(call "$E6b" -100000 0 | grep -c 'LEDGER_BAD_TYPE')"

echo "── ⑦ 실패하면 잔액도 안 움직인다 ── ⭐"
ok "잔액 그대로" "2520000/0" "$(bal)"
ok "원장도 그대로" 0 "$(rows)"

echo "── ⑧ 남의 예치금은 못 건드린다 ──"
ok "남의 것은 거부" 1 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$U',false);
             select public.taam_apply_deposit_delta('$S'::uuid,1000::bigint,0::bigint,null::jsonb);" 2>&1 \
      | grep -c '다른 회원')"

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
exit $FAIL
