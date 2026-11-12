#!/bin/bash
# 슈퍼어드민 방문 리마인드 날짜마다 한 번 · 캘린더 발송 현황 · 연회비 알림 계산 근거 — 2026-11-12 (supabase/migrations/20261112_reminder_day_admin.sql)
# 먼저: 로컬 pg. 실행: bash sql/_test/t_reminder_day_admin.sh   (KEEP=1 이면 DB 를 남긴다)
cd "$(dirname "$0")/../.."
DB=t_rda; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=f1000000-0000-4000-8000-000000000011; M2=f1000000-0000-4000-8000-000000000012; M3=f1000000-0000-4000-8000-000000000013; SU=f1000000-0000-4000-8000-000000000001
I1=f2000000-0000-4000-8000-000000000001; I2=f2000000-0000-4000-8000-000000000002
day(){ $P -c "select to_char((now() at time zone 'Asia/Seoul')::date + $1, 'YYYY.MM.DD')"; }
iso(){ $P -c "select to_char((now() at time zone 'Asia/Seoul')::date + $1, 'YYYY-MM-DD')"; }
D1=$(day 1); D3=$(day 3); D5=$(day 5); DM5=$(day -5); I_D1=$(iso 1); I_D3=$(iso 3); I_D5=$(iso 5); I_DM5=$(iso -5)
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.taam_is_rest_admin(p_rest_id text) returns boolean language sql stable as \$\$ select false \$\$;
insert into auth.users values ('$M'),('$M2'),('$M3'),('$SU');
create table public.profiles(id uuid primary key, display_name text, created_at timestamptz default now(), notif_prefs jsonb default '{}'::jsonb, role text, is_test boolean default false, deleted_at timestamptz);
insert into public.profiles(id, display_name, role, notif_prefs) values ('$M','김회원','user','{}'),('$M2','이회원','user','{"remind1":false}'),('$M3','박회원','user','{}'),('$SU','우댕','superadmin','{}');
create table public.restaurants(id text primary key, name text, name_en text, name_jp text, i18n_jp_approved boolean default true);
insert into public.restaurants(id, name, name_en, name_jp) values ('r-ama','히가시아자부 아마모토','Higashiazabu Amamoto','東麻布 天本'),('r-saito','스시 사이토',null,null);
create table public.ticket_products(id text primary key, rest_id text, date text, time text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, reservation_date text, visit_time text, party_size int, status text, purchase_id text, buyer_name text, buyer_phone text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.daegwan_manual(id uuid primary key default gen_random_uuid(), venue_id text, ymd date, name text, pax int, amount int, memo text, ttype text, venue_name text, created_by uuid, created_at timestamptz default now());
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, change_type text, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now(), paid_at timestamptz, restaurant_id text, restaurant_name text, visit_date text, visit_time text, pax int, ticket_product_id text);
create table public.membership_fee_notices(user_id uuid, due_date date, stage int, notified_at timestamptz default now(), primary key(user_id, due_date, stage));
create table public._fd(user_id uuid, display_name text, tier text, currency text, joined_at date, joined_kind text, years int, paid int, due_date date, days_left int, short int, ahead int, last_paid date, fee_hint text, fee_exempt boolean, fee_exempt_note text, anchor_kind text, anchor_date date, app_signup_date date, membership_joined_at date, start_at date, implicit_first boolean, paid_recorded int);
create or replace function public.taam_membership_fee_due(p_uid uuid default null, p_today date default null, p_include_exempt boolean default false)
returns setof public._fd language sql stable as \$\$ select * from public._fd \$\$;
create or replace function public.taam_admin_push(a text, b text, c text, d text, e text) returns jsonb language sql as \$\$ select jsonb_build_object('ok', true, 'body', b) \$\$;
SQL
awk '/^create or replace function public._taam_fee_caller_ok/{p=1} p{print} /^end \$\$;/{if(p){exit}}' supabase/migrations/20261017_membership_fee_due.sql > /tmp/_rda_fee.sql; $P -f /tmp/_rda_fee.sql >/dev/null 2>&1
awk '/^create or replace function public.taam_membership_fee_notify/{p=1} p{print} /^end \$\$;/{if(p){exit}}' supabase/migrations/20261017_membership_fee_due.sql > /tmp/_rda_fn.sql; $P -f /tmp/_rda_fn.sql >/dev/null 2>&1
awk '/^create or replace function public._taam_refund_visit_date/{p=1} p{print} /^end \$\$;/{if(p){exit}}' sql/refund_policy_server.sql > /tmp/_rda_rvd.sql; $P -f /tmp/_rda_rvd.sql >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
for f in sql/visit_reminder.sql supabase/migrations/20261013_member_start.sql supabase/migrations/20261019_member_link_rows.sql supabase/migrations/20261019_guest_reminder.sql supabase/migrations/20261027_visit_reminder_format.sql supabase/migrations/20261027_visit_reminder_title.sql supabase/migrations/20261027_visit_reminder_admin.sql supabase/migrations/20261107_cancel_deadline_remind.sql; do $P -f $f >/dev/null 2>&1; done
ok "준비: 라이브와 같은 판 — 슈퍼어드민 몫 b3b1c4af · 연회비 알림 3067b7bb · 리마인드 VR_DEADLINE" "b3b1c4af844cf4731f93befe7e1b2bff|3067b7bb7f09fbc016291862dfeef0bc|1" \
   "$($P -c "select md5(prosrc) from pg_proc where oid=to_regproc('public._taam_visit_reminder_admin')")|$($P -c "select md5(prosrc) from pg_proc where oid=to_regproc('public.taam_membership_fee_notify')")|$($P -c "select count(*) from pg_proc where proname='taam_visit_reminder_notify' and prosrc like '%VR_DEADLINE_20261107%'")"

# 일정: 내일 아마모토 = 회원 좌석 둘(초대 INV- · 앱 PAYH) + 수동 좌석 MAN- + 수동 기록 둘(황재철 3 · 우댕 1) · 사이토 = 결제 링크(비회원 · 번호) / 3일 뒤 사이토 회원 1
$P -c "insert into public.reservation_invites(id, invitee_user_id, status, restaurant_id, restaurant_name, visit_date, visit_time, pax) values
  ('$I1','$M','paid','r-ama','히가시아자부 아마모토','$D1','20:30',2),
  ('$I2','$M3','paid','r-ama','히가시아자부 아마모토','$D5','19:00',2)" >/dev/null
$P -c "insert into public.tickets(user_id, restaurant_id, restaurant_name, reservation_date, visit_time, party_size, status, purchase_id, buyer_name, buyer_phone, extra_data, created_at) values
  ('$M','r-ama','히가시아자부 아마모토','$D1','20:30',2,'active','INV-f2000000-A1','김회원',null,'{\"inviteId\":\"$I1\"}', now() - interval '20 days'),
  ('$M2','r-ama','히가시아자부 아마모토','$D1','20:30',2,'active','PAYH-A2','이회원',null,'{}', now() - interval '20 days'),
  ('$SU','r-ama','히가시아자부 아마모토','$D1','',1,'manual','MAN-A3','우댕',null,'{\"manualEntry\":true}', now() - interval '20 days'),
  ('$SU','r-saito','스시 사이토','$D1','12:00',2,'active','LINK-S1','손님','+82 10-1234-5678','{\"linkInvite\":true}', now() - interval '20 days'),
  ('$M','r-saito','스시 사이토','$D3','12:00',2,'active','PAYH-S3','김회원',null,'{}', now() - interval '20 days'),
  ('$SU','r-saito','스시 사이토','$D5','12:00',2,'active','KSK-S5','정산',null,'{\"kashikiri\":true}', now() - interval '20 days'),
  ('$M3','r-saito','스시 사이토','$D5','12:00',2,'active','PAYH-S5','박회원',null,'{}', now() - interval '2 days'),
  ('$M3','r-saito','스시 사이토','$D5','18:00',2,'active','PAYH-S6','박회원',null,'{}', now() - interval '20 days'),
  ('$M','r-saito','스시 사이토','$DM5','12:00',2,'active','PAYH-P5','김회원',null,'{}', now() - interval '20 days')" >/dev/null
$P -c "insert into public.daegwan_manual(venue_id, ymd, name, pax, venue_name) values ('r-ama','$I_D1','황재철',3,'히가시아자부 아마모토'),('r-ama','$I_D1','우댕',1,'히가시아자부 아마모토')" >/dev/null

out=$($P -f supabase/migrations/20261112_reminder_day_admin.sql 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0 · C 교체 · E 교체 · A·B·D ✅" "|0|1|1|3" "$(echo "$out" | grep ERROR | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체(날짜마다 한 번)')|$(echo "$out" | grep -c '✅ 교체(계산 근거)')|$(echo "$out" | grep -cE '^(A|B|D)\|.*\|✅$')"
[ "$FAIL" = 1 ] && echo "$out"

r=$($P -c "select public.taam_visit_reminder_notify()::text")
SA="from public.notifications where user_id='$SU' and type='visit_reminder'"
ok "슈퍼어드민: 내일 한 줄 · 3일 뒤 한 줄 (일정별 줄 없음) · admin_made 2" "1|1|2|2" \
   "$($P -c "select count(*) $SA and payload->>'date'='$I_D1' and payload->>'days'='1'")|$($P -c "select count(*) $SA and payload->>'date'='$I_D3' and payload->>'days'='3'")|$($P -c "select count(*) $SA")|$($P -c "select (('$r')::jsonb->>'admin_made')")"
EXP_T="내일 방문 일정 — 2곳 · 6건 · 11명"
EXP_B="• 스시 사이토 · 오후 12:00 · 1건 2명
• 히가시아자부 아마모토 · 오후 8:30 · 5건 9명

누가 오는지 · 손님 리마인드 발송은 티켓 캘린더에서 확인하세요."
ok "내일 줄: 제목 「2곳 · 6건 · 11명」 · 매장마다 한 줄(이름순 · 시간 · 건·명) · 캘린더 안내 · payload fmt day · rkey" "$EXP_T|t|t|day|day:$I_D1|6|11" \
   "$($P -c "select title $SA and payload->>'days'='1'")|$(echo "select right(body, length(:'e')) = :'e' $SA and payload->>'days'='1'" | $P -v e="$EXP_B")|$($P -c "select body like '[날짜] : %년 %월 %일(_)%' $SA and payload->>'days'='1'")|$($P -c "select payload->>'fmt' $SA and payload->>'days'='1'")|$($P -c "select payload->>'rkey' $SA and payload->>'days'='1'")|$($P -c "select payload->>'count' $SA and payload->>'days'='1'")|$($P -c "select payload->>'pax' $SA and payload->>'days'='1'")"
ok "3일 뒤 줄: 한 매장이면 제목에 이름 · 영어·일본어" "3일 뒤 방문 일정 — 스시 사이토 1건 · 2명|Visits in 3 days — 스시 사이토 · 1 booking · 2 guests|3日後のご来店予定 — スシ サイトー 1件 · 2名" \
   "$($P -c "select title $SA and payload->>'days'='3'")|$($P -c "select payload->'i18n'->'en'->>'title' $SA and payload->>'days'='3'")|$($P -c "select replace(payload->'i18n'->'ja'->>'title', '스시 사이토', 'スシ サイトー') $SA and payload->>'days'='3'")"
ok "Edge 로 가는 줄: 슈퍼어드민 2줄 · ticket_id day:날짜 · days" "2|1" \
   "$($P -c "select count(*) from jsonb_array_elements(('$r')::jsonb->'rows') x where x->>'user_id'='$SU' and x->>'ticket_id' like 'day:%'")|$($P -c "select count(*) from jsonb_array_elements(('$r')::jsonb->'rows') x where x->>'ticket_id'='day:$I_D1' and (x->>'days')='1'")"
ok "회원 리마인드는 그대로: 김회원 내일(초대 좌석) · 3일 뒤 · 이회원(하루 전 끔) 없음" "1|1|0" \
   "$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text=n.payload->>'ticket_id' where t.purchase_id='INV-f2000000-A1' and n.user_id='$M' and n.payload->>'days'='1'")|$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text=n.payload->>'ticket_id' where t.purchase_id='PAYH-S3' and n.payload->>'days'='3'")|$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text=n.payload->>'ticket_id' where t.purchase_id='PAYH-A2'")"
ok "다시 부르면 슈퍼어드민 0 (같은 날짜·일수 한 번)" "0" "$($P -c "select (j->>'admin_made') from public.taam_visit_reminder_notify() j")"

# 옛 일정별 줄(2026-10-27 판)이 같은 날짜·일수로 이미 있으면 보내지 않는다 · 회원이 꽂은 줄(via)은 세지 않는다 · 슈퍼어드민 하루 전 끔
$P -c "delete from public.notifications where user_id='$SU'; insert into public.notifications(user_id, type, title, body, url, payload) values
  ('$SU','visit_reminder','x','x','/', jsonb_build_object('admin', true, 'rkey', 'm:x', 'days', 1, 'date', '$I_D1')),
  ('$SU','visit_reminder','x','x','/', jsonb_build_object('admin', true, 'rkey', 'day:$I_D3', 'days', '3', 'date', '$I_D3', 'via', 'taam_notify_admins'))" >/dev/null
r2=$($P -c "select public.taam_visit_reminder_notify()::text")
ok "옛 일정별 줄 있음 → 내일 줄 안 감 · 회원이 꽂은 줄은 무시 → 3일 뒤 줄 감" "0|1" "$($P -c "select count(*) $SA and payload->>'fmt'='day' and payload->>'days'='1'")|$($P -c "select count(*) $SA and payload->>'fmt'='day' and payload->>'days'='3'")"
$P -c "delete from public.notifications where user_id='$SU'; update public.profiles set notif_prefs='{\"remind1\":false}' where id='$SU'" >/dev/null
$P -c "select public.taam_visit_reminder_notify()" >/dev/null
ok "슈퍼어드민이 하루 전을 끄면 내일 줄 없음 · 3일 뒤만" "0|1" "$($P -c "select count(*) $SA and payload->>'days'='1'")|$($P -c "select count(*) $SA and payload->>'days'='3'")"
$P -c "update public.profiles set notif_prefs='{}' where id='$SU'" >/dev/null

# 푸시 결과 기록 — 서버만
NID=$($P -c "select n.id from public.notifications n join public.tickets t on t.id::text=n.payload->>'ticket_id' where t.purchase_id='INV-f2000000-A1' and n.payload->>'days'='1'")
TID=$($P -c "select id from public.tickets where purchase_id='INV-f2000000-A1'")
ok "기록: 서버 호출 1줄 · 잘못된 id 무시 · 다시 적으면 갱신" "1|1" \
   "$($P -c "select public.taam_visit_reminder_push_mark('[{\"notif_id\":\"$NID\",\"user_id\":\"$M\",\"ticket_key\":\"$TID\",\"days\":1,\"http\":200,\"matched\":1,\"attempted\":1,\"ok\":1,\"failed\":0},{\"notif_id\":\"zz\"}]'::jsonb)")|$($P -c "select public.taam_visit_reminder_push_mark('[{\"notif_id\":\"$NID\",\"user_id\":\"$M\",\"ticket_key\":\"$TID\",\"days\":1,\"http\":200,\"matched\":2,\"attempted\":2,\"ok\":2,\"failed\":0}]'::jsonb)")"
ok "기록: 로그인 세션(슈퍼어드민 포함)은 못 쓴다 · authenticated 권한 없음" "FORBIDDEN|f" \
   "$($P -c "set taam.uid='$SU'; set taam.super='1'; select public.taam_visit_reminder_push_mark('[]'::jsonb)" 2>&1 | grep -o FORBIDDEN | head -1)|$($P -c "select has_function_privilege('authenticated','public.taam_visit_reminder_push_mark(jsonb)','execute')")"

# 비회원 알림톡 기록(3일 전은 보냈고 하루 전은 아직)
LTID=$($P -c "select id from public.tickets where purchase_id='LINK-S1'")
$P -c "insert into public.guest_remind_log(ticket_id, d, result, sent_at) values ('$LTID', 3, 'sent', now() - interval '2 days')" >/dev/null
# 3일 전이 지난 회원 예약(PAYH-S5 는 이틀 전에 삼 → 7일 전 이후 · 3일 전 전) · 5일 지난 예약
# 3일 전 회원 리마인드는 이틀 전에 갔다(푸시 기록 전의 옛 줄 — 회원 알림 줄만 있다)
$P -c "insert into public.notifications(user_id, type, title, body, url, payload, created_at) values ('$M','visit_reminder','x','x','/', jsonb_build_object('ticket_id','$TID','days',3,'kind','visit_reminder'), now() - interval '2 days')" >/dev/null
S(){ $P -c "set taam.uid='$SU'; set taam.super='1'; select public.taam_visit_reminder_status('$1'::date, $2, $3)::text" 2>&1 | tail -1; }
st=$(S "$I_D1" "array['INV-f2000000-A1','PAYH-A2','MAN-A3','LINK-S1','NOPE']" "array['$I1']")
J(){ $P -c "select ('$st')::jsonb #>> '$1'"; }
ok "현황(내일): 초대 좌석 = 회원 · 하루 전 보냄 + 푸시 기기 2/2 · 3일 전 보냄(회원 알림 줄 · 푸시 기록 전)" "member|sent|2|sent|" \
   "$(J '{items,p:INV-f2000000-A1,kind}')|$(J '{items,p:INV-f2000000-A1,stages,2,st}')|$(J '{items,p:INV-f2000000-A1,stages,2,push,ok}')|$(J '{items,p:INV-f2000000-A1,stages,1,st}')|$(J '{items,p:INV-f2000000-A1,stages,1,push,ok}')"
ok "현황: 초대 키(i:)도 같은 좌석 · 이회원 하루 전 = 꺼짐 · 7일 전 기본 꺼짐" "member|off|off" \
   "$(J "{items,i:$I1,kind}")|$(J '{items,p:PAYH-A2,stages,2,st}')|$(J '{items,p:PAYH-A2,stages,0,st}')"
ok "현황: 수동 좌석(번호 없음) = 대상 아님 nophone · 결제 링크 비회원 = 알림톡 · 3일 전 sent · 국내 번호 · 없는 구매 id = no_seat" "none|nophone|guest|sent|true|no_seat" \
   "$(J '{items,p:MAN-A3,kind}')|$(J '{items,p:MAN-A3,why}')|$(J '{items,p:LINK-S1,kind}')|$(J '{items,p:LINK-S1,stages,0,st}')|$(J '{items,p:LINK-S1,kr}')|$(J '{items,p:NOPE,why}')"
st=$(S "$I_D5" "array['PAYH-S5','PAYH-S6','KSK-S5']" "array['$I2']")
ok "현황(5일 뒤): 3일 전·하루 전 = 예정 · 정산 좌석 = ksk · 좌석 없는 초대 = seatless_invite" "plan|plan|ksk|seatless_invite" \
   "$(J '{items,p:PAYH-S6,stages,1,st}')|$(J '{items,p:PAYH-S6,stages,2,st}')|$(J '{items,p:KSK-S5,why}')|$(J "{items,i:$I2,why}")"
st=$(S "$I_DM5" "array['PAYH-P5']" "null")
ok "현황(지난 방문 · 기록 없음): 3일 전·하루 전 = ⚠ 안 감(missed)" "missed|missed" "$(J '{items,p:PAYH-P5,stages,1,st}')|$(J '{items,p:PAYH-P5,stages,2,st}')"
$P -c "update public.tickets set created_at = now() - interval '1 day' where purchase_id='PAYH-P5'" >/dev/null
st=$(S "$I_DM5" "array['PAYH-P5']" "null")
ok "현황: 그 날 이후에 예약 → late" "late|late" "$(J '{items,p:PAYH-P5,stages,1,st}')|$(J '{items,p:PAYH-P5,stages,2,st}')"
ok "현황 권한: 회원 FORBIDDEN · anon 실행 불가 · 401개 TOO_MANY" "FORBIDDEN|f|TOO_MANY" \
   "$($P -c "set taam.uid='$M'; select public.taam_visit_reminder_status(current_date, null, null)" 2>&1 | grep -o FORBIDDEN | head -1)|$($P -c "select has_function_privilege('anon','public.taam_visit_reminder_status(date,text[],text[])','execute')")|$($P -c "set taam.uid='$SU'; set taam.super='1'; select public.taam_visit_reminder_status(current_date, array(select 'X'||g from generate_series(1,401) g), null)" 2>&1 | grep -o TOO_MANY | head -1)"
ok "현황: 읽기 전용 트랜잭션에서도 돈다(PostgREST GET 아님 · stable)" "member" \
   "$($P -c "begin read only; set local taam.uid='$SU'; set local taam.super='1'; select public.taam_visit_reminder_status('$I_D1'::date, array['INV-f2000000-A1'], null) #>> '{items,p:INV-f2000000-A1,kind}'; commit;" 2>&1 | grep -v -E '^(BEGIN|SET|COMMIT)$' | tail -1)"

# 연회비 알림 — 임태규 모양(실제 가입일 2024.12.11 · 납부 2 · 기준일 30일 뒤) / 앱 이후 회원(첫해 암묵) 7일 전
TODAY=$($P -c "select (now() at time zone 'Asia/Seoul')::date")
$P -c "insert into public._fd(user_id, display_name, tier, years, paid, due_date, days_left, short, fee_hint, anchor_kind, anchor_date, implicit_first) values
  ('$M','임태규','M',2,2,'$TODAY'::date + 30,30,0,'₩1,125,000','joined','2024-12-11',false)" >/dev/null
f1=$($P -c "select public.taam_membership_fee_notify()::text")
DUE=$($P -c "select to_char('$TODAY'::date + 30, 'YYYY.MM.DD')")
EXP_F="임태규 · M · 3년차 연회비 ₩1,125,000 · 기준일 $DUE (30일 남음)
  └ 실제 가입일 2024.12.11 + 납부 2년 = $DUE · 30일 전 미리 알림"
FN="from public.notifications where type='membership_fee_due' and user_id='$SU'"
ok "연회비: 제목 「30일 전 알림 · 1명」 · 줄 = 3년차 · 기준일 · 계산 근거 · payload nth 3" "💰 연회비 납부 30일 전 알림 · 1명|t|3|joined" \
   "$($P -c "select title $FN")|$(echo "select body = :'e' $FN" | $P -v e="$EXP_F")|$($P -c "select payload->'members'->0->>'nth' $FN")|$($P -c "select payload->'members'->0->>'anchor_kind' $FN")"
ok "연회비 푸시 본문: 한 줄 「임태규 · 3년차 · 기준일 (30일 남음)」" "임태규 · 3년차 · $DUE (30일 남음)" "$($P -c "select ('$f1')::jsonb->'push'->>'body'")"
$P -c "delete from public.notifications where type='membership_fee_due'; insert into public._fd(user_id, display_name, tier, years, paid, due_date, days_left, short, fee_hint, anchor_kind, anchor_date, implicit_first) values
  ('$M2','신회원','T',1,1,'$TODAY'::date + 6,6,0,'₩630,000','start','2025-11-20',true)" >/dev/null
$P -c "select public.taam_membership_fee_notify()" >/dev/null
ok "연회비: 이미 알린 회원 빠짐 · 앱 이후 회원 7일 전 → 「2년차」 · 「첫 구매·초대 결제일 … + 납부 1년(첫해는 가입 때 제외)」 · 제목 7일 전" "💰 연회비 납부 7일 전 알림 · 1명|t|t" \
   "$($P -c "select title $FN")|$($P -c "select body like '신회원 · T · 2년차 연회비 ₩630,000 · 기준일 % (6일 남음)%' $FN")|$($P -c "select body like '%└ 첫 구매·초대 결제일 2025.11.20 + 납부 1년(첫해는 가입 때 제외) = % · 7일 전 알림' $FN")"
$P -c "delete from public.notifications where type='membership_fee_due'; delete from public.membership_fee_notices; update public._fd set due_date = '$TODAY'::date - 3, days_left = -3, short = 1 where user_id='$M2'" >/dev/null
$P -c "select public.taam_membership_fee_notify()" >/dev/null
ok "연회비: 단계가 섞이면 제목 「납부 시기 N명」 · 지난 회원 「3일 지남 · 부족 1건」" "💰 연회비 납부 시기 2명|t" \
   "$($P -c "select title $FN")|$($P -c "select body like '%신회원 · T · 2년차 연회비 ₩630,000 · 기준일 % (3일 지남) · 부족 1건%' $FN")"

# 다시 RUN · 모르는 판
out2=$($P -f supabase/migrations/20261112_reminder_day_admin.sql 2>&1)
ok "두 번째 RUN: ✅ 이미 새 판 둘 · ❌ 0 · 오류 없음" "1|1|0|" "$(echo "$out2" | grep -c '✅ 이미 새 판(날짜마다 한 번)')|$(echo "$out2" | grep -c '✅ 이미 새 판(계산 근거)')|$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep ERROR | head -1)"
$P -c "create or replace function public._taam_visit_reminder_admin() returns jsonb language plpgsql as \$\$ begin return '{}'::jsonb; end \$\$;
       create or replace function public.taam_membership_fee_notify(p_today date default null) returns jsonb language plpgsql as \$\$ begin return '{}'::jsonb; end \$\$" >/dev/null
out3=$($P -f supabase/migrations/20261112_reminder_day_admin.sql 2>&1)
ok "모르는 판: ❌ 건너뜀 둘 · 덮어쓰지 않음" "2|0|0" "$(echo "$out3" | grep -cE '❌ 라이브 본문이 2026-10-(27|17) 판')|$($P -c "select count(*) from pg_proc where proname='_taam_visit_reminder_admin' and prosrc like '%VR_ADMIN_DAY_20261112%'")|$($P -c "select count(*) from pg_proc where proname='taam_membership_fee_notify' and prosrc like '%FEE_NOTIFY_V2_20261112%'")"

[ -z "$KEEP" ] && psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ "$FAIL" = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
