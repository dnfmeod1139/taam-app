#!/bin/bash
# 회원 좌석 행의 결제 링크·초대 연결 칸 가드 (supabase/migrations/20261028_ticket_link_facts_guard.sql) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_ticket_linkfacts.sh
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261028_ticket_link_facts_guard.sql
FAIL=0
DB=t_linkfacts; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=b1000000-0000-4000-8000-000000000001; M2=b1000000-0000-4000-8000-000000000002; AD=b1000000-0000-4000-8000-000000000008; SU=b1000000-0000-4000-8000-000000000009
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema auth;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, role text);
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable as \$\$ select exists (select 1 from public.profiles where id = u and role in ('superadmin','super_admin')) \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, purchase_id text, status text, extra_data jsonb default '{}', price bigint, party_size int);
SQL
out=$($P -f "$MIG" 2>&1)
$P <<SQL >/dev/null
insert into public.profiles values ('$M','user'),('$M2','user'),('$AD','admin'),('$SU','superadmin');
insert into public.tickets(id,user_id,purchase_id,status,extra_data) values
 ('c0000000-0000-4000-8000-000000000001','$M','LINK-1','active','{"linkInvite":true,"chargeId":"CH1","memberUid":"$M","agencyFee":150000,"agencyPay":110,"currency":"USD","payAmount":1860}'),
 ('c0000000-0000-4000-8000-000000000002','$AD','LINK-2','hold','{"linkInvite":true,"chargeId":"CH2","agencyFee":150000}'),
 ('c0000000-0000-4000-8000-000000000003','$M','INV-abcd1234-1','active','{"inviteId":"I1"}');
SQL
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1 — 기대 [$3] 실제 [$2]"; FAIL=1; fi; }
echo "$out" | grep -q "❌" && { echo "❌ 설치 확인 표에 ❌"; echo "$out"; FAIL=1; } || echo "✅ 설치 확인 표"
T1=c0000000-0000-4000-8000-000000000001
$P -c "set taam.uid='$M'; update public.tickets set status='cancelled', extra_data = extra_data || '{\"chargeId\":\"x\",\"agencyPay\":0,\"agencyFee\":0,\"cancel_reason\":\"회원 취소\"}' where id='$T1';"
ok "회원 주인 — chargeId 되돌림" "$($P -c "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH1"
ok "회원 주인 — agencyPay·agencyFee 되돌림" "$($P -c "select (extra_data->>'agencyPay') || '/' || (extra_data->>'agencyFee') from public.tickets where id='$T1'")" "110/150000"
ok "같은 갱신의 다른 칸(상태·취소 사유)은 그대로" "$($P -c "select status || '/' || (extra_data->>'cancel_reason') from public.tickets where id='$T1'")" "cancelled/회원 취소"
$P -c "set taam.uid='$M'; update public.tickets set extra_data = extra_data - 'chargeId' - 'currency' where id='$T1';"
ok "회원 주인 — 지워도 되살아난다" "$($P -c "select (extra_data->>'chargeId') || '/' || (extra_data->>'currency') from public.tickets where id='$T1'")" "CH1/USD"
$P -c "set taam.uid='$M'; update public.tickets set extra_data = extra_data || '{\"inviteId\":\"I2\"}' where purchase_id='INV-abcd1234-1';"
ok "회원 주인 — 초대 연결(inviteId) 되돌림" "$($P -c "select extra_data->>'inviteId' from public.tickets where purchase_id='INV-abcd1234-1'")" "I1"
$P -c "set taam.uid='$M'; update public.tickets set extra_data = 'null'::jsonb where id='$T1';"
ok "회원 주인 — extra_data 를 통째로 null 로 바꿔도 되돌림" "$($P -c "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH1"
$P -c "set taam.uid='$SU'; update public.tickets set extra_data = extra_data || '{\"chargeId\":\"CH9\"}' where id='$T1';"
ok "슈퍼어드민은 바꿀 수 있다" "$($P -c "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH9"
$P -c "update public.tickets set extra_data = extra_data || '{\"chargeId\":\"CH1\"}' where id='$T1';"
ok "서버(uid 없음)는 바꿀 수 있다" "$($P -c "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH1"
$P -c "set taam.uid='$AD'; update public.tickets set extra_data = extra_data || '{\"agencyFee\":100000}' where purchase_id='LINK-2';"
ok "매장 어드민(자기 행)은 종전대로" "$($P -c "select extra_data->>'agencyFee' from public.tickets where purchase_id='LINK-2'")" "100000"
$P -c "set taam.uid='$M'; update public.tickets set user_id='$M', extra_data = extra_data || '{\"memberUid\":\"$M\",\"chargeId\":\"CH2\"}' where purchase_id='LINK-2';" 2>/dev/null
ok "소유자가 바뀌는 갱신(어드민→회원 이전)은 이 가드가 보지 않는다" "$($P -c "select user_id::text || '/' || (extra_data->>'chargeId') from public.tickets where purchase_id='LINK-2'")" "$M/CH2"
$P -c "set taam.uid='$M2'; update public.tickets set extra_data = extra_data || '{\"chargeId\":\"zz\"}' where id='$T1';"
ok "남의 행은 이 가드가 보지 않는다(RLS·행 가드 몫)" "$($P -c "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "zz"
$P -c "set taam.uid='$M'; insert into public.tickets(user_id,purchase_id,status,extra_data) values ('$M','PAYH-x','hold','{\"chargeId\":\"CH1\",\"inviteId\":\"I1\",\"eventId\":\"E\",\"agencyFee\":150000,\"seatHold\":true}');"
ok "회원 INSERT — 연결 칸은 지우고 표시용 스냅샷(agencyFee)은 둔다" "$($P -c "select coalesce(extra_data->>'chargeId','-') || '/' || coalesce(extra_data->>'inviteId','-') || '/' || coalesce(extra_data->>'eventId','-') || '/' || (extra_data->>'agencyFee') || '/' || (extra_data->>'seatHold') from public.tickets where purchase_id='PAYH-x'")" "-/-/-/150000/true"
out2=$($P -f "$MIG" 2>&1); echo "$out2" | grep -q "❌" && { echo "❌ 재실행"; FAIL=1; } || echo "✅ 재실행"
ok "authenticated 실행 권한 없음" "$($P -c "select has_function_privilege('authenticated','public.taam_guard_ticket_linkfacts()','execute')")" "f"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
