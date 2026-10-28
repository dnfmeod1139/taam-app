#!/bin/bash
# 💳 결제 내역 (카드 · 예치금) RPC (supabase/migrations/20261028_payment_ledger.sql) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_payment_ledger.sh
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261028_payment_ledger.sql
FAIL=0
DB=t_payledger; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M1=b1000000-0000-4000-8000-000000000001; M2=b1000000-0000-4000-8000-000000000002; TST=b1000000-0000-4000-8000-000000000003
SU=b1000000-0000-4000-8000-000000000009
R1=c1000000-0000-4000-8000-000000000001
I1=e1000000-0000-4000-8000-000000000001
C1=a0000000-0000-4000-8000-000000000001; C2=a0000000-0000-4000-8000-000000000002; C3=a0000000-0000-4000-8000-000000000003; C4=a0000000-0000-4000-8000-000000000004
EV=f1000000-0000-4000-8000-000000000001
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
create table public.profiles(id uuid primary key, display_name text, role text, is_test boolean default false, phone text, email text, membership_tier text);
create table public.restaurants(id uuid primary key, name text);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, meal_fee int, agency_fee int, wine_min int);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text,
  reservation_date text, visit_time text, party_size int, price bigint, status text, purchase_id text, buyer_name text, extra_data jsonb default '{}', created_at timestamptz default now());
create table public.payment_orders(order_id text primary key, user_id uuid not null, purpose text, amount bigint, currency text default 'KRW', settle_krw bigint, fx_rate numeric(12,4), status text,
  payment_key text, method text, receipt_url text, approved_at timestamptz, fail_reason text, metadata jsonb default '{}', created_at timestamptz default now(), updated_at timestamptz default now());
create table public.billing_keys(id uuid primary key default gen_random_uuid(), user_id uuid, billing_key text, card_number text, card_company text, card_type text);
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint, description text, payment_id uuid, metadata jsonb default '{}', created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key, host_user_id uuid, invitee_user_id uuid, restaurant_id text, restaurant_name text, visit_date text, visit_time text,
  pax int, meal_fee int, agency_fee int, wine_min int, total_amount int, status text, created_at timestamptz default now(), paid_at timestamptz, cancelled_at timestamptz, ticket_product_id text);
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_id text not null, venue_name text, event_date date not null, event_time time, ticket_product_id text, created_at timestamptz default now());
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, guest_id uuid, label text not null, user_id uuid, amount_krw int not null, amount_jpy int, token text, status text not null,
  order_id text, payment_key text, method text, receipt_url text, fail_reason text, payer_name text, approved_at timestamptz, expires_at timestamptz, created_at timestamptz default now(), payer_phone text,
  pay_currency text default 'KRW', pay_amount numeric(14,2), pay_fx numeric(12,4), refund_krw int, refund_amount numeric(14,2), refunded_at timestamptz, cancel_reason text, link_invite boolean default false,
  purpose text default 'custom', title text, subtitle text, payload jsonb default '{}', applied_at timestamptz, applied_note text, created_by uuid);
create table public.kashikiri_charge_admin(charge_id uuid primary key, note text, fail_note text, created_by uuid, created_at timestamptz default now());
create table public.membership_fees(id uuid primary key default gen_random_uuid(), user_id uuid, paid_at date, amount_krw bigint, method text, source text, source_ref text);
SQL
out=$($P -f "$MIG" 2>&1)

$P <<SQL >/dev/null
insert into public.profiles values ('$M1','회원1','user',false,'01011112222','m1@x.kr','M'),('$M2','회원2','user',false,null,null,'T'),('$TST','테스트1','user',true,null,null,null),('$SU','운영','superadmin',false,null,null,null);
insert into public.restaurants values ('$R1','메이노');
insert into public.ticket_products values ('tp1','$R1','메이노','2026.11.03','19:00',600000,150000,100000), ('tp2','$R1','메이노','2026.12.01','12:00',300000,100000,0);
insert into public.billing_keys(id,user_id,billing_key,card_number,card_company,card_type) values ('d0000000-0000-4000-8000-000000000001','$M2','bk','5365********1234','신한','신용');
-- O1 카드+예치금 · 승인 기록(snap)에 secret 칸 · 티켓은 extra_data.order_id 로 · 예치금 두 주머니
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,settle_krw,status,payment_key,method,receipt_url,approved_at,metadata,created_at) values
 ('O1','$M1','ticket_topup',300000,'KRW',300000,'paid','pk_O1','카드','https://dashboard.tosspayments.com/receipt/O1','2026-10-05T01:00:00Z',
  '{"toss":{"mId":"playtauif6","status":"DONE","method":"카드","totalAmount":300000,"balanceAmount":300000,"approvedAt":"2026-10-05T10:00:00+09:00","secret":"ps_SECRET_SHOULD_NOT_LEAK",
    "card":{"issuerCode":"41","acquirerCode":"41","number":"53651234****123*","installmentPlanMonths":0,"approveNo":"00000000","cardType":"신용","ownerType":"개인","acquireStatus":"READY","amount":300000,"isInterestFree":false},
    "receipt":{"url":"https://dashboard.tosspayments.com/receipt/O1"},"cancels":null}}','2026-10-05T00:59:00Z');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.11.03','19:00',1,850000,'active','PAYH-tp1_1','{"cardPaid":300000,"depositUsed":550000,"order_id":"O1","paidBy":"card+deposit"}','2026-10-05T00:58:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','membership','ticket_purchase',-500000,'{"purchase_id":"PAYH-tp1_1","order_id":"O1","portion":"membership"}','2026-10-05T01:00:01Z'),
 ('$M1','general','ticket_purchase',-50000,'{"purchase_id":"PAYH-tp1_1","order_id":"O1","portion":"general"}','2026-10-05T01:00:01Z');
-- O2 자동 취소(좌석 만료) · 홀드 취소 · 예치금 되돌림(card_auto) · 결제 시각 KST 경계(9/30 15:30Z = 10/1 00:30 KST)
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,status,payment_key,method,approved_at,fail_reason,metadata) values
 ('O2','$M1','ticket_topup',200000,'KRW','canceled','pk_O2','간편결제','2026-09-30T15:30:00Z','seat_lost_refunded','{"toss":{"status":"DONE","method":"간편결제","easyPay":{"provider":"토스페이","amount":200000,"discountAmount":0},"cancels":"bad"}}');
insert into public.tickets(user_id,ticket_product_id,party_size,price,status,purchase_id,extra_data) values ('$M1','tp2',1,0,'cancelled','PAYH-tp2_2','{"seatHold":true}');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','general','ticket_purchase',-100000,'{"purchase_id":"PAYH-tp2_2","order_id":"O2"}','2026-09-30T15:30:01Z'),
 ('$M1','general','ticket_refund',100000,'{"purchase_id":"PAYH-tp2_2","order_id":"O2"}','2026-09-30T15:30:02Z');
-- O3 등록 카드(빌링) · 취소 · 카드 환불 대기 + 인원 줄임 대기 · 앱 토스 취소 기록(app_cancels · 처리자 이름) · 깨진 숫자
insert into public.payment_orders(order_id,user_id,purpose,amount,currency,status,payment_key,method,approved_at,metadata) values
 ('O3','$M2','ticket_topup',400000,'KRW','paid','pk_O3','카드','2026-10-10T03:00:00Z',
  '{"paid_via":"billing_key","billing_key_id":"d0000000-0000-4000-8000-000000000001","toss":{"mId":"bill_taam315","status":"PARTIAL_CANCELED","totalAmount":400000,"balanceAmount":300000,"cancels":[{"cancelAmount":100000,"canceledAt":"2026-10-12T10:00:00+09:00","transactionKey":"tx1","cancelReason":"회원 취소","cancelStatus":"DONE"}]},
    "app_cancels":[{"purchase_id":"PAYH-tp2_3","amount":100000,"tx":"tx1","at":"2026-10-12T01:00:00Z","by":"$SU","policy":"d31"}]}');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M2','$R1','tp2','2026.12.01',2,800000,'cancelled','PAYH-tp2_3',
  '{"cardPaid":"abc","depositUsed":400000,"order_id":"O3","server_cancelled_at":"2026-10-12T00:59:00Z","cancel_reason":"회원 취소",
    "card_refund_pending":{"amount":300000,"status":"pending","requested_at":"2026-10-12T00:59:00Z","set_by_role":"member"},
    "card_refund_queue":[{"amount":50000,"status":"pending","reason":"인원 줄임"}]}','2026-10-10T02:59:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M2','general','ticket_purchase',-400000,'{"purchase_id":"PAYH-tp2_3","order_id":"O3"}','2026-10-10T03:00:01Z'),
 ('$M2','general','ticket_refund',300000,'{"purchase_id":"PAYH-tp2_3","cancel_refund":true,"refund_type":"returned","cancelled_by":"member","agency_held":100000}','2026-10-12T01:00:00Z');
-- O4 pending · O5 failed → 빠진다 · O6 테스트 계정 → 기본 제외
insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key) values ('O4','$M1','ticket_topup',1000,'pending',null),('O5','$M1','ticket_topup',1000,'failed','pk_O5');
insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,approved_at) values ('O6','$TST','ticket_topup',1000,'paid','pk_O6','2026-10-15T00:00:00Z');
-- 결제 링크 C1(외화 · 회원 · 좌석 · 부분 환불 · 어드민 메모) · C2(멤버십 · 연회비 기록) · C3(비회원 정산 · 미결제 pending 결제키 없음 → 빠짐) · C4(테스트 회원 링크 → 기본 제외)
insert into public.kashikiri_events(id,venue_id,venue_name,event_date,event_time,ticket_product_id) values ('$EV','$R1','메이노','2026-11-03','19:00','tp1');
insert into public.kashikiri_charges(id,event_id,label,user_id,amount_krw,status,order_id,payment_key,method,receipt_url,payer_name,payer_phone,approved_at,pay_currency,pay_amount,pay_fx,
  refund_krw,refund_amount,refunded_at,cancel_reason,link_invite,purpose,title,payload) values
 ('$C1','$EV','손님A','$M2',2500000,'refunded','KSK-$C1','pk_C1','카드','https://r/C1','Trina','+1 555',  '2026-10-20T00:00:00Z','USD',1860,1344.0860,2200000,1620,'2026-10-22T00:00:00Z','D-31','true','ticket','메이노 2인','{"pax":2,"price_override":true}'),
 ('$C2',null,'연회비','$M1',1125000,'paid','KSK-$C2','pk_C2','카드',null,'회원1',null,'2026-10-21T00:00:00Z','KRW',1125000,1,null,null,null,null,false,'membership','멤버십 M 갱신','{}'),
 ('$C3','$EV','손님C',null,500000,'pending',null,null,null,null,null,null,null,'KRW',500000,1,null,null,null,null,false,'custom',null,'{}'),
 ('$C4',null,'테','$TST',1000,'paid','KSK-$C4','pk_C4','카드',null,'테',null,'2026-10-21T00:00:00Z','KRW',1000,1,null,null,null,null,false,'custom','시험','{}');
insert into public.kashikiri_charge_admin(charge_id,note) values ('$C1','정가 ₩2,700,000 → \$1,860 · 협의');
insert into public.membership_fees(user_id,paid_at,amount_krw,method,source,source_ref) values ('$M1','2026-10-21',1125000,'link','pay_link','$C2');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data) values
 ('$M2','$R1','tp1','2026.11.03',2,1700000,'cancelled','LINK-1','{"chargeId":"$C1","memberUid":"$M2"}');
-- 캐시 (C1 · O1)
insert into public.toss_payment_cache(payment_key,src,ref,mid,info,info_at,settle,settle_at) values
 ('pk_C1','charge','$C1','playtaamusd','{"status":"PARTIAL_CANCELED","totalAmount":1860,"balanceAmount":240,"card":{"issuerCode":"4V","number":"4111********1111"},"cancels":[{"cancelAmount":1620,"canceledAt":"2026-10-22T09:00:00+09:00","transactionKey":"txc1"}],"receiptUrl":"https://r/C1"}','2026-10-28T00:00:00Z',
  '[{"tx":"a1","soldDate":"2026-10-20","paidOutDate":"2026-10-27","amount":1860,"fee":60,"payOutAmount":1800,"cur":"USD"}]','2026-10-28T00:00:00Z'),
 ('pk_O1','order','O1','playtauif6',null,null,'[]','2026-10-28T00:00:00Z');
-- 예치금: 2주머니 결제 + 취소 환불 · 초대 결제 · 관리 차감(연회비) · 정정(fix) · 인원 줄임 · 부여(외화) · 부모 없는 환불 · 테스트
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.11.03',2,1700000,'cancelled','PAYH-tp1_9','{"paidBy":"deposit","deposit_return":{"type":"returned","returnAmt":1400000,"agencyHeld":300000}}','2026-10-02T00:00:00Z');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,description,metadata,created_at) values
 ('$M1','membership','ticket_purchase',-1000000,'메이노 티켓 결제','{"purchase_id":"PAYH-tp1_9"}','2026-10-02T00:00:00Z'),
 ('$M1','general','ticket_purchase',-700000,'메이노 티켓 결제','{"purchase_id":"PAYH-tp1_9"}','2026-10-02T00:00:00Z'),
 ('$M1','general','ticket_purchase',-700000,'이중 차감','{"purchase_id":"PAYH-tp1_9"}','2026-10-02T00:00:01Z'),
 ('$M1','general','ticket_refund',700000,'정정','{"purchase_id":"PAYH-tp1_9","fix":"double_deduct_2026-09-14"}','2026-10-03T00:00:00Z'),
 ('$M1','general','ticket_refund',1400000,'반환','{"purchase_id":"PAYH-tp1_9","refund_type":"returned","agency_held":300000,"processed_by":"super_admin"}','2026-11-04T00:00:00Z'),
 ('$M1','general','ticket_pax_change',200000,'인원 줄임','{"purchase_id":"PAYH-tp1_9","actor_role":"admin"}','2026-10-04T00:00:00Z');
insert into public.reservation_invites values ('$I1','$SU','$M2','$R1','메이노','2026.11.10','19:00',2,450000,100000,50000,1200000,'paid','2026-10-05','2026-10-06T00:00:00Z',null,'tp1');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,description,metadata,created_at) values
 ('$M2','membership','ticket_purchase',-1200000,'초대 결제 (멤버십) · 메이노','{"purchase_id":"INV-e1000000-1","invite_id":"$I1","source":"reservation_invite"}','2026-10-06T00:00:01Z');
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data)
 values ('$M2','$R1','tp1','2026.11.10',2,1200000,'active','INV-e1000000-1','{"inviteId":"$I1"}');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,description,metadata,created_at) values
 ('$M2','membership','admin_deduct',-1125000,'연회비 2년차','{"granted_by_name":"운영","membership_fee":{"amount_krw":1125000}}','2026-10-08T00:00:00Z'),
 ('$M2','membership','admin_grant',8910000,'송금 \$8,910','{"granted_by_name":"운영","fx_currency":"USD","fx_amount":8910,"fx_rate":1300,"fx_base":1340,"fx_margin_pct":3}','2026-10-07T00:00:00Z'),
 ('$M1','general','ticket_refund',5000,'부모 없는 환불','{"purchase_id":"PAYH-nope"}','2026-10-09T00:00:00Z'),
 ('$TST','general','ticket_purchase',-1000,'테스트','{"purchase_id":"PAYH-t"}','2026-10-09T00:00:00Z');
SQL

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1 — 기대 [$3] 실제 [$2]"; FAIL=1; fi; }
has(){ if echo "$2" | grep -q -- "$3"; then echo "✅ $1"; else echo "❌ $1 — [$3] 없음: ${2:0:300}"; FAIL=1; fi; }
J="select public.taam_payment_ledger"
echo "$out" | grep -q "❌" && { echo "❌ 설치 확인 표에 ❌"; echo "$out" | grep "❌"; FAIL=1; } || echo "✅ 설치 확인 표"
echo "$out" | grep -E "^⑥|^⑦|^⑧" | sed 's/^/   /'

# 권한
r=$($P -c "set taam.uid='$M1'; $J(null,null,false);" 2>&1); has "회원 세션 → FORBIDDEN" "$r" "FORBIDDEN"
r=$($P -c "set taam.uid='$SU'; set taam.super='1'; select jsonb_array_length(($J(null,null,false))->'card');" 2>&1 | tail -1); ok "슈퍼어드민 세션 → 카드 줄 5 (O1 O2 O3 · C1 C2)" "$r" "5"
r=$($P -c "$J('2026-10-10','2026-10-01',false);" 2>&1); has "끝 < 시작 → BAD_RANGE" "$r" "BAD_RANGE"
ok "anon 실행 권한 없음" "$($P -c "select has_function_privilege('anon','public.taam_payment_ledger(date,date,boolean)','execute')")" "f"
ok "authenticated 캐시 읽기 권한 없음" "$($P -c "select has_table_privilege('authenticated','public.toss_payment_cache','select')")" "f"

C="with j as ($J(null,null,false) j) select e from j, jsonb_array_elements(j->'card') e"
D="with j as ($J(null,null,false) j) select e from j, jsonb_array_elements(j->'dep') e"
# 카드 A
o1=$($P -c "$C where e->>'k'='o:O1'")
has "O1 티켓 연결(extra_data.order_id) 구매 id" "$o1" '"pid": "PAYH-tp1_1"'
has "O1 예치금 같이 · 멤버십 500000" "$o1" '"dep_mem": 500000'
has "O1 예치금 같이 · 일반 50000" "$o1" '"dep_gen": 50000'
has "O1 승인 기록 카드사 코드" "$o1" '"issuerCode": "41"'
has "O1 매입 상태" "$o1" '"acquireStatus": "READY"'
has "O1 영수증 URL" "$o1" '"receipt": "https://dashboard.tosspayments.com/receipt/O1"'
has "O1 매장·방문" "$o1" '"visit": "2026-11-03"'
has "O1 구매자 연락처" "$o1" '"phone": "01011112222"'
has "O1 캐시 정산 조회됨(빈 배열)" "$o1" '"settle": \[\]'
ok "secret 칸이 보고서에 없다" "$($P -c "select position('SECRET_SHOULD_NOT_LEAK' in ($J(null,null,true))::text)")" "0"
o2=$($P -c "$C where e->>'k'='o:O2'")
has "O2 자동 취소 상태" "$o2" '"st": "canceled"'
has "O2 사유" "$o2" '"fail": "seat_lost_refunded"'
has "O2 원장 주문 줄로 홀드 연결" "$o2" '"pid": "PAYH-tp2_2"'
has "O2 예치금 되돌림 분류 card_auto" "$o2" '"k": "card_auto"'
has "O2 간편결제" "$o2" '"provider": "토스페이"'
o3=$($P -c "$C where e->>'k'='o:O3'")
has "O3 빌링 채널" "$o3" '"ch": "billing"'
has "O3 등록 카드" "$o3" '"company": "신한"'
has "O3 카드 환불 대기" "$o3" '"status": "pending"'
has "O3 인원 줄임 대기" "$o3" '"reason": "인원 줄임"'
has "O3 앱 취소 처리자 이름" "$o3" '"by": "운영"'
has "O3 토스 취소 목록(승인 기록)" "$o3" '"transactionKey": "tx1"'
has "O3 예치금 환불 줄 분류 cancel" "$o3" '"k": "cancel"'
ok "O3 깨진 cardPaid 는 빠진다" "$($P -c "$C where e->>'k'='o:O3' and e ? 'card_paid'" | wc -l)" "0"
ok "O4 pending · O5 failed 없음" "$($P -c "$C where e->>'order_id' in ('O4','O5')" | wc -l)" "0"
ok "O6 테스트 계정 기본 제외" "$($P -c "$C where e->>'order_id'='O6'" | wc -l)" "0"
ok "O6 포함 옵션" "$($P -c "with j as ($J(null,null,true) j) select count(*) from j, jsonb_array_elements(j->'card') e where e->>'order_id'='O6'")" "1"
# 카드 B
c1=$($P -c "$C where e->>'k'='c:$C1'")
has "C1 링크 채널" "$c1" '"ch": "link"'
has "C1 결제 통화 그대로 USD 1860" "$c1" '"amt": 1860'
has "C1 기록된 원화" "$c1" '"krw": 2500000'
has "C1 결제자" "$c1" '"payer": "Trina"'
has "C1 회원" "$c1" '"buyer": "회원2"'
has "C1 환불 외화 1620" "$c1" '"rf_amt": 1620'
has "C1 좌석 행" "$c1" '"pid": "LINK-1"'
has "C1 어드민 메모" "$c1" '"note": "정가'
has "C1 캐시 live" "$c1" '"issuerCode": "4V"'
has "C1 캐시 정산 지급일" "$c1" '"paidOutDate": "2026-10-27"'
has "C1 MID" "$c1" '"mid": "playtaamusd"'
c2=$($P -c "$C where e->>'k'='c:$C2'")
has "C2 멤버십 채널" "$c2" '"ch": "membership"'
has "C2 연회비 기록" "$c2" '"fee_rec": 1125000'
ok "C3 미결제(결제키 없음) 없음" "$($P -c "$C where e->>'k'='c:$C3'" | wc -l)" "0"
ok "C4 테스트 회원 링크 기본 제외" "$($P -c "$C where e->>'k'='c:$C4'" | wc -l)" "0"
# 기간 (KST)
ok "10월(KST) — O2 는 10/1 00:30 KST 라 들어온다" "$($P -c "with j as ($J('2026-10-01','2026-11-01',false) j) select count(*) from j, jsonb_array_elements(j->'card') e where e->>'order_id'='O2'")" "1"
ok "9월(KST) — O2 없음" "$($P -c "with j as ($J('2026-09-01','2026-10-01',false) j) select count(*) from j, jsonb_array_elements(j->'card') e where e->>'order_id'='O2'")" "0"
# 예치금
d9=$($P -c "$D where e->>'k'='p:$M1|PAYH-tp1_9'")
has "예치금 결제 묶음 합계 2,400,000(이중 차감 포함 · 원장 그대로)" "$d9" '"pay": 2400000'
has "멤버십 1,000,000" "$d9" '"mem": 1000000'
has "일반 1,400,000" "$d9" '"gen": 1400000'
has "줄 수 3" "$d9" '"n": 3'
has "정정 분류 fix" "$d9" '"k": "fix"'
has "반환 분류 returned · 대행비 보유" "$d9" '"agency_held": 300000'
has "인원 줄임 분류 pax" "$d9" '"k": "pax"'
has "티켓 반환 기록" "$d9" '"returnAmt": 1400000'
di=$($P -c "$D where e->>'k'='p:$M2|INV-e1000000-1'")
has "초대 종류" "$di" '"kind": "invite"'
has "초대 보낸 사람" "$di" '"inv_host": "운영"'
has "초대 합계" "$di" '"inv_total": 1200000'
has "초대 티켓 연결" "$di" '"tpid": "INV-e1000000-1"'
dd=$($P -c "$D where e->>'kind'='deduct'")
has "관리 차감 연회비 표시" "$dd" '"fee": true'
has "관리 차감 처리자" "$dd" '"by_name": "운영"'
dg=$($P -c "$D where e->>'kind'='grant'")
has "부여(입금) 외화" "$dg" '"fx_amt": 8910'
has "부여 금액" "$dg" '"in": 8910000'
ok "부모 없는 환불은 기타 입금으로" "$($P -c "$D where e->>'kind'='in_other' and e->>'pid'='PAYH-nope'" | wc -l)" "1"
ok "부모 있는 환불은 따로 안 나온다" "$($P -c "$D where e->>'kind'='in_other' and e->>'pid'='PAYH-tp1_9'" | wc -l)" "0"
ok "카드 주문 같이 뺀 예치금 묶음 — 키에 주문번호(주문마다 따로)" "$($P -c "$D where e->>'k'='p:$M1|PAYH-tp1_1|O1' and e->>'order_id'='O1'" | wc -l)" "1"
ok "테스트 계정 예치금 기본 제외" "$($P -c "$D where e->>'uid'='$TST'" | wc -l)" "0"
# ── 리뷰 반영 ──
OA=OA; OB=OB
$P <<SQL >/dev/null
-- 같은 홀드 PAYH-H: OA 예치금 부족 자동 취소(예치금 25만 되돌림) → OB 로 다시 결제 성공(티켓 order_id OB)
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M2','$R1','tp1','2026.11.03',1,850000,'active','PAYH-H','{"order_id":"OB","cardPaid":300000,"depositUsed":550000}','2026-10-16T00:00:00Z');
insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,approved_at,fail_reason,metadata) values
 ('OA','$M2','ticket_topup',300000,'canceled','pk_OA','2026-10-16T01:00:00Z','deposit_short_refunded','{"toss":{"status":"DONE"}}'),
 ('OB','$M2','ticket_topup',300000,'paid','pk_OB','2026-10-16T02:00:00Z',null,'{"toss":{"status":"DONE"}}');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M2','general','ticket_purchase',-250000,'{"purchase_id":"PAYH-H","order_id":"OA"}','2026-10-16T01:00:01Z'),
 ('$M2','general','ticket_refund',250000,'{"purchase_id":"PAYH-H","order_id":"OA"}','2026-10-16T01:00:02Z'),
 ('$M2','general','ticket_purchase',-550000,'{"purchase_id":"PAYH-H","order_id":"OB"}','2026-10-16T02:00:01Z');
-- 대관 정산 청구에 어드민(테스트 계정) uid 가 실림 · 결제자 Trina
insert into public.kashikiri_charges(id,event_id,label,user_id,amount_krw,status,payment_key,payer_name,approved_at,purpose)
 values ('a0000000-0000-4000-8000-000000000009','$EV','조1','$SU',1600000,'paid','pk_C9','Trina2','2026-10-17T00:00:00Z','custom');
update public.profiles set is_test = true where id = '$SU';
-- M1 이 M2 의 초대 id 를 자기 원장 줄에 적었다(−₩1)
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','general','ticket_purchase',-1,'{"purchase_id":"INV-e1000000-1","invite_id":"$I1"}','2026-10-18T00:00:00Z');
SQL
oa=$($P -c "$C where e->>'k'='o:OA'")
ok "자동 취소된 OA 는 OB 의 티켓에 잇지 않는다" "$(echo "$oa" | grep -c '"pid": "PAYH-H"')" "0"
has "OA 는 제 예치금 줄 구매 id 로 환불 줄을 본다(앱이 주문으로 거른다)" "$oa" '"dep_pid": "PAYH-H"'
has "OA 환불 줄에 OA 되돌림" "$oa" '"order_id": "OA"'
ob=$($P -c "$C where e->>'k'='o:OB'")
has "OB 는 PAYH-H 에 잇는다" "$ob" '"pid": "PAYH-H"'
has "OB 티켓 주문" "$ob" '"t_order": "OB"'
ok "예치금 묶음이 주문마다 따로(OA · OB)" "$($P -c "$D where e->>'k' in ('p:$M2|PAYH-H|OA','p:$M2|PAYH-H|OB')" | wc -l)" "2"
c9=$($P -c "$C where e->>'k'='c:a0000000-0000-4000-8000-000000000009'")
ok "정산 청구의 어드민 uid 는 회원으로 안 본다" "$(echo "$c9" | grep -c '"uid"')" "0"
has "정산 청구 결제자 그대로" "$c9" '"payer": "Trina2"'
ok "어드민이 테스트 계정이어도 손님 정산 결제는 숨지 않는다" "$(echo "$c9" | wc -l)" "1"
inj=$($P -c "$D where e->>'k'='p:$M1|INV-e1000000-1'")
ok "남의 초대 id 를 적은 줄 — 그 초대·티켓이 안 붙는다" "$(echo "$inj" | grep -c '"inv_host"\|"tpid"\|"inv_total"')" "0"
# 2차 리뷰: 자동 취소(OA2) 뒤 같은 홀드를 예치금만으로 다시 결제 → 회원 취소 환불(주문 표시 없음)
$P <<SQL >/dev/null
insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at)
 values ('$M1','$R1','tp1','2026.11.03',1,850000,'cancelled','PAYH-A','{"paidBy":"deposit","server_confirmed":true}','2026-10-19T00:00:00Z');
insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,approved_at,fail_reason,metadata) values
 ('OA2','$M1','ticket_topup',300000,'canceled','pk_OA2','2026-10-19T01:00:00Z','deposit_short_refunded','{"toss":{"status":"DONE"}}');
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata,created_at) values
 ('$M1','general','ticket_purchase',-250000,'{"purchase_id":"PAYH-A","order_id":"OA2"}','2026-10-19T01:00:01Z'),
 ('$M1','general','ticket_refund',250000,'{"purchase_id":"PAYH-A","order_id":"OA2"}','2026-10-19T01:00:02Z'),
 ('$M1','general','ticket_purchase',-850000,'{"purchase_id":"PAYH-A"}','2026-10-19T02:00:00Z'),
 ('$M1','general','ticket_refund',700000,'{"purchase_id":"PAYH-A","cancel_refund":true,"refund_type":"returned"}','2026-10-20T00:00:00Z');
SQL
oa2=$($P -c "$C where e->>'k'='o:OA2'")
ok "자동 취소 OA2 — 예치금만으로 다시 결제된 홀드에 잇지 않는다" "$(echo "$oa2" | grep -c '"pid": "PAYH-A"')" "0"
has "OA2 — 같은 구매에 주문 없는 결제 줄 있음(plain)" "$oa2" '"plain": true'
da=$($P -c "$D where e->>'k'='p:$M1|PAYH-A|OA2'")
has "OA2 예치금 묶음 — plain · 주문 상태 canceled" "$da" '"ord_st": "canceled"'
ok "예치금만 다시 낸 묶음은 따로" "$($P -c "$D where e->>'k'='p:$M1|PAYH-A'" | grep -c '"pay": 850000')" "1"
ok "도우미 함수 authenticated 실행 권한 없음" "$($P -c "select has_function_privilege('authenticated','public._taam_pl_toss(jsonb)','execute')")" "f"
# 재실행
out2=$($P -f "$MIG" 2>&1); echo "$out2" | grep -q "❌" && { echo "❌ 재실행 확인 표에 ❌"; FAIL=1; } || echo "✅ 재실행"
ok "재실행 뒤 캐시 그대로" "$($P -c "select count(*) from public.toss_payment_cache")" "2"
[ -n "$PL_KEEP" ] || psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
