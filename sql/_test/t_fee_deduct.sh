#!/bin/bash
# 예치금 「관리 차감」 → 연회비 기록 트리거 회귀 — 2026-10-18. 먼저: 로컬 pg. 실행: bash sql/_test/t_fee_deduct.sh
#   metadata.membership_fee 가 있는 admin_deduct 줄만 membership_fees 에 적힌다 · 실패하면 차감도 취소(FEE_RECORD_FAILED) · 중복 없음 · 부여·플래그 없음은 무관.
cd "$(dirname "$0")/../.."
DB=t_feededuct; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
A=a1000000-0000-4000-8000-000000000011; B=a1000000-0000-4000-8000-000000000012; G=a1000000-0000-4000-8000-000000000013; SU=a1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
insert into auth.users values ('$A'),('$B'),('$G'),('$SU');
create table public.profiles(id uuid primary key, display_name text, membership_tier text);
insert into public.profiles values ('$A','김티','T'),('$B','박엠','M'),('$G','게스트','A'),('$SU','Super Admin','M');
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint,
  description text, payment_id uuid, metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now());
grant usage on schema public to authenticated; grant usage on schema auth to authenticated;
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P -f supabase/migrations/20261015_membership_fees.sql >/dev/null 2>&1
out=$($P -f supabase/migrations/20261018_fee_deduct_record.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
ok "확인 표 ④ 는 ⚠ (픽스처엔 trg_sync_split_balance 가 없다 · 라이브엔 있다)" "1" "$(echo "$out" | grep -c '⚠ trg_sync_split_balance')"
ins(){ $P -c "set taam.uid='$SU'; set taam.super='1'; insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata) values ('$1','membership','$2',$3,0,'$4','$5'::jsonb) returning id" 2>&1; }
TODAY=$($P -c "select (now() at time zone 'Asia/Seoul')::date")
# ── ① 플래그 true — 차감 금액 · KST 오늘 · 프로필 등급 · 설명 → 메모 · source_ref = 원장 id ──
T1=$(ins $A admin_deduct -630000 '연회비 2년차' '{"granted_by":"'$SU'","membership_fee":true}')
ok "차감 + membership_fee:true → 연회비 기록 1줄 (금액 630,000 · deposit · 등급 T(프로필) · 오늘 KST · 메모=설명 · source deposit_deduct · ref=원장 id · created_by=granted_by)" "1|630000|deposit|T|$TODAY|연회비 2년차|deposit_deduct|$T1|$SU" \
   "$($P -c "select count(*)||'|'||max(amount_krw)||'|'||max(method)||'|'||max(tier)||'|'||max(paid_at)||'|'||max(note)||'|'||max(source)||'|'||max(source_ref)||'|'||max(created_by::text) from public.membership_fees where user_id='$A'")"
# ── ② 플래그 없음 · false · null → 아무것도 안 적는다 ──
ins $A admin_deduct -1000 '그냥 차감' '{}' >/dev/null; ins $A admin_deduct -1000 '플래그 false' '{"membership_fee":false}' >/dev/null; ins $A admin_deduct -1000 '플래그 null' '{"membership_fee":null}' >/dev/null
ok "플래그 없음·false·null 차감 3건 → 기록 그대로 1줄" "1|4" "$($P -c "select (select count(*) from public.membership_fees where user_id='$A')||'|'||(select count(*) from public.deposit_transactions where user_id='$A')")"
# ── ③ 부여(양수)에 플래그 → FEE_RECORD_FAILED 로 원장 줄도 안 들어간다 ──
r=$(ins $B admin_grant 500000 '부여인데 플래그' '{"membership_fee":true}')
ok "부여(+)에 플래그 → FEE_RECORD_FAILED · 원장 줄 0 · 기록 0" "1|0|0" "$(echo "$r" | grep -c 'FEE_RECORD_FAILED')|$($P -c "select count(*) from public.deposit_transactions where user_id='$B'")|$($P -c "select count(*) from public.membership_fees where user_id='$B'")"
# ── ④ 객체 플래그 — 금액·납부일·등급·기간·메모·by 를 그대로 ──
T4=$(ins $B admin_deduct -1125000 '설명' '{"membership_fee":{"amount_krw":1125000,"paid_at":"2026-10-21","tier":"M","period_from":"2026-10-21","period_to":"2027-10-20","note":"3년차 연회비","by":"'$A'"}}')
ok "객체 플래그 → 금액·납부일·등급·기간·메모 그대로 · by 는 **호출자(슈퍼어드민)** — metadata 의 by 는 믿지 않는다" "1125000|2026-10-21|M|2026-10-21|2027-10-20|3년차 연회비|$SU" \
   "$($P -c "select amount_krw||'|'||paid_at||'|'||tier||'|'||period_from||'|'||period_to||'|'||note||'|'||created_by::text from public.membership_fees where source_ref='$T4'")"
# ── ④-b 서버 호출(auth.uid() null · SQL Editor·크론·service_role)은 통과하고 by 를 받는다 ──
T4b=$($P -c "set taam.uid=''; set taam.super='0'; insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata) values ('$B','membership','admin_deduct',-1000,0,'서버','{\"membership_fee\":{\"by\":\"$A\"}}'::jsonb) returning id" 2>&1)
ok "서버 호출(uid 없음) → 기록 1줄 · by = metadata.by" "1|$A" "$($P -c "select count(*)||'|'||max(created_by::text) from public.membership_fees where source_ref='$T4b'")"
# ── ④-c 회원 세션(비슈퍼어드민)이 플래그를 실으면 FEE_RECORD_FAILED(슈퍼어드민만) · 원장 줄도 안 들어간다 — RPC 가 음수 항목 change_type 을 안 보는 옛 구멍이 기록 위조로 이어지지 않게 ──
n0=$($P -c "select count(*) from public.deposit_transactions where user_id='$A'")
r=$($P -c "set taam.uid='$A'; set taam.super='0'; insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata) values ('$A','membership','admin_deduct',-1,0,'위조','{\"membership_fee\":{\"amount_krw\":1125000,\"tier\":\"M\",\"by\":\"$SU\"}}'::jsonb)" 2>&1)
ok "회원 세션 + 플래그 → FEE_RECORD_FAILED(슈퍼어드민만) · 원장 줄 수 그대로 · 기록 1,125,000 없음" "1|$n0|0" "$(echo "$r" | grep -c 'FEE_RECORD_FAILED.*슈퍼어드민만')|$($P -c "select count(*) from public.deposit_transactions where user_id='$A'")|$($P -c "select count(*) from public.membership_fees where user_id='$A' and amount_krw=1125000")"
# ── ④-d 외화 차감 — 원장 metadata 의 fx_currency/fx_amount(음수)가 기록에 양수로 함께 · mf 의 값이 우선 · 모르는 통화는 비움 ──
T4d=$(ins $B admin_deduct -408195 '송금 $300' '{"fx_currency":"USD","fx_amount":-300,"fx_rate":1360.65,"membership_fee":true}')
T4e=$(ins $B admin_deduct -1000 'x' '{"fx_currency":"EUR","fx_amount":-1,"membership_fee":{"fx_currency":"JPY","fx_amount":"100000"}}')
ok "외화 차감 → fx_currency USD · fx_amount 300.00 · mf 값 우선(JPY 100000) · 금액은 원화 그대로" "USD|300.00|408195|JPY|100000.00" "$($P -c "select fx_currency||'|'||fx_amount||'|'||amount_krw from public.membership_fees where source_ref='$T4d'")|$($P -c "select fx_currency||'|'||fx_amount from public.membership_fees where source_ref='$T4e'")"
# ── ⑤ 잘못된 납부일 → 실패 · 원장도 롤백 ──
n0=$($P -c "select count(*) from public.deposit_transactions where user_id='$B'")
r=$(ins $B admin_deduct -1000 'x' '{"membership_fee":{"paid_at":"어제"}}')
ok "납부일이 날짜가 아니면 FEE_RECORD_FAILED · 원장 줄 수 그대로" "1|$n0" "$(echo "$r" | grep -c 'FEE_RECORD_FAILED')|$($P -c "select count(*) from public.deposit_transactions where user_id='$B'")"
# ── ⑥ 게스트(A) 등급은 tier null ──
T6=$(ins $G admin_deduct -300000 '게스트' '{"membership_fee":true}')
ok "프로필 등급 A → tier null (M/T 만)" "null" "$($P -c "select coalesce(tier,'null') from public.membership_fees where source_ref='$T6'")"
# ── ⑦ 표가 없으면 차감도 취소 ──
$P -c "alter table public.membership_fees rename to membership_fees_hidden" >/dev/null
n0=$($P -c "select count(*) from public.deposit_transactions where user_id='$A'")
r=$(ins $A admin_deduct -1000 'x' '{"membership_fee":true}')
$P -c "alter table public.membership_fees_hidden rename to membership_fees" >/dev/null
ok "membership_fees 가 없으면 FEE_RECORD_FAILED(표가 없다) · 차감도 안 들어감" "1|$n0" "$(echo "$r" | grep -c 'FEE_RECORD_FAILED.*표가 없다')|$($P -c "select count(*) from public.deposit_transactions where user_id='$A'")"
# ── ⑧ 같은 원장 줄로 다시 돌려도 두 번 안 적힌다 (트리거 함수 재호출 흉내: 같은 id 의 재INSERT 는 PK 라 불가 → 함수를 직접 두 번 부른 것과 같은 source_ref 검사) ──
$P -c "insert into public.membership_fees(user_id, paid_at, amount_krw, method, source, source_ref) select user_id, paid_at, amount_krw, method, source, source_ref from public.membership_fees where source_ref='$T1' on conflict do nothing" >/dev/null 2>&1
ok "트리거 안 중복 검사 — source_ref 가 이미 있으면 건너뛴다 (함수 문장 포함)" "1" "$($P -c "select count(*) from pg_proc where oid = to_regproc('public.taam_fee_from_deduct') and prosrc like '%source_ref = new.id::text%'")"
# ── ⑨ 회원 세션이 직접 넣는 것은 종전대로 RLS 몫 — 트리거는 security definer 라 RLS 를 지나지만, 원장 INSERT 자체가 회원에게 막혀 있다(라이브 deposit_tx_insert_server) ──
ok "트리거는 security definer · AFTER INSERT 한 개" "t|1" "$($P -c "select prosecdef from pg_proc where oid = to_regproc('public.taam_fee_from_deduct')")|$($P -c "select count(*) from pg_trigger where tgname='trg_taam_fee_from_deduct' and not tgisinternal")"
# ── ⑩ 금액 override 0 → 실패 ──
r=$(ins $A admin_deduct -1000 'x' '{"membership_fee":{"amount_krw":0}}')
ok "amount_krw 0 → FEE_RECORD_FAILED" "1" "$(echo "$r" | grep -c 'FEE_RECORD_FAILED')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
