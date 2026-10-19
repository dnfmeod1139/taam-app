#!/usr/bin/env bash
# 회차 방문일 연도 채우기 · 가드 (20261019_ticket_date_year.sql) — 로컬 postgres 픽스처
cd "$(dirname "$0")/../.."
DB=t_tdy; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At -X"
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P <<'SQL' >/dev/null
create table public.ticket_products(id text primary key, rest_name text, date text, time text, status text default 'active', created_at timestamptz default now(), updated_at timestamptz);
create table public.tickets(id uuid primary key default gen_random_uuid(), ticket_product_id text, reservation_date text, status text, created_at timestamptz default now());
create or replace function public._taam_uid_is_super() returns boolean language sql as $$ select false $$;
do $$ begin create role authenticated; exception when others then null; end $$;
do $$ begin create role anon; exception when others then null; end $$;
-- 라이브 진단의 11건 모양 + 구매 행 연도가 다른 것 하나 + 이미 연도 있는 것
insert into public.ticket_products(id, rest_name, date, time, status, created_at) values
 ('1778460624793','스시 사이토','05.15','12:00','soldout','2026-05-11T00:50:25Z'),
 ('1778473943361','타카미츠','10.03','18:00','soldout','2026-05-11T04:32:24Z'),
 ('1780077640436','아사누마','12.28','21:00','soldout','2026-05-29T18:00:41Z'),
 ('1780800733940','시마즈','06.17','19:30','soldout','2026-06-07T02:52:19Z'),
 ('1780896503823','히가시아자부 아마모토','06.15','20:30','soldout','2026-06-08T05:28:32Z'),
 ('1780896568414','스시 이코우','06.16','20:30','soldout','2026-06-08T05:29:33Z'),
 ('legacyJan','옛 1월','01.25','19:00','soldout','2025-11-01T03:00:00Z'),
 ('late','늦게 올림','06.01','19:00','soldout','2026-06-20T03:00:00Z'),
 ('withbuy','구매 연도 우선','03.10','19:00','soldout','2026-05-01T03:00:00Z'),
 ('y2027','메이노','2027.06.03','20:00','soldout','2026-10-13T04:49:58Z');
insert into public.tickets(ticket_product_id, reservation_date, status) values ('withbuy','2027.03.10','active'),('withbuy','2027.03.10','cancelled'),('1780800733940','2026.06.17','active');
SQL
out=$($P -f supabase/migrations/20261019_ticket_date_year.sql 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
ok "연도 없는 회차 0" "0" "$($P -c "select count(*) from public.ticket_products where date !~ '^\d{4}'")"
ok "6/15·16·17 은 2026 (올린 날 6/7·6/8 기준) — 2027 로 가지 않는다" "2026.06.15|2026.06.16|2026.06.17" "$($P -c "select string_agg(date, '|' order by date) from public.ticket_products where id in ('1780800733940','1780896503823','1780896568414')")"
ok "5/15 · 10/3 · 12/28 (5월에 올림) → 2026" "2026.05.15|2026.10.03|2026.12.28" "$($P -c "select string_agg(date, '|' order by date) from public.ticket_products where id in ('1778460624793','1778473943361','1780077640436')")"
ok "2025-11 에 올린 1/25 → 2026.01.25 (연말 경계)" "2026.01.25" "$($P -c "select date from public.ticket_products where id='legacyJan'")"
ok "방문 뒤 30일 안에 올린 6/1(6/20 작성) → 2026 (지난 기록 입력)" "2026.06.01" "$($P -c "select date from public.ticket_products where id='late'")"
ok "구매 행의 연도가 있으면 그것(2027.03.10 · 올린 날 기준이면 2026)" "2027.03.10" "$($P -c "select date from public.ticket_products where id='withbuy'")"
ok "이미 연도 있는 회차는 그대로" "2027.06.03" "$($P -c "select date from public.ticket_products where id='y2027'")"
ok "되돌리기 기록 9건(바뀐 것만) · 출처 표시" "9|1" "$($P -c "select count(*) from public.ticket_date_year_log")|$($P -c "select count(*) from public.ticket_date_year_log where row_id='withbuy' and source='구매 행 연도' and old_date='03.10' and new_date='2027.03.10'")"
# 가드
$P -c "update public.ticket_products set date='06.17', status='soldout' where id='1780800733940'" >/dev/null
ok "가드: 옛 앱이 연도 없이 다시 저장(월·일 같음) → 옛 연도 유지" "2026.06.17" "$($P -c "select date from public.ticket_products where id='1780800733940'")"
$P -c "update public.ticket_products set date='11.20' where id='1780800733940'" >/dev/null
ok "가드: 연도 없이 다른 날로 바꿈 → 지금 기준 다음 그 날" "$($P -c "select public._taam_mmdd_year('11.20', (now() at time zone 'Asia/Seoul')::date)")" "$($P -c "select date from public.ticket_products where id='1780800733940'")"
$P -c "insert into public.ticket_products(id, rest_name, date, time, created_at) values ('newold','옛 앱 업로드','02.14','19:00','2026-12-01T03:00:00Z')" >/dev/null
ok "가드: 옛 앱이 연도 없이 새로 올림(12월 작성 2/14) → 2027.02.14" "2027.02.14" "$($P -c "select date from public.ticket_products where id='newold'")"
$P -c "insert into public.ticket_products(id, rest_name, date, time) values ('newnew','새 앱','2027.08.01','19:00')" >/dev/null
ok "가드: 새 앱(연도 있음)은 그대로" "2027.08.01" "$($P -c "select date from public.ticket_products where id='newnew'")"
$P -c "update public.ticket_products set status='active' where id='y2027'" >/dev/null
ok "가드: 날짜를 안 건드린 저장은 그대로" "2027.06.03" "$($P -c "select date from public.ticket_products where id='y2027'")"
ok "연도 함수: 형식 밖·빈 값은 null(날짜를 지어내지 않는다)" "||" "$($P -c "select coalesce(public._taam_mmdd_year('abc', current_date),'')||'|'||coalesce(public._taam_mmdd_year('', current_date),'')||'|'||coalesce(public._taam_mmdd_year('13.01', current_date),'')")"
out2=$($P -f supabase/migrations/20261019_ticket_date_year.sql 2>&1)
ok "두 번째 RUN: 오류 없음 · ❌ 0 · 더 바꾼 것 없음(기록 그대로 9)" "|0|9" "$(echo "$out2" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '❌')|$($P -c "select count(*) from public.ticket_date_year_log")"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
