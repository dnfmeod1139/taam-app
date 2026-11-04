#!/bin/bash
# 2026-11-04 조기 예약금 반환 — 처리된 예약의 회원 환불 가드(supabase/migrations/20261104_early_return.sql A) · 로컬 postgres 픽스처
#   실행: bash sql/_test/t_early_return.sh   (판매 현황 덧대기 B 는 t_ticket_sales.sh 의 E 절)
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261104_early_return.sql
FAIL=0
DB=t_early_return; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
M1=b2000000-0000-4000-8000-000000000001; M2=b2000000-0000-4000-8000-000000000002; SU=b2000000-0000-4000-8000-000000000009
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema auth;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, role text);
create or replace function public.is_super_admin(p uuid) returns boolean language sql stable as \$\$ select exists(select 1 from public.profiles where id = p and role = 'superadmin') \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, purchase_id text, status text, price bigint, party_size int, extra_data jsonb default '{}');
grant usage on schema public to authenticated; grant select, insert, update on public.tickets to authenticated;
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, description text, metadata jsonb default '{}', created_at timestamptz default now());
insert into public.profiles values ('$M1','user'),('$M2','user'),('$SU','superadmin');
-- 조기 반환된 초대 좌석(살아 있음) · 위약 처리된 앱 구매(취소) · 처리 안 된 회원 취소 · deposit_return 만 있는 옛 행
insert into public.tickets(user_id,purchase_id,status,price,party_size,extra_data) values
 ('$M1','INV-e965d4ee-1','active',2300000,2,'{"super_admin_processed_at":"2026-11-03T13:30:52Z","deposit_return":{"type":"returned","early":true,"returnAmt":2000000}}'),
 ('$M1','PAYH-PEN','cancelled',1000000,1,'{"super_admin_processed_at":"2026-10-01T00:00:00Z","deposit_return":{"type":"penalty","returnAmt":500000}}'),
 ('$M1','PAYH-OWN','cancelled',1000000,1,'{"cancel_reason":"회원 취소"}'),
 ('$M2','PAYH-OLD','cancelled',800000,1,'{"deposit_return":{"type":"returned","returnAmt":700000}}');
SQL
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $3, 실제 $2)"; FAIL=1; fi; }
out=$($P -f "$MIG" 2>&1)
ok "마이그레이션 — 오류 없음 · ❌ 0 · ① ①-b ④ ✅ · ② 판매 현황 함수 없음 ⚠ 건너뜀" "$(echo "$out" | grep -cE "^ERROR|^psql:.*ERROR")/$(echo "$out" | grep -c '❌')/$(echo "$out" | grep -cE '(①|④).*✅')/$(echo "$out" | grep -c '함수가 없다')" "0/0/3/1"
ins(){ # $1 uid(세션) $2 user_id $3 amount $4 purchase $5 change_type
  $P -c "set taam.uid = '$1'; insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$2','general','${5:-ticket_refund}',$3,'{\"purchase_id\":\"$4\"}')" 2>&1 | awk '/REFUND_ALREADY_PROCESSED/{print "REFUND_ALREADY_PROCESSED"; f=1; exit} /ERROR/{e=1} END{if(!f && e) print "ERROR"}'; }
ok "G1 조기 반환된 예약 — 회원이 남은 대행비 ₩300,000 환불을 더 부르면 거절" "$(ins $M1 $M1 300000 INV-e965d4ee-1)" "REFUND_ALREADY_PROCESSED"
ok "G2 위약 처리된 예약(취소) — 회원이 RPC 로 환불을 더 부르면 거절(종전 구멍)" "$(ins $M1 $M1 100000 PAYH-PEN)" "REFUND_ALREADY_PROCESSED"
ok "G3 deposit_return 만 있는 옛 행도 처리된 것으로" "$(ins $M2 $M2 1000 PAYH-OLD)" "REFUND_ALREADY_PROCESSED"
ok "G4 처리 안 된 회원 취소 환불은 그대로" "$(ins $M1 $M1 900000 PAYH-OWN)" ""
ok "G5 ₩0 줄은 이 가드가 보지 않는다" "$(ins $M1 $M1 0 INV-e965d4ee-1)" ""
ok "G6 슈퍼어드민은 그대로" "$(ins $SU $M1 300000 INV-e965d4ee-1)" ""
ok "G7 서버(로그인 없음 · Edge · SQL Editor)는 그대로" "$($P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M1','general','ticket_refund',1,'{\"purchase_id\":\"INV-e965d4ee-1\"}')" 2>&1 | grep -c ERROR)" "0"
ok "G8 처리된 예약의 인원 줄임 환불 — 회원 세션 거절" "$(ins $M1 $M1 100000 INV-e965d4ee-1 ticket_pax_change)" "REFUND_ALREADY_PROCESSED"
ok "G8b 처리된 예약의 인원 줄임 환불 — 슈퍼어드민도 거절(조기 반환 뒤 이중 환불)" "$(ins $SU $M1 100000 INV-e965d4ee-1 ticket_pax_change)" "REFUND_ALREADY_PROCESSED"
ok "G8c 처리 안 된 예약의 인원 줄임 환불은 그대로(슈퍼어드민·회원)" "$(ins $SU $M1 100000 PAYH-OWN ticket_pax_change)|$(ins $M1 $M1 100000 PAYH-OWN ticket_pax_change)" "|"
ok "G8d 서버(로그인 없음)의 인원 줄임 환불은 그대로 · ₩0 도 그대로" "$($P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M1','general','ticket_pax_change',1,'{\"purchase_id\":\"INV-e965d4ee-1\"}')" 2>&1 | grep -c ERROR)|$(ins $SU $M1 0 INV-e965d4ee-1 ticket_pax_change)" "0|"
ok "G9 구매 id 가 없는 줄은 그대로" "$($P -c "set taam.uid = '$M1'; insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M1','general','ticket_refund',1,'{}')" 2>&1 | grep -c ERROR)" "0"
ok "G10 남의 같은 구매 id(다른 회원 행) 는 그 회원 것만 본다" "$(ins $M2 $M2 1000 INV-e965d4ee-1)" ""
ok "G11 회원·anon 은 가드 함수를 직접 못 부른다" "$($P -c "select has_function_privilege('authenticated', 'public.taam_guard_ledger_refund_processed()', 'execute')::text || '/' || has_function_privilege('anon', 'public.taam_guard_ledger_refund_processed()', 'execute')::text")" "false/false"
# C. 좌석 열기는 언제나 취소 — 초대장 동기화 판정
T0=$(TZ=Asia/Seoul date +%Y.%m.%d)
vr(){ $P -c "select public._taam_seat_visited_return('$1'::jsonb, '$2', null)::text"; }
ok "V1 방문 당일 처리한 반환(표시 없음) = 다녀온 반환(종전)" "$(vr '{"super_admin_processed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","deposit_return":{"type":"returned"}}' "$T0")" "true"
ok "V2 방문 당일이어도 「좌석 열기」 = 취소" "$(vr '{"super_admin_processed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","deposit_return":{"type":"returned","seatOpened":true}}' "$T0")" "false"
ok "V3 연도 없는 날짜 — 표시 없음 = 다녀온 것으로 · 좌석 열기 = 취소" "$(vr '{"deposit_return":{"type":"returned"}}' '11.13')|$(vr '{"deposit_return":{"type":"returned","seatOpened":true}}' '11.13')" "true|false"
ok "V4 위약(penalty)은 종전대로 취소" "$(vr '{"deposit_return":{"type":"penalty"}}' "$T0")" "false"
ok "V5 다녀온 기록(attended)이 있으면 좌석 열기 표시가 있어도 다녀온 반환" "$($P -c "select public._taam_seat_visited_return('{\"deposit_return\":{\"type\":\"returned\",\"seatOpened\":true}}'::jsonb, '2026.10.01', 'attended')::text")" "true"
# A2. 처리된 예약의 카드 환불 대기 — 인원 변경 카드 갈래
cq(){ $P -c "set taam.uid = '$1'; update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_queue}', coalesce(extra_data->'card_refund_queue','[]'::jsonb) || '[{\"amount\":750000,\"status\":\"pending\"}]') where purchase_id = '$2'" 2>&1 | awk '/REFUND_ALREADY_PROCESSED/{print "REFUND_ALREADY_PROCESSED"; f=1; exit} /ERROR/{e=1} END{if(!f && e) print "ERROR"}'; }
ok "C1 처리된 예약의 카드 환불 대기 늘리기 — 파트너·슈퍼어드민 세션 거절" "$(cq $M2 INV-e965d4ee-1)|$(cq $SU INV-e965d4ee-1)" "REFUND_ALREADY_PROCESSED|REFUND_ALREADY_PROCESSED"
ok "C2 처리 안 된 예약은 그대로 · 서버는 그대로 · 다른 칸 갱신은 그대로" "$(cq $SU PAYH-OWN)|$($P -c "update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_queue}', '[{\"amount\":1}]') where purchase_id = 'INV-e965d4ee-1'" 2>&1 | grep -c ERROR)|$($P -c "set taam.uid = '$SU'; update public.tickets set extra_data = extra_data || '{\"memo\":\"x\"}' where purchase_id = 'INV-e965d4ee-1'" 2>&1 | grep -c ERROR)" "|0|0"
out2=$($P -f "$MIG" 2>&1)
ok "재실행 — 오류 없음 · ① ①-b ✅" "$(echo "$out2" | grep -cE "^ERROR|^psql:.*ERROR")/$(echo "$out2" | grep -cE '①.*✅')" "0/2"
[ -z "$KEEP" ] && psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
