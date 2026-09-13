#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 오류 리포팅 표 — 누가 쓰고 누가 읽나 (2026-09-12)
# ═══════════════════════════════════════════════════════════════
#   ① 비로그인도 적을 수 있다 ⭐ (부팅 실패는 로그인 전에 난다)
#   ② 회원은 남의 오류를 못 읽는다 ⭐
#   ③ 표에 직접 INSERT 는 막힌다 ⭐ (함수로만)
#   ④ 한 시간 60건에서 선다 ⭐ 무한 루프 기기 하나가 표를 못 채운다
#   ⑤ 요약은 슈퍼어드민만 ⭐
#   ⑥ 긴 값은 잘린다 (message 500)
#   ⑦ 정리 함수도 슈퍼어드민만
# 실행: bash sql/_test/t_apperr.sh
# ═══════════════════════════════════════════════════════════════
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
U=c1000000-0000-4000-8000-000000000001
V=c1000000-0000-4000-8000-000000000002
S=c1000000-0000-4000-8000-0000000000ff
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
as(){ # uid|'' , sql
  if [ -z "$1" ]; then $P -c "set role anon; select set_config('taam.uid','',false); $2" 2>&1
  else $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" 2>&1; fi
}

# ── 픽스처: 라이브 모양 (is_super_admin(uuid) · profiles.role) ──
$P -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>/tmp/_ae.err || { echo "❌ 픽스처"; head -3 /tmp/_ae.err; exit 1; }
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as
\$\$ select nullif(current_setting('taam.uid', true), '')::uuid \$\$;
create table public.profiles(id uuid primary key, role text default 'member', display_name text);
create or replace function public.is_super_admin(uid uuid) returns boolean
language sql stable security definer set search_path=public as
\$\$ select exists(select 1 from public.profiles where id = uid and role in ('super_admin','superadmin')) \$\$;
do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
end \$\$;
grant usage on schema public, auth to authenticated, anon;
grant select on public.profiles to authenticated, anon;
insert into auth.users values ('$U'),('$V'),('$S');
insert into public.profiles values ('$U','member','회원'),('$V','member','다른회원'),('$S','super_admin','슈퍼');
SQL
$P -v ON_ERROR_STOP=1 -f sql/app_errors.sql >/dev/null 2>/tmp/_ae.err || { echo "❌ SQL 적용"; head -5 /tmp/_ae.err; exit 1; }

echo "── ① 적기 ──"
as ""   "select public.taam_report_error('boot_stuck','8초 안에 안 뜸',null,'/','2026.09.12-a','android','{}'::jsonb);" >/dev/null
as "$U" "select public.taam_report_error('js','TypeError: x is null','at f (index.html:1)','/','2026.09.12-a','ios','{\"k\":1}'::jsonb);" >/dev/null
ok "비로그인도 적힌다 ⭐" 1 "$($P -c "select count(*) from public.app_errors where user_id is null;" | tail -1)"
ok "회원 것은 user_id·role 이 붙는다" "member" "$($P -c "select role from public.app_errors where user_id='$U';" | tail -1)"

echo "── ② 읽기 ──"
ok "회원은 남의 오류를 못 읽는다 ⭐" 0 "$(as "$V" "select count(*) from public.app_errors;" | tail -1)"
ok "자기 것도 못 읽는다 (읽기는 어드민 몫)" 0 "$(as "$U" "select count(*) from public.app_errors;" | tail -1)"
ok "슈퍼어드민은 읽는다" 2 "$(as "$S" "select count(*) from public.app_errors;" | tail -1)"

echo "── ③ 직접 INSERT ──"
if as "$U" "insert into public.app_errors(kind,message) values('js','직접');" | grep -qi "denied\|permission\|policy"; then echo "✅ 표에 직접 INSERT 는 막힌다 ⭐"; else echo "❌ 직접 INSERT 가 됐다"; FAIL=1; fi
if as ""   "insert into public.app_errors(kind,message) values('js','직접');" | grep -qi "denied\|permission\|policy"; then echo "✅ 익명도 막힌다 ⭐"; else echo "❌ 익명 직접 INSERT 가 됐다"; FAIL=1; fi

echo "── ④ 폭주 ──"
for i in $(seq 1 70); do as "$U" "select public.taam_report_error('js','loop $i');" >/dev/null; done
ok "한 시간 60건에서 선다 ⭐ (1 + 59)" 60 "$($P -c "select count(*) from public.app_errors where user_id='$U';" | tail -1)"
for i in $(seq 1 70); do as "" "select public.taam_report_error('js','anon loop $i');" >/dev/null; done
ok "익명도 60건에서 선다 ⭐" 60 "$($P -c "select count(*) from public.app_errors where user_id is null;" | tail -1)"
ok "다른 회원은 영향 없다" 1 "$(as "$V" "select public.taam_report_error('js','v');" >/dev/null; $P -c "select count(*) from public.app_errors where user_id='$V';" | tail -1)"

echo "── ⑤ 요약 ──"
if as "$U" "select public.taam_error_summary(24);" | grep -q "권한"; then echo "✅ 요약은 회원에게 막힌다 ⭐"; else echo "❌ 회원이 요약을 읽었다"; FAIL=1; fi
SUM=$(as "$S" "select public.taam_error_summary(24);" | tail -1)
ok "슈퍼어드민 요약 total" 121 "$(echo "$SUM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["total"])')"
ok "by_kind 에 boot_stuck 이 있다" 1 "$(echo "$SUM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["by_kind"]["boot_stuck"])')"
ok "top 은 8개 이하" 1 "$(echo "$SUM" | python3 -c 'import sys,json;print(1 if len(json.load(sys.stdin)["top"])<=8 else 0)')"

echo "── ⑥ 자르기 ──"
LONG=$(python3 -c "print('x'*900)")
as "$S" "select public.taam_report_error('js','$LONG');" >/dev/null
ok "message 는 500 에서 잘린다" 500 "$($P -c "select max(length(message)) from public.app_errors where user_id='$S';" | tail -1)"

echo "── ⑦ 정리 ──"
if as "$U" "select public.taam_error_prune();" | grep -q "권한"; then echo "✅ 정리는 회원에게 막힌다"; else echo "❌"; FAIL=1; fi
$P -c "update public.app_errors set created_at = now() - interval '40 day' where user_id='$V';" >/dev/null
ok "30일 지난 것을 지운다" 1 "$(as "$S" "select public.taam_error_prune();" | tail -1)"

echo; [ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
exit $FAIL
