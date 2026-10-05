#!/bin/bash
# ticket_products.status 저장 시 재계산 회귀 — 2026-10-05. 먼저: 로컬 pg. 실행: bash sql/_test/t_tp_status_recalc.sh
#   sync v4 + 취소표 알림 마이그레이션을 올린 위에 20261005_ticket_products_status_recalc.sql 을 얹고,
#   재편집(active 덮어쓰기)·정원 늘림·수동 잠금·신규 행·가짜 취소표 알림을 본다.
cd "$(dirname "$0")/../.."
DB=t_tp_recalc; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M1=a1000000-0000-4000-8000-000000000011; M2=a1000000-0000-4000-8000-000000000012; REST=b1000000-0000-4000-8000-000000000001
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
insert into auth.users values ('$M1'),('$M2');
insert into public.profiles(id, role, membership_tier) values ('$M1','member','M'), ('$M2','member','M');
SQL
S0=$(grep -n "create or replace function public.taam_visit_date" sql/visit_reminder.sql | cut -d: -f1); E0=$(grep -n "create or replace function public.taam_visit_reminder_notify" sql/visit_reminder.sql | cut -d: -f1)
sed -n "${S0},$((E0-1))p" sql/visit_reminder.sql | $P >/dev/null 2>&1
S1=$(grep -n "create or replace function public.taam_seat_fillable" sql/ticket_capacity_guard.sql | cut -d: -f1); E1=$(awk -v s=$S1 'NR>s && /^\$\$;/ {print NR; exit}' sql/ticket_capacity_guard.sql)
sed -n "${S1},${E1}p" sql/ticket_capacity_guard.sql | $P >/dev/null 2>&1
S2=$(grep -n "create or replace function public.sync_ticket_soldout" sql/seat_hold_repair.sql | cut -d: -f1); E2=$(grep -n "execute function public.sync_ticket_soldout();" sql/seat_hold_repair.sql | cut -d: -f1)
sed -n "${S2},${E2}p" sql/seat_hold_repair.sql | $P >/dev/null 2>&1
$P -f supabase/migrations/20260929_ticket_restock.sql >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FUT=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 30, 'YYYY.MM.DD')")

echo "── 0) 마이그레이션 전: 시마즈 모양 — 초대로 8/8, 재편집이 active 로 덮음"
$P <<SQL >/dev/null
insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status) values ('shz','$REST','시마즈','$FUT','19:30',8,'active');
insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','shz',5,'active','INV-a'),('$M2','shz',2,'active','INV-b'),('$M1','shz',1,'manual','MAN-c');
SQL
ok "초대·수동으로 8/8 → sync v4 가 soldout" "soldout" "$($P -c "select status from public.ticket_products where id='shz'")"
$P -c "update public.ticket_products set status='active', total_pax=8, time='19:30' where id='shz'" >/dev/null
ok "재편집(트리거 전) → active 로 덮인다 = 사고 재현" "active" "$($P -c "select status from public.ticket_products where id='shz'")"

echo "── 1) 마이그레이션"
out=$($P -f supabase/migrations/20261005_ticket_products_status_recalc.sql 2>&1)
ok "오류 없음 · ✅ 4 · ❌ 0" "|4|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '❌')"
ok "② 가 시마즈 1건을 맞췄다" "1" "$(echo "$out" | grep -c '✅ 1건 — 시마즈')"
ok "시마즈 soldout · auto true" "soldout|true" "$($P -c "select status||'|'||auto_soldout from public.ticket_products where id='shz'")"

echo "── 2) 트리거: 꽉 찬 채 재편집이 active 를 보내도 soldout 유지"
$P -c "update public.ticket_products set status='active', time='19:30' where id='shz'" >/dev/null
ok "status soldout 유지" "soldout" "$($P -c "select status from public.ticket_products where id='shz'")"
ok "취소표 알림 이벤트 없음 (전이 자체가 없다)" "0" "$($P -c "select count(*) from public.ticket_restock_events")"

echo "── 3) 정원을 10 으로 늘림 → 자리 2 → active · 취소표 알림 이벤트 1"
$P -c "update public.ticket_products set total_pax=10 where id='shz'" >/dev/null
ok "active" "active" "$($P -c "select status from public.ticket_products where id='shz'")"
ok "restock 이벤트 1 · seats_left 2" "1|2" "$($P -c "select count(*) from public.ticket_restock_events")|$($P -c "select seats_left from public.ticket_restock_events order by id desc limit 1")"

echo "── 4) 정원을 다시 8 로 줄임(active 로 저장) → 꽉 참 → soldout"
$P -c "update public.ticket_products set total_pax=8, status='active' where id='shz'" >/dev/null
ok "soldout" "soldout" "$($P -c "select status from public.ticket_products where id='shz'")"

echo "── 5) 수동 잠금(auto_soldout=false)은 정원을 늘려도 풀지 않는다"
$P -c "insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status,auto_soldout) values ('lock','$REST','수동','$FUT','18:00',4,'soldout',false)" >/dev/null
$P -c "update public.ticket_products set total_pax=6 where id='lock'" >/dev/null
ok "soldout 유지" "soldout|false" "$($P -c "select status||'|'||auto_soldout from public.ticket_products where id='lock'")"
echo "── 6) 어드민 토글 순서(앱): status='soldout' 먼저 → auto_soldout=false 뒤 — 자리가 있어도 둘 다 그대로"
$P -c "insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status) values ('tg','$REST','토글','$FUT','18:00',4,'active'); insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','tg',1,'active','PAY-tg')" >/dev/null
$P -c "update public.ticket_products set status='soldout' where id='tg'" >/dev/null
$P -c "update public.ticket_products set auto_soldout=false where id='tg'" >/dev/null
ok "soldout · auto false" "soldout|false" "$($P -c "select status||'|'||auto_soldout from public.ticket_products where id='tg'")"
echo "── 7) 판매 재개 토글: status='active' (자리 있음) → active 그대로"
$P -c "update public.ticket_products set status='active' where id='tg'" >/dev/null
ok "active" "active" "$($P -c "select status from public.ticket_products where id='tg'")"

echo "── 8) 신규 업로드(insert) · 정원 없는 행 · pending 행은 건드리지 않는다"
$P -c "insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status) values ('new1','$REST','신규','$FUT','18:00',4,'active'),('nocap','$REST','정원없음','$FUT','18:00',null,'active'),('pend','$REST','승인대기','$FUT','18:00',2,'pending')" >/dev/null
$P -c "insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','pend',2,'active','PAY-p')" >/dev/null
$P -c "update public.ticket_products set status='pending', total_pax=2 where id='pend'" >/dev/null
ok "new1 active · nocap active · pend pending" "active|active|pending" "$($P -c "select string_agg(status, '|' order by id) from public.ticket_products where id in ('new1','nocap','pend')")"

echo "── 9) 취소된 행은 점유에 안 센다 — 8/8 에서 하나 취소되면 재편집 active 가 그대로 산다"
$P -c "update public.tickets set status='cancelled' where purchase_id='MAN-c'" >/dev/null
ok "취소 뒤 sync 가 active 로" "active" "$($P -c "select status from public.ticket_products where id='shz'")"
$P -c "update public.ticket_products set status='active', time='19:30' where id='shz'" >/dev/null
ok "재편집 active 유지(자리 1)" "active" "$($P -c "select status from public.ticket_products where id='shz'")"

echo "── 10) 두 번 돌려도 안전 (idempotent)"
out2=$($P -f supabase/migrations/20261005_ticket_products_status_recalc.sql 2>&1)
ok "재실행 오류 없음 · ②③ 0건" "|2" "$(echo "$out2" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '✅ 0건')"

[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
