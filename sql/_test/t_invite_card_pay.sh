#!/bin/bash
# 초대 「예치금 + 카드」 서버 함수 (supabase/migrations/20261113_invite_card_pay.sql) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_invite_card_pay.sh
#   실제 저장소 함수 위에서 탄다 — 확정 RPC(taam_invite_confirm_hold) · 초대 결제 가드 1·2 · 소유자 가드 · 중복 가드+규정 예외 · 결제 사실 칸 · 연결 칸 ·
#   카드 환불 견적 1·2 · 초대 취소 동기화. 원장 RPC·환불 한도는 **라이브 본문**(sql/_test/fx_live_ledger_2026-11-13.sql · md5 일치)을 올린다.
#   (2026-11-13 라이브와 md5 가 같은 것: taam_invite_confirm_hold · _taam_invite_net_paid · taam_guard_invite_row/_paid_seat/_owner · taam_guard_purchase_unique ·
#    taam_guard_ticket_payfacts/_linkfacts · taam_card_refund_quote · taam_guard_ledger_refund_active/_paid · taam_invite_sync_on_seat_cancel · taam_apply_deposit_delta · taam_refund_cap)
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261113_invite_card_pay.sql
FAIL=0
DB=${TAAM_TEST_DB:-t_invcardpay}
psql -h /tmp -U postgres -d postgres -q -X -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -X -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At -X"
SU=a0000000-0000-4000-8000-000000000001; HOST=a0000000-0000-4000-8000-000000000002
M1=a0000000-0000-4000-8000-000000000011; M2=a0000000-0000-4000-8000-000000000012; M3=a0000000-0000-4000-8000-000000000013; M4=a0000000-0000-4000-8000-000000000014
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
          if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if; end \$\$;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
insert into auth.users values ('$SU'),('$HOST'),('$M1'),('$M2'),('$M3'),('$M4');
create table public.profiles(id uuid primary key, display_name text, role text, phone text,
  membership_deposit_balance bigint default 0, general_deposit_balance bigint default 0, deposit_balance bigint default 0, membership_tier text);
insert into public.profiles(id, display_name, role, membership_deposit_balance, general_deposit_balance) values
  ('$SU','운영','superadmin',0,0),('$HOST','매장','user',0,0),('$M1','안회원','user',0,8000000),('$M2','김회원','user',3000000,1000000),('$M3','빈회원','user',0,0),('$M4','넉넉회원','user',0,50000000);
create or replace function public.is_super_admin(p uuid) returns boolean language sql stable security definer set search_path=public as
  \$\$ select exists (select 1 from public.profiles where id = p and role in ('superadmin','super_admin')) \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path=public as \$\$ select coalesce(public.is_super_admin(auth.uid()), false) \$\$;
create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable security definer set search_path=public as \$\$
begin if auth.uid() is not null then return public.is_super_admin(auth.uid()); end if; return session_user = 'postgres'; end \$\$;
create or replace function public._taam_sr_int(p text) returns bigint language sql immutable as \$\$ select case when p ~ '^\s*-?\d{1,12}(\.\d+)?\s*\$' then round(p::numeric)::bigint end \$\$;
create or replace function public._taam_sr_ts(p text) returns timestamptz language plpgsql stable as \$\$ begin if p is null or btrim(p) = '' then return null; end if; return p::timestamptz; exception when others then return null; end \$\$;
create table public.rate_hits(k text);
create or replace function public.taam_rate_hit(p_key text, p_limit integer, p_window interval) returns boolean language plpgsql volatile as \$\$
begin insert into public.rate_hits values (p_key); return (select count(*) from public.rate_hits where k = p_key) <= p_limit; end \$\$;
create table public.ticket_products(id text primary key, rest_id text, rest_name text, date text, time text, status text default 'active', type_class text default 'A',
  meal_fee int default 0, agency_fee int default 0, wine_min int default 0, total_pax int default 6, sale_state text);
create or replace function public.taam_ticket_price_krw(p_id text, p_pax int) returns bigint language sql stable as \$\$ select ((coalesce(meal_fee,0)+coalesce(agency_fee,0)+coalesce(wine_min,0))*p_pax)::bigint from public.ticket_products where id = p_id \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, ticket_type text,
  reservation_date text, visit_time text, party_size int, price int, status text, purchase_id text, buyer_name text, buyer_phone text, extra_data jsonb default '{}',
  created_at timestamptz default now(), visit_status text, visit_marked_at timestamptz, visit_marked_by uuid);
create table public.reservation_invites(id uuid primary key, host_user_id uuid, invitee_user_id uuid, restaurant_id text, restaurant_name text, ticket_genre text, type_class text,
  visit_date text, visit_time text, pax int, meal_fee int, agency_fee int, wine_min int, total_amount int, ticket_desc text, cancel_policy jsonb, status text,
  created_at timestamptz default now(), paid_at timestamptz, cancelled_at timestamptz, paid_ticket_id text, invitee_seen boolean default false, ticket_product_id text);
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint,
  description text, payment_id uuid, metadata jsonb default '{}', created_at timestamptz default now());
-- 라이브 모양 (2026-11-13 칸·제약)
create table public.payment_orders(order_id text primary key, user_id uuid not null references auth.users(id) on delete cascade, purpose text not null default 'deposit_charge',
  amount bigint not null check (amount > 0), currency text not null default 'KRW', settle_krw bigint, fx_rate numeric, status text not null default 'pending',
  payment_key text, method text, receipt_url text, approved_at timestamptz, fail_reason text, metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint payment_orders_purpose_chk check (purpose = any (array['package_topup'::text, 'deposit_charge'::text, 'ticket_topup'::text, 'membership'::text])),
  constraint payment_orders_status_chk check (status = any (array['pending'::text, 'paid'::text, 'failed'::text, 'canceled'::text])));
create table public.app_config(key text primary key, value text);
grant usage on schema public, auth to authenticated, anon;
SQL
L(){ $P "$@" 2>&1 | grep -E "ERROR" | head -3; }
sed -n '10,108p' supabase/migrations/20261003_invite_confirm_owner.sql > /tmp/_icp_conf.sql
LOADERR="$(L -f sql/refund_policy_server.sql)$(L -f sql/_test/fx_live_ledger_2026-11-13.sql)$(L -f /tmp/_icp_conf.sql)$(L -f supabase/migrations/20261004_invite_owner_guard.sql)\
$(L -f supabase/migrations/20261022_invite_payment_guard.sql)$(L -f supabase/migrations/20261022_invite_payment_guard2.sql)\
$(L -f supabase/migrations/20261014_purchase_uniqueness.sql)$(L -f supabase/migrations/20261022_purchase_rule_exception.sql)\
$(L -f supabase/migrations/20261022_card_refund_quote.sql)$(L -f supabase/migrations/20261022_card_refund_quote2.sql)\
$(L -f supabase/migrations/20261028_ticket_link_facts_guard.sql)$(L -f supabase/migrations/20261103_invite_cancel_sync.sql)"
out=$($P -f "$MIG" 2>&1)

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $3, 실제 $2)"; FAIL=1; fi; }
q(){ $P -c "$1" 2>&1; }
as(){ local u=$1; shift; $P -c "set taam.uid = '$u'; $*" 2>&1 | grep -v '^SET$'; }
code(){ echo "$1" | grep -oE "(INVITE_NOT_FOUND|INVITE_PAID|INVITE_CLOSED|INVITE_NOT_LINKED|INVITE_EXPIRED|HOLD_GONE|PAYMENT_PENDING|PRICE_NOT_SET|PRICE_CHANGED|RATE_LIMITED|FORBIDDEN|DUPLICATE_PURCHASE|TIME_CONFLICT|ORDER_NOT_FOUND|ORDER_NOT_PAID|ORDER_SUPERSEDED|INSUFFICIENT_DEPOSIT|INVITE_ORDER_CLAIM|REFUND_TICKET_ACTIVE|LEDGER_REFUND_POLICY|LEDGER_REFUND_EXCEEDS|permission denied)" | head -1; }
# 초대 + 초대 홀드(보낸 어드민 소유) — $1 초대 id · $2 받는 회원 · $3 인원 · $4 식사(1인) · $5 대행(1인) · $6 회차 · [$7 방문일] [$8 시각]
newinv(){ local d=${7:-2027.12.15} t=${8:-18:00}; q "insert into public.ticket_products(id, rest_id, rest_name, date, time, meal_fee, agency_fee) values ('$6','r_$6','매장 $6','$d','$t',$4,$5) on conflict do nothing;
  insert into public.reservation_invites(id,host_user_id,invitee_user_id,restaurant_id,restaurant_name,visit_date,visit_time,pax,meal_fee,agency_fee,wine_min,total_amount,status,ticket_product_id)
  values ('$1','$HOST','$2','r_$6','매장 $6','$d','$t',$3,$4,$5,0,($4+$5)*$3,'sent','$6');
  insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,buyer_name,extra_data)
  values ('$HOST','r_$6','매장 $6','$6','$d','$t',$3,($4+$5)*$3,'hold','INVH-$(echo $1 | cut -c1-8)-1','초대 대기', jsonb_build_object('inviteHold', true, 'inviteId', '$1'));" >/dev/null; }
prep(){ q "select public.taam_invite_order_prepare('$1', '$2')"; }
J(){ echo "$1" | python3 -c "import sys,json
try:
  d=json.loads(sys.stdin.read()); print(d.get('$2',''))
except Exception as e: print('ERR')"; }
claim(){ q "select public.taam_invite_order_claim('$1', 'pk_$1', '카드', 'https://r/$1', now(), '{\"status\":\"DONE\"}'::jsonb)->>'claimed'"; }
conf(){ q "select public.taam_invite_confirm_card('$1')"; }
bal(){ q "select membership_deposit_balance || '/' || general_deposit_balance from public.profiles where id = '$1'"; }
inv_st(){ q "select status || '/' || (paid_at is not null) from public.reservation_invites where id = '$1'"; }
hold_st(){ q "select status || '/' || (user_id = '$HOST') || '/' || left(purchase_id, 5) from public.tickets where extra_data->>'inviteId' = '$1' order by created_at desc limit 1"; }

ok "픽스처 — 실제 함수들이 오류 없이 올라갔다" "$LOADERR" ""
ok "마이그레이션: 오류 없음 · ❌ 0" "$(echo "$out" | grep -cE "ERROR")/$(echo "$out" | grep -c '❌')" "0/0"
ok "라이브와 같은 본문(md5) — 확정 RPC · 원장 RPC · 환불 한도 · 카드 환불 견적 · 중복 가드" \
   "$(q "select string_agg(md5(prosrc), ',' order by proname) from pg_proc where pronamespace='public'::regnamespace and proname in ('taam_invite_confirm_hold','taam_apply_deposit_delta','taam_refund_cap','taam_card_refund_quote','taam_guard_purchase_unique')")" \
   "36230be09e2560b57c7dd871a9acbe48,13982fb91adc821aeba7fa14c03db36b,ed27df3b771cb0aa866e3ce50227b0f4,3d7992810e87d9398f13567ae039daa3,cc340b5fa74ef009040cef829364a44b"

echo "── A. 주문 만들기 ──"
I1=c1000000-0000-4000-8000-000000000001
newinv $I1 $M1 3 3300000 200000 tp1
r=$(prep $I1 $M1); O1=$(J "$r" order_id)
ok "A1 초대 ₩10,500,000 · 잔액 ₩8,000,000 → 카드 ₩2,500,000 · 예치금 ₩8,000,000" "$(J "$r" need_payment)/$(J "$r" amount)/$(J "$r" deposit_used)/$(J "$r" total)" "True/2500000/8000000/10500000"
ok "A2 주문 줄 — invite_topup · pending · taaminv_ · 메타(초대·구매 id·합계·인원·예치금 몫 · 대행비·홀드 id 는 적지 않는다 · 회차)" \
   "$(q "select purpose || '/' || status || '/' || (order_id like 'taaminv_%') || '/' || amount || '/' || settle_krw || '/' || (metadata->>'invite_id' = '$I1') || '/' || (metadata->>'purchase_id' like 'INV-c1000000-%') || '/' || (metadata->>'total') || '/' || (metadata->>'pax') || '/' || (metadata->>'deposit_used') || '/' || (metadata ? 'agency_fee') || '/' || (metadata ? 'hold_purchase_id') || '/' || (metadata->>'ticket_id') from public.payment_orders where order_id = '$O1'")" \
   "invite_topup/pending/true/2500000/2500000/true/true/10500000/3/8000000/false/false/tp1"
ok "A3 미리 돌려 본 확정은 흔적이 없다 — 초대 보냄 · 홀드 그대로(보낸 어드민 · INVH-) · 원장 0 · 잔액 그대로" "$(inv_st $I1)|$(hold_st $I1)|$(q "select count(*) from public.deposit_transactions")|$(bal $M1)" "sent/false|hold/true/INVH-|0|0/8000000"
r=$(prep $I1 $M1); O1b=$(J "$r" order_id)
ok "A4 다시 만들면 앞 주문은 닫힌다(superseded) · 새 주문 pending" "$(q "select status || '/' || fail_reason from public.payment_orders where order_id = '$O1'")|$(q "select status from public.payment_orders where order_id = '$O1b'")|$([ "$O1" != "$O1b" ] && echo 다름)" "failed/superseded|pending|다름"
I2=c2000000-0000-4000-8000-000000000002; newinv $I2 $M4 2 800000 100000 tp2 2027.11.01 19:00
r=$(prep $I2 $M4)
ok "A5 잔액이 넉넉하면 주문을 만들지 않는다(need_payment false — 종전 예치금 경로)" "$(J "$r" need_payment)/$(q "select count(*) from public.payment_orders where metadata->>'invite_id' = '$I2'")" "False/0"
I3=c3000000-0000-4000-8000-000000000003; newinv $I3 $M3 2 800000 100000 tp3 2027.11.02 19:00
r=$(prep $I3 $M3); O3=$(J "$r" order_id)
ok "A6 잔액 0 → 전액 카드" "$(J "$r" amount)/$(J "$r" deposit_used)" "1800000/0"
I4=c4000000-0000-4000-8000-000000000004; newinv $I4 $M2 1 3900050 100000 tp4 2027.11.03 19:00    # 합계 4,000,050 · 잔액 4,000,000 → 모자람 50
r=$(prep $I4 $M2)
ok "A7 모자란 금액이 ₩100 미만이면 카드 ₩100(예치금을 그만큼 덜 쓴다)" "$(J "$r" amount)/$(J "$r" deposit_used)" "100/3999950"
ok "A8 남의 초대 → INVITE_NOT_FOUND" "$(code "$(prep $I1 $M2)")" "INVITE_NOT_FOUND"
ok "A9 uuid 가 아닌 값·빈 값 → INVITE_NOT_FOUND" "$(code "$(prep "not-a-uuid" $M1)")/$(code "$(prep "" $M1)")" "INVITE_NOT_FOUND/INVITE_NOT_FOUND"
I5=c5000000-0000-4000-8000-000000000005; newinv $I5 $M3 2 800000 100000 tp5 2027.11.04 19:00
q "update public.reservation_invites set status = 'cancelled' where id = '$I5'" >/dev/null
ok "A10 취소된 초대 → INVITE_CLOSED" "$(code "$(prep $I5 $M3)")" "INVITE_CLOSED"
q "update public.reservation_invites set status = 'paid' where id = '$I5'" >/dev/null
ok "A11 이미 결제된 초대 → INVITE_PAID" "$(code "$(prep $I5 $M3)")" "INVITE_PAID"
q "update public.reservation_invites set status = 'sent', ticket_product_id = null where id = '$I5'" >/dev/null
ok "A12 판매 티켓 미연결 초대 → INVITE_NOT_LINKED" "$(code "$(prep $I5 $M3)")" "INVITE_NOT_LINKED"
q "update public.reservation_invites set ticket_product_id = 'tp5', created_at = now() - interval '47 hours 50 minutes' where id = '$I5'" >/dev/null
ok "A13 만료 직전(47시간 50분) → INVITE_EXPIRED" "$(code "$(prep $I5 $M3)")" "INVITE_EXPIRED"
q "update public.reservation_invites set created_at = now() where id = '$I5'; update public.tickets set status = 'cancelled' where extra_data->>'inviteId' = '$I5'" >/dev/null
ok "A14 초대 홀드가 없으면 → HOLD_GONE" "$(code "$(prep $I5 $M3)")" "HOLD_GONE"
ok "A15 로그인 세션(회원·슈퍼어드민)은 못 부른다 → FORBIDDEN" "$(code "$(as $M1 "select public.taam_invite_order_prepare('$I1', '$M1')")")/$(code "$(as $SU "select public.taam_invite_order_prepare('$I1', '$M1')")")" "FORBIDDEN/FORBIDDEN"
ok "A16 회원·비로그인 역할은 실행 권한이 없다" "$(code "$($P -c "set role authenticated; select public.taam_invite_order_prepare('$I1', '$M1')" 2>&1)")/$(code "$($P -c "set role anon; select public.taam_invite_confirm_card('x')" 2>&1)")" "permission denied/permission denied"
# 미리 돌려 보기 — 중복·시간대
I6=c6000000-0000-4000-8000-000000000006; newinv $I6 $M3 2 800000 100000 tp6 2027.11.05 19:00
q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id) values ('$M3','r_tp6','tp6','2027.11.05','19:00',1,900000,'active','PAYH-tp6_1')" >/dev/null
ok "A17 이미 그 회차를 가진 회원 → DUPLICATE_PURCHASE (카드 승인 전에) · 주문 없음 · 초대·홀드 그대로" "$(code "$(prep $I6 $M3)")|$(q "select count(*) from public.payment_orders where metadata->>'invite_id' = '$I6'")|$(inv_st $I6)|$(hold_st $I6)" "DUPLICATE_PURCHASE|0|sent/false|hold/true/INVH-"
I7=c7000000-0000-4000-8000-000000000007; newinv $I7 $M3 2 800000 100000 tp7 2027.11.05 18:00     # 같은 날 저녁 다른 회차
ok "A18 같은 날 같은 시간대에 다른 예약 → TIME_CONFLICT (카드 승인 전에)" "$(code "$(prep $I7 $M3)")|$(q "select count(*) from public.payment_orders where metadata->>'invite_id' = '$I7'")" "TIME_CONFLICT|0"

echo "── B. 잡기(토스 승인 뒤 pending → paid) ──"
ok "B1 표시 없이 paid 로 바꾸면(옛 toss-confirm 모양) → INVITE_ORDER_CLAIM" "$(code "$(q "update public.payment_orders set status = 'paid', payment_key = 'pk_old', metadata = '{\"toss\":{}}'::jsonb where order_id = '$O1b'")")" "INVITE_ORDER_CLAIM"
ok "B2 잡기 → paid · inv_claim · 메타는 합쳐진다(초대 id 유지 · toss 추가)" "$(claim $O1b)|$(q "select status || '/' || payment_key || '/' || (metadata->>'inv_claim') || '/' || (metadata->>'invite_id' = '$I1') || '/' || (metadata->'toss'->>'status') || '/' || (metadata->>'paid_via') from public.payment_orders where order_id = '$O1b'")" "true|paid/pk_$O1b/toss-invite-pay/true/DONE/window"
ok "B3 다시 잡으면 claimed false · 상태 paid" "$(claim $O1b)/$(q "select public.taam_invite_order_claim('$O1b','pk2','카드',null,now(),'{}'::jsonb)->>'status'")" "false/paid"
ok "B4 닫힌(superseded) 주문은 안 잡힌다" "$(claim $O1)/$(q "select status from public.payment_orders where order_id = '$O1'")" "false/failed"
ok "B5 확정 안 된 paid 주문이 있으면 새 주문을 만들지 않는다 → PAYMENT_PENDING" "$(code "$(prep $I1 $M1)")" "PAYMENT_PENDING"

echo "── C. 확정 — 한 트랜잭션 ──"
r=$(conf $O1b); PID1=$(J "$r" purchase_id)
ok "C1 확정 — 합계·예치금·카드" "$(J "$r" ok)/$(J "$r" total)/$(J "$r" deposit_used)/$(J "$r" card_paid)/$(J "$r" balance_after)" "True/10500000/8000000/2500000/0"
ok "C2 초대 결제됨 · 잔액 0" "$(inv_st $I1)|$(bal $M1)" "paid/true|0/0"
ok "C3 좌석 — 회원 소유 확정 행(INV-) · 금액·인원 · 결제 사실(카드·예치금·주문·대행비)" \
   "$(q "select status || '/' || (user_id = '$M1') || '/' || (purchase_id = '$PID1') || '/' || price || '/' || party_size || '/' || (extra_data->>'cardPaid') || '/' || (extra_data->>'depositUsed') || '/' || (extra_data->>'paidBy') || '/' || (extra_data->>'order_id' = '$O1b') || '/' || (extra_data->>'agencyFee') || '/' || (extra_data->>'inviteId' = '$I1') || '/' || (extra_data ? 'confirmed_at') from public.tickets where extra_data->>'inviteId' = '$I1'")" \
   "active/true/true/10500000/3/2500000/8000000/card+deposit/true/200000/true/true"
ok "C4 원장 — 일반 −8,000,000 한 줄 · 구매 id·초대·주문 · server_written · 잔액 뒤 0" \
   "$(q "select count(*) || '/' || min(deposit_type) || '/' || sum(amount) || '/' || min(change_type) || '/' || bool_and(metadata->>'purchase_id' = '$PID1') || '/' || bool_and(metadata->>'invite_id' = '$I1') || '/' || bool_and(metadata->>'order_id' = '$O1b') || '/' || bool_and((metadata->>'server_written')::boolean) || '/' || min(balance_after) from public.deposit_transactions where user_id = '$M1'")" \
   "1/general/-8000000/ticket_purchase/true/true/true/true/0"
ok "C5 주문에 확정 표시" "$(q "select (metadata->>'inv_settled') || '/' || status from public.payment_orders where order_id = '$O1b'")" "true/paid"
r=$(conf $O1b)
ok "C6 다시 부르면 「이미」 — 두 번 빼지 않는다" "$(J "$r" already)/$(q "select count(*) from public.deposit_transactions where user_id = '$M1'")/$(bal $M1)" "True/1/0/0"
ok "C7 초대 순결제(원장)는 예치금 몫만 — 받는 회원이 그 뒤 초대 줄을 고쳐도(읽음 표시) 가드에 안 걸린다" "$(q "select public._taam_invite_net_paid('$I1', '$M1')")|$(as $M1 "update public.reservation_invites set invitee_seen = true where id = '$I1'")|$(q "select invitee_seen from public.reservation_invites where id = '$I1'")" "8000000||t"
# 두 주머니
I8=c8000000-0000-4000-8000-000000000008; newinv $I8 $M2 2 2900000 100000 tp8 2027.11.06 19:00    # 합계 6,000,000 · 멤버십 3,000,000 + 일반 1,000,000 → 카드 2,000,000
r=$(prep $I8 $M2); O8=$(J "$r" order_id); claim $O8 >/dev/null; r=$(conf $O8)
ok "C8 두 주머니 — 멤버십 먼저 · 원장 두 줄" "$(J "$r" deposit_used)/$(J "$r" card_paid)|$(bal $M2)|$(q "select string_agg(deposit_type || ':' || amount, ',' order by deposit_type) from public.deposit_transactions where user_id = '$M2'")" "4000000/2000000|0/0|general:-1000000,membership:-3000000"
# 전액 카드
claim $O3 >/dev/null; r=$(conf $O3)
ok "C9 전액 카드 — 원장 줄 없음 · paidBy card · 예치금 0" "$(J "$r" deposit_used)/$(J "$r" card_paid)|$(q "select count(*) from public.deposit_transactions where user_id = '$M3'")|$(q "select (extra_data->>'paidBy') || '/' || (extra_data->>'depositUsed') || '/' || (extra_data->>'cardPaid') || '/' || status from public.tickets where extra_data->>'inviteId' = '$I3'")" "0/1800000|0|card/0/1800000/active"
# 거절 — 아무것도 안 바뀐다
mkpaid(){ local r o; r=$(prep $1 $2); o=$(J "$r" order_id); claim $o >/dev/null; echo $o; }
IA=ca000000-0000-4000-8000-00000000000a; newinv $IA $M4 2 800000 100000 tpA 2027.11.07 19:00
q "update public.profiles set general_deposit_balance = 1000000 where id = '$M4'" >/dev/null
OA=$(mkpaid $IA $M4)
q "update public.profiles set general_deposit_balance = 999999 where id = '$M4'" >/dev/null
ok "C10 주문 뒤 잔액이 줄었다 → INSUFFICIENT_DEPOSIT · 초대·홀드·잔액·원장 그대로" "$(code "$(conf $OA)")|$(inv_st $IA)|$(hold_st $IA)|$(bal $M4)|$(q "select count(*) from public.deposit_transactions where user_id = '$M4'")" "INSUFFICIENT_DEPOSIT|sent/false|hold/true/INVH-|0/999999|0"
q "update public.profiles set general_deposit_balance = 1000000 where id = '$M4'; update public.reservation_invites set total_amount = 1900000 where id = '$IA'" >/dev/null
ok "C11 주문 뒤 초대 금액이 바뀌었다 → PRICE_CHANGED" "$(code "$(conf $OA)")|$(inv_st $IA)" "PRICE_CHANGED|sent/false"
q "update public.reservation_invites set total_amount = 1800000, status = 'cancelled' where id = '$IA'" >/dev/null
ok "C12 주문 뒤 초대가 취소됐다 → INVITE_CLOSED" "$(code "$(conf $OA)")" "INVITE_CLOSED"
q "update public.reservation_invites set status = 'paid', paid_at = now() where id = '$IA'" >/dev/null
ok "C13 다른 길(예치금)로 이미 결제된 초대 → ORDER_SUPERSEDED" "$(code "$(conf $OA)")" "ORDER_SUPERSEDED"
q "update public.reservation_invites set status = 'sent', paid_at = null where id = '$IA'; update public.tickets set status = 'cancelled' where extra_data->>'inviteId' = '$IA'" >/dev/null
ok "C14 홀드가 사라졌다 → HOLD_GONE · 초대는 보냄 그대로(롤백) · 잔액 그대로" "$(code "$(conf $OA)")|$(inv_st $IA)|$(bal $M4)" "HOLD_GONE|sent/false|0/1000000"
ok "C15 pending 주문 → ORDER_NOT_PAID · 없는 주문·다른 용도 → ORDER_NOT_FOUND" \
   "$(q "insert into public.payment_orders(order_id,user_id,purpose,amount,metadata) values ('taaminv_p','$M4','invite_topup',1000,'{}'), ('taamtkt_x','$M4','ticket_topup',1000,'{}')" >/dev/null; code "$(conf taaminv_p)")/$(code "$(conf nope)")/$(code "$(conf taamtkt_x)")" "ORDER_NOT_PAID/ORDER_NOT_FOUND/ORDER_NOT_FOUND"
# 주문 뒤에 생긴 겹침 — 확정에서 거절되고 전부 롤백
IB=cb000000-0000-4000-8000-00000000000b; newinv $IB $M4 2 400000 100000 tpB 2027.11.08 19:00    # 합계 1,000,000
q "update public.profiles set general_deposit_balance = 600000 where id = '$M4'" >/dev/null
OB=$(mkpaid $IB $M4)
q "insert into public.ticket_products(id,rest_id,rest_name,date,time) values ('tpB2','r_x','다른 매장','2027.11.08','20:00');
   insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id) values ('$M4','r_x','tpB2','2027.11.08','20:00',1,500000,'active','PAYH-tpB2_1')" >/dev/null
ok "C16 주문 뒤에 같은 시간대 예약이 생겼다 → 확정에서 TIME_CONFLICT · 초대 보냄·홀드·잔액 그대로" "$(code "$(conf $OB)")|$(inv_st $IB)|$(hold_st $IB)|$(bal $M4)" "TIME_CONFLICT|sent/false|hold/true/INVH-|0/600000"

echo "── D. 닫기(토스 취소 전에) ──"
r=$(q "select public.taam_invite_order_close('$OB', 'clash')")
ok "D1 확정 안 된 paid 주문 → 닫힘(canceled · clash_canceling)" "$(J "$r" closed)|$(q "select status || '/' || fail_reason from public.payment_orders where order_id = '$OB'")" "True|canceled/clash_canceling"
ok "D2 닫힌 주문은 확정되지 않는다 → ORDER_NOT_PAID" "$(code "$(conf $OB)")" "ORDER_NOT_PAID"
r=$(q "select public.taam_invite_order_close('$O1b', 'x')")
ok "D3 이미 확정된 주문은 닫지 않는다(settled) — 카드 취소로 이어지지 않는다" "$(J "$r" closed)/$(J "$r" settled)|$(q "select status from public.payment_orders where order_id = '$O1b'")" "False/True|paid"
r=$(q "select public.taam_invite_order_close('taaminv_p', 'x')")
ok "D4 pending 주문은 닫지 않는다(상태만 알려 준다)" "$(J "$r" closed)/$(J "$r" status)" "False/pending"
ok "D5 닫힌 뒤에는 새 주문을 만들 수 있다(초대가 살아 있으면)" "$(q "update public.tickets set status = 'cancelled' where purchase_id = 'PAYH-tpB2_1'" >/dev/null; J "$(prep $IB $M4)" need_payment)" "True"

echo "── E. 정리 목록 ──"
q "update public.payment_orders set approved_at = now() - interval '5 minutes' where order_id = '$OA';
   update public.payment_orders set created_at = now() - interval '11 minutes' where order_id = 'taaminv_p';
   update public.payment_orders set fail_reason = 'clash_refund_failed' where order_id = '$OB'" >/dev/null
ok "E1 확정 안 된 paid(3분↑) = confirm · 10분 넘은 pending = lookup · 취소 실패 = cancel · 확정된 주문은 없다" \
   "$(q "select string_agg((x->>'order_id' = '$OA')::text || ':' || (x->>'reconcile'), ',' order by x->>'reconcile') filter (where x->>'order_id' in ('$OA','taaminv_p','$OB')) || '|' || count(*) filter (where x->>'order_id' = '$O1b') from jsonb_array_elements(public.taam_invite_pay_reconcile_list(50)) x")" \
   "false:cancel,true:confirm,false:lookup|0"
ok "E2 kick — 볼 것이 있으면 설정을 찾는다(픽스처엔 없다 → no_config) · 로그인 세션은 목록을 못 본다" "$(q "select public.taam_invite_pay_reconcile_kick()->>'reason'")/$(code "$(as $SU "select public.taam_invite_pay_reconcile_list(5)")")" "no_config/FORBIDDEN"

echo "── F. 그 뒤 — 취소·환불(기존 경로가 그대로 도는가) ──"
# F1 결제 30분 안 회원 취소: 티켓 취소(카드 환불 대기) → 예치금 환불 → 초대장 취소 → 카드 환불 견적
r=$(as $M1 "select public.taam_apply_deposit_delta('$M1', 0, 8000000, jsonb_build_array(jsonb_build_object('deposit_type','general','change_type','ticket_refund','amount',8000000,'metadata',jsonb_build_object('purchase_id','$PID1'))))")
ok "F1 좌석이 살아 있는 동안 회원 환불은 거절(REFUND_TICKET_ACTIVE)" "$(code "$r")" "REFUND_TICKET_ACTIVE"
as $M1 "update public.tickets set status = 'cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount', 2500000, 'order_id', '$O1b', 'status', 'pending')) where purchase_id = '$PID1'" >/dev/null
ok "F2 회원 취소 — 좌석 취소 · 카드 환불 대기(회원 기록) · 초대장도 취소" "$(q "select status || '/' || (extra_data->'card_refund_pending'->>'amount') || '/' || (extra_data->'card_refund_pending'->>'set_by_role') from public.tickets where purchase_id = '$PID1'")|$(q "select status from public.reservation_invites where id = '$I1'")" "cancelled/2500000/member|cancelled"
as $M1 "select public.taam_apply_deposit_delta('$M1', 0, 8000000, jsonb_build_array(jsonb_build_object('deposit_type','general','change_type','ticket_refund','amount',8000000,'metadata',jsonb_build_object('purchase_id','$PID1'))))" >/dev/null
ok "F3 30분 안 — 예치금 몫 ₩8,000,000 전액 환불" "$(bal $M1)" "0/8000000"
r=$(q "select public.taam_card_refund_quote('$PID1')")
ok "F4 카드 환불 견적(30분 안) — 주문·카드 ₩2,500,000 전액" "$(J "$r" ok)/$(J "$r" policy)/$(J "$r" card_paid)/$(J "$r" card_cap)/$(J "$r" target)/$([ "$(J "$r" order_id)" = "$O1b" ] && echo 주문일치)" "True/full_30min/2500000/2500000/2500000/주문일치"
# F5 D-31 이상(결제 30분 뒤): 예치금 4,000,000 전액 · 카드는 대행비(회차 100,000 × 2)를 뺀 1,800,000
PID8=$(q "select purchase_id from public.tickets where extra_data->>'inviteId' = '$I8'")
q "update public.deposit_transactions set created_at = now() - interval '2 hours' where user_id = '$M2'; update public.payment_orders set approved_at = now() - interval '2 hours' where order_id = '$O8'" >/dev/null
as $M2 "update public.tickets set status = 'cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount', 2000000, 'order_id', '$O8', 'status', 'pending')) where purchase_id = '$PID8'" >/dev/null
r1=$(as $M2 "select public.taam_apply_deposit_delta('$M2', 3000000, 1000000, jsonb_build_array(jsonb_build_object('deposit_type','membership','change_type','ticket_refund','amount',3000000,'metadata',jsonb_build_object('purchase_id','$PID8')), jsonb_build_object('deposit_type','general','change_type','ticket_refund','amount',1000000,'metadata',jsonb_build_object('purchase_id','$PID8'))))")
r=$(q "select public.taam_card_refund_quote('$PID8')")
ok "F5 D-31 이상 — 예치금 몫 전액(4,000,000) · 카드 몫은 대행비 200,000 을 뺀 1,800,000 (회원이 2,000,000 을 적어도)" "$(bal $M2)|$(J "$r" policy)/$(J "$r" refundable)/$(J "$r" card_cap)/$(J "$r" target)" "3000000/1000000|d31/5800000/1800000/1800000"
# F6 D-30 안: 환불 없음
I9=c9000000-0000-4000-8000-000000000009; newinv $I9 $M4 2 400000 100000 tp9 "$(date -u -d '+10 days' +%Y.%m.%d)" 19:00
q "update public.profiles set general_deposit_balance = 600000 where id = '$M4'" >/dev/null
O9=$(mkpaid $I9 $M4); r=$(conf $O9); PID9=$(J "$r" purchase_id)
q "update public.deposit_transactions set created_at = now() - interval '2 hours' where user_id = '$M4'; update public.payment_orders set approved_at = now() - interval '2 hours' where order_id = '$O9'" >/dev/null
as $M4 "update public.tickets set status = 'cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount', 400000, 'order_id', '$O9', 'status', 'pending')) where purchase_id = '$PID9'" >/dev/null
r1=$(as $M4 "select public.taam_apply_deposit_delta('$M4', 0, 600000, jsonb_build_array(jsonb_build_object('deposit_type','general','change_type','ticket_refund','amount',600000,'metadata',jsonb_build_object('purchase_id','$PID9'))))")
r=$(q "select public.taam_card_refund_quote('$PID9')")
ok "F6 D-30 안(결제 30분 뒤) — 예치금 환불 거절(LEDGER_REFUND_POLICY) · 카드 몫 0" "$(code "$r1")|$(J "$r" policy)/$(J "$r" card_cap)/$(J "$r" target)|$(bal $M4)" "LEDGER_REFUND_POLICY|none/0/0|0/0"

echo "── G. 다시 RUN · 의존 없는 DB ──"
out2=$($P -f "$MIG" 2>&1)
ok "G1 두 번째 RUN: 오류 없음 · ❌ 0 · 용도 제약 「이미 있음」 · 기존 주문·확정 그대로" "$(echo "$out2" | grep -cE "ERROR")/$(echo "$out2" | grep -c '❌')/$(echo "$out2" | grep -c '이미 있음')|$(q "select count(*) from public.payment_orders where purpose = 'invite_topup' and metadata->>'inv_settled' = 'true'")" "0/0/1|4"
DB2=${DB}_bare; psql -h /tmp -U postgres -d postgres -q -X -c "drop database if exists $DB2" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -X -c "create database $DB2" >/dev/null
psql -h /tmp -U postgres -d $DB2 -q -At -X -c "create schema auth; create function auth.uid() returns uuid language sql as 'select null::uuid';
  create table public.payment_orders(order_id text primary key, user_id uuid, purpose text, status text, amount bigint, metadata jsonb default '{}', fail_reason text, created_at timestamptz default now(), approved_at timestamptz, payment_key text);
  create table public.reservation_invites(id uuid primary key, status text, ticket_product_id text); create table public.tickets(id uuid, status text, purchase_id text, extra_data jsonb);" >/dev/null 2>&1
out3=$(psql -h /tmp -U postgres -d $DB2 -q -At -X -f "$MIG" 2>&1)
ok "G2 확정 RPC·원장 RPC 가 없는 DB — 확인 표가 ❌ 로 알린다(조용히 넘어가지 않는다)" "$(echo "$out3" | grep -c '의존.*❌')" "1"
psql -h /tmp -U postgres -d postgres -q -X -c "drop database if exists $DB2" >/dev/null 2>&1

[ $FAIL = 0 ] && echo "── 전부 통과 ──" || echo "── 실패 있음 ──"
exit $FAIL
