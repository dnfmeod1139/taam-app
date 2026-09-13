#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# single_device_exempt 는 회원이 못 켠다 (2026-09-13)
# ═══════════════════════════════════════════════════════════════
#   profiles 「update own」 정책이 컬럼을 안 가려서, 회원이 자기 면제 플래그를
#   켤 수 있었다 — 단일 기기 규칙과 재구매 제한이 같이 풀린다.
#
#   ① 회원이 켜면 조용히 되돌아간다 ⭐ (같은 UPDATE 의 다른 컬럼은 산다)
#   ② 슈퍼어드민은 켤 수 있다 ⭐
#   ③ 서버(uid null)는 끌 수 있다 (파트너 발급 Edge Function 이 이 길이다)
#   ④ 켜진 뒤 회원이 끄지도 못한다
#
#   ⚠ 픽스처의 RLS 는 라이브 모양을 베낀다 — 「update own」 + 슈퍼어드민 전체.
#     슈퍼어드민 정책을 빼먹고 재면 ②가 RLS 에서 막혀 트리거 탓으로 보인다
#     (처음에 그렇게 틀렸다).
# 실행: bash sql/_test/t_profile_exempt.sh
# ═══════════════════════════════════════════════════════════════
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
U=c1000000-0000-4000-8000-000000000001
S=c1000000-0000-4000-8000-0000000000ff
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0

$P -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>/tmp/_x.err || { echo "❌ 픽스처"; head -3 /tmp/_x.err; exit 1; }
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as
\$\$ select nullif(current_setting('taam.uid', true), '')::uuid \$\$;
create table public.profiles(id uuid primary key, role text default 'member', display_name text,
  notif_prefs jsonb default '{}', single_device_exempt boolean not null default false);
create or replace function public.is_super_admin(uid uuid) returns boolean
language sql stable security definer set search_path=public as
\$\$ select exists(select 1 from public.profiles where id=uid and role in ('super_admin','superadmin')) \$\$;
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
grant usage on schema public, auth to authenticated;
grant select, update on public.profiles to authenticated;
alter table public.profiles enable row level security;
create policy "profiles update own" on public.profiles for update to authenticated
  using (auth.uid()=id) with check (auth.uid()=id);
create policy "super_admin can update all profiles" on public.profiles for update to authenticated
  using (public.is_super_admin(auth.uid())) with check (public.is_super_admin(auth.uid()));
create policy "profiles read" on public.profiles for select to authenticated using (true);
insert into auth.users values ('$U'),('$S');
insert into public.profiles(id,role,display_name) values ('$U','member','회원'),('$S','super_admin','슈퍼');
SQL
$P -v ON_ERROR_STOP=1 -f sql/guard_profile_exempt.sql >/dev/null 2>/tmp/_x.err || { echo "❌ SQL 적용"; head -3 /tmp/_x.err; exit 1; }

as(){ $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" >/dev/null 2>&1; }
ex(){ $P -c "select single_device_exempt from public.profiles where id='$U';" | tail -1; }
nm(){ $P -c "select display_name from public.profiles where id='$U';" | tail -1; }

echo "── ① 회원 ── ⭐"
as $U "update public.profiles set single_device_exempt=true, display_name='이름바꿈' where id='$U';"
ok "회원이 켜도 되돌아간다 ⭐" f "$(ex)"
ok "같은 UPDATE 의 이름 변경은 산다 ⭐" "이름바꿈" "$(nm)"

echo "── ② 슈퍼어드민 ── ⭐"
as $S "update public.profiles set single_device_exempt=true where id='$U';"
ok "슈퍼어드민은 켤 수 있다 ⭐" t "$(ex)"

echo "── ④ 켜진 뒤 회원 ──"
as $U "update public.profiles set single_device_exempt=false where id='$U';"
ok "회원은 끄지도 못한다" t "$(ex)"

echo "── ③ 서버 ──"
$P -c "update public.profiles set single_device_exempt=false where id='$U';" >/dev/null 2>&1
ok "서버(uid null)는 끌 수 있다" f "$(ex)"

echo; [ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
exit $FAIL
