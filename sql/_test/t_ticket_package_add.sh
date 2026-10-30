#!/usr/bin/env bash
# 20261030_ticket_package_add.sql 회귀 — 기존 패키지에 회차 더하기 · 예약 있는 회차 연계 금지 · 숨김으로 올린 회차를 연계와 함께 공개
#   실제 가드(저장소 판)를 올린다: 결제 사실 칸(UPDATE/INSERT) · 확정 금액 하한 · 원장 환불 한도 두 개 · 같은 회차·같은 시간대 가드 · 단일 예치금 확정 함수.
#   라이브에만 있는 가드(INSERT 모양·행 잠금·정원)는 같은 규칙의 작은 대역을 둔다.
set -u
cd "$(dirname "$0")/../.."
DB=tpka_$$
P="psql -h /tmp -U postgres -d $DB -X -q -A -t -v ON_ERROR_STOP=0"
MIG=supabase/migrations/20261029_ticket_package.sql
FAIL=0
SU=a2000000-0000-4000-8000-000000000001; M1=a2000000-0000-4000-8000-000000000002; M2=a2000000-0000-4000-8000-000000000003
M3=a2000000-0000-4000-8000-000000000004; M5=a2000000-0000-4000-8000-000000000005; PT=a2000000-0000-4000-8000-000000000006
RA=c2000000-0000-4000-8000-00000000000a; RB=c2000000-0000-4000-8000-00000000000b; RC=c2000000-0000-4000-8000-00000000000c
RD=c2000000-0000-4000-8000-00000000000d; RE=c2000000-0000-4000-8000-00000000000e
D(){ TZ=Asia/Seoul date -d "$1" +%Y.%m.%d; }
D60=$(D '+60 days'); D61=$(D '+61 days'); D70=$(D '+70 days'); D10=$(D '+10 days'); D75=$(D '+75 days'); DPAST=$(D '-3 days'); DTODAY=$(D 'today')
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
$P >/dev/null 2>&1 <<SQL
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema if not exists auth; grant usage on schema auth to authenticated, anon;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, role text default 'user', display_name text, phone text, single_device_exempt boolean default false,
  membership_deposit_balance bigint default 0, general_deposit_balance bigint default 0, deposit_balance bigint default 0,
  charged_membership_balance bigint default 0, charged_general_balance bigint default 0);
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable security definer set search_path = public as \$\$
  select coalesce((select role in ('super_admin','superadmin') from public.profiles where id = uid), false) \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path = public as \$\$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('superadmin','super_admin')) \$\$;
create table public.restaurants(id uuid primary key, name text, repurchase_day int default 0);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, meal_fee int default 0, agency_fee int default 0,
  wine_min int default 0, status text default 'active', total_pax int default 6, repurchase_open boolean default false, updated_at timestamptz default now());
create or replace function public.taam_repurchase_released(p text) returns boolean language sql stable as \$\$ select coalesce((select repurchase_open from public.ticket_products where id = p), false) \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text,
  ticket_type text, reservation_date text, visit_time text, party_size int, price int, status text, purchase_id text, buyer_name text, buyer_phone text,
  extra_data jsonb default '{}', created_at timestamptz default now());
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint,
  balance_after bigint, description text, metadata jsonb default '{}', created_at timestamptz default now());
create table public.payment_orders(order_id text primary key, user_id uuid not null, purpose text not null default 'deposit_charge', amount bigint not null check (amount > 0),
  currency text not null default 'KRW', settle_krw bigint, fx_rate numeric, status text not null default 'pending', payment_key text, method text, receipt_url text,
  approved_at timestamptz, fail_reason text, metadata jsonb not null default '{}', created_at timestamptz default now(), updated_at timestamptz default now());
alter table public.payment_orders add constraint payment_orders_purpose_chk check (purpose in ('deposit_charge','ticket_topup','membership'));
create table public.reservation_invites(id uuid primary key default gen_random_uuid());
create table public.ticket_restock_events(id bigserial primary key, ticket_product_id text not null, status text not null default 'pending', reason text,
  seats_left int, created_at timestamptz not null default now(), processed_at timestamptz);
-- 라이브 가드 대역 — 회원 INSERT 모양(INVOKER · PAYH- 홀드만) · 회원 행 잠금(취소만) · 정원
create or replace function public.t_guard_insert() returns trigger language plpgsql as \$\$
begin
  if current_user not in ('authenticated','anon') or public._taam_uid_is_super() then return new; end if;
  if new.user_id is distinct from auth.uid() then raise exception 'NOT_OWNER'; end if;
  if lower(coalesce(new.status,'')) <> 'hold' or coalesce(new.purchase_id,'') not like 'PAYH-%' then raise exception '예약은 서버가 확정합니다'; end if;
  return new; end \$\$;
create trigger trg_taam_guard_ticket_insert before insert on public.tickets for each row execute function public.t_guard_insert();
create or replace function public.t_guard_row() returns trigger language plpgsql as \$\$
begin
  if current_user not in ('authenticated','anon') or public._taam_uid_is_super() then return new; end if;
  if new.price is distinct from old.price or new.party_size is distinct from old.party_size then raise exception 'ROW_LOCKED'; end if;
  if new.status is distinct from old.status and lower(coalesce(new.status,'')) not in ('cancelled','canceled') then raise exception 'ROW_LOCKED_STATUS'; end if;
  return new; end \$\$;
create trigger trg_taam_guard_ticket_row before update on public.tickets for each row execute function public.t_guard_row();
create or replace function public.t_capacity() returns trigger language plpgsql security definer set search_path = public as \$\$
declare v_cap int; v_used int;
begin
  if new.ticket_product_id is null or lower(coalesce(new.status,'')) in ('cancelled','canceled') then return new; end if;
  select total_pax into v_cap from public.ticket_products where id = new.ticket_product_id;
  select coalesce(sum(party_size),0) into v_used from public.tickets where ticket_product_id = new.ticket_product_id and lower(coalesce(status,'')) not in ('cancelled','canceled','expired');
  if v_cap is not null and v_used + coalesce(new.party_size,1) > v_cap then raise exception 'TICKET_SOLD_OUT'; end if;
  return new; end \$\$;
create trigger trg_enforce_ticket_capacity before insert on public.tickets for each row execute function public.t_capacity();
create or replace function public.taam_expire_seat_holds() returns json language plpgsql security definer set search_path = public as \$\$
declare v int; begin update public.tickets set status = 'cancelled' where status = 'hold' and purchase_id like 'PAYH-%' and created_at < now() - interval '5 minutes';
get diagnostics v = row_count; return json_build_object('released', v); end \$\$;
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance) values
 ('$SU','superadmin','운영',0,0), ('$M1','user','회원일',1000000,500000), ('$M2','user','회원이',3000000,0), ('$M3','user','회원삼',0,5000000),
 ('$M5','user','회원오',5000000,0), ('$PT','user','파트너',0,0);
insert into public.restaurants values ('$RA','에이',30), ('$RB','비',0), ('$RC','씨',0), ('$RD','디',0), ('$RE','이',0);
insert into public.ticket_products(id,rest_id,rest_name,date,time,meal_fee,agency_fee,wine_min,status,total_pax) values
 ('tpA','$RA','에이','$D60','19:00',400000,100000,0,'active',6),
 ('tpB','$RB','비','$D61','12:00',300000,50000,50000,'active',4),
 ('tpC','$RC','씨','$D61','19:00',200000,50000,0,'active',4),
 ('tpX','$RB','비','$D61','13:00',100000,0,0,'active',4),
 ('tpR','$RA','에이','$D70','19:00',100000,0,0,'active',4),
 ('tpOld','$RC','씨','$DPAST','19:00',100000,0,0,'active',4),
 ('tpNY','$RC','씨','12.24','19:00',100000,0,0,'active',4),
 ('tpPend','$RC','씨','$D75','19:00',100000,0,0,'pending',4),
 ('tpD','$RD','디','$D10','19:00',100000,20000,0,'active',8),
 ('tpE','$RE','이','$D75','19:00',200000,30000,0,'active',8);
-- M5 는 tpE 를 단일로 이미 샀다(연계 전)
insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id)
values ('$M5','$RE','이','tpE','$D75','19:00',2,460000,'active','PAYH-tpE_single');
SQL
# 저장소의 실제 가드·함수
awk 'NR>=31 && NR<=179' supabase/migrations/20261022_card_refund_quote2.sql | $P >/dev/null 2>&1
$P -c "create trigger trg_taam_guard_ticket_payfacts before update on public.tickets for each row execute function public.taam_guard_ticket_payfacts();" >/dev/null 2>&1
awk '/^create or replace function public.taam_guard_ledger_refund_active\(\)/{f=1} f{print} f&&/^end \$\$;/{exit}' supabase/migrations/20261022_invite_payment_guard2.sql | $P >/dev/null 2>&1
$P -c "create trigger trg_taam_guard_ledger_refund_active before insert on public.deposit_transactions for each row execute function public.taam_guard_ledger_refund_active();" >/dev/null 2>&1
$P -f supabase/migrations/20261014_purchase_uniqueness.sql >/dev/null 2>&1
$P -f sql/purchase_confirm_deposit.sql >/dev/null 2>&1
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1 — 기대 [$3] 실제 [$2]"; FAIL=1; fi; }
has(){ if echo "$2" | grep -q -- "$3"; then echo "✅ $1"; else echo "❌ $1 — [$3] 없음: ${2:0:400}"; FAIL=1; fi; }
AS(){ $P -c "set role authenticated; set taam.uid='$1'; $2" 2>&1; }
ANON(){ $P -c "set role anon; set taam.uid=''; $1" 2>&1; }
Q(){ $P -c "$1" 2>&1; }
J(){ $P -c "select ($1)->>'$2'" 2>&1; }
ok "픽스처 — 실제 가드 설치(결제 사실 칸 · 하한 · 환불 한도 둘 · 같은 회차 가드 · 단일 확정)" "$(Q "select count(*) from pg_proc where proname in ('taam_guard_ticket_payfacts','taam_guard_ticket_payfacts_ins','taam_guard_ticket_price_floor','taam_guard_ledger_refund_paid','taam_guard_ledger_refund_active','taam_guard_purchase_unique','taam_purchase_confirm_deposit')")/$(Q "select count(*) from pg_trigger where tgname in ('trg_taam_guard_ticket_payfacts','trg_taam_guard_ticket_payfacts_ins','trg_taam_guard_ticket_price_floor','trg_taam_guard_ledger_refund_paid','trg_taam_guard_ledger_refund_active','trg_taam_guard_ticket_unique')")" "7/6"
out=$($P -f "$MIG" 2>&1)
echo "$out" | grep -q "❌" && { echo "❌ 확인 표에 ❌"; echo "$out" | grep "❌"; FAIL=1; } || echo "✅ 확인 표"
echo "$out" | grep -q "ERROR" && { echo "❌ 설치 중 ERROR"; echo "$out" | grep -A3 ERROR | head -20; FAIL=1; } || echo "✅ 설치 중 ERROR 없음"
has "확인 표 — 용도 제약에 package_topup" "$out" "B payment_orders 용도에 package_topup|✅"

MIG2=supabase/migrations/20261030_ticket_package_add.sql
# 더 쓸 회차 — 매장마다 다른 날 · 숨김 회차(업로드 연계)
Q "insert into public.restaurants values ('c2000000-0000-4000-8000-0000000000f1','에프',0),('c2000000-0000-4000-8000-0000000000f2','지',0)" >/dev/null
for i in 1 2 3 4 5 6; do Q "insert into public.ticket_products(id,rest_id,rest_name,date,time,meal_fee,agency_fee,status,total_pax) values ('tpN$i','c2000000-0000-4000-8000-0000000000f1','에프','$(D "+$((80+i)) days")','19:00',100000,10000,'active',4)" >/dev/null; done
Q "insert into public.ticket_products(id,rest_id,rest_name,date,time,meal_fee,agency_fee,status,total_pax) values
 ('tpH1','c2000000-0000-4000-8000-0000000000f2','지','$(D '+90 days')','19:00',100000,10000,'hidden',4),
 ('tpH2','c2000000-0000-4000-8000-0000000000f2','지','$(D '+91 days')','19:00',100000,10000,'hidden',4),
 ('tpH3','c2000000-0000-4000-8000-0000000000f2','지','$(D '+92 days')','19:00',100000,10000,'hidden',4),
 ('tpH4','c2000000-0000-4000-8000-0000000000f1','에프','$(D '+92 days')','20:00',100000,10000,'hidden',4),
 ('tpH5','c2000000-0000-4000-8000-0000000000f2','지','$(D '+93 days')','12:00',100000,10000,'hidden',4)" >/dev/null
out=$($P -f "$MIG2" 2>&1)
echo "$out" | grep -q "❌" && { echo "❌ 확인 표에 ❌(2)"; echo "$out" | grep "❌"; FAIL=1; } || echo "✅ 확인 표(2)"
echo "$out" | grep -q "ERROR" && { echo "❌ 설치 중 ERROR(2)"; echo "$out" | grep -A3 ERROR | head -20; FAIL=1; } || echo "✅ 설치 중 ERROR 없음(2)"
has "확인 표 — status 제약 없음" "$out" "0 ticket_products.status 에 hidden|✅ 제약 없음"

echo "── 1. 예약 있는 회차는 연계 못 한다(만들기) ──"
has "단일 구매가 있는 회차(tpE) 로 만들기 → ROUND_HAS_BOOKINGS(이 · 1건 2명)" "$(AS "$SU" "select public.taam_package_save(null,'둘',array['tpD','tpE'])")" "ROUND_HAS_BOOKINGS: 이 .*예약 1건(2명)"
ok "  ↳ 패키지가 안 생겼다(통째 롤백)" "$(Q "select count(*) from public.ticket_packages")/$(Q "select count(*) from public.ticket_package_rounds")" "0/0"
H(){ AS "$1" "insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,party_size,price,status,purchase_id,extra_data) values ('$1','$2','x','$3',$4,0,'hold','$5','$6'::jsonb)"; }
H "$M1" "$RD" tpD 2 PAYH-tpD_h1 '{}' >/dev/null
has "결제 중인 단일 홀드가 있는 회차도 → ROUND_HAS_BOOKINGS" "$(AS "$SU" "select public.taam_package_save(null,'둘',array['tpD','tpA'])")" "ROUND_HAS_BOOKINGS: 디"
Q "update public.tickets set status = 'cancelled' where purchase_id = 'PAYH-tpD_h1'" >/dev/null
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','$RD','tpD',1,0,'manual','MAN-tpD')" >/dev/null
has "수동 좌석(MAN-)도 예약이다 → ROUND_HAS_BOOKINGS" "$(AS "$SU" "select public.taam_package_save(null,'둘',array['tpD','tpA'])")" "ROUND_HAS_BOOKINGS"
Q "update public.tickets set status = 'cancelled' where purchase_id = 'MAN-tpD'" >/dev/null
has "취소된 예약만 있으면 통과" "$(AS "$SU" "select public.taam_package_save(null,'둘',array['tpD','tpA'])")" '"ok": true'
Q "delete from public.ticket_package_rounds; delete from public.ticket_packages" >/dev/null
has "운영 우회(SQL Editor · taam.pkg_allow_booked) 는 넣는다" "$(Q "begin; set local taam.pkg_allow_booked = '1'; select public.taam_package_save(null,'우회',array['tpD','tpE']); commit;")" '"ok": true'
Q "delete from public.ticket_package_rounds; delete from public.ticket_packages" >/dev/null

echo "── 2. 기존 패키지에 회차 더하기 ──"
R=$(AS "$SU" "select public.taam_package_save(null,'더하기',array['tpB','tpA'])"); PK=$(Q "select id from public.ticket_packages where title = '더하기'")
has "  만들기(두 회차)" "$R" '"ok": true'
has "회원은 못 더한다" "$(AS "$M1" "select public.taam_package_add_rounds('$PK', array['tpC'])")" "FORBIDDEN"
has "파트너도 못 더한다" "$(AS "$PT" "select public.taam_package_add_rounds('$PK', array['tpC'])")" "FORBIDDEN"
has "비로그인은 부를 수 없다" "$(ANON "select public.taam_package_add_rounds('$PK', array['tpC'])")" "permission denied"
has "빈 목록 → BAD_ROUNDS" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array[]::text[])")" "BAD_ROUNDS"
has "없는 회차 → ROUND_NOT_FOUND" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['nope'])")" "ROUND_NOT_FOUND"
has "이미 이 패키지 → ROUND_IN_PACKAGE" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpA'])")" "ROUND_IN_PACKAGE"
has "같은 날 같은 시간대(tpX 13:00 · tpB 12:00) → PACKAGE_CONFLICT" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpX'])")" "PACKAGE_CONFLICT.*같은 날 같은 시간대"
has "같은 매장 재구매 제한(tpR · tpA 30일) → PACKAGE_CONFLICT" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpR'])")" "PACKAGE_CONFLICT.*재구매 제한"
has "지난 회차 → ROUND_PAST" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpOld'])")" "ROUND_PAST"
has "연도 없는 날짜 → ROUND_NO_YEAR" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpNY'])")" "ROUND_NO_YEAR"
has "승인 대기 회차 → ROUND_NOT_SELLABLE" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpPend'])")" "ROUND_NOT_SELLABLE"
has "숨김 회차(공개 지정 없이) → ROUND_NOT_SELLABLE" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpH1'])")" "ROUND_NOT_SELLABLE"
has "예약 있는 회차(tpE) → ROUND_HAS_BOOKINGS" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpC','tpE'])")" "ROUND_HAS_BOOKINGS"
ok "  ↳ 같이 보낸 tpC 도 안 들어갔다(통째 롤백)" "$(Q "select count(*) from public.ticket_package_rounds where package_id = '$PK'")" "2"
has "합쳐서 9개 → BAD_ROUNDS" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpN1','tpN2','tpN3','tpN4','tpN5','tpN6','tpC'])")" "BAD_ROUNDS: 회차는 합쳐서 2~8개"
RA2=$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpC','tpN1'])")
has "더하기 — tpC · tpN1" "$RA2" '"ok": true'
ok "  ↳ 회차 순서를 방문일 순으로 다시 매긴다(A → B → C → N1)" "$(Q "select string_agg(ticket_product_id, ',' order by sort) from public.ticket_package_rounds where package_id = '$PK'")" "tpA,tpB,tpC,tpN1"
ok "  ↳ 패키지 회차 목록(rounds)도" "$(Q "select array_to_string(rounds, ',') from public.ticket_packages where id = '$PK'")" "tpA,tpB,tpC,tpN1"
has "  ↳ 목록에 네 회차" "$(AS "$SU" "select public.taam_package_list()")" '"id": "tpN1"'
has "다른 패키지의 회차 → ROUND_IN_PACKAGE" "$(AS "$SU" "select public.taam_package_save(null,'둘',array['tpN2','tpN1'])")" "ROUND_IN_PACKAGE"
ok "더한 회차에 단일 홀드 → PACKAGE_ONLY" "$(H "$M2" c2000000-0000-4000-8000-0000000000f1 tpN1 1 PAYH-tpN1_s '{}' | grep -o PACKAGE_ONLY)" "PACKAGE_ONLY"

echo "── 3. 구매자가 있는 패키지에는 못 더한다 ──"
for x in A:$RA B:$RB C:$RC N1:c2000000-0000-4000-8000-0000000000f1; do t=${x%%:*}; r=${x#*:}; H "$M2" "$r" tp$t 1 PAYH-tp${t}_b "{\"pkg\":\"$PK\"}" >/dev/null; done
SB=$(AS "$M2" "select public.taam_package_start('$PK', 1, array['PAYH-tpA_b','PAYH-tpB_b','PAYH-tpC_b','PAYH-tpN1_b'])")
has "  회원 결제 시작(홀드 묶음)" "$SB" '"ok": true'
has "결제 중 홀드가 있으면 → PACKAGE_HAS_BUYERS(결제 중 1)" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpN2'])")" "PACKAGE_HAS_BUYERS.*결제 중 1건"
GB=$(Q "select id from public.ticket_package_orders where user_id = '$M2' and status = 'hold'")
TOT=$(Q "select total from public.ticket_package_orders where id = '$GB'")
has "  예치금 확정" "$(AS "$M2" "select public.taam_package_confirm_deposit('$GB', $TOT)")" '"ok": true'
has "결제된 묶음이 있으면 → PACKAGE_HAS_BUYERS(결제 1)" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpN2'])")" "PACKAGE_HAS_BUYERS.*결제 1건"
Q "update public.profiles set membership_deposit_balance = 0 where id = '$M2'" >/dev/null
QU=$(AS "$M2" "select (public.taam_package_cancel_quote('$GB'))->>'refund'")
has "  회원 통째 취소" "$(AS "$M2" "select public.taam_package_cancel('$GB', $QU, '시험')")" '"ok": true'
has "취소된 묶음만 있으면 더할 수 있다(그 좌석은 다 풀렸다)" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpN2'])")" '"ok": true'
Q "insert into public.ticket_package_orders(id,package_id,user_id,pax,status,purchase_ids,expires_at) values ('PKO-x','$PK','$M3',1,'failed','{}',now())" >/dev/null
Q "insert into public.payment_orders(order_id,user_id,purpose,amount,status,metadata) values ('taampkg_x','$M3','package_topup',1000,'pending',jsonb_build_object('group_id','PKO-x'))" >/dev/null
has "결과를 모르는 카드 주문이 있으면 → PACKAGE_HAS_BUYERS(카드 확인 중 1)" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpN3'])")" "PACKAGE_HAS_BUYERS.*카드 확인 중 1건"
Q "update public.payment_orders set status = 'failed' where order_id = 'taampkg_x'" >/dev/null
AS "$SU" "select public.taam_package_unlink('$PK')" >/dev/null
has "풀린 패키지 → PACKAGE_NOT_ACTIVE" "$(AS "$SU" "select public.taam_package_add_rounds('$PK', array['tpN3'])")" "PACKAGE_NOT_ACTIVE"

echo "── 4. 숨김으로 올린 회차 — 연계와 함께 공개 ──"
has "숨김 회차에 회원 홀드 → TICKET_NOT_OPEN" "$(H "$M1" c2000000-0000-4000-8000-0000000000f2 tpH1 1 PAYH-tpH1_s '{}')" "TICKET_NOT_OPEN"
has "서버의 카드 확정 폴백(PAYC-)도 → TICKET_NOT_OPEN" "$(Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$M1','x','tpH1',1,110000,'active','PAYC-tpH1')")" "TICKET_NOT_OPEN"
has "운영 행(MAN-)은 막지 않는다" "$(Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','x','tpH5',1,0,'manual','MAN-tpH5') returning purchase_id")" "MAN-tpH5"
Q "update public.tickets set status = 'cancelled' where purchase_id = 'MAN-tpH5'" >/dev/null
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$M1','x','tpN4',1,0,'hold','PAYH-mv')" >/dev/null
has "회원 행을 숨김 회차로 옮기기 → TICKET_NOT_OPEN" "$(Q "update public.tickets set ticket_product_id = 'tpH1' where purchase_id = 'PAYH-mv'")" "TICKET_NOT_OPEN"
Q "update public.tickets set status = 'cancelled' where purchase_id = 'PAYH-mv'" >/dev/null
has "숨김 회차로 그냥 만들기 → ROUND_NOT_SELLABLE" "$(AS "$SU" "select public.taam_package_save(null,'숨김',array['tpH1','tpH2'])")" "ROUND_NOT_SELLABLE"
has "회원은 공개 만들기를 못 부른다" "$(AS "$M1" "select public.taam_package_save_reveal(array['tpH1'],'숨김',array['tpH1','tpH2'])")" "FORBIDDEN"
has "회원은 공개 도우미를 못 부른다" "$(AS "$M1" "select public._taam_pkg_reveal(array['tpH1'],array['tpH1'])")" "permission denied"
has "공개 목록이 연계 목록 밖 → BAD_REVEAL" "$(AS "$SU" "select public.taam_package_save_reveal(array['tpA'],'숨김',array['tpH1','tpH2'])")" "BAD_REVEAL"
has "공개 만들기가 실패하면(같은 날 같은 시간대 tpH3·tpH4) → PACKAGE_CONFLICT" "$(AS "$SU" "select public.taam_package_save_reveal(array['tpH3','tpH4'],'충돌',array['tpH3','tpH4'])")" "PACKAGE_CONFLICT"
ok "  ↳ 두 회차는 숨김 그대로(단일로 안 풀린다)" "$(Q "select string_agg(status, ',' order by id) from public.ticket_products where id in ('tpH3','tpH4')")" "hidden,hidden"
RV=$(AS "$SU" "select public.taam_package_save_reveal(array['tpH1','tpH2'],'업로드 연계',array['tpH2','tpH1'],'Upload')")
has "공개 만들기 — 두 회차 공개 · 패키지" "$RV" '"revealed": 2'
ok "  ↳ 두 회차 active · 패키지 회차 둘" "$(Q "select string_agg(status, ',' order by id) from public.ticket_products where id in ('tpH1','tpH2')")/$(Q "select count(*) from public.ticket_package_rounds pr join public.ticket_packages p on p.id = pr.package_id where p.title = '업로드 연계'")" "active,active/2"
PKU=$(Q "select id from public.ticket_packages where title = '업로드 연계'")
has "  ↳ 공개 뒤 단일 홀드 → PACKAGE_ONLY" "$(H "$M1" c2000000-0000-4000-8000-0000000000f2 tpH1 1 PAYH-tpH1_s2 '{}')" "PACKAGE_ONLY"
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','x','tpN5',1,0,'manual','MAN-tpN5')" >/dev/null
has "더하기 + 공개가 실패하면(같이 보낸 tpN5 예약 있음) → ROUND_HAS_BOOKINGS" "$(AS "$SU" "select public.taam_package_add_rounds('$PKU', array['tpH5','tpN5'], array['tpH5'])")" "ROUND_HAS_BOOKINGS"
ok "  ↳ tpH5 는 숨김 그대로" "$(Q "select status from public.ticket_products where id = 'tpH5'")" "hidden"
RA3=$(AS "$SU" "select public.taam_package_add_rounds('$PKU', array['tpH5'], array['tpH5'])")
has "더하기 + 공개 — tpH5" "$RA3" '"revealed": 1'
ok "  ↳ tpH5 active · 패키지 회차 셋(방문일 순 H1 → H2 → H5)" "$(Q "select status from public.ticket_products where id = 'tpH5'")/$(Q "select string_agg(ticket_product_id, ',' order by sort) from public.ticket_package_rounds where package_id = '$PKU'")" "active/tpH1,tpH2,tpH5"

echo "── 4b. 숨김 회차 — 운영 좌석 · 매진 동기화(중첩 갱신)가 못 푼다 ──"
Q "insert into public.ticket_products(id,rest_id,rest_name,date,time,meal_fee,agency_fee,status,total_pax) values ('tpH6','c2000000-0000-4000-8000-0000000000f2','지','$(D '+95 days')','19:00',100000,10000,'hidden',2)" >/dev/null
# 라이브 매진 동기화 모양 — 꽉 차면 soldout(지금 무엇이든) · 자리가 나면 soldout → active (sql/seat_hold_repair.sql 의 v4 와 같은 규칙)
$P >/dev/null 2>&1 <<'SQL'
create or replace function public.t_sync_soldout() returns trigger language plpgsql security definer set search_path = public as $f$
declare v_tp text := coalesce(new.ticket_product_id, old.ticket_product_id); v_occ int; v_cap int;
begin
  select total_pax into v_cap from public.ticket_products where id = v_tp;
  select coalesce(sum(party_size),0) into v_occ from public.tickets where ticket_product_id = v_tp and lower(coalesce(status,'')) not in ('cancelled','canceled','expired');
  if v_cap is not null and v_occ >= v_cap then update public.ticket_products set status = 'soldout' where id = v_tp and status is distinct from 'soldout';
  else update public.ticket_products set status = 'active' where id = v_tp and status = 'soldout'; end if;
  return null; end $f$;
create trigger trg_sync_ticket_soldout after insert or update on public.tickets for each row execute function public.t_sync_soldout();
SQL
has "파트너의 수동 좌석(MAN-) → TICKET_NOT_OPEN" "$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$PT','x','tpH6',2,0,'manual','MAN-h6p')")" "TICKET_NOT_OPEN"
has "슈퍼어드민의 수동 좌석도 → TICKET_NOT_OPEN(좌석이 서면 연계 못 함)" "$(AS "$SU" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','x','tpH6',2,0,'manual','MAN-h6s')")" "TICKET_NOT_OPEN"
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','x','tpH6',2,0,'manual','MAN-h6')" >/dev/null
ok "서버의 운영 좌석이 꽉 채워도 숨김 그대로(매진 동기화가 못 푼다)" "$(Q "select status from public.ticket_products where id = 'tpH6'")" "hidden"
Q "update public.tickets set status = 'cancelled' where purchase_id = 'MAN-h6'" >/dev/null
ok "  ↳ 빠져도 숨김 그대로(soldout → active · 취소표 알림 없음)" "$(Q "select status from public.ticket_products where id = 'tpH6'")" "hidden"
has "슈퍼어드민이 취소된 좌석을 되살리기 → TICKET_NOT_OPEN" "$(AS "$SU" "update public.tickets set status = 'manual' where purchase_id = 'MAN-h6'")" "TICKET_NOT_OPEN"
Q "update public.ticket_products set status = 'soldout' where id = 'tpN6'" >/dev/null
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','x','tpN6',4,0,'manual','MAN-n6')" >/dev/null
Q "update public.tickets set status = 'cancelled' where purchase_id = 'MAN-n6'" >/dev/null
ok "숨김이 아닌 회차의 동기화는 종전대로(soldout → active)" "$(Q "select status from public.ticket_products where id = 'tpN6'")" "active"
AS "$SU" "update public.ticket_products set status = 'active' where id = 'tpH6' and status = 'hidden'" >/dev/null
ok "슈퍼어드민의 직접 「연계 없이 공개」(깊이 1)는 된다" "$(Q "select status from public.ticket_products where id = 'tpH6'")" "active"
has "  ↳ 공개 뒤엔 단일 홀드가 들어간다" "$(H "$M1" c2000000-0000-4000-8000-0000000000f2 tpH6 1 PAYH-h6m '{}'; Q "select status from public.tickets where purchase_id = 'PAYH-h6m'")" "hold"

echo "── 4c. 연계된 회차는 다시 숨기지 않는다(낡은 사본의 「숨김」 저장 · 2차 리뷰) ──"
AS "$SU" "update public.ticket_products set status = 'hidden' where id = 'tpH1'" >/dev/null
ok "연계된 회차를 직접 숨김으로 → 상태 그대로(active)" "$(Q "select status from public.ticket_products where id = 'tpH1'")" "active"
AS "$SU" "insert into public.ticket_products(id,rest_id,rest_name,date,time,meal_fee,agency_fee,status,total_pax) select id,rest_id,'지 (고침)',date,time,meal_fee,agency_fee,'hidden',total_pax from public.ticket_products where id = 'tpH2' on conflict (id) do update set rest_name = excluded.rest_name, status = excluded.status" >/dev/null
ok "  ↳ upsert(앱 저장 모양)로 hidden — 상태는 그대로 · 다른 칸은 반영" "$(Q "select status || '/' || rest_name from public.ticket_products where id = 'tpH2'")" "active/지 (고침)"
has "  ↳ 패키지는 그대로 팔린다(단일 홀드 → PACKAGE_ONLY)" "$(H "$M1" c2000000-0000-4000-8000-0000000000f2 tpH2 1 PAYH-tpH2_s3 '{}')" "PACKAGE_ONLY"
Q "insert into public.ticket_products(id,rest_id,rest_name,date,time,meal_fee,agency_fee,status,total_pax) values ('tpZ1','c2000000-0000-4000-8000-0000000000f1','에프','$(D '+120 days')','19:00',100000,10000,'active',4)" >/dev/null
AS "$SU" "update public.ticket_products set status = 'hidden' where id = 'tpZ1'" >/dev/null
ok "연계 안 된 회차는 숨길 수 있다(종전대로)" "$(Q "select status from public.ticket_products where id = 'tpZ1'")" "hidden"

echo "── 5. 예약 수 함수 ──"
BK=$(AS "$SU" "select public.taam_package_round_bookings(array['tpE','tpA','tpN5','nope'])")
has "tpE 1건 2명" "$BK" '"tpE": {"n": 1, "pax": 2}'
has "tpN5 1건 1명" "$BK" '"tpN5": {"n": 1, "pax": 1}'
ok "예약 없는 회차는 안 나온다" "$(echo "$BK" | grep -c '"nope"\|"tpA"')" "0"
has "회원은 못 부른다" "$(AS "$M1" "select public.taam_package_round_bookings(array['tpE'])")" "FORBIDDEN"

echo "── 6. status 제약이 있는 DB ──"
Q "alter table public.ticket_products add constraint ticket_products_status_chk check (status in ('active','soldout','pending','deleteRequest'))" >/dev/null 2>&1
Q "update public.ticket_products set status = 'active' where status = 'hidden'" >/dev/null
Q "alter table public.ticket_products add constraint ticket_products_status_chk check (status in ('active','soldout','pending','deleteRequest'))" >/dev/null 2>&1
has "  (제약 걸림 — hidden 못 넣는다)" "$(Q "insert into public.ticket_products(id,status) values ('tpZ','hidden')")" "violates check constraint"
out3=$($P -f "$MIG2" 2>&1)
has "제약에 hidden 을 더한다" "$out3" "제약에 hidden 더함(1)"
has "  ↳ 이제 숨김으로 올릴 수 있다" "$(Q "insert into public.ticket_products(id,status) values ('tpZ','hidden') returning id")" "tpZ"

echo "── 7. 재실행 ──"
out2=$($P -f "$MIG2" 2>&1)
echo "$out2" | grep -q "❌" && { echo "❌ 재실행 ❌"; echo "$out2" | grep "❌"; FAIL=1; } || echo "✅ 재실행 ❌ 없음"
echo "$out2" | grep -q "ERROR" && { echo "❌ 재실행 ERROR"; echo "$out2" | grep -A2 ERROR | head; FAIL=1; } || echo "✅ 재실행 ERROR 없음"
has "재실행 — 이미 받음" "$out2" "✅ 이미 받음"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
