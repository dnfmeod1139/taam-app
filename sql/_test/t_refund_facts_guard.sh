#!/bin/bash
# 회원이 쓴 환불 기록은 「완료」·「₩0 처리」 모양이 될 수 없다 (supabase/migrations/20261101_refund_facts_guard.sql) — 2026-11-01.
#   실제 결제 사실 칸 가드(20261022_card_refund_quote.sql → quote2.sql)를 올린 위에서 본다. 먼저: 로컬 pg. 실행: bash sql/_test/t_refund_facts_guard.sh
cd "$(dirname "$0")/../.."
MIG1=supabase/migrations/20261022_card_refund_quote.sql
MIG2=supabase/migrations/20261022_card_refund_quote2.sql
MIG=supabase/migrations/20261101_refund_facts_guard.sql
FAIL=0
DB=t_refundfacts; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
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
insert into public.ticket_products(id,date,agency_fee) values ('tp1','2027.09.20',100000);
SQL
$P -f "$MIG1" >/dev/null 2>&1; $P -f "$MIG2" >/dev/null 2>&1
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $3, 실제 $2)"; FAIL=1; fi; }
as(){ local u=$1; shift; $P -c "set taam.uid = '$u'; $*" 2>&1 | grep -v '^SET$'; }
crp(){ $P -c "select coalesce(extra_data->'card_refund_pending'->>'status','-')||'|'||coalesce(extra_data->'card_refund_pending'->>'amount','-')||'|'||coalesce(extra_data->'card_refund_pending'->>'set_by_role','-')||'|'||coalesce(extra_data->'card_refund_pending'->>'done_by','-')||'|'||coalesce(extra_data->'card_refund_pending'->>'toss_tx','-')||'|'||coalesce(extra_data->'card_refund_pending'->>'via','-')||'|'||coalesce(extra_data->'card_refund_pending'->>'refunded_amount','-') from public.tickets where purchase_id = '$1'"; }
mk(){ $P -c "insert into public.tickets(user_id,ticket_product_id,reservation_date,party_size,price,status,purchase_id,extra_data) values ('${2:-$M1}','tp1','2027.09.20',1,800000,'active','$1', '{\"cardPaid\":400000,\"depositUsed\":400000,\"paidBy\":\"card+deposit\",\"order_id\":\"o-$1\"}'::jsonb)" >/dev/null; }

out=$($P -f "$MIG" 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E '^ERROR|^psql:.*ERROR' | head -1)|$(echo "$out" | grep -c '❌')"
ok "④ ⑤ 정보 — 아직 줄 없음" "0|0" "$(echo "$out" | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')|$(echo "$out" | grep '⑤' | awk -F'|' '{print $NF}' | tr -d ' ')"

# ── A. 카드 환불 대기 ──
mk PAYH-A1
as $M1 "update public.tickets set status='cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount',400000,'status','done','done_by','$SU','toss_tx','fake-tx','via','toss_api','refunded_amount',400000,'refunded_at','2026-11-01T00:00:00Z','requested_at','2026-11-01T00:00:00Z')) where purchase_id='PAYH-A1'" >/dev/null
ok "A1 회원 취소에 위조한 「완료」 → pending · 완료 칸 지움 · set_by_role member · 금액 그대로" "$(crp PAYH-A1)" "pending|400000|member|-|-|-|-"
ok "A1 요청 시각·주문은 남긴다" "$($P -c "select (extra_data->'card_refund_pending' ? 'requested_at')::text from public.tickets where purchase_id='PAYH-A1'")" "true"
mk PAYH-A2
as $M1 "update public.tickets set status='cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount',300000,'order_id','o-PAYH-A2','reason','D-31','requested_at','2026-11-01T00:00:00Z','status','pending')) where purchase_id='PAYH-A2'" >/dev/null
ok "A2 앱이 쓰는 정상 대기 → 그대로 + set_by_role member" "$(crp PAYH-A2)|$($P -c "select extra_data->'card_refund_pending'->>'order_id' from public.tickets where purchase_id='PAYH-A2'")" "pending|300000|member|-|-|-|-|o-PAYH-A2"
as $M1 "update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_pending,status}', '\"done\"') where purchase_id='PAYH-A2'" >/dev/null
ok "A3 취소 뒤 회원이 「완료」로 바꾸려 해도 pending" "$(crp PAYH-A2)" "pending|300000|member|-|-|-|-"
as $SU "update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_pending}', (extra_data->'card_refund_pending') || jsonb_build_object('status','done','refunded_at','2026-11-01T01:00:00Z','done_by','$SU','via','manual','refunded_amount',300000)) where purchase_id='PAYH-A2'" >/dev/null
ok "A4 슈퍼어드민 「완료 표시」(금액 그대로) → done" "$(crp PAYH-A2)" "done|300000|member|$SU|-|manual|300000"
mk PAYH-A5
as $M1 "update public.tickets set status='cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount',250000,'status','pending')) where purchase_id='PAYH-A5'" >/dev/null
as "" "update public.tickets set extra_data = jsonb_set(extra_data, '{card_refund_pending}', (extra_data->'card_refund_pending') || jsonb_build_object('status','done','via','toss_api','toss_tx','tx-1','done_by','$SU','refunded_amount',250000)) where purchase_id='PAYH-A5'" >/dev/null
ok "A5 서버(Edge toss-card-refund 모양) → done · 토스 거래키" "$(crp PAYH-A5)" "done|250000|member|$SU|tx-1|toss_api|250000"
as $M1 "update public.tickets set extra_data = extra_data || '{\"memo\":\"x\"}'::jsonb where purchase_id='PAYH-A5'" >/dev/null
ok "A6 완료된 뒤 회원의 다른 칸 갱신 → 완료 그대로" "$(crp PAYH-A5)" "done|250000|member|$SU|tx-1|toss_api|250000"
mk PAYH-A7
as $RA "update public.tickets set status='cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount',400000,'status','done','via','manual','done_by','$RA')) where purchase_id='PAYH-A7'" >/dev/null
ok "A7 매장 어드민 세션의 위조 「완료」 → pending" "$(crp PAYH-A7)" "pending|400000|member|-|-|-|-"
# 서버 함수(definer)를 회원이 부르는 모양 — 패키지 취소가 첫 줄에 대기를 적는다(auth.uid() = 회원)
$P -c "create or replace function public._t_pkg_cancel(p text) returns void language plpgsql security definer set search_path=public as \$f\$
  begin update public.tickets set status='cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount',500000,'status','pending','pkg_group','G1','reason','패키지 취소')) where purchase_id = p; end \$f\$" >/dev/null
mk PAYH-A8
as $M1 "select public._t_pkg_cancel('PAYH-A8')" >/dev/null
ok "A8 패키지 취소 모양(definer · 회원 호출) → pending · pkg_group 그대로" "$(crp PAYH-A8)|$($P -c "select extra_data->'card_refund_pending'->>'pkg_group' from public.tickets where purchase_id='PAYH-A8'")" "pending|500000|member|-|-|-|-|G1"
mk PAYH-A9
r=$(as $M1 "update public.tickets set status='cancelled', extra_data = extra_data || '{\"card_refund_pending\":\"done\"}'::jsonb where purchase_id='PAYH-A9'")
ok "A9 객체가 아닌 대기 → 오류 없이 통과(취소는 된다)" "$(echo "$r" | grep -c ERROR)|$($P -c "select status from public.tickets where purchase_id='PAYH-A9'")" "0|cancelled"
mk PAYH-A10
as $SU "update public.tickets set status='cancelled', extra_data = extra_data || jsonb_build_object('card_refund_pending', jsonb_build_object('amount',400000,'status','done','via','manual','done_by','$SU')) where purchase_id='PAYH-A10'" >/dev/null
ok "A10 슈퍼어드민이 바로 「완료」로 만든 대기 → done · superadmin" "$(crp PAYH-A10)" "done|400000|superadmin|$SU|-|manual|-"

# ── B. ₩0·음수 환불 줄 ──
$P -c "insert into public.deposit_transactions(user_id,change_type,amount,metadata) values ('$M1','ticket_purchase',-400000,'{\"purchase_id\":\"PAYH-A2\"}')" >/dev/null
r=$(as $M1 "insert into public.deposit_transactions(user_id,change_type,amount,metadata) values ('$M1','ticket_refund',0,'{\"purchase_id\":\"PAYH-A2\",\"refund_type\":\"returned\",\"agency_held\":0,\"card_refund_pending\":5000000}')")
ok "B1 회원 ₩0 ticket_refund → LEDGER_REFUND_NONPOSITIVE" "$(echo "$r" | grep -c LEDGER_REFUND_NONPOSITIVE)" "1"
r=$(as $M1 "insert into public.deposit_transactions(user_id,change_type,amount,metadata) values ('$M1','ticket_refund',-1,'{\"purchase_id\":\"PAYH-A2\",\"refund_type\":\"returned\"}')")
ok "B2 회원 음수 ticket_refund → 거절" "$(echo "$r" | grep -c LEDGER_REFUND_NONPOSITIVE)" "1"
r=$(as $M1 "insert into public.deposit_transactions(user_id,change_type,amount,metadata) values ('$M1','ticket_refund',100000,'{\"purchase_id\":\"PAYH-A2\",\"cancel_refund\":true}')")
ok "B3 회원 양수 ticket_refund(낸 돈 안) → 이 가드는 통과" "$(echo "$r" | grep -c ERROR)" "0"
r=$(as $SU "insert into public.deposit_transactions(user_id,change_type,amount,metadata) values ('$M1','ticket_refund',0,'{\"purchase_id\":\"PAYH-A2\",\"refund_type\":\"penalty\",\"processed_by\":\"super_admin\"}')")
ok "B4 슈퍼어드민 「환불 없음 처리」 ₩0 → 그대로" "$(echo "$r" | grep -c ERROR)" "0"
r=$(as "" "insert into public.deposit_transactions(user_id,change_type,amount,metadata) values ('$M1','ticket_refund',0,'{\"purchase_id\":\"PAYH-A5\"}')")
ok "B5 서버(uid 없음) ₩0 → 그대로" "$(echo "$r" | grep -c ERROR)" "0"
r=$(as $M1 "insert into public.deposit_transactions(user_id,change_type,amount,metadata) values ('$M1','ticket_purchase',-1000,'{\"purchase_id\":\"PAYH-A1\"}')")
ok "B6 회원 음수 ticket_purchase(다른 유형) → 이 가드와 무관" "$(echo "$r" | grep -c LEDGER_REFUND_NONPOSITIVE)" "0"

out2=$($P -f "$MIG" 2>&1)
ok "재실행 안전 · ❌ 0 · ④ 0(위조 완료는 남지 않았다) · ⑤ 1(서버 ₩0 줄 · 처리 표시 없음)" "0|0|1" "$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')|$(echo "$out2" | grep '⑤' | awk -F'|' '{print $NF}' | tr -d ' ')"
ok "트리거 둘 · 순서(대기 정리가 결제 사실 칸 가드 앞)" "2|trg_taam_guard_ticket_crp_member" "$($P -c "select count(*) from pg_trigger where tgname in ('trg_taam_guard_ticket_crp_member','trg_taam_guard_ledger_refund_nonpos') and not tgisinternal")|$($P -c "select tgname from pg_trigger where tgrelid='public.tickets'::regclass and tgname in ('trg_taam_guard_ticket_crp_member','trg_taam_guard_ticket_payfacts') order by tgname limit 1")"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
