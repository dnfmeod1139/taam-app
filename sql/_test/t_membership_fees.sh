#!/bin/bash
# 멤버십 연회비 기록 표 회귀 — 2026-10-15. 먼저: 로컬 pg. 실행: bash sql/_test/t_membership_fees.sh
#   RLS(슈퍼어드민만) · 제약(금액·수단·기간) · created_by/updated_at 트리거.
cd "$(dirname "$0")/../.."
DB=t_mfees; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
A=a1000000-0000-4000-8000-000000000011; B=a1000000-0000-4000-8000-000000000012; SU=a1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
insert into auth.users values ('$A'),('$B'),('$SU');
grant usage on schema public to authenticated; grant usage on schema auth to authenticated;
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
out=$($P -f supabase/migrations/20261015_membership_fees.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
as(){ $P -c "set local taam.uid='$1'; set local taam.super='$2'; set local role authenticated; $3" 2>&1; }
ok "슈퍼어드민 insert → ok · created_by = 슈퍼" "$SU" "$(as $SU 1 "insert into public.membership_fees(user_id, paid_at, amount_krw, method, period_from, period_to, tier, note) values ('$A','2024-12-05',1500000,'transfer','2024-12-05','2025-12-04','M','첫해') returning created_by::text;" | tail -1)"
ok "슈퍼어드민 select → 1건" "1" "$(as $SU 1 "select count(*) from public.membership_fees where user_id='$A';" | tail -1)"
ok "회원 본인 select → 0건 (정책 없음)" "0" "$(as $A 0 "select count(*) from public.membership_fees where user_id='$A';" | tail -1)"
ok "회원 insert → RLS 거부" "1" "$(as $A 0 "insert into public.membership_fees(user_id, paid_at, amount_krw) values ('$A','2025-01-01',1000);" | grep -c "row-level security")"
ok "회원 update → 0행 (안 보임)" "0" "$(as $A 0 "update public.membership_fees set amount_krw=1 where user_id='$A' returning 1;" | grep -c "^1$")"
ok "슈퍼어드민 update → updated_at 찍힘 · created_by 못 바꿈" "true|$SU" "$(as $SU 1 "update public.membership_fees set amount_krw=1600000, created_by='$B' where user_id='$A' returning (updated_at is not null)::text||'|'||created_by::text;" | tail -1)"
ok "음수 금액 → 제약 위반" "1" "$(as $SU 1 "insert into public.membership_fees(user_id, paid_at, amount_krw) values ('$B','2025-01-01',-5);" | grep -c "check constraint")"
ok "모르는 수단 → 제약 위반" "1" "$(as $SU 1 "insert into public.membership_fees(user_id, paid_at, amount_krw, method) values ('$B','2025-01-01',5,'bitcoin');" | grep -c "check constraint")"
ok "기간 역전 → 제약 위반" "1" "$(as $SU 1 "insert into public.membership_fees(user_id, paid_at, amount_krw, period_from, period_to) values ('$B','2025-01-01',5,'2025-01-01','2024-12-31');" | grep -c "check constraint")"
ok "외화 기록(USD) → ok" "USD|1200.00" "$(as $SU 1 "insert into public.membership_fees(user_id, paid_at, amount_krw, fx_currency, fx_amount, method) values ('$B','2025-07-16',1650000,'USD',1200,'transfer') returning fx_currency||'|'||fx_amount::text;" | tail -1)"
ok "슈퍼어드민 delete → ok" "0" "$(as $SU 1 "delete from public.membership_fees where user_id='$A'; select count(*) from public.membership_fees where user_id='$A';" | tail -1)"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
