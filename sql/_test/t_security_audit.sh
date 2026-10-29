#!/usr/bin/env bash
# 20261029_security_audit.sql 회귀 — 초대 코드 표 비로그인 차단 · 인원 변경(taam_change_party_size) 운영 행 거부·파트너 환불 한도
#   라이브 모양: invite_codes_read(roles public · USING true) + 슈퍼어드민 읽기 정책 · taam_change_party_size 는 저장소 sql/ticket_pax_change.sql 판을 그대로 올린다.
set -u
cd "$(dirname "$0")/../.."
DB=tsa_$$
P="psql -h /tmp -U postgres -d $DB -X -q -A -t -v ON_ERROR_STOP=0"
MIG=supabase/migrations/20261029_security_audit.sql
FAIL=0
SU=a1000000-0000-4000-8000-000000000001; M1=a1000000-0000-4000-8000-000000000002; M2=a1000000-0000-4000-8000-000000000003; PT=a1000000-0000-4000-8000-000000000004
R1=c1000000-0000-4000-8000-000000000001
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
$P >/dev/null 2>&1 <<SQL
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema if not exists auth; grant usage on schema auth to authenticated, anon;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, role text default 'user', display_name text, membership_deposit_balance bigint default 0, general_deposit_balance bigint default 0, deposit_balance bigint default 0);
create table public.ticket_products(id text primary key, rest_id text, agency_fee int default 0, meal_fee int default 0, wine_min int default 0, date text);
create or replace function public.taam_ticket_price_krw(p_id text, p_pax int) returns bigint language sql stable as \$\$ select nullif(((coalesce(meal_fee,0)+coalesce(agency_fee,0)+coalesce(wine_min,0))*greatest(p_pax,1))::bigint, 0) from public.ticket_products where id = p_id \$\$;
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, purchase_id text, status text, party_size int, price int, extra_data jsonb default '{}', created_at timestamptz default now());
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint, description text, metadata jsonb default '{}', created_at timestamptz default now());
create table public.admin_grants(user_id uuid, rest_id text, status text default 'approved');
create or replace function public.is_restaurant_admin_of(p text) returns boolean language sql stable security definer set search_path = public as \$\$
  select exists (select 1 from public.admin_grants g where g.user_id = auth.uid() and g.rest_id = p and g.status = 'approved') \$\$;
create table public.invite_codes(code text primary key, invitee_name text, invitee_phone text, invitee_email text, invitee_tier text, used boolean default false, member_id text);
alter table public.invite_codes enable row level security;
create policy invite_codes_read on public.invite_codes for select to public using (true);
create policy "super_admin can read all invite codes" on public.invite_codes for select to authenticated using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'superadmin'));
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;
insert into public.invite_codes values ('KRM00001','홍길동','010-1111-2222',null,'M',false,null),('ENT00002','Jane',null,'j@x.com','T',true,'$M1');
insert into public.profiles(id,role,display_name,general_deposit_balance) values ('$SU','superadmin','운영',0),('$M1','user','회원일',0),('$M2','user','회원이',0),('$PT','user','파트너',0);
insert into public.admin_grants values ('$PT','$R1','approved');
insert into public.ticket_products(id,rest_id,agency_fee,meal_fee,date) values ('tp1','$R1',100000,400000,'2027.01.10'),('tpX','c1000000-0000-4000-8000-0000000000ff',100000,400000,'2027.01.10');
-- 회원 M1 의 2인 구매(₩1,000,000 · 1인 50만 · 대행비 10만) · 파트너 자기 수동 좌석 · 파트너 자기 구매
insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,purchase_id,status,party_size,price,extra_data,created_at) values
 ('$M1','$R1','메이노','tp1','PAYH-tp1_a','active',2,1000000,'{"paidBy":"deposit","depositUsed":1000000}', now() - interval '2 days'),
 ('$M1','$R1','메이노','tp1','PAYH-tp1_new','active',2,1000000,'{"paidBy":"deposit","depositUsed":1000000}', now() - interval '5 minutes'),
 ('$PT','$R1','메이노','tp1','MAN-1700000000000','manual',3,3000000,'{"manualEntry":true}', now() - interval '2 days'),
 ('$PT','$R1','메이노','tp1','PAYH-tp1_pt','active',2,1000000,'{"paidBy":"deposit","depositUsed":1000000}', now() - interval '2 days'),
 ('$M2','$R1','메이노','tp1','PAYH-tp1_su','active',3,1500000,'{"paidBy":"deposit","depositUsed":1500000}', now() - interval '2 days');
SQL
# 저장소의 실제 인원 변경 함수
awk '/^create or replace function public.taam_change_party_size\(/{f=1} f{print} /^comment on function public.taam_change_party_size/{exit}' sql/ticket_pax_change.sql | $P >/dev/null 2>&1
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1 — 기대 [$3] 실제 [$2]"; FAIL=1; fi; }
has(){ if echo "$2" | grep -q -- "$3"; then echo "✅ $1"; else echo "❌ $1 — [$3] 없음: ${2:0:300}"; FAIL=1; fi; }
AS(){ $P -c "set role authenticated; set taam.uid='$1'; $2" 2>&1; }
ANON(){ $P -c "set role anon; set taam.uid=''; $1" 2>&1; }
Q(){ $P -c "$1" 2>&1; }
ok "픽스처 — 인원 변경 함수 설치됨(저장소 판)" "$(Q "select count(*) from pg_proc where proname='taam_change_party_size'")" "1"
ok "고치기 전 — anon 이 초대장 전부를 읽는다(라이브 재현)" "$(ANON "select count(*) from public.invite_codes")" "2"
r=$(AS "$PT" "select public.taam_change_party_size('MAN-1700000000000', 1, 2000000, '줄임')"); ok "고치기 전 — 파트너가 자기 수동 좌석으로 예치금을 만든다(라이브 재현)" "$(Q "select general_deposit_balance + membership_deposit_balance from public.profiles where id='$PT'")" "2000000"
# 되돌리고 마이그레이션
Q "update public.profiles set general_deposit_balance=0, membership_deposit_balance=0, deposit_balance=0 where id='$PT'; update public.tickets set party_size=3, price=3000000, extra_data='{\"manualEntry\":true}' where purchase_id='MAN-1700000000000'; delete from public.deposit_transactions;" >/dev/null
# 원장 — 서버가 적은 예치금 결제(확정 구매만) · 2차 리뷰 픽스처: 회원이 금액을 적은 미결제 홀드 · 회차 없는 행 · 원장 없는 옛 구매 · 여러 번 나눠 줄이는 4인 구매 · 정가보다 비싼 행
Q "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values
 ('$M1','general','ticket_purchase',-1000000,'{\"purchase_id\":\"PAYH-tp1_a\"}'),
 ('$M1','general','ticket_purchase',-1000000,'{\"purchase_id\":\"PAYH-tp1_new\"}'),
 ('$M2','general','ticket_purchase',-1500000,'{\"purchase_id\":\"PAYH-tp1_su\"}'),
 ('$M2','membership','ticket_purchase',-2000000,'{\"purchase_id\":\"PAYH-tp1_seq\"}'),
 ('$M2','general','ticket_purchase',-1400000,'{\"purchase_id\":\"PAYH-tp1_hi\"}');
insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,purchase_id,status,party_size,price,extra_data,created_at) values
 ('$M2','$R1','메이노',null,'PAYH-fake','hold',2,100000000,'{}', now()),
 ('$M2','$R1','메이노','tp1','PAYH-tp1_hold','hold',2,1000000,'{}', now()),
 ('$M2','$R1','메이노','tpX','PAYH-tpX_other','active',2,1000000,'{}', now() - interval '2 days'),
 ('$M2','$R1','메이노','tp1','PAYH-tp1_old','active',2,1000000,'{}', now() - interval '60 days'),
 ('$M2','$R1','메이노','tp1','PAYH-tp1_seq','active',4,2000000,'{}', now() - interval '2 days'),
 ('$M2','$R1','메이노','tp1','PAYH-tp1_hi','active',2,1400000,'{}', now() - interval '2 days');" >/dev/null
out=$($P -f "$MIG" 2>&1)
echo "$out" | grep -q "❌" && { echo "❌ 확인 표에 ❌"; echo "$out" | grep "❌"; FAIL=1; } || echo "✅ 확인 표"
echo "$out" | grep -q "ERROR" && { echo "❌ 설치 중 ERROR"; echo "$out" | grep -A2 ERROR | head; FAIL=1; } || echo "✅ 설치 중 ERROR 없음"
has "확인 표 — 인원 변경 덧댐" "$out" "② taam_change_party_size|✅ 덧댐"
# ① invite_codes
has "anon 은 초대장을 못 읽는다" "$(ANON "select count(*) from public.invite_codes")" "permission denied"
ok "로그인한 회원은 종전처럼 읽는다(가입 흐름의 읽기가 깨지지 않게 · 좁히기는 다음 단계)" "$(AS "$M2" "select count(*) from public.invite_codes")" "2"
ok "슈퍼어드민은 그대로" "$(AS "$SU" "select count(*) from public.invite_codes")" "2"
has "anon 은 쓰기도 못 한다" "$(ANON "update public.invite_codes set used=true where code='KRM00001'")" "permission denied"
# ② 인원 변경
has "운영 행(수동 MAN-)은 거부 — PAX_CHANGE_NOT_FOR_OPS" "$(AS "$PT" "select public.taam_change_party_size('MAN-1700000000000', 1, 2000000, '줄임')")" "PAX_CHANGE_NOT_FOR_OPS"
ok "운영 행 거부 뒤 예치금 그대로" "$(Q "select general_deposit_balance + membership_deposit_balance from public.profiles where id='$PT'")" "0"
has "2차 — 회원이 금액을 적은 미결제 홀드(회차 없음 · ₩1억)는 거부 — PAX_CHANGE_NOT_PAID" "$(AS "$PT" "select public.taam_change_party_size('PAYH-fake', 1, 50000000, '줄임')")" "PAX_CHANGE_NOT_PAID"
has "2차 — 회차에 붙은 미결제 홀드도 거부" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_hold', 1, 400000, '줄임')")" "PAX_CHANGE_NOT_PAID"
ok "2차 — 거부 뒤 회원 예치금 그대로" "$(Q "select general_deposit_balance + membership_deposit_balance from public.profiles where id='$M2'")" "0"
has "2차 — 다른 매장 회차의 행은 거부 — PAX_CHANGE_BAD_ROUND" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tpX_other', 1, 0, '줄임')")" "PAX_CHANGE_BAD_ROUND"
has "2차 — 원장에 예치금 결제가 없는 옛 구매는 돈을 못 돌려준다" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_old', 1, 400000, '줄임')")" "예치금으로 낸 기록"
has "2차 — 같은 옛 구매도 ₩0 감소는 된다" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_old', 1, 0, '줄임')")" '"refund_total": 0'
has "2차 — 정가보다 비싸게 적힌 행은 정가 1인 몫(50만 − 대행비 10만)까지" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_hi', 1, 600000, '줄임')")" "REFUND_TOO_LARGE.*400000"
has "2차 — 4인 → 3인 한도 ₩400,000" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_seq', 3, 400000, '한 명')")" '"refund_total": 400000'
has "2차 — 3인 → 2인 한도도 ₩400,000(앞 감소가 남긴 대행비를 빼고 나눈다 · 종전 433,333)" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_seq', 2, 400001, '한 명')")" "REFUND_TOO_LARGE.*400000"
has "2차 — 3인 → 2인 ₩400,000 은 된다" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_seq', 2, 400000, '한 명')")" '"refund_total": 400000'
has "2차 — 2인 → 1인 한도 ₩400,000" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_seq', 1, 400001, '한 명')")" "REFUND_TOO_LARGE.*400000"
has "슈퍼어드민도 운영 행은 거부(수동 수정 RPC 로)" "$(AS "$SU" "select public.taam_change_party_size('MAN-1700000000000', 1, 0, '줄임')")" "PAX_CHANGE_NOT_FOR_OPS"
has "파트너 — 자기 구매는 못 바꾼다" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_pt', 1, 400000, '줄임')")" "FORBIDDEN_OWN"
has "파트너 — 한 명 줄이며 결제액 전부(대행비 포함)를 돌려주려 하면 REFUND_TOO_LARGE(한도 = 1인 50만 − 대행비 10만)" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_a', 1, 1000000, '줄임')")" "REFUND_TOO_LARGE.*400000"
r=$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_a', 1, 400000, '한 명 줄임')"); has "파트너 — 한도 안(₩400,000)이면 된다" "$r" '"refund_total": 400000'
ok "회원 예치금에 ₩400,000 · 티켓 1인 ₩600,000" "$(Q "select general_deposit_balance + membership_deposit_balance from public.profiles where id='$M1'")/$(Q "select party_size || '/' || price from public.tickets where purchase_id='PAYH-tp1_a'")" "400000/1/600000"
has "파트너 — 구매 30분 안이면 대행비까지(₩500,000)" "$(AS "$PT" "select public.taam_change_party_size('PAYH-tp1_new', 1, 500000, '30분 안')")" '"refund_total": 500000'
r=$(AS "$SU" "select public.taam_change_party_size('PAYH-tp1_su', 1, 1500000, '슈퍼어드민 판단')"); has "슈퍼어드민은 종전 그대로(결제액 이하면 무엇이든)" "$r" '"refund_total": 1500000'
has "회원은 못 부른다(종전 FORBIDDEN)" "$(AS "$M2" "select public.taam_change_party_size('PAYH-tp1_su', 1, 0, '회원')")" "FORBIDDEN\|ALREADY\|NO_CHANGE"
# 재실행 · 모르는 판
out2=$($P -f "$MIG" 2>&1); has "재실행 — 이미 새 판" "$out2" "이미 새 판"
echo "$out2" | grep -q "❌" && { echo "❌ 재실행 확인 표에 ❌"; FAIL=1; } || echo "✅ 재실행 ❌ 없음"
Q "create or replace function public.taam_change_party_size(p_purchase_id text, p_new_pax integer, p_refund integer, p_reason text) returns jsonb language plpgsql security definer set search_path = public as \$x\$ begin return '{}'::jsonb; end \$x\$;" >/dev/null
out3=$($P -f "$MIG" 2>&1); has "모르는 판이면 건드리지 않고 ⚠(❌ 아님 — 뒤 Edge 배포를 막지 않는다)" "$out3" "모양이 저장소와 다르다"
echo "$out3" | grep -q "❌" && { echo "❌ 모르는 판에서 ❌"; FAIL=1; } || echo "✅ 모르는 판 ❌ 없음"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
