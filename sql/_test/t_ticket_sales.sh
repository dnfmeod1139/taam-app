#!/bin/bash
# 📊 티켓 판매 현황 RPC (supabase/migrations/20261021_ticket_sales_report.sql) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_ticket_sales.sh
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261021_ticket_sales_report.sql
FAIL=0
DB=t_sales; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M1=b1000000-0000-4000-8000-000000000001; M2=b1000000-0000-4000-8000-000000000002; TST=b1000000-0000-4000-8000-000000000003
SU=b1000000-0000-4000-8000-000000000009; RA=b1000000-0000-4000-8000-000000000008
R1=c1000000-0000-4000-8000-000000000001
I1=e1000000-0000-4000-8000-000000000001; I2=e2000000-0000-4000-8000-000000000002; I3=e3000000-0000-4000-8000-000000000003
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable security definer set search_path = public as \$\$
begin
  if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if;
  return session_user = 'postgres' or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then return false; end \$\$;
create or replace function public._taam_pu_visit_date(p_text text) returns date language plpgsql immutable as \$\$
declare m text[]; d date; begin
  if p_text is null then return null; end if;
  m := regexp_match(btrim(p_text), '^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})'); if m is null then return null; end if;
  d := make_date(m[1]::int, m[2]::int, m[3]::int); if d < date '2020-01-01' or d > date '2100-01-01' then return null; end if; return d;
exception when others then return null; end \$\$;
create table public.profiles(id uuid primary key, display_name text, role text, is_test boolean default false);
create table public.restaurants(id uuid primary key, name text);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, meal_fee int, agency_fee int, wine_min int);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text,
  reservation_date text, visit_time text, party_size int, price bigint, status text, purchase_id text, buyer_name text, extra_data jsonb default '{}', visit_status text, created_at timestamptz default now());
create table public.payment_orders(order_id text primary key, user_id uuid, purpose text, amount numeric, currency text default 'KRW', settle_krw bigint, status text, method text,
  approved_at timestamptz, updated_at timestamptz default now(), fail_reason text, metadata jsonb default '{}');
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint, description text, metadata jsonb default '{}', created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key, host_user_id uuid, invitee_user_id uuid, restaurant_id text, restaurant_name text, visit_date text, visit_time text,
  pax int, meal_fee int, agency_fee int, wine_min int, total_amount int, status text, created_at timestamptz default now(), paid_at timestamptz, cancelled_at timestamptz, ticket_product_id text);
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_id text not null, venue_name text, event_date date not null, event_time time, ticket_product_id text, created_at timestamptz default now());
create table public.kashikiri_teams(id uuid primary key default gen_random_uuid(), event_id uuid, seq int, pax int default 1);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, label text not null, user_id uuid, amount_krw int not null, status text not null,
  order_id text, payment_key text, method text, fail_reason text, payer_name text, approved_at timestamptz, created_at timestamptz default now(),
  pay_currency text default 'KRW', pay_amount numeric(14,2), pay_fx numeric(12,4), refund_krw int, refund_amount numeric(14,2), refunded_at timestamptz, link_invite boolean default false,
  purpose text default 'custom', title text, payload jsonb default '{}');
create table public.daegwan_manual(id uuid primary key default gen_random_uuid(), venue_id text, ymd date, name text, pax int, amount int, memo text, ttype text, venue_name text, created_by uuid, created_at timestamptz default now());
SQL
out=$($P -f "$MIG" 2>&1)

$P <<SQL >/dev/null
insert into public.profiles values ('$M1','회원1','user',false),('$M2','회원2','user',false),('$TST','테스트1','user',true),('$SU','운영','superadmin',true),('$RA','매장','admin',false);
insert into public.restaurants values ('$R1','메이노');
insert into public.ticket_products values ('tp1','$R1','메이노','2026.11.03','19:00',600000,150000,100000), ('tp2','$R1','메이노','2026.12.01','12:00',300000,100000,0);
-- 1 예치금 구매 active 2인 1.7M (원장 두 주머니)
insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','메이노','tp1','2026.11.03',2,1700000,'active','PAYH-tp1_1','{"paidBy":"deposit","server_confirmed":true,"confirmed_at":"2026-09-15T01:00:00Z"}','2026-09-15T00:58:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','membership','ticket_purchase',-1000000,'{"purchase_id":"PAYH-tp1_1"}','2026-09-15T01:00:00Z'),
 ('$M1','general','ticket_purchase',-700000,'{"purchase_id":"PAYH-tp1_1"}','2026-09-15T01:00:00Z');
-- 2 카드+예치금 2인 (tp2: 400k×2=800k) card 300k dep 500k
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M2','$R1','tp2','2026.12.01',2,800000,'active','PAYH-tp2_2','{"paidBy":"card+deposit","cardPaid":300000,"depositUsed":500000,"agencyFee":100000,"order_id":"O2"}','2026-09-20T00:00:00Z');
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,status,approved_at,metadata) values ('O2','$M2','ticket_topup',300000,'KRW','paid','2026-09-20T00:05:00Z','{"toss":{}}');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M2','general','ticket_purchase',-500000,'{"purchase_id":"PAYH-tp2_2","order_id":"O2"}','2026-09-20T00:05:00Z');
-- 3 D-31 회원 취소: 1.7M 중 1.4M 환불 (두 주머니 · 같은 metadata)
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.11.03',2,1700000,'cancelled','PAYH-tp1_3','{"paidBy":"deposit","server_confirmed":true,"cancel_reason":"D-31","cancelled_at":"2026-09-25T00:00:00Z","deposit_refund":1400000}','2026-09-16T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','membership','ticket_purchase',-1700000,'{"purchase_id":"PAYH-tp1_3"}','2026-09-16T00:00:00Z'),
 ('$M1','membership','ticket_refund',1000000,'{"purchase_id":"PAYH-tp1_3","cancel_refund":true,"refund_type":"returned","agency_held":300000}','2026-09-25T00:00:00Z'),
 ('$M1','general','ticket_refund',400000,'{"purchase_id":"PAYH-tp1_3","cancel_refund":true,"refund_type":"returned","agency_held":300000}','2026-09-25T00:00:00Z');
-- 4 D-30 회원 취소 (환불 0 · 원장 없음)
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M2','$R1','tp1','2026.11.03',1,850000,'cancelled','PAYH-tp1_4','{"paidBy":"deposit","server_confirmed":true,"cancel_reason":"D-30","deposit_refund":0}','2026-09-17T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M2','general','ticket_purchase',-850000,'{"purchase_id":"PAYH-tp1_4"}','2026-09-17T00:00:00Z');
-- 5 버려진 홀드 (cancelled · 0원) → 판매 아님
insert into public.tickets(user_id,ticket_product_id,party_size,price,status,purchase_id,extra_data) values ('$M1','tp1',2,0,'cancelled','PAYH-tp1_5','{"seatHold":true}');
-- 6 슈퍼어드민 방문 후 반환: 1.4M 돌려줌 · 대행비 300k 보유
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.10.01',2,1700000,'cancelled','PAYH-tp1_6','{"paidBy":"deposit","server_confirmed":true,"deposit_return":{"type":"returned","agencyHeld":300000,"returnAmt":1400000}}','2026-09-01T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','general','ticket_purchase',-1700000,'{"purchase_id":"PAYH-tp1_6"}','2026-09-01T00:00:00Z'),
 ('$M1','general','ticket_refund',1400000,'{"purchase_id":"PAYH-tp1_6","refund_type":"returned","agency_held":300000,"processed_by":"super_admin"}','2026-10-02T00:00:00Z');
-- 7 카드 전액 · 30분 안 취소 · 카드 환불 대기 400k
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M2','$R1','tp2','2026.12.01',1,400000,'cancelled','PAYH-tp2_7','{"paidBy":"card+deposit","cardPaid":400000,"depositUsed":0,"agencyFee":100000,"order_id":"O7","cancel_reason":"30분","card_refund_pending":{"amount":400000,"status":"pending"}}','2026-09-21T00:00:00Z');
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,status,approved_at) values ('O7','$M2','ticket_topup',400000,'KRW','paid','2026-09-21T00:01:00Z');
-- 8 PAYC- 폴백 행 (reservation_date null → 회차 날짜)
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M2','$R1','tp2',null,1,400000,'active','PAYC-tp2_8','{"paidBy":"card+deposit","cardPaid":400000,"depositUsed":0,"agencyFee":100000,"order_id":"O8"}','2026-09-22T00:00:00Z');
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,status,approved_at) values ('O8','$M2','ticket_topup',400000,'KRW','paid','2026-09-22T00:01:00Z');
-- 9 테스트 계정 구매 → 기본 제외
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$TST','$R1','tp2','2026.12.01',1,1000,'active','PAYH-tp2_9','{"paidBy":"deposit","server_confirmed":true}','2026-09-23T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$TST','general','ticket_purchase',-1000,'{"purchase_id":"PAYH-tp2_9"}','2026-09-23T00:00:00Z');
-- 10 카드 승인 뒤 좌석 상실 되돌림 (홀드 0원 · 원장 −/+ 짝) → 판매 아님
insert into public.tickets(user_id,ticket_product_id,party_size,price,status,purchase_id) values ('$M1','tp2',1,0,'cancelled','PAYH-tp2_10');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values
 ('$M1','general','ticket_purchase',-200000,'{"purchase_id":"PAYH-tp2_10","order_id":"O10"}'),('$M1','general','ticket_refund',200000,'{"purchase_id":"PAYH-tp2_10","order_id":"O10"}');
-- 11 인원 축소 2→1 (price 가 순액으로 줄었다) · 원장 ticket_pax_change
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.11.03',1,850000,'active','PAYH-tp1_11','{"paidBy":"deposit","server_confirmed":true,"pax_changes":[{"from":2,"to":1,"refund":850000,"price_before":1700000,"price_after":850000}]}','2026-09-18T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','general','ticket_purchase',-1700000,'{"purchase_id":"PAYH-tp1_11"}','2026-09-18T00:00:00Z'),('$M1','general','ticket_pax_change',850000,'{"purchase_id":"PAYH-tp1_11"}','2026-09-19T00:00:00Z');
-- 12 초대 (연결 · INV- 행 있음) 1.2M — 한 번만 세야 한다
insert into public.reservation_invites values ('$I1','$SU','$M1','$R1','메이노','2026.11.10','19:00',2,450000,100000,50000,1200000,'paid','2026-09-05','2026-09-06T00:00:00Z',null,'tp1');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M1','membership','ticket_purchase',-1200000,'{"purchase_id":"INV-e1000000-1","invite_id":"$I1","source":"reservation_invite"}','2026-09-06T00:00:01Z');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.11.10',2,1200000,'active','INV-e1000000-1','{"inviteId":"$I1","invitePaid":true}','2026-09-05T00:00:00Z');
-- 13 초대 (연결 없음 · 티켓 행 없음) 1.0M → 회원 취소 환불 1.0M
insert into public.reservation_invites values ('$I2','$SU','$M2','$R1','메이노','2026.12.20','12:00',1,800000,200000,0,1000000,'cancelled','2026-09-07','2026-09-08T00:00:00Z',null,null);
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M2','general','ticket_purchase',-1000000,'{"purchase_id":"INV-e2000000-2","invite_id":"$I2","source":"reservation_invite"}','2026-09-08T00:00:01Z'),
 ('$M2','general','ticket_refund',1000000,'{"purchase_id":"INV-e2000000-2","cancel_refund":true,"refund_type":"returned"}','2026-09-09T00:00:00Z');
-- 14 INVH 홀드 (price 있음) → 판매 아님
insert into public.tickets(user_id,ticket_product_id,party_size,price,status,purchase_id,extra_data) values ('$SU','tp1',2,1700000,'hold','INVH-e3000000-1','{"inviteHold":true}');
-- 15·16·17 결제 링크
insert into public.kashikiri_events(id,venue_id,venue_name,event_date,event_time,ticket_product_id) values ('f1000000-0000-4000-8000-000000000001','$R1','메이노','2026-11-03','19:00','tp1');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data)
 values ('$SU','$R1','tp1','2026.11.03',2,1700000,'active','LINK-a','{"chargeId":"a0000000-0000-4000-8000-000000000015","agencyFee":150000,"priceOverride":true}'),
        ('$SU','$R1','tp1','2026.11.03',2,1700000,'cancelled','LINK-b','{"chargeId":"a0000000-0000-4000-8000-000000000016","agencyFee":150000}'),
        ('$SU','$R1','tp1','2026.11.03',2,1700000,'cancelled','LINK-c','{"chargeId":"a0000000-0000-4000-8000-000000000017","agencyFee":150000}');
insert into public.kashikiri_charges(id,event_id,label,amount_krw,status,approved_at,link_invite,purpose,payload,pay_currency,pay_amount,pay_fx,refund_krw,refund_amount,refunded_at,payer_name) values
 ('a0000000-0000-4000-8000-000000000015','f1000000-0000-4000-8000-000000000001','손님A',1500000,'paid','2026-09-26T00:00:00Z',true,'ticket','{"price_override":true}','KRW',1500000,1,null,null,null,'손님A'),
 ('a0000000-0000-4000-8000-000000000016','f1000000-0000-4000-8000-000000000001','손님B',2500000,'refunded','2026-09-27T00:00:00Z',true,'ticket','{}','USD',1860,1344.0860,2200000,1620,'2026-09-28T00:00:00Z','Trina'),
 ('a0000000-0000-4000-8000-000000000017','f1000000-0000-4000-8000-000000000001','손님C',1700000,'refunded','2026-09-27T01:00:00Z',true,'ticket','{}','KRW',1700000,1,0,0,'2026-10-20T00:00:00Z','손님C');
-- 18 정산 (연결된 회차) · 한 조 4명 · 두 청구
insert into public.kashikiri_events(id,venue_id,venue_name,event_date,ticket_product_id) values ('f2000000-0000-4000-8000-000000000002','$R1','메이노 대관','2026-10-05','tp1');
insert into public.kashikiri_teams(id,event_id,seq,pax) values ('f3000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000002',1,4);
insert into public.kashikiri_charges(event_id,team_id,label,amount_krw,status,approved_at,purpose) values
 ('f2000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000003','K',400000,'paid','2026-09-29T00:00:00Z','custom'),
 ('f2000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000003','동행',400000,'paid','2026-09-29T01:00:00Z','custom');
-- 19 정산 (티켓 미연결 manual- 회차) → settle_x
insert into public.kashikiri_events(id,venue_id,venue_name,event_date) values ('f4000000-0000-4000-8000-000000000004','manual-123','임의 매장','2026-09-30');
insert into public.kashikiri_charges(event_id,label,amount_krw,status,approved_at,purpose) values ('f4000000-0000-4000-8000-000000000004','X',1125000,'paid','2026-09-30T00:00:00Z','custom');
-- 20·21 멤버십 링크 · 자유 금액 → 판매 아님 (참고 합계)
insert into public.kashikiri_charges(label,amount_krw,status,approved_at,purpose,user_id) values ('M',11250000,'paid','2026-09-24T00:00:00Z','membership','$M1'),('F',50000,'paid','2026-09-24T01:00:00Z','custom',null);
-- 22 수동 입력 (매장 어드민) · 취소된 수동 입력
insert into public.tickets(user_id,restaurant_id,restaurant_name,reservation_date,party_size,price,status,purchase_id,extra_data,created_at) values
 ('$RA','$R1','메이노','2026.10.10',2,300000,'manual','MAN-1','{"manualEntry":true,"ttype":"오프라인"}','2026-09-10T00:00:00Z'),
 ('$RA','$R1','메이노','2026.10.11',2,500000,'cancelled','MAN-2','{"manualEntry":true}','2026-09-10T00:00:00Z');
-- 23 수동 기록
insert into public.daegwan_manual(venue_id,ymd,name,pax,amount,ttype,created_by,created_at) values ('$R1','2026-10-12','홍',2,200000,'오프라인','$SU','2026-09-11T00:00:00Z');
-- 24 정정 줄 (fix) 은 환불로 세지 않는다
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M1','general','ticket_refund',1700000,'{"purchase_id":"PAYH-tp1_1","fix":"double_deduct_2026-09-14"}','2026-09-15T05:00:00Z');
-- 25 게스트석 확정 대기
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M2','$R1','tp1','2026.11.03',1,1000000,'pending_confirm','PAYH-tp1_25','{}','2026-09-24T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M2','general','ticket_purchase',-1000000,'{"purchase_id":"PAYH-tp1_25"}','2026-09-24T00:00:00Z');
-- 26 카드 잡혔는데 티켓 없음
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,status,approved_at,fail_reason) values ('O26','$M1','ticket_topup',300000,'KRW','paid','2026-09-24T00:00:00Z','seat_lost_refund_failed');
-- 27 회원이 extra_data 에 숫자 아닌 cardPaid 를 써도 보고서가 깨지지 않는다
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp2','2026.12.01',1,400000,'active','PAYH-tp2_27','{"paidBy":"deposit","server_confirmed":true,"cardPaid":"abc","agencyFee":"x"}','2026-09-24T02:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M1','general','ticket_purchase',-400000,'{"purchase_id":"PAYH-tp2_27"}','2026-09-24T02:00:00Z');
SQL

R="select public.taam_ticket_sales_report(null, null, 'paid', false)"
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $3, 실제 $2)"; FAIL=1; fi; }
ok "마이그레이션: 오류 없음 · 확인 표 ❌ 0 · ①~④ ✅" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -cE '^ *(①|②|③|④).*✅')" "|0|4"
q(){ $P -c "with j as ($R as j) $1" 2>&1; }
row(){ q "select $2 from j, jsonb_array_elements(j->'rows') r where r->>'k' = '$1'"; }

ok "1 예치금 판매 gross·dep·net·대행비 예정" "$(row PAYH-tp1_1 "concat_ws('/', r->>'gross', r->>'dep', r->>'pm', r->>'net', r->>'agency', r->>'ag_state', r->>'bd')")" "1700000/1700000/deposit/1700000/300000/planned/product"
ok "1 정정(fix) 줄은 환불이 아니다" "$(row PAYH-tp1_1 "r->>'rf_cancel'")" "0"
ok "1 결제일 = 원장 첫 차감 (KST)" "$(row PAYH-tp1_1 "r->>'paid_ymd'")" "2026-09-15"
ok "2 카드+예치금 = mixed · card 는 주문 기준 · 대행비는 회차 요금" "$(row PAYH-tp2_2 "concat_ws('/', r->>'pm', r->>'card', r->>'dep', r->>'bd')")" "mixed/300000/500000/product"
ok "3 D-31 취소 — 두 주머니 합 · 대행비 확정 300k" "$(row PAYH-tp1_3 "concat_ws('/', r->>'st', r->>'rf_cancel', r->>'net', r->>'agency', r->>'ag_state')")" "cancelled/1400000/300000/300000/kept"
ok "4 D-30 취소 — 환불 0 · 전액 보유" "$(row PAYH-tp1_4 "concat_ws('/', r->>'st', r->>'rf_cancel', r->>'net', r->>'agency')")" "cancelled/0/850000/150000"
ok "5 버려진 홀드는 행이 없다" "$(q "select count(*) from j, jsonb_array_elements(j->'rows') r where r->>'k' in ('PAYH-tp1_5','PAYH-tp2_10')")" "0"
ok "6 방문 후 반환 — 순판매엔 안 빠지고 held 만 줄어든다" "$(row PAYH-tp1_6 "concat_ws('/', r->>'st', r->>'rf_return', r->>'net', r->>'held', r->>'agency', r->>'ag_state')")" "returned/1400000/1700000/300000/300000/kept"
ok "7 카드 30분 취소 — 카드 환불 대기도 환불로" "$(row PAYH-tp2_7 "concat_ws('/', r->>'pm', r->>'rf_cancel', r->>'rf_card_pending', r->>'net', r->>'agency')")" "card/400000/400000/0/0"
ok "8 PAYC 폴백 — 방문일은 회차 날짜" "$(row PAYC-tp2_8 "concat_ws('/', r->>'visit', r->>'pm')")" "2026-12-01/card"
ok "9 테스트 계정 기본 제외" "$(q "select (select count(*) from jsonb_array_elements(j->'rows') r where r->>'k'='PAYH-tp2_9') || '/' || (j->'excluded'->'test'->>'n') from j")" "0/1"
ok "11 인원 축소 — gross 원래 · rf_pax · net" "$(row PAYH-tp1_11 "concat_ws('/', r->>'gross', r->>'rf_pax', r->>'net', r->>'pax', r->>'pax0', r->>'agency')")" "1700000/850000/850000/1/2/150000"
ok "12 초대는 한 번만 (INV- 행을 앱 구매로 다시 세지 않는다)" "$(q "select count(*) from j, jsonb_array_elements(j->'rows') r where r->>'k' in ('inv:$I1','INV-e1000000-1')")" "1"
ok "12 초대 내역 스냅샷" "$(row "inv:$I1" "concat_ws('/', r->>'gross', r->>'meal', r->>'ag_gross', r->>'wine', r->>'bd', r->>'paid_ymd')")" "1200000/900000/200000/100000/snap/2026-09-06"
ok "13 티켓 행 없는 초대 · 취소 환불 매칭" "$(row "inv:$I2" "concat_ws('/', r->>'st', r->>'rf_cancel', r->>'net', (r->'flags')::text)")" "cancelled/1000000/0/[\"no_ticket_row\"]"
ok "14 INVH 홀드는 판매 아님" "$(q "select count(*) from j, jsonb_array_elements(j->'rows') r where r->>'k' like 'INVH%'")" "0"
ok "15 결제 링크 — 청구액 (정가 1.7M 아님)" "$(row chg:a0000000-0000-4000-8000-000000000015 "concat_ws('/', r->>'ch', r->>'gross', r->>'net', r->>'agency', (r->'flags')::text)")" "link/1500000/1500000/300000/[\"price_override\"]"
ok "16 외화 링크 부분 환불" "$(row chg:a0000000-0000-4000-8000-000000000016 "concat_ws('/', r->>'cur', r->>'fx_amt', r->>'rf_cancel', r->>'net', r->>'fx_refund')")" "USD/1860.00/2200000/300000/1620.00"
ok "17 ₩0 환불 링크는 전액 보유" "$(row chg:a0000000-0000-4000-8000-000000000017 "concat_ws('/', r->>'st', r->>'net', (r->'flags')::text)")" "cancelled/1700000/[\"refunded_zero\"]"
ok "18 정산 — 조 인원은 한 번만" "$(q "select count(*) || '/' || sum((r->>'pax')::int) || '/' || sum((r->>'net')::int) from j, jsonb_array_elements(j->'rows') r where r->>'ch'='settle'")" "2/4/800000"
ok "19 미연결 정산은 settle_x" "$(q "select count(*) from j, jsonb_array_elements(j->'rows') r where r->>'ch'='settle_x'")" "1"
ok "20·21 멤버십·자유 금액은 행이 아니라 참고 합계" "$(q "select (j->'excluded'->'membership'->>'krw') || '/' || (j->'excluded'->'custom'->>'krw') || '/' || (select count(*) from jsonb_array_elements(j->'rows') r where r->>'ch' like 'x_%') from j")" "11250000/50000/0"
ok "22 수동 입력 — 매장 어드민 표시 · 취소분은 참고" "$(q "select (select concat_ws('/', r->>'ch', r->>'gross', (r->'flags')::text) from jsonb_array_elements(j->'rows') r where r->>'k'='MAN-1') || '|' || (j->'excluded'->'man_cancelled'->>'n') from j")" "man/300000/[\"manual_unverified\", \"by_rest_admin\"]|1"
ok "23 수동 기록" "$(q "select count(*) from j, jsonb_array_elements(j->'rows') r where r->>'ch'='dm'")" "1"
ok "25 게스트석 확정 대기 — 제외 표시" "$(row PAYH-tp1_25 "concat_ws('/', r->>'st', r->>'x')")" "guest_pending/guest_pending"
ok "26 카드 잡힌 채 티켓 없음 → 예외" "$(q "select count(*) from j, jsonb_array_elements(j->'exceptions') e where e->>'kind'='card_captured_no_ticket'")" "1"
ok "27 숫자 아닌 extra_data 도 안 깨진다" "$(row PAYH-tp2_27 "concat_ws('/', r->>'pm', r->>'ag_gross')")" "deposit/100000"
ok "기간 — 9월 결제일만" "$($P -c "select jsonb_array_length(public.taam_ticket_sales_report('2026-09-01','2026-10-01','paid',false)->'rows')")" "$(q "select count(*) from j, jsonb_array_elements(j->'rows') r where (r->>'paid_ymd') between '2026-09-01' and '2026-09-30'")"
ok "방문일 기준 — 11월 방문" "$($P -c "select string_agg(r->>'k', ',' order by r->>'k') from jsonb_array_elements(public.taam_ticket_sales_report('2026-11-01','2026-12-01','visit',false)->'rows') r")" "PAYH-tp1_1,PAYH-tp1_11,PAYH-tp1_25,PAYH-tp1_3,PAYH-tp1_4,chg:a0000000-0000-4000-8000-000000000015,chg:a0000000-0000-4000-8000-000000000016,chg:a0000000-0000-4000-8000-000000000017,inv:$I1"
ok "역범위는 BAD_RANGE" "$($P -c "select public.taam_ticket_sales_report('2026-10-01','2026-09-01')" 2>&1 | grep -c BAD_RANGE)" "1"
ok "회원 세션은 FORBIDDEN" "$($P -c "set taam.uid='$M1'; select public.taam_ticket_sales_report()" 2>&1 | grep -c FORBIDDEN)" "1"
ok "슈퍼어드민 세션은 통과" "$($P -c "set taam.uid='$SU'; set taam.super='1'; select (public.taam_ticket_sales_report()->>'ok')" 2>&1)" "true"
ok "anon 은 실행 권한 없음" "$($P -c "set role anon; select public.taam_ticket_sales_report()" 2>&1 | grep -c 'permission denied')" "1"
echo "── 합계 (전체 · 결제일 · 기본 채널 app/invite/link/settle · guest 제외) ──"
q "select sum((r->>'gross')::bigint) gross, sum((r->>'rf_cancel')::bigint+(r->>'rf_penalty')::bigint+(r->>'rf_pax')::bigint) refund, sum((r->>'net')::bigint) net, sum((r->>'agency')::bigint) agency, count(*) n
     from j, jsonb_array_elements(j->'rows') r where r->>'ch' in ('app','invite','link','settle') and r->>'x' is null"

echo "── 추가: 고친 것 · 경계 ──"
$P <<SQL >/dev/null
-- A 조 없는 정산 청구 둘 — 각자 1명(한 칸으로 묶여 하나만 인원을 받던 것)
insert into public.kashikiri_events(id,venue_id,venue_name,event_date,ticket_product_id) values ('f5000000-0000-4000-8000-000000000005','$R1','메이노 대관2','2026-10-06','tp1');
insert into public.kashikiri_charges(event_id,label,amount_krw,status,approved_at,purpose) values
 ('f5000000-0000-4000-8000-000000000005','조없음1',100000,'paid','2026-09-29T02:00:00Z','custom'),
 ('f5000000-0000-4000-8000-000000000005','조없음2',100000,'paid','2026-09-29T03:00:00Z','custom');
-- F 접두어 없는 옛 앱 행(2026-07) · 예치금
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.07.20',2,1700000,'active','tp1_1752000000000','{}','2026-07-10T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M1','general','ticket_purchase',-1700000,'{"purchase_id":"tp1_1752000000000"}','2026-07-10T00:00:00Z');
-- G 회원 소유 결제 링크 · memberUid 가 깨진 값
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data)
 values ('$SU','$R1','tp1','2026.11.03',1,850000,'active','LINK-g','{"chargeId":"a0000000-0000-4000-8000-000000000099","memberUid":"not-a-uuid"}');
insert into public.kashikiri_charges(id,event_id,label,amount_krw,status,approved_at,link_invite,purpose,pay_currency,pay_amount,pay_fx)
 values ('a0000000-0000-4000-8000-000000000099','f1000000-0000-4000-8000-000000000001','G',850000,'paid','2026-09-26T05:00:00Z',true,'ticket','KRW',850000,1);
SQL
ok "A 조 없는 정산 청구는 각자 1명" "$(q "select string_agg(r->>'pax', ',' order by r->>'paid_at') from j, jsonb_array_elements(j->'rows') r where r->>'rest' = '메이노 대관2' or (r->>'ch'='settle' and r->>'gross'='100000')")" "1,1"
ok "B 참고 합계(멤버십)는 기간으로 거른다 — 10월엔 없음 · 9월엔 있음" "$($P -c "select coalesce(public.taam_ticket_sales_report('2026-10-01','2026-11-01','paid',false)->'excluded'->'membership'->>'krw','없음') || '/' || coalesce(public.taam_ticket_sales_report('2026-09-01','2026-10-01','visit',false)->'excluded'->'membership'->>'krw','없음')")" "없음/11250000"
ok "C 취소된 수동 입력 참고도 기간(입력일)으로" "$($P -c "select (public.taam_ticket_sales_report('2026-10-01','2026-11-01','paid',false)->'excluded'->'man_cancelled'->>'n') || '/' || (public.taam_ticket_sales_report('2026-09-01','2026-10-01','paid',false)->'excluded'->'man_cancelled'->>'n')")" "0/1"
ok "F 접두어 없는 옛 앱 행도 앱 구매 · 7월 결제" "$(row tp1_1752000000000 "concat_ws('/', r->>'ch', r->>'pm', r->>'gross', r->>'paid_ymd')")" "app/deposit/1700000/2026-07-10"
ok "G 깨진 memberUid 도 안 깨진다 · 링크 판매" "$(row chg:a0000000-0000-4000-8000-000000000099 "concat_ws('/', r->>'ch', r->>'gross', coalesce(r->>'uid','(없음)'))")" "link/850000/(없음)"
ok "H 방문일 기준 — 방문일 없는 판매는 참고로" "$($P -c "select (public.taam_ticket_sales_report(null,null,'visit',false)->'excluded'->'no_visit_date'->>'n')")" "0"
ok "I 테스트 계정 포함 켜면 보인다" "$($P -c "select count(*) from jsonb_array_elements(public.taam_ticket_sales_report(null,null,'paid',true)->'rows') r where r->>'k'='PAYH-tp2_9'")" "1"

echo "── 적대 리뷰 반영: 회원이 쓸 수 있는 칸으로 금액·상태를 못 바꾼다 ──"
M3=b1000000-0000-4000-8000-000000000004
I4=e4000000-0000-4000-8000-000000000004; I5=e5000000-0000-4000-8000-000000000005; I6=e6000000-0000-4000-8000-000000000006
$P <<SQL >/dev/null
insert into public.profiles values ('$M3','회원3','user',false);
-- R1 위조 홀드: price 5천만 · 취소 · 결제 줄 없음 → 판매 아님 · 조용히
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M3','$R1','tp1','2026.11.03',2,50000000,'cancelled','PAYH-fake_1','{"server_confirmed":true,"confirmed_at":"2026-10-05T00:00:00Z"}','2026-10-05T00:00:00Z');
-- R1b 살아 있는데 돈 기록이 없는 행 → 「확인 필요」
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,created_at)
 values ('$M3','$R1','tp1','2026.11.04',1,850000,'active','PAYH-nomoney','2026-10-06T00:00:00Z');
-- R2 ₩0 환불 줄에 거대한 agency_held · 'returned' → 무시 (실제 판매 PAYH-tp1_1 의 회원 M1 이 씀)
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','general','ticket_refund',0,'{"purchase_id":"PAYH-tp1_1","refund_type":"returned","agency_held":999999999999999}','2026-10-01T00:00:00Z');
-- R3 회원이 extra_data 에 위조한 pax_changes (price_before 거대 · from 거대)
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M3','$R1','tp2','2026.12.01',1,400000,'active','PAYH-forge_3','{"pax_changes":[{"from":"999999999999999","price_before":999999999,"refund":0}]}','2026-10-07T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M3','general','ticket_purchase',-400000,'{"purchase_id":"PAYH-forge_3"}','2026-10-07T00:00:00Z');
-- R6 위약 환불: agency_held 0 · 30% 위약 (1.7M 중 1.19M 환불)
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,created_at)
 values ('$M3','$R1','tp1','2026.11.03',2,1700000,'cancelled','PAYH-pen_6','2026-10-08T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M3','general','ticket_purchase',-1700000,'{"purchase_id":"PAYH-pen_6"}','2026-10-08T00:00:00Z'),
 ('$M3','general','ticket_refund',1190000,'{"purchase_id":"PAYH-pen_6","refund_type":"penalty","agency_held":0}','2026-10-09T00:00:00Z');
-- R7 방문 전에 'returned' 라벨을 단 환불 → 취소로 센다
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,created_at)
 values ('$M3','$R1','tp1','2026.11.03',2,1700000,'cancelled','PAYH-ret_7','2026-10-08T01:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M3','general','ticket_purchase',-1700000,'{"purchase_id":"PAYH-ret_7"}','2026-10-08T01:00:00Z'),
 ('$M3','general','ticket_refund',1400000,'{"purchase_id":"PAYH-ret_7","refund_type":"returned","agency_held":300000}','2026-10-10T00:00:00Z');
-- R8 다른 회원이 같은 purchase_id 로 쓴 결제·환불 줄 → 붙지 않는다
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M2','general','ticket_refund',500000,'{"purchase_id":"PAYH-tp1_1","cancel_refund":true}','2026-10-11T00:00:00Z');
-- R10 카드 통화 칸에 HTML · R11 confirmed_at infinity · R12 같은 order_id 를 두 행이 주장
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,status,approved_at) values ('O12','$M3','ticket_topup',400000,'KRW','paid','2026-10-12T00:00:00Z');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at) values
 ('$M3','$R1','tp2','2026.12.01',1,400000,'active','PAYH-o12_a','{"order_id":"O12","cardPaid":400000,"card_currency":"<img src=x onerror=alert(1)>","confirmed_at":"infinity"}','2026-10-12T00:00:00Z'),
 ('$M3','$R1','tp2','2026.12.02',1,400000,'active','PAYH-o12_b','{"order_id":"O12","cardPaid":400000}','2026-10-12T01:00:00Z');
-- R4 초대: 결제 뒤 자동 되돌림(capacity_auto_refund) · 여전히 paid · INV 행 없음
insert into public.reservation_invites values ('$I4','$SU','$M3','$R1','메이노','2026.11.20','19:00',1,700000,150000,0,850000,'paid','2026-10-01','2026-10-01T01:00:00Z',null,null);
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M3','general','ticket_purchase',-850000,'{"purchase_id":"INV-e4000000-1","invite_id":"$I4"}','2026-10-01T01:00:00Z'),
 ('$M3','general','ticket_refund',850000,'{"purchase_id":"INV-e4000000-1","refund_type":"returned","reason":"capacity_auto_refund"}','2026-10-01T01:00:05Z');
-- R5 초대: paid 인데 원장 결제 줄 없음 (회원이 자기 초대 행을 paid 로 바꿀 수 있다)
insert into public.reservation_invites values ('$I5','$SU','$M3','$R1','메이노','2026.11.21','19:00',1,700000,150000,0,850000,'paid','2026-10-01','2026-10-02T00:00:00Z',null,null);
-- R13 초대: 회원이 대행비를 부풀림(회차 대행비 150k 보다 큰 900k) → 회차 대행비로 깎는다
insert into public.reservation_invites values ('$I6','$SU','$M3','$R1','메이노','2026.11.22','19:00',1,0,900000,0,850000,'paid','2026-10-01','2026-10-03T00:00:00Z',null,'tp1');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values ('$M3','general','ticket_purchase',-850000,'{"purchase_id":"INV-e6000000-1","invite_id":"$I6"}','2026-10-03T00:00:00Z');
-- R9 결제 링크 memberUid: 대시 없는 36자 헥스
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data)
 values ('$SU','$R1','tp1','2026.11.03',1,850000,'active','LINK-r9','{"chargeId":"a0000000-0000-4000-8000-000000000098","memberUid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}');
insert into public.kashikiri_charges(id,event_id,label,amount_krw,status,approved_at,link_invite,purpose,pay_currency,pay_amount,pay_fx,payload)
 values ('a0000000-0000-4000-8000-000000000098','f1000000-0000-4000-8000-000000000001','R9',850000,'paid','2026-10-13T00:00:00Z',true,'ticket','KRW',850000,1,'{"pax":1}');
SQL
ok "보고서가 깨지지 않는다(거대한 숫자 · 깨진 uuid · infinity)" "$($P -c "select (public.taam_ticket_sales_report(null,null,'paid',false)->>'ok')" 2>&1)" "true"
ok "R1 위조 홀드(5천만 · 취소 · 결제 줄 없음)는 행도 예외도 아니다" "$(q "select (select count(*) from jsonb_array_elements(j->'rows') r where r->>'k'='PAYH-fake_1') || '/' || (select count(*) from jsonb_array_elements(j->'exceptions') e where e->>'ref'='PAYH-fake_1') from j")" "0/0"
ok "R1b 살아 있는데 돈 기록 없는 행 → 합계 밖 「확인 필요」" "$(q "select (select count(*) from jsonb_array_elements(j->'rows') r where r->>'k'='PAYH-nomoney') || '/' || (select e->>'kind' from jsonb_array_elements(j->'exceptions') e where e->>'ref'='PAYH-nomoney') from j")" "0/app_no_money_record"
ok "R2 ₩0 환불 줄의 agency_held·returned 는 무시 — PAYH-tp1_1 은 그대로 판매 · 대행비 300k 예정" "$(row PAYH-tp1_1 "concat_ws('/', r->>'st', r->>'net', r->>'agency', r->>'ag_state')")" "active/1700000/300000/planned"
ok "R3 위조 pax_changes — 판매액은 원장(400k) · 거대한 from 은 무시" "$(row PAYH-forge_3 "concat_ws('/', r->>'gross', r->>'net', coalesce(r->>'pax0','-'), r->>'pax')")" "400000/400000/-/1"
ok "R6 위약(agency_held 0) — 대행비는 0 이 아니라 1인 대행비 × 인원(보유 몫 안)" "$(row PAYH-pen_6 "concat_ws('/', r->>'st', r->>'rf_penalty', r->>'net', r->>'agency', r->>'ag_state')")" "penalty/1190000/510000/300000/kept"
ok "R7 방문 전 'returned' 환불은 취소로 — 순판매에서 빠진다" "$(row PAYH-ret_7 "concat_ws('/', r->>'st', r->>'rf_cancel', r->>'rf_return', r->>'net', (r->'flags')::text)")" "cancelled/1400000/0/300000/[\"return_before_visit\"]"
ok "R8 다른 회원의 같은 purchase_id 줄은 붙지 않는다 (PAYH-tp1_1 환불 0)" "$(row PAYH-tp1_1 "r->>'rf_cancel'")" "0"
ok "R10 카드 통화 칸의 HTML 은 KRW 로" "$(row PAYH-o12_a "r->>'cur'")" "KRW"
ok "R11 infinity confirmed_at 은 안 쓴다 — 결제일은 카드 승인일" "$(row PAYH-o12_a "r->>'paid_ymd'")" "2026-10-12"
ok "R12 같은 카드 주문은 한 판매에만 (먼저 만든 행)" "$(q "select string_agg((r->>'k') || '=' || (r->>'gross'), ',' order by r->>'k') from j, jsonb_array_elements(j->'rows') r where r->>'k' like 'PAYH-o12_%'")" "PAYH-o12_a=400000"
ok "R12b 주문을 못 가진 두 번째 행은 「확인 필요」" "$(q "select count(*) from j, jsonb_array_elements(j->'exceptions') e where e->>'ref'='PAYH-o12_b' and e->>'kind'='app_no_money_record'")" "1"
ok "R4 자동 되돌린 초대는 판매 아님 → 「확인 필요」(still paid)" "$(q "select (select count(*) from jsonb_array_elements(j->'rows') r where r->>'k'='inv:$I4') || '/' || (select e->>'kind' from jsonb_array_elements(j->'exceptions') e where e->>'ref'='$I4') from j")" "0/invite_reversed_still_paid"
ok "R5 원장 없는 paid 초대 → 「확인 필요」" "$(q "select (select count(*) from jsonb_array_elements(j->'rows') r where r->>'k'='inv:$I5') || '/' || (select e->>'kind' from jsonb_array_elements(j->'exceptions') e where e->>'ref'='$I5') from j")" "0/invite_paid_no_ledger"
ok "R13 부풀린 초대 대행비는 회차 대행비로 · 판매액은 원장" "$(row "inv:$I6" "concat_ws('/', r->>'gross', r->>'agency', ((r->'flags') ? 'agency_snapshot_differs')::text)")" "850000/150000/true"
ok "R9 대시 없는 36자 memberUid 도 안 깨진다 · 링크 판매" "$(row chg:a0000000-0000-4000-8000-000000000098 "concat_ws('/', r->>'ch', r->>'gross', coalesce(r->>'uid','(없음)'))")" "link/850000/(없음)"
out2=$($P -f "$MIG" 2>&1)
ok "두 번째 RUN: 오류 없음 · ❌ 0 · ⑤ 채널 합계 줄이 찍힌다(이름 없음)" "$(echo "$out2" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '❌')|$( [ $(echo "$out2" | grep -cE '⑤ (app|invite|link|settle)') -ge 4 ] && echo ok)|$(echo "$out2" | grep -c '회원1')" "|0|ok|0"
# 화면 시험용 — TSR_DUMP=파일 이면 보고서 JSON 을 남긴다(결제일·전체 · 기본)
[ -n "$TSR_DUMP" ] && $P -c "select public.taam_ticket_sales_report(null, null, 'paid', false)" > "$TSR_DUMP"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
