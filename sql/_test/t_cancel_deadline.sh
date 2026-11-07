#!/bin/bash
# 취소 마감일(D-31) 당일 리마인드 회귀 — 2026-11-07 (supabase/migrations/20261107_cancel_deadline_remind.sql). 먼저: 로컬 pg. 실행: bash sql/_test/t_cancel_deadline.sh
cd "$(dirname "$0")/../.."
DB=t_cdl; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=e1000000-0000-4000-8000-000000000011; M2=e1000000-0000-4000-8000-000000000012; M3=e1000000-0000-4000-8000-000000000013; SU=e1000000-0000-4000-8000-000000000001
day(){ $P -c "select to_char((now() at time zone 'Asia/Seoul')::date + $1, 'YYYY.MM.DD')"; }
D31=$(day 31); D30=$(day 30); D32=$(day 32); D3=$(day 3)
DLKO=$($P -c "select extract(month from d)::int||'월 '||extract(day from d)::int||'일' from (select (now() at time zone 'Asia/Seoul')::date d) z")
DLEN=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date, 'Mon FMDD')")
MD31=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 31, 'MM.DD')")
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.taam_is_rest_admin(p_rest_id text) returns boolean language sql stable as \$\$ select false \$\$;
insert into auth.users values ('$M'),('$M2'),('$M3'),('$SU');
create table public.profiles(id uuid primary key, display_name text, created_at timestamptz default now(), notif_prefs jsonb default '{}'::jsonb, role text, is_test boolean default false);
insert into public.profiles(id, display_name, role, notif_prefs) values ('$M','김회원','user','{}'),('$M2','이회원','user','{"remind31":false}'),('$M3','박회원','user','{"all":false}'),('$SU','우댕','superadmin','{}');
create table public.restaurants(id text primary key, name text, name_en text, name_jp text, i18n_jp_approved boolean default true);
insert into public.restaurants(id, name, name_en, name_jp) values ('r-mitou','미토우','Mitou','味豆'),('r-saito','스시 사이토',null,null);
create table public.ticket_products(id text primary key, rest_id text, date text, time text);
insert into public.ticket_products values ('tp31','r-mitou','$D31','19:30'),('tp3','r-saito','$D3','12:00');
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, reservation_date text, visit_time text, party_size int, status text, purchase_id text, buyer_name text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.daegwan_manual(id uuid primary key default gen_random_uuid(), venue_id text, ymd date, name text, pax int, amount int, memo text, ttype text, venue_name text, created_by uuid, created_at timestamptz default now());
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, change_type text, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now(), paid_at timestamptz, restaurant_id text, restaurant_name text, visit_date text, visit_time text, pax int, ticket_product_id text);
SQL
awk '/^create or replace function public._taam_fee_caller_ok/{p=1} p{print} /^end \$\$;/{if(p){exit}}' supabase/migrations/20261017_membership_fee_due.sql > /tmp/_cdl_fee.sql; $P -f /tmp/_cdl_fee.sql >/dev/null 2>&1
awk '/^create or replace function public._taam_refund_visit_date/{p=1} p{print} /^end \$\$;/{if(p){exit}}' sql/refund_policy_server.sql > /tmp/_cdl_rvd.sql; $P -f /tmp/_cdl_rvd.sql >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
for f in sql/visit_reminder.sql supabase/migrations/20261013_member_start.sql supabase/migrations/20261019_member_link_rows.sql supabase/migrations/20261027_visit_reminder_format.sql supabase/migrations/20261027_visit_reminder_title.sql supabase/migrations/20261027_visit_reminder_admin.sql; do $P -f $f >/dev/null 2>&1; done
ok "준비: 라이브와 같은 판(슈퍼어드민 전 일정 md5 052a4a4b…)" "052a4a4bd7fe297529b982bb446e9a45" "$($P -c "select md5(prosrc) from pg_proc where oid=to_regproc('public.taam_visit_reminder_notify')")"

# 예약: 방문 31일 뒤(= 오늘이 마감일)
#   T1 김회원 PAYH 확정 미토우 3인 ✓ · T2 김회원 초대 좌석 INV- ✓ · T3 김회원 결제 링크(memberUid) ✓ + 「TAAM 에 문의」
#   T4 비회원 결제 링크(memberUid 없음) ✗ · T5 수동 예약 MAN- ✗ · T6 조기 반환 처리된 예약 ✗ · T7 패키지 줄 ✗
#   T8 이회원(remind31 끔) ✗ · T9 박회원(알림 전체 끔) ✗ · T10 홀드 ✗ · T11 취소 ✗ · T12 30일·32일 뒤 ✗ · T13 연도 없는 날짜 ✗
#   + 김회원 3일 뒤 사이토(방문 리마인드는 그대로)
$P -c "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, party_size, status, purchase_id, buyer_name, extra_data) values
  ('$M','r-mitou','미토우','tp31','$D31','19:30',3,'active','PAYH-T1','김회원','{}'),
  ('$M','r-mitou','미토우','tp31','$D31','19:30',2,'active','INV-a1b2c3d4-T2','김회원','{}'),
  ('$M','r-mitou','미토우','tp31','$D31','19:30',2,'active','LINK-T3','김회원','{\"memberUid\":\"$M\",\"linkInvite\":true}'),
  ('$SU','r-mitou','미토우','tp31','$D31','19:30',2,'active','LINK-T4','비회원','{\"linkInvite\":true}'),
  ('$SU','r-mitou','미토우','tp31','$D31','19:30',2,'manual','MAN-T5','우댕','{\"manualEntry\":true}'),
  ('$M','r-mitou','미토우','tp31','$D31','19:30',2,'active','PAYH-T6','김회원','{\"super_admin_processed_at\":\"2026-11-01T00:00:00Z\",\"deposit_return\":{\"type\":\"returned\",\"early\":true}}'),
  ('$M','r-mitou','미토우','tp31','$D31','19:30',2,'active','PAYH-T7','김회원','{\"pkg\":\"pk1\"}'),
  ('$M2','r-mitou','미토우','tp31','$D31','19:30',2,'active','PAYH-T8','이회원','{}'),
  ('$M3','r-mitou','미토우','tp31','$D31','19:30',2,'active','PAYH-T9','박회원','{}'),
  ('$M','r-mitou','미토우','tp31','$D31','19:30',2,'hold','PAYH-T10','김회원','{}'),
  ('$M','r-mitou','미토우','tp31','$D31','19:30',2,'cancelled','PAYH-T11','김회원','{}'),
  ('$M','r-mitou','미토우','tp31','$D30','19:30',2,'active','PAYH-T12a','김회원','{}'),
  ('$M','r-mitou','미토우','tp31','$D32','19:30',2,'active','PAYH-T12b','김회원','{}'),
  ('$M','r-mitou','미토우','tp31','$MD31','19:30',2,'active','PAYH-T13','김회원','{}'),
  ('$M','r-saito','스시 사이토','tp3','$D3','12:00',2,'active','PAYH-V3','김회원','{}')" >/dev/null

out=$($P -f supabase/migrations/20261107_cancel_deadline_remind.sql 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0 · ② 교체 · ① 문구 예시 ✅" "|0|1|1" "$(echo "$out" | grep ERROR | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체(취소 마감일 붙임)')|$(echo "$out" | grep -cE '^①\|.*\|✅$')"
[ "$FAIL" = 1 ] && echo "$out"

r=$($P -c "select public.taam_visit_reminder_notify()::text")
cd(){ $P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where n.payload->>'kind'='cancel_deadline' and t.purchase_id='$1'"; }
ok "실행: 마감일 3건(PAYH · 초대 좌석 · 회원 결제 링크) · deadline_made 3 · 방문 리마인드 3일 전도 그대로" "3|1" "$($P -c "select (('$r')::jsonb->>'deadline_made')")|$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where t.purchase_id='PAYH-V3' and n.user_id='$M' and n.payload->>'days'='3' and coalesce(n.payload->>'kind','')<>'cancel_deadline'")"
ok "대상: T1 · T2 · T3 각 1건" "1|1|1" "$(cd PAYH-T1)|$(cd INV-a1b2c3d4-T2)|$(cd LINK-T3)"
ok "빠지는 것: 비회원 링크 · 수동 · 처리된 예약 · 패키지 · remind31 끔 · 전체 끔 · 홀드 · 취소 · 30일 · 32일 · 연도 없음" "0|0|0|0|0|0|0|0|0|0|0" "$(cd LINK-T4)|$(cd MAN-T5)|$(cd PAYH-T6)|$(cd PAYH-T7)|$(cd PAYH-T8)|$(cd PAYH-T9)|$(cd PAYH-T10)|$(cd PAYH-T11)|$(cd PAYH-T12a)|$(cd PAYH-T12b)|$(cd PAYH-T13)"
T1W="from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where n.payload->>'kind'='cancel_deadline' and t.purchase_id='PAYH-T1'"
EXP_KO="[인원] : 3

오늘($DLKO) 밤 12시(한국 시간)까지 취소하시면 대행비를 제외한 금액이 환불됩니다.
내일부터는 취소해도 환불되지 않습니다."
ok "문구(한국어): 제목 · 본문 넷 + 오늘 날짜 마감 안내 · 받는 사람 = 회원 · 알림함 type visit_reminder · url 구매 내역" \
   "미토우 · 오늘이 환불 가능한 마지막 날입니다|t|t|$M|visit_reminder|/?open_ticket_hist=1" \
   "$($P -c "select n.title $T1W")|$(echo "select right(n.body, length(:'e')) = :'e' $T1W" | $P -v e="$EXP_KO")|$($P -c "select n.body like '[레스토랑] : 미토우%' $T1W")|$($P -c "select n.user_id $T1W")|$($P -c "select n.type $T1W")|$($P -c "select n.url $T1W")"
ok "문구(영어·일본어): 매장 이름 Mitou · 味豆 · 마감 날짜" "Mitou · Today is the last day to cancel with a refund|t|味豆 · 本日が返金可能な最終日です|t" \
   "$($P -c "select n.payload->'i18n'->'en'->>'title' $T1W")|$($P -c "select position('Cancel by midnight today ($DLEN, Korea time)' in n.payload->'i18n'->'en'->>'body') > 0 $T1W")|$($P -c "select n.payload->'i18n'->'ja'->>'title' $T1W")|$($P -c "select n.payload->'i18n'->'ja'->>'body' like '[レストラン] : 味豆%' $T1W")"
ok "결제 링크 예약은 「취소는 TAAM 에 문의」 · PAYH 에는 없음" "1|0" "$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where t.purchase_id='LINK-T3' and n.body like '%취소는 TAAM 에 문의해 주세요.'")|$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where t.purchase_id='PAYH-T1' and n.body like '%TAAM 에 문의%'")"
ok "돌려주는 줄(Edge 푸시): 마감 3줄 · days 31 · tag 열쇠 cd- · i18n" "3|3" "$($P -c "select count(*) from jsonb_array_elements(('$r')::jsonb->'rows') x where x->>'ticket_id' like 'cd-%' and (x->>'days')='31'")|$($P -c "select count(*) from jsonb_array_elements(('$r')::jsonb->'rows') x where x->>'ticket_id' like 'cd-%' and x->'i18n'->'ja'->>'title' is not null")"
ok "슈퍼어드민에게는 마감 알림 없음(회원 본인에게만)" "0" "$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'kind'='cancel_deadline'")"
ok "다시 부르면 0 (같은 티켓·같은 마감일 한 번) · 방문 리마인드도 0" "0|0" "$($P -c "select (j->>'deadline_made')||'|'||(j->>'made') from public.taam_visit_reminder_notify() j" | cut -d'|' -f1)|$($P -c "select (j->>'made') from public.taam_visit_reminder_notify() j")"

# 위조 줄: 회원이 자기 알림 줄에 days 'x' · 다른 마감일로 넣어도 막히지 않는다(글자 비교 · 그날 실행 전체가 멈추지 않는다)
$P -c "delete from public.notifications; insert into public.notifications(user_id, type, title, body, url, payload) values
  ('$M','visit_reminder','x','x','/', jsonb_build_object('kind','cancel_deadline','ticket_id',(select id::text from public.tickets where purchase_id='PAYH-T1'),'deadline','2000-01-01','days','x'))" >/dev/null
r3=$($P -c "select public.taam_visit_reminder_notify()::text" 2>&1)
ok "위조 줄(days 'x' · 다른 마감일)이 있어도 실행 성공 · 마감 3건 다시" "3" "$($P -c "select (('$r3')::jsonb->>'deadline_made')" 2>&1)"

# 실패 격리: 마감 몫이 깨져도(함수 없음) 방문 리마인드는 나간다
$P -c "delete from public.notifications; alter function public._taam_cancel_deadline_remind() rename to _taam_cancel_deadline_remind_x" >/dev/null
r4=$($P -c "select public.taam_visit_reminder_notify()::text" 2>/dev/null)
ok "마감 몫 실패 → 방문 리마인드 그대로(회원 1 + 슈퍼어드민 1) · deadline_made 0 · 오류 없음" "2|0" "$($P -c "select (('$r4')::jsonb->>'made')" 2>&1)|$($P -c "select (('$r4')::jsonb->>'deadline_made')" 2>&1)"
$P -c "alter function public._taam_cancel_deadline_remind_x() rename to _taam_cancel_deadline_remind" >/dev/null

# 권한: 회원·anon 은 마감 함수를 직접 못 부른다
ok "권한: 회원·anon 실행 불가" "f|f" "$($P -c "select has_function_privilege('authenticated','public._taam_cancel_deadline_remind()','execute')")|$($P -c "select has_function_privilege('anon','public._taam_cancel_deadline_remind()','execute')")"

# 다시 RUN · 모르는 판
out2=$($P -f supabase/migrations/20261107_cancel_deadline_remind.sql 2>&1)
ok "두 번째 RUN: ✅ 이미 새 판 · ❌ 0" "1|0" "$(echo "$out2" | grep -c '✅ 이미 새 판(취소 마감일)')|$(echo "$out2" | grep -c '❌')"
$P -c "create or replace function public.taam_visit_reminder_notify() returns jsonb language plpgsql as \$\$ begin return '{}'::jsonb; end \$\$" >/dev/null
out3=$($P -f supabase/migrations/20261107_cancel_deadline_remind.sql 2>&1)
ok "모르는 판: ❌ 건너뜀 · 덮어쓰지 않음" "1|0" "$(echo "$out3" | grep -c '❌ 라이브 본문이 슈퍼어드민 전 일정 판')|$($P -c "select count(*) from pg_proc where proname='taam_visit_reminder_notify' and prosrc like '%VR_DEADLINE_20261107%'")"

[ -z "$KEEP" ] && psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ "$FAIL" = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
