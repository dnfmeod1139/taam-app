#!/bin/bash
# 회차 날짜·시간 이동 → 팔린 예약·초대·정산 좌석이 같이 옮겨 간다 — 2026-11-16 (supabase/migrations/20261116_round_move_sync.sql)
# 먼저: 로컬 pg(/tmp 소켓). 실행: bash sql/_test/t_round_move.sh   (KEEP=1 이면 DB 를 남긴다)
#   픽스처 = fx_repurchase_live_2026-11-15(가드 원문) + fx_round_move_live_2026-11-16(이동 경로에 걸리는 라이브 트리거 원문 · md5 대조) + 재구매 v2
#   리마인드 패치는 t_reminder_day_admin.sh 가 만든 t_rda(라이브 md5 52d0603a·b42fdace 재현)를 본떠서 본다.
cd "$(dirname "$0")/../.."
FX=sql/_test/fx_repurchase_live_2026-11-15; FX2=sql/_test/fx_round_move_live_2026-11-16; MIG=${TAAM_TEST_MIG:-supabase/migrations/20261116_round_move_sync.sql}
H="-h /tmp -U postgres"; DB=${TAAM_TEST_DB:-t_rmove}   # TAAM_TEST_DB 로 DB 이름을 바꿀 수 있다(여러 세션이 같이 돌 때)
psql $H -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql $H -d postgres -q -c "create database $DB" >/dev/null
P="psql $H -d $DB -q -At -v ON_ERROR_STOP=1"
Q="psql $H -d $DB -q -At"
for f in $FX/fixture.sql $FX2/fixture_extra.sql $FX/fns.sql $FX2/fns_extra.sql $FX2/ksk_sync.sql $FX/triggers.sql $FX2/triggers_extra.sql; do
  $P -f $f >/dev/null || { echo "FIXTURE FAIL $f"; exit 1; }
done
$P -f supabase/migrations/20261115_repurchase_guard_v2.sql >/dev/null || { echo "V2 FAIL"; exit 1; }
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
md(){ $P -c "select md5(prosrc) from pg_proc where proname='$1' and pronamespace='public'::regnamespace"; }
echo "── 0. 픽스처 = 라이브 원문"
for pair in taam_guard_purchase_unique:ed27df3b771cb0aa866e3ce50227b0f4 taam_guard_repurchase:7c0a12f2bf9fb338e838903c187a6f0e taam_guard_ticket_row:c34e544b9c52f6732de9d46003cd763b \
  taam_guard_ticket_payfacts:b43c845c1f011217df199853564ddcd7 taam_guard_ticket_linkfacts:83fc4d47af48ebc2a7ad2b7d9b479947 taam_guard_text_input:95cd6adc5c899001635306c5bddbf00a \
  _taam_text_bad:e72ebaff387790c5f8c1b867821370bb taam_guard_ticket_crp_member:4d04a26272a71938b52ccfadf2a84f66 taam_guard_ticket_processed_cardq:8b201f8f0644178f7778061187fbc240 \
  touch_ticket_product_on_seat_change:d9c4beeacd17b38e74c1eaf473cc73e5 sync_ticket_soldout:d2c21d9ebb98b43f19efd7fa95c0fd76 _taam_tp_date_year:64fb6e6f4dc323ae31ff16dbab7a0100 \
  taam_tp_status_recalc:57bbefcca5e563e356ca63f4249d4c2c taam_guard_tp_keep_hidden:0d61a84ac8fa11f3590b01382a341a8b taam_guard_invite_host:4b0c5ddb3346b9da7df29368f70ff951 \
  taam_guard_invite_row:d683fd9e4ff4a1dcf713ac70d11d4b65 taam_guard_invite_rest:a9ea7ce8ed3dfb3791969cb67417f67c taam_ksk_seat_on_event:057b8297fa3ef2b76fe75fcc438bb8f7 \
  _taam_ksk_seat_sync:8272a889d81f31d16e0db63fc97b9dcc _taam_pu_clash_other:1b0c6b25766aa8a9e9c4ec30e84e659c _taam_fee_caller_ok:128d1f7ba2a0a556b1975d17a070fdfb \
  _taam_pu_visit_date:b200c9f08dce087dcb74cf0632859a25 _taam_purchase_exc_find:2cc9e4a71c8c9ff6b5c3dda0f9de0217 _taam_ticket_is_ops:0833f46be29199689edb1d494ba47894 \
  taam_time_slot:d7ecede66431a3e408eae8e636bd7bc7 taam_ticket_sold_slots:708f1b3e5765278f3ed13291964f05fb; do
  ok "md5 ${pair%%:*}" "${pair#*:}" "$(md ${pair%%:*})"
done

M1=a0000000-0000-4000-8000-000000000001; M2=a0000000-0000-4000-8000-000000000002; M3=a0000000-0000-4000-8000-000000000003; M4=a0000000-0000-4000-8000-000000000004
M5=a0000000-0000-4000-8000-000000000005; M6=a0000000-0000-4000-8000-000000000006; M7=a0000000-0000-4000-8000-000000000007; M8=a0000000-0000-4000-8000-000000000008
M9=a0000000-0000-4000-8000-000000000009; MA=a0000000-0000-4000-8000-00000000000a; PT=a0000000-0000-4000-8000-0000000000aa; SU=a0000000-0000-4000-8000-0000000000ff
RA=b0000000-0000-4000-8000-00000000000a; RB=b0000000-0000-4000-8000-00000000000b
E1=c0000000-0000-4000-8000-000000000001; C1=d0000000-0000-4000-8000-000000000001; C2=d0000000-0000-4000-8000-000000000002; C3=d0000000-0000-4000-8000-000000000003
I1=e0000000-0000-4000-8000-000000000001; I2=e0000000-0000-4000-8000-000000000002
T_PAY=f0000000-0000-4000-8000-000000000001; T_LEG=f0000000-0000-4000-8000-000000000002; T_INV=f0000000-0000-4000-8000-000000000003; T_INVH=f0000000-0000-4000-8000-000000000004
T_LINKM=f0000000-0000-4000-8000-000000000005; T_LINKG=f0000000-0000-4000-8000-000000000006; T_MAN=f0000000-0000-4000-8000-000000000007; T_HOLD=f0000000-0000-4000-8000-000000000008
T_PC=f0000000-0000-4000-8000-000000000009; T_CXL=f0000000-0000-4000-8000-00000000000a; T_VIS=f0000000-0000-4000-8000-00000000000b; T_SIB1=f0000000-0000-4000-8000-00000000000c
T_SIB2=f0000000-0000-4000-8000-00000000000d; T_M3A=f0000000-0000-4000-8000-00000000000e; T_M3B=f0000000-0000-4000-8000-00000000000f; T_M4B=f0000000-0000-4000-8000-000000000010
seed(){ $P <<SQL >/dev/null
set session_replication_role = replica;   -- 시드만 — 가드를 끄고 넣는다(라이브에 있는 모양 그대로)
delete from public._push_calls; delete from public.notifications; delete from public.guest_remind_log; delete from public.daegwan_manual;
delete from public.kashikiri_charges; delete from public.kashikiri_teams; delete from public.kashikiri_events; delete from public.reservation_invites;
delete from public.purchase_rule_exception_uses; delete from public.purchase_rule_exceptions; delete from public.tickets; delete from public.ticket_products;
delete from public.restaurants; delete from public.profiles; delete from auth.users;
do \$\$ begin if to_regclass('public.ticket_round_moves') is not null then delete from public.ticket_round_moves; end if; end \$\$;
insert into auth.users values ('$M1'),('$M2'),('$M3'),('$M4'),('$M5'),('$M6'),('$M7'),('$M8'),('$M9'),('$MA'),('$PT'),('$SU');
insert into public.profiles(id,role,display_name) values ('$M1','user','회원1'),('$M2','user','회원2'),('$M3','user','회원3'),('$M4','user','회원4'),('$M5','user','회원5'),
 ('$M6','user','회원6'),('$M7','user','회원7'),('$M8','user','회원8'),('$M9','user','회원9'),('$MA','user','회원A'),('$PT','user','파트너'),('$SU','superadmin','슈퍼');
update public.profiles set notif_prefs='{"all":false}' where id='$M5';
insert into public.restaurants(id,name,repurchase_day,name_en,name_jp) values ('$RA','미토우',30,'Mitou','味豆'),('$RB','다른집',0,null,null);
insert into public.ticket_products(id,rest_id,rest_name,date,time,status,total_pax) values
 ('R1','$RA','미토우','2027.03.10','18:00','active',40),('R2','$RB','다른집','2027.03.17','18:30','active',10),
 ('R3','$RA','미토우','2027.04.10','18:00','active',10),('R0','$RA','미토우','2026.01.10','18:00','active',10),('RE','$RB','다른집','2027.05.01','12:00','active',10);
-- R1 의 좌석 행 — 회원 결제 · 옛 숫자 id · 초대 좌석 · 초대 홀드 · 결제 링크(회원/비회원) · 수동(20:30) · 결제 중 홀드 · 게스트 확정 대기 · 취소 · 방문 처리 · 같은 회차 두 장
insert into public.tickets(id,user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,buyer_name,buyer_phone,extra_data) values
 ('$T_PAY','$M1','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'active','PAYH-R1-M1',null,null,'{"time_change":{"from":"17:00","to":"18:00","status":"pending"}}'),
 ('$T_LEG','$M4','$RA','미토우','R1','2027.03.10','',2,1800000,'active','1789000000001',null,null,'{}'),
 ('$T_INV','$M5','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'active','INV-e0000000-1',null,null,'{"inviteId":"$I1"}'),
 ('$T_INVH','$SU','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'hold','INVH-e0000000-2',null,null,'{"inviteId":"$I2","inviteHold":true}'),
 ('$T_LINKM','$M7','$RA','미토우','R1','2027.03.10','18:00',2,0,'active','LINK-d0000000-1',null,null,'{"chargeId":"$C1","linkInvite":true,"memberUid":"$M7"}'),
 ('$T_LINKG','$SU','$RA','미토우','R1','2027.03.10','18:00',1,0,'active','LINK-d0000000-2','손님L','01011112222','{"chargeId":"$C2","linkInvite":true}'),
 ('$T_MAN','$SU','$RA','미토우','R1','2027.03.10','20:30',3,0,'manual','MAN-1791','손님M','01033334444','{"manualEntry":true}'),
 ('$T_HOLD','$M8','$RA','미토우','R1','2027.03.10','18:00',2,0,'hold','PAYH-R1-M8',null,null,'{}'),
 ('$T_PC','$M9','$RA','미토우','R1','2027.03.10','18:00',1,900000,'pending_confirm','PAYH-R1-M9',null,null,'{}'),
 ('$T_CXL','$M1','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'cancelled','PAYH-R1-M1x',null,null,'{}'),
 ('$T_VIS','$MA','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'active','PAYH-R1-MA',null,null,'{}'),
 ('$T_SIB1','$M2','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'active','PAYH-R1-M2a',null,null,'{}'),
 ('$T_SIB2','$M2','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'active','PAYH-R1-M2b',null,null,'{}'),
 ('$T_M3A','$M3','$RA','미토우','R1','2027.03.10','18:00',2,1800000,'active','PAYH-R1-M3',null,null,'{}'),
 ('$T_M3B','$M3','$RB','다른집','R2','2027.03.17','18:30',2,500000,'active','PAYH-R2-M3',null,null,'{}'),
 ('$T_M4B','$M4','$RA','미토우','R3','2027.04.10','18:00',2,1800000,'active','PAYH-R3-M4',null,null,'{}');
update public.tickets set visit_status='attended' where id='$T_VIS';
insert into public.reservation_invites(id,host_user_id,invitee_user_id,restaurant_id,restaurant_name,visit_date,visit_time,pax,status,ticket_product_id) values
 ('$I1','$SU','$M5','$RA','미토우','2027.03.10','18:00',2,'paid','R1'),('$I2','$SU','$M6','$RA','미토우','2027.03.10','18:00',2,'sent','R1');
insert into public.kashikiri_charges(id,label,status,purpose,subtitle,link_invite) values
 ('$C1','회원7','paid','ticket','2027.03.10 18:00',true),('$C2','손님L','paid','ticket','2027.03.10 18:00',true);
insert into public.kashikiri_events(id,venue_id,venue_name,event_date,event_time,ticket_product_id,created_by) values ('$E1','$RA','미토우','2027-03-10','18:00','R1','$SU');
insert into public.kashikiri_teams(id,event_id,pax) values ('$C3','$E1',2);
insert into public.kashikiri_charges(id,event_id,team_id,label,status,purpose,payer_name) values ('$C3','$E1','$C3','정산','paid','custom','정산손님');
insert into public.purchase_rule_exceptions(user_id,ticket_product_id,allow_dup,allow_time,extra,expires_at,note)
 values ('$M2','R1',true,false,1,((date '2027-03-10' + 1)::timestamp at time zone 'Asia/Seoul'),'두 장'),
        ('$M2','R1',true,false,1,timestamptz '2027-12-31 00:00+09','직접 정한 기한');
insert into public.guest_remind_log(ticket_id,d,result) values ('$T_LINKG',3,'sent');
insert into public.daegwan_manual(venue_id,ymd,name,pax) values ('$RA','2027-03-10','황',3),('$RA','2027-03-11','다른날',1);
set session_replication_role = origin;
select public._taam_ksk_seat_sync('$E1');   -- 정산 좌석(KSK-) 하나
SQL
}
su(){ $Q -c "begin; set local taam.uid='$SU'; set local role authenticated; $1; commit;" 2>&1; }
as_uid(){ $Q -c "begin; set local taam.uid='$1'; set local role authenticated; $2; commit;" 2>&1; }
dt(){ $P -c "select coalesce(reservation_date,'')||' '||coalesce(visit_time,'') from public.tickets where id='$1'"; }

echo "── 1. 옛 가드(패치 전) — 같은 회차 두 장의 날짜를 차례로 옮기면 두 번째가 TIME_CONFLICT"
seed
o=$($Q -c "begin; set local taam.uid='$SU'; update public.tickets set reservation_date='2027.03.17' where id in ('$T_SIB1','$T_SIB2'); rollback;" 2>&1)
ok "옛 가드: 형제 행 이동이 TIME_CONFLICT" 1 "$(echo "$o" | grep -c TIME_CONFLICT)"

echo "── 2. 마이그레이션"
out=$($P -f $MIG 2>&1); echo "$out" | grep -E "❌|ERROR" | head -5
ok "확인 표 ❌ 는 ③④ 둘뿐(이 픽스처엔 리마인드 함수가 없다 — 12절에서 따로 본다)" "2|2" "$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '^[③④].*❌')"
ok "확인 표 ✅ 5줄(①②⑤⑥⑦)" 5 "$(echo "$out" | grep -c '✅')"
ok "가드 패치 표시" 1 "$($P -c "select count(*) from pg_proc where proname='taam_guard_purchase_unique' and prosrc like '%ROUND_MOVE_20261116%'")"
seed

echo "── 3. 앱이 직접 보낸 저장은 날짜를 못 바꾼다(옮길 예약이 있는 회차)"
o=$(su "update public.ticket_products set date='2027.03.17' where id='R1'"); ok "직접 UPDATE → ROUND_RESCHEDULE_REQUIRED" 1 "$(echo "$o" | grep -c ROUND_RESCHEDULE_REQUIRED)"
o=$(su "insert into public.ticket_products(id,rest_id,rest_name,date,time,status) values ('R1','$RA','미토우','2027.03.10','19:00','active') on conflict (id) do update set date=excluded.date, time=excluded.time")
ok "upsert(시간 변경) → ROUND_RESCHEDULE_REQUIRED" 1 "$(echo "$o" | grep -c ROUND_RESCHEDULE_REQUIRED)"
o=$(su "insert into public.ticket_products(id,rest_id,rest_name,date,time,status,total_pax) values ('R1','$RA','미토우','2027.03.10','18:00','soldout',40) on conflict (id) do update set date=excluded.date, time=excluded.time, status=excluded.status")
ok "같은 날짜·시간 upsert(매진 토글) → 통과" 0 "$(echo "$o" | grep -c ERROR)"
o=$(su "insert into public.ticket_products(id,rest_id,rest_name,date,time,status,total_pax) values ('R1','$RA','미토우','03.10','18:00:00','active',40) on conflict (id) do update set date=excluded.date, time=excluded.time, status=excluded.status")
ok "형식만 다른 upsert('03.10' · '18:00:00') → 통과 · 이동 기록 없음" "0|0" "$(echo "$o" | grep -c ERROR)|$($P -c "select count(*) from public.ticket_round_moves")"
ok "  날짜는 저장된 연도로(2027.03.10)" "2027.03.10" "$($P -c "select date from public.ticket_products where id='R1'")"
o=$(su "update public.ticket_products set date='2027.05.02' where id='RE'"); ok "예약 없는 회차는 직접 바꿔도 된다" 0 "$(echo "$o" | grep -c ERROR)"
o=$(as_uid $PT "update public.ticket_products set date='2027.03.17' where id='R1'")
ok "파트너 직접 수정(승인 트리거가 되돌림) → 오류 없음 · 날짜 그대로 · 이동 없음" "0|2027.03.10|0" "$(echo "$o" | grep -c ERROR)|$($P -c "select date from public.ticket_products where id='R1'")|$($P -c "select count(*) from public.ticket_round_moves")"

echo "── 4. 미리보기 (읽기만)"
pv=$($Q -c "begin read only; set local taam.uid='$SU'; set local role authenticated; select public.taam_round_move_preview('R1','2027.03.17',null); commit;" 2>&1)
ok "미리보기 읽기 전용 트랜잭션에서 된다" 0 "$(echo "$pv" | grep -c ERROR)"
pvj=$(echo "$pv" | grep '^{')
ok "옮길 좌석 행 11 (회원·옛id·초대좌석·초대홀드·링크2·수동·홀드·확정대기·형제2+M3)" 12 "$($P -c "select count(*) from jsonb_array_elements('$pvj'::jsonb->'rows') e where e->>'kind'='ticket' and e->>'action'='move'")"
ok "남길 행: 방문 처리 1" "visited" "$($P -c "select string_agg(e->>'reason',',') from jsonb_array_elements('$pvj'::jsonb->'rows') e where e->>'action'='keep'")"
ok "초대 2 · 정산 회차 1 · 정산 좌석 1" "2|1|1" "$($P -c "select (select count(*) from jsonb_array_elements(j->'rows') e where e->>'kind'='invite' and e->>'action'='move')||'|'||(select count(*) from jsonb_array_elements(j->'rows') e where e->>'kind'='event' and e->>'action'='move')||'|'||(select count(*) from jsonb_array_elements(j->'rows') e where e->>'action'='event') from (select '$pvj'::jsonb j) x")"
ok "겹침: 회원3(다른집 03.17 18:30) · 재구매 창: 회원4(R3 04.10 · 24일)" "repurchase|time" "$($P -c "select string_agg(e->>'kind','|' order by e->>'kind') from jsonb_array_elements('$pvj'::jsonb->'conflicts') e")"
ok "수동 기록 후보 1 · 기한 바뀔 예외 1" "1|1" "$($P -c "select jsonb_array_length('$pvj'::jsonb->'manual')||'|'||('$pvj'::jsonb->>'exceptions')")"
ok "회원은 미리보기 못 함" 1 "$(as_uid $M1 "select public.taam_round_move_preview('R1','2027.03.17',null)" | grep -c FORBIDDEN)"
ok "비로그인 실행 권한 없음(다섯 RPC)" 0 "$($P -c "select count(*) from pg_proc where proname in ('taam_round_move_preview','taam_round_reschedule','taam_round_move_resync','taam_round_moves','taam_round_move_notify') and has_function_privilege('anon', oid, 'execute')")"
ok "내부 도우미는 회원이 못 부른다(계획·적용·따라올 날짜)" "false|false|false" "$($P -c "select has_function_privilege('authenticated','public._taam_round_move_plan(text,date,text,date[],text[],jsonb)','execute')||'|'||has_function_privilege('authenticated','public._taam_round_move_apply(text,date,text,date,text,date[],text[],text,text,jsonb)','execute')||'|'||has_function_privilege('authenticated','public._taam_round_follow_spec(text,boolean)','execute')")"

echo "── 5. 날짜 바꾸기 RPC"
o=$(su "select public.taam_round_reschedule('R1','2027.03.17',null,'2027.03.09','18:00','{}')"); ok "화면이 본 옛 값과 다르면 STALE_ROUND" 1 "$(echo "$o" | grep -c STALE_ROUND)"
o=$(su "select public.taam_round_reschedule('R1','2026.03.17',null,'2027.03.10','18:00','{}')"); ok "새 날짜가 지난 날 → NEW_DATE_PAST" 1 "$(echo "$o" | grep -c NEW_DATE_PAST)"
o=$(su "select public.taam_round_reschedule('R1','03.17',null,'2027.03.10','18:00','{}')"); ok "연도 없는 날짜 → BAD_DATE" 1 "$(echo "$o" | grep -c BAD_DATE)"
o=$(as_uid $M1 "select public.taam_round_reschedule('R1','2027.03.17',null,'2027.03.10','18:00','{}')"); ok "회원 → FORBIDDEN" 1 "$(echo "$o" | grep -c FORBIDDEN)"
o=$(su "select public.taam_round_reschedule('R1','2027.03.17',null,'2027.03.10','18:00','{\"note\":\"매장 요청\",\"move_manual\":true}')")
ok "RPC 성공" 1 "$(echo "$o" | grep -c '"ok": true')"
ok "회차 날짜 2027.03.17 · 시간 18:00 그대로" "2027.03.17 18:00" "$($P -c "select date||' '||time from public.ticket_products where id='R1'")"
for t in T_PAY T_LEG T_INV T_INVH T_LINKM T_LINKG T_HOLD T_PC T_SIB1 T_SIB2 T_M3A; do
  eval id=\$$t; ok "  $t → 2027.03.17" "2027.03.17" "$($P -c "select reservation_date from public.tickets where id='$id'")"
done
ok "  옛 숫자 id 의 빈 시각은 비운 채(시간은 안 바꿈)" "2027.03.17 " "$(dt $T_LEG)"
ok "  수동 좌석 20:30 그대로" "2027.03.17 20:30" "$(dt $T_MAN)"
ok "  취소 행 · 방문 처리 행은 옛 날짜" "2027.03.10|2027.03.10" "$($P -c "select reservation_date from public.tickets where id='$T_CXL'")|$($P -c "select reservation_date from public.tickets where id='$T_VIS'")"
ok "  초대 두 줄 → 2027.03.17" "2027.03.17,2027.03.17" "$($P -c "select string_agg(visit_date,',') from public.reservation_invites")"
ok "  정산 회차 · 정산 좌석(KSK-)" "2027-03-17|2027.03.17 18:00" "$($P -c "select event_date from public.kashikiri_events")|$($P -c "select reservation_date||' '||visit_time from public.tickets where purchase_id like 'KSK-%'")"
ok "  결제 링크 부제" "2027.03.17 18:00,2027.03.17 18:00" "$($P -c "select string_agg(subtitle,',' order by subtitle) from public.kashikiri_charges where purpose='ticket'")"
ok "  기본 기한 예외만 새 방문일 끝으로 · 직접 정한 기한 그대로" "2027-03-18 00:00:00|2027-12-31 00:00:00" "$($P -c "select string_agg(to_char(expires_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS'),'|' order by expires_at) from public.purchase_rule_exceptions")"
ok "  비회원 알림톡 기록 지움" 0 "$($P -c "select count(*) from public.guest_remind_log")"
ok "  수동 기록(같은 매장·옛 날짜)만 옮김" "2027-03-11,2027-03-17" "$($P -c "select string_agg(ymd::text,',' order by ymd) from public.daegwan_manual")"
ok "  같은 회차 두 장 · 구매 규정 예외 사용 기록 안 생김" 0 "$($P -c "select count(*) from public.purchase_rule_exception_uses")"
ok "  옮긴 행 표시(round_move) · 회원 대기 시간 변경 안내는 그대로(시간 안 바뀜)" "2027.03.10|pending" "$($P -c "select (extra_data->'round_move'->'from'->>'d')||'|'||(extra_data->'time_change'->>'status') from public.tickets where id='$T_PAY'")"
ok "  회차 상태 그대로(active) · 매진 동기화 오작동 없음" "active" "$($P -c "select status from public.ticket_products where id='R1'")"
mv=$($P -c "select id||'|'||via||'|'||jsonb_array_length(moved)||'|'||jsonb_array_length(kept)||'|'||jsonb_array_length(errors)||'|'||coalesce(note,'')||'|'||(moved_by='$SU') from public.ticket_round_moves order by id desc limit 1")
MID=${mv%%|*}
ok "  기록 한 줄: reschedule · 옮김 14(좌석 11+수동? · 초대 2 · 정산 1) · 남김 1 · 오류 0 · 메모 · 누가" "reschedule|15|1|0|매장 요청|true" "${mv#*|}"
ok "  기록의 겹침 2(시간대 회원3 · 재구매 회원4)" "repurchase:$M4|time:$M3" "$($P -c "select string_agg((e->>'kind')||':'||(e->>'uid'),'|' order by e->>'kind') from public.ticket_round_moves m, jsonb_array_elements(m.conflicts) e where m.id=$MID")"
ok "  정산 동기화 결과 기록" 1 "$($P -c "select jsonb_array_length(side->'ksk') from public.ticket_round_moves where id=$MID")"

echo "── 6. 시간만 바꾸기 18:00 → 19:00 (같은 저녁 시간대)"
o=$(su "select public.taam_round_reschedule('R1','2027.03.17','19:00','2027.03.17','18:00','{}')")
ok "RPC 성공" 1 "$(echo "$o" | grep -c '"ok": true')"
ok "  회원 좌석 19:00 · 수동 20:30 그대로 · 빈 시각은 19:00 으로" "2027.03.17 19:00|2027.03.17 20:30|2027.03.17 19:00" "$(dt $T_PAY)|$(dt $T_MAN)|$(dt $T_LEG)"
ok "  초대 19:00 · 정산 회차 19:00 · 정산 좌석 19:00" "19:00,19:00|19:00:00|19:00" "$($P -c "select string_agg(visit_time,',') from public.reservation_invites")|$($P -c "select event_time from public.kashikiri_events")|$($P -c "select visit_time from public.tickets where purchase_id like 'KSK-%'")"
ok "  부제 19:00" "2027.03.17 19:00,2027.03.17 19:00" "$($P -c "select string_agg(subtitle,',' order by subtitle) from public.kashikiri_charges where purpose='ticket'")"
ok "  대기 중이던 시간 변경 안내 → superseded" "superseded" "$($P -c "select extra_data->'time_change'->>'status' from public.tickets where id='$T_PAY'")"
ok "  수동 좌석은 남김(time_individual)" "time_individual" "$($P -c "select e->>'reason' from public.ticket_round_moves m, jsonb_array_elements(m.kept) e where m.id=(select max(id) from public.ticket_round_moves) and e->>'pid'='MAN-1791'")"
ok "  같은 슬롯 안 시간 변경은 겹침 판정 대상 아님(가드 미도달) · 오류 0" 0 "$($P -c "select jsonb_array_length(errors) from public.ticket_round_moves order by id desc limit 1")"

echo "── 7. 회원 알림 (한 번만)"
nr=$(su "select public.taam_round_move_notify($MID)")
ok "알림 RPC 성공" 1 "$(echo "$nr" | grep -c '"ok": true')"
ok "  알림함 줄: 회원1·2·3·4·5(초대좌석)·6(보낸 초대)·7(회원 링크)·9(확정대기) — 8명 · 홀드(회원8)·수동·비회원 링크·초대홀드 주인 없음" 8 "$($P -c "select count(*) from public.notifications where type='ticket_date_changed'")"
ok "  회원2(두 장)는 한 줄" 1 "$($P -c "select count(*) from public.notifications where type='ticket_date_changed' and user_id='$M2'")"
ok "  보낸 초대는 결제 화면 링크" "/?ri_pay=$I2" "$($P -c "select url from public.notifications where user_id='$M6' and type='ticket_date_changed'")"
ok "  문구(한국어) — 매장·옛→새 날짜" 1 "$($P -c "select count(*) from public.notifications where user_id='$M1' and type='ticket_date_changed' and body like '미토우%2027년 3월 10일(수) 18:00 → 2027년 3월 17일(수) 18:00%'")"
ok "  세 언어 i18n(영어 매장 이름 · 일본어 요일)" "Mitou|味豆" "$($P -c "select split_part(payload->'i18n'->'en'->>'body',E'\n',1)||'|'||split_part(payload->'i18n'->'ja'->>'body',E'\n',1) from public.notifications where user_id='$M1' and type='ticket_date_changed'")"
ok "  푸시: 알림 끈 회원5 빼고 7번 · 분류 ticket_time_changed" "7|ticket_time_changed" "$($P -c "select count(*)||'|'||min(category) from public._push_calls")"
ok "  수동·비회원 링크는 직접 연락 목록(전화 포함)" "2|01033334444" "$(echo "$nr" | grep '^{' | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(len(d['manual_contact']))+'|'+[m['phone'] for m in d['manual_contact'] if m['owner']=='manual'][0])")"
ok "  알림 줄에 purchase_id(옛 FK) 안 씀" 0 "$($P -c "select count(*) from public.notifications where purchase_id is not null")"
ok "  두 번째 호출 → already · 줄 안 늘어남" "1|8" "$(su "select public.taam_round_move_notify($MID)" | grep -c already)|$($P -c "select count(*) from public.notifications where type='ticket_date_changed'")"

echo "── 8. SQL Editor 로 바꿈(트리거 경로) · 잠긴 행은 busy 로 남고 다시 맞추기로"
($Q -c "begin; select 1 from public.tickets where id='$T_SIB1' for update; select pg_sleep(3); commit;" >/dev/null 2>&1 &)
sleep 0.7
$P -c "update public.ticket_products set date='2027.03.24' where id='R1'" >/dev/null
ok "SQL Editor 이동: 잠긴 회원2-a 는 옛 날짜 · 나머지는 03.24" "2027.03.17|2027.03.24" "$($P -c "select reservation_date from public.tickets where id='$T_SIB1'")|$($P -c "select reservation_date from public.tickets where id='$T_SIB2'")"
ok "  기록: via trigger · 오류 busy 1" "trigger|busy" "$($P -c "select via||'|'||(errors->0->>'code') from public.ticket_round_moves order by id desc limit 1")"
sleep 3
o=$(su "select public.taam_round_move_resync('R1')"); ok "다시 맞추기 → 회원2-a 도 03.24" "2027.03.24" "$($P -c "select reservation_date from public.tickets where id='$T_SIB1'")"
ok "  다시 맞추기 기록 via resync · 옮김 1" "resync|1" "$($P -c "select via||'|'||jsonb_array_length(moved) from public.ticket_round_moves order by id desc limit 1")"
o=$(su "select public.taam_round_move_resync('R1')"); ok "  한 번 더 → 옮길 것 없음(기록 없음)" 1 "$(echo "$o" | grep -c '"move_id": null')"

echo "── 9. 지난 회차 · 지난 새 날짜 · 못 읽는 날짜"
$P <<SQL >/dev/null
insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id) values ('$M1','$RA','미토우','R0','2026.01.10','18:00',2,100,'active','PAYH-R0-M1');
SQL
$P -c "update public.ticket_products set date='2027.06.01' where id='R0'" >/dev/null
ok "옛 날짜가 지난 회차 → 행은 그대로 · 기록 past_round" "2026.01.10|past_round" "$($P -c "select reservation_date from public.tickets where purchase_id='PAYH-R0-M1'")|$($P -c "select kept->0->>'reason' from public.ticket_round_moves order by id desc limit 1")"
$P -c "update public.ticket_products set date='2026.03.24' where id='R1'" >/dev/null
ok "새 날짜가 지난 날(연도 실수) → 아무것도 안 옮김 · NEW_DATE_PAST" "2027.03.24|NEW_DATE_PAST" "$($P -c "select reservation_date from public.tickets where id='$T_PAY'")|$($P -c "select errors->0->>'code' from public.ticket_round_moves order by id desc limit 1")"
$P -c "update public.ticket_products set date='2027.03.24' where id='R1'" >/dev/null
$P -c "update public.ticket_products set date='언젠가' where id='R1'" >/dev/null
ok "못 읽는 날짜 → NEW_DATE_UNREADABLE · 행 그대로" "2027.03.24|NEW_DATE_UNREADABLE" "$($P -c "select reservation_date from public.tickets where id='$T_PAY'")|$($P -c "select errors->0->>'code' from public.ticket_round_moves order by id desc limit 1")"
$P -c "update public.ticket_products set date='2027.03.24' where id='R1'" >/dev/null

echo "── 10. 새로 넣는 행은 회차 날짜로 고정"
o=$(su "insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values ('$SU','$RA','미토우','R1','2027.03.10','20:00',1,0,'manual','MAN-stale','{\"manualEntry\":true}')")
ok "낡은 화면의 수동 좌석(옛 날짜 · 20:00) → 회차 날짜 · 시각은 그대로" "2027.03.24 20:00" "$($P -c "select reservation_date||' '||visit_time from public.tickets where purchase_id='MAN-stale'")"
o=$(su "insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id) values ('$SU','$RA','미토우','R1','2027.03.10',null,1,0,'manual','MAN-stale2')")
ok "빈 시각 → 회차 시각" "2027.03.24 19:00" "$($P -c "select reservation_date||' '||visit_time from public.tickets where purchase_id='MAN-stale2'")"
o=$(su "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,restaurant_name,visit_date,visit_time,pax,status,ticket_product_id) values ('$SU','$MA','$RA','미토우','2027.03.10','20:30',1,'sent','R1')")
ok "낡은 화면의 초대 → 회차 날짜 · 고른 시각 그대로" "2027.03.24 20:30" "$($P -c "select visit_date||' '||visit_time from public.reservation_invites where invitee_user_id='$MA'")"

echo "── 11. 다시 실행 · 모르는 가드"
out=$($P -f $MIG 2>&1); ok "두 번째 RUN: ❌ 는 ③④ 둘 · 오류 0" "2|0" "$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c ERROR)"
ok "  가드 덩어리 한 번만" 1 "$($P -c "select (length(prosrc)-length(replace(prosrc,'ROUND_MOVE_20261116','')))/length('ROUND_MOVE_20261116') from pg_proc where proname='taam_guard_purchase_unique'")"
DB2=${DB}_unk; psql $H -d postgres -q -c "drop database if exists $DB2" >/dev/null 2>&1; psql $H -d postgres -q -c "create database $DB2" >/dev/null
P2="psql $H -d $DB2 -q -At -v ON_ERROR_STOP=1"
for f in $FX/fixture.sql $FX2/fixture_extra.sql $FX/fns.sql $FX2/fns_extra.sql $FX2/ksk_sync.sql $FX/triggers.sql $FX2/triggers_extra.sql; do $P2 -f $f >/dev/null; done
$P2 -c "create or replace function public.taam_guard_purchase_unique() returns trigger language plpgsql as \$\$ begin return new; end \$\$" >/dev/null
out=$($P2 -f $MIG 2>&1)
ok "모르는 가드 판 → ① ❌ · 트리거 안 만듦" "1|0" "$(echo "$out" | grep -c '① .*❌\|❌ 가드')|$($P2 -c "select count(*) from pg_trigger where tgname in ('trg_taam_tp_round_move','trg_taam_tp_round_lock')")"
psql $H -d postgres -q -c "drop database if exists $DB2" >/dev/null 2>&1

echo "── 11-2. 1차 판(기다리는 회원 잠금) → 2차 판으로 바꾼다"
$P >/dev/null <<'SQL'
do $x$ declare d text; begin
  d := pg_get_functiondef('public.taam_guard_purchase_unique()'::regprocedure);
  d := replace(d, E'    if not pg_try_advisory_xact_lock(hashtext(\'tkuniq_\' || new.user_id::text)) then   -- 그 회원의 다른 구매가 진행 중 — 기다리지 않고 busy\n      raise exception \'ROUND_MOVE_MEMBER_BUSY\' using errcode = \'55P03\';\n    end if;\n',
                  E'    perform pg_advisory_xact_lock(hashtext(\'tkuniq_\' || new.user_id::text));\n');
  execute d;
end $x$;
SQL
ok "  (되돌린 1차 판 모양)" "1|0" "$($P -c "select (prosrc like '%ROUND_MOVE_20261116%')::int||'|'||(prosrc like '%ROUND_MOVE_MEMBER_BUSY%')::int from pg_proc where proname='taam_guard_purchase_unique'")"
out=$($P -f $MIG 2>&1)
ok "  다시 RUN → 회원 잠금 try-lock · 덩어리 한 번 · ❌ 는 ③④ 둘" "1|1|2" "$($P -c "select (prosrc like '%ROUND_MOVE_MEMBER_BUSY%')::int||'|'||(length(prosrc)-length(replace(prosrc,'ROUND_MOVE_20261116','')))/length('ROUND_MOVE_20261116') from pg_proc where proname='taam_guard_purchase_unique'")|$(echo "$out" | grep -c '❌')"
ok "  좌석 날짜 고정 트리거는 중복 가드 뒤(zdate_pin) · 옛 이름 없음" "1|0" "$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_zdate_pin'")|$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_date_pin'")"

# ── 2차 검토(RM-1~6) — 새 회차들로 따로 본다(가드를 끄고 시드 · 회원 결제 행은 같은 회원·회차 하나씩)
seed2(){ $P <<SQL >/dev/null
set session_replication_role = replica;
delete from public.ticket_round_moves where round_id in ('RX','RP','RI','RK','RD','RT');
delete from public.guest_remind_log; delete from public._push_calls;
delete from public.notifications where type='ticket_date_changed';
delete from public.tickets where ticket_product_id in ('RX','RP','RI','RK','RD','RT');
delete from public.reservation_invites where ticket_product_id in ('RX','RP','RI','RK','RD','RT');
delete from public.kashikiri_charges where event_id in (select id from public.kashikiri_events where ticket_product_id in ('RX','RP','RI','RK','RD','RT')) or id in ('$C2X');
delete from public.kashikiri_teams where event_id in (select id from public.kashikiri_events where ticket_product_id in ('RX','RP','RI','RK','RD','RT'));
delete from public.kashikiri_events where ticket_product_id in ('RX','RP','RI','RK','RD','RT');
delete from public.purchase_rule_exceptions where ticket_product_id in ('RX','RP','RI','RK','RD','RT');
delete from public.ticket_products where id in ('RX','RP','RI','RK','RD','RT');
insert into public.ticket_products(id,rest_id,rest_name,date,time,status,total_pax) values
 ('RX','$RB','다른집','2027.06.10','18:00','active',20),('RP','$RB','다른집','2026.10.01','18:00','active',20),
 ('RI','$RB','다른집','2027.07.10','18:00','active',20),('RK','$RB','다른집','2027.08.10','18:00','active',20),
 ('RD','$RB','다른집','2027.09.10','18:00','active',20),('RT','$RB','다른집','2027.10.10','18:00','active',20);
insert into public.tickets(id,user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,buyer_name,buyer_phone,extra_data) values
 ('$X1','$M1','$RB','다른집','RX','2027.06.10','18:00',2,100,'active','PAYH-X1',null,null,'{}'),
 ('$X3','$M3','$RB','다른집','RI','2027.07.10','18:00',2,100,'active','INV-e3000000-1',null,null,'{"inviteId":"$IX3"}'),
 ('$XL','$SU','$RB','다른집','RD','2027.09.10','18:00',1,0,'active','LINK-d2000000-2','손님X','01055556666','{"chargeId":"$C2X","linkInvite":true}'),
 ('$XA1','$M6','$RB','다른집','RT','2027.10.10','18:00',2,100,'active','PAYH-XA1',null,null,'{}'),
 ('$XA2','$M7','$RB','다른집','RT','2027.10.10','18:00',2,100,'active','PAYH-XA2',null,null,'{}');
insert into public.reservation_invites(id,host_user_id,invitee_user_id,restaurant_id,restaurant_name,visit_date,visit_time,pax,status,ticket_product_id) values
 ('$IX2','$SU','$M2','$RB','다른집','2027.06.10','18:00',2,'sent','RX'),('$IX3','$SU','$M3','$RB','다른집','2027.07.10','18:00',2,'paid','RI');
insert into public.kashikiri_events(id,venue_id,venue_name,event_date,event_time,ticket_product_id,created_by) values
 ('$EP','$RB','다른집','2026-10-01','18:00','RP','$SU'),('$EK','$RB','다른집','2027-08-10','18:00','RK','$SU');
insert into public.kashikiri_teams(id,event_id,pax) values ('$CP','$EP',2),('$CK','$EK',2);
insert into public.kashikiri_charges(id,event_id,team_id,label,status,purpose,payer_name) values ('$CP','$EP','$CP','정산P','paid','custom','정산P'),('$CK','$EK','$CK','정산K','paid','custom','정산K');
insert into public.kashikiri_charges(id,label,status,purpose,subtitle,link_invite) values ('$C2X','손님X','paid','ticket','2027.09.10 18:00',true);
insert into public.guest_remind_log(ticket_id,d,result) values ('$XL',3,'sent'),('$XL',1,'sent');
set session_replication_role = origin;
select public._taam_ksk_seat_sync('$EP'); select public._taam_ksk_seat_sync('$EK');
SQL
}
X1=f2000000-0000-4000-8000-000000000001; X3=f2000000-0000-4000-8000-000000000003; XL=f2000000-0000-4000-8000-000000000004
XA1=f2000000-0000-4000-8000-000000000005; XA2=f2000000-0000-4000-8000-000000000006
IX2=e2000000-0000-4000-8000-000000000002; IX3=e3000000-0000-4000-8000-000000000003
EP=c2000000-0000-4000-8000-000000000001; EK=c2000000-0000-4000-8000-000000000002
CP=d2000000-0000-4000-8000-000000000001; CK=d2000000-0000-4000-8000-000000000002; C2X=d2000000-0000-4000-8000-000000000003
seed2

echo "── 12. 2차 RM-1 — 연도 실수(NEW_DATE_PAST)를 고치는 이동이 처음 날짜의 예약을 데려온다"
$P -c "update public.ticket_products set date='2026.06.24' where id='RX'" >/dev/null
ok "연도 실수 → NEW_DATE_PAST · 예약·초대 그대로" "NEW_DATE_PAST|2027.06.10|2027.06.10" "$($P -c "select errors->0->>'code' from public.ticket_round_moves where round_id='RX' order by id desc limit 1")|$(dt $X1 | cut -d' ' -f1)|$($P -c "select visit_date from public.reservation_invites where id='$IX2'")"
pv=$(su "select public.taam_round_move_preview('RX','2027.06.24',null)" | grep '^{')
ok "  고치는 미리보기: 처음 날짜의 예약·초대가 「옮김」 · 옛 날짜 지남 경고 없음" "move,move|0" "$($P -c "select string_agg(e->>'action',',' order by e->>'kind' desc) from jsonb_array_elements('$pv'::jsonb->'rows') e")|$($P -c "select count(*) from jsonb_array_elements_text('$pv'::jsonb->'warnings') w where w='old_date_past'")"
ok "  미리보기에 마지막 기록 번호" "$($P -c "select max(id) from public.ticket_round_moves where round_id='RX'")" "$($P -c "select '$pv'::jsonb->>'last_move_id'")"
o=$(su "update public.ticket_products set date='2027.06.24' where id='RX'"); ok "  앱이 직접 보낸 저장은 거절(남은 예약이 있다)" 1 "$(echo "$o" | grep -c ROUND_RESCHEDULE_REQUIRED)"
o=$(su "select public.taam_round_reschedule('RX','2027.06.24',null,'2026.06.24','18:00','{}')")
ok "  옮기기 RPC → 예약·초대 2027.06.24 · 기록의 from 은 처음 날짜" "2027.06.24|2027.06.24|2027.06.10" "$(dt $X1 | cut -d' ' -f1)|$($P -c "select visit_date from public.reservation_invites where id='$IX2'")|$($P -c "select e->'from'->>'d' from public.ticket_round_moves m, jsonb_array_elements(m.moved) e where m.round_id='RX' and m.id=(select max(id) from public.ticket_round_moves where round_id='RX') and e->>'kind'='ticket'")"
$P -c "update public.ticket_products set date='언젠가' where id='RX'" >/dev/null
$P -c "update public.ticket_products set date='2027.06.30' where id='RX'" >/dev/null
ok "  못 읽는 날짜(NEW_DATE_UNREADABLE) 뒤 SQL Editor 로 고침 → 따라온다" "2027.06.30|2027.06.30" "$(dt $X1 | cut -d' ' -f1)|$($P -c "select visit_date from public.reservation_invites where id='$IX2'")"

echo "── 13. 2차 RM-2 — 다시 맞추기는 따로 바꾼 시간을 지킨다"
su "select public.taam_round_reschedule('RT','2027.10.10','19:00','2027.10.10','18:00','{}')" >/dev/null
$P -c "update public.tickets set visit_time='18:00' where id='$XA2'" >/dev/null   # ⏰ 시간 변경 — 회원7 만 18:00 으로
($Q -c "begin; select 1 from public.tickets where id='$XA1' for update; select pg_sleep(3); commit;" >/dev/null 2>&1 &)
sleep 0.7
$P -c "update public.ticket_products set date='2027.10.17' where id='RT'" >/dev/null
ok "  트리거 이동: 잠긴 회원6 은 옛 날짜(busy) · 회원7 은 날짜만 옮기고 18:00 그대로" "2027.10.10 19:00|2027.10.17 18:00|busy" "$(dt $XA1)|$(dt $XA2)|$($P -c "select errors->0->>'code' from public.ticket_round_moves where round_id='RT' order by id desc limit 1")"
sleep 3
o=$(su "select public.taam_round_move_resync('RT')")
ok "  다시 맞추기 → 회원6 만 2027.10.17 19:00 · 회원7 은 18:00 그대로(종전엔 19:00 으로 되돌렸다)" "2027.10.17 19:00|2027.10.17 18:00|1" "$(dt $XA1)|$(dt $XA2)|$($P -c "select jsonb_array_length(moved) from public.ticket_round_moves where round_id='RT' order by id desc limit 1")"

echo "── 14. 2차 RM-3 — 이동 중(트리거 경로)에 들어온 홀드는 새 날짜로 · 같은 회원의 다른 구매와 교착 없음"
($Q -c "begin; update public.ticket_products set date='2027.06.07' where id='RX'; select pg_sleep(2.5); commit;" >/dev/null 2>&1 &)
sleep 0.7
o=$(as_uid $M4 "insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values ('$M4','$RB','다른집','RX','2027.06.30','18:00',2,0,'hold','PAYH-RX-M4','{}')")
sleep 2.3
ok "  이동 중 들어온 회원 홀드 → 기다렸다 새 날짜(2027.06.07) · 오류 없음" "2027.06.07|0" "$($P -c "select reservation_date from public.tickets where purchase_id='PAYH-RX-M4'")|$(echo "$o" | grep -c ERROR)"
$P -c "insert into public.purchase_rule_exceptions(user_id,ticket_product_id,allow_dup,allow_time,extra,expires_at,note) values ('$M1','RX',true,true,1,now()+interval '300 days','x')" >/dev/null
$P -c "create or replace function public._t_slow() returns trigger language plpgsql as \$\$ begin if new.purchase_id like 'PAYH-RX-M1b%' then perform pg_sleep(2); end if; return new; end \$\$; create trigger trg_taam_guard_ticket_v_slow before insert on public.tickets for each row execute function public._t_slow();" >/dev/null
RS=$(mktemp); ($Q -c "begin; set local taam.uid='$M1'; set local role authenticated; insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values ('$M1','$RB','다른집','RX','2027.06.07','18:00',2,0,'hold','PAYH-RX-M1b','{}'); commit;" > $RS 2>&1 &)
sleep 0.6
o=$($Q -c "begin; update public.ticket_products set date='2027.06.14' where id='RX'; select pg_sleep(2.5); commit;" 2>&1)
sleep 2.5
ok "  회원 잠금을 쥔 같은 회원의 구매 · 이동 — 교착 없음 · 이동은 회원1 행을 busy 로 남김 · 구매는 새 날짜" "0|0|busy|2027.06.14" "$(grep -c deadlock $RS)|$(echo "$o" | grep -c deadlock)|$($P -c "select e->>'code' from public.ticket_round_moves m, jsonb_array_elements(m.errors) e where m.round_id='RX' and m.id=(select max(id) from public.ticket_round_moves where round_id='RX') and e->>'pid'='PAYH-X1'")|$($P -c "select reservation_date from public.tickets where purchase_id='PAYH-RX-M1b'")"
rm -f $RS; $P -c "drop trigger trg_taam_guard_ticket_v_slow on public.tickets" >/dev/null
o=$(su "select public.taam_round_move_resync('RX')"); ok "  다시 맞추기로 회원1 도 새 날짜" "2027.06.14" "$(dt $X1 | cut -d' ' -f1)"

echo "── 15. 2차 RM-4 — 정산 좌석 동기화가 실패한 뒤 다시 맞추기가 좌석을 맞춘다"
$P -c "create or replace function public._t_boom() returns trigger language plpgsql as \$\$ begin if new.purchase_id like 'KSK-%' and current_setting('test.boom', true) = '1' then raise exception 'deadlock detected (simulated)' using errcode='40P01'; end if; return new; end \$\$; create trigger zz_t_boom before update on public.tickets for each row execute function public._t_boom();" >/dev/null
o=$($Q -c "begin; set local taam.uid='$SU'; set local role authenticated; set local test.boom='1'; select public.taam_round_reschedule('RK','2027.08.17',null,'2027.08.10','18:00','{}'); commit;" 2>&1)
ok "  옮기기: 정산 회차는 옮겨졌지만 좌석 동기화 실패(ksk_sync 오류) · 좌석은 옛 날짜" "2027-08-17|2027.08.10|ksk_sync" "$($P -c "select event_date from public.kashikiri_events where id='$EK'")|$($P -c "select reservation_date from public.tickets where purchase_id like 'KSK-%' and extra_data->>'eventId'='$EK' and status<>'cancelled'")|$($P -c "select errors->0->>'kind' from public.ticket_round_moves where round_id='RK' order by id desc limit 1")"
$P -c "drop trigger zz_t_boom on public.tickets" >/dev/null
o=$(su "select public.taam_round_move_resync('RK')")
ok "  다시 맞추기 → 좌석 2027.08.17 · 「이미 모두 옮겨져 있다」가 아니라 기록(정산 좌석 1)" "2027.08.17|0|1" "$($P -c "select reservation_date from public.tickets where purchase_id like 'KSK-%' and extra_data->>'eventId'='$EK' and status<>'cancelled'")|$(echo "$o" | grep -c '"move_id": null')|$($P -c "select jsonb_array_length(side->'ksk'->0->'seats') from public.ticket_round_moves where round_id='RK' order by id desc limit 1")"
o=$(su "select public.taam_round_move_resync('RK')"); ok "  한 번 더 → 옮길 것 없음(기록 없음)" 1 "$(echo "$o" | grep -c '"move_id": null')"

echo "── 16. 2차 RM-5 — 다시 맞추기로 옮긴 좌석의 부제·알림톡 기록 · 좌석이 남은 결제 초대에 알림"
($Q -c "begin; select 1 from public.tickets where id='$XL' for update; select pg_sleep(2.5); commit;" >/dev/null 2>&1 &)
sleep 0.6
$P -c "update public.ticket_products set date='2027.09.17' where id='RD'" >/dev/null
ok "  잠긴 비회원 링크 좌석 → busy · 부제·알림톡 기록 그대로" "2027.09.10|2027.09.10 18:00|2" "$(dt $XL | cut -d' ' -f1)|$($P -c "select subtitle from public.kashikiri_charges where id='$C2X'")|$($P -c "select count(*) from public.guest_remind_log where ticket_id='$XL'")"
sleep 2.4
o=$(su "select public.taam_round_move_resync('RD')")
ok "  다시 맞추기 → 좌석 2027.09.17 · 부제 2027.09.17 18:00 · 알림톡 기록 지움" "2027.09.17|2027.09.17 18:00|0" "$(dt $XL | cut -d' ' -f1)|$($P -c "select subtitle from public.kashikiri_charges where id='$C2X'")|$($P -c "select count(*) from public.guest_remind_log where ticket_id='$XL'")"
($Q -c "begin; select 1 from public.tickets where id='$X3' for update; select pg_sleep(2.5); commit;" >/dev/null 2>&1 &)
sleep 0.6
$P -c "update public.ticket_products set date='2027.07.17' where id='RI'" >/dev/null
RMID=$($P -c "select max(id) from public.ticket_round_moves where round_id='RI'")
ok "  결제된 초대는 옮기고 그 좌석(INV-)은 잠겨 남음" "invite|busy" "$($P -c "select string_agg(e->>'kind',',') from public.ticket_round_moves m, jsonb_array_elements(m.moved) e where m.id=$RMID")|$($P -c "select errors->0->>'code' from public.ticket_round_moves where id=$RMID")"
nr=$(su "select public.taam_round_move_notify($RMID)")
ok "  알림 → 회원3 에게 초대로 한 줄(구매 내역 링크) · 종전엔 0" "1|/?open_ticket_hist=1" "$($P -c "select count(*) from public.notifications where user_id='$M3' and type='ticket_date_changed'")|$($P -c "select max(url) from public.notifications where user_id='$M3' and type='ticket_date_changed'")"
sleep 2
o=$(su "select public.taam_round_move_resync('RI')")
RMID2=$($P -c "select max(id) from public.ticket_round_moves where round_id='RI'")
nr=$(su "select public.taam_round_move_notify($RMID2)")
ok "  다시 맞추기 기록도 알림을 보낼 수 있다(앱이 묻는다) — 좌석으로 한 줄 더" "resync|2" "$($P -c "select via from public.ticket_round_moves where id=$RMID2")|$($P -c "select count(*) from public.notifications where user_id='$M3' and type='ticket_date_changed'")"

echo "── 17. 2차 RM-6 — 지난 회차의 정산 좌석은 「옮길 예약」이 아니다"
pv=$(su "select public.taam_round_move_preview('RP','2026.10.02',null)" | grep '^{')
ok "  미리보기: 정산 회차·정산 좌석 둘 다 남김(past_round) · 「옮김/정산」 없음" "keep:past_round,keep:past_round|0" "$($P -c "select string_agg((e->>'action')||':'||(e->>'reason'),',') from jsonb_array_elements('$pv'::jsonb->'rows') e")|$($P -c "select count(*) from jsonb_array_elements('$pv'::jsonb->'rows') e where e->>'action' in ('move','event')")"
o=$(su "update public.ticket_products set date='2026.10.02' where id='RP'")
ok "  앱이 직접 보낸 저장으로 지난 회차 날짜를 고칠 수 있다(종전엔 ROUND_RESCHEDULE_REQUIRED · 옮기기 RPC 는 NEW_DATE_PAST — 어느 쪽도 안 됐다)" "0|2026.10.02" "$(echo "$o" | grep -c ERROR)|$($P -c "select date from public.ticket_products where id='RP'")"
o=$(su "update public.ticket_products set date='2027.08.24' where id='RK'"); ok "  앞으로 올 정산 회차의 좌석은 여전히 「옮길 예약」(직접 저장 거절)" 1 "$(echo "$o" | grep -c ROUND_RESCHEDULE_REQUIRED)"

echo "── 18. 리마인드 중복 방지에 방문일 (t_rda = 라이브 52d0603a · b42fdace 재현)"
if psql $H -d postgres -Atc "select 1 from pg_database where datname='t_rda'" | grep -q 1; then
  DB3=${DB}_rem; psql $H -d postgres -q -c "drop database if exists $DB3" >/dev/null 2>&1
  psql $H -d postgres -q -c "create database $DB3 template t_rda" >/dev/null
  P3="psql $H -d $DB3 -q -At"
  ok "리마인드 원문 md5" "52d0603ae3c0bd4482784b5799ca82c7|b42fdace23b67d970608cf8fa1cf98b0" "$($P3 -c "select md5(prosrc) from pg_proc where proname='taam_visit_reminder_notify'")|$($P3 -c "select md5(prosrc) from pg_proc where proname='_taam_vr_seat_status'")"
  # 7 절(리마인드 패치)만 떼어 돌린다 — t_rda 에는 이동 픽스처가 없다
  RM7=$(mktemp); awk '/^-- ── 7\. 리마인드/{p=1} /^-- ── 확인/{p=0} p{print}' $MIG > $RM7
  out=$($P3 -f $RM7 2>&1); rm -f $RM7; ok "패치 적용 오류 없음" 0 "$(echo "$out" | grep -c ERROR)"
  ok "두 함수에 표시" "1|1" "$($P3 -c "select count(*) from pg_proc where proname='taam_visit_reminder_notify' and prosrc like '%VR_DATEKEY_20261116%'")|$($P3 -c "select count(*) from pg_proc where proname='_taam_vr_seat_status' and prosrc like '%VR_DATEKEY_20261116%'")"
  U=$($P3 -c "select id from public.profiles where coalesce(role,'user') not in ('superadmin','super_admin','admin') order by id limit 1")
  [ -z "$U" ] && { U=a1000000-0000-4000-8000-000000000001; $P3 -c "insert into auth.users(id) values ('$U') on conflict do nothing; insert into public.profiles(id,role,display_name) values ('$U','user','리마인드회원') on conflict do nothing" >/dev/null 2>&1; }
  D3=$($P3 -c "select to_char((now() at time zone 'Asia/Seoul')::date + 3,'YYYY.MM.DD')")
  TK=$($P3 -c "insert into public.tickets(user_id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,status,purchase_id) values ('$U','r-x','리마인드집','$D3','18:00',2,'active','PAYH-rem-1') returning id" | head -1)
  # 옛 방문일(10일 뒤)로 이미 3일 전 알림이 갔다고 친다 — 날짜가 다르니 새 날짜의 3일 전은 다시 나가야 한다
  $P3 -c "insert into public.notifications(user_id,type,title,body,url,payload) values ('$U','visit_reminder','옛','옛','/',jsonb_build_object('ticket_id','$TK','days',3,'date',to_char((now() at time zone 'Asia/Seoul')::date + 10,'YYYY-MM-DD')))" >/dev/null
  $P3 -c "select public.taam_visit_reminder_notify()" >/dev/null 2>&1
  ok "옛 날짜로 보낸 3일 전 기록이 있어도 새 날짜의 3일 전은 나간다" 2 "$($P3 -c "select count(*) from public.notifications where type='visit_reminder' and payload->>'ticket_id'='$TK' and payload->>'days'='3'")"
  $P3 -c "select public.taam_visit_reminder_notify()" >/dev/null 2>&1
  ok "같은 날짜·일수로는 다시 안 나간다" 2 "$($P3 -c "select count(*) from public.notifications where type='visit_reminder' and payload->>'ticket_id'='$TK' and payload->>'days'='3'")"
  TK2=$($P3 -c "insert into public.tickets(user_id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,status,purchase_id) values ('$U','r-x','리마인드집','$D3','18:00',2,'active','PAYH-rem-2') returning id" | head -1)
  $P3 -c "insert into public.notifications(user_id,type,title,body,url,payload) values ('$U','visit_reminder','옛','옛','/',jsonb_build_object('ticket_id','$TK2','days',3))" >/dev/null
  $P3 -c "select public.taam_visit_reminder_notify()" >/dev/null 2>&1
  ok "날짜 없는 옛 기록은 종전처럼 막는다" 1 "$($P3 -c "select count(*) from public.notifications where type='visit_reminder' and payload->>'ticket_id'='$TK2' and payload->>'days'='3'")"
  TK3=$($P3 -c "insert into public.tickets(user_id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,status,purchase_id) values ('$U','r-x','리마인드집',to_char((now() at time zone 'Asia/Seoul')::date + 20,'YYYY.MM.DD'),'18:00',2,'active','PAYH-rem-3') returning id" | head -1)
  $P3 -c "insert into public.visit_reminder_push_log(notif_id,user_id,ticket_key,days,http,ok,at) values (gen_random_uuid(),'$U','$TK3',3,200,1,now())" >/dev/null 2>&1
  ok "발송 현황: 다른 날에 보낸 푸시 기록은 새 방문일의 3일 전 「보냄」이 아니다" "plan" "$($P3 -c "select e->>'st' from jsonb_array_elements(public._taam_vr_seat_status('$TK3')->'stages') e where e->>'d'='3'")"
  [ -z "$KEEP" ] && psql $H -d postgres -q -c "drop database if exists $DB3" >/dev/null 2>&1
else
  echo "⚠ t_rda 가 없다 — 먼저 KEEP=1 bash sql/_test/t_reminder_day_admin.sh"; FAIL=1
fi

[ -z "$KEEP" ] && psql $H -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
