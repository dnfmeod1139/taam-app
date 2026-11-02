#!/bin/bash
# 방문 기록 가드 회귀 — 2026-11-01. 먼저: 로컬 pg. 실행: bash sql/_test/t_visit_guard.sh
#   회원 세션의 visit_status 직접 UPDATE 는 되돌림(다른 칸은 반영) · INSERT 는 비움 · 슈퍼어드민·서버·definer RPC 는 그대로 · 재실행.
cd "$(dirname "$0")/../.."
DB=t_visitguard; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
A=a1000000-0000-4000-8000-000000000011; SU=a1000000-0000-4000-8000-000000000001; PA=a1000000-0000-4000-8000-000000000022
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
insert into auth.users values ('$A'),('$SU'),('$PA');
create table public.profiles(id uuid primary key, display_name text, role text);
insert into public.profiles values ('$A','김회원','user'),('$SU','Super Admin','superadmin'),('$PA','파트너','user');
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path=public as
  \$\$ select exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('super_admin','superadmin')) \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, purchase_id text, status text default 'active',
  price integer, party_size integer default 2, reservation_date text, visit_time text, extra_data jsonb default '{}'::jsonb,
  visit_status text, visit_marked_at timestamptz, visit_marked_by uuid, created_at timestamptz default now());
alter table public.tickets add constraint tickets_visit_status_chk check (visit_status is null or visit_status in ('attended','no_show'));
-- 라이브 모양의 기록 RPC(간략) — definer · 방문일 검사 없이 적는다(여기서 보는 건 「가드를 지나는가」뿐)
create or replace function public.taam_set_ticket_visit(p_ticket_id text, p_status text) returns jsonb language plpgsql security definer set search_path=public as \$\$
begin update public.tickets set visit_status = p_status, visit_marked_at = case when p_status is null then null else now() end, visit_marked_by = case when p_status is null then null else auth.uid() end where id = p_ticket_id::uuid; return jsonb_build_object('ok', true); end \$\$;
grant usage on schema public to authenticated; grant usage on schema auth to authenticated;
grant select, insert, update on public.tickets to authenticated; grant select on public.profiles to authenticated;
grant execute on function public.taam_set_ticket_visit(text, text) to authenticated;
insert into public.tickets(id, user_id, purchase_id, price, reservation_date) values ('b1000000-0000-4000-8000-000000000001','$A','PAYH-1',900000,'2026.12.20');
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
out=$($P -f supabase/migrations/20261101_ticket_visit_guard.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · ④ 0" "|0|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')"
T=b1000000-0000-4000-8000-000000000001
asm(){ $P -c "set role authenticated; set taam.uid='$1'; $2; reset role;" 2>&1; }
st(){ $P -c "select coalesce(visit_status,'-')||'|'||coalesce(visit_marked_by::text,'-')||'|'||status||'|'||coalesce(extra_data->>'memo','-') from public.tickets where id='$T'"; }
# ── 회원 세션 ──
r=$(asm $A "update public.tickets set visit_status='attended', visit_marked_at=now(), visit_marked_by='$A' where id='$T'")
ok "회원 UPDATE visit_status=attended → 되돌림 · 오류 없음" "-|-|active|-|" "$(st)|$(echo "$r" | grep -c ERROR | sed 's/^0$//')"
r=$(asm $A "update public.tickets set visit_status='attended', extra_data = extra_data || '{\"memo\":\"같이\"}'::jsonb where id='$T'")
ok "회원 UPDATE 방문 기록 + 다른 칸 → 방문 기록만 되돌리고 다른 칸은 반영" "-|-|active|같이" "$(st)"
r=$(asm $A "update public.tickets set visit_status='no_show' where id='$T'")
ok "회원 UPDATE no_show → 되돌림" "-|-|active|같이" "$(st)"
r=$(asm $A "insert into public.tickets(user_id, purchase_id, price, reservation_date, visit_status, visit_marked_at, visit_marked_by) values ('$A','PAYH-2',100,'2026.12.21','attended',now(),'$A') returning coalesce(visit_status,'-')||'|'||coalesce(visit_marked_by::text,'-')")
ok "회원 INSERT 에 방문 기록 → 비워서 들어간다" "-|-" "$(echo "$r" | head -1)"
# ── 매장 어드민(파트너 · 글자 role user) 직접 UPDATE 도 되돌림 — RPC 로만 ──
r=$(asm $PA "update public.tickets set visit_status='attended' where id='$T'")
ok "파트너 세션 직접 UPDATE → 되돌림" "-|-|active|같이" "$(st)"
# ── definer RPC 는 지난다(파트너 호출) ──
r=$(asm $PA "select public.taam_set_ticket_visit('$T','attended')")
ok "파트너가 RPC 로 기록 → attended · marked_by=파트너" "attended|$PA|active|같이" "$(st)"
r=$(asm $A "update public.tickets set visit_status=null, visit_marked_by=null where id='$T'")
ok "회원이 기록을 지우려 해도 되돌림" "attended|$PA|active|같이" "$(st)"
r=$(asm $A "update public.tickets set status='cancelled', visit_status='no_show' where id='$T'")
ok "회원 취소(status) + 방문 기록 변경 → 취소는 반영 · 기록은 그대로" "attended|$PA|cancelled|같이" "$(st)"
# ── 슈퍼어드민 · 서버 ──
r=$(asm $SU "update public.tickets set visit_status='no_show', visit_marked_by='$SU' where id='$T'")
ok "슈퍼어드민 직접 UPDATE → 그대로" "no_show|$SU|cancelled|같이" "$(st)"
r=$($P -c "set taam.uid=''; update public.tickets set visit_status='attended', visit_marked_by=null where id='$T'" 2>&1)
ok "서버(uid 없음 · postgres) → 그대로" "attended|-|cancelled|같이" "$(st)"
ok "트리거 하나 · BEFORE · INSERT+UPDATE · invoker" "1|t|t|f" "$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_visit' and not tgisinternal")|$($P -c "select (tgtype::int & 2) = 2 and (tgtype::int & 4) = 4 from pg_trigger where tgname='trg_taam_guard_ticket_visit'")|$($P -c "select (tgtype::int & 16) = 16 from pg_trigger where tgname='trg_taam_guard_ticket_visit'")|$($P -c "select prosecdef from pg_proc where oid=to_regproc('public.taam_guard_ticket_visit')")"
# ── ④ 정보 — 회원 소유자가 찍은 모양 · 백필(시각·사람 없음)은 안 센다 ──
$P -c "set taam.uid=''; update public.tickets set visit_status='attended', visit_marked_at=now(), visit_marked_by='$A' where id='$T'" >/dev/null
# 실제 08-31 백필 문장(sql/ticket_visit_record.sql ⑥)의 모양 — visit_marked_at = coalesce(visit_marked_at, created_at) · marked_by 는 안 적는다
$P -c "set taam.uid=''; insert into public.tickets(user_id, purchase_id, price, reservation_date, status) values ('$A','PAYH-bf',100,'2026.08.01','completed'); update public.tickets set visit_status = coalesce(visit_status,'attended'), visit_marked_at = coalesce(visit_marked_at, created_at) where purchase_id = 'PAYH-bf'" >/dev/null
ok "④ 정보 — marked_by 가 행 소유자인 행 1 · 실제 백필 모양(시각 = 구매 시각 · 사람 없음)은 제외" "1" "$($P -f supabase/migrations/20261101_ticket_visit_guard.sql 2>&1 | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')"
# 가드 전에 회원이 칸 하나만 적은 가장 단순한 모양(시각·사람 없음) 은 센다
$P -c "set taam.uid=''; insert into public.tickets(user_id, purchase_id, price, reservation_date, visit_status) values ('$A','PAYH-naive',100,'2026.12.01','attended')" >/dev/null
ok "④ 정보 — 칸 하나만 적은 모양(시각·사람 없음)은 센다 → 2" "2" "$($P -f supabase/migrations/20261101_ticket_visit_guard.sql 2>&1 | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')"
out2=$($P -f supabase/migrations/20261101_ticket_visit_guard.sql 2>&1)
ok "재실행 안전 · ❌ 0" "0" "$(echo "$out2" | grep -c '❌')"
# ── definer 가 아닌 기록 RPC 가 있으면 가드를 걸지 않고 ③ ❌ ──
$P -c "drop trigger if exists trg_taam_guard_ticket_visit on public.tickets; create or replace function public.taam_set_ticket_visit(p_ticket_id text, p_status text) returns jsonb language sql as \$\$ select '{}'::jsonb \$\$;" >/dev/null 2>&1
out3=$($P -f supabase/migrations/20261101_ticket_visit_guard.sql 2>&1)
ok "definer 아닌 RPC 판 → 트리거 안 걸림 · ①③ ❌ 2" "0|2" "$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_visit' and not tgisinternal")|$(echo "$out3" | grep -c '❌')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
