#!/bin/bash
# 재구매 제한 가드 v2 회귀 — 2026-11-15 (supabase/migrations/20261115_repurchase_guard_v2.sql). 먼저: 로컬 pg(/tmp 소켓). 실행: bash sql/_test/t_repurchase_v2.sh
#   픽스처 fx_repurchase_live_2026-11-15/ = 라이브 pg_get_functiondef 원문(가드·중복 가드·결제 사실 칸·매장 고정 …) — 같은 순서의 트리거로 올린다.
#   ① 옛 판(라이브)에서 열려 있던 길을 먼저 보이고(❌ 가 아니라 「옛 판: 통과」로 기록) ② v2 를 올린 뒤 같은 길이 막히는지, 정상 구매는 그대로인지 본다.
cd "$(dirname "$0")/../.."
FX=sql/_test/fx_repurchase_live_2026-11-15; MIG=supabase/migrations/20261115_repurchase_guard_v2.sql
H="-h /tmp -U postgres"; DB=t_rep_v2
psql $H -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql $H -d postgres -q -c "create database $DB" >/dev/null
P="psql $H -d $DB -q -At -v ON_ERROR_STOP=1"
$P -f $FX/fixture.sql >/dev/null || { echo FIXTURE FAIL; exit 1; }
$P -f $FX/fns.sql >/dev/null || { echo FNS FAIL; exit 1; }
$P -f $FX/triggers.sql >/dev/null || { echo TRG FAIL; exit 1; }
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "픽스처 가드 = 라이브 판(md5 538def28…)" 538def2887ae9d9395b88b87512d11d6 "$($P -c "select md5(prosrc) from pg_proc where oid='public.taam_guard_repurchase()'::regprocedure")"
M=a0000000-0000-4000-8000-000000000001; M2=a0000000-0000-4000-8000-000000000002; M3=a0000000-0000-4000-8000-000000000003; M4=a0000000-0000-4000-8000-000000000004
M5=a0000000-0000-4000-8000-000000000005; M6=a0000000-0000-4000-8000-000000000006; M7=a0000000-0000-4000-8000-000000000007; M8=a0000000-0000-4000-8000-000000000008
M9=a0000000-0000-4000-8000-000000000009; SU=a0000000-0000-4000-8000-0000000000ff; EX=a0000000-0000-4000-8000-0000000000ee
RA=b0000000-0000-4000-8000-00000000000a; RB=b0000000-0000-4000-8000-00000000000b; RC=b0000000-0000-4000-8000-00000000000c
seed(){ $P <<SQL >/dev/null
delete from public.tickets; delete from public.ticket_products; delete from public.restaurants; delete from public.profiles; delete from auth.users;
insert into auth.users values ('$M'),('$M2'),('$M3'),('$M4'),('$M5'),('$M6'),('$M7'),('$M8'),('$M9'),('$SU'),('$EX');
insert into public.profiles(id,role,display_name,single_device_exempt) values ('$M','user','M',false),('$M2','user','M2',false),('$M3','user','M3',false),('$M4','user','M4',false),
 ('$M5','user','M5',false),('$M6','user','M6',false),('$M7','user','M7',false),('$M8','user','M8',false),('$M9','user','M9',false),('$SU','superadmin','SU',false),('$EX','user','EX',true);
insert into public.restaurants values ('$RA','90일 매장',90),('$RB','처음엔 제한없음',0),('$RC','180일 매장',180);
insert into public.ticket_products(id,rest_id,rest_name,date,time) values
 ('A1','$RA','90일 매장','2027.01.10','18:00'),('A2','$RA','90일 매장','2027.02.20','18:00'),('A2b','$RA','90일 매장','2027.02.21','18:00'),('A1L','$RA','90일 매장','2027.01.10','12:00'),('A9','$RA','90일 매장','2027.06.30','18:00'),
 ('B1','$RB','처음엔','2027.01.10','18:00'),('B2','$RB','처음엔','2027.02.01','18:00'),
 ('C1','$RC','180일 매장','2027.01.10','18:00'),('C2','$RC','180일 매장','2027.08.01','18:00'),('C3','$RC','180일 매장','2027.03.01','18:00');
SQL
}
res(){ if echo "$1" | grep -q REPURCHASE_BLOCKED; then echo BLOCKED; elif echo "$1" | grep -q ERROR; then echo "ERR:$(echo "$1" | grep ERROR | head -1 | cut -c1-110)"; else echo OK; fi; }
# 회원 세션 홀드(앱과 같은 모양)
hold(){ res "$($P -c "begin; set local taam.uid='$1'; set local role authenticated; insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id, extra_data) values ('$1','$3','$2',${4:-null},'hold','$5','${6:-{\}}'::jsonb); commit;" 2>&1)"; }
# Edge 카드 확정 폴백(toss-confirm · toss-billing-charge convertHoldToActive) 그대로 — service_role · 방문일 null · active
fallback(){ res "$($P -c "begin; set local role service_role; insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, party_size, price, status, purchase_id, extra_data) values ('$1','$3','x','$2',null,2,1000,'active','$4','{\"cardPaid\":1000}'::jsonb); commit;" 2>&1)"; }
srvins(){ res "$($P -c "begin; set local role service_role; insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values ('$1','$3','$2',${4:-null},'active','$5'); commit;" 2>&1)"; }
confirm(){ $P -c "update public.tickets set status='active' where purchase_id='$1'" >/dev/null; }

run_matrix(){   # $1 = old | v2 — 옛 판에선 「열린 길」이 OK, v2 에선 BLOCKED
  local V=$1; seed
  local GAP=OK; [ "$V" = v2 ] && GAP=BLOCKED
  echo "── [$V] 0. 기본 — 회원 세션"
  ok "[$V] M: A1(2027.01.10) 홀드" OK "$(hold $M A1 $RA "'2027.01.10'" PAYH-A1-M)"; confirm PAYH-A1-M
  ok "[$V] M: A2(41일 · 90일 매장) → 막힘" BLOCKED "$(hold $M A2 $RA "'2027.02.20'" PAYH-A2-M)"
  ok "[$V] M: 같은 날 다른 회차(A1L 점심) → 허용(같은 날 예외)" OK "$(hold $M A1L $RA "'2027.01.10'" PAYH-A1L-M)"
  ok "[$V] M: A9(171일 · 창 밖) → 허용" OK "$(hold $M A9 $RA "'2027.06.30'" PAYH-A9-M)"
  ok "[$V] M: 방문일을 안 보내도(null) 막힘" BLOCKED "$(hold $M A2 $RA null PAYH-A2-Mn)"
  ok "[$V] M: 매장 id 를 속여도 막힘" BLOCKED "$(hold $M A2 $RB "'2027.02.20'" PAYH-A2-Ms)"
  ok "[$V] 면제 계정 EX: A1 → A2 둘 다 허용" "OK/OK" "$(hold $EX A1 $RA "'2027.01.10'" PAYH-A1-EX)/$(hold $EX A2 $RA "'2027.02.20'" PAYH-A2-EX)"
  echo "── [$V] 1. 매장 설정을 나중에 바꿈 — 이미 팔린 티켓에도 적용"
  ok "[$V] M2: B1(제한 없음)" OK "$(hold $M2 B1 $RB "'2027.01.10'" PAYH-B1-M2)"; confirm PAYH-B1-M2
  $P -c "update public.restaurants set repurchase_day=90 where id='$RB'" >/dev/null
  ok "[$V] M2: 설정을 0→90 으로 올린 뒤 B2(22일) → 막힘(올리기 전에 산 B1 이 기준)" BLOCKED "$(hold $M2 B2 $RB "'2027.02.01'" PAYH-B2-M2)"
  $P -c "update public.restaurants set repurchase_day=0 where id='$RB'" >/dev/null
  ok "[$V] M2: 다시 0 으로 → 허용" OK "$(hold $M2 B2 $RB "'2027.02.01'" PAYH-B2-M2b)"
  $P -c "update public.restaurants set repurchase_day=30 where id='$RA'" >/dev/null
  ok "[$V] M: 90→30 으로 내리면 A2(41일) → 허용" OK "$(hold $M A2 $RA "'2027.02.20'" PAYH-A2-M30)"
  $P -c "update public.tickets set status='cancelled' where purchase_id='PAYH-A2-M30'; update public.restaurants set repurchase_day=90 where id='$RA'" >/dev/null
  echo "── [$V] 2. 회차별 재구매 해제"
  $P -c "update public.ticket_products set repurchase_open=true where id='A2'" >/dev/null
  ok "[$V] M: 해제된 A2 → 허용" OK "$(hold $M A2 $RA "'2027.02.20'" PAYH-A2-Mrel)"; confirm PAYH-A2-Mrel
  $P -c "update public.ticket_products set repurchase_open=false where id='A2'" >/dev/null
  ok "[$V] M3: A1 홀드 뒤 · 해제를 되돌린 A2 → 다시 막힘" "OK/BLOCKED" "$(hold $M3 A1 $RA "'2027.01.10'" PAYH-A1-M3)/$(hold $M3 A2 $RA "'2027.02.20'" PAYH-A2-M3)"
  echo "── [$V] 3. 카드 확정 폴백(Edge · service_role · 방문일 null)"
  ok "[$V] M4: A1 보유" OK "$(hold $M4 A1 $RA "'2027.01.10'" PAYH-A1-M4)"; confirm PAYH-A1-M4
  ok "[$V] M4: A2(41일) 카드 폴백 INSERT — 옛 판은 통과 · v2 는 막음(Edge 가 예치금 환원·카드 취소)" $GAP "$(fallback $M4 A2 $RA PAYC-A2_1)"
  ok "[$V] M5: 홀드 만료 뒤 같은 id 로 폴백(A1 · 기존 예약 없음) → 들어감" OK "$(fallback $M5 A1 $RA PAYH-A1-M5)"
  local FILL=""; [ "$V" = v2 ] && FILL="2027.01.10|18:00"; [ "$V" = old ] && FILL="|"
  ok "[$V] 그 폴백 행의 방문일·시각 — 옛 판은 빈 칸 · v2 는 회차 값으로 채움" "$FILL" "$($P -c "select coalesce(reservation_date,'')||'|'||coalesce(visit_time,'') from public.tickets where purchase_id='PAYH-A1-M5'")"
  ok "[$V] M5: 그 뒤 A2(41일) 홀드 — 옛 판은 빈 방문일 행을 못 봐 통과 · v2 는 막음" $GAP "$(hold $M5 A2 $RA "'2027.02.20'" PAYH-A2-M5)"
  ok "[$V] 서버의 운영 행(LINK-·KSK-·INV-)은 종전대로 통과" "OK/OK/OK" "$(srvins $M4 A2b $RA "'2027.02.21'" LINK-x1)/$(srvins $M4 A2b $RA "'2027.02.21'" KSK-x1)/$(srvins $M4 A2b $RA "'2027.02.21'" INV-x1)"
  if [ "$V" = v2 ]; then
    ok "[v2] SQL Editor 우회(set local taam.repurchase_bypass='1') → 통과" OK "$(res "$($P -c "begin; set local taam.repurchase_bypass='1'; insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values ('$M4','$RA','A2','2027.02.20','active','PAYC-bypass'); commit;" 2>&1)")"
    ok "[v2] 회원 세션은 우회 설정을 넣어도 안 된다" BLOCKED "$(res "$($P -c "begin; set local taam.uid='$M3'; set local taam.repurchase_bypass='1'; set local role authenticated; insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values ('$M3','$RA','A2b','2027.02.21','hold','PAYH-byp-m'); commit;" 2>&1)")"
    $P -c "insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values ('$SU','$RA','A1','2027.01.10','active','PAYH-su-1')" >/dev/null
    ok "[v2] 주인이 슈퍼어드민인 시험 결제 폴백 → 통과" OK "$(fallback $SU A2 $RA PAYC-su-2)"
  fi
  echo "── [$V] 4. 판매 뒤 회차 날짜를 고침"
  ok "[$V] M6: C1(2027.01.10 · 180일 매장)" OK "$(hold $M6 C1 $RC "'2027.01.10'" PAYH-C1-M6)"; confirm PAYH-C1-M6
  $P -c "update public.ticket_products set date='2027.07.20' where id='C1'" >/dev/null
  ok "[$V] M6: C1 을 2027.07.20 으로 옮긴 뒤 C2(2027.08.01 · 실제 12일) — 옛 판은 옛 날짜로 셈 → 통과 · v2 는 막음" $GAP "$(hold $M6 C2 $RC "'2027.08.01'" PAYH-C2-M6)"
  $P -c "update public.tickets set status='cancelled' where purchase_id='PAYH-C2-M6'" >/dev/null 2>&1
  $P -c "update public.ticket_products set date='2027.12.31' where id='C1'" >/dev/null
  local WR=BLOCKED; [ "$V" = v2 ] && WR=OK
  ok "[$V] M6: C1 을 2027.12.31 로 옮긴 뒤 C3(2027.03.01 · 실제 305일) — 옛 판은 잘못 막음 · v2 는 허용" $WR "$(hold $M6 C3 $RC "'2027.03.01'" PAYH-C3-M6)"
  $P -c "update public.ticket_products set date='2027.01.10' where id='C1'" >/dev/null
  echo "── [$V] 5. 판매 뒤 회차의 매장을 바꿈"
  ok "[$V] M7: C1(180일 매장 · 2027.01.10)" OK "$(hold $M7 C1 $RC "'2027.01.10'" PAYH-C1-M7)"; confirm PAYH-C1-M7
  $P -c "update public.ticket_products set rest_id='$RA', rest_name='90일 매장' where id='C1'" >/dev/null
  ok "[$V] M7: C1 을 90일 매장으로 옮긴 뒤 A2b(42일) — 옛 판은 옛 매장으로 셈 → 통과 · v2 는 막음" $GAP "$(hold $M7 A2b $RA "'2027.02.21'" PAYH-A2b-M7)"
  $P -c "update public.ticket_products set rest_id='$RC', rest_name='180일 매장' where id='C1'" >/dev/null
  echo "── [$V] 6. 연도 없는 날짜가 살아 있는 행에 있을 때"
  $P -c "insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values ('$M8','$RA','zz','06.17','active','PAYH-yl-M8')" >/dev/null
  local YL; YL="$(hold $M8 A1 $RA "'2027.01.10'" PAYH-A1-M8)"
  if [ "$V" = old ]; then ok "[old] 연도 없는 행 → 형 변환 오류로 구매가 깨진다" ERR "${YL%%:*}"; else ok "[v2] 연도 없는 행은 근거 없음으로 건너뛰고 구매는 된다" OK "$YL"; fi
  echo "── [$V] 7. 회원이 자기 행을 고쳐 비켜 가기"
  o=$($P -c "begin; set local taam.uid='$M3'; set local role authenticated; update public.tickets set reservation_date='2026.01.01' where purchase_id='PAYH-A1-M3'; commit;" 2>&1 | grep -c ERROR); ok "[$V] 방문일 직접 변경 → 거절" 1 "$o"
}
run_matrix old
echo "════════ v2 마이그레이션 적용 ════════"
out=$($P -f $MIG 2>&1); echo "$out" | grep -E "✅|❌|repurchase v2" | sed 's/^/   /'
ok "확인 표에 ❌ 없음" 0 "$(echo "$out" | grep -c '❌')"
ok "가드가 v2" 1 "$($P -c "select count(*) from pg_proc where oid='public.taam_guard_repurchase()'::regprocedure and prosrc like '%REPURCHASE_V2_20261115%'")"
out2=$($P -f $MIG 2>&1); ok "두 번 실행해도 그대로(이미 v2)" 1 "$(echo "$out2" | grep -c '이미 v2')"
run_matrix v2
echo "════════ 모르는 판이면 건드리지 않는다 ════════"
$P -c "drop database if exists t_rep_v2_unk" >/dev/null 2>&1; psql $H -d postgres -q -c "drop database if exists t_rep_v2_unk" >/dev/null 2>&1; psql $H -d postgres -q -c "create database t_rep_v2_unk" >/dev/null
PU="psql $H -d t_rep_v2_unk -q -At"
$PU -f $FX/fixture.sql >/dev/null 2>&1; $PU -f $FX/fns.sql >/dev/null 2>&1; $PU -f $FX/triggers.sql >/dev/null 2>&1
$PU -c "create or replace function public.taam_guard_repurchase() returns trigger language plpgsql as \$x\$ begin return new; end \$x\$" >/dev/null
o=$($PU -f $MIG 2>&1); ok "모르는 판 → 확인 표 ❌ · 본문 그대로" "1|0" "$(echo "$o" | grep -c '❌ 바뀌지 않음')|$($PU -c "select count(*) from pg_proc where oid='public.taam_guard_repurchase()'::regprocedure and prosrc like '%REPURCHASE_V2%'")"
psql $H -d postgres -q -c "drop database if exists t_rep_v2_unk" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
