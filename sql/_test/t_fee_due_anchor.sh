#!/bin/bash
# 연회비 기준일 두 부류 회귀 — 2026-10-19. 먼저: 로컬 pg. 실행: bash sql/_test/t_fee_due_anchor.sh
cd "$(dirname "$0")/../.."
DB=t_fdanchor; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
U=a1000000-0000-4000-8000-0000000000
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
alter default privileges in schema public grant execute on functions to anon, authenticated;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true), '')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true), '') = '1' \$\$;
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true), '') = '1' \$\$;
create or replace function public._taam_ts_safe(p_any text) returns timestamptz language plpgsql immutable as \$\$ begin return nullif(btrim(p_any), '')::timestamptz; exception when others then return null; end \$\$;
grant usage on schema public, auth to authenticated;
create table public.profiles(id uuid primary key, display_name text, role text, membership_tier text, currency text, currency_prev text, created_at timestamptz default now(), membership_joined_at date, deleted_at timestamptz);
create table public.membership_fees(id uuid primary key default gen_random_uuid(), user_id uuid, paid_at date, amount_krw int, fx_currency text, created_at timestamptz default now());
create table public.deposit_transactions(id bigserial primary key, user_id uuid, change_type text, payment_id uuid, created_at timestamptz default now());
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, status text, purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now(), paid_at timestamptz);
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.push_calls(title text, body text, url text, tag text, category text);
create or replace function public.taam_admin_push(p_title text, p_body text, p_url text default '/', p_tag text default null, p_category text default 'admin') returns jsonb language plpgsql as \$\$
begin insert into public.push_calls values (p_title, p_body, p_url, p_tag, p_category); return jsonb_build_object('ok', true); end \$\$;
insert into auth.users select ('${U}' || lpad(g::text, 2, '0'))::uuid from generate_series(11, 24) g;
insert into public.profiles(id, display_name, role, membership_tier, currency, created_at, membership_joined_at, deleted_at) values
 ('${U}11','가나다','user','M','KRW','2026-01-10T00:00:00Z','2024-12-05',null),
 ('${U}12','벽돌','user','M',null,'2024-12-19T16:00:00Z',null,null),
 ('${U}13','게스트','user','A','KRW','2026-01-10T00:00:00Z',null,null),
 ('${U}14','탈퇴','user','M','KRW','2024-01-10T00:00:00Z',null,'2026-01-01T00:00:00Z'),
 ('${U}15','운영자','superadmin','M','KRW','2024-01-10T00:00:00Z',null,null),
 ('${U}16','운영자2','super_admin',null,null,'2024-01-10T00:00:00Z',null,null),
 ('${U}17','Frank','user','T','USD','2026-10-01T00:00:00Z','2026-10-01',null),
 ('${U}18','길동','user','M','KRW','2026-09-25T00:00:00Z','2026-09-25',null),
 ('${U}19','하늬','user','T','KRW','2025-11-06T00:00:00Z','2025-11-06',null),
 ('${U}20','엔화','user','M','JPY','2026-01-01T00:00:00Z','2026-01-01',null),
 ('${U}21','티빈','user','T','','2026-03-01T00:00:00Z','2026-03-01',null);
update public.profiles set currency='KRW' where id in ('${U}17');   -- Frank 도 라이브처럼 잠김 — 기록의 외화로 가려야 한다
insert into public.profiles(id, display_name, role, membership_tier, currency, currency_prev, created_at, membership_joined_at) values
 ('${U}22','Eric','user','M','KRW','USD','2026-08-27T00:00:00Z','2026-08-27'),
 ('${U}23','PrevOnly','user','T','KRW','USD','2027-06-01T00:00:00Z','2027-06-01'),
 ('${U}24','YenFee','user','M','KRW',null,'2026-09-01T00:00:00Z','2026-09-01');
insert into public.membership_fees(user_id, paid_at, amount_krw) values ('${U}11','2024-12-05',1125000), ('${U}19','2025-11-06',630000), ('${U}20','2026-01-01',1125000), ('${U}21','2026-03-01',630000);
insert into public.membership_fees(user_id, paid_at, amount_krw, fx_currency) values ('${U}17','2026-10-01',402695,'USD'), ('${U}22','2026-08-27',1328892,'USD'), ('${U}24','2026-09-01',1125000,'JPY');
insert into public.deposit_transactions(user_id, change_type) values ('${U}11','membership_payment'), ('${U}11','ticket_purchase'), ('${U}12','ticket_purchase');
insert into public.deposit_transactions(user_id, change_type, payment_id) values ('${U}21','membership_payment','e1000000-0000-4000-8000-000000000001'), ('${U}21','membership_payment','e1000000-0000-4000-8000-000000000001');
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P -f supabase/migrations/20261017_membership_fee_due.sql >/dev/null 2>&1
$P -f supabase/migrations/20261017_membership_fee_exempt.sql >/dev/null 2>&1
# 첫 구매 날짜를 고정한다 — 벽돌(12): 원장 ticket_purchase 2025-03-10 · 새 회원 25: 앱 가입 2026-10-12 · 회원 소유 LINK- 티켓 2026-10-15 · 26: 앱 가입만(시작 전) · 27: 초대 결제 2026-10-01 · 28: 기록 2건 + 첫 구매 2024-06-01
$P -c "update public.deposit_transactions set created_at='2025-03-10T03:00:00Z' where user_id='${U}12' and change_type='ticket_purchase'" >/dev/null
$P -c "insert into auth.users values ('${U}25'),('${U}26'),('${U}27'),('${U}28'),('${U}29'),('${U}30'),('${U}31')" >/dev/null
$P -c "insert into public.profiles(id, display_name, role, membership_tier, currency, created_at) values ('${U}25','새회원','user','T','KRW','2026-10-12T01:00:00Z'),('${U}26','아직','user','M','KRW','2026-10-12T01:00:00Z'),('${U}27','초대파','user','M','KRW','2026-09-20T01:00:00Z'),('${U}28','두번낸','user','T','KRW','2024-05-01T01:00:00Z'),('${U}29','갱신함','user','M','KRW','2025-03-01T01:00:00Z'),('${U}30','늦결제','user','M','KRW','2026-09-20T01:00:00Z'),('${U}31','확정일','user','T','KRW','2026-08-20T01:00:00Z')" >/dev/null
$P -c "insert into public.tickets(user_id, status, purchase_id, extra_data, created_at) values ('${U}25','active','LINK-x','{\"linkInvite\":true,\"memberUid\":\"${U}25\"}','2026-10-15T09:00:00Z'), ('${U}26','hold','PAYH-h','{}','2026-10-13T09:00:00Z'), ('${U}26','active','LINK-y','{\"linkInvite\":true}','2026-10-13T09:00:00Z'), ('${U}28','active','PAYC-z','{}','2024-06-01T09:00:00Z'), ('${U}29','active','PAYC-r','{}','2025-03-10T09:00:00Z'), ('${U}31','active','INV-c','{\"confirmed_at\":\"2026-09-05T05:00:00Z\"}','2026-09-01T05:00:00Z')" >/dev/null
$P -c "insert into public.reservation_invites(invitee_user_id, status, created_at, paid_at) values ('${U}27','paid','2026-10-01T05:00:00Z',null), ('${U}26','pending','2026-10-14T05:00:00Z',null), ('${U}30','paid','2026-10-01T05:00:00Z','2026-10-09T05:00:00Z')" >/dev/null
$P -c "insert into public.membership_fees(user_id, paid_at, amount_krw) values ('${U}28','2024-06-01',630000), ('${U}28','2025-06-01',630000), ('${U}29','2026-03-12',1125000)" >/dev/null
out=$($P -f supabase/migrations/20261019_fee_due_anchor.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · 교체 ✅ · ⑥ 은 member_start 가 없어 ⚠(먼저 실행 안내)" "|0|1|1" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체')|$(echo "$out" | grep -c '⚠ 20261019_member_link_rows.sql')"
S="set taam.uid=''; set taam.super='0';"
q(){ $P -c "$S select $2 from public.taam_membership_fee_due(null, date '2026-10-18', true) d where d.user_id='${U}$1'"; }
ok "① 앱 이전 회원(가나다 · 실제 가입일 2024-12-05 · 기록1+앱결제1=2건) → joined 기준 · 기준일 2026-12-05 · paid 2 · 부족 0" "joined|2024-12-05|2026-12-05|2|0|false" "$(q 11 "anchor_kind||'|'||anchor_date||'|'||due_date||'|'||paid||'|'||short||'|'||implicit_first")"
ok "② 앱 이후(벽돌 · 실제 가입일 없음 · 원장 첫 구매 2025-03-10 · 기록 0) → start 기준 · 첫해 암묵 1건 · 기준일 2026-03-10 · 부족 1(2년차 시작) · implicit" "start|2025-03-10|2026-03-10|1|0|1|true|2024-12-20" "$(q 12 "anchor_kind||'|'||anchor_date||'|'||due_date||'|'||paid||'|'||paid_recorded||'|'||short||'|'||implicit_first||'|'||app_signup_date")"
ok "② 회원 소유 LINK- 티켓이 첫 구매(새회원 · 2026-10-15) → start · 기준일 2027-10-15 · D-362 · 정상" "start|2026-10-15|2027-10-15|362|0|2026-10-12" "$(q 25 "anchor_kind||'|'||start_at||'|'||due_date||'|'||days_left||'|'||short||'|'||app_signup_date")"
ok "② 아직 구매·초대 없음(아직 · 홀드·비회원 LINK-·pending 초대는 안 센다) → none · 기준일 없음 · 알림 대상 아님" "none||0|0|2026-10-12" "$(q 26 "anchor_kind||'|'||coalesce(due_date::text,'')||'|'||years||'|'||short||'|'||app_signup_date")"
ok "② 초대 결제가 첫 시작(초대파 · 2026-10-01) → start 2026-10-01 · 기준일 2027-10-01" "start|2026-10-01|2027-10-01" "$(q 27 "anchor_kind||'|'||start_at||'|'||due_date")"
ok "② 기록 2건이면 암묵 없음(두번낸 · 첫 구매 2024-06-01 · 기록 2 · 첫 기록이 첫 기념일 전) → 기준일 2026-06-01 · 3년차 · 부족 1 · implicit false" "start|2026-06-01|3|2|1|false" "$(q 28 "anchor_kind||'|'||due_date||'|'||years||'|'||paid||'|'||short||'|'||implicit_first")"
ok "② 기록 0 → 2년차 갱신 1건(첫 기념일 뒤 · 갱신함 · 첫 구매 2025-03-10 · 기록 2026-03-12) → 암묵 1 + 기록 1 = paid 2 · 기준일 2027-03-10 · 부족 0 (기록 수로 가르면 부족 1 로 남던 결함)" "start|2027-03-10|2|2|1|0|true" "$(q 29 "anchor_kind||'|'||due_date||'|'||years||'|'||paid||'|'||paid_recorded||'|'||short||'|'||implicit_first")"
ok "② 시작일은 결제한 날 — 초대 10-01 발송 · paid_at 10-09 결제(늦결제) → start 2026-10-09" "2026-10-09|2027-10-09" "$(q 30 "start_at||'|'||due_date")"
ok "② 초대 확정 행(INV- · created 09-01 · extra_data.confirmed_at 09-05)은 확정일(확정일) → start 2026-09-05" "2026-09-05" "$(q 31 "start_at")"
ok "매일 알림이 새 함수로 돈다 — 시작 전 회원은 안 알리고 부족·30일 내만" "true" "$($P -c "$S select (public.taam_membership_fee_notify(date '2026-10-18')->>'ok')")"
ok "알림 대상에 「아직」(none)은 없고 벽돌(부족 · 새 기준일 2026-03-10)은 다섯 단계가 적혔다" "0|5" "$($P -c "select (select count(*) from public.membership_fee_notices where user_id='${U}26')||'|'||(select count(*) from public.membership_fee_notices where user_id='${U}12' and due_date=date '2026-03-10')")"
ok "회원 세션은 FORBIDDEN 그대로" "1" "$($P -c "set taam.uid='${U}12'; select count(*) from public.taam_membership_fee_due()" 2>&1 | grep -c FORBIDDEN)"
out2=$($P -f supabase/migrations/20261019_fee_due_anchor.sql 2>&1)
ok "두 번째 RUN: 이미 새 판 → ✅ 그대로 · ❌ 0" "1|0" "$(echo "$out2" | grep -c '이미 새 판')|$(echo "$out2" | grep -c '❌')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
