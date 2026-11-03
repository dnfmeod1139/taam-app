#!/bin/bash
# 초대 좌석 취소 → 초대장 취소 회귀 — 2026-11-03. 먼저: 로컬 pg. 실행: bash sql/_test/t_invite_cancel_sync.sh
#   INV- 좌석이 취소·환불되면(어느 세션이든) 같은 초대의 살아 있는 좌석이 없을 때만 reservation_invites paid → cancelled.
#   초대장 가드 두 개(host · row)는 라이브 본문(2026-11-03 pg_get_functiondef)을 그대로 올린다 — 그 가드에 걸려 넘어지지 않는지 본다.
cd "$(dirname "$0")/../.."
DB=t_invcxsync; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
A=a1000000-0000-4000-8000-000000000011; H=a1000000-0000-4000-8000-000000000022; SU=a1000000-0000-4000-8000-000000000001
I1=c1000000-0000-4000-8000-000000000001; I2=c2000000-0000-4000-8000-000000000002; I3=c3000000-0000-4000-8000-000000000003
I4=c4000000-0000-4000-8000-000000000004; I5=c5000000-0000-4000-8000-000000000005; I0=c0000000-0000-4000-8000-000000000000
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
             if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
insert into auth.users values ('$A'),('$H'),('$SU');
create table public.profiles(id uuid primary key, display_name text, role text);
insert into public.profiles values ('$A','유회원','user'),('$H','보낸 어드민','user'),('$SU','Super Admin','superadmin');
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable security definer set search_path=public as
  \$\$ select exists(select 1 from public.profiles p where p.id=u and p.role in ('super_admin','superadmin')) \$\$;
create or replace function public._taam_invite_net_paid(p_inv uuid, p_uid uuid) returns bigint language sql stable as \$\$ select 0::bigint \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, purchase_id text, status text default 'active',
  price integer, party_size integer default 2, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now(), ticket_product_id text);
create table public.ticket_products(id text primary key, agency_fee integer);
insert into public.ticket_products values ('tp1', 150000);
create table public.deposit_transactions(id bigserial primary key, user_id uuid, deposit_type text, change_type text, amount bigint, metadata jsonb default '{}'::jsonb);
grant select, insert on public.deposit_transactions to authenticated; grant usage on sequence public.deposit_transactions_id_seq to authenticated;
create table public.reservation_invites(id uuid primary key, host_user_id uuid, invitee_user_id uuid, status text, pax int, total_amount bigint,
  meal_fee bigint, agency_fee bigint, wine_min bigint, ticket_product_id text, restaurant_id text, paid_at timestamptz, cancelled_at timestamptz,
  invitee_seen boolean default false, restaurant_name text);
-- 라이브 가드 두 개 (2026-11-03 본문 그대로)
CREATE OR REPLACE FUNCTION public.taam_guard_invite_host() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS \$function\$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or public.is_super_admin(v_uid) or pg_trigger_depth() > 1 then return NEW; end if;
  if TG_OP = 'INSERT' then
    if v_uid = NEW.host_user_id and v_uid is distinct from NEW.invitee_user_id then
      NEW.status := 'sent'; NEW.paid_at := null; NEW.cancelled_at := null;
    end if;
    return NEW;
  end if;
  if v_uid = OLD.host_user_id and v_uid is distinct from OLD.invitee_user_id then
    if coalesce(OLD.status, '') <> 'paid' and coalesce(NEW.status, '') = 'paid' then
      raise exception 'INVITE_HOST_PAID_FORBIDDEN: 결제는 받는 회원이 합니다' using errcode = '42501';
    end if;
    if coalesce(OLD.status, '') <> 'paid' then NEW.paid_at := OLD.paid_at; end if;
    if coalesce(OLD.status, '') = 'paid' then
      NEW.invitee_user_id := OLD.invitee_user_id; NEW.total_amount := OLD.total_amount; NEW.pax := OLD.pax;
      NEW.meal_fee := OLD.meal_fee; NEW.agency_fee := OLD.agency_fee; NEW.wine_min := OLD.wine_min;
      NEW.ticket_product_id := OLD.ticket_product_id; NEW.restaurant_id := OLD.restaurant_id; NEW.paid_at := OLD.paid_at;
      if NEW.status is distinct from OLD.status and coalesce(NEW.status, '') <> 'cancelled' then NEW.status := OLD.status; end if;
    end if;
  end if;
  return NEW;
end \$function\$;
CREATE OR REPLACE FUNCTION public.taam_guard_invite_row() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS \$function\$
declare v_uid uuid := auth.uid(); v_net bigint;
begin
  if v_uid is null then return new; end if;
  if coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if v_uid is distinct from old.invitee_user_id or v_uid = old.host_user_id then return new; end if;
  new := jsonb_populate_record(new, to_jsonb(old) - array['status', 'paid_at', 'cancelled_at', 'invitee_seen']);
  if new.status is distinct from old.status then
    if lower(coalesce(old.status, '')) in ('cancelled', 'canceled', 'expired') then
      raise exception 'INVITE_CLOSED: 취소·만료된 초대는 되살릴 수 없습니다 (상태 %)', old.status using errcode = '42501';
    end if;
    if lower(coalesce(new.status, '')) = 'paid' then
      v_net := public._taam_invite_net_paid(old.id, old.invitee_user_id);
      if v_net < coalesce(old.total_amount, 0) then
        raise exception 'INVITE_NOT_PAID: 결제가 확인되지 않았습니다 (원장 결제 %원 · 초대 합계 %원)', v_net, coalesce(old.total_amount, 0) using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end \$function\$;
create trigger trg_taam_guard_invite_host before insert or update on public.reservation_invites for each row execute function public.taam_guard_invite_host();
create trigger trg_taam_guard_invite_row before update on public.reservation_invites for each row execute function public.taam_guard_invite_row();
grant usage on schema public to authenticated; grant usage on schema auth to authenticated;
grant select, insert, update on public.tickets, public.reservation_invites to authenticated; grant select on public.profiles to authenticated;
-- 초대장 다섯 + 이미 어긋난 것 하나(I0 — 마이그레이션이 맞춘다)
insert into public.reservation_invites(id, host_user_id, invitee_user_id, status, pax, total_amount, paid_at, restaurant_name) values
 ('$I0','$H','$A','paid',3,2850000,now(),'타카미츠'), ('$I1','$H','$A','paid',3,2850000,now(),'타카미츠'),
 ('$I2','$H','$A','paid',4,4000000,now(),'아카'), ('$I3','$H','$A','sent',2,2000000,null,'슌지'),
 ('$I4','$H','$A','paid',2,2000000,now(),'나루세'), ('$I5','$H','$A','paid',2,2000000,now(),'오바나');
insert into public.tickets(user_id, purchase_id, status, price, extra_data) values
 ('$A','INV-c0000000-1','cancelled',2850000,'{"inviteId":"$I0"}'),
 ('$A','INV-c1000000-1','active',2850000,'{"inviteId":"$I1"}'),
 ('$A','INV-c2000000-1','active',2000000,'{"inviteId":"$I2"}'), ('$A','INV-c2000000-2','active',2000000,'{"inviteId":"$I2"}'),
 ('$H','INVH-c3000000-1','hold',2000000,'{"inviteId":"$I3"}'),
 ('$A','INV-c4000000-1','active',2000000,'{"inviteId":"$I4"}'),
 ('$A','INV-c5000000-1','active',2000000,'{"inviteId":"not-a-uuid"}'),
 ('$A','INV-c6000000-1','active',2000000,'{}'),
 ('$A','INV-c7000000-1','cancelled',2000000,'{"inviteId":"c7000000-0000-4000-8000-000000000007","deposit_return":{"type":"returned"}}'),
 ('$A','INV-c8000000-1','active',2000000,'{"inviteId":"c8000000-0000-4000-8000-000000000008"}');
insert into public.reservation_invites(id, host_user_id, invitee_user_id, status, pax, total_amount, paid_at, restaurant_name) values
 ('c6000000-0000-4000-8000-000000000006','$H','$A','paid',2,2000000,now(),'옛좌석'),
 ('c7000000-0000-4000-8000-000000000007','$H','$A','paid',2,2000000,now(),'다녀온초대'),
 ('c8000000-0000-4000-8000-000000000008','$H','$A','paid',2,2000000,now(),'방문후반환');
SQL
# 20261022 판 가드(저장소 원본) — md5 가드가 「교체」로 가는지 본다
awk '/^create or replace function public.taam_guard_ledger_refund_paid\(\)/,/for each row execute function public.taam_guard_ledger_refund_paid\(\);/' supabase/migrations/20261022_card_refund_quote2.sql | $P >/dev/null 2>&1
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
out=$($P -f supabase/migrations/20261103_invite_cancel_sync.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · ③ 맞춘 수 1 · ④ ✅ · ⑤ 교체" "|0|1|✅ 0|✅ 교체" "$(echo "$out" | grep -E "ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep '③' | awk -F'|' '{print $NF}')|$(echo "$out" | grep '④' | awk -F'|' '{print $NF}')|$(echo "$out" | grep '⑤' | awk -F'|' '{print $NF}')"
inv(){ $P -c "select status||'|'||(cancelled_at is not null) from public.reservation_invites where id='$1'"; }
ok "이미 어긋난 I0 → cancelled (시각 있음)" "cancelled|true" "$(inv $I0)"
ok "백필은 방문 후 반환(다녀온 초대)을 건드리지 않는다" "paid|false" "$(inv c7000000-0000-4000-8000-000000000007)"
as(){ $P -c "set role authenticated; set taam.uid='$1'; $2; reset role;" 2>&1; }
# ① 슈퍼어드민이 예치금 관리에서 처리(타카미츠 모양)
r=$(as $SU "update public.tickets set status='cancelled', extra_data = extra_data || '{\"deposit_return\":{\"type\":\"penalty\"}}'::jsonb where purchase_id='INV-c1000000-1'")
ok "슈퍼어드민이 INV- 취소 → 초대장 cancelled · 오류 없음" "cancelled|true|0" "$(inv $I1)|$(echo "$r" | grep -c ERROR)"
# ② 좌석이 둘인 초대 — 하나만 취소하면 그대로, 둘 다면 취소 (받는 회원 세션 — 라이브 row 가드를 지난다)
r=$(as $A "update public.tickets set status='cancelled' where purchase_id='INV-c2000000-1'")
ok "좌석 둘 중 하나 취소 → 초대장 paid 그대로" "paid|false" "$(inv $I2)"
r=$(as $A "update public.tickets set status='cancelled' where purchase_id='INV-c2000000-2'")
ok "남은 좌석도 취소(받는 회원 세션) → cancelled" "cancelled|true|0" "$(inv $I2)|$(echo "$r" | grep -c ERROR)"
# ③ 홀드(INVH-)는 결제 전 — 초대장은 그대로
r=$(as $H "update public.tickets set status='cancelled' where purchase_id='INVH-c3000000-1'")
ok "INVH- 홀드 반납 → 초대장 sent 그대로" "sent|false" "$(inv $I3)"
# ④ 상태가 안 바뀌는 갱신 · expired 는 건드리지 않는다
$P -c "update public.tickets set extra_data = extra_data || '{\"memo\":\"x\"}'::jsonb where purchase_id='INV-c4000000-1'"
ok "상태 안 바뀐 갱신 → 그대로" "paid|false" "$(inv $I4)"
$P -c "update public.tickets set status='expired' where purchase_id='INV-c4000000-1'"
ok "INV- 가 expired 로 → 그대로(취소·환불만 본다)" "paid|false" "$(inv $I4)"
# ⑤ 보낸 어드민(host) 세션의 취소 · refunded 도 같다
$P -c "update public.tickets set status='active' where purchase_id='INV-c4000000-1'"
r=$(as $H "update public.tickets set status='refunded' where purchase_id='INV-c4000000-1'")
ok "보낸 어드민 세션 · refunded → cancelled (host 가드는 중첩이라 통과)" "cancelled|true|0" "$(inv $I4)|$(echo "$r" | grep -c ERROR)"
# ⑥ 이미 취소된 초대장의 시각은 안 바뀐다
c1=$($P -c "select cancelled_at from public.reservation_invites where id='$I1'")
$P -c "update public.tickets set status='active' where purchase_id='INV-c1000000-1'; update public.tickets set status='cancelled' where purchase_id='INV-c1000000-1'"
ok "이미 cancelled 인 초대장 → 시각 그대로" "$c1" "$($P -c "select cancelled_at from public.reservation_invites where id='$I1'")"
# ⑦ inviteId 가 uuid 가 아니어도 티켓 취소는 된다
r=$($P -c "update public.tickets set status='cancelled' where purchase_id='INV-c5000000-1' returning status" 2>&1)
ok "inviteId 가 이상해도 티켓 취소는 된다 · 초대장 그대로" "cancelled|paid" "$(echo "$r" | head -1)|$($P -c "select status from public.reservation_invites where id='$I5'")"
# ⑧ 초대장 갱신이 터져도 티켓 취소는 막지 않는다
$P -c "update public.tickets set extra_data='{\"inviteId\":\"$I5\"}', status='active' where purchase_id='INV-c5000000-1'"
$P <<'BOOM'
create function public._boom() returns trigger language plpgsql as $b$ begin raise exception 'boom'; end $b$;
create trigger zz_boom before update on public.reservation_invites for each row execute function public._boom();
BOOM
r=$($P -c "update public.tickets set status='cancelled' where purchase_id='INV-c5000000-1' returning status" 2>&1)
ok "초대장 갱신 예외 → 삼킴 · 티켓은 cancelled · 초대장 paid" "cancelled|paid" "$(echo "$r" | grep -v WARNING | head -1)|$($P -c "select status from public.reservation_invites where id='$I5'")"
$P -c "drop trigger zz_boom on public.reservation_invites"
# ⑩ 방문 후 반환(반환 완료 처리) — 초대장은 그대로 (적대 리뷰)
r=$(as $SU "update public.tickets set status='cancelled', extra_data = extra_data || '{\"super_admin_processed_at\":\"x\",\"deposit_return\":{\"type\":\"returned\"}}'::jsonb where purchase_id='INV-c8000000-1'")
ok "슈퍼어드민 「반환 완료 처리」(type returned) → 초대장 paid 그대로" "paid|false" "$(inv c8000000-0000-4000-8000-000000000008)"
# ⑪ inviteId 가 없는 옛 좌석 — INV- 뒤 8자 + 받는 회원으로 찾는다
r=$(as $SU "update public.tickets set status='cancelled' where purchase_id='INV-c6000000-1'")
ok "inviteId 없는 옛 INV- 좌석 취소 → 접두어로 찾아 cancelled" "cancelled|true" "$(inv c6000000-0000-4000-8000-000000000006)"
# ⑫ 회원 예치금 환불 한도 — 인원 줄일 때 남긴 대행비 (카드 없음)
G=g1000000-0000-4000-8000-000000000001
$P -c "insert into public.tickets(user_id, purchase_id, status, price, party_size, ticket_product_id, created_at, extra_data) values
 ('$A','PAYH-G1','cancelled',1050000,1,'tp1', now() - interval '3 hours', jsonb_build_object('paidBy','deposit','depositUsed',1800000,'pax_changes', jsonb_build_array(jsonb_build_object('at', now() - interval '2 hours','from',2,'to',1,'refund',750000,'price_before',1800000)))),
 ('$A','PAYH-G2','cancelled',1050000,1,'tp1', now() - interval '3 hours', jsonb_build_object('paidBy','deposit','depositUsed',1800000,'pax_changes', jsonb_build_array(jsonb_build_object('at', now() - interval '2 hours 55 minutes','from',2,'to',1,'refund',750000,'price_before',1800000)))),
 ('$A','PAYH-G3','cancelled',900000,1,'tp1', now() - interval '3 hours', jsonb_build_object('paidBy','card+deposit','cardPaid',900000,'depositUsed',900000,'pax_changes', jsonb_build_array(jsonb_build_object('at', now() - interval '2 hours','from',2,'to',1,'refund',750000,'price_before',1800000))));
insert into public.deposit_transactions(user_id, change_type, amount, metadata) values
 ('$A','ticket_purchase',-1800000,'{\"purchase_id\":\"PAYH-G1\"}'),('$A','ticket_pax_change',750000,'{\"purchase_id\":\"PAYH-G1\"}'),
 ('$A','ticket_purchase',-1800000,'{\"purchase_id\":\"PAYH-G2\"}'),('$A','ticket_pax_change',750000,'{\"purchase_id\":\"PAYH-G2\"}'),
 ('$A','ticket_purchase',-900000,'{\"purchase_id\":\"PAYH-G3\"}'),('$A','ticket_pax_change',750000,'{\"purchase_id\":\"PAYH-G3\"}');"
rf(){ as $1 "insert into public.deposit_transactions(user_id, change_type, amount, metadata) values ('$A','ticket_refund',$2,'{\"purchase_id\":\"$3\"}')" | grep -o 'LEDGER_REFUND_EXCEEDS_PAID' | head -1; }
ok "남긴 대행비 ₩150,000 — 회원 환불 ₩900,000(지금 인원 대행비만 뺀 값) 거절" "LEDGER_REFUND_EXCEEDS_PAID" "$(rf $A 900000 PAYH-G1)"
ok "규정 금액 ₩750,000 은 통과(총 1,500,000 = 1,800,000 − 대행비 2명)" "" "$(rf $A 750000 PAYH-G1)"
ok "구매 30분 안에 줄였으면 남긴 대행비 없음 — ₩1,050,000 통과" "" "$(rf $A 1050000 PAYH-G2)"
ok "카드 섞인 구매는 종전 한도(예치금 낸 돈 − 돌려준 것): ₩150,000 통과" "" "$(rf $A 150000 PAYH-G3)"
ok "카드 섞인 구매 — 그 위로는 거절" "LEDGER_REFUND_EXCEEDS_PAID" "$(rf $A 1 PAYH-G3)"
ok "슈퍼어드민은 한도 밖" "" "$(rf $SU 999999 PAYH-G1)"
# ⑨ 권한 · 재실행
ok "회원은 함수를 직접 못 부른다" "f" "$($P -c "select has_function_privilege('authenticated','public.taam_invite_sync_on_seat_cancel()','execute')")"
out2=$($P -f supabase/migrations/20261103_invite_cancel_sync.sql 2>&1)
ok "재실행 — 오류 없음 · ❌ 0 · ③ 1 (⑧ 에서 일부러 어긋나게 남긴 I5 를 맞춘다)" "|0|1|cancelled" "$(echo "$out2" | grep -E "ERROR" | head -1)|$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep '③' | awk -F'|' '{print $NF}')|$($P -c "select status from public.reservation_invites where id='$I5'")"
out3=$($P -f supabase/migrations/20261103_invite_cancel_sync.sql 2>&1)
ok "세 번째 실행 — ③ 0 · ④ ✅ · ⑤ 이미 새 판" "0|✅ 0|✅ 이미 새 판" "$(echo "$out3" | grep '③' | awk -F'|' '{print $NF}')|$(echo "$out3" | grep '④' | awk -F'|' '{print $NF}')|$(echo "$out3" | grep '⑤' | awk -F'|' '{print $NF}')"
$P -c "create or replace function public.taam_guard_ledger_refund_paid() returns trigger language plpgsql as \$\$ begin return new; end \$\$;"
out4=$($P -f supabase/migrations/20261103_invite_cancel_sync.sql 2>&1)
ok "모르는 판이면 ⑤ ❌ 건너뜀(본문 그대로)" "1|t" "$(echo "$out4" | grep '⑤' | grep -c '❌ 모르는 판')|$($P -c "select position('KEPT_AGENCY' in prosrc)=0 from pg_proc where proname='taam_guard_ledger_refund_paid'")"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
