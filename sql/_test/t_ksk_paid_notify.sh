#!/bin/bash
# 정산·링크 결제 완료 → 슈퍼어드민 알림 회귀 — 2026-10-13. 먼저: 로컬 pg. 실행: bash sql/_test/t_ksk_paid_notify.sh
cd "$(dirname "$0")/../.."
DB=t_kskpaid; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU1=a1000000-0000-4000-8000-000000000001; SU2=a1000000-0000-4000-8000-000000000002; M=a1000000-0000-4000-8000-000000000011
EV=c1000000-0000-4000-8000-000000000001; TM=c1000000-0000-4000-8000-000000000002
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
create table public.profiles(id uuid primary key, role text);
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.kashikiri_events(id uuid primary key, venue_name text, event_date date, event_time time);
create table public.kashikiri_teams(id uuid primary key, event_id uuid, pax int default 1);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, label text, user_id uuid, amount_krw integer, status text default 'pending', payer_name text, pay_currency text default 'KRW', pay_amount numeric(14,2), link_invite boolean default false);
insert into auth.users values ('$SU1'),('$SU2'),('$M');
insert into public.profiles values ('$SU1','super_admin'), ('$SU2','superadmin'), ('$M','member');
insert into public.kashikiri_events values ('$EV','Takiya','2027-03-20','19:30');
insert into public.kashikiri_teams values ('$TM','$EV',2);
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
out=$($P -f supabase/migrations/20261013_kashikiri_paid_notify.sql 2>&1)
ok "마이그레이션 오류 없음 · ✅ 3 · ⚠ 1(푸시 설정 없음) · ❌ 0" "|3|1|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '⚠')|$(echo "$out" | grep -c '❌')"
$P -c "insert into public.kashikiri_charges(id, event_id, team_id, label, amount_krw, payer_name, pay_currency, pay_amount) values ('d1000000-0000-4000-8000-000000000001','$EV','$TM','Trina',2321555,'Trina Chin','USD',1679.85)" >/dev/null
ok "pending 상태에선 알림 없음" "0" "$($P -c "select count(*) from public.notifications")"
$P -c "update public.kashikiri_charges set status='paid' where id='d1000000-0000-4000-8000-000000000001'" 2>&1 | grep -i "error" | head -1
ok "paid 로 바뀌면 슈퍼어드민 2명에게 1줄씩 (회원 제외)" "2|0" "$($P -c "select count(*) from public.notifications where type='kashikiri_paid' and user_id in ('$SU1','$SU2')")|$($P -c "select count(*) from public.notifications where user_id='$M'")"
ok "제목 정산 결제 완료 · 본문 매장·날짜·이름·달러·원화" "💳 정산 결제 완료|Takiya 2027.03.20 19:30 · Trina Chin · \$1,679.85 (₩2,321,555)" "$($P -c "select title from public.notifications limit 1")|$($P -c "select body from public.notifications limit 1")"
$P -c "update public.kashikiri_charges set status='paid', payer_name='다시' where id='d1000000-0000-4000-8000-000000000001'" >/dev/null
ok "paid → paid 재갱신은 알림 없음" "2" "$($P -c "select count(*) from public.notifications")"
$P -c "insert into public.kashikiri_charges(id, event_id, team_id, label, amount_krw, pay_currency, link_invite) values ('d1000000-0000-4000-8000-000000000002','$EV','$TM','K様',900000,'KRW',true); update public.kashikiri_charges set status='paid' where id='d1000000-0000-4000-8000-000000000002'" >/dev/null
ok "링크 초대 · 원화 · 이름 없으면 label" "🔗 링크 초대 결제 완료|Takiya 2027.03.20 19:30 · K様 · ₩900,000" "$($P -c "select title from public.notifications where payload->>'charge_id'='d1000000-0000-4000-8000-000000000002' limit 1")|$($P -c "select body from public.notifications where payload->>'charge_id'='d1000000-0000-4000-8000-000000000002' limit 1")"
ok "푸시 함수: 설정 없으면 no_config (예외 아님)" "no_config" "$($P -c "select public.taam_admin_push('t','b')->>'reason'")"
ok "payload 에 charge_id·link_invite" "t" "$($P -c "select (payload->>'link_invite')::boolean from public.notifications where payload->>'charge_id'='d1000000-0000-4000-8000-000000000002' limit 1")"
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
