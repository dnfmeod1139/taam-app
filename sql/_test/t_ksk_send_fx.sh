#!/bin/bash
# 정산 링크 외화 입력 회귀 — 2026-09-29. 먼저: 로컬 pg. 실행: bash sql/_test/t_ksk_send_fx.sh
cd "$(dirname "$0")/../.."
DB=t_ksksendfx; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; EV=e1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable as \$\$ select u = '$SU'::uuid \$\$;
create or replace function public.taam_kashikiri_token() returns text language sql as \$\$ select md5(random()::text || clock_timestamp()::text) \$\$;
create table public.kashikiri_events(id uuid primary key, event_date date, fx_rate numeric, fx_usd numeric, total_krw int);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, guest_id uuid, label text, user_id uuid, payer_phone text,
  amount_krw int, amount_jpy int, pay_currency text, pay_fx numeric, pay_amount numeric(14,2), expires_at timestamptz, status text default 'pending', token text default public.taam_kashikiri_token());
insert into public.kashikiri_events values ('$EV','2027-03-20', 9.1, 1382, null);
SQL
out=$($P -f supabase/migrations/20260929_kashikiri_send_fx_input.sql 2>&1); FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
ok "마이그레이션 ✅" "1|" "$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -E '^ERROR')"
S="select set_config('taam.uid','$SU',false);"
$P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Trina\",\"currency\":\"USD\",\"pay_amount\":1680,\"amount_krw\":2321760}]'::jsonb)" >/dev/null
ok "달러 1680 입력 → 승인 \$1680.00 · 원화 round(1680×1382)=2,321,760" "1680.00|2321760|USD|1382" "$($P -c "select pay_amount||'|'||amount_krw||'|'||pay_currency||'|'||pay_fx::int from public.kashikiri_charges where label='Trina'")"
$P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Sato\",\"currency\":\"JPY\",\"pay_amount\":99999.6}]'::jsonb)" >/dev/null
ok "엔 99999.6 입력 → 정수 ¥100,000 · amount_jpy 같음 · 원화 910,000" "100000.00|100000|910000" "$($P -c "select pay_amount||'|'||amount_jpy||'|'||amount_krw from public.kashikiri_charges where label='Sato'")"
$P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Kim\",\"currency\":\"KRW\",\"amount_krw\":500000}]'::jsonb)" >/dev/null
ok "원화 줄은 종전 그대로" "500000.00|500000|KRW" "$($P -c "select pay_amount||'|'||amount_krw||'|'||pay_currency from public.kashikiri_charges where label='Kim'")"
$P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Old\",\"currency\":\"USD\",\"amount_krw\":2321555}]'::jsonb)" >/dev/null
ok "외화 입력 없는 달러 줄은 종전 나눗셈 (2321555/1382=1679.85)" "1679.85|2321555" "$($P -c "select pay_amount||'|'||amount_krw from public.kashikiri_charges where label='Old'")"
r=$($P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Zero\",\"currency\":\"USD\",\"pay_amount\":0,\"amount_krw\":0}]'::jsonb)" 2>&1)
ok "0 이하 → 거부" "1" "$(echo "$r" | grep -c '0 이하')"
$P -c "update public.kashikiri_events set total_krw = 2321760 + 910000 + 500000 + 2321555 + 138200 where id='$EV'" >/dev/null
$P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Last\",\"currency\":\"USD\",\"pay_amount\":100}]'::jsonb)" >/dev/null
ok "총액 대조는 서버가 만든 원화(100×1382=138,200)로 맞는다" "1" "$($P -c "select count(*) from public.kashikiri_charges where label='Last' and amount_krw=138200")"
$P -c "update public.kashikiri_events set total_krw = 99999999 where id='$EV'" >/dev/null
$P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Partial\",\"currency\":\"KRW\",\"amount_krw\":1000}]'::jsonb)" >/dev/null
ok "총액에 모자라는 부분 발송은 통과 (나눠 보내기)" "1" "$($P -c "select count(*) from public.kashikiri_charges where label='Partial'")"
$P -c "update public.kashikiri_events set total_krw = 100 where id='$EV'" >/dev/null
r=$($P -c "$S select count(*) from public.taam_kashikiri_send('$EV', '[{\"label\":\"Over\",\"currency\":\"KRW\",\"amount_krw\":1000}]'::jsonb)" 2>&1)
ok "총액을 넘기면 거부" "1" "$(echo "$r" | grep -c '총액을 넘습니다')"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="; exit $FAIL
