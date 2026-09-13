#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 원장 4단계 — 회원은 원장을 직접 쓰지 못하고, 서버는 RPC 로 쓴다 (2026-09-14)
# ═══════════════════════════════════════════════════════════════
#   sql/ledger_close_member_insert.sql 을 로컬 pg 에 적용해 잰다.
#
#   ① 적용 전: 회원이 가짜 ticket_purchase 행을 직접 INSERT 할 수 있다 (사고 모양)
#   ② 적용 후: 같은 INSERT 가 RLS 에 막힌다 ⭐
#   ③ 슈퍼어드민의 직접 INSERT 는 그대로 된다 (adminGrantDeposit · 환불 0원 기록)
#   ④ RPC 를 거친 회원 원장은 그대로 쓰인다 (정책은 definer 함수를 안 건드린다)
#   ⑤ service_role(authenticator 접속 + set role) 호출이 슈퍼어드민처럼 통과 ⭐
#      · prev_mem/prev_gen 이 돌아온다 · 원장에 server_caller 가 남는다
#   ⑥ service_role 의 양수(좌석 상실 환원) — 구매 한도 검사 없이 통과
#   ⑦ uid 도 없고 service_role 도 아니면 「로그인이 필요합니다」
#   ⑧ postgres 세션(SQL Editor) 도 서버 길로 통과
#   ⑨ 원장을 넘겼는데 잔액 부족 → LEDGER_INSUFFICIENT · 잔액·원장 그대로 ⭐
#   ⑩ 원장 없는 옛 3인자 호출은 종전대로 0 에서 멈춘다(호환)
#   ⑪ 2026-09-13 자가 충전 방어가 그대로 살아 있다
#
# 먼저: 로컬 pg. 실행: bash sql/_test/t_ledger_close.sh
# ═══════════════════════════════════════════════════════════════
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
PA="psql -h /tmp -U authenticator -d postgres -q -t -A"
U=b1000000-0000-4000-8000-000000000001
S=b1000000-0000-4000-8000-0000000000ff
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
has(){ echo "$1" | grep -q "$2" && echo 1 || echo 0; }
FAIL=0

$P -v ON_ERROR_STOP=1 -f sql/_test/fx_ledger.sql       >/dev/null 2>/tmp/_c.err || { echo "❌ 픽스처"; head -3 /tmp/_c.err; exit 1; }
$P -v ON_ERROR_STOP=1 -f sql/_test/fx_ledger_close.sql >/dev/null 2>/tmp/_c.err || { echo "❌ 픽스처(close)"; head -3 /tmp/_c.err; exit 1; }
$P -v ON_ERROR_STOP=1 -f sql/ledger_server_side.sql    >/dev/null 2>/tmp/_c.err || { echo "❌ 2단계 함수"; head -5 /tmp/_c.err; exit 1; }
$P -c "insert into auth.users(id) values ('$U'),('$S');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance)
 values ('$U','member','회원',2000000,500000),('$S','super_admin','슈퍼',0,0);" >/dev/null

# 회원/슈퍼 세션 흉내 (PostgREST 처럼 authenticator 로 접속해 set role)
as_user(){ # uid, sql
  $PA -c "set role authenticated; select set_config('taam.uid','$1',false); $2" 2>&1
}
as_service(){ # sql
  $PA -c "set role service_role; select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false); $1" 2>&1
}
call_user(){ # uid, target, mem, gen, entries|null
  as_user $1 "select public.taam_apply_deposit_delta('$2'::uuid, $3::bigint, $4::bigint,
    $( [ "$5" = "null" ] && echo "null::jsonb" || echo "\$j\$$5\$j\$::jsonb" ));"
}
call_service(){ # target, mem, gen, entries|null
  as_service "select public.taam_apply_deposit_delta('$1'::uuid, $2::bigint, $3::bigint,
    $( [ "$4" = "null" ] && echo "null::jsonb" || echo "\$j\$$4\$j\$::jsonb" ));"
}
bal(){ $P -c "select membership_deposit_balance||'/'||general_deposit_balance from public.profiles where id='$U';" | tail -1; }
nrows(){ $P -c "select count(*) from public.deposit_transactions where user_id='$U'$1;" | tail -1; }
FAKE="insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,balance_after,metadata)
      values ('$U','membership','ticket_purchase',-9000000,0,'{\"purchase_id\":\"FORGED-1\"}');"

echo "── ① 적용 전 — 사고 모양 재현"
OUT=$(as_user $U "$FAKE")
ok "회원이 가짜 구매 행을 직접 넣을 수 있다 (옛 정책)" 0 "$(has "$OUT" ERROR)"
ok "가짜 행 1건" 1 "$(nrows " and metadata->>'purchase_id'='FORGED-1'")"
$P -c "delete from public.deposit_transactions where user_id='$U';" >/dev/null

echo "── 적용"
$P -v ON_ERROR_STOP=1 -f sql/ledger_close_member_insert.sql >/tmp/_c.out 2>/tmp/_c.err || { echo "❌ 4단계 적용"; head -5 /tmp/_c.err; exit 1; }
ok "확인 표에 ❌ 없음" 0 "$(grep -c '❌' /tmp/_c.out)"
ok "확인 표 7줄 전부 ✅" 7 "$(grep -c '✅' /tmp/_c.out)"

echo "── ② 적용 후 — 회원 직접 INSERT ⭐"
OUT=$(as_user $U "$FAKE")
ok "회원의 직접 INSERT 는 RLS 에 막힌다" 1 "$(has "$OUT" "row-level security")"
ok "원장에 남지 않음" 0 "$(nrows)"

echo "── ③ 슈퍼어드민 직접 INSERT"
OUT=$(as_user $S "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,balance_after,metadata)
      values ('$U','general','ticket_refund',0,2500000,'{\"processed_by\":\"super_admin\"}');")
ok "슈퍼어드민은 그대로 쓴다 (환불 0원 기록)" 0 "$(has "$OUT" ERROR)"
ok "1건 남음" 1 "$(nrows)"
$P -c "delete from public.deposit_transactions where user_id='$U';" >/dev/null

echo "── ④ RPC 를 거친 회원 원장"
E='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-1400000,"metadata":{"purchase_id":"taam-100"}}]'
OUT=$(call_user $U $U -1400000 0 "$E")
ok "회원 구매 차감 + 원장 통과" 0 "$(has "$OUT" ERROR)"
ok "잔액" "600000/500000" "$(bal)"
ok "원장 1건 (definer 가 썼다)" 1 "$(nrows " and metadata->>'server_written'='true'")"
ok "회원 호출엔 server_caller 없음" 0 "$(nrows " and metadata ? 'server_caller'")"

echo "── ⑤ service_role 호출 ⭐"
E='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-600000,"metadata":{"purchase_id":"HOLD-1","order_id":"ORD-1","portion":"membership"}},
    {"deposit_type":"general","change_type":"ticket_purchase","amount":-100000,"metadata":{"purchase_id":"HOLD-1","order_id":"ORD-1","portion":"general"}}]'
OUT=$(call_service $U -600000 -100000 "$E")
ok "Edge(service_role) 차감 통과" 0 "$(has "$OUT" ERROR)"
ok "prev_mem/prev_gen 이 돌아온다" 1 "$(has "$OUT" '"prev_mem" : 600000')"
ok "새 잔액" "0/400000" "$(bal)"
ok "원장 2건 · server_caller=service_role" 2 "$(nrows " and metadata->>'server_caller'='service_role'")"
ok "balance_after 누적 (1,100,000 → 500,000 → 400,000)" "500000,400000" "$($P -c "select string_agg(balance_after::text, ',' order by balance_after desc) from public.deposit_transactions where user_id='$U' and metadata->>'purchase_id'='HOLD-1';" | tail -1)"

echo "── ⑥ service_role 양수(좌석 상실 환원) — 한도 검사 없음"
E='[{"deposit_type":"membership","change_type":"ticket_refund","amount":600000,"metadata":{"purchase_id":"HOLD-1","order_id":"ORD-1"}},
    {"deposit_type":"general","change_type":"ticket_refund","amount":100000,"metadata":{"purchase_id":"HOLD-1","order_id":"ORD-1"}}]'
OUT=$(call_service $U 600000 100000 "$E")
ok "환원 통과" 0 "$(has "$OUT" ERROR)"
ok "잔액 복원" "600000/500000" "$(bal)"
E='[{"deposit_type":"general","change_type":"admin_grant","amount":1000,"metadata":{}}]'
ok "서버의 임의 부여도 통과 (슈퍼어드민과 같다)" 0 "$(has "$(call_service $U 0 1000 "$E")" ERROR)"
ok "잔액" "600000/501000" "$(bal)"

echo "── ⑦ uid 없고 service_role 도 아니면"
OUT=$($PA -c "set role authenticated; select set_config('request.jwt.claims','{\"role\":\"authenticated\"}',false);
  select public.taam_apply_deposit_delta('$U'::uuid, -1::bigint, 0::bigint, null::jsonb);" 2>&1)
ok "「로그인이 필요합니다」" 1 "$(has "$OUT" "로그인이 필요합니다")"
OUT=$($PA -c "set role anon; select set_config('request.jwt.claims','{\"role\":\"anon\"}',false);
  select public.taam_apply_deposit_delta('$U'::uuid, -1::bigint, 0::bigint, null::jsonb);" 2>&1)
ok "anon 은 실행 권한 자체가 없다" 1 "$(has "$OUT" "permission denied")"
ok "잔액 그대로" "600000/501000" "$(bal)"

echo "── ⑧ postgres 세션(SQL Editor)"
E='[{"deposit_type":"general","change_type":"admin_adjust","amount":-1000,"metadata":{"note":"editor"}}]'
OUT=$($P -c "select public.taam_apply_deposit_delta('$U'::uuid, 0::bigint, -1000::bigint, \$j\$$E\$j\$::jsonb);" 2>&1)
ok "SQL Editor 호출 통과" 0 "$(has "$OUT" ERROR)"
ok "server_caller=postgres 로 남음" 1 "$(nrows " and metadata->>'server_caller'='postgres'")"
ok "잔액" "600000/500000" "$(bal)"

echo "── ⑨ 원장 + 잔액 부족 ⭐"
N0=$(nrows)
E='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-700000,"metadata":{"purchase_id":"taam-200"}}]'
OUT=$(call_user $U $U -700000 0 "$E")
ok "회원: 멤버십 600,000 인데 700,000 → LEDGER_INSUFFICIENT" 1 "$(has "$OUT" LEDGER_INSUFFICIENT)"
OUT=$(call_service $U -700000 0 "$E")
ok "서버 호출도 같다 (잔액이 기준이다)" 1 "$(has "$OUT" LEDGER_INSUFFICIENT)"
ok "잔액 그대로" "600000/500000" "$(bal)"
ok "원장도 그대로" "$N0" "$(nrows)"
E='[{"deposit_type":"membership","change_type":"ticket_purchase","amount":-600000,"metadata":{"purchase_id":"taam-201"}},
    {"deposit_type":"general","change_type":"ticket_purchase","amount":-100000,"metadata":{"purchase_id":"taam-201"}}]'
ok "두 주머니로 나눠 딱 맞게 내면 통과" 0 "$(has "$(call_user $U $U -600000 -100000 "$E")" ERROR)"
ok "잔액" "0/400000" "$(bal)"

echo "── ⑩ 원장 없는 옛 3인자 호출 (호환)"
OUT=$(as_user $U "select public.taam_apply_deposit_delta('$U'::uuid, 0::bigint, -900000::bigint);")
ok "옛 호출은 종전대로 통과" 0 "$(has "$OUT" ERROR)"
ok "0 에서 멈춘다 (clamp)" "0/0" "$(bal)"

echo "── ⑪ 자가 충전 방어 유지"
ok "원장 없이 +천만 거부" 1 "$(has "$(call_user $U $U 10000000 0 null)" LEDGER_CREDIT_DENIED)"
E='[{"deposit_type":"general","change_type":"ticket_refund","amount":5000000,"metadata":{"purchase_id":"FAKE-9"}}]'
ok "낸 적 없는 구매의 환불 거부" 1 "$(has "$(call_user $U $U 0 5000000 "$E")" LEDGER_REFUND_EXCEEDS)"
E='[{"deposit_type":"membership","change_type":"ticket_refund","amount":600000,"metadata":{"purchase_id":"taam-201"}}]'
ok "낸 돈 안의 환불은 통과" 0 "$(has "$(call_user $U $U 600000 0 "$E")" ERROR)"
ok "다른 회원 것은 못 건드림" 1 "$(has "$(call_user $U $S 0 -1 null)" "다른 회원")"

echo "── ⑫ 슈퍼어드민 부여·차감이 RPC 로 (2026-09-14 adminGrantDeposit)"
$P -c "update public.profiles set membership_deposit_balance=0, general_deposit_balance=0, granted_membership_balance=0, granted_general_balance=0 where id='$U'; delete from public.deposit_transactions where user_id='$U';" >/dev/null
E='[{"deposit_type":"general","change_type":"admin_grant","amount":50000,"description":"테스트 부여","metadata":{"granted_by":"'$S'"}}]'
OUT=$(call_user $S $U 0 50000 "$E")
ok "슈퍼어드민 부여 +50,000 통과" 0 "$(has "$OUT" ERROR)"
ok "잔액" "0/50000" "$(bal)"
ok "부여 누적은 트리거가 **한 번만** 더한다 ⭐" "50000" "$($P -c "select granted_general_balance from public.profiles where id='$U';" | tail -1)"
ok "원장 admin_grant 1건" 1 "$(nrows " and change_type='admin_grant'")"
E='[{"deposit_type":"general","change_type":"admin_deduct","amount":-20000,"description":"테스트 차감","metadata":{}}]'
ok "차감 −20,000 통과" 0 "$(has "$(call_user $S $U 0 -20000 "$E")" ERROR)"
ok "부여 누적도 같이 준다" "30000" "$($P -c "select granted_general_balance from public.profiles where id='$U';" | tail -1)"
E='[{"deposit_type":"general","change_type":"admin_deduct","amount":-40000,"description":"과다 차감","metadata":{}}]'
ok "잔액(30,000) 넘는 차감은 LEDGER_INSUFFICIENT ⭐" 1 "$(has "$(call_user $S $U 0 -40000 "$E")" LEDGER_INSUFFICIENT)"
ok "잔액 그대로" "0/30000" "$(bal)"
E='[{"deposit_type":"membership","change_type":"admin_deduct","amount":-1,"description":"빈 주머니","metadata":{}}]'
ok "빈 멤버십 주머니 차감도 거부 (앱이 「다른 주머니에 있다」 안내)" 1 "$(has "$(call_user $S $U -1 0 "$E")" LEDGER_INSUFFICIENT)"

echo "── ⑬ 4단계 SQL(admin_grant_via_rpc.sql) 적용·확인 표"
$P -v ON_ERROR_STOP=1 -f sql/admin_grant_via_rpc.sql >/tmp/_c2.out 2>/tmp/_c2.err || { echo "❌ 적용"; head -5 /tmp/_c2.err; FAIL=1; }
ok "확인 표 ①~③ ✅" 3 "$(grep -c '✅' /tmp/_c2.out)"
ok "부여 누적 ≠ 원장 인 회원 없음" 0 "$(grep -c '⚠ 차이' /tmp/_c2.out)"
$P -c "update public.profiles set granted_general_balance = 999 where id='$U';" >/dev/null
$P -f sql/admin_grant_via_rpc.sql >/tmp/_c2.out 2>/dev/null
ok "누적을 틀어 놓으면 그 회원이 「⚠ 차이」로 보인다" 1 "$(grep -c '⚠ 차이' /tmp/_c2.out)"

echo
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
