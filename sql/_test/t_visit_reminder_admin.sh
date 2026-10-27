#!/bin/bash
# 방문 리마인드 — 슈퍼어드민 전 일정(수동 추가 포함) 회귀 — 2026-10-27. 먼저: 로컬 pg. 실행: bash sql/_test/t_visit_reminder_admin.sh
cd "$(dirname "$0")/../.."
DB=t_vra; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=c1000000-0000-4000-8000-000000000011; M2=c1000000-0000-4000-8000-000000000012; TT=c1000000-0000-4000-8000-000000000013; SU=c1000000-0000-4000-8000-000000000001
D1=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 1, 'YYYY.MM.DD')"); D3=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 3, 'YYYY.MM.DD')")
D7=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 7, 'YYYY.MM.DD')"); D5=$($P -c "select to_char((now() at time zone 'Asia/Seoul')::date + 5, 'YYYY.MM.DD')")
Y1=$($P -c "select ((now() at time zone 'Asia/Seoul')::date + 1)::text")
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.taam_is_rest_admin(p_rest_id text) returns boolean language sql stable as \$\$ select false \$\$;
insert into auth.users values ('$M'),('$M2'),('$TT'),('$SU');
create table public.profiles(id uuid primary key, display_name text, created_at timestamptz default now(), notif_prefs jsonb default '{}'::jsonb, role text, is_test boolean default false);
insert into public.profiles(id, display_name, role, notif_prefs, is_test) values ('$M','김회원','user','{}',false),('$M2','이회원','user','{}',false),('$TT','테스트1','user','{}',true),('$SU','우댕','superadmin','{}',true);
create table public.restaurants(id text primary key, name text, name_en text, name_jp text, i18n_jp_approved boolean default true);
insert into public.restaurants(id, name, name_en, name_jp) values ('r-mitou','미토우','Mitou','味豆'),('r-saito','스시 사이토',null,null),('r-kanda','칸다','Kanda',null);
create table public.ticket_products(id text primary key, rest_id text, date text, time text);
insert into public.ticket_products values ('tp1','r-mitou','$D1','18:30'),('tp2','r-saito','$D3','12:00'),('tp3','r-kanda','$D7','19:00');
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, reservation_date text, visit_time text, party_size int, status text, purchase_id text, buyer_name text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.daegwan_manual(id uuid primary key default gen_random_uuid(), venue_id text, ymd date, name text, pax int, amount int, memo text, ttype text, venue_name text, created_by uuid, created_at timestamptz default now());
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, change_type text, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now(), paid_at timestamptz);
SQL
awk '/^create or replace function public._taam_fee_caller_ok/{p=1} p{print} /^end \$\$;/{if(p){exit}}' supabase/migrations/20261017_membership_fee_due.sql > /tmp/_vra_fee.sql; $P -f /tmp/_vra_fee.sql >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
for f in sql/visit_reminder.sql supabase/migrations/20261013_member_start.sql supabase/migrations/20261019_member_link_rows.sql supabase/migrations/20261027_visit_reminder_format.sql supabase/migrations/20261027_visit_reminder_title.sql; do $P -f $f >/dev/null 2>&1; done
ok "준비: 라이브와 같은 판(제목 판 md5 3e902422…)" "3e902422c5a93c8e593d617ba93518a2" "$($P -c "select md5(prosrc) from pg_proc where oid=to_regproc('public.taam_visit_reminder_notify')")"

# 일정: ① 우댕 수동 예약(MAN-, 소유 = 슈퍼어드민) 내일 미토우 2인 ② 회원 구매 3일 뒤 사이토 ③ 슈퍼어드민이 회원으로 산 것 내일 미토우 ④ 정산 KSK- 7일 뒤 칸다
#       ⑤ 결제 링크 LINK- 홀드(결제 전) 내일 · ⑥ 취소된 회원 구매 내일 · ⑦ 테스트 계정 회원 구매 내일 · ⑧ 5일 뒤(대상 아님) · ⑨ 수동 기록(daegwan_manual) 내일 칸다
$P -c "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, party_size, status, purchase_id, buyer_name) values
  ('$SU','r-mitou','미토우','tp1','$D1','18:30',2,'manual','MAN-1','우댕'),
  ('$M',null,'스시 사이토','tp2','$D3','12:00',3,'active','PAYH-2',null),
  ('$SU','r-mitou','미토우','tp1','$D1','18:30',1,'active','PAYH-3','우댕'),
  ('$SU','r-kanda','칸다','tp3','$D7','19:00',6,'active','KSK-4','Trina'),
  ('$SU','r-mitou','미토우','tp1','$D1','18:30',2,'hold','LINK-5','비회원'),
  ('$M2','r-mitou','미토우','tp1','$D1','18:30',2,'cancelled','PAYH-6','이회원'),
  ('$TT','r-mitou','미토우','tp1','$D1','18:30',1,'active','PAYH-7','테스트1'),
  ('$M2','r-saito','스시 사이토','tp2','$D5','12:00',2,'active','PAYH-8','이회원')" >/dev/null
$P -c "insert into public.daegwan_manual(venue_id, ymd, name, pax, venue_name) values ('r-kanda','$Y1','우댕',4,'칸다')" >/dev/null

out=$($P -f supabase/migrations/20261027_visit_reminder_admin.sql 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0 · ② 교체" "|0|1" "$(echo "$out" | grep ERROR | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체(슈퍼어드민 전 일정 붙임)')"
[ "$FAIL" = 1 ] && echo "$out"
ok "[예약자] 줄은 넷째 줄 뒤·매장 문구 앞" "1" "$(echo "$out" | grep -cE '^①\|.*\|✅$')"

r=$($P -c "select public.taam_visit_reminder_notify()::text")
ok "실행: 회원 줄 3(김회원 3일 · 슈퍼어드민 본인 구매 1일 · 테스트1 1일) + 슈퍼어드민 몫 3(우댕 MAN- 1일 · 김회원 3일 · 수동 기록 1일) · admin_made 3" "6|3" "$($P -c "select (('$r')::jsonb->>'made')")|$($P -c "select (('$r')::jsonb->>'admin_made')")"
ok "우댕 수동 예약 → 슈퍼어드민: 「내일은 미토우 방문일입니다」 · 본문 넷 + [예약자] : 우댕" "내일은 미토우 방문일입니다|1" "$($P -c "select title from public.notifications where user_id='$SU' and payload->>'rkey' like 't:%' and payload->>'who'='우댕' and payload->>'admin'='true'")|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'admin'='true' and body like E'[레스토랑] : 미토우\\n[날짜] : %\\n[시간] : 오후 6:30\\n[인원] : 2\\n[예약자] : 우댕'")"
ok "회원 구매(김회원 3일 뒤) → 슈퍼어드민에게도 · 회원 본인에게도 · 예약자 = 회원 이름" "스시 사이토 방문 3일 전입니다|1|1" "$($P -c "select title from public.notifications where user_id='$SU' and payload->>'admin'='true' and payload->>'days'='3'")|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'admin'='true' and body like '%[예약자] : 김회원'")|$($P -c "select count(*) from public.notifications where user_id='$M' and payload->>'days'='3'")"
ok "슈퍼어드민이 회원으로 산 것(PAYH-3)은 한 번만(회원 줄) · 수동 기록은 시각 줄 없이 [예약자]" "1|1" "$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where n.user_id='$SU' and t.purchase_id='PAYH-3'")|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'rkey' like 'm:%' and body = E'[레스토랑] : 칸다\\n[날짜] : ' || (select extract(year from d)::int||'년 '||extract(month from d)::int||'월 '||extract(day from d)::int||'일('||(array['일','월','화','수','목','금','토'])[extract(dow from d)::int+1]||')' from (select (now() at time zone 'Asia/Seoul')::date + 1 d) z) || E'\\n[인원] : 4\\n[예약자] : 우댕'")"
ok "빠지는 것: 결제 전 홀드 · 취소 · 테스트 계정 회원 구매(슈퍼어드민 몫) · 5일 뒤 · 7일 전(기본 꺼짐)" "0|0|0|0|0" "$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where t.purchase_id='LINK-5'")|$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where t.purchase_id='PAYH-6'")|$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where t.purchase_id='PAYH-7' and n.user_id='$SU'")|$($P -c "select count(*) from public.notifications n join public.tickets t on t.id::text = n.payload->>'ticket_id' where t.purchase_id='PAYH-8'")|$($P -c "select count(*) from public.notifications where payload->>'days'='7'")"
ok "EN/JA: 제목 영어 · [Name] · [ご予約者](우댕 일정 둘 — 수동 예약·수동 기록)" "Your visit to Mitou is tomorrow|1|2" "$($P -c "select payload->'i18n'->'en'->>'title' from public.notifications where user_id='$SU' and payload->>'rkey' like 't:%' and payload->>'who'='우댕' and payload->>'admin'='true'")|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'admin'='true' and payload->'i18n'->'en'->>'body' like '%[Guests] : 2' || E'\\n' || '[Name] : 우댕'")|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'admin'='true' and payload->'i18n'->'ja'->>'body' like '%[ご予約者] : 우댕'")"
ok "돌려주는 줄(Edge 푸시): 슈퍼어드민 몫 3줄 · tag 열쇠 t:/m: · i18n" "3|3" "$($P -c "select count(*) from jsonb_array_elements(('$r')::jsonb->'rows') x where x->>'ticket_id' ~ '^(t|m):'")|$($P -c "select count(*) from jsonb_array_elements(('$r')::jsonb->'rows') x where x->>'ticket_id' ~ '^(t|m):' and x->'i18n'->'ko'->>'title' is not null")"
ok "다시 부르면 0 (같은 일정·일수 한 번)" "0|0" "$($P -c "select (j->>'made')||'|'||(j->>'admin_made') from public.taam_visit_reminder_notify() j")"

# 7일 전을 켠 슈퍼어드민 → 정산 KSK- 7일 뒤 칸다도 · 하루 전을 끄면 내일 것은 안 감
$P -c "delete from public.notifications; update public.profiles set notif_prefs='{\"remind7\":true,\"remind1\":false}' where id='$SU'" >/dev/null
r2=$($P -c "select public.taam_visit_reminder_notify()::text")
ok "슈퍼어드민 설정: 7일 전 켬 → 정산(KSK-) 칸다 · 하루 전 끔 → 내일 것 없음 · 3일 전은 기본 켜짐" "1|0|1|Trina" "$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'days'='7'")|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'days'='1'")|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'days'='3' and payload->>'admin'='true'")|$($P -c "select payload->>'who' from public.notifications where user_id='$SU' and payload->>'days'='7'")"
$P -c "update public.profiles set notif_prefs='{}' where id='$SU'" >/dev/null

# 위조: 슈퍼어드민 몫이 실패해도(수동 기록 표 없음) 회원 리마인드는 그대로
$P -c "delete from public.notifications; alter table public.daegwan_manual rename to daegwan_manual_x" >/dev/null
r3=$($P -c "select public.taam_visit_reminder_notify()::text" 2>&1)
ok "슈퍼어드민 몫 실패(표 없음) → 회원 줄 3 그대로 · admin_made 0 · 오류로 끝나지 않음" "3|0|0" "$($P -c "select count(*) from public.notifications where payload->>'admin' is null")|$($P -c "select count(*) from public.notifications where payload->>'admin'='true'")|$(echo "$r3" | grep -c '^ERROR')"
$P -c "alter table public.daegwan_manual_x rename to daegwan_manual; delete from public.notifications" >/dev/null
# 회원이 days 'x' 로 위조한 자기 줄 · rkey 위조 → 실행이 멈추지 않는다
$P -c "insert into public.notifications(user_id,type,title,body,payload) values ('$M','visit_reminder','x','y','{\"days\":\"x\",\"rkey\":\"t:zzz\"}')" >/dev/null
ok "위조 줄이 있어도 실행 성공(글자 비교)" "6" "$($P -c "select (public.taam_visit_reminder_notify()->>'made')" 2>&1)"

# 테스트 발송 파일 — 슈퍼어드민만 · 예시 · 앞으로 받을 일정(건수만) · Edge 호출은 설정이 없으면 ⚠ 로 건너뜀
$P -c "create or replace function public._taam_member_push(a uuid,b text,c text,d text,e text,f text,g jsonb) returns jsonb language sql as \$\$ select jsonb_build_object('ok',true,'request_id',42) \$\$" >/dev/null
$P -c "delete from public.notifications" >/dev/null
out4=$($P -f supabase/migrations/20261027_visit_reminder_admin_test.sql 2>&1)
ok "테스트 파일: 오류 없음 · 예시 1건(슈퍼어드민) · [예약자] : 우댕 · 내일 하루 전 2건(수동 기록·수동 예약 · 회원 구매) · 이름 없음 · Edge ⚠ 건너뜀" "|1|1|1|0|1" "$(echo "$out4" | grep ERROR | head -1)|$(echo "$out4" | grep -c 'request_id=42')|$($P -c "select count(*) from public.notifications where user_id='$SU' and payload->>'test'='true' and body like '%[예약자] : 우댕'")|$(echo "$out4" | grep -cE '^B [0-9]{2}-[0-9]{2}\(.+\) 11:00\|하루 전 · 2건 \(')|$(echo "$out4" | grep -c '김회원')|$(echo "$out4" | grep -c '^C Edge 호출|⚠')"
# 다시 RUN · 모르는 판
out2=$($P -f supabase/migrations/20261027_visit_reminder_admin.sql 2>&1)
ok "두 번째 RUN: ✅ 이미 새 판 · ❌ 0" "1|0" "$(echo "$out2" | grep -c '✅ 이미 새 판(슈퍼어드민 전 일정)')|$(echo "$out2" | grep -c '❌')"
$P -c "create or replace function public.taam_visit_reminder_notify() returns jsonb language sql as \$\$ select '{\"made\":0}'::jsonb \$\$" >/dev/null
out3=$($P -f supabase/migrations/20261027_visit_reminder_admin.sql 2>&1)
ok "모르는 판: ❌ 건너뜀 · 덮어쓰지 않음" "1|{\"made\": 0}" "$(echo "$out3" | grep -c '❌ 라이브 본문이')|$($P -c "select public.taam_visit_reminder_notify()")"
[ -z "$KEEP" ] && psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
