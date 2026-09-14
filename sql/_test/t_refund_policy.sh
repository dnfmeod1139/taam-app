#!/bin/bash
# 환불 정책 서버화 (sql/refund_policy_server.sql) 재보기. 먼저: 로컬 pg. 실행: bash sql/_test/t_refund_policy.sh
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
U=a1000000-0000-4000-8000-000000000001
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
has(){ echo "$1" | grep -q "$2" && echo 1 || echo 0; }
FAIL=0
$P -v ON_ERROR_STOP=1 -f sql/_test/fx_ledger.sql       >/dev/null 2>/tmp/_r.err || { echo "❌ 픽스처"; head -3 /tmp/_r.err; exit 1; }
$P -v ON_ERROR_STOP=1 -f sql/_test/fx_ledger_close.sql >/dev/null 2>/tmp/_r.err || { echo "❌ 픽스처(close)"; head -3 /tmp/_r.err; exit 1; }
$P -v ON_ERROR_STOP=1 -f sql/ledger_close_member_insert.sql >/dev/null 2>/tmp/_r.err || { echo "❌ ledger_close 적용"; grep -i error /tmp/_r.err | head -3; exit 1; }
# 라이브 모양의 tickets / ticket_products (reservation_date 는 text)
$P -v ON_ERROR_STOP=1 -c "create table if not exists public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, purchase_id text, status text default 'active', price integer, party_size integer default 2, reservation_date text, ticket_product_id text, created_at timestamptz default now());
create table if not exists public.ticket_products(id bigserial primary key, agency_fee integer, meal_fee integer, wine_min integer);
insert into public.ticket_products(id, agency_fee, meal_fee) values (1, 50000, 250000);" >/dev/null
$P -v ON_ERROR_STOP=1 -f sql/refund_policy_server.sql >/tmp/_r.out 2>/tmp/_r.err || { echo "❌ 적용 실패"; grep -i error /tmp/_r.err | head -5; exit 1; }
ok "확인 표 ❌ 없음" 0 "$(grep -c '❌' /tmp/_r.out)"
ok "확인 표 ✅ 5줄" 5 "$(grep -c '✅' /tmp/_r.out)"

# 회원 U: 예치금 1,000,000 · 구매 원장 (서버가 쓴 것처럼 슈퍼어드민 세션으로 넣는다)
S=a1000000-0000-4000-8000-0000000000ff
$P -c "insert into public.profiles(id,role,membership_deposit_balance,general_deposit_balance) values ('$U','member',0,0),('$S','super_admin',0,0) on conflict (id) do update set membership_deposit_balance=0, general_deposit_balance=0, role=excluded.role;" >/dev/null
# 구매 4건: 2인 × (250,000+50,000) = 600,000 씩 (원장은 슈퍼어드민이 직접 INSERT)
mk(){ # purchase_id, created_at, reservation_date
  $P -c "set role authenticated; select set_config('taam.uid','$S',false);
    insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,balance_after,metadata,created_at) values ('$U','general','ticket_purchase',-${4:-600000},0,'{\"purchase_id\":\"$1\"}','${5:-2026-09-01T00:00:00Z}');
    reset role;
    insert into public.tickets(user_id,purchase_id,price,party_size,reservation_date,ticket_product_id,created_at) values ('$U','$1',600000,2,'$3','1','$2');" >/dev/null
}
mk P-FRESH "$(date -u +%FT%TZ)" "2027-01-01" 600000 "$(date -u +%FT%TZ)"
# 홀드는 40분 전, 결제(원장)는 20분 전 → 결제 기준이면 아직 30분 안이다
mk P-PAID20 "$(date -u -d '40 minutes ago' +%FT%TZ)" "2027-01-01" 600000 "$(date -u -d '20 minutes ago' +%FT%TZ)"
# 카드+예치금 혼합: 총액 600,000 중 예치금 200,000 만 원장에 있다
mk P-MIX "2026-09-01T00:00:00Z" "2026-12-01" 200000
mk P-FAR   "2026-09-01T00:00:00Z" "2026-12-01"
mk P-NEAR  "2026-09-01T00:00:00Z" "2026-09-20"
mk P-NODATE "2026-09-01T00:00:00Z" ""
$P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,balance_after,metadata) values ('$U','general','ticket_purchase',-600000,0,'{\"purchase_id\":\"P-OLD\"}');" >/dev/null   # tickets 행 없음(옛 구매)
cap(){ $P -c "select public.taam_refund_cap('$U','$1');" | tail -1; }
echo "── 한도 계산"
ok "30분 이내 → 전액" 600000 "$(cap P-FRESH)"
ok "D-31 이상 → 대행비(50,000×2) 제외" 500000 "$(cap P-FAR)"
ok "D-30 이하 → 0" 0 "$(cap P-NEAR)"
ok "홀드 40분 전·결제 20분 전 → 결제 기준 30분 안이라 전액 ⭐" 600000 "$(cap P-PAID20)"
ok "카드+예치금 혼합(예치금 200,000·총액 600,000·D-31 이상) → 예치금 200,000 전부 (대행비는 총액에서) ⭐" 200000 "$(cap P-MIX)"
ok "방문일 모름 → 대행비 제외" 500000 "$(cap P-NODATE)"
ok "tickets 행 없는 옛 구매 → 낸 돈 그대로" 600000 "$(cap P-OLD)"
ok "경계: 정확히 D-31 은 환불된다" 500000 "$($P -c "insert into public.tickets(user_id,purchase_id,party_size,reservation_date,ticket_product_id,created_at) values ('$U','P-EDGE',2,to_char((now() at time zone 'Asia/Seoul')::date + 31,'YYYY.MM.DD'),'1','2026-09-01');
  insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,balance_after,metadata,created_at) values ('$U','general','ticket_purchase',-600000,0,'{\"purchase_id\":\"P-EDGE\"}','2026-09-01');
  select public.taam_refund_cap('$U','P-EDGE');" | tail -1)"
ok "경계: D-30 은 0" 0 "$($P -c "update public.tickets set reservation_date = to_char((now() at time zone 'Asia/Seoul')::date + 30,'YYYY.MM.DD') where purchase_id='P-EDGE'; select public.taam_refund_cap('$U','P-EDGE');" | tail -1)"

call(){ # uid, mem, gen, entries
  $P -c "set role authenticated; select set_config('taam.uid','$1',false); select public.taam_apply_deposit_delta('$U'::uuid, $2::bigint, $3::bigint, '$4'::jsonb);" 2>&1
}
E(){ echo "[{\"deposit_type\":\"general\",\"change_type\":\"ticket_refund\",\"amount\":$2,\"metadata\":{\"purchase_id\":\"$1\"}}]"; }
echo "── 회원 호출 (앱을 고친 회원 = 정책 밖 금액)"
ok "D-30 이하 티켓 전액 환불 시도 → LEDGER_REFUND_POLICY ⭐" 1 "$(has "$(call $U 0 600000 "$(E P-NEAR 600000)")" LEDGER_REFUND_POLICY)"
ok "D-31 티켓 대행비까지 환불 시도 → 거부 ⭐" 1 "$(has "$(call $U 0 600000 "$(E P-FAR 600000)")" LEDGER_REFUND_POLICY)"
ok "  … 잔액 안 움직임" 0 "$($P -c "select general_deposit_balance from public.profiles where id='$U';" | tail -1)"
ok "D-31 티켓 대행비 제외(500,000) → 통과" 0 "$(has "$(call $U 0 500000 "$(E P-FAR 500000)")" ERROR)"
ok "  … 잔액 500,000" 500000 "$($P -c "select general_deposit_balance from public.profiles where id='$U';" | tail -1)"
ok "같은 구매 한 번 더 → 종전 한도(EXCEEDS 또는 POLICY)로 거부" 1 "$(has "$(call $U 0 1 "$(E P-FAR 1)")" "LEDGER_REFUND")"
ok "30분 이내 전액 → 통과" 0 "$(has "$(call $U 0 600000 "$(E P-FRESH 600000)")" ERROR)"
ok "옛 구매(tickets 없음) 전액 → 종전대로 통과" 0 "$(has "$(call $U 0 600000 "$(E P-OLD 600000)")" ERROR)"
echo "── 슈퍼어드민 예외 환불은 그대로"
ok "슈퍼어드민이 D-30 티켓 전액 환불 → 통과" 0 "$(has "$(call $S 0 600000 "$(E P-NEAR 600000)")" ERROR)"
echo "── 종전 테스트도 그대로 통과하는지 (ledger_close 52건 위에 덧대어)"
bash sql/_test/t_ledger_close.sh >/tmp/_lc.out 2>&1; ok "t_ledger_close ❌ 0" 0 "$(grep -c '^❌' /tmp/_lc.out)"
$P -v ON_ERROR_STOP=1 -f sql/refund_policy_server.sql >/dev/null 2>&1 || { echo "❌ ledger_close 픽스처 위 재적용 실패"; FAIL=1; }
ok "tickets 표 없는 픽스처에서도 함수는 산다 (to_regclass 폴백)" "t" "$($P -c "select public.taam_refund_cap('$U','NOPE') >= 0;" | tail -1)"
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
