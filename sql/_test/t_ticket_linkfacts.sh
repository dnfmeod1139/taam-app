#!/bin/bash
# 좌석 행의 결제 링크·초대 연결 칸 가드 (supabase/migrations/20261028_ticket_link_facts_guard.sql · 3차 판) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_ticket_linkfacts.sh
#   앱이 직접 보낸 문장(current_user = authenticated)만 본다 — 시험도 set role authenticated 로 그 모양을 만든다. 서버 함수(security definer)·서버 세션은 그대로.
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261028_ticket_link_facts_guard.sql
FAIL=0
DB=t_linkfacts; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M=b1000000-0000-4000-8000-000000000001; M2=b1000000-0000-4000-8000-000000000002; AD=b1000000-0000-4000-8000-000000000008; SU=b1000000-0000-4000-8000-000000000009
PT=b1000000-0000-4000-8000-000000000007   # 파트너 — role 'user' + admin_grants (매장 어드민 권한은 역할이 아니라 grants 로 온다)
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema auth; grant usage on schema auth to authenticated, anon;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, role text);
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path = public as \$\$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('superadmin','super_admin')) \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, purchase_id text, status text, extra_data jsonb default '{}', price bigint, party_size int);
grant select, insert, update on public.tickets to authenticated; grant select on public.profiles to authenticated;
-- 서버 함수 흉내: 매장 어드민(파트너)의 결제 링크 만들기 — security definer 안의 INSERT
create or replace function public.fake_link_create(p_pid text, p_charge text) returns void language plpgsql security definer set search_path = public as \$\$
begin insert into public.tickets(user_id, purchase_id, status, extra_data) values (auth.uid(), p_pid, 'hold', jsonb_build_object('linkInvite', true, 'chargeId', p_charge, 'token', 'tk')); end \$\$;
grant execute on function public.fake_link_create(text, text) to authenticated;
-- 서버 함수 흉내: 회원 세션에서 도는 초대 확정 — 홀드 없이 INV- 확정 행을 넣는다
create or replace function public.fake_invite_confirm(p_pid text) returns void language plpgsql security definer set search_path = public as \$\$
begin insert into public.tickets(user_id, purchase_id, status, extra_data) values (auth.uid(), p_pid, 'active', '{"inviteId":"I9","invitePaid":true,"confirmed_at":"2026-10-28T00:00:00Z"}'); end \$\$;
grant execute on function public.fake_invite_confirm(text) to authenticated;
SQL
out=$($P -f "$MIG" 2>&1)
$P <<SQL >/dev/null
insert into public.profiles values ('$M','user'),('$M2','user'),('$AD','admin'),('$SU','superadmin'),('$PT','user');
insert into public.tickets(id,user_id,purchase_id,status,extra_data) values
 ('c0000000-0000-4000-8000-000000000001','$M','LINK-1','active','{"linkInvite":true,"chargeId":"CH1","memberUid":"$M","agencyFee":150000,"agencyPay":110,"currency":"USD","payAmount":1860,"paidAt":"2026-10-18T00:00:00Z"}'),
 ('c0000000-0000-4000-8000-000000000002','$AD','LINK-2','hold','{"linkInvite":true,"chargeId":"CH2","agencyFee":150000}'),
 ('c0000000-0000-4000-8000-000000000003','$M','INV-abcd1234-1','active','{"inviteId":"I1","confirmed_at":"2026-10-01T00:00:00Z"}');
SQL
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1 — 기대 [$3] 실제 [$2]"; FAIL=1; fi; }
AS(){ $P -c "set role authenticated; set taam.uid='$1'; $2" 2>&1; }      # 앱이 직접 보낸 문장
Q(){ $P -c "$1"; }
echo "$out" | grep -q "❌" && { echo "❌ 설치 확인 표에 ❌"; echo "$out"; FAIL=1; } || echo "✅ 설치 확인 표"
T1=c0000000-0000-4000-8000-000000000001
AS "$M" "update public.tickets set status='cancelled', extra_data = extra_data || '{\"chargeId\":\"x\",\"agencyPay\":0,\"agencyFee\":0,\"cancel_reason\":\"회원 취소\"}' where id='$T1';" >/dev/null
ok "회원(직접) — chargeId 되돌림" "$(Q "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH1"
ok "회원(직접) — agencyPay·agencyFee 되돌림" "$(Q "select (extra_data->>'agencyPay') || '/' || (extra_data->>'agencyFee') from public.tickets where id='$T1'")" "110/150000"
ok "같은 갱신의 다른 칸(상태·취소 사유)은 그대로" "$(Q "select status || '/' || (extra_data->>'cancel_reason') from public.tickets where id='$T1'")" "cancelled/회원 취소"
AS "$M" "update public.tickets set extra_data = extra_data - 'chargeId' - 'currency' where id='$T1';" >/dev/null
ok "회원(직접) — 지워도 되살아난다" "$(Q "select (extra_data->>'chargeId') || '/' || (extra_data->>'currency') from public.tickets where id='$T1'")" "CH1/USD"
AS "$M" "update public.tickets set extra_data = extra_data || '{\"paidAt\":\"2099-01-01T00:00:00Z\"}' where id='$T1';" >/dev/null
ok "회원(직접) — paidAt(연회비 기준일) 되돌림" "$(Q "select extra_data->>'paidAt' from public.tickets where id='$T1'")" "2026-10-18T00:00:00Z"
AS "$M" "update public.tickets set extra_data = extra_data || '{\"inviteId\":\"I2\",\"confirmed_at\":\"2099-01-01\"}' where purchase_id='INV-abcd1234-1';" >/dev/null
ok "회원(직접) — inviteId·confirmed_at 되돌림" "$(Q "select (extra_data->>'inviteId') || '/' || (extra_data->>'confirmed_at') from public.tickets where purchase_id='INV-abcd1234-1'")" "I1/2026-10-01T00:00:00Z"
AS "$M" "update public.tickets set extra_data = 'null'::jsonb where id='$T1';" >/dev/null
ok "회원(직접) — extra_data 를 통째로 null 로 바꿔도 되돌림" "$(Q "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH1"
AS "$AD" "update public.tickets set extra_data = extra_data || '{\"agencyFee\":0,\"chargeId\":\"x\",\"memo\":\"m\"}' where purchase_id='LINK-2';" >/dev/null
ok "매장 어드민(직접) — 결제 링크 좌석의 연결·대행비 칸 되돌림 · 다른 칸은 그대로" "$(Q "select (extra_data->>'agencyFee') || '/' || (extra_data->>'chargeId') || '/' || (extra_data->>'memo') from public.tickets where purchase_id='LINK-2'")" "150000/CH2/m"
AS "$PT" "update public.tickets set extra_data = extra_data || '{\"agencyPay\":0}' where id='$T1';" >/dev/null
ok "파트너(role user · 남의 행 · 직접) — 되돌림(역할을 안 본다)" "$(Q "select extra_data->>'agencyPay' from public.tickets where id='$T1'")" "110"
AS "$SU" "update public.tickets set extra_data = extra_data || '{\"chargeId\":\"CH9\"}' where id='$T1';" >/dev/null
ok "슈퍼어드민(직접)은 바꿀 수 있다" "$(Q "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH9"
Q "update public.tickets set extra_data = extra_data || '{\"chargeId\":\"CH1\"}' where id='$T1';" >/dev/null
ok "서버 세션(postgres · service_role)은 바꿀 수 있다" "$(Q "select extra_data->>'chargeId' from public.tickets where id='$T1'")" "CH1"
# INSERT
r=$(AS "$AD" "insert into public.tickets(user_id,purchase_id,status,extra_data) values ('$AD','LINK-zz','hold','{\"chargeId\":\"CH2\",\"agencyFee\":0}');")
ok "매장 어드민(직접) — LINK- 좌석 INSERT 거절(같은 chargeId 로 새 홀드)" "$(echo "$r" | grep -c LINK_SEAT_SERVER_ONLY)" "1"
r=$(AS "$AD" "insert into public.tickets(user_id,purchase_id,status,extra_data) values ('$AD','KSK-zz','hold','{}');")
ok "매장 어드민(직접) — KSK- 좌석 INSERT 거절" "$(echo "$r" | grep -c LINK_SEAT_SERVER_ONLY)" "1"
AS "$PT" "select public.fake_link_create('LINK-pt1','CH7');" >/dev/null
ok "파트너의 결제 링크 만들기(서버 함수 · security definer) — chargeId·token 그대로" "$(Q "select (extra_data->>'chargeId') || '/' || (extra_data->>'token') from public.tickets where purchase_id='LINK-pt1'")" "CH7/tk"
AS "$M" "select public.fake_invite_confirm('INV-c7000000-9');" >/dev/null
ok "회원 세션의 초대 확정(서버 함수) — INV- 행 inviteId·confirmed_at 그대로" "$(Q "select (extra_data->>'inviteId') || '/' || (extra_data->>'confirmed_at') from public.tickets where purchase_id='INV-c7000000-9'")" "I9/2026-10-28T00:00:00Z"
AS "$M" "insert into public.tickets(user_id,purchase_id,status,extra_data) values ('$M','PAYH-x','hold','{\"chargeId\":\"CH1\",\"inviteId\":\"I1\",\"eventId\":\"E\",\"agencyFee\":150000,\"seatHold\":true}');" >/dev/null
ok "회원 홀드(직접) — 연결 칸은 지우고 표시용 스냅샷(agencyFee)은 둔다" "$(Q "select coalesce(extra_data->>'chargeId','-') || '/' || coalesce(extra_data->>'inviteId','-') || '/' || coalesce(extra_data->>'eventId','-') || '/' || (extra_data->>'agencyFee') || '/' || (extra_data->>'seatHold') from public.tickets where purchase_id='PAYH-x'")" "-/-/-/150000/true"
AS "$AD" "insert into public.tickets(user_id,purchase_id,status,extra_data) values ('$AD','INVH-abcd1234-2','hold','{\"inviteHold\":true,\"inviteId\":\"I5\",\"chargeId\":\"CHx\"}');" >/dev/null
ok "매장 어드민의 초대 홀드(INVH- · 직접) — inviteId 는 두고 chargeId 는 지움" "$(Q "select (extra_data->>'inviteId') || '/' || coalesce(extra_data->>'chargeId','-') from public.tickets where purchase_id='INVH-abcd1234-2'")" "I5/-"
r=$(AS "$M" "insert into public.tickets(user_id,purchase_id,status,extra_data) values ('$M','LINK-mine','hold','{}');")
ok "회원(직접) — LINK- INSERT 거절" "$(echo "$r" | grep -c LINK_SEAT_SERVER_ONLY)" "1"
out2=$($P -f "$MIG" 2>&1); echo "$out2" | grep -q "❌" && { echo "❌ 재실행"; FAIL=1; } || echo "✅ 재실행"
ok "SECURITY INVOKER" "$(Q "select prosecdef from pg_proc where oid = 'public.taam_guard_ticket_linkfacts'::regproc")" "f"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
