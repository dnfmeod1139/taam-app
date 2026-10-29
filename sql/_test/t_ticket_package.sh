#!/usr/bin/env bash
# 20261029_ticket_package.sql 회귀 — 티켓 연계(패키지): 만들기 · 단일 구매 막음 · 패키지 홀드·확정(예치금·카드) · 통째 취소 · 카드 환불 · 풀기
#   실제 가드(저장소 판)를 올린다: 결제 사실 칸(UPDATE/INSERT) · 확정 금액 하한 · 원장 환불 한도 두 개 · 같은 회차·같은 시간대 가드 · 단일 예치금 확정 함수.
#   라이브에만 있는 가드(INSERT 모양·행 잠금·정원)는 같은 규칙의 작은 대역을 둔다.
set -u
cd "$(dirname "$0")/../.."
DB=tpkg_$$
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

echo "── 1. 만들기(슈퍼어드민) ──"
has "회원은 못 만든다" "$(AS "$M1" "select public.taam_package_save(null,'나',array['tpA','tpB'])")" "FORBIDDEN"
has "파트너도 못 만든다" "$(AS "$PT" "select public.taam_package_save(null,'나',array['tpA','tpB'])")" "FORBIDDEN"
has "회차 1개는 거절" "$(AS "$SU" "select public.taam_package_save(null,'나',array['tpA'])")" "BAD_ROUNDS"
has "같은 날 같은 시간대(점심 12:00 · 13:00)는 거절" "$(AS "$SU" "select public.taam_package_save(null,'나',array['tpB','tpX','tpA'])")" "PACKAGE_CONFLICT.*같은 날 같은 시간대"
has "같은 매장 재구매 제한(30일) 안의 두 회차는 거절" "$(AS "$SU" "select public.taam_package_save(null,'나',array['tpA','tpR'])")" "PACKAGE_CONFLICT.*재구매 제한"
Q "update public.ticket_products set repurchase_open = true where id = 'tpR'" >/dev/null
has "재구매 해제된 회차면 통과(만들어진다)" "$(AS "$SU" "select public.taam_package_save(null,'시험',array['tpA','tpR'])")" '"ok": true'
Q "delete from public.ticket_package_rounds; delete from public.ticket_packages; update public.ticket_products set repurchase_open = false where id = 'tpR'" >/dev/null
has "지난 회차는 거절" "$(AS "$SU" "select public.taam_package_save(null,'나',array['tpA','tpOld'])")" "ROUND_PAST"
has "연도 없는 날짜는 거절" "$(AS "$SU" "select public.taam_package_save(null,'나',array['tpA','tpNY'])")" "ROUND_NO_YEAR"
has "승인 대기 회차는 거절" "$(AS "$SU" "select public.taam_package_save(null,'나',array['tpA','tpPend'])")" "ROUND_NOT_SELLABLE"
has "이름에 태그는 거절" "$(AS "$SU" "select public.taam_package_save(null,'<img src=x>',array['tpA','tpB'])")" "BAD_INPUT"
R=$(AS "$SU" "select public.taam_package_save(null,'도쿄 미식 3일',array['tpC','tpA','tpB'],'Tokyo 3 days','東京3日間','설명')")
has "만들기 — 회차 셋(매장 셋 · 같은 날 점심·저녁은 된다)" "$R" '"ok": true'
PK1=$(Q "select id from public.ticket_packages where title = '도쿄 미식 3일'")
ok "회차는 방문일·시각 순으로(A → B → C)" "$(Q "select string_agg(ticket_product_id, ',' order by sort) from public.ticket_package_rounds where package_id = '$PK1'")" "tpA,tpB,tpC"
has "이미 다른 패키지의 회차는 거절" "$(AS "$SU" "select public.taam_package_save(null,'둘',array['tpC','tpE'])")" "ROUND_IN_PACKAGE"
has "이름·설명 고치기(회차는 그대로)" "$(AS "$SU" "select public.taam_package_save('$PK1','도쿄 미식 3일',null,'Tokyo Gourmet 3 Days')")" '"updated": true'
ok "고친 영문 이름" "$(Q "select title_en from public.ticket_packages where id = '$PK1'")" "Tokyo Gourmet 3 Days"
has "목록 — 회차 · 주문 수 · 충돌 없음" "$(AS "$SU" "select public.taam_package_list()")" '"conflicts": \[\]'
has "목록은 슈퍼어드민만" "$(AS "$M1" "select public.taam_package_list()")" "FORBIDDEN"

echo "── 2. 연계된 회차의 단일 구매 막음 ──"
H(){ AS "$1" "insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,party_size,price,status,purchase_id,extra_data) values ('$1','$2','x','$3',$4,0,'hold','$5','$6'::jsonb)"; }
has "연계 회차에 단일 홀드 → PACKAGE_ONLY" "$(H "$M1" "$RA" tpA 2 PAYH-tpA_s1 '{}')" "PACKAGE_ONLY"
has "다른 패키지 id 를 붙인 홀드도 → PACKAGE_ONLY" "$(H "$M1" "$RA" tpA 2 PAYH-tpA_s2 '{"pkg":"pk_fake"}')" "PACKAGE_ONLY"
H "$M1" "$RD" tpD 2 PAYH-tpD_s1 '{"pkg":"pk_fake"}' >/dev/null
ok "연계 안 된 회차의 패키지 표시는 지운다(단일 홀드로)" "$(Q "select coalesce(extra_data->>'pkg','없음') from public.tickets where purchase_id = 'PAYH-tpD_s1'")" "없음"
Q "update public.tickets set status = 'cancelled' where purchase_id = 'PAYH-tpD_s1'" >/dev/null
has "서버(카드 확정 폴백)의 PAYC- 확정 행도 → PACKAGE_ONLY" "$(Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$M1','$RA','tpA',2,1000000,'active','PAYC-tpA_1')")" "PACKAGE_ONLY"
has "운영 행(수동 MAN-)은 막지 않는다(어드민 판단)" "$(Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','$RA','tpA',1,0,'manual','MAN-1') returning purchase_id")" "MAN-1"
Q "delete from public.tickets where purchase_id = 'MAN-1'" >/dev/null

echo "── 3. 패키지 홀드 · 등록 ──"
for x in A:$RA B:$RB C:$RC; do t=${x%%:*}; r=${x#*:}; H "$M1" "$r" tp$t 2 PAYH-tp${t}_m1 "{\"pkg\":\"$PK1\"}" >/dev/null; done
ok "패키지 홀드 셋(회원 세션 · 정원·같은 회차 가드를 지난다)" "$(Q "select count(*) from public.tickets where user_id = '$M1' and status = 'hold' and extra_data->>'pkg' = '$PK1'")" "3"
ok "패키지 홀드의 방문일은 회차 값(결제 사실 칸 가드)" "$(Q "select reservation_date from public.tickets where purchase_id = 'PAYH-tpB_m1'")" "$D61"
has "인원이 다르면 HOLDS_MISMATCH" "$(AS "$M1" "select public.taam_package_start('$PK1', 3, array['PAYH-tpA_m1','PAYH-tpB_m1','PAYH-tpC_m1'])")" "HOLDS_MISMATCH"
has "회차가 모자라면 HOLDS_MISMATCH" "$(AS "$M1" "select public.taam_package_start('$PK1', 2, array['PAYH-tpA_m1','PAYH-tpB_m1'])")" "HOLDS_MISMATCH"
has "남의 홀드로는 못 한다" "$(AS "$M2" "select public.taam_package_start('$PK1', 2, array['PAYH-tpA_m1','PAYH-tpB_m1','PAYH-tpC_m1'])")" "내 예약이 아닙니다"
has "화면 금액이 다르면 PRICE_CHANGED" "$(AS "$M1" "select public.taam_package_start('$PK1', 2, array['PAYH-tpA_m1','PAYH-tpB_m1','PAYH-tpC_m1'], 1000)")" "PRICE_CHANGED"
S1=$(AS "$M1" "select public.taam_package_start('$PK1', 2, array['PAYH-tpC_m1','PAYH-tpA_m1','PAYH-tpB_m1'], 2300000)")
has "등록 — 합계 = 정가 합 (1,000,000 + 800,000 + 500,000)" "$S1" '"total": 2300000'
has "등록 — 부족 800,000(잔액 1,500,000)" "$S1" '"shortfall": 800000'
G1=$(Q "select id from public.ticket_package_orders where user_id = '$M1' and status = 'hold'")

echo "── 4. 패키지 홀드를 단일 확정으로 집으면 막는다 ──"
has "단일 예치금 확정(taam_purchase_confirm_deposit) → PACKAGE_ONLY" "$(AS "$M1" "select public.taam_purchase_confirm_deposit('PAYH-tpA_m1', 1000000)")" "PACKAGE_ONLY"
ok "  ↳ 예치금 그대로 · 원장 없음" "$(Q "select membership_deposit_balance + general_deposit_balance from public.profiles where id = '$M1'")/$(Q "select count(*) from public.deposit_transactions where user_id = '$M1'")" "1500000/0"
has "서버가 홀드를 단일로 확정(toss-confirm 모양) → PACKAGE_ONLY" "$(Q "update public.tickets set status = 'active', price = 1000000 where purchase_id = 'PAYH-tpA_m1'")" "PACKAGE_ONLY"
has "예치금이 모자라면 INSUFFICIENT_DEPOSIT" "$(AS "$M1" "select public.taam_package_confirm_deposit('$G1', 2300000)")" "INSUFFICIENT_DEPOSIT"

echo "── 5. 카드 몫(서버 함수 — Edge toss-package-pay 가 부른다) ──"
has "회원은 카드 주문 함수를 못 부른다" "$(AS "$M1" "select public.taam_package_order_prepare('$G1', '$M1')")" "permission denied"
Q "update public.tickets set created_at = now() - interval '4 minutes' where purchase_id like 'PAYH-tp%_m1'" >/dev/null
O1=$(Q "select public.taam_package_order_prepare('$G1', '$M1')")
has "주문 — 카드 800,000 · 예치금 1,500,000" "$O1" '"amount": 800000'
OID1=$(echo "$O1" | grep -o '"order_id": "[^"]*"' | cut -d'"' -f4)
ok "주문 행 — package_topup · 묶음 id" "$(Q "select purpose || '/' || (metadata->>'group_id' = '$G1') || '/' || (metadata->>'deposit_used') from public.payment_orders where order_id = '$OID1'")" "package_topup/true/1500000"
ok "카드창 왕복 동안 좌석을 붙든다(홀드 시각 다시)" "$(Q "select count(*) from public.tickets where purchase_id like 'PAYH-tp%_m1' and created_at > now() - interval '1 minute'")" "3"
has "결제 안 된 주문으로 확정 → ORDER_NOT_PAID" "$(Q "select public.taam_package_confirm_card('$OID1')")" "ORDER_NOT_PAID"
O2=$(Q "select public.taam_package_order_prepare('$G1', '$M1')"); OID2=$(echo "$O2" | grep -o '"order_id": "[^"]*"' | cut -d'"' -f4)
ok "다시 주문하면 옛 주문은 superseded" "$(Q "select status || '/' || fail_reason from public.payment_orders where order_id = '$OID1'")" "failed/superseded"
Q "update public.payment_orders set status = 'paid', payment_key = 'pk_old' where order_id = '$OID1'" >/dev/null
has "늦게 승인된 옛 주문으로 확정 → ORDER_SUPERSEDED(Edge 가 카드 취소)" "$(Q "select public.taam_package_confirm_card('$OID1')")" "ORDER_SUPERSEDED"
Q "update public.payment_orders set status = 'paid', payment_key = 'pk_m1', approved_at = now() where order_id = '$OID2'" >/dev/null
C1=$(Q "select public.taam_package_confirm_card('$OID2')")
has "카드 확정 — 합계 2,300,000 · 예치금 1,500,000 · 카드 800,000" "$C1" '"card_paid": 800000'
ok "세 줄 확정 · 정가" "$(Q "select string_agg(purchase_id || '=' || status || ':' || price, ',' order by purchase_id) from public.tickets where purchase_id like 'PAYH-tp%_m1'")" "PAYH-tpA_m1=active:1000000,PAYH-tpB_m1=active:800000,PAYH-tpC_m1=active:500000"
ok "줄마다 몫 — A 예치금 1,000,000 · B 예치금 500,000+카드 300,000 · C 카드 500,000" "$(Q "select string_agg(coalesce(extra_data->>'depositUsed','-') || '+' || coalesce(extra_data->>'cardPaid','-') || '/' || coalesce(extra_data->>'order_id','-'), ',' order by purchase_id) from public.tickets where purchase_id like 'PAYH-tp%_m1'" | sed "s/$OID2/O/g")" "1000000+0/-,500000+300000/O,0+500000/O"
ok "원장 — A 멤버십 1,000,000 · B 일반 500,000 (구매 id 마다)" "$(Q "select string_agg(metadata->>'purchase_id' || ':' || deposit_type || ':' || amount, ',' order by metadata->>'purchase_id') from public.deposit_transactions where user_id = '$M1' and change_type = 'ticket_purchase'")" "PAYH-tpA_m1:membership:-1000000,PAYH-tpB_m1:general:-500000"
ok "잔액 0" "$(Q "select membership_deposit_balance || '/' || general_deposit_balance from public.profiles where id = '$M1'")" "0/0"
ok "묶음 paid · 표시용 pkg_info" "$(Q "select status from public.ticket_package_orders where id = '$G1'")/$(Q "select extra_data->'pkg_info'->>'i' || '/' || (extra_data->'pkg_info'->>'n') from public.tickets where purchase_id = 'PAYH-tpB_m1'")" "paid/2/3"
has "같은 주문으로 다시 확정 → already" "$(Q "select public.taam_package_confirm_card('$OID2')")" '"already": true'

echo "── 6. 결제된 패키지의 한 줄만 · 인원 ──"
has "회원이 한 줄만 취소 → PACKAGE_CANCEL_WHOLE" "$(AS "$M1" "update public.tickets set status = 'cancelled' where purchase_id = 'PAYH-tpC_m1'")" "PACKAGE_CANCEL_WHOLE"
has "인원 변경(슈퍼어드민 세션) → PACKAGE_PAX_LOCKED" "$(AS "$SU" "update public.tickets set party_size = 1 where purchase_id = 'PAYH-tpC_m1'")" "PACKAGE_PAX_LOCKED"

echo "── 7. 통째 취소 — 회차마다 규정 · 예치금 먼저 · 카드 몫은 환불 대기 ──"
has "남의 패키지 견적은 못 본다" "$(AS "$M2" "select public.taam_package_cancel_quote('$G1')")" "FORBIDDEN"
has "결제 30분 안 — 전액 2,300,000" "$(AS "$M1" "select public.taam_package_cancel_quote('$G1')")" '"refund": 2300000'
Q "update public.ticket_package_orders set paid_at = now() - interval '2 hours' where id = '$G1'" >/dev/null
QQ=$(AS "$M1" "select public.taam_package_cancel_quote('$G1')")
has "D-31 이상 — (1,000,000−200,000)+(800,000−100,000)+(500,000−100,000) = 1,900,000" "$QQ" '"refund": 1900000'
has "  ↳ 예치금 1,500,000 먼저 · 카드 400,000" "$QQ" '"card_refund": 400000'
has "화면 금액이 다르면 REFUND_CHANGED" "$(AS "$M1" "select public.taam_package_cancel('$G1', 2300000)")" "REFUND_CHANGED"
CX=$(AS "$M1" "select public.taam_package_cancel('$G1', 1900000, '일정 변경')")
has "취소 — 예치금 1,500,000 · 카드 400,000" "$CX" '"deposit_refund": 1500000'
ok "세 줄 모두 취소" "$(Q "select count(*) from public.tickets where purchase_id like 'PAYH-tp%_m1' and status = 'cancelled'")" "3"
ok "예치금이 나간 주머니로(멤버십 1,000,000 · 일반 500,000)" "$(Q "select membership_deposit_balance || '/' || general_deposit_balance from public.profiles where id = '$M1'")" "1000000/500000"
ok "환불 원장 — 구매 id 마다(환불 한도 가드를 지난다)" "$(Q "select string_agg(metadata->>'purchase_id' || ':' || deposit_type || ':' || amount, ',' order by metadata->>'purchase_id') from public.deposit_transactions where user_id = '$M1' and change_type = 'ticket_refund'")" "PAYH-tpA_m1:membership:1000000,PAYH-tpB_m1:general:500000"
ok "첫 줄에 카드 환불 대기 400,000(카드환불 탭)" "$(Q "select (extra_data->'card_refund_pending'->>'amount') || '/' || (extra_data->'card_refund_pending'->>'pkg_group' = '$G1') || '/' || (extra_data->'card_refund_pending'->>'set_by_role') from public.tickets where purchase_id = 'PAYH-tpA_m1'")" "400000/true/member"
ok "줄마다 예치금 환불 몫(A 800,000+200,000 · B 500,000 · C 0) · 줄 환불액(정책)" "$(Q "select string_agg((extra_data->>'deposit_refund') || '/' || (extra_data->>'refunded_amount'), ',' order by purchase_id) from public.tickets where purchase_id like 'PAYH-tp%_m1'")" "1000000/800000,500000/700000,0/400000"
ok "패키지 환불 요약은 첫 줄에만" "$(Q "select count(*) from public.tickets where purchase_id like 'PAYH-tp%_m1' and extra_data ? 'pkg_refund'")/$(Q "select extra_data->'pkg_refund'->>'refund' from public.tickets where purchase_id = 'PAYH-tpA_m1'")" "1/1900000"
ok "묶음 cancelled · 카드 환불 pending" "$(Q "select status || '/' || (card_refund->>'status') || '/' || (card_refund->>'amount') from public.ticket_package_orders where id = '$G1'")" "cancelled/pending/400000"
has "두 번 취소 → GROUP_CLOSED" "$(AS "$M1" "select public.taam_package_cancel('$G1', 0)")" "GROUP_CLOSED"

echo "── 8. 카드 환불 처리(슈퍼어드민) ──"
has "회원은 카드 환불 견적을 못 본다" "$(AS "$M1" "select public.taam_package_card_refund_quote('$G1')")" "FORBIDDEN"
RQ=$(AS "$SU" "select public.taam_package_card_refund_quote('$G1')")
has "견적 — 400,000 · 결제키" "$RQ" '"payment_key": "pk_m1"'
has "완료 표시" "$(AS "$SU" "select public.taam_package_card_refund_mark('$G1', 400000, 'tx_1', 'toss_api')")" '"ok": true'
ok "  ↳ 묶음 done · 첫 줄 대기 done · 주문 app_cancels" "$(Q "select card_refund->>'status' from public.ticket_package_orders where id = '$G1'")/$(Q "select extra_data->'card_refund_pending'->>'status' from public.tickets where purchase_id = 'PAYH-tpA_m1'")/$(Q "select jsonb_array_length(metadata->'app_cancels') from public.payment_orders where order_id = '$OID2'")" "done/done/1"
has "다시 표시 → already" "$(AS "$SU" "select public.taam_package_card_refund_mark('$G1', 400000)")" '"already": true'

echo "── 9. 예치금만 · 방문 30일 안 회차 · 방문 시작 ──"
R2=$(AS "$SU" "select public.taam_package_save(null,'연말 둘',array['tpD','tpE'])"); PK2=$(Q "select id from public.ticket_packages where title = '연말 둘'")
H "$M2" "$RD" tpD 2 PAYH-tpD_m2 "{\"pkg\":\"$PK2\"}" >/dev/null; H "$M2" "$RE" tpE 2 PAYH-tpE_m2 "{\"pkg\":\"$PK2\"}" >/dev/null
AS "$M2" "select public.taam_package_start('$PK2', 2, array['PAYH-tpD_m2','PAYH-tpE_m2'], 700000)" >/dev/null
G2=$(Q "select id from public.ticket_package_orders where user_id = '$M2' and status = 'hold'")
has "예치금 확정 — 240,000 + 460,000" "$(AS "$M2" "select public.taam_package_confirm_deposit('$G2', 700000)")" '"deposit_used": 700000'
ok "  ↳ 두 줄 확정 · 잔액 2,300,000" "$(Q "select count(*) from public.tickets where purchase_id like 'PAYH-tp%_m2' and status = 'active'")/$(Q "select membership_deposit_balance from public.profiles where id = '$M2'")" "2/2300000"
ok "  ↳ 원장 두 줄(멤버십)" "$(Q "select count(*) || ':' || sum(amount) from public.deposit_transactions where user_id = '$M2' and change_type = 'ticket_purchase' and deposit_type = 'membership'")" "2:-700000"
Q "update public.ticket_package_orders set paid_at = now() - interval '2 hours' where id = '$G2'" >/dev/null
has "방문 10일 전 회차는 0 · 75일 전 회차는 대행비 제외 400,000" "$(AS "$M2" "select public.taam_package_cancel_quote('$G2')")" '"refund": 400000'
# M3 도 같은 패키지 — 방문이 시작되면 회원은 못 취소 · 슈퍼어드민 전액은 된다
H "$M3" "$RD" tpD 2 PAYH-tpD_m3 "{\"pkg\":\"$PK2\"}" >/dev/null; H "$M3" "$RE" tpE 2 PAYH-tpE_m3 "{\"pkg\":\"$PK2\"}" >/dev/null
AS "$M3" "select public.taam_package_start('$PK2', 2, array['PAYH-tpD_m3','PAYH-tpE_m3'], 700000)" >/dev/null
G3=$(Q "select id from public.ticket_package_orders where user_id = '$M3' and status = 'hold'")
AS "$M3" "select public.taam_package_confirm_deposit('$G3', 700000)" >/dev/null
Q "update public.ticket_package_orders set items = jsonb_set(items, '{0,date}', to_jsonb('$DTODAY'::text)), paid_at = now() - interval '2 hours' where id = '$G3'" >/dev/null
has "방문이 시작된 패키지 — 회원 취소 → PACKAGE_CANCEL_CLOSED" "$(AS "$M3" "select public.taam_package_cancel('$G3', null)")" "PACKAGE_CANCEL_CLOSED"
has "슈퍼어드민 전액 환불 취소는 된다(700,000)" "$(AS "$SU" "select public.taam_package_cancel('$G3', 700000, '운영 판단', true)")" '"refund": 700000'
ok "  ↳ M3 일반 예치금 5,000,000 으로 복구" "$(Q "select general_deposit_balance from public.profiles where id = '$M3'")" "5000000"
has "회원 M2 취소(400,000)" "$(AS "$M2" "select public.taam_package_cancel('$G2', 400000)")" '"deposit_refund": 400000'
ok "  ↳ M2 잔액 2,700,000 · 카드 환불 없음" "$(Q "select membership_deposit_balance from public.profiles where id = '$M2'")/$(Q "select coalesce(card_refund::text,'없음') from public.ticket_package_orders where id = '$G2'")" "2700000/없음"

echo "── 10. 이미 산 회차 · 홀드 만료 · 반납 ──"
has "단일로 이미 산 회차(tpE)가 든 패키지 → DUPLICATE_PURCHASE(같은 회차 가드)" "$(H "$M5" "$RE" tpE 2 PAYH-tpE_m5 "{\"pkg\":\"$PK2\"}")" "DUPLICATE_PURCHASE"
H "$M5" "$RD" tpD 2 PAYH-tpD_m5 "{\"pkg\":\"$PK2\"}" >/dev/null
Q "update public.tickets set created_at = now() - interval '6 minutes' where purchase_id = 'PAYH-tpD_m5'" >/dev/null
Q "select public.taam_expire_seat_holds()" >/dev/null
ok "5분 지난 패키지 홀드는 기존 만료가 푼다" "$(Q "select status from public.tickets where purchase_id = 'PAYH-tpD_m5'")" "cancelled"
H "$M5" "$RD" tpD 2 PAYH-tpD_m5b "{\"pkg\":\"$PK2\"}" >/dev/null
has "회원 반납(패키지 회차의 내 홀드)" "$(AS "$M5" "select public.taam_package_release(null, '$PK2')")" '"released": 1'

echo "── 11. 실패 · 풀기 · 회차 삭제 ──"
H "$M2" "$RD" tpD 1 PAYH-tpD_m2b "{\"pkg\":\"$PK2\"}" >/dev/null; H "$M2" "$RE" tpE 1 PAYH-tpE_m2b "{\"pkg\":\"$PK2\"}" >/dev/null
AS "$M2" "select public.taam_package_start('$PK2', 1, array['PAYH-tpD_m2b','PAYH-tpE_m2b'])" >/dev/null
G4=$(Q "select id from public.ticket_package_orders where user_id = '$M2' and status = 'hold'")
has "서버 실패 처리 — 홀드 반납" "$(Q "select public.taam_package_fail('$G4', 'seat_lost')")" '"released": 2'
has "회원은 실패 함수를 못 부른다" "$(AS "$M2" "select public.taam_package_fail('$G4', 'x')")" "permission denied"
has "연계된 회차는 못 지운다 → PACKAGE_ROUND_LOCKED" "$(Q "delete from public.ticket_products where id = 'tpD'")" "PACKAGE_ROUND_LOCKED"
H "$M2" "$RD" tpD 1 PAYH-tpD_m2c "{\"pkg\":\"$PK2\"}" >/dev/null; H "$M2" "$RE" tpE 1 PAYH-tpE_m2c "{\"pkg\":\"$PK2\"}" >/dev/null
AS "$M2" "select public.taam_package_start('$PK2', 1, array['PAYH-tpD_m2c','PAYH-tpE_m2c'])" >/dev/null
G5=$(Q "select id from public.ticket_package_orders where user_id = '$M2' and status = 'hold'")
has "풀기(슈퍼어드민) — 결제 중 묶음 수" "$(AS "$SU" "select public.taam_package_unlink('$PK2')")" '"holds_in_flight": 1'
has "풀린 뒤 결제 중이던 패키지 확정 → PACKAGE_NOT_ACTIVE" "$(AS "$M2" "select public.taam_package_confirm_deposit('$G5', 340000)")" "PACKAGE_NOT_ACTIVE"
has "풀린 뒤 그 패키지 홀드를 단일로 확정해도 → PACKAGE_ONLY(패키지 표시가 남은 홀드)" "$(AS "$M2" "select public.taam_purchase_confirm_deposit('PAYH-tpD_m2c', 120000)")" "PACKAGE_ONLY"
AS "$M2" "select public.taam_package_release(null, '$PK2')" >/dev/null
H "$M2" "$RD" tpD 1 PAYH-tpD_single '{}' >/dev/null
has "풀린 회차는 단일로 다시 산다" "$(AS "$M2" "select public.taam_purchase_confirm_deposit('PAYH-tpD_single', 120000)")" '"ok" : true'
has "풀린 회차는 지울 수 있다" "$(Q "delete from public.ticket_products where id = 'tpX' returning id")" "tpX"

echo "── 12. 읽기 권한 ──"
ok "비로그인은 연계 중인 패키지만 읽는다" "$(ANON "select count(*) from public.ticket_packages")" "1"
ok "회원은 자기 패키지 구매만 읽는다" "$(AS "$M1" "select count(*) from public.ticket_package_orders")" "1"
has "회원은 패키지 표를 못 쓴다" "$(AS "$M1" "insert into public.ticket_packages(id,title) values ('x','y')")" "permission denied"
has "회원은 구매 표를 못 쓴다" "$(AS "$M1" "update public.ticket_package_orders set status = 'paid'")" "permission denied"

echo "── 13. 재실행 ──"
out2=$($P -f "$MIG" 2>&1)
echo "$out2" | grep -q "❌" && { echo "❌ 재실행 ❌"; echo "$out2" | grep "❌"; FAIL=1; } || echo "✅ 재실행 ❌ 없음"
echo "$out2" | grep -q "ERROR" && { echo "❌ 재실행 ERROR"; echo "$out2" | grep -A2 ERROR | head; FAIL=1; } || echo "✅ 재실행 ERROR 없음"
has "재실행 — 용도 제약 이미 있음" "$out2" "이미 있음"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
