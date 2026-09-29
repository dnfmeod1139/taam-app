#!/bin/bash
# 취소표 알림 회귀 — 2026-09-29. 먼저: 로컬 pg. 실행: bash sql/_test/t_restock.sh
#   실제 sync_ticket_soldout v4 · taam_seat_fillable · taam_visit_date 를 올리고, 전이 트리거가 커밋 시점에만 판단하는지,
#   수신자 필터(등급·설정·탈퇴·보유자·슈퍼어드민)가 맞는지, 쿨다운·만석 토글·한 트랜잭션 왕복·지난 날짜·flex 미충족을 거르는지 본다.
cd "$(dirname "$0")/../.."
DB=t_restock; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; M1=a1000000-0000-4000-8000-000000000011; M2=a1000000-0000-4000-8000-000000000012
T1=a1000000-0000-4000-8000-000000000013; A1=a1000000-0000-4000-8000-000000000014; D1=a1000000-0000-4000-8000-000000000015
OFF=a1000000-0000-4000-8000-000000000016; HOLD=a1000000-0000-4000-8000-000000000017
REST=b1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create table public.profiles(id uuid primary key, role text, membership_tier text, notif_prefs jsonb not null default '{}'::jsonb, deleted_at timestamptz, display_name text);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, total_pax int, slots jsonb, status text default 'active',
  min_tier text default '', sale_state text, sale_open_at text, auto_soldout boolean not null default true);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, ticket_product_id text, party_size int, status text, purchase_id text, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, seen boolean default false, created_at timestamptz default now());
create table public.app_config(key text primary key, value jsonb, updated_at timestamptz default now());
create or replace function public.taam_ticket_visible(p text, u uuid) returns boolean language sql stable as \$\$ select true \$\$;
create or replace function public.taam_tier_rank(p text) returns int language sql immutable as \$\$ select case upper(coalesce(p,'')) when 'M' then 3 when 'T' then 2 when 'A' then 1 else 0 end \$\$;
create or replace function public.taam_tier_is_open(p text) returns boolean language sql immutable as \$\$ select upper(coalesce(p,'')) = 'A' \$\$;
create or replace function public.taam_user_tier(p uuid) returns text language sql stable as \$\$ select membership_tier from public.profiles where id = p \$\$;
insert into auth.users values ('$SU'),('$M1'),('$M2'),('$T1'),('$A1'),('$D1'),('$OFF'),('$HOLD');
insert into public.profiles(id, role, membership_tier, notif_prefs, deleted_at, display_name) values
  ('$SU','super_admin','M','{}',null,'슈퍼'), ('$M1','member','M','{}',null,'M회원1'), ('$M2','member','M','{"remind7":true}',null,'M회원2'),
  ('$T1','member','T','{}',null,'T회원'), ('$A1','member','A','{}',null,'게스트'), ('$D1','member','M','{}',now(),'탈퇴'),
  ('$OFF','member','M','{"restock":false}',null,'끈회원'), ('$HOLD','member','M','{}',null,'보유자');
SQL
# 실제 헬퍼: taam_visit_date · taam_seat_fillable · sync_ticket_soldout v4
S0=$(grep -n "create or replace function public.taam_visit_date" sql/visit_reminder.sql | cut -d: -f1); E0=$(grep -n "create or replace function public.taam_visit_reminder_notify" sql/visit_reminder.sql | cut -d: -f1)
sed -n "${S0},$((E0-1))p" sql/visit_reminder.sql | $P >/dev/null 2>&1
S1=$(grep -n "create or replace function public.taam_seat_fillable" sql/ticket_capacity_guard.sql | cut -d: -f1); E1=$(awk -v s=$S1 'NR>s && /^\$\$;/ {print NR; exit}' sql/ticket_capacity_guard.sql)
sed -n "${S1},${E1}p" sql/ticket_capacity_guard.sql | $P >/dev/null 2>&1
S2=$(grep -n "create or replace function public.sync_ticket_soldout" sql/seat_hold_repair.sql | cut -d: -f1); E2=$(grep -n "execute function public.sync_ticket_soldout();" sql/seat_hold_repair.sql | cut -d: -f1)
sed -n "${S2},${E2}p" sql/seat_hold_repair.sql | $P >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "픽스처: sync v4 · fillable · visit_date 올라감" "3" "$($P -c "select count(*) from pg_proc where proname in ('sync_ticket_soldout','taam_seat_fillable','taam_visit_date')")"
out=$($P -f supabase/migrations/20260929_ticket_restock.sql 2>&1)
ok "마이그레이션 오류 없음 · ✅ 6 · ⚠ 1(설정 없음) · ❌ 0" "|6|1|0" "$(echo "$out" | grep -E "^ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '⚠')|$(echo "$out" | grep -c '❌')"

FUT=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 30, 'YYYY.MM.DD')")
PAST=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date - 1, 'YYYY.MM.DD')")
$P <<SQL >/dev/null
insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status,min_tier) values ('tp1','$REST','타키야','$FUT','20:30',4,'active','M');
insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$HOLD','tp1',2,'active','PAY-h1'),('$M2','tp1',2,'active','PAY-m2');
SQL
ok "① 만석이 되면 sync v4 가 soldout 으로" "soldout" "$($P -c "select status from public.ticket_products where id='tp1'")"

echo "── ② 회원 취소 → active → 커밋 시 이벤트"
$P -c "update public.tickets set status='cancelled' where purchase_id='PAY-m2'" >/dev/null
ok "status active · pending 이벤트 1 · 잔여 2" "active|1|2" "$($P -c "select status from public.ticket_products where id='tp1'")|$($P -c "select count(*) from public.ticket_restock_events where status='pending'")|$($P -c "select seats_left from public.ticket_restock_events order by id desc limit 1")"

echo "── ③ 처리: 수신자 = 살 수 있는 회원 + 슈퍼어드민"
r=$($P -c "select (public.taam_ticket_restock_process())::text" 2>&1)
ok "events 1 · 오류 없음" "1|" "$(echo "$r" | grep -c '"events": 1')|$(echo "$r" | grep -E '^ERROR')"
ok "알림 3건: M회원1 · M회원2(취소했으니 다시 살 수 있다) · 슈퍼 — T·게스트·탈퇴·끈회원·보유자는 제외" "3|1|1|1|0|0|0|0|0" "$($P -c "select count(*) from public.notifications where type='ticket_restock'")|$($P -c "select count(*) from public.notifications where user_id='$M1'")|$($P -c "select count(*) from public.notifications where user_id='$M2'")|$($P -c "select count(*) from public.notifications where user_id='$SU'")|$($P -c "select count(*) from public.notifications where user_id='$T1'")|$($P -c "select count(*) from public.notifications where user_id='$A1'")|$($P -c "select count(*) from public.notifications where user_id='$D1'")|$($P -c "select count(*) from public.notifications where user_id='$OFF'")|$($P -c "select count(*) from public.notifications where user_id='$HOLD'")"
ok "문구: 🎫 취소표가 나왔습니다 / 타키야 · 날짜 20:30 · 잔여 2석 · url ?ticket=tp1" "1|1" "$($P -c "select count(*) from public.notifications where title='🎫 취소표가 나왔습니다' and body like '타키야 · $FUT 20:30 · 잔여 2석%' and url='/?ticket=tp1' and user_id='$M1'")|$(echo "$r" | grep -c '"member_ids"')"
ok "이벤트 sent · made 3" "sent|3" "$($P -c "select status||'|'||made from public.ticket_restock_events order by id desc limit 1")"

echo "── ④ 쿨다운: 60분 안에 같은 회차가 또 풀려도 이벤트 없음"
$P -c "insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','tp1',2,'active','PAY-fill')" >/dev/null
ok "다시 만석 → soldout" "soldout" "$($P -c "select status from public.ticket_products where id='tp1'")"
$P -c "update public.tickets set status='cancelled' where purchase_id='PAY-fill'" >/dev/null
ok "풀렸지만 이벤트는 그대로 1" "active|1" "$($P -c "select status from public.ticket_products where id='tp1'")|$($P -c "select count(*) from public.ticket_restock_events")"

echo "── ⑤ 만석인데 어드민이 판매중으로 바꿈(재편집·토글) → 자리가 없으니 이벤트 없음"
$P -c "insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status,min_tier) values ('tp2','$REST','슌지','$FUT','18:00',2,'active',''); insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','tp2',2,'active','PAY-tp2')" >/dev/null
ok "tp2 만석 soldout" "soldout" "$($P -c "select status from public.ticket_products where id='tp2'")"
$P -c "update public.ticket_products set status='active' where id='tp2'" >/dev/null
ok "이벤트 여전히 1 (FULL)" "1" "$($P -c "select count(*) from public.ticket_restock_events")"
$P -c "update public.ticket_products set status='soldout' where id='tp2'" >/dev/null

echo "── ⑥ 한 트랜잭션 안의 soldout→active→soldout 왕복 → 커밋 시 다시 보니 만석 → 이벤트 없음"
$P -c "begin; update public.tickets set status='cancelled' where purchase_id='PAY-tp2'; insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M2','tp2',2,'active','PAY-tp2b'); commit;" >/dev/null
ok "tp2 soldout 유지 · 이벤트 1" "soldout|1" "$($P -c "select status from public.ticket_products where id='tp2'")|$($P -c "select count(*) from public.ticket_restock_events")"

echo "── ⑦ 지난 날짜 회차 → 이벤트 없음"
$P -c "insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status,min_tier) values ('tp3','$REST','옛날','$PAST','18:00',2,'active',''); insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','tp3',2,'active','PAY-tp3')" >/dev/null
$P -c "update public.tickets set status='cancelled' where purchase_id='PAY-tp3'" >/dev/null
ok "tp3 active 인데 이벤트 없음 (PAST)" "active|1" "$($P -c "select status from public.ticket_products where id='tp3'")|$($P -c "select count(*) from public.ticket_restock_events")"

echo "── ⑧ flex 엄격 모드에서 남은 1석을 채울 수 없으면(허용 2인·1인 0) → 이벤트 없음"
$P -c "insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,slots,status,min_tier,auto_soldout) values ('tp4','$REST','플렉스','$FUT','19:00',5,'{\"mode\":\"flex\",\"allowed\":[2],\"solo\":0,\"strict\":true}','soldout','',false); insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','tp4',2,'active','PAY-tp4a'),('$M2','tp4',2,'active','PAY-tp4b')" >/dev/null
$P -c "update public.ticket_products set status='active', auto_soldout=true where id='tp4'" >/dev/null
ok "tp4 잔여 1 · 채울 수 없음 → 이벤트 없음" "1|UNFILLABLE" "$($P -c "select count(*) from public.ticket_restock_events")|$($P -c "select public.taam_ticket_restock_check('tp4')->>'reason'")"
$P -c "update public.ticket_products set slots='{\"mode\":\"flex\",\"allowed\":[2],\"solo\":0,\"strict\":false}', status='soldout' where id='tp4'" >/dev/null
$P -c "update public.ticket_products set status='active' where id='tp4'" >/dev/null
ok "완화 모드는 마지막 1석 1인 개방 → 이벤트 2" "2" "$($P -c "select count(*) from public.ticket_restock_events")"

echo "── ⑨ kick: 설정 없으면 조용히 no_config · pending 없으면 nothing_pending"
ok "pending 1 · no_config" "no_config" "$($P -c "select public.taam_restock_kick()->>'reason'")"
$P -c "select public.taam_ticket_restock_process()" >/dev/null
ok "처리 뒤 nothing_pending" "nothing_pending" "$($P -c "select public.taam_restock_kick()->>'reason'")"
$P -c "insert into public.app_config(key,value) values ('restock_push', '{\"vault_secret\":\"x\",\"url\":\"https://example.test/functions/v1/notify-restock\"}'); insert into public.ticket_restock_events(ticket_product_id) values ('tp1')" >/dev/null
ok "설정은 있는데 pg_net 없음 → no_pg_net (예외 아님)" "no_pg_net" "$($P -c "select public.taam_restock_kick()->>'reason'")"

[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
