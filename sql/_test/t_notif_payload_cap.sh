#!/bin/bash
# 회원이 만든 알림 payload 크기 제한 회귀 — 2026-10-25. 먼저: 로컬 pg. 실행: bash sql/_test/t_notif_payload_cap.sh
#   실제 taam_notify_admins(sql/audit_hardening_2026-09-13.sql)를 올려 회원 호출 → 슈퍼어드민 알림의 payload 가 잘리는지 본다.
cd "$(dirname "$0")/../.."
DB=t_notifcap; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; SU2=a1000000-0000-4000-8000-000000000002; M=a1000000-0000-4000-8000-000000000011
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
          if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.taam_rate_hit(k text, n int, w interval) returns boolean language sql as \$\$ select true \$\$;
create table public.profiles(id uuid primary key, display_name text, role text);
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, seen boolean default false, created_at timestamptz default now());
insert into public.profiles values ('$SU','슈퍼','super_admin'),('$SU2','슈퍼2','superadmin'),('$M','회원','member');
grant usage on schema public to authenticated, anon; grant all on all tables in schema public to authenticated; grant usage on schema auth to authenticated, anon;
SQL
sed -n '/^create or replace function public.taam_notify_admins(/,/^end \$\$;/p' sql/audit_hardening_2026-09-13.sql | $P >/dev/null 2>&1
$P -c "grant execute on function public.taam_notify_admins(text,text,text,text,jsonb) to authenticated" >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
call(){ $P -c "set local taam.uid='$1'; set local taam.super='$2'; set local role authenticated; select public.taam_notify_admins('$3','제목','본문','/', \$j\$$4\$j\$::jsonb);" 2>&1 | tail -1; }
callx(){ $P -c "set local taam.uid='$1'; set local taam.super='$2'; set local role authenticated; select public.taam_notify_admins('$3','제목','본문','/', $4);" 2>&1 | tail -1; }
BIGX="jsonb_build_object('purchase_id','PAYH-1_1','pad', repeat('x', 3000000))"
# 원본: 회원이 3MB payload 를 꽂는다
ok "원본(트리거 전): 회원 호출이 3MB 그대로 슈퍼어드민 두 명에게" "2" "$(callx $M 0 ticket_purchased "$BIGX")"
ok "  저장된 크기 > 3MB" "t" "$($P -c "select bool_and(octet_length(payload::text) > 3000000) from public.notifications")"
$P -c "delete from public.notifications" >/dev/null
out=$($P -f supabase/migrations/20261025_notif_payload_cap.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
ok "회원 호출 3MB → 저장 성공 2행" "2" "$(callx $M 0 ticket_purchased "$BIGX")"
ok "  긴 문자열은 500자로 · 라우팅 키(purchase_id · actor_id · via) 남음" "500|PAYH-1_1|$M|taam_notify_admins" "$($P -c "select length(payload->>'pad')||'|'||(payload->>'purchase_id')||'|'||(payload->>'actor_id')||'|'||(payload->>'via') from public.notifications limit 1")"
$P -c "delete from public.notifications" >/dev/null
ARR=$(python3 -c "import json; print(json.dumps({'user_id':'$M','rows':[{'x':'y'*200} for _ in range(200)]}))")
ok "회원 호출 큰 배열(>16KB) → 짧은 스칼라만 + payload_truncated" "2" "$(call $M 0 sync_from_storage "$ARR")"
ok "  rows 빠짐 · user_id 남음 · 원래 크기 기록" "f|$M|t" "$($P -c "select (payload ? 'rows')::text::char||'|'||(payload->>'user_id')||'|'||((payload->>'payload_truncated')::int > 16384)::text::char from public.notifications limit 1")"
$P -c "delete from public.notifications" >/dev/null
ok "작은 payload 는 그대로(키·값 동일)" "2" "$(call $M 0 ticket_purchased '{"purchase_id":"PAYH-9_9","ticket_id":"777","pax":2,"amount":850000,"buyer":"최정우"}')"
ok "  pax 숫자 · buyer · 잘림 표시 없음" "2|최정우|f" "$($P -c "select (payload->>'pax')||'|'||(payload->>'buyer')||'|'||(payload ? 'payload_truncated')::text::char from public.notifications limit 1")"
$P -c "delete from public.notifications" >/dev/null
# 슈퍼어드민·서버는 손대지 않는다
ok "슈퍼어드민 호출 큰 payload → 그대로(다른 슈퍼어드민 1명)" "1" "$(call $SU 1 x "{\"pad\":\"$(python3 -c "print('y'*20000)")\"}")"
ok "  20000자 유지" "20000" "$($P -c "select length(payload->>'pad') from public.notifications limit 1")"
$P -c "delete from public.notifications" >/dev/null
ok "서버(uid 없음) 직접 INSERT 큰 payload → 그대로" "20000" "$($P -c "insert into public.notifications(user_id,type,title,payload) values ('$SU','membership_fee_due','t', jsonb_build_object('pad', repeat('z',20000))); select length(payload->>'pad') from public.notifications limit 1;" | tail -1)"
ok "회원이 자기 행 payload 를 UPDATE 로 키워도 잘림" "500" "$($P -c "set local taam.uid='$M'; set local taam.super='0'; update public.notifications set payload = jsonb_build_object('pad', repeat('q',9000)) returning length(payload->>'pad');" | grep -E '^[0-9]+$')"
ok "payload null · 배열은 그대로 통과(오류 없음)" "ok" "$($P -c "set local taam.uid='$M'; set local taam.super='0'; insert into public.notifications(user_id,type,title,payload) values ('$M','t','t',null),('$M','t','t','[1,2]'::jsonb); select 'ok';" 2>&1 | tail -1)"
ok "재실행 안전" "0" "$($P -f supabase/migrations/20261025_notif_payload_cap.sql 2>&1 | grep -cE 'ERROR|❌')"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
