#!/bin/bash
# 방문 리마인드 「예약 안내」 문구 · 매장 유의사항/안내말씀 회귀 — 2026-10-27. 먼저: 로컬 pg. 실행: bash sql/_test/t_visit_reminder_format.sh
cd "$(dirname "$0")/../.."
DB=t_vrf; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=a1000000-0000-4000-8000-000000000011; M2=a1000000-0000-4000-8000-000000000012; SU=a1000000-0000-4000-8000-000000000001; AD=a1000000-0000-4000-8000-000000000021
TOMORROW=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 1, 'YYYY.MM.DD')")
IN3=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 3, 'YYYY.MM.DD')")
TOMK=$($P -c "with d as (select (now() at time zone 'Asia/Seoul')::date + 1 x) select extract(year from x)::int||'년 '||extract(month from x)::int||'월 '||extract(day from x)::int||'일('||(array['일','월','화','수','목','금','토'])[extract(dow from x)::int+1]||')' from d")
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
-- 매장 어드민: admin_grants 대신 설정값으로 (taam.rest = 그 어드민의 매장 id)
create or replace function public.taam_is_rest_admin(p_rest_id text) returns boolean language sql stable as \$\$ select auth.uid() is not null and coalesce(current_setting('taam.rest', true),'') = p_rest_id \$\$;
insert into auth.users values ('$M'),('$M2'),('$SU'),('$AD');
create table public.profiles(id uuid primary key, display_name text, created_at timestamptz default now(), notif_prefs jsonb default '{}'::jsonb, role text);
insert into public.profiles(id, display_name, role, notif_prefs) values ('$M','김회원','user','{}'),('$M2','이회원','user','{"remind1":false}'),('$SU','Super','superadmin','{}'),('$AD','매장','admin','{}');
create table public.restaurants(id text primary key, name text, name_en text, name_jp text);
insert into public.restaurants values ('r-mitou','미토우','Mitou','味豆'),('r-saito','스시 사이토',null,null);
create table public.ticket_products(id text primary key, rest_id text, date text, time text);
insert into public.ticket_products values ('tp1','r-mitou','$TOMORROW','18:30'),('tp2','r-saito','$IN3','12:00');
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, reservation_date text, visit_time text, party_size int, status text, purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
-- 20261019 판 함수에 필요한 것 (taam_member_start 쪽은 이 테스트가 보지 않는다)
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, change_type text, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now(), paid_at timestamptz);
SQL
awk '/^create or replace function public._taam_fee_caller_ok/{p=1} p{print} /^end \$\$;/{if(p){exit}}' supabase/migrations/20261017_membership_fee_due.sql > /tmp/_vrf_fee.sql
$P -f /tmp/_vrf_fee.sql >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P -f sql/visit_reminder.sql >/dev/null 2>&1
$P -f supabase/migrations/20261013_member_start.sql >/dev/null 2>&1
$P -f supabase/migrations/20261019_member_link_rows.sql >/dev/null 2>&1
ok "준비: 라이브와 같은 판(20261019 · md5 3b8771fc…)" "3b8771fc6bde3213d6d63f5e7be4c4d7" "$($P -c "select md5(prosrc) from pg_proc where oid=to_regproc('public.taam_visit_reminder_notify')")"

# 행: 회원 미토우 내일 18:30 5인(restaurant_id 있음) · 회원 사이토 3일 뒤 12:00 2인(restaurant_id 없음 → 회차의 rest_id) · 하루 전 끈 회원 · 비회원 LINK-
$P -c "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, party_size, status, purchase_id, extra_data) values
  ('$M','r-mitou','미토우','tp1','$TOMORROW','18:30',5,'active','PAYH-aaa','{}'),
  ('$M',null,'스시 사이토','tp2','$IN3','12:00',2,'active','PAYH-bbb','{}'),
  ('$M2','r-mitou','미토우','tp1','$TOMORROW','18:30',2,'active','PAYH-ccc','{}'),
  ('$SU','r-mitou','미토우','tp1','$TOMORROW','18:30',2,'active','LINK-ddd','{\"linkInvite\":true}')" >/dev/null

out=$($P -f supabase/migrations/20261027_visit_reminder_format.sql 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0 · ④ ✅ 교체 · ①②③⑤ ✅" "|0|1|4" "$(echo "$out" | grep -E "ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체')|$(echo "$out" | grep -cE '^(①|②|③|⑤)\|.*\|✅$')"
[ "$FAIL" = 1 ] && echo "$out"

# 문구 만들기 — 요청 예시 그대로
ok "예시: 미토우 2026-09-10 18:30 5인 (KO)" "예약 안내|[레스토랑] : 미토우
[날짜] : 2026년 9월 10일(목)
[시간] : 오후 6:30
[인원] : 5" "$($P -c "select j->'ko'->>'title'||'|'||(j->'ko'->>'body') from public._taam_visit_remind_msg('{\"ko\":\"미토우\",\"en\":\"Mitou\",\"ja\":\"味豆\"}', date '2026-09-10', '18:30', 5, null) j")"
ok "예시 (EN)" "Reservation Reminder|[Restaurant] : Mitou
[Date] : Thu, Sep 10, 2026
[Time] : 6:30 PM
[Guests] : 5" "$($P -c "select j->'en'->>'title'||'|'||(j->'en'->>'body') from public._taam_visit_remind_msg('{\"ko\":\"미토우\",\"en\":\"Mitou\",\"ja\":\"味豆\"}', date '2026-09-10', '18:30', 5, null) j")"
ok "예시 (JA)" "ご予約のご案内|[レストラン] : 味豆
[日付] : 2026年9月10日(木)
[時間] : 午後6:30
[人数] : 5" "$($P -c "select j->'ja'->>'title'||'|'||(j->'ja'->>'body') from public._taam_visit_remind_msg('{\"ko\":\"미토우\",\"en\":\"Mitou\",\"ja\":\"味豆\"}', date '2026-09-10', '18:30', 5, null) j")"
ok "시각: 12:00 오후 12:00 · 00:30 오전 12:30 · 09:05 오전 9:05 · 'TBD' 그대로 · 빈 값이면 줄 없음" "오후 12:00|오전 12:30|오전 9:05|TBD|0" "$($P -c "select string_agg(x, '|' order by n) from (select 1 n, substring(public._taam_visit_remind_msg('{\"ko\":\"a\"}', date '2026-09-10', '12:00', 1, null)->'ko'->>'body' from '\[시간\] : ([^\n]+)') x union all select 2, substring(public._taam_visit_remind_msg('{\"ko\":\"a\"}', date '2026-09-10', '00:30', 1, null)->'ko'->>'body' from '\[시간\] : ([^\n]+)') union all select 3, substring(public._taam_visit_remind_msg('{\"ko\":\"a\"}', date '2026-09-10', '09:05', 1, null)->'ko'->>'body' from '\[시간\] : ([^\n]+)') union all select 4, substring(public._taam_visit_remind_msg('{\"ko\":\"a\"}', date '2026-09-10', 'TBD', 1, null)->'ko'->>'body' from '\[시간\] : ([^\n]+)') union all select 5, (position('[시간]' in public._taam_visit_remind_msg('{\"ko\":\"a\"}', date '2026-09-10', '', 1, null)->'ko'->>'body'))::text) s")"
ok "영어·일본어 이름이 없으면 한국어 이름 · 문구가 한국어만이면 세 언어 모두 한국어 문구" "스시 사이토|스시 사이토|1|1" "$($P -c "select substring(j->'en'->>'body' from '\[Restaurant\] : ([^\n]+)')||'|'||substring(j->'ja'->>'body' from '\[レストラン\] : ([^\n]+)')||'|'||(position(E'[Notes]\n주차 불가' in j->'en'->>'body')>0)::int||'|'||(position(E'[ご注意事項]\n주차 불가' in j->'ja'->>'body')>0)::int from public._taam_visit_remind_msg('{\"ko\":\"스시 사이토\"}', date '2026-09-10', '12:00', 2, '{\"notice\":\"주차 불가\"}') j")"

# 리마인드 실행 — 문구 · 매장 문구 없음 → 넷만
r=$($P -c "select public.taam_visit_reminder_notify()::text")
ok "실행: 2건(내일 미토우 · 3일 뒤 사이토) · 하루 전 끈 회원·비회원 LINK- 없음" "2|0|0" "$(echo "$r" | $P -c "select 1" >/dev/null; $P -c "select count(*) from public.notifications where user_id='$M'")|$($P -c "select count(*) from public.notifications where user_id='$M2'")|$($P -c "select count(*) from public.notifications where user_id='$SU'")"
ok "알림함 줄: 제목 「예약 안내」 · 본문 넷(내일 날짜 · 오후 6:30 · 5) · 유의사항 없음" "예약 안내|[레스토랑] : 미토우
[날짜] : $TOMK
[시간] : 오후 6:30
[인원] : 5" "$($P -c "select title||'|'||body from public.notifications where user_id='$M' and payload->>'days'='1'")"
ok "restaurant_id 가 빈 행은 회차의 매장(r-saito) · payload fmt v2 · pax 2 · date · i18n en" "r-saito|v2|2|1|Reservation Reminder" "$($P -c "select (payload->>'rest_id')||'|'||(payload->>'fmt')||'|'||(payload->>'pax')||'|'||(payload->>'date' ~ '^\d{4}-\d{2}-\d{2}$')::int||'|'||(payload->'i18n'->'en'->>'title') from public.notifications where user_id='$M' and payload->>'days'='3'")"
ok "돌려주는 줄에 i18n(세 언어) — Edge 가 그대로 쓴다" "2|2" "$(echo "$r" | $P -c "select 1" >/dev/null; $P -c "select count(*) from jsonb_array_elements(('$r')::jsonb->'rows') x where x->'i18n'->'ja'->>'title' = 'ご予約のご案内'")|$($P -c "select (('$r')::jsonb->>'made')")"
ok "다시 부르면 0 (같은 티켓·일수 한 번)" "0" "$($P -c "select (public.taam_visit_reminder_notify()->>'made')")"

# 매장 문구 — 권한
ok "회원은 못 쓴다 (FORBIDDEN)" "1" "$($P -c "set taam.uid='$M'; select public.taam_visit_notes_set('r-mitou','{\"notice\":\"x\"}')" 2>&1 | grep -c FORBIDDEN)"
ok "다른 매장 어드민은 못 쓴다" "1" "$($P -c "set taam.uid='$AD'; set taam.rest='r-saito'; select public.taam_visit_notes_set('r-mitou','{\"notice\":\"x\"}')" 2>&1 | grep -c FORBIDDEN)"
ok "그 매장 어드민은 쓴다 · 앞뒤 공백 정리 · 적은 사람" "true|주차 불가합니다.|$AD" "$($P -c "set taam.uid='$AD'; set taam.rest='r-mitou'; select (public.taam_visit_notes_set('r-mitou','{\"notice\":\"  주차 불가합니다.  \",\"message\":\"\"}')->>'ok')" )|$($P -c "select notice||'|'||updated_by from public.restaurant_visit_notes where restaurant_id='r-mitou'")"
ok "300자 넘으면 TOO_LONG" "1" "$($P -c "set taam.uid='$AD'; set taam.rest='r-mitou'; select public.taam_visit_notes_set('r-mitou', jsonb_build_object('message', repeat('가', 301)))" 2>&1 | grep -c TOO_LONG)"
ok "슈퍼어드민은 아무 매장 · 전부 읽기(null)" "true|2" "$($P -c "set taam.uid='$SU'; set taam.super='1'; select (public.taam_visit_notes_set('r-saito','{\"message\":\"시간 엄수 부탁드립니다.\",\"message_en\":\"Please arrive on time.\"}')->>'ok')")|$($P -c "set taam.uid='$SU'; set taam.super='1'; select jsonb_array_length(public.taam_visit_notes_get(null))")"
ok "매장 어드민은 전부 읽기 못 함 · 자기 매장 읽기는 됨" "1|주차 불가합니다." "$($P -c "set taam.uid='$AD'; set taam.rest='r-mitou'; select public.taam_visit_notes_get(null)" 2>&1 | grep -c FORBIDDEN)|$($P -c "set taam.uid='$AD'; set taam.rest='r-mitou'; select public.taam_visit_notes_get('r-mitou')->>'notice'")"
ok "미리보기(저장 전 값) — 유의사항 칸 · 그 매장의 회차 시각" "1|오후 6:30" "$($P -c "set taam.uid='$AD'; set taam.rest='r-mitou'; select (position(E'\n\n[유의사항]\n새 문구' in public.taam_visit_notes_preview('r-mitou','{\"notice\":\"새 문구\"}')->'ko'->>'body')>0)::int")|$($P -c "set taam.uid='$AD'; set taam.rest='r-mitou'; select substring(public.taam_visit_notes_preview('r-mitou',null)->'ko'->>'body' from '\[시간\] : ([^\n]+)')")"
ok "표는 직접 못 읽는다 (authenticated 권한 없음)" "1" "$($P -c "set role authenticated; select * from public.restaurant_visit_notes" 2>&1 | grep -c 'permission denied')"

# 매장 문구가 있으면 그 칸만 나간다
$P -c "delete from public.notifications" >/dev/null
$P -c "select public.taam_visit_reminder_notify()" >/dev/null
ok "미토우: 유의사항만(안내말씀 칸 없음)" "1|0" "$($P -c "select (position(E'[인원] : 5\n\n[유의사항]\n주차 불가합니다.' in body)>0)::int||'|'||(position('[안내말씀]' in body)>0)::int from public.notifications where user_id='$M' and payload->>'days'='1'")"
ok "사이토: 안내말씀만 · EN 은 영어 문구" "0|1|1" "$($P -c "select (position('[유의사항]' in body)>0)::int||'|'||(position(E'[안내말씀]\n시간 엄수 부탁드립니다.' in body)>0)::int||'|'||(position(E'[Message]\nPlease arrive on time.' in payload->'i18n'->'en'->>'body')>0)::int from public.notifications where user_id='$M' and payload->>'days'='3'")"
ok "전부 비우면 줄을 지운다 → 다시 넷만" "true|0" "$($P -c "set taam.uid='$SU'; set taam.super='1'; select (public.taam_visit_notes_set('r-saito','{\"message\":\" \",\"message_en\":\"\"}')->>'cleared')")|$($P -c "select count(*) from public.restaurant_visit_notes where restaurant_id='r-saito'")"

# 다시 RUN — ✅ 이미 새 판 · ❌ 0 · 매장 문구는 그대로
out2=$($P -f supabase/migrations/20261027_visit_reminder_format.sql 2>&1)
ok "두 번째 RUN: ✅ 이미 새 판 · ❌ 0 · 매장 문구 유지" "1|0|1" "$(echo "$out2" | grep -c '✅ 이미 새 판')|$(echo "$out2" | grep -c '❌')|$($P -c "select count(*) from public.restaurant_visit_notes")"
# 모르는 판은 ❌ 로 건너뛴다
$P -c "create or replace function public.taam_visit_reminder_notify() returns jsonb language sql as \$\$ select '{\"made\":0}'::jsonb \$\$" >/dev/null
out3=$($P -f supabase/migrations/20261027_visit_reminder_format.sql 2>&1)
ok "모르는 판: ❌ 건너뜀 · 덮어쓰지 않음" "1|{\"made\": 0}" "$(echo "$out3" | grep -c '❌ 라이브 본문이')|$($P -c "select public.taam_visit_reminder_notify()")"
# 테스트 발송 파일 — 슈퍼어드민에게만 · 실제 함수 문구 · 회원 알림 0
$P -c "create or replace function public._taam_member_push(a uuid,b text,c text,d text,e text,f text,g jsonb) returns jsonb language sql as \$\$ select jsonb_build_object('ok',true,'request_id',42) \$\$" >/dev/null
$P -f supabase/migrations/20261027_visit_reminder_format.sql >/dev/null 2>&1   # 모르는 판 덮어쓰기 거부 뒤라 옛 판 그대로 — 테스트 파일은 그것을 ⚠ 로 알린다
$P -c "delete from public.notifications" >/dev/null
$P -c "set taam.uid='$AD'; set taam.rest='r-mitou'; select public.taam_visit_notes_set('r-mitou','{\"notice\":\"주차 불가\"}')" >/dev/null
out4=$($P -f supabase/migrations/20261027_visit_reminder_format_test.sql 2>&1)
ok "테스트 발송: 오류 없음 · 슈퍼어드민 1명 request_id 42 · 가장 가까운 예약(내일 미토우 18:30 + 유의사항) · 회원 알림 0" "|1|1|0|[테스트] 예약 안내" "$(echo "$out4" | grep -E "ERROR" | head -1)|$(echo "$out4" | grep -c 'request_id=42')|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'test'='true' and body like E'[레스토랑] : 미토우\n[날짜] : %\n[시간] : 오후 6:30\n[인원] : %\n\n[유의사항]\n주차 불가'")|$($P -c "select count(*) from public.notifications where user_id<>'$SU'")|$($P -c "select title from public.notifications where user_id='$SU' and payload->>'test'='true'")"
[ -z "$KEEP" ] && psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
