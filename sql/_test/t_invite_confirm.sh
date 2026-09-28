#!/bin/bash
# taam_invite_confirm_hold 회귀 — 2026-09-28. 먼저: 로컬 pg. 실행: bash sql/_test/t_invite_confirm.sh
cd "$(dirname "$0")/../.."
DB=t_invconf; P="psql -h /tmp -U postgres -d $DB -q -At -v ON_ERROR_STOP=0"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
$P <<'SQL' >/dev/null 2>&1
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('taam.uid', true),'')::uuid $$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as $$ select coalesce(current_setting('taam.super', true),'') = '1' $$;
create table public.profiles(id uuid primary key, display_name text);
create table public.ticket_products(id text primary key, rest_id uuid, type_class text);
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, ticket_product_id text,
  total_amount bigint, pax int, visit_date text, visit_time text, restaurant_id text, restaurant_name text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text,
  ticket_type text, reservation_date text, visit_time text, party_size int, price bigint, status text, purchase_id text,
  buyer_name text, buyer_phone text, extra_data jsonb, created_at timestamptz default now());
insert into public.profiles values ('a1000000-0000-4000-8000-000000000001','유수봉'),('a1000000-0000-4000-8000-000000000002','남');
insert into public.ticket_products values ('tp1','b1000000-0000-4000-8000-000000000001','Standard');
insert into public.reservation_invites(id,invitee_user_id,status,ticket_product_id,total_amount,pax,visit_date,visit_time,restaurant_id,restaurant_name) values
 ('c1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','paid','tp1',2500000,2,'2027.05.01','18:00','r1','마츠카와'),
 ('c2000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','paid','tp1',1000000,1,'2027.05.01','18:00','r1','마츠카와'),
 ('c3000000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000001','sent','tp1',1000000,1,'2027.05.01','18:00','r1','마츠카와');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id,extra_data) values
 ('a1000000-0000-4000-8000-000000000001','r1','tp1',2,2500000,'hold','INVH-c1000000-1','{"inviteHold":true,"inviteId":"c1000000-0000-4000-8000-000000000001"}');
SQL
$P -f supabase/migrations/20260928_invite_confirm_hold.sql 2>&1 | grep -E "❌|ERROR" ; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
me(){ $P -c "select set_config('taam.uid','a1000000-0000-4000-8000-000000000001',false); $1" 2>&1; }
other(){ $P -c "select set_config('taam.uid','a1000000-0000-4000-8000-000000000002',false); $1" 2>&1; }
r=$(me "select (public.taam_invite_confirm_hold('c1000000-0000-4000-8000-000000000001','INV-c1000000-999'))::text")
ok "홀드→확정 converted" "1" "$(echo "$r" | grep -c '"converted" : true')"
ok "행이 active · INV- 구매ID · 좌석 유지(2명)" "active|INV-c1000000-999|2" "$($P -c "select status||'|'||purchase_id||'|'||party_size from public.tickets where ticket_product_id='tp1'")"
r=$(me "select (public.taam_invite_confirm_hold('c1000000-0000-4000-8000-000000000001','INV-c1000000-999'))::text")
ok "두 번 불러도 already (중복 좌석 없음)" "1|1" "$(echo "$r" | grep -c '"already" : true')|$($P -c "select count(*) from public.tickets")"
r=$(me "select (public.taam_invite_confirm_hold('c2000000-0000-4000-8000-000000000002',null))::text")
ok "홀드 없음 + 연결 티켓 → 확정 행 삽입" "1|2" "$(echo "$r" | grep -c '"inserted" : true')|$($P -c "select count(*) from public.tickets where status='active' and ticket_product_id='tp1'")"
ok "  삽입 행 인원·금액·매장 uuid" "1|1000000|b1000000-0000-4000-8000-000000000001" "$($P -c "select party_size||'|'||price||'|'||restaurant_id from public.tickets where purchase_id like 'INV-c2000000-%' and extra_data->>'inserted'='true'")"
r=$(other "select (public.taam_invite_confirm_hold('c1000000-0000-4000-8000-000000000001','INV-c1000000-999'))::text")
ok "남의 초대 → 거부" "1" "$(echo "$r" | grep -c '내 초대가 아닙니다')"
r=$(me "select (public.taam_invite_confirm_hold('c3000000-0000-4000-8000-000000000003',null))::text")
ok "미결제(sent) → 거부" "1" "$(echo "$r" | grep -c 'INVITE_NOT_PAID')"
r=$(me "select (public.taam_invite_confirm_hold('c1000000-0000-4000-8000-000000000001','INV-zzzzzzzz-1'))::text")
ok "구매ID 불일치 → 거부 (already 보다 먼저 검사)" "1" "$(echo "$r" | grep -c 'PURCHASE_ID_MISMATCH')"
r=$($P -c "select set_config('taam.uid','',false); select set_config('taam.super','0',false); select (public.taam_invite_confirm_hold('c2000000-0000-4000-8000-000000000002',null))::text" 2>&1 | tail -1)
ok "SQL Editor(postgres, uid 없음) 호출 허용 → already" "1" "$(echo "$r" | grep -c '"already" : true')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과" || { echo "=== 실패 있음"; exit 1; }
