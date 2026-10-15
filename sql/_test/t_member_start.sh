#!/bin/bash
# 회원 시작일 RPC 회귀 — 2026-10-13 (+ 2026-10-15 실제 멤버십 가입일·가드·시드). 먼저: 로컬 pg. 실행: bash sql/_test/t_member_start.sh
cd "$(dirname "$0")/../.."
DB=t_mstart; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
A=a1000000-0000-4000-8000-000000000011; B=a1000000-0000-4000-8000-000000000012; C=a1000000-0000-4000-8000-000000000013; D=a1000000-0000-4000-8000-000000000014; SU=a1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create table public.profiles(id uuid primary key, created_at timestamptz default now(), display_name text, role text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, party_size int, status text, purchase_id text, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now(), paid_at timestamptz);
create table public.deposit_transactions(id bigserial primary key, user_id uuid, change_type text, amount int, created_at timestamptz default now());
insert into auth.users values ('$A'),('$B'),('$C'),('$D'),('$SU');
insert into public.profiles(id, created_at, display_name) values
  ('$A','2026-01-10','가입만'), ('$B','2026-02-01','초대먼저'), ('$C','2026-03-01','구매먼저'), ('$D','2026-04-01','홀드만'), ('$SU','2025-01-01','슈퍼');
-- B: 초대(paid) 2026-05-01 가 구매 2026-06-01 보다 빠르다 · 취소된 구매 2026-04-15 는 안 센다
insert into public.reservation_invites(invitee_user_id, status, created_at, paid_at) values ('$B','paid','2026-05-01','2026-05-03'), ('$B','cancelled','2026-04-01',null);
insert into public.tickets(user_id, party_size, status, purchase_id, created_at) values
  ('$B',2,'cancelled','PAY-x','2026-04-15'), ('$B',2,'active','INV-abc','2026-05-01'), ('$B',2,'active','PAY-y','2026-06-01'),
  ('$C',1,'active','PAY-c1','2026-07-10'), ('$C',1,'active','INV-c2','2026-08-10'),
  ('$D',1,'hold','PAYH-d','2026-09-01'), ('$D',1,'active','MAN-d','2026-09-02'), ('$D',1,'active','KSK-d','2026-09-03');
-- C: 옛 원장 줄이 tickets 보다 빠르다(2026-06-20) → 첫 구매는 원장 기준
insert into public.deposit_transactions(user_id, change_type, amount, created_at) values ('$C','ticket_purchase',-100,'2026-06-20'), ('$C','admin_grant',100,'2026-05-20');
grant usage on schema public to authenticated; grant all on all tables in schema public to authenticated; grant usage on schema auth to authenticated;
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
out=$($P -f supabase/migrations/20261013_member_start.sql 2>&1)
ok "마이그레이션 오류 없음 · ✅ 2 · ❌ 0" "|2|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '❌')"
q(){ $P -c "set local taam.uid='$1'; set local taam.super='$2'; select public.taam_member_start($3)->>'$4';" 2>&1 | tail -1; }
ok "A 가입만 → 시작 전 (started false · start null)" "false|" "$(q $A 0 null started)|$(q $A 0 null start_at)"
ok "B 초대가 먼저 → start=초대일 2026-05-01 · kind invite" "2026-05-01T00:00:00+00:00|invite" "$(q $B 0 null start_at)|$(q $B 0 null start_kind)"
ok "B 첫 구매는 취소 제외 → 2026-05-01(INV 행) · 가입일 2026-02-01" "2026-05-01T00:00:00+00:00|2026-02-01T00:00:00+00:00" "$(q $B 0 null first_purchase_at)|$(q $B 0 null signup_at)"
ok "C 옛 원장 줄이 더 빠름 → 2026-06-20 · kind purchase · year_end 2027-06-20" "2026-06-20T00:00:00+00:00|purchase|2027-06-20T00:00:00+00:00" "$(q $C 0 null start_at)|$(q $C 0 null start_kind)|$(q $C 0 null year_end_at)"
ok "D 홀드·MAN-·KSK- 만 → 시작 전" "false" "$(q $D 0 null started)"
ok "남의 것: 회원은 거부, 슈퍼어드민은 허용" "ERROR|true" "$($P -c "set local taam.uid='$A'; set local taam.super='0'; select public.taam_member_start('$B');" 2>&1 | grep -oE "ERROR|권한" | head -1)|$(q $SU 1 "'$B'" started)"
ok "p_uid 생략 = 본인" "2026-05-01T00:00:00+00:00" "$(q $B 0 null start_at)"
echo "── 2026-10-15 실제 멤버십 가입일 (2차 마이그레이션)"
out2=$($P -f supabase/migrations/20261015_membership_joined.sql 2>&1)
ok "2차 마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out2" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '❌')"
ok "A: 실제 가입일 없음 → joined_at = 앱 가입일(KST) · kind app · membership_joined_at null" "2026-01-10|app|2026-01-10|" "$(q $A 0 null joined_at)|$(q $A 0 null joined_kind)|$(q $A 0 null app_signup_date)|$(q $A 0 null membership_joined_at)"
ok "B: 옛 키(start_at·start_kind) 그대로" "2026-05-01T00:00:00+00:00|invite" "$(q $B 0 null start_at)|$(q $B 0 null start_kind)"
# 회원이 자기 칸을 적으려 하면 → 되돌림(예외 없음)
$P -c "set local taam.uid='$A'; set local taam.super='0'; set local role authenticated; update public.profiles set membership_joined_at='2024-12-05', display_name='가입만2' where id='$A';" >/dev/null 2>&1
ok "회원이 자기 실제 가입일을 적으면 → 되돌림 · 같은 UPDATE 의 다른 칸(display_name)은 반영" "|가입만2" "$($P -c "select coalesce(membership_joined_at::text,'')||'|'||display_name from public.profiles where id='$A'")"
# 슈퍼어드민이 적으면 → 날짜 + 누가·언제
$P -c "set local taam.uid='$SU'; set local taam.super='1'; set local role authenticated; update public.profiles set membership_joined_at='2024-12-05' where id='$A';" >/dev/null 2>&1
ok "슈퍼어드민이 적음 → joined_at 2024-12-05 · kind manual · set_by 슈퍼 · set_at 있음" "2024-12-05|manual|$SU|true" "$(q $A 0 null joined_at)|$(q $A 0 null joined_kind)|$($P -c "select membership_joined_set_by::text||'|'||(membership_joined_set_at is not null) from public.profiles where id='$A'")"
$P -c "set local taam.uid='$A'; set local taam.super='0'; set local role authenticated; update public.profiles set membership_joined_at='2020-01-01' where id='$A';" >/dev/null 2>&1
ok "회원이 바꾸려 하면 → 그대로 2024-12-05 · set_by 도 그대로" "2024-12-05|$SU" "$($P -c "select membership_joined_at::text||'|'||membership_joined_set_by::text from public.profiles where id='$A'")"
$P -c "set local taam.uid='$SU'; set local taam.super='1'; set local role authenticated; update public.profiles set display_name='가입만3', membership_joined_set_by='$B', membership_joined_set_at=null where id='$A';" >/dev/null 2>&1
ok "날짜가 그대로인 UPDATE 는 set_by/set_at 를 못 건드림" "$SU|true|가입만3" "$($P -c "select membership_joined_set_by::text||'|'||(membership_joined_set_at is not null)||'|'||display_name from public.profiles where id='$A'")"
ok "미래 날짜 → BAD_JOINED_DATE" "BAD_JOINED_DATE" "$($P -c "set local taam.uid='$SU'; set local taam.super='1'; set local role authenticated; update public.profiles set membership_joined_at='2030-01-01' where id='$A';" 2>&1 | grep -oE "BAD_JOINED_DATE" | head -1)"
ok "2015 년 전 → BAD_JOINED_DATE" "BAD_JOINED_DATE" "$($P -c "set local taam.uid='$SU'; set local taam.super='1'; set local role authenticated; update public.profiles set membership_joined_at='2014-12-31' where id='$A';" 2>&1 | grep -oE "BAD_JOINED_DATE" | head -1)"
E=a1000000-0000-4000-8000-000000000015
$P -c "set local taam.uid='$E'; set local taam.super='0'; set local role authenticated; insert into public.profiles(id, created_at, display_name, membership_joined_at) values ('$E','2026-05-01','새회원','2020-01-01');" >/dev/null 2>&1
ok "회원 가입 INSERT 에 실제 가입일을 실어도 → null" "|새회원" "$($P -c "select coalesce(membership_joined_at::text,'')||'|'||display_name from public.profiles where id='$E'")"
$P -c "set local taam.uid='$SU'; set local taam.super='1'; set local role authenticated; update public.profiles set membership_joined_at=null where id='$A';" >/dev/null 2>&1
ok "슈퍼어드민이 지우면 → joined_at 은 앱 가입일로 · kind app · 지운 기록(set_by 슈퍼)" "2026-01-10|app|$SU" "$(q $A 0 null joined_at)|$(q $A 0 null joined_kind)|$($P -c "select membership_joined_set_by::text from public.profiles where id='$A'")"
echo "── 시드 (이름으로 맞춘다)"
$P -c "insert into public.profiles(id, created_at, display_name) values (gen_random_uuid(),'2026-01-11','이지형'), (gen_random_uuid(),'2026-01-12','김지훈'), (gen_random_uuid(),'2026-01-13','김 지훈 ');" >/dev/null
seed=$($P -f sql/membership_joined_seed_2026-10-15.sql 2>&1)
ok "시드: 이지형 ✅ · 김지훈(2명) ⚠ · 임태규 ❌ · 오류 없음" "✅|⚠|❌|" "$(echo "$seed" | grep '^이지형' | cut -d'|' -f3 | grep -oE '^(✅|⚠|❌|＝)')|$(echo "$seed" | grep '^김지훈' | cut -d'|' -f3 | grep -oE '^(✅|⚠|❌|＝)')|$(echo "$seed" | grep '^임태규' | cut -d'|' -f3 | grep -oE '^(✅|⚠|❌|＝)')|$(echo "$seed" | grep -E '^ERROR|^psql:.*ERROR' | head -1)"
ok "시드 뒤 이지형 2024-12-05 · 김지훈 둘 다 비어 있음" "2024-12-05|0" "$($P -c "select membership_joined_at::text from public.profiles where display_name='이지형'")|$($P -c "select count(*) from public.profiles where regexp_replace(display_name,'\s','','g')='김지훈' and membership_joined_at is not null")"
ok "시드 두 번 돌리면 이지형은 ＝ 이미 같음" "＝" "$($P -f sql/membership_joined_seed_2026-10-15.sql 2>&1 | grep '^이지형' | cut -d'|' -f3 | grep -oE '^(✅|⚠|❌|＝)')"
ok "시드 결과 행 수 = 목록 22" "22" "$($P -f sql/membership_joined_seed_2026-10-15.sql 2>&1 | grep -cE '^[가-힣]+\|')"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
