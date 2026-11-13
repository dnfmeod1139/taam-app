#!/bin/bash
# 취소표 알림 끄기 회귀 — 2026-11-13. 먼저: 로컬 pg. 실행: bash sql/_test/t_restock_mute.sh
#   실제 20260929_ticket_restock.sql + sync_ticket_soldout v4 위에 20261113_restock_mute.sql 을 올리고,
#   「끔」이 살아 있는 동안 풀린 좌석은 이벤트가 skipped·MUTED 로 남아 알림이 안 가는지, 닫은 뒤·만료 뒤·다른 회차는 종전대로인지,
#   쿨다운에 안 걸리는지, 회원은 못 부르는지 본다.
cd "$(dirname "$0")/../.."
DB=${TAAM_TEST_DB:-t_restock_mute}; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; M1=a1000000-0000-4000-8000-000000000011; M2=a1000000-0000-4000-8000-000000000012
REST=b1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if; end \$\$;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
-- 라이브 본문 그대로(2026-11-13 md5 128d1f7b…)
create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable security definer set search_path = public as \$f\$
begin
  if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if;
  return session_user = 'postgres'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then
  return false;
end \$f\$;
create table public.profiles(id uuid primary key, role text, membership_tier text, notif_prefs jsonb not null default '{}'::jsonb, deleted_at timestamptz, display_name text);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, total_pax int, slots jsonb, status text default 'active',
  min_tier text default '', sale_state text, sale_open_at text, auto_soldout boolean not null default true);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, ticket_product_id text, party_size int, status text, purchase_id text, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, seen boolean default false, created_at timestamptz default now());
create table public.app_config(key text primary key, value jsonb, updated_at timestamptz default now());
create or replace function public.taam_ticket_visible(p text, u uuid) returns boolean language sql stable as \$\$ select true \$\$;
create or replace function public.taam_tier_rank(p text) returns int language sql immutable as \$\$ select case upper(coalesce(p,'')) when 'M' then 3 when 'T' then 2 when 'A' then 1 else 0 end \$\$;
create or replace function public.taam_tier_is_open(p text) returns boolean language sql immutable as \$\$ select upper(coalesce(p,'')) = 'A' \$\$;
create or replace function public.taam_user_tier(p uuid) returns text language sql stable as \$\$ select membership_tier from public.profiles where id = p \$\$;
insert into auth.users values ('$SU'),('$M1'),('$M2'),('a1000000-0000-4000-8000-000000000002');
insert into public.profiles(id, role, membership_tier) values ('$SU','super_admin','M'), ('a1000000-0000-4000-8000-000000000002','super_admin','M'), ('$M1','member','M'), ('$M2','member','M');
SQL
S0=$(grep -n "create or replace function public.taam_visit_date" sql/visit_reminder.sql | cut -d: -f1); E0=$(grep -n "create or replace function public.taam_visit_reminder_notify" sql/visit_reminder.sql | cut -d: -f1)
sed -n "${S0},$((E0-1))p" sql/visit_reminder.sql | $P >/dev/null 2>&1
S1=$(grep -n "create or replace function public.taam_seat_fillable" sql/ticket_capacity_guard.sql | cut -d: -f1); E1=$(awk -v s=$S1 'NR>s && /^\$\$;/ {print NR; exit}' sql/ticket_capacity_guard.sql)
sed -n "${S1},${E1}p" sql/ticket_capacity_guard.sql | $P >/dev/null 2>&1
S2=$(grep -n "create or replace function public.sync_ticket_soldout" sql/seat_hold_repair.sql | cut -d: -f1); E2=$(grep -n "execute function public.sync_ticket_soldout();" sql/seat_hold_repair.sql | cut -d: -f1)
sed -n "${S2},${E2}p" sql/seat_hold_repair.sql | $P >/dev/null 2>&1
$P -f supabase/migrations/20260929_ticket_restock.sql >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "픽스처: 취소표 함수·트리거 올라감" "1|1" "$($P -c "select count(*) from pg_trigger where tgname='trg_ticket_restock'")|$($P -c "select count(*) from pg_proc where proname='taam_ticket_restock_process'")"

# 연계 회차 건너뛰기 흉내(라이브 trg_taam_restock_skip_package 와 같은 모양 — 회차 'pkg' 만)
$P <<'SQL' >/dev/null
create or replace function public.taam_restock_skip_package() returns trigger language plpgsql as $b$
begin if coalesce(new.status,'pending') = 'pending' and new.ticket_product_id = 'pkg' then return null; end if; return new; end $b$;
create trigger trg_taam_restock_skip_package before insert on public.ticket_restock_events for each row execute function public.taam_restock_skip_package();
SQL

out=$($P -f supabase/migrations/20261113_restock_mute.sql 2>&1)
ok "마이그레이션 오류 없음 · ✅ 5 · ❌ 0" "|5|0" "$(echo "$out" | grep -E "^ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '❌')"
ok "트리거 순서: 끔 검사가 연계 건너뛰기보다 먼저(이름 순)" "trg_taam_restock_mute,trg_taam_restock_skip_package" "$($P -c "select string_agg(tgname, ',' order by tgname) from pg_trigger where tgrelid='public.ticket_restock_events'::regclass and not tgisinternal")"

FUT=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 30, 'YYYY.MM.DD')")
fill(){ $P -c "insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','$1',$2,'$3','$4')" >/dev/null; }
cx(){ $P -c "update public.tickets set status='cancelled' where purchase_id='$1'" >/dev/null; }
st(){ $P -c "select status from public.ticket_products where id='$1'"; }
ev(){ $P -c "select coalesce(string_agg(status||':'||coalesce(reason,''), ',' order by id),'') from public.ticket_restock_events where ticket_product_id='$1'"; }
SUP="set taam.uid='$SU'; set taam.super='1';"
MEM="set taam.uid='$M2'; set taam.super='0';"
$P -c "insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,status) values ('tp1','$REST','미타니','$FUT','18:00',4,'active'),('tp2','$REST','시마즈','$FUT','19:00',2,'active'),('tp3','$REST','아마모토','$FUT','20:30',2,'active'),('pkg','$REST','패키지','$FUT','20:30',2,'active')" >/dev/null
fill tp1 2 manual MAN-a; fill tp1 2 active PAY-b
ok "① tp1 만석 → soldout" "soldout" "$(st tp1)"

echo "── ② 슈퍼어드민이 끄고 수동 좌석을 풂 → 이벤트 skipped·MUTED · 알림 0"
TOK=$($P -c "$SUP select (public.taam_restock_mute(array['tp1'], 5, '캘린더 × MAN-a'))->>'token'" | tail -1)
ok "끄기: 토큰 받음 · 끔 줄 1(5분 · 설정자 = 슈퍼어드민)" "1|1|1" "$([ -n "$TOK" ] && echo 1 || echo 0)|$($P -c "select count(*) from public.ticket_restock_mutes where token='$TOK' and until between now()+interval '4 minutes' and now()+interval '6 minutes'")|$($P -c "select count(*) from public.ticket_restock_mutes where token='$TOK' and set_by='$SU' and note='캘린더 × MAN-a'")"
cx MAN-a
ok "좌석은 풀림(active) · 이벤트 skipped:MUTED" "active|skipped:MUTED" "$(st tp1)|$(ev tp1)"
r=$($P -c "select (public.taam_ticket_restock_process())::text")
ok "처리할 것 없음 · 알림 0" "0|0" "$(echo "$r" | grep -c '"events": 1')|$($P -c "select count(*) from public.notifications")"
u=$($P -c "$SUP select (public.taam_restock_unmute('$TOK'))::text" | tail -1)
ok "닫기: cleared 1 · hits 1 · muted_ids [tp1]" "1|1|1" "$(echo "$u" | grep -c '"cleared": 1')|$(echo "$u" | grep -c '"hits": 1')|$(echo "$u" | grep -c '"muted_ids": \["tp1"\]')"
ok "다시 닫아도 cleared 0 · hits 그대로" "1|1" "$($P -c "$SUP select (public.taam_restock_unmute('$TOK'))::text" | tail -1 | grep -c '"cleared": 0')|$($P -c "$SUP select (public.taam_restock_unmute('$TOK'))->>'hits'" | tail -1)"

echo "── ③ 닫은 뒤 다시 매진 → 회원 취소: 알림 간다(skipped 줄은 60분 쿨다운에 안 든다)"
fill tp1 2 active PAY-c
ok "다시 soldout" "soldout" "$(st tp1)"
cx PAY-c
ok "이벤트 pending 생김" "skipped:MUTED,pending:" "$(ev tp1)"
r=$($P -c "select (public.taam_ticket_restock_process())::text")
ok "처리 1 · 알림 감(M2 + 슈퍼어드민 둘 — 보유자 M1 제외)" "1|3" "$(echo "$r" | grep -c '"events": 1')|$($P -c "select count(*) from public.notifications where type='ticket_restock'")"

echo "── ④ 다른 회차의 끔은 이 회차를 막지 않는다"
fill tp2 2 manual MAN-t2
T2=$($P -c "$SUP select (public.taam_restock_mute(array['tp3'], 5))->>'token'" | tail -1)
cx MAN-t2
ok "tp2 이벤트 pending" "pending:" "$(ev tp2)"
$P -c "$SUP select public.taam_restock_unmute('$T2')" >/dev/null

echo "── ⑤ 만료된 끔은 안 막는다"
fill tp3 2 manual MAN-t3
$P -c "insert into public.ticket_restock_mutes(token,ticket_product_id,until) values (gen_random_uuid(),'tp3', now() - interval '1 second')" >/dev/null
cx MAN-t3
ok "tp3 이벤트 pending" "pending:" "$(ev tp3)"

echo "── ⑥ 끔 두 개가 겹치면 하나를 닫아도 다른 것이 막는다"
$P -c "delete from public.ticket_restock_events where ticket_product_id='tp3'" >/dev/null
fill tp3 2 manual MAN-t3b
A=$($P -c "$SUP select (public.taam_restock_mute(array['tp3'], 5))->>'token'" | tail -1)
B=$($P -c "$SUP select (public.taam_restock_mute(array['tp3','tp2'], 5))->>'token'" | tail -1)
$P -c "$SUP select public.taam_restock_unmute('$A')" >/dev/null
cx MAN-t3b
ok "tp3 skipped:MUTED · B 의 hits 1 · A 의 hits 0" "skipped:MUTED|1|0" "$(ev tp3)|$($P -c "$SUP select (public.taam_restock_unmute('$B'))->>'hits'" | tail -1)|$($P -c "$SUP select (public.taam_restock_unmute('$A'))->>'hits'" | tail -1)"

echo "── ⑦ 한 트랜잭션(SQL Editor)에서 끄고 풀고 닫기"
$P -c "delete from public.ticket_restock_events where ticket_product_id='tp3'" >/dev/null
fill tp3 2 manual MAN-t3c
$P -c "do \$\$ declare t uuid; begin t := (public.taam_restock_mute(array['tp3']))->>'token'; update public.tickets set status='cancelled' where purchase_id='MAN-t3c'; end \$\$" >/dev/null
ok "커밋 때 끔이 아직 살아 있어 skipped:MUTED" "skipped:MUTED" "$(ev tp3)"

echo "── ⑧ 연계 회차: 끔이 먼저 돌아 skipped 줄이 남는다(알림은 어느 쪽이든 없음) · 끔 없으면 줄 없음(종전)"
fill pkg 2 manual MAN-p1
cx MAN-p1
ok "끔 없음 → 줄 없음" "" "$(ev pkg)"
fill pkg 2 manual MAN-p2
PK=$($P -c "$SUP select (public.taam_restock_mute(array['pkg']))->>'token'" | tail -1)
cx MAN-p2
ok "끔 있음 → skipped:MUTED (pending 아님)" "skipped:MUTED" "$(ev pkg)"

echo "── ⑨ 권한·입력"
ok "회원 세션 → FORBIDDEN" "1" "$($P -c "$MEM select public.taam_restock_mute(array['tp1'])" 2>&1 | grep -c FORBIDDEN)"
ok "회원 세션 닫기 → FORBIDDEN" "1" "$($P -c "$MEM select public.taam_restock_unmute('$PK')" 2>&1 | grep -c FORBIDDEN)"
ok "서버(service_role 클레임) 통과" "1" "$($P -c "set request.jwt.claims='{\"role\":\"service_role\"}'; set taam.uid=''; select (public.taam_restock_mute(array['tp1']))->>'ok'" | tail -1 | grep -c true)"
ok "이상한 id 만 → BAD_TICKET_IDS" "1" "$($P -c "$SUP select public.taam_restock_mute(array['<b>x', ''])" 2>&1 | grep -c BAD_TICKET_IDS)"
ok "21개 → TOO_MANY_TICKETS" "1" "$($P -c "$SUP select public.taam_restock_mute(array(select 't'||g from generate_series(1,21) g))" 2>&1 | grep -c TOO_MANY_TICKETS)"
ok "분은 1~30 으로 자름(999 → 30분)" "1" "$($P -c "$SUP select (public.taam_restock_mute(array['tp9'], 999))->>'minutes'" | tail -1 | grep -c '^30$')"
ok "anon 실행 권한 없음 · authenticated 있음" "f|t" "$($P -c "select has_function_privilege('anon','public.taam_restock_mute(text[],integer,text)','execute')")|$($P -c "select has_function_privilege('authenticated','public.taam_restock_mute(text[],integer,text)','execute')")"
ok "authenticated 는 끔 표에 직접 못 씀" "f|f" "$($P -c "select has_table_privilege('authenticated','public.ticket_restock_mutes','insert')")|$($P -c "select has_table_privilege('authenticated','public.ticket_restock_mutes','update')")"
ok "트리거 함수는 authenticated 가 못 부름" "f" "$($P -c "select has_function_privilege('authenticated','public.taam_restock_mute_check()','execute')")"

echo "── ⑪ 끈 사람의 풀기만 막는다 — 같은 때 회원이 자기 좌석을 풀면 종전대로 알림(검토)"
$P -c "delete from public.ticket_restock_events where ticket_product_id in ('tp2')" >/dev/null
$P -c "update public.tickets set status='cancelled' where ticket_product_id='tp2'" >/dev/null
$P -c "insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M2','tp2',1,'active','PAY-m2a'),('$M1','tp2',1,'manual','MAN-s1')" >/dev/null
ok "tp2 만석" "soldout" "$(st tp2)"
$P -c "delete from public.ticket_restock_events where ticket_product_id='tp2'" >/dev/null
W=$($P -c "$SUP select (public.taam_restock_mute(array['tp2'], 5))->>'token'" | tail -1)
$P -c "set taam.uid='$M2'; set taam.super='0'; update public.tickets set status='cancelled' where purchase_id='PAY-m2a'" >/dev/null
ok "끈 동안 회원 취소 → pending(알림 간다) · 끈 쪽 hits 0" "pending:|0" "$(ev tp2)|$($P -c "$SUP select (public.taam_restock_unmute('$W'))->>'hits'" | tail -1)"
$P -c "delete from public.ticket_restock_events where ticket_product_id='tp2'; insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M2','tp2',1,'active','PAY-m2b')" >/dev/null
ok "다시 만석" "soldout" "$(st tp2)"
W2=$($P -c "$SUP select (public.taam_restock_mute(array['tp2'], 5))->>'token'" | tail -1)
$P -c "$SUP update public.tickets set status='cancelled' where purchase_id='MAN-s1'" >/dev/null
ok "끈 슈퍼어드민 세션의 풀기 → skipped:MUTED · hits 1" "skipped:MUTED|1" "$(ev tp2)|$($P -c "$SUP select (public.taam_restock_unmute('$W2'))->>'hits'" | tail -1)"
# 다른 슈퍼어드민이 끈 것은 이 슈퍼어드민의 풀기를 막지 않는다(각자 고른다)
SU2=a1000000-0000-4000-8000-000000000002
$P -c "delete from public.ticket_restock_events where ticket_product_id='tp2'; insert into public.tickets(user_id,ticket_product_id,party_size,status,purchase_id) values ('$M1','tp2',1,'manual','MAN-s2')" >/dev/null
W3=$($P -c "set taam.uid='$SU2'; set taam.super='1'; select (public.taam_restock_mute(array['tp2'], 5))->>'token'" | tail -1)
$P -c "$SUP update public.tickets set status='cancelled' where purchase_id='MAN-s2'" >/dev/null
ok "다른 슈퍼어드민의 끔은 이 풀기를 막지 않는다 → pending" "pending:" "$(ev tp2)"
$P -c "$SUP select public.taam_restock_unmute('$W3')" >/dev/null

echo "── ⑫ 끔 줄이 잠겨 있어도 풀기 커밋은 기다리지 않는다(skip locked)"
$P -c "delete from public.ticket_restock_events where ticket_product_id='tp3'" >/dev/null
fill tp3 2 manual MAN-lk
L=$($P -c "$SUP select (public.taam_restock_mute(array['tp3'], 5))->>'token'" | tail -1)
( $P -c "begin; select id from public.ticket_restock_mutes where token='$L' for update; select pg_sleep(4); commit;" >/dev/null 2>&1 & )
sleep 0.6
T0=$(date +%s%N)
$P -c "update public.tickets set status='cancelled' where purchase_id='MAN-lk'" >/dev/null
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 1000000 ))
ok "잠긴 동안 풀기 커밋 2초 안 · 그래도 skipped:MUTED" "1|skipped:MUTED" "$([ $MS -lt 2000 ] && echo 1 || echo "0(${MS}ms)")|$(ev tp3)"
sleep 4

echo "── ⑩ 다시 RUN 해도 안전"
out2=$($P -f supabase/migrations/20261113_restock_mute.sql 2>&1)
ok "오류 없음 · ✅ 5 · ❌ 0 · 트리거 하나" "|5|0|1" "$(echo "$out2" | grep -E "^ERROR" | head -1)|$(echo "$out2" | grep -c '✅')|$(echo "$out2" | grep -c '❌')|$($P -c "select count(*) from pg_trigger where tgname='trg_taam_restock_mute'")"

[ $FAIL = 0 ] && echo "━━ 전부 통과" || echo "━━ 실패 있음"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit $FAIL
