#!/bin/bash
# 링크 초대 회귀 — 2026-09-29. 먼저: 로컬 pg. 실행: bash sql/_test/t_link_invite.sh
cd "$(dirname "$0")/../.."
DB=t_linkinv; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
$P <<'SQL' >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('taam.uid', true),'')::uuid $$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as $$ select coalesce(current_setting('taam.super', true),'') = '1' $$;
create or replace function public.taam_kashikiri_token() returns text language sql as $$ select md5(random()::text || clock_timestamp()::text) $$;
create table public.profiles(id uuid primary key, display_name text);
create table public.admin_grants(user_id uuid, rest_id text, venue_id text);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, total_pax int, meal_fee int, agency_fee int, wine_min int, type_class text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, ticket_type text,
  reservation_date text, visit_time text, party_size int, price bigint, status text, purchase_id text, buyer_name text, buyer_phone text, extra_data jsonb, created_at timestamptz default now());
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_id text, venue_name text, event_date date, event_time time, total_pax int, escort boolean, status text,
  fx_rate numeric, fx_usd numeric, ticket_product_id text, created_by uuid, memo text, created_at timestamptz default now());
create table public.kashikiri_teams(id uuid primary key default gen_random_uuid(), event_id uuid, seq int, host_label text, pax int);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, label text, payer_phone text, amount_krw int, amount_jpy int,
  token text default public.taam_kashikiri_token(), status text default 'pending' check (status in ('pending','paid','cancelled','expired','failed')),
  pay_currency text default 'KRW', pay_fx numeric, pay_amount numeric, expires_at timestamptz, payment_key text, payer_name text, approved_at timestamptz);
create or replace function public.taam_ticket_price_krw(p text, n int) returns bigint language sql stable as $$
  select (coalesce(meal_fee,0)+coalesce(agency_fee,0)+coalesce(wine_min,0))*greatest(coalesce(n,1),1) from public.ticket_products where id = p $$;
-- 용량 트리거 흉내: 정원 넘으면 TICKET_SOLD_OUT
create or replace function public._cap() returns trigger language plpgsql as $$
declare v int; c int; begin
  select total_pax into c from public.ticket_products where id = new.ticket_product_id;
  select coalesce(sum(party_size),0) into v from public.tickets where ticket_product_id = new.ticket_product_id and coalesce(status,'')<>'cancelled';
  if c is not null and v + new.party_size > c then raise exception 'TICKET_SOLD_OUT'; end if; return new; end $$;
create trigger t_cap before insert on public.tickets for each row execute function public._cap();
insert into auth.users values ('a1000000-0000-4000-8000-000000000001');
insert into public.profiles values ('a1000000-0000-4000-8000-000000000001','슈퍼');
insert into public.ticket_products values ('tp1','b1000000-0000-4000-8000-000000000001','마츠카와','05.01','18:00',4,750000,150000,350000,'Standard');
SQL
$P -f supabase/migrations/20260929_link_invite.sql 2>&1 | grep -E "❌|ERROR"; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
S="select set_config('taam.uid','a1000000-0000-4000-8000-000000000001',false); select set_config('taam.super','1',false);"
r=$($P -c "$S select (public.taam_link_invite_create('tp1','Joy','+1 415 555 0100',2,'USD',1380,'2027.05.01','18:00'))::text" 2>&1)
ok "만들기 ok · 금액 (750000+150000+350000)×2=2,500,000 · \$1811.59" "1|1" "$(echo "$r" | grep -c '"amount_krw" : 2500000')|$(echo "$r" | grep -c '"pay_amount" : 1811.59')"
ok "홀드 행 LINK- · 2명 · hold" "hold|2" "$($P -c "select status||'|'||party_size from public.tickets where purchase_id like 'LINK-%'")"
ok "정산 회차·팀·청구 각 1 · 청구 USD·link_invite" "1|1|1|USD|true" "$($P -c "select (select count(*) from public.kashikiri_events)||'|'||(select count(*) from public.kashikiri_teams)||'|'||(select count(*) from public.kashikiri_charges)||'|'||(select pay_currency||'|'||link_invite from public.kashikiri_charges limit 1)")"
CID=$($P -c "select id from public.kashikiri_charges limit 1")
r=$($P -c "$S select (public.taam_link_invite_create('tp1','Kim',null,3,'KRW',null,'2027.05.01','18:00'))::text" 2>&1)
ok "정원 초과(2+3>4) → TICKET_SOLD_OUT 롤백 (청구도 안 남음)" "1|1" "$(echo "$r" | grep -c TICKET_SOLD_OUT)|$($P -c "select count(*) from public.kashikiri_charges")"
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk1', payer_name='Joy Kim' where id='$CID'" >/dev/null
ok "결제 → 홀드가 active · 이름 반영 ⭐" "active|Joy Kim" "$($P -c "select status||'|'||buyer_name from public.tickets where purchase_id like 'LINK-%'")"
q=$($P -c "select (public.taam_link_invite_refund_quote('$CID'))::text")
ok "30분 안 → 전액 환불 견적 (2,500,000 · \$1811.59)" "1|1" "$(echo "$q" | grep -c '"refund_krw" : 2500000')|$(echo "$q" | grep -c 'within_30min_full')"
$P -c "update public.kashikiri_charges set approved_at=now()-interval '2 hours' where id='$CID'" >/dev/null
q=$($P -c "select (public.taam_link_invite_refund_quote('$CID'))::text")
ok "D-31 이상 → 총액−대행비(150000×2) = 2,200,000" "1|1" "$(echo "$q" | grep -c '"refund_krw" : 2200000')|$(echo "$q" | grep -c 'd31_minus_agency')"
$P -c "update public.tickets set reservation_date=to_char((now() at time zone 'Asia/Seoul')::date + 10, 'YYYY.MM.DD') where purchase_id like 'LINK-%'" >/dev/null
q=$($P -c "select (public.taam_link_invite_refund_quote('$CID'))::text")
ok "D-10 → 0 원" "1" "$(echo "$q" | grep -c '"refund_krw" : 0')"
r=$($P -c "$S select (public.taam_link_invite_mark_refunded('$CID', 0, 0, '테스트'))::text" 2>&1)
ok "환불 확정 → refunded · 좌석 행 cancelled ⭐" "refunded|cancelled" "$($P -c "select (select status from public.kashikiri_charges where id='$CID')||'|'||(select status from public.tickets where purchase_id like 'LINK-%')")"
r=$($P -c "select set_config('taam.uid','a1000000-0000-4000-8000-000000000001',false); select set_config('taam.super','0',false); select (public.taam_link_invite_create('tp1','Nope',null,1,'KRW',null,'2027.05.01',null))::text" 2>&1)
ok "권한 없는 사용자 → 거부" "1" "$(echo "$r" | grep -c '권한이 없습니다')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과" || { echo "=== 실패 있음"; exit 1; }
