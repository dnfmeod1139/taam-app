#!/usr/bin/env bash
# 회차 방문일 연도 채우기 · 가드 (20261019_ticket_date_year.sql) — 로컬 postgres 픽스처
cd "$(dirname "$0")/../.."
DB=t_tdy; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At -X"
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P <<'SQL' >/dev/null
create table public.ticket_products(id text primary key, rest_name text, date text, time text, status text default 'active', created_at timestamptz default now(), updated_at timestamptz);
create table public.tickets(id uuid primary key default gen_random_uuid(), ticket_product_id text, reservation_date text, status text, purchase_id text, created_at timestamptz default now());
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), restaurant_name text, visit_date text, status text, created_at timestamptz default now());
create or replace function public._taam_uid_is_super() returns boolean language sql as $$ select false $$;
do $$ begin create role authenticated; exception when others then null; end $$;
do $$ begin create role anon; exception when others then null; end $$;
grant usage on schema public to authenticated; grant select, insert, update on public.ticket_products to authenticated;
-- sql/visit_reminder.sql 의 taam_visit_date (라이브 함수)
create or replace function public.taam_visit_date(p_raw text) returns date language plpgsql immutable as $f$
declare s text; d date;
begin
  s := btrim(coalesce(p_raw, '')); if s = '' then return null; end if;
  s := btrim(regexp_replace(s, '[^0-9]+', '-', 'g'), '-');
  begin d := to_date(s, 'YYYY-MM-DD'); exception when others then return null; end;
  if d < date '2020-01-01' or d > date '2100-01-01' then return null; end if;
  return d;
end $f$;
-- 라이브 진단의 11건 모양 + 경계·충돌 사례 + 이미 연도 있는 것
insert into public.ticket_products(id, rest_name, date, time, status, created_at) values
 ('1778460624793','스시 사이토','05.15','12:00','soldout','2026-05-11T00:50:25Z'),
 ('1778473943361','타카미츠','10.03','18:00','soldout','2026-05-11T04:32:24Z'),
 ('1780061141482','키우','07.02','20:15','soldout','2026-05-29T13:25:43Z'),
 ('1780077640436','아사누마','12.28','21:00','soldout','2026-05-29T18:00:41Z'),
 ('1780800733940','시마즈','06.17','19:30','soldout','2026-06-07T02:52:19Z'),
 ('1780896503823','히가시아자부 아마모토','06.15','20:30','soldout','2026-06-08T05:28:32Z'),
 ('1780896568414','스시 이코우','06.16','20:30','soldout','2026-06-08T05:29:33Z'),
 ('legacyJan','옛 1월','01.25','19:00','soldout','2025-11-01T03:00:00Z'),
 ('late','늦게 올림','06.01','19:00','soldout','2026-06-20T03:00:00Z'),
 ('agree','구매 연도 일치','06.20','19:00','soldout','2026-05-01T03:00:00Z'),
 ('conflict','구매 연도 충돌','06.10','19:00','soldout','2026-05-01T03:00:00Z'),
 ('holdonly','홀드·취소 연도만','07.10','19:00','soldout','2026-05-01T03:00:00Z'),
 ('y2027','메이노','2027.06.03','20:00','soldout','2026-10-13T04:49:58Z');
insert into public.tickets(ticket_product_id, reservation_date, status, purchase_id) values
 ('agree','2026.06.20','active','PAYC-1'),
 ('conflict','2027.06.10','active','PAYC-2'),
 ('holdonly','2027.07.10','hold','PAYH-3'),('holdonly','2027.07.10','cancelled','PAYC-4'),
 ('1780800733940','2026.06.17','active','INV-5'),
 ('y2027','2026.06.03','active','PAYC-6');   -- 회차 2027 · 구매 2026 → ⑤ 의심
insert into public.reservation_invites(restaurant_name, visit_date, status, created_at) values
 ('옛 초대 한 해 일찍','2026.06.25','paid','2026-10-10T03:00:00Z'),
 ('정상 초대','2027.06.25','paid','2026-10-10T03:00:00Z');
SQL
out=$($P -f supabase/migrations/20261019_ticket_date_year.sql 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0" "|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')"
ok "가드 함수는 security definer · 연도 함수는 immutable" "t|i" "$($P -c "select prosecdef from pg_proc where oid='public._taam_tp_date_year()'::regprocedure")|$($P -c "select provolatile from pg_proc where oid='public._taam_mmdd_year(text,date)'::regprocedure")"
ok "6/15·16·17 은 2026 (올린 날 6/7·6/8 기준) — 2027 로 가지 않는다" "2026.06.15|2026.06.16|2026.06.17" "$($P -c "select string_agg(date, '|' order by date) from public.ticket_products where id in ('1780800733940','1780896503823','1780896568414')")"
ok "5/15 · 7/2 · 10/3 · 12/28 (5월에 올림) → 2026" "2026.05.15|2026.07.02|2026.10.03|2026.12.28" "$($P -c "select string_agg(date, '|' order by date) from public.ticket_products where id in ('1778460624793','1778473943361','1780061141482','1780077640436')")"
ok "2025-11 에 올린 1/25 → 2026.01.25 (연말 경계)" "2026.01.25" "$($P -c "select date from public.ticket_products where id='legacyJan'")"
ok "방문 뒤 30일 안에 올린 6/1(6/20 작성) → 2026 (지난 기록 입력)" "2026.06.01" "$($P -c "select date from public.ticket_products where id='late'")"
ok "확정 구매 연도와 같으면 채운다(2026.06.20)" "2026.06.20" "$($P -c "select date from public.ticket_products where id='agree'")"
ok "확정 구매 연도(2027)와 다르면 바꾸지 않고 ⚠" "06.10|1" "$($P -c "select date from public.ticket_products where id='conflict'")|$(echo "$out" | grep -c '구매 연도 충돌.*⚠ 바꾸지 않음')"
ok "홀드·취소 행의 연도는 보지 않는다(2026 으로 채움)" "2026.07.10" "$($P -c "select date from public.ticket_products where id='holdonly'")"
ok "이미 연도 있는 회차는 그대로" "2027.06.03" "$($P -c "select date from public.ticket_products where id='y2027'")"
ok "되돌리기 기록 = 채운 11건(충돌 1건은 안 채움) · batch 표시" "11|11" "$($P -c "select count(*) from public.ticket_date_year_log")|$($P -c "select count(*) from public.ticket_date_year_log where batch='20261019_backfill'")"
ok "② 연도 없는 회차 남음 = ⚠ 1건(충돌)" "1" "$(echo "$out" | grep -c '② 연도 없는 회차 남음.*⚠ 1건')"
ok "⑤ 의심: 회차와 날짜가 다른 연결 구매 · 보낸 날보다 앞선 초대" "1|1" "$(echo "$out" | grep -c '⑤ 구매·회차 날짜 다름 PAYC-6')|$(echo "$out" | grep -c '⑤ 초대 날짜가 보낸 날보다 앞섬.*옛 초대 한 해 일찍')"
# 가드 — upsert(INSERT … ON CONFLICT DO UPDATE)가 INSERT 트리거를 먼저 탄다
$P -c "insert into public.ticket_products(id, rest_name, date, time) values ('1780800733940','시마즈','06.17','19:30') on conflict (id) do update set date = excluded.date, time = excluded.time" >/dev/null
ok "가드: 옛 앱의 upsert(연도 없이 · created_at 없이) → 저장된 2026 유지 (2027 이 되지 않는다)" "2026.06.17" "$($P -c "select date from public.ticket_products where id='1780800733940'")"
$P -c "update public.ticket_products set date='06.15', status='soldout' where id='1780896503823'" >/dev/null
ok "가드: 옛 앱의 UPDATE(월·일 같음) → 옛 연도 유지" "2026.06.15" "$($P -c "select date from public.ticket_products where id='1780896503823'")"
$P -c "insert into public.ticket_products(id, rest_name, date, time) values ('conflict','구매 연도 충돌','06.10','19:00') on conflict (id) do update set date = excluded.date" >/dev/null
ok "가드: 아직 연도 없는 행의 upsert → 그 행의 올린 날(5/1) 기준 2026" "2026.06.10" "$($P -c "select date from public.ticket_products where id='conflict'")"
$P -c "update public.ticket_products set date='11.20' where id='late'" >/dev/null
ok "가드: 연도 없이 다른 날로 바꿈 → 지금 기준 다음 그 날" "$($P -c "select public._taam_mmdd_year('11.20', (now() at time zone 'Asia/Seoul')::date)")" "$($P -c "select date from public.ticket_products where id='late'")"
$P -c "insert into public.ticket_products(id, rest_name, date, time, created_at) values ('newold','옛 앱 업로드','02.14','19:00','2026-12-01T03:00:00Z')" >/dev/null
ok "가드: 옛 앱이 연도 없이 새로 올림(12월 작성 2/14) → 2027.02.14" "2027.02.14" "$($P -c "select date from public.ticket_products where id='newold'")"
$P -c "insert into public.ticket_products(id, rest_name, date, time) values ('newnew','새 앱','2027.08.01','19:00')" >/dev/null
ok "가드: 새 앱(연도 있음)은 그대로" "2027.08.01" "$($P -c "select date from public.ticket_products where id='newnew'")"
$P -c "update public.ticket_products set status='active' where id='y2027'" >/dev/null
ok "가드: 날짜를 안 건드린 저장은 그대로" "2027.06.03" "$($P -c "select date from public.ticket_products where id='y2027'")"
$P -c "set role authenticated; insert into public.ticket_products(id, rest_name, date, time) values ('1780896568414','스시 이코우','06.16','20:30') on conflict (id) do update set date = excluded.date" >/dev/null 2>&1
ok "가드: 회원 권한 세션의 upsert 도 통과 · 2026 유지 · 기록 남음(guard:keep)" "2026.06.16|1" "$($P -c "select date from public.ticket_products where id='1780896568414'")|$($P -c "select count(*) from public.ticket_date_year_log where row_id='1780896568414' and source='guard:keep'")"
ok "연도 함수: 형식 밖·빈 값·기준일 없음·없는 날은 null(날짜를 지어내지 않는다)" "||||" "$($P -c "select coalesce(public._taam_mmdd_year('abc', current_date),'')||'|'||coalesce(public._taam_mmdd_year('', current_date),'')||'|'||coalesce(public._taam_mmdd_year('13.01', current_date),'')||'|'||coalesce(public._taam_mmdd_year('06.17', null),'')||'|'||coalesce(public._taam_mmdd_year('04.31', current_date),'')")"
ok "연도 함수: 2/29 는 기준일 뒤 첫 윤년(2028)" "2028.02.29" "$($P -c "select public._taam_mmdd_year('02.29', date '2026-10-19')")"
n0=$($P -c "select count(*) from public.ticket_date_year_log where batch='20261019_backfill'")
out2=$($P -f supabase/migrations/20261019_ticket_date_year.sql 2>&1)
ok "두 번째 RUN: 오류 없음 · ❌ 0 · 채우기 기록이 더 늘지 않는다" "|0|$n0" "$(echo "$out2" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '❌')|$($P -c "select count(*) from public.ticket_date_year_log where batch='20261019_backfill'")"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
