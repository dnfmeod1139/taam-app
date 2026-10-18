#!/bin/bash
# 회원 소유 LINK- 행 → 리마인드·시작일 회귀 — 2026-10-19. 먼저: 로컬 pg. 실행: bash sql/_test/t_member_link_rows.sh
cd "$(dirname "$0")/../.."
DB=t_mlr; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=a1000000-0000-4000-8000-000000000011; SU=a1000000-0000-4000-8000-000000000001
TOMORROW=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 1, 'YYYY.MM.DD')")
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
insert into auth.users values ('$M'),('$SU');
create table public.profiles(id uuid primary key, display_name text, created_at timestamptz default now() - interval '400 days', membership_joined_at date, notif_prefs jsonb default '{}'::jsonb, role text);
insert into public.profiles(id, display_name, role) values ('$M','김회원','user'),('$SU','Super','superadmin');
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_name text, reservation_date text, visit_time text, status text, purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, change_type text, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now());
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P -f sql/visit_reminder.sql >/dev/null 2>&1
$P -f supabase/migrations/20261013_member_start.sql >/dev/null 2>&1
# 20261015 판 member_start 만 올린다 (파일 전체는 profiles 컬럼·가드가 많다) — 함수 정의 구간만 잘라서
awk '/^create or replace function public.taam_member_start/{p=1} p{print} /^end \$\$;/{if(p){exit}}' supabase/migrations/20261015_membership_joined.sql > /tmp/_ms_fn.sql
$P -f /tmp/_ms_fn.sql >/dev/null 2>&1
# 행: 회원 소유 LINK-(memberUid) 내일 · 비회원 LINK- 내일 · 회원 PAYH- 내일
$P -c "insert into public.tickets(user_id, restaurant_name, reservation_date, visit_time, status, purchase_id, extra_data) values
  ('$M','마츠카와','$TOMORROW','18:00','active','LINK-aaa','{\"linkInvite\":true,\"memberUid\":\"$M\"}'),
  ('$SU','사이토','$TOMORROW','12:00','active','LINK-bbb','{\"linkInvite\":true}'),
  ('$M','카타오리','$TOMORROW','19:00','active','PAYC-ccc','{}')" >/dev/null
before=$($P -c "set taam.uid='$M'; select (public.taam_member_start('$M')->>'started')")
r0=$($P -c "select (public.taam_visit_reminder_notify()->>'made')")
ok "교체 전: 리마인드는 PAYC- 1건만 · 시작일은 PAYC- 로 true" "1|true" "$r0|$before"
$P -c "delete from public.notifications" >/dev/null
out=$($P -f supabase/migrations/20261019_member_link_rows.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · 둘 다 ✅ 교체" "|0|2" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체')"
r1=$($P -c "select (public.taam_visit_reminder_notify()->>'made')")
ok "교체 후: 리마인드 2건 (PAYC- + 회원 소유 LINK-) · 비회원 LINK- 는 없음 · 어드민에게 가는 알림 0" "2|0" "$r1|$($P -c "select count(*) from public.notifications where user_id='$SU'")"
ok "회원 소유 LINK- 리마인드 본문에 매장·시각" "1" "$($P -c "select count(*) from public.notifications where user_id='$M' and body like '마츠카와 · 18:00%'")"
$P -c "delete from public.tickets where purchase_id='PAYC-ccc'" >/dev/null
ok "시작일: PAYC- 없이 회원 소유 LINK- 만 있어도 첫 구매로 센다 (started=true · start_kind purchase)" "true|purchase" "$($P -c "set taam.uid='$M'; select (j->>'started')||'|'||(j->>'start_kind') from public.taam_member_start('$M') j")"
$P -c "update public.tickets set extra_data='{\"linkInvite\":true}' where purchase_id='LINK-aaa'" >/dev/null
ok "memberUid 를 지우면 다시 비회원 행 — started=false" "false" "$($P -c "set taam.uid='$M'; select (public.taam_member_start('$M')->>'started')")"
# md5 가드 — 두 번째 RUN 은 본문이 이미 바뀌어 저장소 원본과 다르다 → ❌ 건너뜀 (덮어쓰지 않음)
out2=$($P -f supabase/migrations/20261019_member_link_rows.sql 2>&1)
ok "두 번째 RUN: 라이브 본문이 원본과 다르니 둘 다 ❌ 건너뜀 · ②③ 은 ✅ 그대로" "2|2" "$(echo "$out2" | grep -c '❌ 라이브 본문이')|$(echo "$out2" | grep -cE '^ *[②③].*✅')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
