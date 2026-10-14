#!/bin/bash
# 캘린더 수동 추가(MAN-) 수정 RPC 회귀 — 2026-10-14. 먼저: 로컬 pg. 실행: bash sql/_test/t_manual_edit.sh
#   실제 행 가드(sql/audit_hardening_2026-09-13.sql 의 taam_guard_ticket_row + 트리거)를 그대로 올려 「매장 어드민의 직접 UPDATE 는 막히고,
#   RPC 는 지난다」를 같이 본다. 정원은 ticket_products.total_pax 로만(총 정원).
cd "$(dirname "$0")/../.."
DB=t_manedit; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; A1=a1000000-0000-4000-8000-000000000002; A2=a1000000-0000-4000-8000-000000000003; M=a1000000-0000-4000-8000-000000000011
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
          if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create table public.profiles(id uuid primary key, role text, display_name text);
create table public.restaurant_admins(user_id uuid, restaurant_id text);
create or replace function public.is_restaurant_admin_of(p_restaurant_id text) returns boolean language sql stable security definer as \$\$
  select exists (select 1 from public.restaurant_admins ra where ra.user_id = auth.uid() and ra.restaurant_id = p_restaurant_id) \$\$;
create table public.ticket_products(id text primary key, total_pax int, slots jsonb, status text default 'active');
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text,
  ticket_type text, reservation_date text, visit_time text, party_size int default 1, price int default 0, status text default 'manual', purchase_id text,
  buyer_name text, buyer_phone text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
insert into auth.users values ('$SU'),('$A1'),('$A2'),('$M');
insert into public.profiles values ('$SU','super_admin','슈퍼'), ('$A1','admin','매장1 어드민'), ('$A2','admin','매장2 어드민'), ('$M','member','회원');
insert into public.restaurant_admins values ('$A1','r1'), ('$A2','r2');
insert into public.ticket_products values ('tp1', 8, null, 'active'), ('tp0', null, null, 'active');
insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, party_size, price, status, purchase_id, buyer_name, buyer_phone, extra_data) values
  ('$A1','r1','매장1','tp1','2027.03.01','19:00', 2, 0, 'manual', 'MAN-1', '김수동', '', '{"manualEntry":true,"ttype":"오프라인","memo":"창가"}'),
  ('$M', 'r1','매장1','tp1','2027.03.01','19:00', 4, 500000, 'active', 'PAY-x', null, null, '{}'),
  ('$A1','r1','매장1','tp1','2027.03.01','19:00', 1, 0, 'cancelled', 'MAN-2', '취소된', '', '{"manualEntry":true}'),
  ('$A1','r1','매장1','tp0','2027.03.02','12:00', 1, 0, 'manual', 'MAN-3', '무정원', '', '{"manualEntry":true}'),
  ('$SU','r2','매장2',null,'2027.03.03','19:00', 2, 0, 'manual', 'MAN-4', '회차없음', '', '{"manualEntry":true}');
grant usage on schema public to authenticated, anon; grant all on all tables in schema public to authenticated; grant usage on schema auth to authenticated, anon;
SQL
# 실제 행 가드(audit_hardening 판) 함수 + 트리거
S=$(grep -n 'create or replace function public.taam_guard_ticket_row' sql/audit_hardening_2026-09-13.sql | head -1 | cut -d: -f1)
E=$(grep -n 'execute function public.taam_guard_ticket_row();' sql/audit_hardening_2026-09-13.sql | head -1 | cut -d: -f1)
sed -n "${S},${E}p" sql/audit_hardening_2026-09-13.sql | $P >/dev/null 2>&1
out=$($P -f supabase/migrations/20261014_manual_entry_edit.sql 2>&1)
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
ok "픽스처: 행 가드 트리거 올라감" "1" "$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_row'")"
# rpc uid super pid name phone pax amount ttype memo → OK:<json> | <ERRCODE>
rpc(){ o=$($P -c "set local taam.uid='$1'; set local taam.super='$2'; set local role authenticated; select public.taam_manual_entry_update('$3', $4, $5, $6, $7, $8, $9);" 2>&1); if echo "$o" | grep -q "^ERROR"; then echo "$o" | grep -oE "ERROR:  [A-Z_]+" | head -1 | sed 's/ERROR:  //'; else echo "OK:$o"; fi; }
col(){ $P -c "select $2 from public.tickets where purchase_id='$1'"; }
echo "── 슈퍼어드민"
r=$(rpc $SU 1 MAN-1 "'박수정'" "''" 2 150000 "'초대'" "'룸 요청'")
ok "이름·금액·유형·메모 수정 → ok · changed 4개" "OK|4" "$(echo "$r" | cut -c1-2)|$(echo "$r" | sed 's/^OK://' | jq -r '.changed|length' 2>/dev/null)"
ok "행에 반영: buyer_name·price·ttype·memo" "박수정|150000|초대|룸 요청" "$(col MAN-1 "buyer_name||'|'||price||'|'||(extra_data->>'ttype')||'|'||(extra_data->>'memo')")"
ok "수정 기록 1건 · from.pax 2 · role super_admin" "1|2|super_admin" "$(col MAN-1 "jsonb_array_length(extra_data->'edits')||'|'||(extra_data->'edits'->0->'from'->>'pax')||'|'||(extra_data->'edits'->0->>'role')")"
ok "인원 2→4 (남 4명 + 4 = 8 ≤ 정원 8) → ok" "OK" "$(rpc $SU 1 MAN-1 "'박수정'" "''" 4 150000 "'초대'" "'룸 요청'" | cut -c1-2)"
ok "인원 4→5 (4+5 > 8) → TICKET_SOLD_OUT" "TICKET_SOLD_OUT" "$(rpc $SU 1 MAN-1 "'박수정'" "''" 5 150000 "'초대'" "'룸 요청'")"
ok "인원 그대로 4 (정원 꽉 찬 상태) → 검사 없이 ok" "OK" "$(rpc $SU 1 MAN-1 "'박수정'" "''" 4 160000 "'초대'" "'룸 요청'" | cut -c1-2)"
ok "인원 4→1 (감소) → ok, 행 party_size 1" "OK|1" "$(rpc $SU 1 MAN-1 "'박수정'" "''" 1 160000 "'초대'" "'룸 요청'" | cut -c1-2)|$(col MAN-1 party_size)"
r=$(rpc $SU 1 MAN-1 "'박수정'" "''" 1 160000 "'초대'" "'룸 요청'")
ok "바뀐 게 없으면 ok · changed [] · 기록 안 쌓임(4건 그대로)" "OK|0|4" "$(echo "$r" | cut -c1-2)|$(echo "$r" | sed 's/^OK://' | jq -r '.changed|length')|$(col MAN-1 "jsonb_array_length(extra_data->'edits')")"
echo "── 번호"
ok "+82 10-1234-5678 → 01012345678" "01012345678" "$(rpc $SU 1 MAN-1 "'박수정'" "'+82 10-1234-5678'" 1 160000 "'초대'" "'룸 요청'" >/dev/null; col MAN-1 buyer_phone)"
ok "02-123-4567 (유선) → BAD_PHONE" "BAD_PHONE" "$(rpc $SU 1 MAN-1 "'박수정'" "'02-123-4567'" 1 160000 "'초대'" "'룸 요청'")"
ok "비우면 '' (알림톡 안 보냄)" "" "$(rpc $SU 1 MAN-1 "'박수정'" "''" 1 160000 "'초대'" "'룸 요청'" >/dev/null; col MAN-1 buyer_phone)"
echo "── 매장 어드민"
ok "A1 직접 UPDATE party_size → 행 가드가 막음 (RPC 가 필요한 이유)" "1" "$($P -c "set local taam.uid='$A1'; set local taam.super='0'; set local role authenticated; update public.tickets set party_size=3 where purchase_id='MAN-1';" 2>&1 | grep -c "인원은 직접 바꿀 수 없습니다")"
ok "A1(매장1 어드민) RPC 로 인원 1→3 → ok · 행 3 · role restaurant_admin" "OK|3|restaurant_admin" "$(rpc $A1 0 MAN-1 "'박수정'" "''" 3 160000 "'초대'" "'룸 요청'" | cut -c1-2)|$(col MAN-1 party_size)|$(col MAN-1 "extra_data->'edits'->-1->>'role'")"
ok "A2(다른 매장 어드민) → FORBIDDEN" "FORBIDDEN" "$(rpc $A2 0 MAN-1 "'해킹'" "''" 1 0 "'초대'" "''")"
ok "회원 → FORBIDDEN (행 내용 안 샘)" "FORBIDDEN" "$(rpc $M 0 MAN-1 "'해킹'" "''" 1 0 "'초대'" "''")"
ok "비로그인 → NOT_AUTHENTICATED" "NOT_AUTHENTICATED" "$(rpc '' 0 MAN-1 "'x'" "''" 1 0 "'초대'" "''")"
echo "── 대상 검사"
ok "앱 구매 행(PAY-x) → NOT_MANUAL" "NOT_MANUAL" "$(rpc $SU 1 PAY-x "'x'" "''" 1 0 "'초대'" "''")"
ok "취소된 MAN-2 → ALREADY_CANCELLED" "ALREADY_CANCELLED" "$(rpc $SU 1 MAN-2 "'x'" "''" 1 0 "'초대'" "''")"
ok "없는 purchase_id → PURCHASE_NOT_FOUND" "PURCHASE_NOT_FOUND" "$(rpc $SU 1 MAN-없음 "'x'" "''" 1 0 "'초대'" "''")"
ok "정원 없는 회차(tp0) 1→20 → ok (제한 없음)" "OK" "$(rpc $SU 1 MAN-3 "'무정원'" "''" 20 0 "'오프라인'" "''" | cut -c1-2)"
ok "회차 연결 없는 행(ticket_product_id null) 2→6 → ok" "OK" "$(rpc $SU 1 MAN-4 "'회차없음'" "''" 6 0 "'오프라인'" "''" | cut -c1-2)"
ok "100명 → BAD_PAX" "BAD_PAX" "$(rpc $SU 1 MAN-3 "'무정원'" "''" 100 0 "'오프라인'" "''")"
ok "유형이 초대/오프라인 밖이면 옛값 유지" "오프라인" "$(rpc $SU 1 MAN-3 "'무정원'" "''" 20 1000 "'엉뚱'" "''" >/dev/null; col MAN-3 "extra_data->>'ttype'")"
ok "빈 이름 → '수동 예약' 기본값" "수동 예약" "$(rpc $SU 1 MAN-3 "'  '" "''" 20 1000 "'오프라인'" "''" >/dev/null; col MAN-3 buyer_name)"
ok "메모 1001자 → MEMO_TOO_LONG" "MEMO_TOO_LONG" "$(rpc $SU 1 MAN-3 "'x'" "''" 20 1000 "'오프라인'" "repeat('가',1001)")"
echo "── 기록 상한"
for i in $(seq 1 33); do rpc $SU 1 MAN-4 "'회차없음'" "''" 6 $i "'오프라인'" "''" >/dev/null; done
ok "33번 고쳐도 edits 는 30건 · 마지막 to.price 33" "30|33" "$(col MAN-4 "jsonb_array_length(extra_data->'edits')||'|'||(extra_data->'edits'->-1->'to'->>'price')")"
echo "── 권한 부여"
ok "authenticated 실행 가능 · anon 불가" "true|false" "$($P -c "select has_function_privilege('authenticated','public.taam_manual_entry_update(text,text,text,integer,integer,text,text)','execute')||'|'||has_function_privilege('anon','public.taam_manual_entry_update(text,text,text,integer,integer,text,text)','execute')")"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
