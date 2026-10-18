#!/bin/bash
# 원장 유형 가드 회귀 — 2026-10-18. 먼저: 로컬 pg. 실행: bash sql/_test/t_ledger_type_guard.sh
#   회원 세션의 admin_* 줄 거절 · 회원 정상 유형 통과 · 슈퍼어드민·서버 통과 · 연회비 기록 트리거보다 먼저(BEFORE) 걸린다.
cd "$(dirname "$0")/../.."
DB=t_ltguard; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
A=a1000000-0000-4000-8000-000000000011; SU=a1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable as \$\$ select uid = '$SU'::uuid \$\$;   -- 인자를 본다 — 호출자가 아니라 행 소유자를 검사하는 변이를 잡으려고(리뷰)
insert into auth.users values ('$A'),('$SU');
create table public.profiles(id uuid primary key, display_name text, membership_tier text, role text);
insert into public.profiles values ('$A','김티','T','user'),('$SU','Super Admin','M','superadmin');
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint,
  description text, payment_id uuid, metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now());
grant usage on schema public to authenticated; grant usage on schema auth to authenticated;
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P -f supabase/migrations/20261015_membership_fees.sql >/dev/null 2>&1
$P -f supabase/migrations/20261018_fee_deduct_record.sql >/dev/null 2>&1
out=$($P -f supabase/migrations/20261018_ledger_admin_type_guard.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · ④ 정보 0" "|0|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')"
ins(){ $P -c "set taam.uid='$1'; set taam.super='$2'; insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata) values ('$3','membership','$4',$5,0,'$6','$7'::jsonb) returning id" 2>&1; }
cnt(){ $P -c "select count(*) from public.deposit_transactions where user_id='$1'"; }
# ── 회원 세션 ──
r=$(ins $A 0 $A admin_deduct -1 '위조 차감' '{}'); ok "회원 admin_deduct → LEDGER_TYPE_FORBIDDEN(42501) · 줄 0" "1|0" "$(echo "$r" | grep -c 'LEDGER_TYPE_FORBIDDEN')|$(cnt $A)"
r=$(ins $A 0 $A admin_grant 1000 '위조 부여' '{}'); ok "회원 admin_grant → 거절" "1|0" "$(echo "$r" | grep -c 'LEDGER_TYPE_FORBIDDEN')|$(cnt $A)"
r=$(ins $A 0 $A ADMIN_DEDUCT -1 '대문자' '{}'); ok "회원 ADMIN_DEDUCT(대문자) → 거절" "1" "$(echo "$r" | grep -c 'LEDGER_TYPE_FORBIDDEN')"
r=$(ins $A 0 $A admin_deduct -1 '플래그' '{"membership_fee":true}'); ok "회원 admin_deduct + 연회비 플래그 → 유형 가드가 먼저(BEFORE) 거절 · FEE_RECORD_FAILED 아님 · 기록 0" "1|0|0" "$(echo "$r" | grep -c 'LEDGER_TYPE_FORBIDDEN')|$(echo "$r" | grep -c 'FEE_RECORD_FAILED')|$($P -c "select count(*) from public.membership_fees")"
ins $A 0 $A ticket_purchase -500000 '예치금 구매' '{}' >/dev/null; ins $A 0 $A ticket_refund 500000 '환불' '{}' >/dev/null; ins $A 0 $A membership_payment -1125000 '멤버십' '{}' >/dev/null; ins $A 0 $A user_charge 100000 '충전' '{}' >/dev/null
ok "회원 정상 유형 4종(ticket_purchase · ticket_refund · membership_payment · user_charge) → 전부 통과" "4" "$(cnt $A)"
r=$(ins $A 0 $A administrative_fee -1 '접두어만 비슷' '{}'); ok "admin_ 접두어가 아닌 유형(administrative_fee)은 통과 — 가드는 admin_* 만" "0|5" "$(echo "$r" | grep -c 'LEDGER_TYPE_FORBIDDEN')|$(cnt $A)"
# ── 슈퍼어드민 · 서버 ──
r=$(ins $SU 1 $A admin_deduct -630000 '연회비' '{"granted_by":"'$SU'","membership_fee":true}'); ok "슈퍼어드민 admin_deduct(+연회비 플래그) → 통과 · 기록 1" "0|6|1" "$(echo "$r" | grep -c 'LEDGER_TYPE_FORBIDDEN')|$(cnt $A)|$($P -c "select count(*) from public.membership_fees where user_id='$A'")"
r=$(ins '' 0 $A admin_grant 10000 '서버 부여' '{"server_caller":"service_role"}'); ok "서버(uid 없음 · SQL Editor·Edge) admin_grant → 통과" "0|7" "$(echo "$r" | grep -c 'LEDGER_TYPE_FORBIDDEN')|$(cnt $A)"
ok "트리거 BEFORE INSERT · security definer · 하나" "O|t|1" "$($P -c "select tgtype::int & 2 = 2 from pg_trigger where tgname='trg_taam_guard_ledger_change_type'" | sed 's/^t$/O/')|$($P -c "select prosecdef from pg_proc where oid=to_regproc('public.taam_guard_ledger_change_type')")|$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ledger_change_type' and not tgisinternal")"
# ── ④ 정보 행 — 회원이 스스로 쓴 admin_* 줄을 센다(granted_by = 본인 · 비슈퍼어드민) ──
$P -c "alter table public.deposit_transactions disable trigger trg_taam_guard_ledger_change_type" >/dev/null
ins $A 0 $A admin_deduct -1 '옛 위조' '{}' >/dev/null
$P -c "alter table public.deposit_transactions enable trigger trg_taam_guard_ledger_change_type" >/dev/null
ins $SU 1 $A admin_deduct -1 '어드민이 적은 줄' '{"granted_by":"'$SU'"}' >/dev/null 2>&1 || true
ok "④ 정보 — 가드 전에 회원 원장에 로그인 호출로 들어간 admin_* 줄을 센다(granted_by 없음·본인 포함 · 슈퍼어드민이 적은 줄은 제외)" "1" "$($P -f supabase/migrations/20261018_ledger_admin_type_guard.sql 2>&1 | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
