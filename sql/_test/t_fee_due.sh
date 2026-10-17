#!/bin/bash
# 연회비 납부 시기 보고·알림 회귀 — 2026-10-17. 먼저: 로컬 pg. 실행: bash sql/_test/t_fee_due.sh
cd "$(dirname "$0")/../.."
DB=t_feedue; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
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
grant usage on schema public, auth to authenticated;
create table public.profiles(id uuid primary key, display_name text, role text, membership_tier text, currency text, currency_prev text, created_at timestamptz default now(), membership_joined_at date, deleted_at timestamptz);
create table public.membership_fees(id uuid primary key default gen_random_uuid(), user_id uuid, paid_at date, amount_krw int, fx_currency text, created_at timestamptz default now());
create table public.deposit_transactions(id bigserial primary key, user_id uuid, change_type text, payment_id uuid, created_at timestamptz default now());
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
out=$($P -f supabase/migrations/20261017_membership_fee_due.sql 2>&1)
ok "마이그레이션 오류 없음 · ✅ 5 · ⚠ 2(pg_cron 없음 notice + ④) · ❌ 0" "|5|2|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '⚠')|$(echo "$out" | grep -c '❌')"
out2=$($P -f supabase/migrations/20261017_membership_fee_exempt.sql 2>&1)
ok "제외 스위치 마이그레이션 오류 없음 · ✅ 4 · ❌ 0" "|4|0" "$(echo "$out2" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '✅')|$(echo "$out2" | grep -c '❌')"
$P -c "delete from public.membership_fee_notices; delete from public.notifications; delete from public.push_calls" >/dev/null   # ⑤ 가 오늘로 한 번 돌았으므로 비운다
# 연차 수
ok "연차: 2024-12-05 → 2026-10-17 = 2 · 2/29 가입 2026-02-28 = 3 · 2026-02-27 = 2 · 가입 전 0 · 당일 1" "2|3|2|0|1" "$($P -c "select public._taam_fee_years('2024-12-05','2026-10-17') || '|' || public._taam_fee_years('2024-02-29','2026-02-28') || '|' || public._taam_fee_years('2024-02-29','2026-02-27') || '|' || public._taam_fee_years('2026-10-18','2026-10-17') || '|' || public._taam_fee_years('2026-10-17','2026-10-17')")"
# 보고
T=2026-10-17
ok "대상 10명(게스트·탈퇴·운영 계정 제외) · 기준일 순" "벽돌,길동,하늬,가나다,엔화,PrevOnly,Eric,YenFee,Frank,티빈" "$($P -c "select string_agg(display_name, ',' order by due_date, display_name) from public.taam_membership_fee_due(null, '$T')")"
ok "가나다: 실제 가입일 · 기록1+앱결제1=2 · 2년차 · 2026-12-05 D-49 · 부족0" "2024-12-05|manual|2|2|2026-12-05|49|0|0|₩1,125,000|2024-12-05" "$($P -c "select joined_at || '|' || joined_kind || '|' || years || '|' || paid || '|' || due_date || '|' || days_left || '|' || short || '|' || ahead || '|' || fee_hint || '|' || last_paid from public.taam_membership_fee_due('${U}11', '$T')")"
ok "벽돌: created_at UTC 12-19 16:00 → KST 12-20 · 납부0 · 2년차 · 666일 지남 · 부족2" "2024-12-20|app|2|0|2024-12-20|-666|2" "$($P -c "select joined_at || '|' || joined_kind || '|' || years || '|' || paid || '|' || due_date || '|' || days_left || '|' || short from public.taam_membership_fee_due('${U}12', '$T')")"
ok "Frank: currency 는 KRW 로 잠겼지만 기록 외화 USD → \$300 · 2027-10-01" "\$300|2027-10-01|349" "$($P -c "select fee_hint || '|' || due_date || '|' || days_left from public.taam_membership_fee_due('${U}17', '$T')")"
ok "엔화: JPY 는 규정 없음 · 빈 통화는 KRW T → ₩630,000" "JPY — 규정 없음|₩630,000" "$($P -c "select (select fee_hint from public.taam_membership_fee_due('${U}20', '$T')) || '|' || (select fee_hint from public.taam_membership_fee_due('${U}21', '$T'))")"
ok "티빈: 한 결제가 두 주머니 → 원장 2줄 = 1건 · 기록 1 → 납부 2 · 기준일 2028-03-01 · 선납 1" "2|2028-03-01|1" "$($P -c "select paid || '|' || due_date || '|' || ahead from public.taam_membership_fee_due('${U}21', '$T')")"
ok "통화: 기록 외화 USD(Eric) \$990 · 기록 없고 currency_prev USD(PrevOnly) \$300 · 기록 JPY(YenFee) 규정 없음" "\$990|\$300|JPY — 규정 없음" "$($P -c "select (select fee_hint from public.taam_membership_fee_due('${U}22', '$T')) || '|' || (select fee_hint from public.taam_membership_fee_due('${U}23', '$T')) || '|' || (select fee_hint from public.taam_membership_fee_due('${U}24', '$T'))")"
$P -c "insert into public.deposit_transactions(user_id, change_type, created_at) values ('${U}20','membership_payment','2026-01-01 14:59:59.9+09'), ('${U}20','membership_payment','2026-01-01 15:00:00.1+09')" >/dev/null
ok "payment_id 없는 두 줄이 분 경계를 걸쳐도 같은 KST 날짜 = 1건 (엔화 기록1 + 1 = 2)" "2" "$($P -c "select paid from public.taam_membership_fee_due('${U}20', '$T')")"
$P -c "delete from public.deposit_transactions where user_id='${U}20'" >/dev/null
ok "오늘 기본값(p_today 없음)도 돈다" "10" "$($P -c "select count(*) from public.taam_membership_fee_due()")"
# 권한
ok "회원 세션 → FORBIDDEN" "FORBIDDEN" "$($P -c "set taam.uid='${U}11'; set taam.super='0'; select count(*) from public.taam_membership_fee_due(null, '$T')" 2>&1 | grep -oE 'FORBIDDEN' | head -1)"
ok "슈퍼어드민 세션 → 10명" "10" "$($P -c "set taam.uid='${U}15'; set taam.super='1'; select count(*) from public.taam_membership_fee_due(null, '$T')")"
ok "회원 세션은 알림 함수도 FORBIDDEN" "FORBIDDEN" "$($P -c "set taam.uid='${U}11'; set taam.super='0'; select public.taam_membership_fee_notify('$T')" 2>&1 | grep -oE 'FORBIDDEN' | head -1)"
ok "anon 실행 권한 없음 (보고·알림·내부)" "false|false|false" "$($P -c "select has_function_privilege('anon','public.taam_membership_fee_due(uuid,date,boolean)','execute') || '|' || has_function_privilege('anon','public.taam_membership_fee_notify(date)','execute') || '|' || has_function_privilege('anon','public._taam_fee_caller_ok()','execute')")"
# 알림 — 마이그레이션 ⑦ 이 실제 오늘로 한 번 돌았으므로 기록을 비우고 고정 날짜로 다시
$P -c "delete from public.membership_fee_notices; delete from public.notifications; delete from public.push_calls" >/dev/null
r1=$($P -c "select public.taam_membership_fee_notify('$T')")
ok "1회차($T): 벽돌(-666)·길동(-22)·하늬(D-20) 3명 · 슈퍼어드민 2" "3|2|true" "$(echo "$r1" | python3 -c "import json,sys; j=json.load(sys.stdin); print(str(j['notified'])+'|'+str(j['superadmins'])+'|'+str(j['push']['ok']).lower())")"
ok "인앱 알림: 슈퍼어드민 둘에게 1줄씩 · 회원엔 없음 · url /?feedue=1" "2|0|/?feedue=1" "$($P -c "select (select count(*) from public.notifications where type='membership_fee_due' and user_id in ('${U}15','${U}16')) || '|' || (select count(*) from public.notifications where user_id not in ('${U}15','${U}16')) || '|' || (select url from public.notifications limit 1)")"
ok "제목 · 본문 3줄(기준일 순 · 등급 · 남은날 · 연차 · 예상액)" "💰 연회비 납부 시기 3명|벽돌 · M · 2024.12.20 666일 지남 · 2년차 · ₩1,125,000/길동 · M · 2026.09.25 22일 지남 · 1년차 · ₩1,125,000/하늬 · T · 2026.11.06 D-20 · 1년차 · ₩630,000" "$($P -c "select title || '|' || replace(body, E'\n', '/') from public.notifications limit 1")"
ok "푸시 1번 · tag mfee-20261017 · category admin" "1|mfee-20261017|admin" "$($P -c "select count(*) || '|' || min(tag) || '|' || min(category) from public.push_calls")"
ok "기록: 벽돌 5단계 · 길동 4(30,7,0,-7) · 하늬 1(30)" "5|4|1" "$($P -c "select (select count(*) from public.membership_fee_notices where user_id='${U}12') || '|' || (select count(*) from public.membership_fee_notices where user_id='${U}18') || '|' || (select count(*) from public.membership_fee_notices where user_id='${U}19')")"
ok "payload: count 3 · members 3 · 길동 stage -7" "3|3|-7" "$($P -c "select (payload->>'count') || '|' || jsonb_array_length(payload->'members') || '|' || (select m->>'stage' from jsonb_array_elements(payload->'members') m where m->>'name'='길동') from public.notifications limit 1")"
ok "같은 날 2회차: 새로 알릴 것 없음" "0" "$($P -c "select public.taam_membership_fee_notify('$T')->>'notified'")"
ok "  → 알림·푸시 그대로" "2|1" "$($P -c "select (select count(*) from public.notifications) || '|' || (select count(*) from public.push_calls)")"
# ⚠ 알림 호출과 조회를 한 문장에 넣으면 조회가 호출 전 스냅샷을 본다 — 반드시 따로 부른다
ok "10-30: 하늬 D-7 · 길동 35일 지남(-30 단계) 2명 (벽돌은 다 알렸음)" "2" "$($P -c "select public.taam_membership_fee_notify('2026-10-30')->>'notified'")"
ok "  → 본문 2줄" "길동 · M · 2026.09.25 35일 지남 · 1년차 · ₩1,125,000/하늬 · T · 2026.11.06 D-7 · 1년차 · ₩630,000" "$($P -c "select replace(body, E'\n', '/') from public.notifications order by created_at desc limit 1")"
$P -c "insert into public.membership_fees(user_id, paid_at, amount_krw) values ('${U}19','2026-10-31',630000)" >/dev/null
ok "하늬 납부 기록 뒤 11-06: 하늬 기준일 2027 로 밀림 · 가나다가 D-29 로 창에 들어옴 → 1" "1|2027-11-06|365" "$($P -c "select public.taam_membership_fee_notify('2026-11-06')->>'notified'")|$($P -c "select due_date || '|' || days_left from public.taam_membership_fee_due('${U}19', '2026-11-06')")"
ok "  → 본문 가나다 D-29 · 2년차" "가나다 · M · 2026.12.05 D-29 · 2년차 · ₩1,125,000" "$($P -c "select body from public.notifications order by created_at desc limit 1")"
ok "12-05: 가나다 당일(3년차 시작) + 엔화 D-27 → 2명" "2" "$($P -c "select public.taam_membership_fee_notify('2026-12-05')->>'notified'")"
ok "  → 「오늘」 · 3년차 · JPY 규정 없음" "가나다 · M · 2026.12.05 오늘 · 3년차 · ₩1,125,000/엔화 · M · 2027.01.01 D-27 · 1년차 · JPY — 규정 없음" "$($P -c "select replace(body, E'\n', '/') from public.notifications order by created_at desc limit 1")"
$P -c "create or replace function public.taam_admin_push(p_title text, p_body text, p_url text default '/', p_tag text default null, p_category text default 'admin') returns jsonb language plpgsql as \$\$ begin raise exception 'net down'; end \$\$;" >/dev/null
ok "12-12: 푸시가 깨져도 인앱 알림은 간다 (가나다 -7 · push.ok=false · reason)" "1|false|net down" "$($P -c "with r as (select public.taam_membership_fee_notify('2026-12-12') j) select (j->>'notified') || '|' || (j->'push'->>'ok') || '|' || (j->'push'->>'reason') from r")"
ok "  → 인앱 알림 누적 5회 × 슈퍼어드민 2 = 10" "10" "$($P -c "select count(*) from public.notifications")"
# 9명 넘으면 푸시 본문 8줄 + 외 N명, 인앱은 전부
$P -c "create or replace function public.taam_admin_push(p_title text, p_body text, p_url text default '/', p_tag text default null, p_category text default 'admin') returns jsonb language plpgsql as \$\$ begin insert into public.push_calls values (p_title, p_body, p_url, p_tag, p_category); return jsonb_build_object('ok', true); end \$\$;
insert into auth.users select ('${U}' || g::text)::uuid from generate_series(30, 41) g;
insert into public.profiles(id, display_name, role, membership_tier, currency, created_at, membership_joined_at) select ('${U}' || g::text)::uuid, 'm' || g, 'user', 'T', 'KRW', '2025-01-01', '2025-01-01' from generate_series(30, 41) g;" >/dev/null
ok "2027-01-15: 새 T 12명(3년차 · 부족3) + 가나다(-41→-30) + 엔화(-14→-7) = 14명" "14" "$($P -c "select public.taam_membership_fee_notify('2027-01-15')->>'notified'")"
ok "  → 인앱 본문 14줄 · 푸시 8줄 + 「외 6명」 · 제목 14명 · 첫 줄 m30 3년차 부족" "14|9|외 6명|💰 연회비 납부 시기 14명|m30 · T · 2025.01.01 744일 지남 · 3년차 · ₩630,000" "$($P -c "select (select array_length(string_to_array(body, E'\n'), 1) from public.notifications order by created_at desc limit 1) || '|' || (select array_length(string_to_array(body, E'\n'), 1) from public.push_calls order by tag desc limit 1) || '|' || (select split_part(body, E'\n', 9) from public.push_calls order by tag desc limit 1) || '|' || (select title from public.push_calls order by tag desc limit 1) || '|' || (select split_part(body, E'\n', 1) from public.notifications order by created_at desc limit 1)")"
$P -c "insert into auth.users select ('${U}' || g::text)::uuid from generate_series(50, 90) g;
insert into public.profiles(id, display_name, role, membership_tier, currency, created_at, membership_joined_at) select ('${U}' || g::text)::uuid, 'Michael Minku Lee ' || g, 'user', 'M', 'KRW', '2025-01-01', '2025-01-01' from generate_series(50, 90) g;" >/dev/null
ok "2027-03-01: 긴 이름 41명 + 엔화(-59→-30) = 42명" "42" "$($P -c "select public.taam_membership_fee_notify('2027-03-01')->>'notified'")"
ok "  → 인앱 본문은 줄 단위로 1000자 안 · 마지막 줄 「외 N명 — 전원은…」 · 그 앞 줄은 온전 · 첫 줄 Michael 50" "true|true|Michael Minku Lee 50 · M · 2025.01.01 789일 지남 · 3년차 · ₩1,125,000|true" "$($P -c "with b as (select body, string_to_array(body, E'\\n') as l from public.notifications order by created_at desc limit 1) select (length(body) <= 1000) || '|' || (l[array_length(l,1)] like '외 %명 — 전원은 「연회비 납부 시기」 화면에서') || '|' || l[1] || '|' || (l[array_length(l,1)-1] like '% · ₩1,125,000') from b")"
ok "  → 표시 줄 수 + 외 N = 42 · 푸시는 8줄 + 외 34명" "42|9|외 34명" "$($P -c "with b as (select string_to_array(body, E'\\n') as l from public.notifications order by created_at desc limit 1) select ((array_length(l,1) - 1) + substring(l[array_length(l,1)] from '외 (\\d+)명')::int) || '|' || (select array_length(string_to_array(body, E'\\n'), 1) from public.push_calls order by tag desc limit 1) || '|' || (select split_part(body, E'\\n', 9) from public.push_calls order by tag desc limit 1) from b")"
# ── 연회비 대상 제외 ──
N0=$($P -c "select count(*) from public.taam_membership_fee_due(null, '$T')")
$P -c "update public.profiles set fee_exempt = true, fee_exempt_note = '테스트 계정' where id = '${U}21'" >/dev/null
ok "티빈 제외 → 기본 조회에서 한 명 빠짐 · p_include_exempt 면 보임(fee_exempt true · 메모 · 맨 뒤)" "$((N0-1))|$N0|true|테스트 계정|티빈" "$($P -c "select (select count(*) from public.taam_membership_fee_due(null, '$T')) || '|' || (select count(*) from public.taam_membership_fee_due(null, '$T', true)) || '|' || (select fee_exempt || '|' || fee_exempt_note from public.taam_membership_fee_due('${U}21', '$T', true)) || '|' || (select display_name from public.taam_membership_fee_due(null, '$T', true) order by fee_exempt desc limit 1)")"
ok "  → 누가·언제 기록(set_at) · SQL Editor 는 set_by null" "true|true" "$($P -c "select (fee_exempt_set_at is not null) || '|' || (fee_exempt_set_by is null) from public.profiles where id='${U}21'")"
$P -c "insert into auth.users values ('${U}25'); insert into public.profiles(id, display_name, role, membership_tier, currency, created_at, membership_joined_at, fee_exempt, fee_exempt_note) values ('${U}25','Ex','user','M','KRW','2026-01-01','2026-01-01',true,'면제')" >/dev/null
ok "제외 회원은 밀렸어도 알림 대상이 아님 (2027-05-01 · Ex 만 새 대상)" "0" "$($P -c "select public.taam_membership_fee_notify('2027-05-01')->>'notified'")"
$P -c "update public.profiles set fee_exempt = false where id = '${U}25'" >/dev/null
ok "  → 다시 포함하면 알림 대상 (Ex 1명 · 메모는 그대로 남음)" "1|면제" "$($P -c "select public.taam_membership_fee_notify('2027-05-01')->>'notified'")|$($P -c "select fee_exempt_note from public.profiles where id='${U}25'")"
$P -c "grant select, insert, update on public.profiles to authenticated;" >/dev/null
ok "가드: 회원 세션이 자기 fee_exempt 를 켜도 되돌림(경고) · 메모도 그대로" "false|면제" "$($P -c "set role authenticated; set taam.uid='${U}25'; set taam.super='0'; update public.profiles set fee_exempt = true, fee_exempt_note = '내가 면제' where id='${U}25'; reset role; select fee_exempt || '|' || fee_exempt_note from public.profiles where id='${U}25'" 2>/dev/null)"
ok "가드: 슈퍼어드민 세션은 바꿀 수 있고 set_by 에 uid" "true|${U}15" "$($P -c "set role authenticated; set taam.uid='${U}15'; set taam.super='1'; update public.profiles set fee_exempt = true where id='${U}25'; reset role; select fee_exempt || '|' || fee_exempt_set_by from public.profiles where id='${U}25'" 2>/dev/null)"
ok "가드: 다른 칸만 바꾸는 UPDATE 는 건드리지 않음(기록 유지)" "true|${U}15" "$($P -c "update public.profiles set display_name = 'Ex2' where id='${U}25'; select fee_exempt || '|' || fee_exempt_set_by from public.profiles where id='${U}25'")"
ok "가드: 회원 INSERT 가 fee_exempt=true 로 넣어도 false" "f" "$($P -c "insert into auth.users values ('${U}26'); set role authenticated; set taam.uid='${U}26'; set taam.super='0'; insert into public.profiles(id, display_name, role, membership_tier, fee_exempt) values ('${U}26','Ex3','user','T',true); reset role; select fee_exempt from public.profiles where id='${U}26'" 2>/dev/null)"
ok "RLS: 기록 표는 슈퍼어드민만 읽기 정책 · authenticated select 권한" "membership_fee_notices_super_read|true" "$($P -c "select (select string_agg(policyname, ',') from pg_policies where tablename='membership_fee_notices') || '|' || has_table_privilege('authenticated', 'public.membership_fee_notices', 'select')")"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
