#!/bin/bash
# 카드 승인 뒤 확정 실패 — 예치금 되돌림 서버 함수 · 가드 · 정리 (supabase/migrations/20261116_card_order_settle.sql) · 로컬 postgres(/tmp 소켓).
#   실행: bash sql/_test/t_card_order_settle.sh   (DB 이름: TAAM_TEST_DB, 기본 tcos_settle)
#   원장 RPC 는 라이브 본문(sql/_test/fx_live_ledger_2026-11-13.sql · md5 36230be0…), 원장 가드는 라이브 본문(fx_live_ledger_guards_2026-11-16.sql)을 올린다.
#   확인: ① 원장 근거 계산 ② 멱등 ③ 상한(서버 기록 card_dep · p_cap) ④ 위조 줄 ⑤ 옛 되돌림 ⑥ 0 ⑦ 권한 ⑧ 동시 호출 ⑨ 늦게 커밋된 차감 ⑩ 재실행
#         2026-11-16 적대 리뷰: ⑪ CF-1 위조 차감 줄로 잔액 두 배 ⑫ CF-2 실패 길 이중 환불 ⑬ CF-2 성공 길(처리 중 회원 환불 막음) ⑭ 정상 회원 환불은 지난다
#         ⑮ 인자·홀드·티켓 거절 ⑯ 같은 홀드 두 주문 ⑰ 다른 주머니 환불 ⑱ PAYMENT_PENDING ⑲ 주문 보기(peek) ⑳ 정리 목록·킥
#         2차 검증: ㉑ N1 같은 홀드를 다른 결제가 같이 쓴 통(예치금 단독 확정) — 이 주문 몫까지만 · 이 주문 주머니로 ㉒ N4 처리 중 카드 주문이 있어도
#                   그 주문이 뺀 몫 밖의 회원 환불은 지난다(묶음은 위조 환불 줄로 못 푼다) ㉓ N5 정리 목록 물러서기(시도 기록 · 알림 보낸 것 뒤로)
cd "$(dirname "$0")/../.."
MIG=${TAAM_SETTLE_MIG:-supabase/migrations/20261116_card_order_settle.sql}
FAIL=0
DB=${TAAM_TEST_DB:-tcos_settle}
psql -h /tmp -U postgres -d postgres -q -X -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -X -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At -X"
U1=a0000000-0000-4000-8000-000000000011; U2=a0000000-0000-4000-8000-000000000012; SU=a0000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
          if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if; end \$\$;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
insert into auth.users values ('$U1'),('$U2'),('$SU');
create table public.profiles(id uuid primary key, display_name text, role text, phone text,
  membership_deposit_balance bigint default 0, general_deposit_balance bigint default 0, deposit_balance bigint default 0);
insert into public.profiles(id, display_name, role, membership_deposit_balance, general_deposit_balance) values
  ('$U1','회원1','user',0,0),('$U2','회원2','user',0,0),('$SU','운영','superadmin',0,0);
create table public.ticket_products(id text primary key, agency_fee int default 0);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, purchase_id text, party_size int, reservation_date text, price int,
  ticket_product_id text, status text, extra_data jsonb default '{}', created_at timestamptz default now());
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint,
  description text, payment_id uuid, metadata jsonb default '{}', created_at timestamptz default now());
create table public.payment_orders(order_id text primary key, user_id uuid not null, purpose text not null default 'deposit_charge', amount bigint not null,
  currency text not null default 'KRW', settle_krw bigint, status text not null default 'pending', payment_key text, fail_reason text, approved_at timestamptz,
  metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
grant usage on schema public, auth to authenticated, anon, service_role;
grant select on all tables in schema public to authenticated;
SQL
LOADERR="$($P -f sql/_test/fx_live_ledger_2026-11-13.sql 2>&1 | grep ERROR | head -3)$($P -f sql/_test/fx_live_ledger_guards_2026-11-16.sql 2>&1 | grep ERROR | head -3)$($P -f $MIG 2>&1 | grep -E 'ERROR' | head -3)"
[ -n "$LOADERR" ] && { echo "LOAD FAIL: $LOADERR"; exit 1; }
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 [$2], 실제 [$3])"; FAIL=1; fi; }
has(){ if echo "$3" | grep -q -- "$2"; then echo "✅ $1"; else echo "❌ $1  (기대 포함 [$2], 실제 [$3])"; FAIL=1; fi; }

ok "원장 RPC = 라이브 본문(md5 36230be0…)" 36230be09e2560b57c7dd871a9acbe48 "$($P -c "select md5(prosrc) from pg_proc where oid='public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)'::regprocedure")"
ok "마이그레이션 확인 표에 ❌ 없음" "0" "$($P -f $MIG 2>/dev/null | grep -c '❌')"

# 시드 — Edge deductDeposit 과 같은 모양(서버 호출 · metadata {purchase_id, ticket_id, order_id, portion})으로 차감
seed(){ $P <<SQL >/dev/null
delete from public.deposit_transactions; delete from public.payment_orders; delete from public.tickets;
update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 0;
update public.profiles set membership_deposit_balance = 400000, general_deposit_balance = 500000 where id = '$U1';
update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 300000 where id = '$U2';
insert into public.payment_orders(order_id, user_id, purpose, amount, status, metadata) values
  ('O1', '$U1', 'ticket_topup', 400000, 'paid', '{"toss":{"status":"DONE"}}'),                       -- toss-confirm 옛 모양: 승인 뒤 metadata 를 덮었다(deposit_used·홀드 없음)
  ('O2', '$U2', 'ticket_topup', 100000, 'paid', '{"deposit_used":200000,"hold_purchase_id":"PAYH-2"}'), -- toss-billing-charge: metadata 를 합쳤다
  ('O3', '$U1', 'deposit_charge', 1000, 'paid', '{}'),
  ('O4', '$U1', 'ticket_topup', 1000, 'paid', '{}');
SQL
}
deduct(){ # $1 user $2 order $3 mem $4 gen [$5 purchase id]
  local pid=${5:-PAYH-1}
  $P -c "select public.taam_apply_deposit_delta('$1', -$3, -$4, (select jsonb_agg(e) from (
    select jsonb_build_object('deposit_type','membership','change_type','ticket_purchase','amount',-$3,'description','차감',
           'metadata', jsonb_build_object('purchase_id','$pid','order_id','$2','portion','membership')) e where $3 > 0
    union all
    select jsonb_build_object('deposit_type','general','change_type','ticket_purchase','amount',-$4,'description','차감',
           'metadata', jsonb_build_object('purchase_id','$pid','order_id','$2','portion','general')) where $4 > 0) z))" >/dev/null
}
bal(){ $P -c "select membership_deposit_balance||'/'||general_deposit_balance from public.profiles where id='$1'"; }
settle(){ $P -c "select public.taam_card_order_settle('$2', '$1', ${3:-null}, '${4:-PAYH-1}', 'repurchase_blocked', null)" 2>&1; }
# 회원 세션으로 원장 RPC 한 줄(양수 = 환불 · 음수 = 차감)
member(){ # $1 user $2 pocket $3 amount $4 metadata json
  local m=0 g=0; if [ "$2" = membership ]; then m=$3; else g=$3; fi
  $P -c "begin; set local taam.uid='$1'; set local role authenticated;
    select public.taam_apply_deposit_delta('$1', $m, $g, jsonb_build_array(jsonb_build_object('deposit_type','$2','change_type', case when $3 > 0 then 'ticket_refund' else 'ticket_purchase' end,'amount',$3,'metadata','$4'::jsonb)))->>'gen'; commit;" 2>&1
}
J(){ echo "$1" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('$2'))" 2>/dev/null; }

# ① 기본 — 멤버십 400,000 + 일반 200,000 빠짐 → 되돌림 같은 주머니로
seed; deduct $U1 O1 400000 200000
ok "차감 뒤 잔액" "0/300000" "$(bal $U1)"
R=$(settle $U1 O1 600000)
ok "① 되돌림 멤버십 400,000" "400000" "$(J "$R" refunded_mem)"
ok "① 되돌림 일반 200,000" "200000" "$(J "$R" refunded_gen)"
ok "① 잔액 원상복구" "400000/500000" "$(bal $U1)"
ok "① 원장 줄: ticket_refund 2줄 · metadata order_id · purchase_id · card_fail_code" "2|2" "$($P -c "select count(*)||'|'||count(*) filter (where metadata->>'card_fail_code'='repurchase_blocked' and metadata->>'order_id'='O1' and metadata->>'purchase_id'='PAYH-1') from public.deposit_transactions where change_type='ticket_refund' and user_id='$U1'")"
ok "① 되돌림 줄에 판매현황 분류 키(reason·fix·refund_type·cancel_refund) 없음" "0" "$($P -c "select count(*) from public.deposit_transactions where change_type='ticket_refund' and (metadata ? 'reason' or metadata ? 'fix' or metadata ? 'refund_type' or metadata ? 'cancel_refund')")"
# ② 멱등
R=$(settle $U1 O1 600000)
ok "② 두 번째 호출 — 되돌림 0" "0|0" "$(J "$R" refunded_mem)|$(J "$R" refunded_gen)"
ok "② 잔액 그대로(두 번 안 돌려줌)" "400000/500000" "$(bal $U1)"
# ③ 상한 — p_cap 없이 주문 metadata.deposit_used(O2) · 서버 기록 card_dep
seed; deduct $U2 O2 0 200000 PAYH-2
R=$(settle $U2 O2 null PAYH-2)
ok "③ 상한 = 주문 metadata.deposit_used(200,000) · 되돌림 200,000" "200000" "$(J "$R" refunded_gen)"
ok "③ 잔액 복구" "0/300000" "$(bal $U2)"
seed; deduct $U1 O1 400000 200000
$P -c "update public.payment_orders set metadata = metadata || '{\"card_dep\":{\"hold\":\"PAYH-1\",\"plan\":600000,\"state\":\"taken\",\"taken\":300000}}' where order_id='O1'" >/dev/null
R=$(settle $U1 O1 600000)
ok "③ 서버 기록(card_dep.taken 300,000)이 p_cap(600,000)보다 작으면 그만큼만" "300000" "$(J "$R" owed_before)"
seed; deduct $U1 O1 400000 200000
$P -c "update public.payment_orders set metadata = metadata || '{\"card_dep\":{\"hold\":\"PAYH-1\",\"plan\":600000,\"state\":\"none\",\"taken\":0}}' where order_id='O1'" >/dev/null
R=$(settle $U1 O1 600000)
ok "③ 서버 기록이 「안 뺐다(none)」면 0" "0" "$(J "$R" owed_before)"
seed; deduct $U1 O1 400000 200000
$P -c "update public.payment_orders set metadata = metadata || '{\"card_dep\":{\"hold\":\"PAYH-1\",\"plan\":600000,\"state\":\"deducting\"}}' where order_id='O1'" >/dev/null
R=$(settle $U1 O1)
ok "③ 차감 결과 모름(deducting) · p_cap 없음 → 상한 = plan 600,000" "600000" "$(J "$R" owed_before)"
# ④ 위조 줄 — 회원이 이 주문 번호를 단 「차감」 줄(다른 구매 id 또는 구매 id 없음)을 써도 통(홀드 구매 id)에 안 들어온다
seed; deduct $U1 O1 400000 200000
$P -c "update public.profiles set general_deposit_balance = general_deposit_balance + 100000 where id='$U1'" >/dev/null
R4=$(member $U1 general -100000 '{"order_id":"O1","server_caller":"service_role"}')
FORGED=$($P -c "select count(*) from public.deposit_transactions where user_id='$U1' and amount=-100000")
R=$(settle $U1 O1 600000)
ok "④ 위조 줄은 세지 않음 — 되돌림은 Edge 가 뺀 600,000" "600000" "$(( $(J "$R" refunded_mem) + $(J "$R" refunded_gen) ))"
[ "$FORGED" = "1" ] && echo "  (위조 줄이 실제로 들어갔다 — 통에 안 들어와 무시됐다)"
R=$(settle $U1 O1 600000)
ok "④ 다시 불러도 0" "0" "$(( $(J "$R" refunded_mem) + $(J "$R" refunded_gen) ))"
# ⑤ 부분 되돌림이 이미 있었다(옛 Edge refundDeposit 줄 모양 {order_id, purchase_id}) — 남은 것만
seed; deduct $U1 O1 400000 200000
$P -c "select public.taam_apply_deposit_delta('$U1', 400000, 0, '[{\"deposit_type\":\"membership\",\"change_type\":\"ticket_refund\",\"amount\":400000,\"description\":\"좌석 만료 취소 · 예치금 환원\",\"metadata\":{\"order_id\":\"O1\",\"purchase_id\":\"PAYH-1\"}}]'::jsonb)" >/dev/null
R=$(settle $U1 O1 600000)
ok "⑤ 옛 되돌림 뒤 남은 일반 200,000 만" "0|200000" "$(J "$R" refunded_mem)|$(J "$R" refunded_gen)"
ok "⑤ 잔액" "400000/500000" "$(bal $U1)"
# ⑥ 차감이 없었다 — 0
seed
R=$(settle $U1 O1 600000)
ok "⑥ 빠진 것이 없으면 0 · ok" "True|0" "$(J "$R" ok)|$(J "$R" owed_before)"
# ⑦ 권한
seed; deduct $U1 O1 400000 200000
ok "⑦ 회원 세션 — FORBIDDEN(또는 권한 없음)" "1" "$($P -c "begin; set local taam.uid='$U1'; set local role authenticated; select public.taam_card_order_settle('O1','$U1',600000,'PAYH-1','x',null); commit;" 2>&1 | grep -c -E 'FORBIDDEN|permission denied')"
ok "⑦ 슈퍼어드민 세션도 거절" "1" "$($P -c "begin; set local taam.uid='$SU'; set local role authenticated; select public.taam_card_order_settle('O1','$U1',600000,'PAYH-1','x',null); commit;" 2>&1 | grep -c -E 'FORBIDDEN|permission denied')"
ok "⑦ anon 거절" "1" "$($P -c "begin; set local role anon; select public.taam_card_order_settle('O1','$U1',600000,'PAYH-1','x',null); commit;" 2>&1 | grep -c -E 'FORBIDDEN|permission denied')"
ok "⑦ service_role(JWT role) 통과" "600000" "$($P -c "begin; set local role service_role; set local request.jwt.claims = '{\"role\":\"service_role\"}'; select (public.taam_card_order_settle('O1','$U1',600000,'PAYH-1','x',null)->>'owed_before'); commit;" 2>&1 | grep -E '^[0-9]+$')"
ok "⑦ 남의 주문 — ORDER_FORBIDDEN" "1" "$(settle $U2 O1 600000 | grep -c ORDER_FORBIDDEN)"
ok "⑦ 다른 용도 주문 — SETTLE_BAD_PURPOSE" "1" "$(settle $U1 O3 1000 | grep -c SETTLE_BAD_PURPOSE)"
ok "⑦ 없는 주문 — ORDER_NOT_FOUND" "1" "$(settle $U1 NOPE 1000 | grep -c ORDER_NOT_FOUND)"
# ⑧ 동시 호출 — 잔액 줄 잠금으로 직렬화(두 세션이 같이 불러도 한 번만)
seed; deduct $U1 O1 400000 200000
( $P -c "begin; select public.taam_card_order_settle('O1','$U1',600000,'PAYH-1','x',null); select pg_sleep(1.5); commit;" >/dev/null 2>&1 ) &
sleep 0.4
$P -c "select public.taam_card_order_settle('O1','$U1',600000,'PAYH-1','x',null)" >/dev/null 2>&1
wait
ok "⑧ 겹친 두 호출 — 되돌림은 한 번(원장 환불 합 600,000)" "600000" "$($P -c "select coalesce(sum(amount),0) from public.deposit_transactions where user_id='$U1' and change_type='ticket_refund'")"
ok "⑧ 잔액" "400000/500000" "$(bal $U1)"
# ⑨ 늦게 커밋된 차감 — 차감 트랜잭션이 잔액 줄을 잡고 있는 동안 되돌림을 부르면, 차감이 끝날 때까지 기다렸다가 그 줄까지 센다
seed
( $P -c "begin; select public.taam_apply_deposit_delta('$U1', -400000, -200000, '[{\"deposit_type\":\"membership\",\"change_type\":\"ticket_purchase\",\"amount\":-400000,\"metadata\":{\"order_id\":\"O1\",\"purchase_id\":\"PAYH-1\"}},{\"deposit_type\":\"general\",\"change_type\":\"ticket_purchase\",\"amount\":-200000,\"metadata\":{\"order_id\":\"O1\",\"purchase_id\":\"PAYH-1\"}}]'::jsonb); select pg_sleep(1.5); commit;" >/dev/null 2>&1 ) &
sleep 0.4
R=$(settle $U1 O1 600000)
wait
ok "⑨ 진행 중이던 차감까지 되돌림(600,000)" "600000" "$(J "$R" owed_before)"
ok "⑨ 잔액 원상복구" "400000/500000" "$(bal $U1)"
# ⑩ 재실행 — 마이그레이션 두 번
ok "⑩ 마이그레이션 재실행 오류 없음" "0" "$($P -f $MIG 2>&1 | grep -c ERROR)"

# ⑪ CF-1 — 회원이 결제창을 연 채 자기 원장에 −10,000,000(order_id O9 · purchase_id FAKE-1) → deposit_short 정리 → FAKE-1 로 한 번 더 환불(두 배)
seed
$P -c "update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 10000000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,metadata) values ('O9','$U1','ticket_topup',500000,'pending','{\"deposit_used\":10000000,\"hold_purchase_id\":\"PAYH-9\",\"total\":10500000}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status) values ('$U1','PAYH-9',2,0,'T9','hold')" >/dev/null
member $U1 general -10000000 '{"order_id":"O9","purchase_id":"FAKE-1"}' >/dev/null
ok "⑪ 위조 차감 뒤 잔액 0" "0/0" "$(bal $U1)"
R=$(settle $U1 O9 10000000 PAYH-9)
ok "⑪ 정리가 위조 줄(FAKE-1)을 홀드 구매 id 로 돌려주지 않음" "0" "$(J "$R" owed_before)"
member $U1 general 10000000 '{"purchase_id":"FAKE-1"}' >/dev/null
ok "⑪ 회원 자기 환불(FAKE-1) 뒤에도 시작 잔액 그대로(두 배 아님)" "0/10000000" "$(bal $U1)"
# ⑫ CF-2 실패 길 — Edge 차감 뒤(티켓 hold) 회원이 홀드 구매 id 로 스스로 환불 → 정리는 그 환불까지 세어 다시 주지 않는다
seed
$P -c "update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 10000000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,metadata) values ('O9','$U1','ticket_topup',500000,'pending','{\"deposit_used\":10000000,\"hold_purchase_id\":\"PAYH-9\",\"total\":10500000}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status) values ('$U1','PAYH-9',2,0,'T9','hold')" >/dev/null
deduct $U1 O9 0 10000000 PAYH-9
R=$(member $U1 general 10000000 '{"purchase_id":"PAYH-9"}')
ok "⑫ (주문 pending — 가드 밖) 회원 자기 환불은 지난다" "10000000" "$(echo "$R" | grep -E '^[0-9]+$')"
R=$(settle $U1 O9 10000000 PAYH-9)
ok "⑫ 정리는 0 — 같은 통에 이미 돌아갔다" "0" "$(J "$R" owed_before)"
ok "⑫ 잔액 = 시작(두 번 안 줌)" "0/10000000" "$(bal $U1)"
# ⑬ CF-2 성공 길 — Edge 가 잡은 주문(paid · unknown:converting) · 차감 뒤 회원이 홀드 구매 id 로 스스로 환불 → 거절
seed
$P -c "update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 10000000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,fail_reason,metadata) values ('O9','$U1','ticket_topup',500000,'paid','unknown:converting:abc123','{\"toss\":{},\"claim_nonce\":\"abc123\",\"card_dep\":{\"hold\":\"PAYH-9\",\"plan\":10000000,\"state\":\"taken\",\"taken\":10000000}}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status) values ('$U1','PAYH-9',2,0,'T9','hold')" >/dev/null
deduct $U1 O9 0 10000000 PAYH-9
has "⑬ 처리 중 카드 주문의 홀드 환불 — REFUND_CARD_PENDING" "REFUND_CARD_PENDING" "$(member $U1 general 10000000 '{"purchase_id":"PAYH-9"}')"
ok "⑬ 잔액 그대로(환불 안 됨)" "0/0" "$(bal $U1)"
$P -c "update public.payment_orders set fail_reason = null where order_id='O9'" >/dev/null
has "⑬ 옛 Edge 모양(paid · 표시 없음 · 티켓 아직 hold)도 거절" "REFUND_CARD_PENDING" "$(member $U1 general 10000000 '{"purchase_id":"PAYH-9"}')"
# 전환 성공 → 티켓 active(order_id O9) → 살아 있는 티켓이라 환불 거절(라이브 refund_active) → 회원이 취소하면 환불 지난다
$P -c "update public.tickets set status='active', price=10500000, extra_data = jsonb_build_object('order_id','O9','cardPaid',500000,'depositUsed',10000000,'paidBy','card+deposit') where purchase_id='PAYH-9'" >/dev/null
has "⑬ 확정 뒤 — 살아 있는 티켓 환불 거절(REFUND_TICKET_ACTIVE)" "REFUND_TICKET_ACTIVE" "$(member $U1 general 10000000 '{"purchase_id":"PAYH-9"}')"
$P -c "update public.tickets set status='cancelled' where purchase_id='PAYH-9'" >/dev/null
ok "⑬ 회원이 취소한 뒤 환불은 지난다(정상 경로)" "10000000" "$(member $U1 general 10000000 '{"purchase_id":"PAYH-9"}' | grep -E '^[0-9]+$')"
$P -c "update public.tickets set status='hold', extra_data='{}' where purchase_id='PAYH-9'; update public.payment_orders set fail_reason='unknown:converting:abc123' where order_id='O9'" >/dev/null
SAREF='[{"deposit_type":"general","change_type":"ticket_refund","amount":1000,"metadata":{"purchase_id":"PAYH-9"}}]'
ok "⑬ 슈퍼어드민 세션 환불은 가드 밖" "1" "$($P -c "begin; set local taam.uid='$SU'; set local role authenticated; select public.taam_apply_deposit_delta('$U1', 0, 1000, '$SAREF'::jsonb) is not null; commit;" 2>&1 | grep -c '^t$')"
ok "⑬ 서버(Edge 정리) 환불은 가드 밖" "1" "$($P -c "select public.taam_apply_deposit_delta('$U1', 0, 1000, '$SAREF'::jsonb) is not null" 2>&1 | grep -c '^t$')"
# ⑭ 정상 회원 환불 — 결제창을 열었다 닫은(pending) 주문이 같은 홀드를 적어 두었고, 예치금만으로 산 뒤 취소
seed
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,metadata) values ('O7','$U1','ticket_topup',100000,'pending','{\"deposit_used\":500000,\"hold_purchase_id\":\"PAYH-7\"}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status) values ('$U1','PAYH-7',2,500000,'T7','cancelled')" >/dev/null
deduct $U1 '' 0 500000 PAYH-7
ok "⑭ 버려진 pending 카드 주문은 회원 환불을 막지 않음" "500000" "$(member $U1 general 500000 '{"purchase_id":"PAYH-7"}' | grep -E '^[0-9]+$')"
# ⑮ 거절 — 홀드 구매 id 없음 · 다른 홀드 · 상한 근거 없음 · 이 주문의 살아 있는 티켓
seed; deduct $U1 O1 400000 200000
has "⑮ 홀드 구매 id 없음 → SETTLE_BAD_ARGS" "SETTLE_BAD_ARGS" "$($P -c "select public.taam_card_order_settle('O1','$U1',600000,null,'x',null)" 2>&1)"
has "⑮ 주문 홀드와 다른 구매 id → SETTLE_HOLD_MISMATCH" "SETTLE_HOLD_MISMATCH" "$(settle $U2 O2 200000 PAYH-1)"
has "⑮ 상한 근거 없음(p_cap 없음 · 서버 기록 없음) → SETTLE_NO_CAP" "SETTLE_NO_CAP" "$(settle $U1 O1)"
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status,extra_data) values ('$U1','PAYH-1',2,1000000,'T1','active','{\"order_id\":\"O1\"}')" >/dev/null
has "⑮ 이 주문으로 확정된 살아 있는 티켓 → SETTLE_TICKET_LIVE" "SETTLE_TICKET_LIVE" "$(settle $U1 O1 600000)"
ok "⑮ 거절 뒤 잔액 그대로" "0/300000" "$(bal $U1)"
# ⑯ 같은 홀드로 두 주문이 차감(앞 주문은 이미 정리됨) — 뒤 주문은 자기 몫만
seed
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,metadata) values ('O8','$U1','ticket_topup',1,'canceled','{\"hold_purchase_id\":\"PAYH-1\",\"deposit_used\":600000}'),('O9','$U1','ticket_topup',1,'paid','{\"hold_purchase_id\":\"PAYH-1\",\"deposit_used\":600000}')" >/dev/null
deduct $U1 O8 400000 200000
R=$(settle $U1 O8 600000); ok "⑯ 앞 주문 정리 600,000" "600000" "$(J "$R" owed_before)"
deduct $U1 O9 400000 200000
R=$(settle $U1 O9 600000); ok "⑯ 뒤 주문 정리 600,000" "600000" "$(J "$R" owed_before)"
R=$(settle $U1 O8 600000); ok "⑯ 앞 주문 다시 — 0(이미 돌려줌)" "0" "$(J "$R" owed_before)"
ok "⑯ 잔액 원상복구" "400000/500000" "$(bal $U1)"
# ⑰ 다른 주머니로 받은 회원 환불 — 합계로 센다(멤버십 600,000 빠짐 · 회원이 일반으로 100,000 환불 → 정리 500,000)
seed
$P -c "update public.profiles set membership_deposit_balance = 600000, general_deposit_balance = 0 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,metadata) values ('O9','$U1','ticket_topup',1,'pending','{\"hold_purchase_id\":\"PAYH-1\",\"deposit_used\":600000}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status) values ('$U1','PAYH-1',2,0,'T1','hold')" >/dev/null
deduct $U1 O9 600000 0
member $U1 general 100000 '{"purchase_id":"PAYH-1"}' >/dev/null
R=$(settle $U1 O9 600000)
ok "⑰ 정리 500,000(멤버십)" "500000|0" "$(J "$R" refunded_mem)|$(J "$R" refunded_gen)"
ok "⑰ 합계 원상복구(600,000)" "500000/100000" "$(bal $U1)"
# ⑱ PAYMENT_PENDING — 결과 모르는 카드 주문이 있으면 같은 홀드(또는 승인된 같은 회차)로 새 카드 주문을 못 만든다
seed
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,fail_reason,metadata) values ('A1','$U1','ticket_topup',1,'pending','unknown:toss_billing_NETWORK_ERROR','{\"hold_purchase_id\":\"PAYH-1\",\"ticket_id\":\"T1\"}')" >/dev/null
has "⑱ 같은 홀드 → PAYMENT_PENDING" "PAYMENT_PENDING" "$($P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,metadata) values ('B1','$U1','ticket_topup',1,'{\"hold_purchase_id\":\"PAYH-1\",\"ticket_id\":\"T1\"}')" 2>&1)"
ok "⑱ 다른 홀드(pending 앞 주문) → 만든다" "" "$($P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,metadata) values ('B2','$U1','ticket_topup',1,'{\"hold_purchase_id\":\"PAYH-2\",\"ticket_id\":\"T1\"}')" 2>&1)"
$P -c "update public.payment_orders set status='paid', fail_reason='unknown:converting:x', metadata='{\"toss\":{},\"card_dep\":{\"hold\":\"PAYH-1\",\"tid\":\"T1\"}}' where order_id='A1'" >/dev/null
has "⑱ 승인된(paid) 같은 회차 주문 결과 모름 → 새 홀드여도 PAYMENT_PENDING(card_dep 로 찾음)" "PAYMENT_PENDING" "$($P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,metadata) values ('B3','$U1','ticket_topup',1,'{\"hold_purchase_id\":\"PAYH-3\",\"ticket_id\":\"T1\"}')" 2>&1)"
ok "⑱ 다른 회원 · 다른 용도는 상관없음" "" "$($P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,metadata) values ('B4','$U2','ticket_topup',1,'{\"hold_purchase_id\":\"PAYH-1\",\"ticket_id\":\"T1\"}'),('B5','$U1','invite_topup',1,'{\"hold_purchase_id\":\"PAYH-1\"}')" 2>&1)"
$P -c "update public.payment_orders set created_at = now() - interval '2 hours' where order_id='A1'" >/dev/null
ok "⑱ 60분 지난 결과 모름 주문은 막지 않음(정리 크론이 본다)" "" "$($P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,metadata) values ('B6','$U1','ticket_topup',1,'{\"hold_purchase_id\":\"PAYH-1\",\"ticket_id\":\"T1\"}')" 2>&1)"
$P -c "update public.payment_orders set created_at = now(), fail_reason='repurchase_blocked_refunded', status='canceled' where order_id='A1'" >/dev/null
ok "⑱ 결과가 난 주문은 막지 않음" "" "$($P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,metadata) values ('B7','$U1','ticket_topup',1,'{\"hold_purchase_id\":\"PAYH-1\",\"ticket_id\":\"T1\"}')" 2>&1)"
# ⑲ 주문 보기(peek) — 슈퍼어드민만
seed
$P -c "update public.payment_orders set status='pending', fail_reason='unknown:approving', payment_key='pk_abcdefgh12345678', metadata='{\"hold_purchase_id\":\"PAYH-1\",\"restaurant_name\":\"미토우\"}' where order_id='O4'" >/dev/null
R=$($P -c "begin; set local taam.uid='$SU'; set local role authenticated; select public.taam_card_order_peek('O4'); commit;" 2>&1 | grep '{')
ok "⑲ 슈퍼어드민 — 상태 · 결과 꼬리 · 결제키 끝 8자리 · 홀드" "pending|unknown:approving|12345678|PAYH-1|미토우" "$(J "$R" status)|$(J "$R" fail_reason)|$(J "$R" pk_tail)|$(J "$R" hold)|$(J "$R" restaurant_name)"
has "⑲ 회원 세션 거절" "FORBIDDEN" "$($P -c "begin; set local taam.uid='$U1'; set local role authenticated; select public.taam_card_order_peek('O4'); commit;" 2>&1)"
has "⑲ anon 거절" "permission denied" "$($P -c "begin; set local role anon; select public.taam_card_order_peek('O4'); commit;" 2>&1)"
# ⑳ 정리 목록 · 킥
seed
$P <<SQL >/dev/null
insert into public.payment_orders(order_id,user_id,purpose,amount,status,fail_reason,updated_at,created_at) values
  ('L1','$U1','ticket_topup',1,'pending','unknown:approving', now() - interval '6 minutes', now() - interval '7 minutes'),
  ('L2','$U1','ticket_topup',1,'pending','unknown:approving', now() - interval '2 minutes', now() - interval '3 minutes'),
  ('L3','$U1','ticket_topup',1,'paid','unknown:converting:x', now() - interval '11 minutes', now() - interval '12 minutes'),
  ('L4','$U1','ticket_topup',1,'paid','unknown:converting:y', now() - interval '4 minutes', now() - interval '5 minutes'),
  ('L5','$U1','ticket_topup',1,'failed','swept_no_payment:approving', now() - interval '10 minutes', now() - interval '30 minutes'),
  ('L6','$U1','ticket_topup',1,'failed','swept_no_payment:approving', now() - interval '50 minutes', now() - interval '60 minutes'),
  ('L7','$U1','ticket_topup',1,'pending',null, now() - interval '50 minutes', now() - interval '60 minutes'),
  ('L8','$U1','invite_topup',1,'pending','unknown:approving', now() - interval '20 minutes', now() - interval '21 minutes'),
  ('L9','$U1','ticket_topup',1,'paid','unknown:converting:z', now() - interval '20 minutes', now() - interval '5 days');
SQL
L=$($P -c "begin; set local role service_role; set local request.jwt.claims = '{\"role\":\"service_role\"}'; select string_agg((x->>'order_id')||':'||(x->>'reconcile'), ',') from jsonb_array_elements(public.taam_card_topup_reconcile_list(15)) x; commit;" 2>&1 | grep -E 'L[0-9]')
ok "⑳ 정리 목록 — 5분 지난 pending 결과 모름 · 10분 지난 paid 결과 모름 · 닫은 지 3~45분 「결제 없음」(오래된 것부터 · 닫힌 주문은 남는 자리에)" "L3:resolve,L1:lookup,L5:orphan" "$L"
has "⑳ 목록 — 회원 세션 거절" "FORBIDDEN\|permission denied" "$($P -c "begin; set local taam.uid='$U1'; set local role authenticated; select public.taam_card_topup_reconcile_list(15); commit;" 2>&1)"
ok "⑳ 킥 — 설정 없으면 부르지 않음(no_config)" "no_config" "$(J "$($P -c "select public.taam_card_topup_reconcile_kick()")" reason)"
$P -c "delete from public.payment_orders" >/dev/null
ok "⑳ 킥 — 볼 것 없으면 건너뜀" "nothing" "$(J "$($P -c "select public.taam_card_topup_reconcile_kick()")" skipped)"

# ㉑ N1 — 같은 홀드를 예치금만으로 확정한 결제(서버 줄 −1,000,000 · order_id 없음) + Edge 는 차감 전에 끊긴 카드 주문 O9(card_dep deducting · plan 600,000)
seed
$P -c "update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 1000000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,fail_reason,metadata) values ('O9','$U1','ticket_topup',400000,'paid','pk9','unknown:converting:abc','{\"card_dep\":{\"hold\":\"PAYH-9\",\"plan\":600000,\"state\":\"deducting\"}}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status,extra_data) values ('$U1','PAYH-9',2,1000000,'T9','active','{\"paidBy\":\"deposit\"}')" >/dev/null
$P -c "select public.taam_apply_deposit_delta('$U1', 0, -1000000, '[{\"deposit_type\":\"general\",\"change_type\":\"ticket_purchase\",\"amount\":-1000000,\"metadata\":{\"purchase_id\":\"PAYH-9\"}}]'::jsonb)" >/dev/null
R=$(settle $U1 O9 600000 PAYH-9)
ok "㉑ N1 Edge 가 이 주문으로 한 푼도 안 뺐으면 0(같은 통의 예치금 단독 결제는 안 돌려줌)" "0|0" "$(J "$R" owed_before)|$(J "$R" order_out)"
ok "㉑ N1 잔액 그대로(공짜 돈 없음)" "0/0" "$(bal $U1)"
# Edge 가 이 주문으로 일반 600,000 을 뺐고, 같은 통의 예치금 단독 결제는 멤버십 1,000,000 → 정리는 600,000 만 · 일반으로
seed
$P -c "update public.profiles set membership_deposit_balance = 1000000, general_deposit_balance = 600000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,fail_reason,metadata) values ('O9','$U1','ticket_topup',400000,'paid','pk9','unknown:converting:abc','{\"card_dep\":{\"hold\":\"PAYH-9\",\"plan\":600000,\"state\":\"taken\",\"taken\":600000}}')" >/dev/null
$P -c "select public.taam_apply_deposit_delta('$U1', -1000000, 0, '[{\"deposit_type\":\"membership\",\"change_type\":\"ticket_purchase\",\"amount\":-1000000,\"metadata\":{\"purchase_id\":\"PAYH-9\"}}]'::jsonb)" >/dev/null
deduct $U1 O9 0 600000 PAYH-9
R=$(settle $U1 O9 600000 PAYH-9)
ok "㉑ N1 이 주문 몫 600,000 만 · 이 주문이 뺀 주머니(일반)로" "0|600000" "$(J "$R" refunded_mem)|$(J "$R" refunded_gen)"
ok "㉑ N1 잔액 — 예치금 단독 결제 1,000,000 은 그대로 빠져 있음" "0/600000" "$(bal $U1)"
R=$(settle $U1 O9 600000 PAYH-9)
ok "㉑ N1 다시 — 0" "0" "$(J "$R" owed_before)"
# 위조 줄(같은 통 · 이 주문 번호)은 이 주문 몫에 들어오지만 상한(Edge 가 뺀 금액)과 회원 자신의 환불 한도로 두 번 못 받는다(V-a)
seed
$P -c "update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 1000000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,fail_reason,metadata) values ('O9','$U1','ticket_topup',500000,'paid','pk9','unknown:failing:convert_failed','{\"card_dep\":{\"hold\":\"PAYH-9\",\"plan\":600000,\"state\":\"deducting\"}}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status) values ('$U1','PAYH-9',2,0,'T9','hold')" >/dev/null
member $U1 general -600000 '{"purchase_id":"PAYH-9","order_id":"O9"}' >/dev/null
R=$(settle $U1 O9 600000 PAYH-9)
$P -c "update public.tickets set status='cancelled' where purchase_id='PAYH-9'; update public.payment_orders set status='canceled', fail_reason='convert_failed_refunded' where order_id='O9'" >/dev/null
member $U1 general 600000 '{"purchase_id":"PAYH-9"}' >/dev/null
ok "㉑ V-a 위조 줄 되돌림 뒤 회원 자기 환불 — 시작 잔액 그대로(두 배 아님)" "0/1000000" "$(bal $U1)"

# ㉒ N4 — 처리 중 카드 주문 O9(paid · 결과 모름 · 티켓 없음)가 같은 홀드를 적어 두었다
seed
$P -c "update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 1000000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,fail_reason,metadata) values ('O9','$U1','ticket_topup',400000,'paid','pk9','unknown:converting:abc','{\"card_dep\":{\"hold\":\"PAYH-9\",\"plan\":600000,\"state\":\"deducting\"}}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status,extra_data) values ('$U1','PAYH-9',2,1000000,'T9','cancelled','{\"paidBy\":\"deposit\"}')" >/dev/null
$P -c "select public.taam_apply_deposit_delta('$U1', 0, -1000000, '[{\"deposit_type\":\"general\",\"change_type\":\"ticket_purchase\",\"amount\":-1000000,\"metadata\":{\"purchase_id\":\"PAYH-9\"}}]'::jsonb)" >/dev/null
ok "㉒ N4 같은 홀드를 예치금만으로 산 구매의 취소 환불은 지난다(V-c)" "1000000" "$(member $U1 general 1000000 '{"purchase_id":"PAYH-9"}' | grep -E '^[0-9]+$')"
R=$(settle $U1 O9 600000 PAYH-9)
ok "㉒ N4 그 뒤 정리는 0(두 번 안 돌려줌)" "0" "$(J "$R" owed_before)"
ok "㉒ N4 잔액 = 시작" "0/1000000" "$(bal $U1)"
# Edge 가 이 주문으로 600,000 을 뺐다(같은 통에 예치금 단독 1,000,000) — 1,000,000 까지는 환불 · Edge 몫 600,000 은 묶임
seed
$P -c "update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 1600000 where id = '$U1'" >/dev/null
$P -c "insert into public.payment_orders(order_id,user_id,purpose,amount,status,payment_key,fail_reason,metadata) values ('O9','$U1','ticket_topup',400000,'paid','pk9','unknown:converting:abc','{\"card_dep\":{\"hold\":\"PAYH-9\",\"plan\":600000,\"state\":\"taken\",\"taken\":600000}}')" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,party_size,price,ticket_product_id,status,extra_data) values ('$U1','PAYH-9',2,1000000,'T9','cancelled','{\"paidBy\":\"deposit\"}')" >/dev/null
$P -c "select public.taam_apply_deposit_delta('$U1', 0, -1000000, '[{\"deposit_type\":\"general\",\"change_type\":\"ticket_purchase\",\"amount\":-1000000,\"metadata\":{\"purchase_id\":\"PAYH-9\"}}]'::jsonb)" >/dev/null
deduct $U1 O9 0 600000 PAYH-9
has "㉒ N4 Edge 몫까지 넘는 환불(1,000,001) — REFUND_CARD_PENDING" "REFUND_CARD_PENDING" "$(member $U1 general 1000001 '{"purchase_id":"PAYH-9"}')"
ok "㉒ N4 Edge 몫 밖(1,000,000)은 지난다" "1000000" "$(member $U1 general 1000000 '{"purchase_id":"PAYH-9"}' | grep -E '^[0-9]+$')"
has "㉒ N4 남은 것은 Edge 몫 — 더는 막힘" "REFUND_CARD_PENDING" "$(member $U1 general 1 '{"purchase_id":"PAYH-9"}')"
# 묶음을 위조 환불 줄로 못 푼다 — 회원이 −600,000(태그 없음)을 넣고 order_id O9 를 단 환불로 받은 뒤 또 받으려 하면 막힘
member $U1 general -600000 '{"purchase_id":"PAYH-9"}' >/dev/null
ok "㉒ N4 (자기 돈 600,000 을 넣고) O9 를 단 환불 600,000 — 지난다(자기 돈)" "1" "$(member $U1 general 600000 '{"purchase_id":"PAYH-9","order_id":"O9"}' | grep -cE '^[0-9]+$')"
has "㉒ N4 O9 를 단 환불 줄로 묶음이 풀리지 않음 — Edge 몫 600,000 은 그대로 막힘" "REFUND_CARD_PENDING" "$(member $U1 general 600000 '{"purchase_id":"PAYH-9"}')"
ok "㉒ N4 잔액 — Edge 몫 600,000 만 빠져 있음" "0/1000000" "$(bal $U1)"
R=$(settle $U1 O9 600000 PAYH-9)
ok "㉒ N4 정리 — 회원이 O9 를 단 환불 600,000 을 이 주문 몫에서 뺀다(그 몫은 이미 회원 손에 있다)" "0" "$(J "$R" owed_before)"

# ㉓ N5 — 정리 목록 물러서기(metadata.sweep {n, at}) · 한 번도 안 본 것 먼저 · 알림 보낸 것 뒤로
seed
$P <<SQL >/dev/null
insert into public.payment_orders(order_id,user_id,purpose,amount,status,fail_reason,updated_at,created_at,metadata) values
  ('S1','$U1','ticket_topup',1,'paid','unknown:converting:a', now() - interval '20 minutes', now() - interval '2 days', jsonb_build_object('sweep', jsonb_build_object('n',1,'at', to_char((now() - interval '5 minutes') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')))),
  ('S2','$U1','ticket_topup',1,'paid','unknown:converting:b', now() - interval '20 minutes', now() - interval '2 days', jsonb_build_object('sweep', jsonb_build_object('n',1,'at', to_char((now() - interval '11 minutes') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')))),
  ('S3','$U1','ticket_topup',1,'paid','unknown:converting:c', now() - interval '40 minutes', now() - interval '2 days', jsonb_build_object('sweep', jsonb_build_object('n',4,'at', to_char((now() - interval '20 minutes') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')))),
  ('S4','$U1','ticket_topup',1,'paid','unknown:converting:d', now() - interval '90 minutes', now() - interval '2 days', jsonb_build_object('sweep', jsonb_build_object('n',9,'at', to_char((now() - interval '60 minutes') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')))),
  ('S5','$U1','ticket_topup',1,'paid','unknown:converting:e', now() - interval '20 minutes', now() - interval '1 hour', '{}'),
  ('S6','$U1','ticket_topup',1,'pending','unknown:approving:alerted', now() - interval '20 minutes', now() - interval '3 hours', '{}'),
  ('S7','$U1','ticket_topup',1,'paid','unknown:converting:f', now() - interval '20 minutes', now() - interval '1 day', '{"sweep":{"n":"x","at":"2026-99-99T99:99"}}'),
  ('S8','$U1','ticket_topup',1,'failed','swept_no_payment:approving', now() - interval '10 minutes', now() - interval '2 days', jsonb_build_object('sweep', jsonb_build_object('n',9,'at', to_char((now() - interval '12 minutes') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'))));
SQL
L=$($P -c "begin; set local role service_role; set local request.jwt.claims = '{\"role\":\"service_role\"}'; select string_agg(x->>'order_id', ','), max((x->>'sweep_n')::int) from jsonb_array_elements(public.taam_card_topup_reconcile_list(15)) x; commit;" 2>&1 | grep -E 'S[0-9]')
ok "㉓ N5 물러서기 — 한 번도 안 본 것(S7 이상한 기록 · S5) → 오래전에 본 것(S2) → 알림 보낸 것(S6) → 닫힌 주문(S8 · 물러서지 않음) · 방금 본 것(S1 · 10분 안) · 4번째 30분 안(S3) · 9번째 120분 안(S4) 은 빠짐" "S7,S5,S2,S6,S8|9" "$L"
L=$($P -c "begin; set local role service_role; set local request.jwt.claims = '{\"role\":\"service_role\"}'; select string_agg(x->>'order_id', ',') from jsonb_array_elements(public.taam_card_topup_reconcile_list(2)) x; commit;" 2>&1 | grep -E 'S[0-9]')
ok "㉓ N5 자리가 2개면 한 번도 안 본 것부터(오래 막힌 주문이 앞자리를 차지하지 않음)" "S7,S5" "$L"

[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
