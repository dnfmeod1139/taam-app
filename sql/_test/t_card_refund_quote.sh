#!/bin/bash
# 카드 결제분 환불 견적·결제 사실 칸 보호 (supabase/migrations/20261022_card_refund_quote.sql) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_card_refund_quote.sh
cd "$(dirname "$0")/../.."
MIG1=supabase/migrations/20261022_card_refund_quote.sql   # 1차(라이브) 위에 2차
MIG=supabase/migrations/20261022_card_refund_quote2.sql
FAIL=0
DB=t_crquote; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a0000000-0000-4000-8000-000000000001; M1=a0000000-0000-4000-8000-000000000011; RA=a0000000-0000-4000-8000-000000000021
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
          if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if; end \$\$;
create schema auth;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, role text);
create or replace function public.is_super_admin(p uuid) returns boolean language sql stable as \$\$ select exists (select 1 from public.profiles where id = p and role = 'superadmin') \$\$;
create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable as \$\$
begin if auth.uid() is not null then return public.is_super_admin(auth.uid()); end if; return session_user = 'postgres'; end \$\$;
create or replace function public._taam_sr_int(p text) returns bigint language sql immutable as \$\$ select case when p ~ '^\s*-?\d{1,12}(\.\d+)?\s*$' then round(p::numeric)::bigint end \$\$;
create or replace function public._taam_sr_ts(p text) returns timestamptz language plpgsql stable as \$\$ begin if p is null or btrim(p) = '' then return null; end if; return p::timestamptz; exception when others then return null; end \$\$;
create or replace function public._taam_pu_visit_date(p_text text) returns date language plpgsql immutable as \$\$
declare m text[]; begin m := regexp_match(btrim(coalesce(p_text,'')), '^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})'); if m is null then return null; end if; return make_date(m[1]::int, m[2]::int, m[3]::int); exception when others then return null; end \$\$;
create table public.ticket_products(id text primary key, date text, agency_fee int, meal_fee int default 700000, wine_min int default 0, time text default '19:00');
create or replace function public.taam_ticket_price_krw(p_id text, p_pax int) returns bigint language sql stable as \$\$ select ((coalesce(meal_fee,0)+coalesce(agency_fee,0)+coalesce(wine_min,0))*p_pax)::bigint from public.ticket_products where id = p_id \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, ticket_product_id text, reservation_date text, visit_time text, party_size int, price int, status text, purchase_id text, restaurant_name text, extra_data jsonb default '{}', created_at timestamptz default now());
create table public.payment_orders(order_id text primary key, user_id uuid, status text, amount bigint, currency text default 'KRW', payment_key text, approved_at timestamptz, created_at timestamptz default now(), metadata jsonb default '{}');
create table public.deposit_transactions(user_id uuid, change_type text, amount int, metadata jsonb, created_at timestamptz default now());
insert into public.profiles values ('$SU','superadmin'),('$M1','user'),('$RA','admin');
SQL
out=$($P -f "$MIG1" 2>&1)
# 1차 시절의 옛 대기(2차가 채운다): 회원 대기 · 슈퍼어드민 대기
$P -c "insert into public.ticket_products(id,date,agency_fee) values ('tp_old','2027.09.20',100000);
  insert into public.tickets(user_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data,created_at) values
   ('$M1','tp_old','2027.09.20',1,800000,'cancelled','PAYH-old_m', jsonb_build_object('card_refund_pending', jsonb_build_object('amount',125000,'status','pending','requested_at','2026-10-20T01:00:00Z')), '2026-10-20T00:50:00Z'),
   ('$M1','tp_old','2027.09.20',1,800000,'cancelled','PAYH-old_s', jsonb_build_object('super_admin_processed_at','2026-10-20T02:00:00Z','super_admin_processed_by','$SU',
      'card_refund_pending', jsonb_build_object('amount',300000,'status','pending','requested_at','2026-10-20T02:00:00Z')), '2026-10-01T00:00:00Z')" >/dev/null
out=$($P -f "$MIG" 2>&1)
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $3, 실제 $2)"; FAIL=1; fi; }
as(){ local u=$1; shift; $P -c "set taam.uid = '$u'; $*" 2>&1 | grep -v '^SET$'; }
Q(){ $P -c "select public.taam_card_refund_quote('$1')->>'$2'"; }
D(){ date -u -d "$1" +%Y.%m.%d; }
echo "$out" | grep -E "❌|ERROR" && FAIL=1
# 구매 하나 만들기: $1 구매 id · $2 방문일 · $3 결제(카드 승인) 몇 분 전 · 예치금 675,000 + 카드 125,000 = 800,000 · 2명 · 대행비 100,000/인
mk(){ $P -c "insert into public.ticket_products values ('tp_$1', '$2', 100000) on conflict do nothing;
  insert into public.tickets(user_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,restaurant_name,extra_data)
    values ('$M1','tp_$1','$2',2,800000,'active','$1','타케야마치', jsonb_build_object('order_id','O_$1','cardPaid',125000,'depositUsed',675000,'paidBy','card+deposit'));
  insert into public.payment_orders values ('O_$1','$M1','paid',125000,'KRW','pk_$1', now() - interval '$3 minutes', now(), jsonb_build_object('hold_purchase_id','$1','total',800000,'agency_fee',100000,'pax',2));
  insert into public.deposit_transactions values ('$M1','ticket_purchase',-675000, jsonb_build_object('purchase_id','$1'), now() - interval '$3 minutes');" >/dev/null; }
cancel_member(){ as $M1 "update public.tickets set status = 'cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount', $2, 'order_id', '$3', 'status', 'pending')) where purchase_id = '$1'" >/dev/null; }

echo "── A. 결제 사실 칸 보호 ──"
mk PAYH-a 2027.09.20 5
cancel_member PAYH-a 125000 O_PAYH-a
ok "A1 취소하는 그 갱신에서는 대기를 적는다 · set_by_role member · 서버 취소 시각" "$($P -c "select (extra_data->'card_refund_pending'->>'amount') || '/' || (extra_data->'card_refund_pending'->>'set_by_role') || '/' || (extra_data ? 'server_cancelled_at') from public.tickets where purchase_id='PAYH-a'")" "125000/member/true"
as $M1 "update public.tickets set extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount', 1700000, 'order_id', 'O_other', 'status', 'pending'), 'order_id', 'O_other', 'cardPaid', 9999999, 'server_cancelled_at', '2026-01-01') where purchase_id = 'PAYH-a'" >/dev/null
ok "A2 취소 뒤 회원이 대기 금액·주문번호·cardPaid·서버 취소 시각을 고치면 되돌린다" "$($P -c "select (extra_data->'card_refund_pending'->>'amount') || '/' || (extra_data->>'order_id') || '/' || (extra_data->>'cardPaid') || '/' || (extra_data->>'server_cancelled_at' <> '2026-01-01') from public.tickets where purchase_id='PAYH-a'")" "125000/O_PAYH-a/125000/true"
$P -c "update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_pending,status}', '\"done\"') where purchase_id='PAYH-a'" >/dev/null
as $M1 "update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_pending,status}', '\"pending\"') where purchase_id = 'PAYH-a'" >/dev/null
ok "A3 완료(done)를 회원이 대기로 되돌리지 못한다" "$($P -c "select extra_data->'card_refund_pending'->>'status' from public.tickets where purchase_id='PAYH-a'")" "done"
as $M1 "update public.tickets set extra_data = extra_data || '{\"memo\":\"x\"}' where purchase_id = 'PAYH-a'" >/dev/null
ok "A4 보호 칸 밖의 extra_data 는 그대로 쓸 수 있다" "$($P -c "select extra_data->>'memo' from public.tickets where purchase_id='PAYH-a'")" "x"

echo "── B. 견적 — 회원 규정으로 카드 몫 ──"
mk PAYH-b 2027.09.20 5
cancel_member PAYH-b 125000 O_PAYH-b
ok "B1 결제 30분 안 취소 → 전액 800,000 − 예치금 675,000 = 카드 125,000" "$(Q PAYH-b policy)/$(Q PAYH-b card_cap)/$(Q PAYH-b target)" "full_30min/125000/125000"
mk PAYH-c 2027.09.20 5
cancel_member PAYH-c 1700000 O_other
ok "B2 취소 때 금액을 부풀려 적어도(1,700,000 · 다른 주문) 목표는 서버 카드 몫 125,000 · 주문은 이 구매의 것" "$(Q PAYH-c target)/$(Q PAYH-c order_id)/$(Q PAYH-c crp_order_id)" "125000/O_PAYH-c/O_other"
mk PAYH-d "$(D '+60 days')" 90
cancel_member PAYH-d 125000 O_PAYH-d
ok "B3 30분 지나 방문 60일 전 취소 → D-31 · 800,000 − 대행비 200,000 = 600,000 → 예치금 675,000 먼저 → 카드 0" "$(Q PAYH-d policy)/$(Q PAYH-d refundable)/$(Q PAYH-d card_cap)/$(Q PAYH-d target)" "d31/600000/0/0"
mk PAYH-e "$(D '+10 days')" 90
cancel_member PAYH-e 125000 O_PAYH-e
ok "B4 방문 10일 전 취소 → 규정상 0" "$(Q PAYH-e policy)/$(Q PAYH-e target)" "none/0"
mk PAYH-f "$(D '+10 days')" 90
as $SU "update public.tickets set status = 'cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount', 125000, 'order_id', 'O_PAYH-f', 'status', 'pending')) where purchase_id = 'PAYH-f'" >/dev/null
ok "B5 슈퍼어드민이 적은 대기(특별 환불)는 그 금액(카드 결제액 이하)" "$(Q PAYH-f set_by_role)/$(Q PAYH-f target)" "superadmin/125000"
mk PAYC-g 2027.09.20 5
$P -c "update public.payment_orders set metadata = (metadata - 'hold_purchase_id') || jsonb_build_object('ticket_id','tp_PAYC-g') where order_id = 'O_PAYC-g'" >/dev/null
cancel_member PAYC-g 125000 O_PAYC-g
ok "B6 홀드 없이 만든 주문(PAYC- 폴백 행) — 서버가 적은 order_id 로 찾는다" "$(Q PAYC-g order_id)/$(Q PAYC-g target)" "O_PAYC-g/125000"
mk PAYH-h 2027.09.20 5
$P -c "update public.payment_orders set metadata = jsonb_set(metadata, '{hold_purchase_id}', '\"PAYH-zzz\"') where order_id = 'O_PAYH-h'" >/dev/null
cancel_member PAYH-h 125000 O_PAYH-h
ok "B7 다른 구매에 묶인 주문은 쓰지 않는다 → no_order_for_purchase" "$(Q PAYH-h error)" "no_order_for_purchase"
mk PAYH-i 2027.09.20 5
ok "B8 좌석이 살아 있으면(대기도 없음) 거절" "$(Q PAYH-i error)" "not_pending"
ok "B9 회원·매장 어드민 세션은 FORBIDDEN" "$(as $M1 "select public.taam_card_refund_quote('PAYH-b')" | grep -c FORBIDDEN)/$(as $RA "select public.taam_card_refund_quote('PAYH-b')" | grep -c FORBIDDEN)" "1/1"
ok "B10 슈퍼어드민 세션은 본다" "$(as $SU "select public.taam_card_refund_quote('PAYH-b')->>'target'")" "125000"


echo "── C. 2차 — 만들 때 · 방문일 · 주문 회차 · 확정 금액 하한 · 옛 대기 ──"
$P -c "insert into public.ticket_products(id,date,agency_fee,time) values ('tp_c','2027.09.20',100000,'18:00')" >/dev/null
as $M1 "insert into public.tickets(user_id,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values ('$M1','tp_c','2099.12.31','23:00',2,0,'hold','PAYH-c1',
   jsonb_build_object('seatHold',true,'order_id','O_X','cardPaid',9999999,'card_refund_pending', jsonb_build_object('amount',1700000,'set_by_role','superadmin','status','pending')))" >/dev/null
ok "C1 회원 홀드 INSERT — 결제 사실 칸(order_id·cardPaid·대기)은 지우고 방문일·시간은 회차 값" "$($P -c "select concat_ws('/', extra_data ? 'order_id', extra_data ? 'cardPaid', extra_data ? 'card_refund_pending', extra_data ? 'seatHold', reservation_date, visit_time) from public.tickets where purchase_id='PAYH-c1'")" "f/f/f/t/2027.09.20/18:00"
# PAYC 폴백 공격: 살아 있는 PAYC 행이 O_X(홀드 없는 주문)를 쓴다 → 가짜 홀드에 O_X 를 몰래 실어도 지워진다 · 서버가 만든 가짜 PAYC 라도 다른 살아 있는 티켓이 쓰면 거절
$P -c "insert into public.tickets(user_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data) values ('$M1','tp_c','2027.09.20',2,1700000,'active','PAYC-tp_c_1', jsonb_build_object('order_id','O_X'));
       insert into public.payment_orders values ('O_X','$M1','paid',1700000,'KRW','pk_X', now() - interval '5 minutes', now(), jsonb_build_object('ticket_id','tp_c','total',1700000,'pax',2));
       insert into public.tickets(user_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data) values ('$M1','tp_c','2027.09.20',2,1700000,'active','PAYC-tp_c_2', jsonb_build_object('order_id','O_X'))" >/dev/null
as $M1 "update public.tickets set status='cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount',1700000,'status','pending')) where purchase_id in ('PAYH-c1','PAYC-tp_c_2')" >/dev/null
ok "C2 가짜 홀드(주문번호 지워짐) → no_order_for_purchase" "$(Q PAYH-c1 error)" "no_order_for_purchase"
ok "C3 같은 주문을 쓰는 다른 살아 있는 티켓이 있으면 PAYC 폴백 거절" "$(Q PAYC-tp_c_2 error)" "no_order_for_purchase"
mk PAYH-m 2027.09.20 5
$P -c "update public.payment_orders set metadata = jsonb_set(metadata, '{ticket_id}', '\"tp_other\"') where order_id = 'O_PAYH-m'" >/dev/null
cancel_member PAYH-m 125000 O_PAYH-m
ok "C4 주문의 회차가 이 티켓 회차와 다르면 order_ticket_mismatch" "$(Q PAYH-m error)" "order_ticket_mismatch"
mk PAYH-v "$(D '+10 days')" 90
$P -c "update public.tickets set reservation_date = '2099.12.31' where purchase_id = 'PAYH-v'" >/dev/null
cancel_member PAYH-v 125000 O_PAYH-v
ok "C5 티켓 방문일을 멀리 적어도 회차 날짜(10일 뒤)로 판정 → 규정 0" "$(Q PAYH-v policy)/$(Q PAYH-v target)" "none/0"
$P -c "update public.payment_orders set metadata = metadata || jsonb_build_object('app_cancels', jsonb_build_array(jsonb_build_object('purchase_id','PAYH-b','amount',100000), jsonb_build_object('purchase_id','PAYH-zz','amount',5000))) where order_id = 'O_PAYH-b'" >/dev/null
ok "C6 이 구매에 앱이 한 취소 · 주문 전체" "$(Q PAYH-b done_for_purchase)/$(Q PAYH-b app_cancelled_order)" "100000/105000"
$P -c "insert into public.tickets(user_id,ticket_product_id,party_size,price,status,purchase_id,extra_data) values ('$M1','tp_c',2,500000,'hold','PAYH-f1','{}'),('$M1','tp_c',2,1600000,'hold','PAYH-f2','{}'),('$M1','tp_c',2,10,'hold','PAYH-f3','{\"card_currency\":\"USD\"}')" >/dev/null
r1=$($P -c "update public.tickets set status='active' where purchase_id='PAYH-f1'" 2>&1); r2=$($P -c "update public.tickets set status='active', price=1600000 where purchase_id='PAYH-f2'" 2>&1); r3=$($P -c "update public.tickets set status='active' where purchase_id='PAYH-f3'" 2>&1)
ok "C7 홀드 확정 금액 < 회차 정가×인원(1,600,000) → PRICE_BELOW_TICKET · 정가는 통과 · 외화는 제외" "$(echo "$r1" | grep -c PRICE_BELOW_TICKET)/$($P -c "select string_agg(status, ',' order by purchase_id) from public.tickets where purchase_id in ('PAYH-f1','PAYH-f2','PAYH-f3')")" "1/hold,active,active"
ok "C8 옛 회원 대기 → member · 서버 취소 시각 = 요청 시각" "$($P -c "select (extra_data->'card_refund_pending'->>'set_by_role') || '/' || left(extra_data->>'server_cancelled_at', 16) from public.tickets where purchase_id='PAYH-old_m'")" "member/2026-10-20T01:00"
ok "C9 옛 슈퍼어드민 대기(처리자가 실제 슈퍼어드민) → superadmin" "$($P -c "select extra_data->'card_refund_pending'->>'set_by_role' from public.tickets where purchase_id='PAYH-old_s'")" "superadmin"
echo "── 배포 전 2차 리뷰: 인원 줄임 뒤 취소 ──"
VD60=$(D '+60 days')
# C10 전액 카드 2인 ₩1,600,000 → 슈퍼어드민 인원 줄임 2→1(₩700,000 카드 환불 · price 900,000) → 회원이 대기를 99,999,999 로 적어 취소
$P -c "insert into public.ticket_products values ('tp_p1', '$VD60', 100000) on conflict do nothing;
  insert into public.tickets(user_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,restaurant_name,extra_data)
    values ('$M1','tp_p1','$VD60',2,1600000,'active','PAYH-p1','타케야마치', jsonb_build_object('order_id','O_p1','cardPaid',1600000,'depositUsed',0,'paidBy','card+deposit'));
  insert into public.payment_orders values ('O_p1','$M1','paid',1600000,'KRW','pk_p1', now() - interval '3 hours', now(), jsonb_build_object('hold_purchase_id','PAYH-p1','total',1600000,'agency_fee',100000,'pax',2));
  update public.tickets set party_size = 1, price = 900000, extra_data = extra_data || jsonb_build_object('card_refund_queue', jsonb_build_array(jsonb_build_object('amount', 700000, 'status', 'pending'))) where purchase_id = 'PAYH-p1'" >/dev/null
cancel_member PAYH-p1 99999999 O_p1
ok "C10 인원 줄임 뒤(전액 카드): 총액 = 지금 금액 900,000 · 인원 1 · 인원 줄임 카드 몫 700,000 · 상한·목표 800,000 (처음 금액으로 부풀지 않는다)" "$(Q PAYH-p1 total)/$(Q PAYH-p1 pax_card)/$(Q PAYH-p1 card_cap)/$(Q PAYH-p1 target)" "900000/700000/800000/800000"
# C11 섞음: 카드 1,000,000 + 예치금 600,000 → 인원 줄임 ₩700,000(예치금 600,000 원장 + 카드 100,000) · price 900,000
$P -c "insert into public.ticket_products values ('tp_p2', '$VD60', 100000) on conflict do nothing;
  insert into public.tickets(user_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,restaurant_name,extra_data)
    values ('$M1','tp_p2','$VD60',1,900000,'active','PAYH-p2','타케야마치', jsonb_build_object('order_id','O_p2','cardPaid',1000000,'depositUsed',600000,'paidBy','card+deposit'));
  insert into public.payment_orders values ('O_p2','$M1','paid',1000000,'KRW','pk_p2', now() - interval '3 hours', now(), jsonb_build_object('hold_purchase_id','PAYH-p2','total',1600000,'agency_fee',100000,'pax',2));
  insert into public.deposit_transactions values ('$M1','ticket_purchase',-600000, jsonb_build_object('purchase_id','PAYH-p2'), now() - interval '3 hours'),
                                                ('$M1','ticket_pax_change',600000, jsonb_build_object('purchase_id','PAYH-p2'), now() - interval '2 hours')" >/dev/null
cancel_member PAYH-p2 99999999 O_p2
ok "C11 인원 줄임 뒤(섞음): 예치금 몫 600,000(원장) · 카드 몫 100,000 · 남은 예치금 0 → 목표 800,000" "$(Q PAYH-p2 pax_dep)/$(Q PAYH-p2 pax_card)/$(Q PAYH-p2 dep_paid)/$(Q PAYH-p2 target)" "600000/100000/0/800000"
# C12 슈퍼어드민이 적은 대기라도 인원 줄임으로 이미 돌려준 카드 몫은 넘지 못한다 (카드 1,600,000 − 700,000)
$P -c "update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_pending}', jsonb_build_object('amount', 2000000, 'status', 'pending', 'set_by_role', 'superadmin')) where purchase_id = 'PAYH-p1'" >/dev/null
ok "C12 슈퍼어드민 대기 2,000,000 → 목표 = 카드 − 인원 줄임 카드 몫 = 900,000" "$(Q PAYH-p1 target)" "900000"
# C13 인원 줄임이 없으면 pax_card 0 · 회원이 card_refund_queue 를 부풀려도 견적은 그 칸을 안 본다
as $M1 "update public.tickets set extra_data = extra_data || jsonb_build_object('card_refund_queue', jsonb_build_array(jsonb_build_object('amount', 9999999))) where purchase_id = 'PAYH-b'" >/dev/null
ok "C13 인원 줄임 없음 → pax_card 0 (회원이 적은 card_refund_queue 는 무시)" "$(Q PAYH-b pax_card)" "0"
out2=$($P -f "$MIG" 2>&1)
ok "재실행 오류 없음 · ❌ 0" "$(echo "$out2" | grep -cE "^ERROR|psql:.*ERROR")|$(echo "$out2" | grep -c '❌')" "0|0"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
