#!/bin/bash
# 재구매 제한 회귀 — 2026-10-13. 먼저: 로컬 pg. 실행: bash sql/_test/t_repurchase.sh
#   실제 가드(sql/repurchase_release_7days.sql 의 함수 5개 + 트리거)를 그대로 올려, 회원(authenticated)이
#   같은 매장에 N일 안의 방문일로 홀드를 넣으면 REPURCHASE_BLOCKED 로 막히는지 본다. 120·180일 포함.
cd "$(dirname "$0")/../.."
DB=t_repur; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=a1000000-0000-4000-8000-000000000011; SU=a1000000-0000-4000-8000-000000000001; X=a1000000-0000-4000-8000-000000000012
R180=b1000000-0000-4000-8000-000000000001; R120=b1000000-0000-4000-8000-000000000002; R0=b1000000-0000-4000-8000-000000000003
TODAY=$(date -u +%Y.%m.%d); OLD=$(date -u -d '-8 days' +%Y.%m.%d)
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create table public.profiles(id uuid primary key, role text, single_device_exempt boolean default false);
create table public.restaurants(id uuid primary key, name text, repurchase_day int);
create table public.ticket_products(id text primary key, sale_state text, sale_open_at text, reg_date text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id uuid, ticket_product_id text, reservation_date text, party_size int default 2, status text default 'hold', purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
insert into auth.users values ('$M'),('$SU'),('$X');
insert into public.profiles values ('$M','member',false), ('$SU','super_admin',false), ('$X','member',true);
insert into public.restaurants values ('$R180','반년 매장',180), ('$R120','넉달 매장',120), ('$R0','제한없음',0);
insert into public.ticket_products values ('tp-new','open',null,'$TODAY'), ('tp-old','open',null,'$OLD'), ('tp-draft','draft',null,'$TODAY');
-- 회원 M 의 기존 예약: 반년 매장 2027.01.10 · 넉달 매장 2027.01.10
insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values
  ('$M','$R180','tp-x','2027.01.10','active','PAY-a'), ('$M','$R120','tp-y','2027.01.10','active','PAY-b');
grant usage on schema public to authenticated; grant all on all tables in schema public to authenticated; grant usage on schema auth to authenticated;
SQL
# 실제 가드 함수 5개 + 트리거 (파일의 41행부터 트리거 선언 끝까지)
E=$(grep -n 'execute function public.taam_guard_repurchase();' sql/repurchase_release_7days.sql | head -1 | cut -d: -f1)
sed -n "41,${E}p" sql/repurchase_release_7days.sql | $P >/dev/null 2>&1
# 2026-10-13 해제 폐지 마이그레이션을 그 위에 얹는다
$P -f supabase/migrations/20261013_repurchase_no_release.sql 2>&1 | grep -E "^ERROR|❌" | head -1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "픽스처: 가드 트리거·해제 함수 올라감" "2" "$($P -c "select (select count(*) from pg_trigger where tgname='trg_taam_repurchase_guard') + (select count(*) from pg_proc where proname='taam_repurchase_released')")"
# 회원으로 홀드 넣기: uid·role 을 세팅하고 insert. 결과 = OK | BLOCKED | 기타 오류
res(){ o=$($P -c "set local taam.uid='$1'; set local taam.super='$2'; set local role authenticated; insert into public.tickets(user_id, restaurant_id, ticket_product_id, reservation_date, status, purchase_id) values ('$1','$3','$4','$5','hold','$6');" 2>&1); if echo "$o" | grep -q REPURCHASE_BLOCKED; then echo REPURCHASE_BLOCKED; elif echo "$o" | grep -q ERROR; then echo "ERROR:$(echo "$o" | head -1 | cut -c1-80)"; else echo OK; fi; }
echo "── 180일 매장 (오늘 발매 → 아직 해제 전)"
ok "50일 뒤 방문 (2027.03.01) → 막힘" "REPURCHASE_BLOCKED" "$(res $M 0 $R180 tp-new 2027.03.01 PAYH-1)"
ok "179일 뒤 (2027.07.08) → 막힘" "REPURCHASE_BLOCKED" "$(res $M 0 $R180 tp-new 2027.07.08 PAYH-2)"
ok "180일 뒤 (2027.07.09) → 허용" "OK" "$(res $M 0 $R180 tp-new 2027.07.09 PAYH-3)"
ok "앞쪽 방문도 센다: 100일 전 (2026.10.02) → 막힘" "REPURCHASE_BLOCKED" "$(res $M 0 $R180 tp-new 2026.10.02 PAYH-4)"
ok "같은 날 (2027.01.10) → 허용 (같은 날 예외)" "OK" "$(res $M 0 $R180 tp-new 2027.01.10 PAYH-5)"
echo "── 120일 매장"
ok "115일 뒤 (2027.05.05) → 막힘" "REPURCHASE_BLOCKED" "$(res $M 0 $R120 tp-new 2027.05.05 PAYH-6)"
ok "122일 뒤 (2027.05.12) → 허용" "OK" "$(res $M 0 $R120 tp-new 2027.05.12 PAYH-7)"
echo "── 예외"
ok "발매 8일 지난 티켓(tp-old) → 그래도 막힘 (7일 해제 폐지 · 2026-10-13)" "REPURCHASE_BLOCKED" "$(res $M 0 $R180 tp-old 2027.03.01 PAYH-8)"
ok "미공개(draft) 티켓 → 막힘" "REPURCHASE_BLOCKED" "$(res $M 0 $R180 tp-draft 2027.03.01 PAYH-9)"
ok "제한없음 매장 → 허용" "OK" "$(res $M 0 $R0 tp-new 2027.03.01 PAYH-10)"
ok "초대 홀드(INVH-) → 허용" "OK" "$(res $M 0 $R180 tp-new 2027.03.01 INVH-11)"
ok "슈퍼어드민 → 허용" "OK" "$(res $SU 1 $R180 tp-new 2027.03.01 PAYH-12)"
ok "면제 계정(single_device_exempt) → 허용" "OK" "$(res $X 0 $R180 tp-new 2027.03.01 PAYH-13)"
# 앞 단계에서 허용돼 들어간 홀드(PAYH-3·5·8…)도 「기존 예약」이므로 전부 취소한 뒤 본다
$P -c "update public.tickets set status='cancelled' where user_id='$M' and restaurant_id='$R180'" >/dev/null
ok "기존 예약을 전부 취소하면 → 허용" "OK" "$(res $M 0 $R180 tp-new 2027.03.01 PAYH-14)"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
