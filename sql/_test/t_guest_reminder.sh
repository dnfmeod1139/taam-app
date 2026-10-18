#!/bin/bash
# 비회원 리마인드(알림톡) 대상·기록 회귀 — 2026-10-19. 먼저: 로컬 pg. 실행: bash sql/_test/t_guest_reminder.sh
cd "$(dirname "$0")/../.."
DB=t_grem; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=a1000000-0000-4000-8000-000000000011; SU=a1000000-0000-4000-8000-000000000001
D1=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 1, 'YYYY.MM.DD')"); D3=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 3, 'YYYY.MM.DD')"); D5=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 5, 'YYYY.MM.DD')")
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable as \$\$ select uid = '$SU'::uuid \$\$;
create table public.profiles(id uuid primary key, notif_prefs jsonb default '{}'::jsonb);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_name text, reservation_date text, visit_time text, party_size int, buyer_name text, buyer_phone text, status text, purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
grant usage on schema public to authenticated, anon, service_role;
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P -f sql/visit_reminder.sql >/dev/null 2>&1
out=$($P -f supabase/migrations/20261019_guest_reminder.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
$P -c "insert into public.tickets(user_id, restaurant_name, reservation_date, visit_time, party_size, buyer_name, buyer_phone, status, purchase_id, extra_data) values
  ('$SU','마츠카와','$D1','18:00',2,'Joy','010-1234-5678','active','LINK-g1','{\"linkInvite\":true}'),
  ('$SU','사이토','$D3','12:00',1,'수동손님','01099990000','manual','MAN-g2','{\"manualEntry\":true}'),
  ('$M','카타오리','$D1','19:00',2,'회원','010-5555-6666','active','LINK-g3','{\"linkInvite\":true,\"memberUid\":\"$M\"}'),
  ('$M','회원매장','$D1','19:00',2,'회원','010-5555-6666','active','PAYC-g4','{}'),
  ('$SU','번호없음','$D1','18:00',1,'없음','','active','LINK-g5','{\"linkInvite\":true}'),
  ('$SU','짧은번호','$D1','18:00',1,'짧음','12345','active','LINK-g6','{\"linkInvite\":true}'),
  ('$SU','5일뒤','$D5','18:00',1,'아직','010-7777-8888','active','LINK-g7','{\"linkInvite\":true}'),
  ('$SU','취소','$D1','18:00',1,'취소','010-7777-8888','cancelled','LINK-g8','{\"linkInvite\":true}'),
  ('$SU','정산','$D1','18:00',1,'정산','010-7777-8888','active','KSK-g9','{\"kashikiri\":true}'),
  ('$SU','해외','$D1','18:00',1,'Foreign','+1 415 555 0100','active','LINK-g10','{\"linkInvite\":true}')" >/dev/null
S="set taam.uid=''; set taam.super='0';"
ok "서버(SQL Editor) 호출: 대상 3건 — 비회원 LINK- 내일 · MAN- 3일 전 · 해외 번호(skip 은 Edge 가 적는다) / 회원 LINK-·PAYC-·번호 없음·짧은 번호·5일 뒤·취소·KSK- 는 아님" "3|LINK-g1,LINK-g10,MAN-g2" \
   "$($P -c "$S select count(*) from public.taam_guest_reminder_targets()")|$($P -c "$S select string_agg(j->>'purchase_id', ',' order by (j->>'d')::int, j->>'purchase_id') from public.taam_guest_reminder_targets() j")"
ok "행 내용: 이름·번호(숫자만)·매장·날짜·시각·인원·d" "Joy|01012345678|마츠카와|$D1|18:00|2|1" "$($P -c "$S select (j->>'name')||'|'||(j->>'phone')||'|'||(j->>'rest')||'|'||(j->>'date')||'|'||(j->>'vtime')||'|'||(j->>'pax')||'|'||(j->>'d') from public.taam_guest_reminder_targets() j where j->>'purchase_id'='LINK-g1'")"
T1=$($P -c "select id from public.tickets where purchase_id='LINK-g1'")
$P -c "$S select public.taam_guest_reminder_mark('$T1', 1, 'sent', '1012345678')" >/dev/null
ok "기록 뒤 같은 (티켓, d) 는 대상에서 빠진다 · 기록 1줄" "2|1|sent" "$($P -c "$S select count(*) from public.taam_guest_reminder_targets()")|$($P -c "select count(*) from public.guest_remind_log")|$($P -c "select result from public.guest_remind_log where ticket_id='$T1'")"
$P -c "$S select public.taam_guest_reminder_mark('$T1', 1, 'fail(http 500)')" >/dev/null
ok "같은 열쇠 다시 mark → 결과 갱신(upsert) · 줄 수 그대로" "fail(http 500)|1|1012345678" "$($P -c "select result||'|'||(select count(*) from public.guest_remind_log)||'|'||phone_key from public.guest_remind_log where ticket_id='$T1'")"
ok "회원 세션 → FORBIDDEN · 슈퍼어드민 → 통과 · anon(uid 없음·role anon) → FORBIDDEN" "1|2|1" "$($P -c "set taam.uid='$M'; select count(*) from public.taam_guest_reminder_targets()" 2>&1 | grep -c FORBIDDEN)|$($P -c "set taam.uid='$SU'; select count(*) from public.taam_guest_reminder_targets()")|$($P -c "set taam.uid=''; set role anon; set request.jwt.claims='{\"role\":\"anon\"}'; select count(*) from public.taam_guest_reminder_targets()" 2>&1 | grep -c 'FORBIDDEN\|permission denied')"
ok "service_role JWT 클레임 → 통과" "2" "$($P -c "set taam.uid=''; set request.jwt.claims='{\"role\":\"service_role\"}'; select count(*) from public.taam_guest_reminder_targets()")"
ok "회원이 되면(memberUid 가 적히면) 비회원 리마인드 대상에서 빠진다" "1" "$($P -c "update public.tickets set extra_data = extra_data || '{\"memberUid\":\"$M\"}' where purchase_id='LINK-g10'; $S select count(*) from public.taam_guest_reminder_targets()")"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
