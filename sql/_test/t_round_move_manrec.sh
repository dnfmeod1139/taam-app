#!/bin/bash
# 회차 날짜 이동(20261116_round_move_sync.sql) × 캘린더 수동 기록 좌석(20261117_manual_record_seats.sql) — 6차 재점검 반영 (2026-11-16)
# 먼저: 로컬 pg(/tmp 소켓). 실행: bash sql/_test/t_round_move_manrec.sh   (KEEP=1 이면 DB 를 남긴다 · TAAM_TEST_DB 로 DB 이름)
#   20261117 파일·픽스처(fx_manual_record_live_2026-11-16)가 이 브랜치에 없으면 건너뛴다 — TAAM_MR_ROOT 로 그 둘이 있는 checkout(예: manrec-srv 워크트리)을 지정한다.
#   TAAM_RM_ORDER=after 면 이동 파일을 20261117 **뒤에** 올린다. TAAM_TEST_MIG 로 이동 파일을 바꿀 수 있다(고치기 전 판을 돌려 ❌ 를 보는 용도).
#   본 것:
#     RV-SRV-1 좌석 행이 없는(또는 취소 행뿐인) 회차 — 옛 날짜의 기록만으로 자동 매진이면 날짜를 옮길 때 서버가 다시 세어 푼다(미리보기 reopen.stay 와 같게)
#              · 끔이면 skipped:MUTED · 기록도 옮기면 매진 그대로 · 손 잠금은 그대로 · 직접 저장 · 파트너 승인(정의자 함수) 경로도 · 시간만 바꾸면 그대로
#     RV-SRV-2 이동이 기록 줄을 처음 잠근 뒤 그 날짜에 커밋된 새 기록을 다른 세션이 고쳐도 교착(40P01) 없이 옮겨 간다(3번)
#   7차 (2026-11-16 재점검 반영):
#     RV2-SRV-1 그 늦은 기록을 다른 세션이 두 번째 잠금 **전에** 잡으면(이동이 새 날짜 열쇠를 기다리는 사이) 교착 대신 바로 ROUND_MOVE_BUSY(55P03) ·
#              기록 쪽은 warning 없이 저장 · 다시 옮기면 된다(2b — pg_locks 로 순서를 맞춘 결정적 재현 · 6차 판에서 ❌)
#     RV2-APP-3 날짜와 정원을 같이 바꾸면 한 문장(ROUND_MOVE_CAP) — 정원을 줄여 끝이 매진이면 취소표 없음 · 늘리면 이동 커밋에서 pending · 끔이면 MUTED (3)
cd "$(dirname "$0")/../.."
RMF=${TAAM_TEST_MIG:-supabase/migrations/20261116_round_move_sync.sql}; FX2=sql/_test/fx_round_move_live_2026-11-16
MR=${TAAM_MR_ROOT:-.}; MIG=$MR/supabase/migrations/20261117_manual_record_seats.sql; FX3=$MR/sql/_test/fx_manual_record_live_2026-11-16
if [ ! -f "$MIG" ] || [ ! -d "$FX3" ]; then
  echo "── 건너뜀: 20261117_manual_record_seats.sql($MIG) 또는 픽스처($FX3)가 없다 — TAAM_MR_ROOT 로 그 파일이 있는 checkout 을 지정"; exit 0
fi
FX=sql/_test/fx_repurchase_live_2026-11-15
H="-h /tmp -U postgres"; DB=${TAAM_TEST_DB:-t_rmove_manrec}
psql $H -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql $H -d postgres -q -c "create database $DB" >/dev/null
P="psql $H -d $DB -q -At -v ON_ERROR_STOP=1"; Q="psql $H -d $DB -q -At"
for f in $FX/fixture.sql $FX2/fixture_extra.sql $FX/fns.sql $FX2/fns_extra.sql $FX2/ksk_sync.sql $FX/triggers.sql $FX2/triggers_extra.sql; do
  $P -f $f >/dev/null || { echo "FIXTURE FAIL $f"; exit 1; }
done
$P <<'SQL' >/dev/null
alter table public.ticket_products add column if not exists sale_state text, add column if not exists min_tier text default '',
  add column if not exists meal_fee int, add column if not exists agency_fee int, add column if not exists wine_min int;
alter table public.profiles add column if not exists membership_tier text, add column if not exists deleted_at timestamptz;
create table if not exists public.admin_grants(user_id uuid, rest_id text, venue_id text, status text default 'pending');
create table if not exists public.app_config(key text primary key, value jsonb, updated_at timestamptz default now());
alter table public.kashikiri_events add column if not exists escort boolean, add column if not exists fx_rate numeric, add column if not exists fx_usd numeric, add column if not exists memo text;
alter table public.kashikiri_teams add column if not exists host_label text;
alter table public.kashikiri_charges add column if not exists amount_jpy int, add column if not exists token text, add column if not exists pay_fx numeric,
 add column if not exists expires_at timestamptz, add column if not exists payment_key text;
SQL
$P -f supabase/migrations/20261115_repurchase_guard_v2.sql >/dev/null || { echo "V2 FAIL"; exit 1; }
FAIL=0; TMPA=$(mktemp); TMPB=$(mktemp)
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
rm_apply(){ ROUT=$(psql $H -d $DB -At -v ON_ERROR_STOP=1 -f "$RMF" 2>&1) || { echo "RM FAIL"; echo "$ROUT" | grep ERROR | head -3; exit 1; }; }
mr_apply(){ $P -c "drop function if exists public.taam_rest_admin_ok(text) cascade" >/dev/null; $P -f $FX3/fns.sql >/dev/null || { echo "FNS3 FAIL"; exit 1; }
  $P -f supabase/migrations/20260929_ticket_restock.sql >/dev/null 2>&1; $P -f supabase/migrations/20261113_restock_mute.sql >/dev/null 2>&1
  $P -f $FX3/fns.sql >/dev/null; $P -f $FX3/triggers.sql >/dev/null 2>&1
  MOUT=$(psql $H -d $DB -At -v ON_ERROR_STOP=1 --single-transaction -f $MIG 2>&1); }
if [ "${TAAM_RM_ORDER:-before}" = after ]; then mr_apply; rm_apply; else rm_apply; mr_apply; fi
echo "── 0. 마이그레이션 (이동 파일 ${TAAM_RM_ORDER:-before} 20261117)"
ok "20261117 오류 0 · ❌ 0" "0|0" "$(echo "$MOUT" | grep -c 'ERROR')|$(echo "$MOUT" | grep -c '❌')"
ok "이동 파일 확인 표 ⑪(ROUND_MOVE_RECOUNT · MANREC_RELOCK) ✅" "✅" "$(echo "$ROUT" | grep '^⑪' | awk -F'|' '{print $NF}')"

SU=a0000000-0000-4000-8000-0000000000ff; M1=a0000000-0000-4000-8000-000000000001
RA=b0000000-0000-4000-8000-00000000000a; T1=f0000000-0000-4000-8000-000000000001; DM=d0000000-0000-4000-8000-000000000001
YID=d0000000-0000-4000-8000-0000000000a9
# seed <정원> <auto_soldout> <좌석 행: none|cancelled|live> [회차 상태]
seed(){ $P <<SQL >/dev/null
set session_replication_role = replica;
delete from public.ticket_restock_events; delete from public.ticket_restock_mutes; delete from public.daegwan_manual; delete from public.tickets;
delete from public.ticket_products; delete from public.ticket_round_moves; delete from public.restaurants; delete from public.profiles; delete from auth.users;
insert into auth.users values ('$SU'),('$M1');
insert into public.profiles(id, role, display_name, membership_tier) values ('$SU','superadmin','슈퍼','M'),('$M1','user','회원1','M');
insert into public.restaurants(id, name, repurchase_day) values ('$RA','미토우',0);
insert into public.ticket_products(id, rest_id, rest_name, date, time, status, total_pax, auto_soldout) values
 ('R1','$RA','미토우','2027.03.10','18:00','${4:-soldout}',$1,$2);
insert into public.tickets(id, user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, party_size, price, status, purchase_id)
 select '$T1','$M1','$RA','미토우','R1','2027.03.10','18:00',2,0, case when '$3' = 'cancelled' then 'cancelled' else 'active' end,'PAYH-r1a' where '$3' <> 'none';
insert into public.daegwan_manual(id, venue_id, ymd, name, pax) values ('$DM','$RA','2027-03-10','오프라인',2);
SQL
}
st(){ $P -c "select date||'|'||status||'|'||auto_soldout::text||'|'||public.taam_ticket_sold_pax('R1') from public.ticket_products where id='R1'"; }
ev(){ $P -c "select coalesce(string_agg(status||coalesce(':'||reason,''), ',' order by id), '-') from public.ticket_restock_events where ticket_product_id='R1'"; }
rec(){ $P -c "select ymd||'|'||pax from public.daegwan_manual where id='$DM'"; }
pv(){ $Q -c "begin read only; set local taam.uid='$SU'; set local role authenticated; select (j->'reopen'->>'stay')||'|'||(j->'seats'->>'after_stay')||'|'||jsonb_array_length(j->'rows')||'|'||(j->>'manual_movable') from (select public.taam_round_move_preview('R1','2027.03.17',null) j) x; commit;" 2>&1 | grep -v '^$' | head -1; }
resched(){ $Q -c "begin; set local taam.uid='$SU'; set local role authenticated; select 'A:'||coalesce(j->>'ok','null')||'|'||coalesce(j->'round'->>'status','-') from (select public.taam_round_reschedule('R1','${2:-2027.03.17}',${3:-null},'2027.03.10','18:00','$1') j) x; commit;" 2>&1 | grep -E '^A:|ERROR' | head -1; }

echo "── 1. RV-SRV-1 — 좌석 행이 없는 회차(옛 날짜의 기록만으로 자동 매진)를 옮기면 서버가 다시 센다(미리보기 reopen.stay 와 같게)"
for SEATS in none cancelled; do
  seed 2 true $SEATS
  ok "좌석 행 $SEATS · 미리보기: stay 풀림 · 옮긴 뒤 점유 0 · 옮길 예약 0건 · 기록 옮길 수 있음" "true|0|0|true" "$(pv)"
  o=$(resched '{}')
  ok "좌석 행 $SEATS · 날짜 바꾸기 → 응답 active · 회차 2027.03.17 판매중(자동) 점유 0 · 취소표 pending · 기록은 옛 날짜" \
     "A:true|active|2027.03.17|active|true|0|pending|2027-03-10|2" "$o|$(st)|$(ev)|$(rec)"
done
seed 2 true none
o=$($Q -c "begin; set local taam.uid='$SU'; set local role authenticated; select public.taam_restock_mute(array['R1'], 5, '회차 이동'); commit;" 2>&1 >/dev/null)
o=$(resched '{}')
ok "슈퍼어드민이 끄고 옮김 → 판매중 · skipped:MUTED" "A:true|active|2027.03.17|active|true|0|skipped:MUTED" "$o|$(st)|$(ev)"
seed 2 true none
o=$(resched '{"move_manual":true}')
ok "기록도 옮김 → 새 날짜에서도 꽉 참 · 매진 그대로 · 기록 2027-03-17 · 취소표 없음" "A:true|soldout|2027.03.17|soldout|true|2|2027-03-17|2|-" "$o|$(st)|$(rec)|$(ev)"
seed 2 false none
o=$(resched '{}')
ok "손으로 잠근 매진(auto_soldout=false) → 그대로 매진 · 취소표 없음" "A:true|soldout|2027.03.17|soldout|false|0|-" "$o|$(st)|$(ev)"
seed 2 true none hidden
o=$(resched '{}')
ok "숨김 회차 → 그대로 숨김 · 취소표 없음" "A:true|hidden|2027.03.17|hidden|true|0|-" "$o|$(st)|$(ev)"
seed 2 true none
o=$($Q -c "begin; set local taam.uid='$SU'; set local role authenticated; update public.ticket_products set date='2027.03.17', status='soldout', updated_at=now() where id='R1'; commit;" 2>&1 | grep -c ERROR)
ok "직접 저장(앱의 옛 pass() 길 · status 'soldout' 을 같이 보냄) → 판매중 · 취소표 pending" "0|2027.03.17|active|true|0|pending" "$o|$(st)|$(ev)"
seed 2 true none
$P -c "create or replace function public._t_approve_date(p_id text, p_date text) returns void language plpgsql security definer set search_path = public as \$f\$
       begin update public.ticket_products set date = p_date, updated_at = now() where id = p_id; end \$f\$;" >/dev/null
o=$($Q -c "begin; set local taam.uid='$SU'; set local role authenticated; select public._t_approve_date('R1','2027.03.17'); commit;" 2>&1 | grep -c ERROR)
ok "파트너 수정 승인 모양(정의자 함수가 날짜만 바꿈) → 판매중 · 취소표 pending" "0|2027.03.17|active|true|0|pending" "$o|$(st)|$(ev)"
seed 2 true none
o=$(resched '{}' 2027.03.10 "'19:00'")
ok "시간만 바꿈(같은 날 — 기록이 그대로 세임) → 매진 그대로 · 취소표 없음" "A:true|soldout|2027.03.10|soldout|true|2|-" "$o|$(st)|$(ev)"
seed 4 true live
$P -c "set session_replication_role = replica; update public.ticket_products set status='soldout', auto_soldout=true where id='R1'" >/dev/null
o=$(resched '{}')
ok "대조 — 살아 있는 좌석 행 2 + 기록 2(4/4) → 옮기면 2/4 판매중 · pending(종전 길 그대로)" "A:true|active|2027.03.17|active|true|2|pending" "$o|$(st)|$(ev)"

echo "── 2. RV-SRV-2 — 기록 줄을 처음 잠근 뒤 그 날짜에 커밋된 새 기록을 다른 세션이 고쳐도 교착 없이 옮긴다"
for RUN in 1 2 3; do
  seed 4 true live
  ( $Q -c "begin; insert into public.daegwan_manual(id, venue_id, ymd, name, pax) values ('$YID','$RA','2027-03-10','새기록',1); select pg_sleep(1.0); commit;" >/dev/null 2>&1 ) &
  B1=$!; sleep 0.1
  ( $Q -c "begin; select 1 from public.tickets where id='$T1' for update; select pg_sleep(3.5); commit;" >/dev/null 2>&1 ) &
  BC=$!; sleep 0.2
  ( resched '{"move_manual":true}' > $TMPA ) &
  BR=$!; sleep 1.2
  ( $Q -c "begin; update public.daegwan_manual set pax = 2 where id='$YID'; commit;" > $TMPB 2>&1 ) &
  B2=$!
  wait $B1 $BC $BR $B2
  ok "엇갈림 $RUN — 이동 ok · 교착 없음(이동·기록 수정 둘 다) · 기록 둘 다 2027-03-17 · 새 기록 2명 · 회차 매진 그대로 · 이동 기록 1" \
     "A:true|soldout|0|0|2027-03-17x2,2027-03-17x2|2027.03.17|soldout|1" \
     "$(cat $TMPA)|$(grep -c -E '40P01|deadlock' $TMPB)|$($P -c "select count(*) from public.ticket_round_moves where errors::text like '%40P01%'")|$($P -c "select string_agg(ymd||'x'||pax, ',' order by name) from public.daegwan_manual")|$($P -c "select date||'|'||status from public.ticket_products where id='R1'")|$($P -c "select count(*) from public.ticket_round_moves")"
done

echo "── 2b. 7차 RV2-SRV-1 — 늦게 커밋된 기록을 다른 세션이 두 번째 잠금 **전에** 잡으면(이동이 새 날짜 열쇠를 기다리는 사이) 교착 대신 바로 ROUND_MOVE_BUSY"
#   순서는 sleep 이 아니라 pg_locks 로 맞춘다(결정적). 문지기 두 세션이 A·C 의 커밋을 쥔다.
#   C = 새 날짜(03-17)에 실제 기록을 넣는 거래(트리거가 03-17 열쇠를 쥔다) · A = 옛 날짜(03-10)에 기록 Y · R = 기록도 옮기는 날짜 바꾸기
#   B = Y 를 고치는/지우는 세션(줄 잠금 → R 이 쥔 옛 날짜 열쇠를 기다림). 6차 판: C 를 놓으면 R 의 두 번째 스캔이 Y 를 기다려 교착(40P01) —
#   R 이 지면 이동 전체 실패, B 가 지면 기록이 정원 잠금 없이 warning 으로 저장. 이제 R 은 기다리지 않고 바로 55P03 · B 는 정상 저장.
ZID=d0000000-0000-4000-8000-0000000000c3
LO(){ $P -c "select ($1::bigint & 4294967295)"; }
KOLD=$($P -c "select public._taam_manrec_daykey('$RA','2027-03-10')"); KNEW=$($P -c "select public._taam_manrec_daykey('$RA','2027-03-17')")
LOLD=$(LO $KOLD); LNEW=$(LO $KNEW)
ok "2b 전제: 옛 날짜 열쇠 < 새 날짜 열쇠(이동이 옛 → 새 순으로 잡는다)" "t" "$($P -c "select ($KOLD::bigint < $KNEW::bigint)::text" | cut -c1)"
wadv(){ $P -c "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid where a.application_name = '$1' and not l.granted and l.locktype = 'advisory' and l.objid::bigint = $2"; }
poll(){ for i in $(seq 1 200); do [ "$(eval "$1")" = "$2" ] && return 0; sleep 0.05; done; echo "   (시간 초과: $1)"; return 1; }
term(){ $P -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name = '$1'" >/dev/null; }
for CASE in "del 1.6" "pax 0.2" "pax 1.6"; do
  BMODE=${CASE% *}; DLY=${CASE#* }
  seed 4 true live
  OUTD=$(mktemp -d)
  ( PGAPPNAME=r7k1 $Q -c "begin; select pg_advisory_xact_lock(77001); select pg_sleep(60); commit;" >/dev/null 2>&1 ) &
  ( PGAPPNAME=r7k2 $Q -c "begin; select pg_advisory_xact_lock(77002); select pg_sleep(60); commit;" >/dev/null 2>&1 ) &
  poll "$P -c \"select count(*) from pg_stat_activity where application_name in ('r7k1','r7k2') and wait_event = 'PgSleep'\"" 2
  ( PGAPPNAME=r7c $Q -c "begin; insert into public.daegwan_manual(id, venue_id, ymd, name, pax) values ('$ZID','$RA','2027-03-17','새날기록',1); select pg_advisory_xact_lock(77002); commit;" > $OUTD/c 2>&1 ) & BC=$!
  ( PGAPPNAME=r7a $Q -c "begin; insert into public.daegwan_manual(id, venue_id, ymd, name, pax) values ('$YID','$RA','2027-03-10','새기록',1); select pg_advisory_xact_lock(77001); commit;" > $OUTD/a 2>&1 ) & BA=$!
  poll "wadv r7c 77002" 1; poll "wadv r7a 77001" 1
  ( PGAPPNAME=r7r $Q -v VERBOSITY=verbose -c "begin; set local taam.uid='$SU'; set local role authenticated; select 'R:'||((public.taam_round_reschedule('R1','2027.03.17',null,'2027.03.10','18:00','{\"move_manual\":true}'))->>'ok'); commit;" > $OUTD/r 2>&1; date +%s%N > $OUTD/rt ) & BR=$!
  poll "wadv r7r $LOLD" 1
  term r7k1                                  # A 커밋 → Y 가 보인다 · R 은 옛 날짜 열쇠를 얻고 새 날짜 열쇠(C)를 기다린다
  poll "wadv r7r $LNEW" 1
  if [ "$BMODE" = del ]; then BSQL="delete from public.daegwan_manual where id='$YID'"; else BSQL="update public.daegwan_manual set pax = 2 where id='$YID'"; fi
  ( PGAPPNAME=r7b $Q -c "begin; $BSQL; commit;" > $OUTD/b 2>&1 ) & BB=$!
  poll "wadv r7b $LOLD" 1                     # B 가 Y 줄을 잠그고 옛 날짜 열쇠(R)를 기다린다
  sleep $DLY
  date +%s%N > $OUTD/ct; term r7k2           # C 커밋 → R 이 새 날짜 열쇠를 얻고 두 번째 기록 줄 잠금(Y — B 가 쥠)
  wait $BC $BA $BR $BB
  rms=$(( ($(cat $OUTD/rt) - $(cat $OUTD/ct)) / 1000000 ))
  if [ "$BMODE" = del ]; then YEXP="-"; else YEXP="2027-03-10x2"; fi
  ok "2b B=$BMODE · C 를 ${DLY}초 뒤 놓음 → R 은 바로 ROUND_MOVE_BUSY(55P03 · ${rms}ms) · 교착 없음(R·B) · B 의 warning 없음 · B 저장됨 · 회차 그대로 · 이동 기록 0" \
     "1|1|0|0|$YEXP|2027.03.10|soldout|0" \
     "$(grep -c '55P03: ROUND_MOVE_BUSY' $OUTD/r)|$([ $rms -lt 900 ] && echo 1 || echo "느림${rms}ms")|$(cat $OUTD/r $OUTD/b | grep -c -E 'deadlock|40P01')|$(grep -c WARNING $OUTD/b)|$($P -c "select coalesce(max(ymd||'x'||pax),'-') from public.daegwan_manual where id='$YID'")|$($P -c "select date||'|'||status from public.ticket_products where id='R1'")|$($P -c "select count(*) from public.ticket_round_moves")"
  rm -rf $OUTD
done
# 바로 다시 옮기면(아무도 그 줄을 안 쥠) 된다 — 이 거절은 다시 시도할 수 있는 것
o=$(resched '{"move_manual":true}')
ok "2b 잠시 뒤 다시 옮기면 된다 — 이동 ok · 기록 셋 다 2027-03-17" "A:true|soldout|3" "$o|$($P -c "select count(*) from public.daegwan_manual where ymd='2027-03-17' and id in ('$DM','$YID','$ZID')")"

echo "── 3. 7차 RV2-APP-3 · ROUND_MOVE_CAP — 날짜를 옮기며 정원도 바꾸면 한 문장(옛 정원으로 잠깐 풀려 취소표가 나가지 않게)"
# capseed <좌석 행 none|live> <옛 날짜 기록> <새 날짜 기록> — R1 정원 4 · 자동 매진(4/4) · 옛 날짜에 점심 회차 R0(그날 기록은 못 옮김)
capseed(){ seed 4 true $1
  $P <<SQL >/dev/null
set session_replication_role = replica;
update public.daegwan_manual set pax = $2 where id = '$DM';
insert into public.daegwan_manual(venue_id, ymd, name, pax) select '$RA','2027-03-17','새날오프라인',$3 where $3 > 0;
insert into public.ticket_products(id, rest_id, rest_name, date, time, status, total_pax, auto_soldout) values ('R0','$RA','미토우','2027.03.10','12:00','active',8,true);
SQL
}
# 앱이 이어서 저장하는 나머지 칸(정원 · 응답의 status) — 앱 저장과 같은 모양
follow(){ $Q -c "begin; set local taam.uid='$SU'; set local role authenticated; update public.ticket_products set total_pax = $1, status = '$2', updated_at = now() where id='R1'; commit;" 2>&1 | grep -c ERROR; }
capres(){ $Q -c "begin; set local taam.uid='$SU'; set local role authenticated; select 'A:'||coalesce(j->>'ok','null')||'|'||coalesce(j->'round'->>'status','-')||'|'||coalesce(j->'round'->>'total_pax','-') from (select public.taam_round_reschedule('R1','2027.03.17',null,'2027.03.10','18:00','$1') j) x; commit;" 2>&1 | grep -E '^A:|ERROR' | head -1; }
capseed none 4 2
ok "3 전제(검토 capdn2 모양): 옛 날짜 기록 4 → 4/4 매진 · 새 날짜 기록 2 · 그날 점심 회차라 기록은 못 옮김 · 미리보기 stay 풀림(옛 정원 4)" "true|2|false|2027.03.10|soldout|true|4" "$(pv | awk -F'|' '{print $1"|"$2"|"$4}')|$(st)"
o=$(capres '{"total_pax":2}'); f=$(follow 2 soldout)
ok "3 정원 4→2 + 날짜 → 응답 soldout · 정원 2 · 끝까지 2/2 매진 · 취소표 없음(종전: 날짜만 먼저 커밋 → 2/4 판매중 · pending 뒤 다시 매진)" \
   "A:true|soldout|2|0|2027.03.17|soldout|true|2|2|-" "$o|$f|$(st)|$($P -c "select total_pax from public.ticket_products where id='R1'")|$(ev)"
capseed live 2 0
o=$(capres '{"total_pax":2}'); f=$(follow 2 soldout)
ok "3 예약 있는 회차(좌석 행 2 + 옛 날짜 기록 2) · 정원 4→2 + 날짜(기록 안 옮김) → soldout · 취소표 없음" "A:true|soldout|2|0|2027.03.17|soldout|true|2|-" "$o|$f|$(st)|$(ev)"
capseed none 4 2
o=$(capres '{"total_pax":3}'); f=$(follow 3 active)
ok "3 정원 4→3 · 새 날짜 2/3 → 정말 풀림 → active · 취소표 pending(그 자리는 있다)" "A:true|active|3|0|2027.03.17|active|true|2|pending" "$o|$f|$(st)|$(ev)"
capseed none 4 2
o=$(capres '{"total_pax":6}'); f=$(follow 6 active)
ok "3 정원 4→6 + 날짜 → active · 정원 6 · 취소표 pending 하나(이동 커밋에서)" "A:true|active|6|0|2027.03.17|active|true|2|pending" "$o|$f|$(st)|$(ev)"
capseed none 4 2
$Q -c "begin; set local taam.uid='$SU'; set local role authenticated; select public.taam_restock_mute(array['R1'], 5, '회차 이동'); commit;" >/dev/null 2>&1
o=$(capres '{"total_pax":6}')
ok "3 정원 4→6 · 끄고 옮김 → active · skipped:MUTED" "A:true|active|6|skipped:MUTED" "$o|$(ev)"
capseed none 4 2
o=$(capres '{"total_pax":"2"}')
ok "3 정원이 숫자가 아니면 BAD_TOTAL_PAX · 아무것도 안 바뀜" "A:false|-|-|2027.03.10|soldout|true|4|-" "$o|$(st)|$(ev)"

rm -f "$TMPA" "$TMPB"
[ -z "$KEEP" ] && psql $H -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
