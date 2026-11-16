#!/bin/bash
# 카드 승인 뒤 확정 실패 — 예치금 되돌림 서버 함수 (supabase/migrations/20261116_card_order_settle.sql) · 로컬 postgres(/tmp 소켓).
#   실행: bash sql/_test/t_card_order_settle.sh   (DB 이름: TAAM_TEST_DB, 기본 tcos_settle)
#   원장 RPC 는 라이브 본문(sql/_test/fx_live_ledger_2026-11-13.sql · md5 36230be0…)을 올린다 — Edge 가 쓰는 차감 줄 모양 그대로 시드한다.
#   확인: ① 원장 근거 계산(주머니별) ② 멱등(두 번 불러도 한 번) ③ 상한(위조 줄) ④ 권한(서버만) ⑤ 동시 호출(잠금 직렬화) ⑥ 늦게 커밋된 차감 ⑦ 재실행
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261116_card_order_settle.sql
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
  currency text not null default 'KRW', settle_krw bigint, status text not null default 'pending', payment_key text, fail_reason text,
  metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
grant usage on schema public, auth to authenticated, anon, service_role;
SQL
LOADERR="$($P -f sql/_test/fx_live_ledger_2026-11-13.sql 2>&1 | grep ERROR | head -3)$($P -f $MIG 2>&1 | grep -E 'ERROR' | head -3)"
[ -n "$LOADERR" ] && { echo "LOAD FAIL: $LOADERR"; exit 1; }
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 [$2], 실제 [$3])"; FAIL=1; fi; }
has(){ if echo "$3" | grep -q -- "$2"; then echo "✅ $1"; else echo "❌ $1  (기대 포함 [$2], 실제 [$3])"; FAIL=1; fi; }

ok "원장 RPC = 라이브 본문(md5 36230be0…)" 36230be09e2560b57c7dd871a9acbe48 "$($P -c "select md5(prosrc) from pg_proc where oid='public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)'::regprocedure")"
ok "마이그레이션 확인 표에 ❌ 없음" "0" "$($P -f $MIG 2>/dev/null | grep -c '❌')"

# 시드 — Edge deductDeposit 과 같은 모양(서버 호출 · metadata {purchase_id, ticket_id, order_id, portion})으로 차감
seed(){ $P <<SQL >/dev/null
delete from public.deposit_transactions; delete from public.payment_orders;
update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 0;
update public.profiles set membership_deposit_balance = 400000, general_deposit_balance = 500000 where id = '$U1';
update public.profiles set membership_deposit_balance = 0, general_deposit_balance = 300000 where id = '$U2';
insert into public.payment_orders(order_id, user_id, purpose, amount, status, metadata) values
  ('O1', '$U1', 'ticket_topup', 400000, 'paid', '{"toss":{"status":"DONE"}}'),                       -- toss-confirm: 승인 뒤 metadata 를 덮었다(deposit_used 없음)
  ('O2', '$U2', 'ticket_topup', 100000, 'paid', '{"deposit_used":200000,"hold_purchase_id":"PAYH-2"}'), -- toss-billing-charge: metadata 를 합쳤다
  ('O3', '$U1', 'deposit_charge', 1000, 'paid', '{}'),
  ('O4', '$U1', 'ticket_topup', 1000, 'paid', '{}');
SQL
}
deduct(){ # $1 user $2 order $3 mem $4 gen
  $P -c "select public.taam_apply_deposit_delta('$1', -$3, -$4, (select jsonb_agg(e) from (
    select jsonb_build_object('deposit_type','membership','change_type','ticket_purchase','amount',-$3,'description','차감',
           'metadata', jsonb_build_object('purchase_id','PAYH-1','order_id','$2','portion','membership')) e where $3 > 0
    union all
    select jsonb_build_object('deposit_type','general','change_type','ticket_purchase','amount',-$4,'description','차감',
           'metadata', jsonb_build_object('purchase_id','PAYH-1','order_id','$2','portion','general')) where $4 > 0) z))" >/dev/null
}
bal(){ $P -c "select membership_deposit_balance||'/'||general_deposit_balance from public.profiles where id='$1'"; }
settle(){ $P -c "select public.taam_card_order_settle('$2', '$1', ${3:-null}, 'PAYH-1', 'repurchase_blocked', null)" 2>&1; }
J(){ echo "$1" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('$2'))" 2>/dev/null; }

# ① 기본 — 멤버십 400,000 + 일반 200,000 빠짐 → 되돌림 같은 주머니로
seed; deduct $U1 O1 400000 200000
ok "차감 뒤 잔액" "0/300000" "$(bal $U1)"
R=$(settle $U1 O1 600000)
ok "① 되돌림 멤버십 400,000" "400000" "$(J "$R" refunded_mem)"
ok "① 되돌림 일반 200,000" "200000" "$(J "$R" refunded_gen)"
ok "① 잔액 원상복구" "400000/500000" "$(bal $U1)"
ok "① 원장 줄: ticket_refund 2줄 · metadata order_id · card_fail_code" "2|2" "$($P -c "select count(*)||'|'||count(*) filter (where metadata->>'card_fail_code'='repurchase_blocked' and metadata->>'order_id'='O1') from public.deposit_transactions where change_type='ticket_refund' and user_id='$U1'")"
ok "① 되돌림 줄에 판매현황 분류 키(reason·fix·refund_type·cancel_refund) 없음" "0" "$($P -c "select count(*) from public.deposit_transactions where change_type='ticket_refund' and (metadata ? 'reason' or metadata ? 'fix' or metadata ? 'refund_type' or metadata ? 'cancel_refund')")"
# ② 멱등
R=$(settle $U1 O1 600000)
ok "② 두 번째 호출 — 되돌림 0" "0|0" "$(J "$R" refunded_mem)|$(J "$R" refunded_gen)"
ok "② 잔액 그대로(두 번 안 돌려줌)" "400000/500000" "$(bal $U1)"
# ③ 상한 없음 + metadata deposit_used 사용(O2)
seed; deduct $U2 O2 0 200000
R=$(settle $U2 O2)
ok "③ 상한 = 주문 metadata.deposit_used(200,000) · 되돌림 200,000" "200000" "$(J "$R" refunded_gen)"
ok "③ 잔액 복구" "0/300000" "$(bal $U2)"
# ④ 위조 줄 — 회원이 자기 원장에 이 주문 번호를 단 「차감」 줄을 쓴다(회원 세션 · 음수 줄은 원장 RPC 가 받는다 · server_caller 까지 흉내)
#   합계 0 짜리(멤버십 −, 일반 +)는 원장 RPC 가 양수 줄을 거절해 못 쓴다 — 회원이 쓸 수 있는 것은 진짜로 빠지는 음수 줄뿐이다(제 돈)
seed; deduct $U1 O1 400000 200000
$P -c "update public.profiles set general_deposit_balance = general_deposit_balance + 100000 where id='$U1'" >/dev/null
$P -c "begin; set local taam.uid='$U1'; set local role authenticated;
  select public.taam_apply_deposit_delta('$U1', 0, -100000, '[{\"deposit_type\":\"general\",\"change_type\":\"ticket_purchase\",\"amount\":-100000,\"metadata\":{\"order_id\":\"O1\",\"server_caller\":\"service_role\"}}]'::jsonb); commit;" >/dev/null 2>&1
FORGED=$($P -c "select count(*) from public.deposit_transactions where user_id='$U1' and amount=-100000")
R=$(settle $U1 O1 600000)
ok "④ 위조 줄이 있어도 되돌림 합계는 상한(600,000)까지" "600000" "$(( $(J "$R" refunded_mem) + $(J "$R" refunded_gen) ))"
if [ "$FORGED" = "1" ]; then echo "  (위조 줄이 실제로 들어갔다 — 상한이 막았다)"; else echo "  (위조 줄은 원장 RPC 가 거절했다 — 상한은 받침)"; fi
R=$(settle $U1 O1 600000)
ok "④ 다시 불러도 0 (상한에서 이미 돌아간 몫을 뺀다)" "0" "$(( $(J "$R" refunded_mem) + $(J "$R" refunded_gen) ))"
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
ok "⑦ 다른 용도 주문 — SETTLE_BAD_PURPOSE" "1" "$(settle $U1 O3 | grep -c SETTLE_BAD_PURPOSE)"
ok "⑦ 없는 주문 — ORDER_NOT_FOUND" "1" "$(settle $U1 NOPE | grep -c ORDER_NOT_FOUND)"
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
( $P -c "begin; select public.taam_apply_deposit_delta('$U1', -400000, -200000, '[{\"deposit_type\":\"membership\",\"change_type\":\"ticket_purchase\",\"amount\":-400000,\"metadata\":{\"order_id\":\"O1\"}},{\"deposit_type\":\"general\",\"change_type\":\"ticket_purchase\",\"amount\":-200000,\"metadata\":{\"order_id\":\"O1\"}}]'::jsonb); select pg_sleep(1.5); commit;" >/dev/null 2>&1 ) &
sleep 0.4
R=$(settle $U1 O1 600000)
wait
ok "⑨ 진행 중이던 차감까지 되돌림(600,000)" "600000" "$(J "$R" owed_before)"
ok "⑨ 잔액 원상복구" "400000/500000" "$(bal $U1)"
# ⑩ 재실행 — 마이그레이션 두 번
ok "⑩ 마이그레이션 재실행 오류 없음" "0" "$($P -f $MIG 2>&1 | grep -c ERROR)"

[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
