#!/bin/bash
# 연회비 갱신일 → 종료일 동기화 · 실제 가입일 출시일 가드 회귀 — 2026-10-19. 먼저: 로컬 pg. 실행: bash sql/_test/t_member_until_sync.sh
cd "$(dirname "$0")/../.."
DB=t_musync; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
U=a1000000-0000-4000-8000-0000000000; SU=a1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
          if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if; end \$\$;
alter default privileges in schema public grant execute on functions to anon, authenticated;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true), '')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true), '') = '1' \$\$;
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true), '') = '1' \$\$;
create or replace function public._taam_ts_safe(p_any text) returns timestamptz language plpgsql immutable as \$\$ begin return nullif(btrim(p_any), '')::timestamptz; exception when others then return null; end \$\$;
grant usage on schema public, auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
create table public.profiles(id uuid primary key, display_name text, role text, membership_tier text, currency text, currency_prev text, created_at timestamptz default now(), membership_joined_at date, membership_joined_set_at timestamptz, membership_joined_set_by uuid, deleted_at timestamptz, member_until timestamptz, is_test boolean not null default false, fee_exempt boolean not null default false, fee_exempt_note text);
grant select, update on public.profiles to authenticated;
create table public.membership_fees(id uuid primary key default gen_random_uuid(), user_id uuid, paid_at date, amount_krw int, fx_currency text, created_at timestamptz default now());
create table public.deposit_transactions(id bigserial primary key, user_id uuid, change_type text, payment_id uuid, created_at timestamptz default now());
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, status text, purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), invitee_user_id uuid, status text, created_at timestamptz default now(), paid_at timestamptz);
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create or replace function public.taam_admin_push(p_title text, p_body text, p_url text default '/', p_tag text default null, p_category text default 'admin') returns jsonb language plpgsql as \$\$ begin return '{}'::jsonb; end \$\$;
insert into auth.users select ('${U}' || lpad(g::text, 2, '0'))::uuid from generate_series(11, 19) g;
insert into public.profiles(id, display_name, role, membership_tier, currency, created_at, membership_joined_at, member_until, is_test, fee_exempt) values
 ('${U}11','이전계약','user','M','KRW','2026-06-02T00:00:00Z','2024-12-05','2027-12-31T14:59:59Z',false,false),
 ('${U}12','시월가입','user','M','KRW','2026-10-14T01:00:00Z','2026-10-14','2027-12-31T14:59:59Z',false,false),
 ('${U}13','시작전','user','M','KRW','2026-10-12T01:00:00Z',null,'2027-12-31T14:59:59Z',false,false),
 ('${U}14','테스트','user','T','KRW','2026-05-20T01:00:00Z',null,'2027-12-31T14:59:59Z',true,true),
 ('${U}15','제외','user','M','KRW','2026-08-27T01:00:00Z',null,'2027-12-31T14:59:59Z',false,true),
 ('${U}16','구매자','user','T','KRW','2026-08-31T01:00:00Z',null,'2027-12-31T14:59:59Z',false,false),
 ('${U}17','밀린이전','user','M','KRW','2026-06-01T00:00:00Z','2025-03-10','2027-12-31T14:59:59Z',false,false),
 ('${U}18','출시직후','user','M','KRW','2026-08-25T01:00:00Z','2026-08-25','2027-12-31T14:59:59Z',false,false),
 ('${SU}','Super Admin','superadmin','M','KRW','2024-01-01T00:00:00Z',null,null,false,false);
insert into public.membership_fees(user_id, paid_at, amount_krw) values ('${U}11','2024-12-05',1125000), ('${U}11','2025-12-05',1125000);
insert into public.tickets(user_id, status, purchase_id, extra_data, created_at) values ('${U}12','active','PAYC-a','{}','2026-10-14T05:00:00Z'), ('${U}16','active','PAYC-b','{}','2026-10-05T05:00:00Z');
SQL
# 선행: 연회비 보고 함수들 + 20261015 가드(저장소 원본 = md5 일치해야 교체된다)
$P -f supabase/migrations/20261017_membership_fee_due.sql >/dev/null 2>&1
$P -f supabase/migrations/20261017_membership_fee_exempt.sql >/dev/null 2>&1
$P -f supabase/migrations/20261019_fee_due_anchor.sql >/dev/null 2>&1
awk '/^create or replace function public.taam_guard_membership_joined/{p=1} p{print} /^  for each row execute function public.taam_guard_membership_joined\(\);/{if(p){exit}}' supabase/migrations/20261015_membership_joined.sql > /tmp/_mj_guard.sql
$P -f /tmp/_mj_guard.sql >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "선행: 가드가 저장소 원본으로 올라감" "1" "$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_membership_joined'")"
out=$($P -f supabase/migrations/20261019_member_until_sync.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · 가드 ✅ 교체 · ③⑤⑥ ✅" "|0|1|3" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체')|$(echo "$out" | grep -cE '^ *(③|⑤|⑥).*✅')"
ok "② 출시일 이후 실제 가입일(시월가입 10-14 · 출시직후 08-25)만 지웠다 · 이전계약·밀린이전은 그대로" "시월가입 · 출시직후|2024-12-05|2025-03-10" "$(echo "$out" | grep '②' | sed 's/.*|//')|$($P -c "select membership_joined_at from public.profiles where id='${U}17' or id='${U}11' order by id" | tr '\n' '|' | sed 's/|$//')"
ok "지운 회원의 실제 가입일 null · 감사 칸은 지운 시각으로" "|true" "$($P -c "select coalesce(membership_joined_at::text,'')||'|'||(membership_joined_set_at is not null) from public.profiles where id='${U}12'")"
S="set taam.uid='${SU}'; set taam.super='1';"
ok "가드: 출시일 이후 날짜는 JOINED_AFTER_LAUNCH · 출시 전 날짜는 들어간다" "1|2024-12-11" "$($P -c "$S update public.profiles set membership_joined_at='2026-09-01' where id='${U}13'" 2>&1 | grep -c JOINED_AFTER_LAUNCH)|$($P -c "$S update public.profiles set membership_joined_at='2024-12-11' where id='${U}13' returning membership_joined_at" | head -1)"
$P -c "$S update public.profiles set membership_joined_at=null where id='${U}13'" >/dev/null
# ── 미리보기 ──
q(){ $P -c "$S select $2 from public.taam_member_until_sync(null, false) s where s.user_id='${U}$1'"; }
ok "미리보기 ①: 이전계약(2024-12-05 · 기록 2) → 2026-12-05 · changed" "joined|2026-12-05|true|실제 가입일 기준 갱신일" "$(q 11 "anchor_kind||'|'||to_char(new_until at time zone 'Asia/Seoul','YYYY-MM-DD')||'|'||changed||'|'||reason")"
ok "미리보기 ② 구매 있음: 시월가입(첫 구매 10-14 · 기록 0) → 첫 구매 1년 뒤 2027-10-14" "start|2027-10-14|true" "$(q 12 "anchor_kind||'|'||to_char(new_until at time zone 'Asia/Seoul','YYYY-MM-DD')||'|'||changed")"
ok "미리보기 ② 시작 전: 프로모션 2027-12-31 그대로 → changed false" "none|2027-12-31|false|시작 전 — 프로모션 유지(갱신일 미정)" "$(q 13 "anchor_kind||'|'||to_char(new_until at time zone 'Asia/Seoul','YYYY-MM-DD')||'|'||changed||'|'||reason")"
ok "미리보기: 밀린이전(2025-03-10 · 기록 0 · 2년차) → 과거 2025-03-10 (갱신할 때라는 신호)" "2025-03-10|true" "$(q 17 "to_char(new_until at time zone 'Asia/Seoul','YYYY-MM-DD')||'|'||changed")"
ok "미리보기: 테스트·제외 회원은 목록에 없다 · 구매자(T · 08-31 가입 · 첫 구매 10-05) → 2027-10-05" "0|2027-10-05" "$($P -c "$S select count(*) from public.taam_member_until_sync(null, false) s where s.user_id in ('${U}14','${U}15')")|$(q 16 "to_char(new_until at time zone 'Asia/Seoul','YYYY-MM-DD')")"
ok "미리보기는 아무것도 안 바꾼다" "0" "$($P -c "select count(*) from public.profiles where member_until <> '2027-12-31T14:59:59Z' and id::text like '${U}%'")"
# ── 적용 ──
ok "적용: 바뀐 회원 수 4 · 로그 4 · 이전계약 종료일 2026-12-05 23:59:59 KST" "4|4|2026-12-05 23:59:59" "$($P -c "$S select count(*) filter (where changed) from public.taam_member_until_sync(null, true)")|$($P -c "select count(*) from public.member_until_sync_log")|$($P -c "select to_char(member_until at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS') from public.profiles where id='${U}11'")"
ok "다시 적용하면 바뀔 것 0" "0" "$($P -c "$S select count(*) filter (where changed) from public.taam_member_until_sync(null, true)")"
# ── 납부 기록 → 자동 동기화 ──
$P -c "$S insert into public.membership_fees(user_id, paid_at, amount_krw) values ('${U}11','2026-12-05',1125000)" >/dev/null
ok "연회비 기록이 생기면 그 회원 종료일이 1년 밀린다(2027-12-05) · 로그 +1" "2027-12-05|5" "$($P -c "select to_char(member_until at time zone 'Asia/Seoul','YYYY-MM-DD') from public.profiles where id='${U}11'")|$($P -c "select count(*) from public.member_until_sync_log")"
$P -c "$S delete from public.membership_fees where user_id='${U}11' and paid_at='2026-12-05'" >/dev/null
ok "기록을 지우면 되돌아온다(2026-12-05)" "2026-12-05" "$($P -c "select to_char(member_until at time zone 'Asia/Seoul','YYYY-MM-DD') from public.profiles where id='${U}11'")"
ok "회원 세션은 FORBIDDEN · anon 은 execute 없음" "1|f" "$($P -c "set taam.uid='${U}12'; set taam.super='0'; select count(*) from public.taam_member_until_sync(null,false)" 2>&1 | grep -c FORBIDDEN)|$($P -c "select has_function_privilege('anon','public.taam_member_until_sync(uuid,boolean)','execute')")"
out2=$($P -f supabase/migrations/20261019_member_until_sync.sql 2>&1)
ok "두 번째 RUN: ❌ 0 · 가드 「이미 새 판」 · ② 없음" "0|1|1" "$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep -c '이미 새 판')|$(echo "$out2" | grep -c '②.*|없음')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
