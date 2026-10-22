#!/bin/bash
# 초대 결제 보안 가드 (supabase/migrations/20261022_invite_payment_guard.sql) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_invite_guard.sh
#   실제 확정 RPC(20261003_invite_confirm_owner.sql 의 taam_invite_confirm_hold)를 함께 올려 「결제 → 결제됨 → (환불) → 확정」 순서를 그대로 탄다.
cd "$(dirname "$0")/../.."
MIG1=supabase/migrations/20261022_invite_payment_guard.sql   # 1차(라이브) 위에 2차를 올린다
MIG=supabase/migrations/20261022_invite_payment_guard2.sql
CONF=supabase/migrations/20261003_invite_confirm_owner.sql
FAIL=0
DB=t_invguard; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a0000000-0000-4000-8000-000000000001; HOST=a0000000-0000-4000-8000-000000000002; M1=a0000000-0000-4000-8000-000000000011; M2=a0000000-0000-4000-8000-000000000012
I1=c1000000-0000-4000-8000-000000000001; I2=c2000000-0000-4000-8000-000000000002; I3=c3000000-0000-4000-8000-000000000003; I4=c4000000-0000-4000-8000-000000000004; I5=c5000000-0000-4000-8000-000000000005   # 앞 8자리가 달라야 한다(INV-앞8자리 구매 id)
$P <<SQL >/dev/null 2>&1
create schema auth;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, display_name text, role text);
create or replace function public.is_super_admin(p uuid) returns boolean language sql stable as \$\$ select exists (select 1 from public.profiles where id = p and role = 'superadmin') \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select public.is_super_admin(auth.uid()) \$\$;
create table public.ticket_products(id text primary key, rest_id text, type_class text, agency_fee int);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, ticket_type text,
  reservation_date text, visit_time text, party_size int, price int, status text, purchase_id text, buyer_name text, buyer_phone text, extra_data jsonb default '{}', created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key, host_user_id uuid, invitee_user_id uuid, restaurant_id text, restaurant_name text, ticket_genre text, type_class text,
  visit_date text, visit_time text, pax int, meal_fee int, agency_fee int, wine_min int, total_amount int, ticket_desc text, cancel_policy jsonb, status text,
  created_at timestamptz default now(), paid_at timestamptz, cancelled_at timestamptz, paid_ticket_id text, invitee_seen boolean default false, ticket_product_id text);
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount int, metadata jsonb, created_at timestamptz default now());
insert into public.profiles values ('$SU','운영','superadmin'),('$HOST','매장','admin'),('$M1','회원1','user'),('$M2','회원2','user');
insert into public.ticket_products values ('tp1','r1','A',150000);
SQL
# 실제 확정 RPC (본문만 — 아래 수리 쿼리는 빼고)
sed -n '/^create or replace function public.taam_invite_confirm_hold/,/^grant execute on function public.taam_invite_confirm_hold/p' "$CONF" | $P >/dev/null 2>&1
out=$($P -f "$MIG1" 2>&1)$($P -f "$MIG" 2>&1)
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $3, 실제 $2)"; FAIL=1; fi; }
as(){ local u=$1; shift; $P -c "set taam.uid = '$u'; $*" 2>&1 | grep -v '^SET$'; }   # 오류는 여러 줄이라 통째로 — code() 가 코드만 고른다
code(){ echo "$1" | grep -oE "(INVITE_NOT_PAID|INVITE_CLOSED|REFUND_TICKET_ACTIVE)" | head -1; }
newinv(){ $P -c "insert into public.reservation_invites(id,host_user_id,invitee_user_id,restaurant_id,restaurant_name,visit_date,visit_time,pax,meal_fee,agency_fee,wine_min,total_amount,status,ticket_product_id)
  values ('$1','$HOST','$2','r1','메이노','2026.12.01','19:00',2,850000,150000,0,2000000,'sent','tp1');
  insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data)
  values ('$HOST','r1','tp1','2026.12.01','19:00',2,0,'hold','INVH-$(echo $1 | cut -c1-8)-1', jsonb_build_object('inviteHold', true, 'inviteId', '$1'));" >/dev/null; }
pay(){ $P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$2','general','ticket_purchase',-$3, jsonb_build_object('invite_id','$1','purchase_id','INV-$(echo $1 | cut -c1-8)-9'))" >/dev/null; }

echo "${out}" | grep -E "❌|ERROR" && FAIL=1
echo "── A. 초대 행 — 받는 회원은 금액·인원·당사자를 못 바꾼다 ──"
newinv $I1 $M1
as $M1 "update public.reservation_invites set total_amount = 1, pax = 8, agency_fee = 0, meal_fee = 1, invitee_user_id = '$M2', host_user_id = '$M1', ticket_product_id = 'x', visit_date = '2027.01.01', paid_ticket_id = 'INV-x', invitee_seen = true where id = '$I1'" >/dev/null
ok "A1 금액·인원·당사자·회차·paid_ticket_id 는 되돌려지고 invitee_seen 만 바뀐다" "$($P -c "select concat_ws('/', total_amount, pax, agency_fee, meal_fee, invitee_user_id = '$M1', host_user_id = '$HOST', ticket_product_id, visit_date, coalesce(paid_ticket_id,'-'), invitee_seen) from public.reservation_invites where id = '$I1'")" "2000000/2/150000/850000/t/t/tp1/2026.12.01/-/t"
r=$(as $M1 "update public.reservation_invites set status = 'paid', paid_at = now() where id = '$I1'")
ok "A2 결제 없이 「결제됨」 → INVITE_NOT_PAID" "$(code "$r")" "INVITE_NOT_PAID"
pay $I1 $M1 1999999
r=$(as $M1 "update public.reservation_invites set status = 'paid', paid_at = now() where id = '$I1'")
ok "A3 1원 모자란 결제 → INVITE_NOT_PAID" "$(code "$r")" "INVITE_NOT_PAID"
pay $I1 $M1 1
as $M1 "update public.reservation_invites set status = 'paid', paid_at = now(), total_amount = 5 where id = '$I1'" >/dev/null
ok "A4 전액(두 줄 합) 결제 뒤 「결제됨」 OK · 같은 UPDATE 의 금액 변경은 되돌림" "$($P -c "select status || '/' || total_amount || '/' || (paid_at is not null) from public.reservation_invites where id = '$I1'")" "paid/2000000/true"
as $M1 "update public.reservation_invites set status = 'sent', paid_at = null where id = '$I1'" >/dev/null
ok "A5 riPay 되돌림(결제됨 → 보냄 · paid_at 비움)은 된다" "$($P -c "select status || '/' || (paid_at is null) from public.reservation_invites where id = '$I1'")" "sent/true"
newinv $I2 $M1
as $M1 "update public.reservation_invites set status = 'cancelled', cancelled_at = now() where id = '$I2'" >/dev/null
ok "A6 받은 초대 취소는 된다" "$($P -c "select status from public.reservation_invites where id = '$I2'")" "cancelled"
r=$(as $M1 "update public.reservation_invites set status = 'sent' where id = '$I2'")
ok "A7 취소된 초대를 되살리면 INVITE_CLOSED" "$(code "$r")" "INVITE_CLOSED"
as $HOST "update public.reservation_invites set status = 'sent', total_amount = 2100000 where id = '$I2'" >/dev/null
ok "A8 보낸 사람(host)은 그대로 고친다" "$($P -c "select status || '/' || total_amount from public.reservation_invites where id = '$I2'")" "sent/2100000"
as $SU "update public.reservation_invites set total_amount = 2200000 where id = '$I2'" >/dev/null
$P -c "update public.reservation_invites set pax = 3 where id = '$I2'" >/dev/null
ok "A9 슈퍼어드민·서버(auth.uid 없음)도 그대로" "$($P -c "select total_amount || '/' || pax from public.reservation_invites where id = '$I2'")" "2200000/3"
r=$(as $M2 "update public.reservation_invites set total_amount = 1 where id = '$I2'")
ok "A10 남의 초대(RLS 가 먼저 막는다 · 트리거는 받는 회원만 본다) — 이 픽스처는 RLS 없이 갱신되므로 값만 확인" "$($P -c "select total_amount from public.reservation_invites where id = '$I2'")" "1"
$P -c "update public.reservation_invites set total_amount = 2200000 where id = '$I2'" >/dev/null

echo "── B. 확정 — 실제 taam_invite_confirm_hold ──"
newinv $I3 $M1
pay $I3 $M1 2000000
as $M1 "update public.reservation_invites set status = 'paid', paid_at = now() where id = '$I3'" >/dev/null
r=$(as $M1 "select (public.taam_invite_confirm_hold('$I3', 'INV-$(echo $I3 | cut -c1-8)-9')->>'ok')")
ok "B1 정상: 결제 → 결제됨 → 확정 (홀드가 회원 소유 active 로)" "$r|$($P -c "select status || '/' || (user_id = '$M1') || '/' || price from public.tickets where extra_data->>'inviteId' = '$I3'")" "true|active/true/2000000"
newinv $I4 $M1
pay $I4 $M1 2000000
as $M1 "update public.reservation_invites set status = 'paid', paid_at = now() where id = '$I4'" >/dev/null
r=$(as $M1 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M1','general','ticket_refund',2000000,'{\"purchase_id\":\"INV-$(echo $I4 | cut -c1-8)-9\"}')")
ok "B2 확정 전(티켓 행 없음) 회원 환불은 된다 — riPay 확정 실패 되돌림 길" "$($P -c "select count(*) from public.deposit_transactions where user_id = '$M1' and change_type = 'ticket_refund' and metadata->>'purchase_id' like 'INV-$(echo $I4 | cut -c1-8)%'")" "1"
r=$(as $M1 "select public.taam_invite_confirm_hold('$I4', 'INV-$(echo $I4 | cut -c1-8)-9')")
ok "B3 결제 → 결제됨 → 스스로 환불 → 확정 = INVITE_NOT_PAID (좌석은 홀드 그대로)" "$(code "$r")|$($P -c "select status from public.tickets where extra_data->>'inviteId' = '$I4'")" "INVITE_NOT_PAID|hold"
newinv $I5 $M1
$P -c "update public.reservation_invites set status = 'paid' where id = '$I5'" >/dev/null   # (옛 데이터처럼) 서버가 paid 로 둔 결제 없는 초대
r=$(as $M1 "select public.taam_invite_confirm_hold('$I5', 'INV-$(echo $I5 | cut -c1-8)-9')")
ok "B4 결제 없이 paid 인 옛 초대도 회원 확정은 막힌다" "$(code "$r")" "INVITE_NOT_PAID"
r=$(as $SU "select (public.taam_invite_confirm_hold('$I5', 'INV-$(echo $I5 | cut -c1-8)-9')->>'ok')")
ok "B5 슈퍼어드민의 확정은 그대로 (수동 처리)" "$r" "true"
r=$(as $M1 "insert into public.tickets(user_id,status,purchase_id,extra_data,price) values ('$M1','active','PAYH-x_1','{}',1000)")
ok "B6 초대가 아닌 회원 행은 B 가드와 무관" "$($P -c "select count(*) from public.tickets where purchase_id = 'PAYH-x_1'")" "1"

echo "── C. 살아 있는 티켓의 회원 환불 ──"
$P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_purchase',-900000,'{\"purchase_id\":\"PAYH-c_1\"}');
       insert into public.tickets(user_id,status,purchase_id,price,party_size) values ('$M2','active','PAYH-c_1',900000,1)" >/dev/null
r=$(as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',900000,'{\"purchase_id\":\"PAYH-c_1\"}')")
ok "C1 티켓이 살아 있는데 회원이 스스로 환불 → REFUND_TICKET_ACTIVE" "$(code "$r")" "REFUND_TICKET_ACTIVE"
as $M2 "update public.tickets set status = 'cancelled' where purchase_id = 'PAYH-c_1'" >/dev/null
r=$(as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',900000,'{\"purchase_id\":\"PAYH-c_1\"}')")
ok "C2 앱 순서(먼저 취소 → 환불)는 된다" "$($P -c "select count(*) from public.deposit_transactions where user_id = '$M2' and change_type = 'ticket_refund'")" "1"
$P -c "insert into public.tickets(user_id,status,purchase_id,price,party_size) values ('$M2','hold','PAYH-c_2',0,1),('$M2','active','PAYH-c_3',100,1)" >/dev/null
r=$(as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',1,'{\"purchase_id\":\"PAYH-c_2\"}')")
ok "C3 홀드(결제 전 좌석)는 막지 않는다" "$($P -c "select count(*) from public.deposit_transactions where metadata->>'purchase_id' = 'PAYH-c_2'")" "1"
as $SU "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',50,'{\"purchase_id\":\"PAYH-c_3\",\"refund_type\":\"returned\"}')" >/dev/null
$P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',10,'{\"purchase_id\":\"PAYH-c_3\"}')" >/dev/null
ok "C4 슈퍼어드민(방문 후 반환)·서버(Edge·SQL Editor)는 살아 있는 티켓도 환불한다" "$($P -c "select count(*) from public.deposit_transactions where metadata->>'purchase_id' = 'PAYH-c_3'")" "2"
as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_purchase',-100,'{\"purchase_id\":\"PAYH-c_3\"}')" >/dev/null
ok "C5 결제(음수) 줄은 C 가드와 무관" "$($P -c "select count(*) from public.deposit_transactions where metadata->>'purchase_id' = 'PAYH-c_3' and amount < 0")" "1"


echo "── 2차: 결제 한 줄은 한 초대에만 · 확정은 그 좌석 구매 id 의 결제로 · 살아 있는 초대 좌석의 결제는 환불 불가 ──"
I6=c6000000-0000-4000-8000-000000000006; I7=c7000000-0000-4000-8000-000000000007; I8=c8000000-0000-4000-8000-000000000008
newinv $I6 $M2; newinv $I7 $M2
# invite_id=I6 · purchase_id 는 I7 앞자리 — 한 줄로 두 초대를 노린다
$P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_purchase',-2000000, jsonb_build_object('invite_id','$I6','purchase_id','INV-c7000000-5'))" >/dev/null
as $M2 "update public.reservation_invites set status = 'paid' where id = '$I6'" >/dev/null
r=$(as $M2 "update public.reservation_invites set status = 'paid' where id = '$I7'")
ok "G1 invite_id 가 있는 결제는 그 초대에만 — 다른 초대(앞자리만 맞음)는 INVITE_NOT_PAID" "$(code "$r")|$($P -c "select status from public.reservation_invites where id = '$I6'")" "INVITE_NOT_PAID|paid"
newinv $I8 $M2
$P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_purchase',-2000000, jsonb_build_object('invite_id','$I8','purchase_id','INV-c8000000-1'))" >/dev/null
as $M2 "update public.reservation_invites set status = 'paid' where id = '$I8'" >/dev/null
r=$(as $M2 "select public.taam_invite_confirm_hold('$I8', 'INV-c8000000-2')")
ok "G2 P1 으로 내고 P2 로 확정 → INVITE_NOT_PAID (좌석은 홀드 그대로)" "$(code "$r")|$($P -c "select status from public.tickets where extra_data->>'inviteId' = '$I8'")" "INVITE_NOT_PAID|hold"
r=$(as $M2 "select (public.taam_invite_confirm_hold('$I8', 'INV-c8000000-1')->>'ok')")
ok "G3 같은 구매 id(P1)로 확정은 된다 (riPay 정상 경로)" "$r|$($P -c "select status || '/' || purchase_id from public.tickets where extra_data->>'inviteId' = '$I8'")" "true|active/INV-c8000000-1"
r=$(as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',2000000, jsonb_build_object('purchase_id','INV-c8000000-1'))")
ok "G4 살아 있는 초대 좌석의 결제 환불 → REFUND_TICKET_ACTIVE" "$(code "$r")" "REFUND_TICKET_ACTIVE"
r=$(as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',2000000, jsonb_build_object('purchase_id','INV-zzz','invite_id','$I8'))")
ok "G5 invite_id 만 맞춰 다른 구매 id 로 환불해도 막힌다" "$(code "$r")" "REFUND_TICKET_ACTIVE"
# 좌석을 다른 구매 id 로 살려 둔 모양(1차의 구멍) — 서버가 확정해 둔 P2 좌석 + P1 결제 → P1 환불
I9=c9000000-0000-4000-8000-000000000009
newinv $I9 $M2
$P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_purchase',-2000000, jsonb_build_object('invite_id','$I9','purchase_id','INV-c9000000-1'));
       update public.tickets set status = 'active', purchase_id = 'INV-c9000000-2', user_id = '$M2' where extra_data->>'inviteId' = '$I9'" >/dev/null
r=$(as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',2000000, jsonb_build_object('purchase_id','INV-c9000000-1'))")
ok "G6 결제 P1 · 좌석 P2 로 살아 있으면 P1 환불도 막힌다 (1차 구멍)" "$(code "$r")" "REFUND_TICKET_ACTIVE"
$P -c "update public.tickets set status = 'cancelled' where extra_data->>'inviteId' = '$I9'" >/dev/null
r=$(as $M2 "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','general','ticket_refund',2000000, jsonb_build_object('purchase_id','INV-c9000000-1'))")
ok "G7 좌석을 취소한 뒤 환불은 된다" "$($P -c "select count(*) from public.deposit_transactions where metadata->>'purchase_id' = 'INV-c9000000-1' and change_type = 'ticket_refund'")" "1"
echo "── 재실행 · 확인 표 ──"
out2=$($P -f "$MIG" 2>&1)
ok "두 번째 RUN 오류 없음 · ❌ 0 · ⑤⑥ 정보 줄" "$(echo "$out2" | grep -cE "^ERROR|psql:.*ERROR")|$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep -cE "⑤|⑥")" "0|0|2"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
