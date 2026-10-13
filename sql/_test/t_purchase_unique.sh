#!/usr/bin/env bash
# 중복 구매·같은 시간대 차단 회귀 (2026-10-13) — supabase/migrations/20261014_purchase_uniqueness.sql
# 로컬 Postgres: psql -h /tmp -U postgres (trust). 실행: bash sql/_test/t_purchase_unique.sh
cd "$(dirname "$0")/../.."
PSQL="psql -h /tmp -U postgres -X -q"
$PSQL -c "drop database if exists t_pu" >/dev/null 2>&1; $PSQL -c "create database t_pu" >/dev/null
P="$PSQL -d t_pu -At"
M=11111111-1111-1111-1111-111111111111; N=22222222-2222-2222-2222-222222222222; L=33333333-3333-3333-3333-333333333333; A=99999999-9999-9999-9999-999999999999; F=44444444-4444-4444-4444-444444444444
$P <<SQL
create schema if not exists auth;
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create table public.profiles(id uuid primary key, display_name text);
create table public.ticket_products(id text primary key, rest_id text, rest_name text, date text, time text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, reservation_date text, visit_time text, party_size int default 2, price bigint default 0, status text default 'hold', purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
insert into public.profiles values ('$M','회원M'),('$N','회원N'),('$L','옛중복L'),('$A','어드민'),('$F','회원F');
grant usage on schema public, auth to authenticated; grant all on all tables in schema public to authenticated;
insert into public.ticket_products values
 ('tp-a','r1','카타오리','2027.05.21','19:00'), ('tp-b','r2','다른매장','2027.05.21','18:30'), ('tp-c','r2','다른매장','2027.05.21','12:00'),
 ('tp-d','r2','다른매장','2027.05.22','19:00'), ('tp-e','r1','카타오리','2027.05.21','12:00'), ('tp-f','r3','시간없는매장','2027.05.21',''),
 ('tp-g','r4','옛매장','2027.06.01','19:00'), ('tp-h','r5','폴백매장','2027.05.21','20:00'), ('tp-i','r6','형식매장','2027.05.21','19:30');
SQL
out=$($P -f supabase/migrations/20261014_purchase_uniqueness.sql 2>&1)
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
# ins uid tp date time pid [status] [extra] [rest_name]  → OK | DUPLICATE_PURCHASE | TIME_CONFLICT | ERROR:…
ins(){ o=$($P -c "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, status, purchase_id, extra_data) values ('$1', (select rest_id from ticket_products where id='$2'), '${8:-매장}', nullif('$2',''), nullif('$3',''), nullif('$4',''), '${6:-hold}', '$5', '${7:-{\}}'::jsonb);" 2>&1); cls "$o"; }
cls(){ if echo "$1" | grep -q DUPLICATE_PURCHASE; then echo DUPLICATE_PURCHASE; elif echo "$1" | grep -q TIME_CONFLICT; then echo TIME_CONFLICT; elif echo "$1" | grep -q ERROR; then echo "ERROR:$(echo "$1" | head -1 | cut -c1-90)"; else echo OK; fi; }
upd(){ o=$($P -c "update public.tickets set $1 where purchase_id='$2';" 2>&1); cls "$o"; }
echo "── ① 같은 회차 중복"
ok "첫 홀드 (M · 카타오리 5/21 19:00) → OK" "OK" "$(ins $M tp-a 2027.5.21 19:00 PAYH-1)"
ok "같은 회차 두 번째 홀드 → 막힘" "DUPLICATE_PURCHASE" "$(ins $M tp-a 2027.5.21 19:00 PAYH-2)"
ok "같은 회차 확정 행 직접 INSERT(postgres = service_role 과 같은 호출자) → 막힘" "DUPLICATE_PURCHASE" "$(ins $M tp-a 2027.5.21 19:00 PAYC-3 active)"
ok "내 홀드 → active (같은 행 갱신) → OK" "OK" "$(upd "status='active', price=700000" PAYH-1)"
ok "확정 뒤에도 같은 회차 → 막힘" "DUPLICATE_PURCHASE" "$(ins $M tp-a 2027.5.21 19:00 PAYH-4)"
ok "내 확정 행의 purchase_id 를 그대로 적은 두 번째 홀드 → 막힘 (리뷰 #3)" "DUPLICATE_PURCHASE" "$(ins $M tp-a 2027.5.21 19:00 PAYH-1)"
# 회원 세션(authenticated)이 남의 user_id 로 넣으면 이 가드는 보지 않는다 — 라이브에선 바로 뒤 소유권 가드가 42501 로 끊는다 (리뷰 #2: 문구 유출 차단)
mem(){ o=$($P -c "set local taam.uid='$1'; set local taam.super='0'; set local role authenticated; insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, status, purchase_id) values ('$2', 'r1', '매장', '$3', '$4', '$5', 'hold', '$6');" 2>&1); cls "$o"; }
ok "회원 N 세션이 M 의 user_id 로 같은 회차 → 이 가드는 침묵(OK · 문구에 M 의 예약이 실리지 않음)" "OK" "$(mem $N $M tp-a 2027.5.21 19:00 PAYH-X1)"
$P -c "delete from public.tickets where purchase_id='PAYH-X1'" >/dev/null
ok "회원 M 세션이 자기 user_id 로 같은 회차 → 막힘" "DUPLICATE_PURCHASE" "$(mem $M $M tp-a 2027.5.21 19:00 PAYH-X2)"
ok "회원 N 세션이 M 의 user_id 로 같은 날 다른 매장 저녁 → 침묵(OK)" "OK" "$(mem $N $M tp-b 2027.5.21 18:30 PAYH-X3)"
$P -c "delete from public.tickets where purchase_id='PAYH-X3'" >/dev/null
echo "── ② 같은 날 같은 시간대"
ok "같은 날 다른 매장 저녁(18:30) → 막힘" "TIME_CONFLICT" "$(ins $M tp-b 2027.5.21 18:30 PAYH-5)"
ok "같은 매장 같은 날 점심(12:00, 다른 회차) → OK (시간대 다름)" "OK" "$(ins $M tp-e 2027.5.21 12:00 PAYH-6)"
ok "같은 날 다른 매장 점심(12:00) → 막힘 (점심이 이미 있음)" "TIME_CONFLICT" "$(ins $M tp-c 2027.5.21 12:00 PAYH-7)"
ok "다음 날(5/22) 저녁 → OK" "OK" "$(ins $M tp-d 2027.5.22 19:00 PAYH-8)"
ok "점심 회차 취소 뒤 다른 매장 점심 → OK·OK" "OK|OK" "$(upd "status='cancelled'" PAYH-6)|$(ins $M tp-c 2027.5.21 12:00 PAYH-9)" 
echo "── ③ 시각 모름 · 폴백 · 날짜 형식"
ok "다른 회원 N: 카타오리 5/21 19:00 → OK" "OK" "$(ins $N tp-a 2027.5.21 19:00 PAYH-10)"
ok "N: 같은 날 시각 없는 회차(tp-f) → 막힘 (모르면 겹침으로)" "TIME_CONFLICT" "$(ins $N tp-f 2027.5.21 '' PAYH-11)"
ok "M: toss-confirm 폴백 모양(날짜·시각 null, 회차만) 5/21 20:00 매장 → 막힘 (회차에서 보충)" "TIME_CONFLICT" "$(ins $M tp-h '' '' PAYC-12 active)"
ok "M: 날짜 '2027.05.21' 표기 다른 매장 19:30 → 막힘" "TIME_CONFLICT" "$(ins $M tp-i 2027.05.21 19:30 PAYH-13)"
ok "M: 날짜 '2027-05-21' 표기 → 막힘" "TIME_CONFLICT" "$(ins $M tp-i 2027-05-21 19:30 PAYH-14)"
ok "회차·날짜 모두 없는 옛 행 → OK (셀 수 없음)" "OK" "$(ins $M '' '' '' OLD-15 active)"
ok "M: 삭제된 회차 id + 시각 '' + 5/21 → 막힘 (회차가 없어도 읽은 날짜를 지우지 않는다 · 리뷰 #4)" "TIME_CONFLICT" "$(ins $M tp-deleted 2027.5.21 '' PAYH-15b)"
echo "── ④ 운영 행은 제외"
ok "어드민 A: KSK- 두 건 같은 회차 → OK·OK" "OK|OK" "$(ins $A tp-a 2027.5.21 19:00 KSK-16 active '{"kashikiri":true}')|$(ins $A tp-a 2027.5.21 19:00 KSK-17 active '{"kashikiri":true}')"
ok "어드민 A: LINK- 홀드 · INVH- 홀드 같은 회차 → OK·OK" "OK|OK" "$(ins $A tp-a 2027.5.21 19:00 LINK-18 hold '{"linkInvite":true}')|$(ins $A tp-a 2027.5.21 19:00 INVH-19 hold '{"inviteHold":true}')"
ok "M 에게 MAN- 수동 추가(같은 회차) → OK (운영 행)" "OK" "$(ins $M tp-a 2027.5.21 19:00 MAN-20 manual '{"manualEntry":true}')"
echo "── ⑤ 초대 확정 — 소유자가 초대받은 회원으로 바뀌는 UPDATE"
ok "INVH- 홀드 → INV- 확정 · 소유자 M(이미 같은 회차 보유) → 막힘" "DUPLICATE_PURCHASE" "$(upd "status='active', purchase_id='INV-19', user_id='$M', extra_data='{\"inviteHold\":false,\"invitePaid\":true}'" INVH-19)"
ok "같은 확정 · 소유자 F(처음) → OK" "OK" "$(upd "status='active', purchase_id='INV-19', user_id='$F', extra_data='{\"inviteHold\":false,\"invitePaid\":true}'" INVH-19)"
ok "F: 이제 같은 회차 홀드 → 막힘 (INV- 는 회원 것)" "DUPLICATE_PURCHASE" "$(ins $F tp-a 2027.5.21 19:00 PAYH-21)"
echo "── ⑥ 이미 들어 있는 중복은 건드리지 않는다"
$P -c "alter table public.tickets disable trigger trg_taam_guard_ticket_unique" >/dev/null
ok "옛 중복 두 건 넣기(트리거 끔) → OK·OK" "OK|OK" "$(ins $L tp-g 2027.6.1 19:00 PAY-22 active)|$(ins $L tp-g 2027.6.1 19:00 PAY-23 active)"
$P -c "alter table public.tickets enable trigger trg_taam_guard_ticket_unique" >/dev/null
ok "옛 중복 행 출석 처리(status attended) → OK" "OK" "$(upd "status='attended'" PAY-23)"
ok "옛 중복 행 금액 보정 → OK" "OK" "$(upd "price=1" PAY-22)"
ok "옛 중복 행 취소 → OK" "OK" "$(upd "status='cancelled'" PAY-22)"
ok "취소한 것을 되살리면(cancelled→active) → 막힘" "DUPLICATE_PURCHASE" "$(upd "status='active'" PAY-22)"
ok "L: 같은 회차 새 홀드 → 막힘" "DUPLICATE_PURCHASE" "$(ins $L tp-g 2027.6.1 19:00 PAYH-24)"
$P -c "update public.tickets set status='active' where purchase_id='PAY-22'" >/dev/null 2>&1   # (막혔으므로 아직 cancelled)
$P -c "alter table public.tickets disable trigger trg_taam_guard_ticket_unique; update public.tickets set status='active' where purchase_id='PAY-22'; alter table public.tickets enable trigger trg_taam_guard_ticket_unique" >/dev/null
ok "옛 중복 행의 시각만 변경(19:00→19:30) → OK (리뷰 #6/#13)" "OK" "$(upd "visit_time='19:30'" PAY-23)"
ok "옛 중복 행을 같은 시간대 안 다른 시각으로(18:00) → OK" "OK" "$(upd "visit_time='18:00'" PAY-22)"
ok "옛 중복 행을 다른 날짜로 옮겨 새 겹침(L 의 5/21 저녁은 없음) → OK" "OK" "$(upd "reservation_date='2027.6.2'" PAY-22)"
$P -c "alter table public.tickets disable trigger trg_taam_guard_ticket_unique; insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, status, purchase_id) values ('$L','r9','겹침매장','tp-z','2027.6.3','19:00','active','PAY-26'); alter table public.tickets enable trigger trg_taam_guard_ticket_unique" >/dev/null
ok "옛 중복 행을 6/3 로 옮기면 L 의 6/3 저녁과 새 겹침 → 막힘" "TIME_CONFLICT" "$(upd "reservation_date='2027.6.3'" PAY-22)"
echo "── ⑦ 취소 뒤 재구매"
$P -c "update public.tickets set status='cancelled' where user_id='$M'" >/dev/null
ok "M 의 티켓을 전부 취소하면 카타오리 5/21 다시 → OK" "OK" "$(ins $M tp-a 2027.5.21 19:00 PAYH-25)"
ok "트리거 이름이 소유권·등급 가드 뒤에 온다 (ticket_unique > ticket_tier)" "t" "$($P -c "select 'trg_taam_guard_ticket_unique' > 'trg_taam_guard_ticket_tier' and 'trg_taam_guard_ticket_unique' > 'trg_taam_guard_invite_owner'")"
ok "라이브 taam_visit_date 는 만들지도 덮지도 않는다" "0" "$($P -c "select count(*) from pg_proc where proname='taam_visit_date'")"
# 마이그레이션은 여러 번 돌려도 안전하다 — 다시 돌려 확인 표가 그대로 ❌ 0 이고 ⑤ 가 수를 세는지 본다 (L 의 중복은 위에서 하나를 취소했다)
out2=$($P -f supabase/migrations/20261014_purchase_uniqueness.sql 2>&1)
ok "재실행: 오류 없음 · ❌ 0 · ⑤ 는 '1쌍'(L 의 PAY-22·23)" "|0|1쌍" "$(echo "$out2" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep '⑤' | grep -o '✅ [0-9]*쌍' | head -1 | sed 's/^✅ //')"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
