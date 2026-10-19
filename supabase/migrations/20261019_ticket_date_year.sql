-- ═══════════════════════════════════════════════════════════════
-- 회차 방문일에 연도를 채우고, 연도 없는 날짜가 다시는 저장되지 않게 (2026-10-19)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 「티켓 캘린더 2027년 6월에 2026년 6월 티켓(시마즈 6/17 · 스시 이코우 6/16 · 히가시아자부 아마모토 6/15)이 또 보인다 — 올린 적 없다」.
--     2026.07 전에 올린 회차 11개가 연도 없이 'MM.DD' 로 저장돼 있었고(진단 20261019_diag_yearless_dates.sql · 전부 2026-05-11 ~ 06-08 작성 · 매진),
--     앱이 연도 없는 날짜를 「오늘 기준 120일 넘게 지났으면 내년」으로 읽어 2027 로 옮겼다. 날이 갈수록 더 옮겨 간다(7월 회차는 10월 말, 9·10월 회차는 1~2월).
--     구매·초대·수동 기록은 전부 연도가 있다(진단) — 회차 표만의 문제다.
-- 무엇:
--   ① _taam_mmdd_year(p_mmdd, p_anchor): 연도 없는 'MM.DD' 를 「기준일 30일 전 이후 첫 그 날」의 'YYYY.MM.DD' 로. 회차는 방문 전에 올리므로
--      기준일 = 올린 날(created_at, KST). 2/29 는 평년이면 비교만 2/28 로 한다(글자는 그대로).
--   ② 채우기: 연도 없는 회차마다 — 그 회차를 산 구매 행(tickets.reservation_date · 연도 있음 · 월·일 같음)의 연도가 있으면 그것, 없으면 ① (created_at 기준).
--      옛값은 ticket_date_year_log 에 남긴다(되돌리기용 · 슈퍼어드민만 읽기).
--   ③ 가드 trg_taam_tp_date_year(BEFORE INSERT/UPDATE OF date): 연도 없는 date 가 들어오면 — 같은 행의 옛 date 에 연도가 있고 월·일이 같으면
--      그 연도(옛 앱이 dateYear 없이 다시 저장해도 연도가 지워지지 않게), 아니면 ① (INSERT 는 created_at, UPDATE 는 지금 기준).
--      새 앱은 언제나 연도를 보내므로 아무 일도 안 한다.
-- 바꾸지 않는 것: 상태·좌석·가격·구매 행. 회차 date 의 글자만(연도 앞붙임).
-- ═══════════════════════════════════════════════════════════════

-- ① 연도 없는 월·일 → 'YYYY.MM.DD'
create or replace function public._taam_mmdd_year(p_mmdd text, p_anchor date)
returns text
language plpgsql immutable
as $$
declare s text := btrim(coalesce(p_mmdd, '')); m int; d int; y int; base date; cand date;
begin
  if s !~ '^\d{1,2}\.\d{1,2}$' then return null; end if;
  m := split_part(s, '.', 1)::int; d := split_part(s, '.', 2)::int;
  if m < 1 or m > 12 or d < 1 or d > 31 then return null; end if;
  base := coalesce(p_anchor, (now() at time zone 'Asia/Seoul')::date) - 30;
  y := extract(year from base)::int;
  begin
    cand := make_date(y, m, least(d, extract(day from (make_date(y, m, 1) + interval '1 month - 1 day'))::int));
  exception when others then return null; end;
  if cand < base then y := y + 1; end if;
  return y::text || '.' || s;
end $$;
comment on function public._taam_mmdd_year(text, date) is
  '연도 없는 회차 날짜 MM.DD → YYYY.MM.DD (기준일 30일 전 이후 첫 그 날). 기준일 = 올린 날. 2026-10-19';

-- ② 되돌리기 기록
create table if not exists public.ticket_date_year_log (
  id bigserial primary key,
  tbl text not null,
  row_id text not null,
  old_date text,
  new_date text,
  source text,
  at timestamptz not null default now()
);
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
as $$
declare s text; o text; anchor date;
begin
  s := btrim(coalesce(NEW.date, ''));
  if s !~ '^\d{1,2}\.\d{1,2}$' then return NEW; end if;
  -- 같은 행의 옛 날짜에 연도가 있고 월·일이 같으면 그 연도를 지킨다 (옛 앱의 다시 저장 · 연도를 모르는 쪽이 지우지 못하게)
  if TG_OP = 'UPDATE' then
    o := btrim(coalesce(OLD.date, ''));
    if o ~ '^\d{4}\.\d{1,2}\.\d{1,2}$'
       and split_part(o, '.', 2)::int = split_part(s, '.', 1)::int
       and split_part(o, '.', 3)::int = split_part(s, '.', 2)::int then
      NEW.date := split_part(o, '.', 1) || '.' || s;
      return NEW;
    end if;
  end if;
  anchor := case when TG_OP = 'INSERT'
                 then ((coalesce((to_jsonb(NEW)->>'created_at')::timestamptz, now())) at time zone 'Asia/Seoul')::date
                 else (now() at time zone 'Asia/Seoul')::date end;
  NEW.date := coalesce(public._taam_mmdd_year(s, anchor), NEW.date);
  return NEW;
end $$;

drop trigger if exists trg_taam_tp_date_year on public.ticket_products;
create trigger trg_taam_tp_date_year
  before insert or update of date on public.ticket_products
  for each row execute function public._taam_tp_date_year();

-- ④ 채우기 — 구매 행의 연도 우선, 없으면 올린 날 기준
drop table if exists _tdy; create temp table _tdy(id text primary key, old_date text, new_date text, source text);
insert into _tdy(id, old_date, new_date, source)
select tp.id, tp.date,
       coalesce(
         (select y || '.' || btrim(tp.date) from (
             select split_part(btrim(t.reservation_date::text), '.', 1) as y, count(*) as n
               from public.tickets t
              where t.ticket_product_id = tp.id
                and btrim(t.reservation_date::text) ~ '^\d{4}\.\d{1,2}\.\d{1,2}$'
                and split_part(btrim(t.reservation_date::text), '.', 2)::int = split_part(btrim(tp.date), '.', 1)::int
                and split_part(btrim(t.reservation_date::text), '.', 3)::int = split_part(btrim(tp.date), '.', 2)::int
              group by 1 order by 2 desc, 1 limit 1) x),
         public._taam_mmdd_year(tp.date, ((tp.created_at) at time zone 'Asia/Seoul')::date)
       ),
       case when exists (select 1 from public.tickets t where t.ticket_product_id = tp.id
                          and btrim(t.reservation_date::text) ~ '^\d{4}\.\d{1,2}\.\d{1,2}$'
                          and split_part(btrim(t.reservation_date::text), '.', 2)::int = split_part(btrim(tp.date), '.', 1)::int
                          and split_part(btrim(t.reservation_date::text), '.', 3)::int = split_part(btrim(tp.date), '.', 2)::int)
            then '구매 행 연도' else '올린 날 기준' end
  from public.ticket_products tp
 where btrim(coalesce(tp.date, '')) ~ '^\d{1,2}\.\d{1,2}$';

insert into public.ticket_date_year_log(tbl, row_id, old_date, new_date, source)
select 'ticket_products', id, old_date, new_date, source from _tdy where new_date is not null;

update public.ticket_products tp set date = x.new_date
  from _tdy x where x.id = tp.id and x.new_date is not null;

-- ── 확인 — 한 표 ──
select '① 연도 함수 · 가드 트리거' as 항목,
       case when to_regprocedure('public._taam_mmdd_year(text,date)') is not null
             and exists (select 1 from pg_trigger where tgname = 'trg_taam_tp_date_year' and not tgisinternal) then '✅' else '❌' end as 결과
union all
select '② 연도 없는 회차 남음', case when n = 0 then '✅ 0' else '❌ ' || n || '건 — 읽을 수 없는 날짜(아래 목록 확인)' end
  from (select count(*) as n from public.ticket_products where btrim(coalesce(date, '')) ~ '^\d{1,2}\.\d{1,2}$') c
union all
select '③ 채운 회차 ' || coalesce(tp.rest_name, '?') || ' (' || x.id || ')', x.old_date || ' → ' || coalesce(x.new_date, '(못 읽음)') || ' · ' || x.source
  from _tdy x left join public.ticket_products tp on tp.id = x.id
union all
select '④ 가드 시험 — 옛 앱이 연도 없이 다시 저장', case when public._taam_mmdd_year('06.17', date '2026-06-07') = '2026.06.17'
             and public._taam_mmdd_year('01.25', date '2025-11-01') = '2026.01.25'
             and public._taam_mmdd_year('06.17', date '2026-10-19') = '2027.06.17'
             and public._taam_mmdd_year('10.03', date '2026-10-19') = '2026.10.03' then '✅' else '❌ 연도 규칙' end
order by 1;
