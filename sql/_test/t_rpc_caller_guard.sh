#!/bin/bash
# 재구매 해제 알림 대상 함수 호출자 검사 회귀 — 2026-10-16. 먼저: 로컬 pg. 실행: bash sql/_test/t_rpc_caller_guard.sh
#   원본(sql/repurchase_release_7days.sql · 검사 없음)을 올린 뒤 마이그레이션을 얹어 「같은 결과 · 슈퍼어드민만」을 본다.
cd "$(dirname "$0")/../.."
DB=t_rpcguard; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; M=a1000000-0000-4000-8000-000000000011; N=a1000000-0000-4000-8000-000000000012; R=b1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
          if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create table public.profiles(id uuid primary key, display_name text, role text);
create table public.restaurants(id uuid primary key, repurchase_day int);
create table public.ticket_products(id text primary key, rest_id uuid, date text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id uuid, ticket_product_id text, reservation_date text, status text, purchase_id text, extra_data jsonb default '{}'::jsonb);
insert into auth.users values ('$SU'),('$M'),('$N');
insert into public.profiles values ('$SU','슈퍼','super_admin'),('$M','최근방문','member'),('$N','이미산','member');
insert into public.restaurants values ('$R', 30);
insert into public.ticket_products values ('tp1','$R','2027.05.21');
insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values
  ('$M','$R','tp0','2027.05.10','active','PAY-m'), ('$N','$R','tp0','2027.05.12','active','PAY-n'), ('$N','$R','tp1','2027.05.21','active','PAY-n2');
grant usage on schema public to authenticated, anon; grant all on all tables in schema public to authenticated; grant usage on schema auth to authenticated, anon;
alter default privileges in schema public grant execute on functions to anon, authenticated;
SQL
# 원본 함수(검사 없음) + taam_date_or_null
sed -n 124,136p sql/repurchase_release_7days.sql | $P >/dev/null 2>&1
sed -n 263,310p sql/repurchase_release_7days.sql | $P >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
q(){ $P -c "set local taam.uid='$1'; set local taam.super='$2'; set local role $3; select user_id::text from public.taam_repurchase_release_targets('tp1') order by 1;" 2>&1 | grep -oE "^[0-9a-f-]{36}$|ERROR" | tr '\n' '|'; }
ok "원본: 회원도 남의 대상을 읽는다 (지적된 구멍) · 대상 = 최근방문 M 만(이미 산 N 제외)" "$M|" "$(q $M 0 authenticated)"
out=$($P -f supabase/migrations/20261016_rpc_caller_guard.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
ok "슈퍼어드민 → 같은 결과 (M 만)" "$M|" "$(q $SU 1 authenticated)"
ok "회원 → 거절" "ERROR|" "$(q $M 0 authenticated)"
ok "비로그인(anon) → 거절" "ERROR|" "$(q '' 0 anon)"
ok "SQL Editor(postgres · uid 없음) → 허용" "$M|" "$($P -c "select user_id::text from public.taam_repurchase_release_targets('tp1');" 2>&1 | grep -oE "^[0-9a-f-]{36}$|ERROR" | tr '\n' '|')"
ok "anon 실행 권한 없음 · authenticated 있음" "false|true" "$($P -c "select has_function_privilege('anon','public.taam_repurchase_release_targets(text)','execute')||'|'||has_function_privilege('authenticated','public.taam_repurchase_release_targets(text)','execute')")"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
