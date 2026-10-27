#!/bin/bash
# 게스트 만료 알림 중복 검사 글자 비교 회귀 — 2026-10-27. 먼저: 로컬 pg. 실행: bash sql/_test/t_guest_expiry_days_text.sh
cd "$(dirname "$0")/../.."
DB=t_gedt; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
G=b1000000-0000-4000-8000-000000000031; SU=b1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if; end \$\$;
create table public.profiles(id uuid primary key, display_name text, membership_tier text, guest_expires_at timestamptz, role text);
insert into public.profiles values ('$G','게스트','A', now() + interval '2 days 23 hours', 'user'), ('$SU','Super',null,null,'superadmin');
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable as \$\$ select exists(select 1 from public.profiles where id = u and role = 'superadmin') \$\$;
create table public.membership_settings(k text primary key, v jsonb);
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
# 라이브 판 후보 두 개를 차례로 — 옛 판(guest_expiry_notice.sql) · 새 판(low_batch_2026-09-14.sql)
for SRC in sql/guest_expiry_notice.sql sql/low_batch_2026-09-14.sql; do
  $P -c "delete from public.notifications" >/dev/null
  $P -c "drop function if exists public.taam_guest_expiry_notify()" >/dev/null
  awk '/^create or replace function public.taam_guest_days_left/{p=1} p{print} /^\$\$;/{if(p){exit}}' sql/guest_expiry_notice.sql > /tmp/_gedt_dl.sql; $P -f /tmp/_gedt_dl.sql >/dev/null 2>&1
  awk '/^create or replace function public.taam_guest_expiry_notify/{p=1} p{print} /^\$\$;/{if(p){exit}}' $SRC > /tmp/_gedt_fn.sql; $P -f /tmp/_gedt_fn.sql >/dev/null 2>&1
  $P -c "grant execute on function public.taam_guest_expiry_notify() to anon, authenticated" >/dev/null
  # 위조 줄: 게스트 본인(days 'x') · 슈퍼어드민 알림함(taam_notify_admins 모양 · guest_id 그 게스트 · days 'x')
  $P -c "insert into public.notifications(user_id, type, title, body, payload) values ('$G','guest_expiry_self','x','y','{\"days\":\"x\"}'), ('$SU','guest_expiry_admin','x','y','{\"guest_id\":\"$G\",\"days\":\"x\"}')" >/dev/null
  before=$($P -c "select public.taam_guest_expiry_notify()" 2>&1 | grep -c 'invalid input syntax')
  out=$($P -f supabase/migrations/20261027_guest_expiry_days_text.sql 2>&1)
  ok "[$SRC] 고치기 전 위조 줄로 실행 실패 · 마이그레이션 ✅ 교체 2곳 · ❌ 0" "1|1|0" "$before|$(echo "$out" | grep -c '✅ 교체(중복 검사 2곳')|$(echo "$out" | grep -c '❌')"
  r=$($P -c "select public.taam_guest_expiry_notify()" 2>&1)
  ok "[$SRC] 고친 뒤: 위조 줄이 있어도 실행 성공 · 슈퍼어드민 1 · 게스트 본인 1(3일 전)" "1|1" "$(echo "$r" | $P -c "select 1" >/dev/null; $P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'days'='3'")|$($P -c "select count(*) from public.notifications where user_id='$G' and type='guest_expiry_self' and payload->>'days'='3'")"
  ok "[$SRC] 다시 부르면 0·0 (같은 일수 한 번)" "0|0" "$($P -c "select (j->>'admin')||'|'||(j->>'self') from public.taam_guest_expiry_notify() j")"
  ok "[$SRC] 권한: anon·회원 실행 불가로 맞춤" "f|f" "$($P -c "select has_function_privilege('anon','public.taam_guest_expiry_notify()','execute')")|$($P -c "select has_function_privilege('authenticated','public.taam_guest_expiry_notify()','execute')")"
  out2=$($P -f supabase/migrations/20261027_guest_expiry_days_text.sql 2>&1)
  ok "[$SRC] 다시 RUN: ✅ 이미 글자 비교 · ❌ 0" "1|0" "$(echo "$out2" | grep -c '✅ 이미 글자 비교')|$(echo "$out2" | grep -c '❌')"
done
# 모르는 판 — 비교 모양이 없으면 덮어쓰지 않는다
$P -c "create or replace function public.taam_guest_expiry_notify() returns jsonb language sql as \$\$ select '{\"admin\":0}'::jsonb \$\$" >/dev/null
out3=$($P -f supabase/migrations/20261027_guest_expiry_days_text.sql 2>&1)
ok "모르는 판: ❌ 건너뜀 · 본문 그대로" "1|{\"admin\": 0}" "$(echo "$out3" | grep -c '❌ 중복 검사 모양을 못 찾음')|$($P -c "select public.taam_guest_expiry_notify()")"
# 함수가 없는 DB — ⚠ 만, ❌ 없음
$P -c "drop function public.taam_guest_expiry_notify()" >/dev/null
out4=$($P -f supabase/migrations/20261027_guest_expiry_days_text.sql 2>&1)
ok "함수 없는 DB: ⚠ · ❌ 0 · 오류 없음" "1|0|" "$(echo "$out4" | grep -c '⚠ 라이브에 함수가 없다')|$(echo "$out4" | grep -c '❌')|$(echo "$out4" | grep ERROR | head -1)"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
