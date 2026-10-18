#!/bin/bash
# 테스트 계정 숨김(profiles.is_test) 회귀 — 2026-10-19. 먼저: 로컬 pg. 실행: bash sql/_test/t_test_accounts.sh
cd "$(dirname "$0")/../.."
DB=t_testacc; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
U=a1000000-0000-4000-8000-0000000000; SU=a1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true), '')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true), '') = '1' \$\$;
grant usage on schema public, auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
create table public.profiles(id uuid primary key, display_name text, phone text, email text, role text, deleted_at timestamptz, fee_exempt boolean not null default false, fee_exempt_note text, created_at timestamptz default now());
grant select, update, insert on public.profiles to authenticated;
insert into public.profiles(id, display_name, phone, role, deleted_at, fee_exempt, fee_exempt_note) values
 ('${U}11','김우','010-1111-1111','user',null,false,null),
 ('${U}12',' 테스트1 ','010-2222-2222','user',null,true,'면제'),
 ('${U}13','김우종은','010-3333-3333','user',null,false,null),
 ('${U}14','김우종은','010-4444-4444','user',null,false,null),
 ('${U}15','홍길동','010-5555-5555','user',null,false,null),
 ('${U}18','김우종 ','010-8888-8888','user',null,false,null),
 ('${U}16','테스트1','010-6666-6666','user','2026-01-01T00:00:00Z',false,null),
 ('${SU}','Super Admin','010-0000-0000','superadmin',null,false,null);
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
out=$($P -f supabase/migrations/20261019_test_accounts.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · ✅ 숨김 2 · ⚠ 1(김우종은 2명)" "|0|2|1" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 숨김 + 연회비 제외')|$(echo "$out" | grep -c '⚠ 2명 일치')"
ok "김우: is_test · fee_exempt · 메모 「테스트 계정」 · set_at 있음 · set_by 없음(SQL Editor)" "true|true|테스트 계정|true|" "$($P -c "select is_test||'|'||fee_exempt||'|'||fee_exempt_note||'|'||(is_test_set_at is not null)||'|'||coalesce(is_test_set_by::text,'') from public.profiles where id='${U}11'")"
ok "테스트1: 공백 있는 이름도 맞고 · 기존 면제 메모 「면제」는 그대로 · 탈퇴한 동명(16)은 안 건드린다" "true|true|면제|false" "$($P -c "select (select is_test||'|'||fee_exempt||'|'||fee_exempt_note from public.profiles where id='${U}12')||'|'||(select is_test from public.profiles where id='${U}16')")"
ok "김우종은 둘은 그대로(⚠ · 손으로) · 홍길동 그대로" "false|false|false" "$($P -c "select string_agg(is_test::text, '|' order by id) from public.profiles where id in ('${U}13','${U}14','${U}15')")"
ok "⑤ 정보 줄에 숨긴 계정 이름 둘" "1" "$(echo "$out" | grep -c '⑤.*김우 · 테스트1')"
# ── 가드 ──
ok "회원 세션이 자기 is_test 를 켜면 되돌리고 같은 UPDATE 의 다른 칸은 산다" "false|010-9999-0000" "$($P -c "set role authenticated; set taam.uid='${U}15'; set taam.super='0'; update public.profiles set is_test=true, phone='010-9999-0000' where id='${U}15'; select is_test||'|'||phone from public.profiles where id='${U}15'" 2>/dev/null)"
ok "회원 세션이 숨긴 계정을 끄려 해도 그대로" "t" "$($P -c "set role authenticated; set taam.uid='${U}11'; set taam.super='0'; update public.profiles set is_test=false where id='${U}11'; select is_test from public.profiles where id='${U}11'" 2>/dev/null)"
ok "회원 세션이 감사 칸(set_by)만 보내면 되돌린다" "" "$($P -c "set role authenticated; set taam.uid='${U}11'; set taam.super='0'; update public.profiles set is_test_set_by='${U}11' where id='${U}11'; select coalesce(is_test_set_by::text,'') from public.profiles where id='${U}11'" 2>/dev/null)"
ok "회원 세션 INSERT 에 is_test=true 를 실어도 false" "f" "$($P -c "set role authenticated; set taam.uid='${U}15'; set taam.super='0'; insert into public.profiles(id, display_name, is_test) values ('${U}17','새회원',true); select is_test from public.profiles where id='${U}17'" 2>/dev/null)"
ok "슈퍼어드민 세션이 켜면 켜지고 set_by 가 슈퍼어드민" "true|${SU}" "$($P -c "set role authenticated; set taam.uid='${SU}'; set taam.super='1'; update public.profiles set is_test=true where id='${U}15'; select is_test||'|'||is_test_set_by from public.profiles where id='${U}15'" 2>/dev/null)"
ok "슈퍼어드민이 끄면 꺼지고 기록이 갱신된다(fee_exempt 는 안 건드린다)" "false|${SU}|false" "$($P -c "set role authenticated; set taam.uid='${SU}'; set taam.super='1'; update public.profiles set is_test=false where id='${U}15'; select is_test||'|'||is_test_set_by||'|'||fee_exempt from public.profiles where id='${U}15'" 2>/dev/null)"
# ── 다시 돌리면 ──
out2=$($P -f supabase/migrations/20261019_test_accounts.sql 2>&1)
ok "두 번째 RUN: ❌ 0 · 「이미 숨김」 2 · ⚠ 1" "0|2|1" "$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep -c '✅ 이미 숨김')|$(echo "$out2" | grep -c '⚠ 2명')"
$P -c "update public.profiles set fee_exempt=false where id='${U}11'" >/dev/null
out3=$($P -f supabase/migrations/20261019_test_accounts.sql 2>&1)
ok "숨김인데 연회비 제외가 풀려 있으면 다시 제외하고 「숨김 + 연회비 제외」" "1|t" "$(echo "$out3" | grep -c '김우|✅ 숨김 + 연회비 제외')|$($P -c "select fee_exempt from public.profiles where id='${U}11'")"
# ── 2026-10-19 정정 파일: 「김우종」(공백 포함 이름 · 정확히 한 명) → 숨김 + 연회비 제외 · 두 번째 RUN 은 「이미 숨김」 · ② 줄에 세 이름
out4=$($P -f supabase/migrations/20261019_test_accounts_kimwoojong.sql 2>&1)
ok "정정 파일: 김우종 ✅ 숨김 + 연회비 제외 · is_test·fee_exempt true · ❌ 0" "1|t|t|0" "$(echo "$out4" | grep -c '김우종 *|.*✅ 숨김 + 연회비 제외')|$($P -c "select is_test from public.profiles where id='${U}18'")|$($P -c "select fee_exempt from public.profiles where id='${U}18'")|$(echo "$out4" | grep -c '❌')"
ok "정정 파일 ② 줄: 지금 숨긴 계정에 김우 · 김우종 · 테스트1" "1" "$(echo "$out4" | grep -c '김우 · 김우종 · 테스트1')"
out5=$($P -f supabase/migrations/20261019_test_accounts_kimwoojong.sql 2>&1)
ok "정정 파일 두 번째 RUN: 「이미 숨김」" "1" "$(echo "$out5" | grep -c '✅ 이미 숨김')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
