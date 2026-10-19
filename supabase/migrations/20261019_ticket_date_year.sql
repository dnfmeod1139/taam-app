-- ═══════════════════════════════════════════════════════════════
-- 회차 방문일에 연도를 채우고, 연도 없는 날짜가 다시는 저장되지 않게 (2026-10-19)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 한 줄도 없어야 정상(⚠ 는 사람이 볼 것).
-- 왜: 「티켓 캘린더 2027년 6월에 2026년 6월 티켓(시마즈 6/17 · 스시 이코우 6/16 · 히가시아자부 아마모토 6/15)이 또 보인다 — 올린 적 없다」.
--     2026.07 전에 올린 회차 11개가 연도 없이 'MM.DD' 로 저장돼 있었고(진단 20261019_diag_yearless_dates.sql · 전부 2026-05-11 ~ 06-08 작성 · 매진),
--     앱이 연도 없는 날짜를 「오늘 기준 120일 넘게 지났으면 내년」으로 읽어 2027 로 옮겼다(5/15 스시 사이토는 9/12 부터 2027년 5월에도 떠 있었다).
--     날이 갈수록 더 옮겨 간다(7월 회차는 10월 말, 9·10월 회차는 1~2월). 회원 화면은 「180일」 규칙이라 12월 중순부터 지난 회차가 2027년 회차로 되살아날 차례였다.
--     구매·초대·수동 기록은 전부 연도가 있다(진단) — 회차 표만의 문제다.
-- 무엇:
--   ① _taam_mmdd_year(p_mmdd, p_anchor): 'MM.DD' → 「기준일 30일 전 이후 첫 그 날」의 'YYYY.MM.DD'. 기준일이 없으면 null(지어내지 않는다 · immutable).
--      2/29 는 기준일 뒤 첫 윤년. 회차는 방문 **전에** 올리므로 기준일 = 올린 날(created_at, KST). 앱 _tkInferYear 와 같은 식.
--   ② 채우기: 연도 없는 회차마다 ① (created_at 기준). 그 회차를 산 확정 구매 행(홀드·취소 제외)의 연도와 **다르면 바꾸지 않고 ⚠**(사람이 본다).
--      옛값은 ticket_date_year_log 에 남긴다(되돌리기용 · 슈퍼어드민만 읽기). 되돌리기: 트리거를 끄고
--      update ticket_products tp set date = l.old_date from ticket_date_year_log l where l.batch = '20261019_backfill' and l.row_id = tp.id and tp.date = l.new_date;
--   ③ 가드 trg_taam_tp_date_year(BEFORE INSERT/UPDATE OF date · security definer): 연도 없는 date 가 들어오면
--      · 같은 id 의 저장된 날짜에 연도가 있고 월·일이 같으면 그 연도(옛 앱의 다시 저장 — **upsert 는 INSERT 트리거를 먼저 탄다**:
--        INSERT 가지에서 지금 기준으로 연도를 지으면 '06.17' 이 2027.06.17 이 되어 ON CONFLICT 의 UPDATE 로 그대로 들어간다 · 적대 리뷰)
--      · 저장된 행이 아직 연도가 없으면 그 행의 created_at 기준 · 월·일이 바뀌었으면(옛 앱의 날짜 수정) 지금(KST) 기준 · 새 행은 created_at(없으면 지금) 기준.
--      고친 것은 기록에 남긴다(source guard:…) — 옛 빌드가 아직 도는지 보인다. 새 앱은 언제나 연도를 보내므로 아무 일도 안 한다.
--   ④ 확인 표에 연도 의심 행(읽기만): 회차와 날짜가 다른 연결 구매 · 올린 날보다 앞선 날짜로 저장된 초대(옛 초대 날짜 고르기가 연도를 버리고 다시 짐작하던 것).
-- 바꾸지 않는 것: 상태·좌석·가격·구매·초대 행. 회차 date 의 글자만(연도 앞붙임).
-- ═══════════════════════════════════════════════════════════════

-- ① 연도 없는 월·일 → 'YYYY.MM.DD' (기준일 필수)
create or replace function public._taam_mmdd_year(p_mmdd text, p_anchor date)
returns text
language plpgsql immutable
as $$
declare s text := btrim(coalesce(p_mmdd, '')); m int; d int; y int; base date;
begin
  if p_anchor is null then return null; end if;
  if s !~ '^\d{1,2}\.\d{1,2}$' then return null; end if;
  m := split_part(s, '.', 1)::int; d := split_part(s, '.', 2)::int;
  if m < 1 or m > 12 or d < 1 or d > 31 then return null; end if;
  base := p_anchor - 30;
  y := extract(year from base)::int;
  if m = 2 and d = 29 then
    -- 기준일 뒤 첫 윤년의 2/29
    for i in 0..8 loop
      if ((y % 4 = 0 and y % 100 <> 0) or y % 400 = 0) and make_date(y, 2, 29) >= base then
        return y::text || '.' || s;
      end if;
      y := y + 1;
    end loop;
    return null;
  end if;
  if d > extract(day from (make_date(y, m, 1) + interval '1 month - 1 day'))::int then return null; end if;   -- 4/31 같은 없는 날
  if make_date(y, m, d) < base then y := y + 1; end if;
  return y::text || '.' || s;
end $$;
comment on function public._taam_mmdd_year(text, date) is
  '연도 없는 회차 날짜 MM.DD → YYYY.MM.DD (기준일 30일 전 이후 첫 그 날 · 기준일 없으면 null). 기준일 = 올린 날(KST). 2026-10-19';

-- ② 되돌리기 기록
create table if not exists public.ticket_date_year_log (
  id bigserial primary key,
  tbl text not null,
  row_id text not null,
  old_date text,
  new_date text,
  source text,
  batch text,
  at timestamptz not null default now()
);
alter table public.ticket_date_year_log add column if not exists batch text;
alter table public.ticket_date_year_log enable row level security;
revoke all on public.ticket_date_year_log from anon, authenticated;
drop policy if exists tdyl_super_read on public.ticket_date_year_log;
do $do$ begin
  if to_regprocedure('public._taam_uid_is_super()') is not null then
    execute 'create policy tdyl_super_read on public.ticket_date_year_log for select to authenticated using (public._taam_uid_is_super())';
    execute 'grant select on public.ticket_date_year_log to authenticated';
  end if;
end $do$;

-- ③ 가드 — 연도 없는 회차 날짜는 저장되지 않는다
create or replace function public._taam_tp_date_year()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare s text; o text; o_created timestamptz; anchor date; src text; v_new text;
begin
  s := btrim(coalesce(NEW.date, ''));
  if s !~ '^\d{1,2}\.\d{1,2}$' then return NEW; end if;
  -- 저장된 같은 id 의 행 — UPDATE 는 OLD, INSERT 는 직접 읽는다(upsert 의 INSERT 가지 · 아직 없는 새 행이면 null)
  if TG_OP = 'UPDATE' then
    o := btrim(coalesce(OLD.date, '')); o_created := (to_jsonb(OLD)->>'created_at')::timestamptz;
  else
    select btrim(coalesce(tp.date, '')), (to_jsonb(tp)->>'created_at')::timestamptz into o, o_created
      from public.ticket_products tp where tp.id = NEW.id;
  end if;
  if o ~ '^\d{4}\.\d{1,2}\.\d{1,2}$'
     and split_part(o, '.', 2)::int = split_part(s, '.', 1)::int
     and split_part(o, '.', 3)::int = split_part(s, '.', 2)::int then
    v_new := split_part(o, '.', 1) || '.' || s; src := 'guard:keep';                                   -- 옛 앱의 다시 저장 — 저장된 연도를 지킨다
  elsif o ~ '^\d{1,2}\.\d{1,2}$' and split_part(o, '.', 1)::int = split_part(s, '.', 1)::int and split_part(o, '.', 2)::int = split_part(s, '.', 2)::int then
    v_new := public._taam_mmdd_year(s, (coalesce(o_created, now()) at time zone 'Asia/Seoul')::date); src := 'guard:created';   -- 아직 연도 없는 옛 행 — 그 행의 올린 날
  elsif o is not null and o <> '' then
    v_new := public._taam_mmdd_year(s, (now() at time zone 'Asia/Seoul')::date); src := 'guard:moved';   -- 옛 앱의 날짜 수정 — 지금 기준
  else
    v_new := public._taam_mmdd_year(s, (coalesce((to_jsonb(NEW)->>'created_at')::timestamptz, now()) at time zone 'Asia/Seoul')::date); src := 'guard:new';
  end if;
  if v_new is not null then
    begin
      insert into public.ticket_date_year_log(tbl, row_id, old_date, new_date, source) values ('ticket_products', NEW.id::text, s, v_new, src);
    exception when others then null; end;   -- 기록 실패가 저장을 막지 않는다
    NEW.date := v_new;
  end if;
  return NEW;
end $$;
revoke all on function public._taam_tp_date_year() from public, anon, authenticated;

drop trigger if exists trg_taam_tp_date_year on public.ticket_products;
create trigger trg_taam_tp_date_year
  before insert or update of date on public.ticket_products
  for each row execute function public._taam_tp_date_year();

-- ④ 채우기 — 올린 날 기준 · 확정 구매 행의 연도와 다르면 멈추고 ⚠
drop table if exists _tdy; create temp table _tdy(id text primary key, rest text, old_date text, new_date text, buy_year text, apply boolean);
insert into _tdy(id, rest, old_date, new_date, buy_year, apply)
select tp.id, tp.rest_name, tp.date,
       public._taam_mmdd_year(tp.date, ((to_jsonb(tp)->>'created_at')::timestamptz at time zone 'Asia/Seoul')::date),
       (select split_part(btrim(t.reservation_date::text), '.', 1)
          from public.tickets t
         where t.ticket_product_id = tp.id
           and lower(coalesce(t.status, '')) in ('active', 'completed', 'manual', 'used')
           and coalesce(t.purchase_id, '') !~ '^(PAYH|INVH)-'
           and btrim(t.reservation_date::text) ~ '^\d{4}\.\d{1,2}\.\d{1,2}$'
           and split_part(btrim(t.reservation_date::text), '.', 2)::int = split_part(btrim(tp.date), '.', 1)::int
           and split_part(btrim(t.reservation_date::text), '.', 3)::int = split_part(btrim(tp.date), '.', 2)::int
         group by 1 order by count(*) desc, 1 limit 1),
       false
  from public.ticket_products tp
 where btrim(coalesce(tp.date, '')) ~ '^\d{1,2}\.\d{1,2}$';
update _tdy set apply = (new_date is not null and (buy_year is null or buy_year = split_part(new_date, '.', 1)));

insert into public.ticket_date_year_log(tbl, row_id, old_date, new_date, source, batch)
select 'ticket_products', id, old_date, new_date,
       case when buy_year is null then '올린 날 기준' else '올린 날 기준 · 구매 연도 일치' end, '20261019_backfill'
  from _tdy where apply;

update public.ticket_products tp set date = x.new_date
  from _tdy x where x.id = tp.id and x.apply;
-- 위 UPDATE 는 연도가 붙은 날짜를 쓰므로 가드는 아무 일도 안 한다(기록이 두 번 남지 않는다).

-- ── 확인 — 한 표 ──
drop table if exists _tdy_check; create temp table _tdy_check(k text, v text);
insert into _tdy_check
select '① 연도 함수 · 가드 트리거',
       case when to_regprocedure('public._taam_mmdd_year(text,date)') is not null
             and exists (select 1 from pg_trigger where tgname = 'trg_taam_tp_date_year' and not tgisinternal)
             and exists (select 1 from pg_proc where oid = to_regprocedure('public._taam_tp_date_year()') and prosecdef) then '✅' else '❌' end
union all
select '② 연도 없는 회차 남음', case when n = 0 then '✅ 0' else '⚠ ' || n || '건 — 아래 ③ 의 ⚠ 를 보고 손으로' end
  from (select count(*) as n from public.ticket_products where btrim(coalesce(date, '')) ~ '^\d{1,2}\.\d{1,2}$') c
union all
select '③ ' || coalesce(x.rest, '?') || ' (' || x.id || ')',
       x.old_date || ' → ' || coalesce(x.new_date, '(못 읽음)')
       || case when x.apply then ' ✅' || case when x.buy_year is not null then ' · 구매 연도 ' || x.buy_year || ' 일치' else '' end
               else ' ⚠ 바꾸지 않음 — ' || case when x.new_date is null then '날짜를 읽을 수 없다' else '확정 구매 행의 연도 ' || x.buy_year || ' 와 다르다' end end
  from _tdy x
union all
select '④ 연도 규칙 시험',
       case when public._taam_mmdd_year('06.17', date '2026-06-07') = '2026.06.17'
             and public._taam_mmdd_year('01.25', date '2025-11-01') = '2026.01.25'
             and public._taam_mmdd_year('12.28', date '2026-01-10') = '2025.12.28'
             and public._taam_mmdd_year('06.17', date '2026-10-19') = '2027.06.17'
             and public._taam_mmdd_year('10.03', date '2026-10-19') = '2026.10.03'
             and public._taam_mmdd_year('02.29', date '2026-10-19') = '2028.02.29'
             and public._taam_mmdd_year('06.17', null) is null
             and public._taam_mmdd_year('04.31', date '2026-01-01') is null then '✅' else '❌ 연도 규칙' end;
-- ⑤ 연도 의심(읽기만 · ⚠) — 회차와 날짜가 다른 연결 구매(정산 KSK- 는 제 회차 날짜를 따로 쓴다) · 올린 날보다 앞선 날짜로 저장된 초대
do $do$
declare r record;
begin
  if to_regprocedure('public.taam_visit_date(text)') is null then
    insert into _tdy_check values ('⑤ 연도 의심 점검', '⚠ taam_visit_date 없음 — 건너뜀'); return;
  end if;
  for r in
    select t.purchase_id, t.status, t.reservation_date::text as rd, tp.date as tpd, tp.rest_name
      from public.tickets t join public.ticket_products tp on tp.id = t.ticket_product_id
     where lower(coalesce(t.status, '')) not in ('cancelled', 'expired')
       and coalesce(t.purchase_id, '') !~ '^KSK-'
       and public.taam_visit_date(t.reservation_date::text) is not null
       and public.taam_visit_date(tp.date) is not null
       and public.taam_visit_date(t.reservation_date::text) <> public.taam_visit_date(tp.date)
     limit 40
  loop
    insert into _tdy_check values ('⑤ 구매·회차 날짜 다름 ' || coalesce(r.purchase_id, '?'), '⚠ 구매 ' || r.rd || ' · 회차 ' || r.tpd || ' ' || coalesce(r.rest_name, '') || ' · ' || coalesce(r.status, ''));
  end loop;
  if to_regclass('public.reservation_invites') is not null then
    for r in execute $q$
      select i.id::text as id, i.restaurant_name, i.visit_date::text as vd, i.status, i.created_at
        from public.reservation_invites i
       where lower(coalesce(i.status, '')) not in ('cancelled', 'canceled', 'expired', 'rejected')
         and public.taam_visit_date(i.visit_date::text) is not null
         and public.taam_visit_date(i.visit_date::text) < (i.created_at at time zone 'Asia/Seoul')::date - 1
       limit 40 $q$
    loop
      insert into _tdy_check values ('⑤ 초대 날짜가 보낸 날보다 앞섬 ' || r.id, '⚠ ' || coalesce(r.restaurant_name, '') || ' · 방문 ' || r.vd || ' · 보낸 날 ' || to_char(r.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD') || ' · ' || coalesce(r.status, '') || ' — 한 해 일찍 저장된 것인지 확인');
    end loop;
  end if;
  if not exists (select 1 from _tdy_check where k like '⑤ %') then
    insert into _tdy_check values ('⑤ 연도 의심 점검', '✅ 의심 행 없음');
  end if;
end $do$;
select k as 항목, v as 결과 from _tdy_check order by 1;
