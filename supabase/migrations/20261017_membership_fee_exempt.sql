-- ═══════════════════════════════════════════════════════════════
-- 연회비 대상 제외 스위치 — profiles.fee_exempt (2026-10-17 운영 결정)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN (20261017_membership_fee_due.sql 뒤). 마지막 표에 ❌ 가 없어야 정상.
-- 왜: 테스트 계정·면제 회원이 M/T 등급이면 「연회비 납부 시기」 목록과 매일 알림에 계속 올라온다. 슈퍼어드민이 회원 원장 연회비 탭에서
--     「대상 제외 / 포함」을 누르면 목록·알림에서 빠지고(기본 조회), 화면의 「제외」 필터(p_include_exempt)에서만 보인다.
-- 가드: 회원 세션은 이 칸을 못 바꾼다 — 자기를 제외해 연회비 알림을 피하는 길이 되므로. membership_joined_at 가드와 같은 방식(되돌림 · 예외 아님).
--       누가·언제는 트리거가 적는다(fee_exempt_set_by/at · 앱이 보내도 무시).
-- 바뀌는 함수: taam_membership_fee_due 에 p_include_exempt(기본 false)와 출력 열 fee_exempt · fee_exempt_note 가 더해진다.
--             taam_membership_fee_notify 는 기본값(false)으로 부르니 제외 회원에게는 알리지 않는다.
-- 회귀: bash sql/_test/t_fee_due.sh (이 파일까지 올린다)
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists fee_exempt        boolean not null default false,
  add column if not exists fee_exempt_note   text,
  add column if not exists fee_exempt_set_at timestamptz,
  add column if not exists fee_exempt_set_by uuid;

-- ── 가드 — 회원 세션은 되돌린다 · 바뀌면 누가·언제를 적는다 ──
create or replace function public.taam_guard_fee_exempt()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_member boolean := (current_user in ('authenticated', 'anon') and not coalesce(public._taam_uid_is_super(), false));
begin
  if tg_op = 'INSERT' then
    if coalesce(new.fee_exempt, false) = false and new.fee_exempt_note is null then
      new.fee_exempt := false; new.fee_exempt_set_at := null; new.fee_exempt_set_by := null;
      return new;
    end if;
    if v_member then
      raise warning '[guard] fee_exempt 는 슈퍼어드민만 바꿉니다 (insert · uid=%)', auth.uid();
      new.fee_exempt := false; new.fee_exempt_note := null; new.fee_exempt_set_at := null; new.fee_exempt_set_by := null;
      return new;
    end if;
    new.fee_exempt_set_at := now(); new.fee_exempt_set_by := auth.uid();
    return new;
  end if;
  if new.fee_exempt is not distinct from old.fee_exempt and new.fee_exempt_note is not distinct from old.fee_exempt_note then
    new.fee_exempt_set_at := old.fee_exempt_set_at; new.fee_exempt_set_by := old.fee_exempt_set_by;   -- 그대로면 기록도 그대로
    return new;
  end if;
  if v_member then
    raise warning '[guard] fee_exempt 변경 차단: % → % (uid=%)', old.fee_exempt, new.fee_exempt, auth.uid();
    new.fee_exempt := old.fee_exempt; new.fee_exempt_note := old.fee_exempt_note;
    new.fee_exempt_set_at := old.fee_exempt_set_at; new.fee_exempt_set_by := old.fee_exempt_set_by;
    return new;
  end if;
  new.fee_exempt_set_at := now(); new.fee_exempt_set_by := auth.uid();
  return new;
end $$;
drop trigger if exists trg_taam_guard_fee_exempt on public.profiles;
create trigger trg_taam_guard_fee_exempt
  before insert or update of fee_exempt, fee_exempt_note on public.profiles
  for each row execute function public.taam_guard_fee_exempt();

-- ── 보고 함수 — p_include_exempt · fee_exempt 출력 (몸체는 20261017_membership_fee_due.sql 과 같고 제외 조건만 더함) ──
drop function if exists public.taam_membership_fee_due(uuid, date);
drop function if exists public.taam_membership_fee_due(uuid, date, boolean);
create or replace function public.taam_membership_fee_due(p_uid uuid default null, p_today date default null, p_include_exempt boolean default false)
returns table (
  user_id uuid, display_name text, tier text, currency text, joined_at date, joined_kind text,
  years int, paid int, due_date date, days_left int, short int, ahead int, last_paid date, fee_hint text,
  fee_exempt boolean, fee_exempt_note text
)
language plpgsql stable security definer set search_path = public
as $$
declare v_today date := coalesce(p_today, (now() at time zone 'Asia/Seoul')::date);
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
  with m as (
    select p.id, p.display_name, p.membership_tier as tier,
           coalesce(
             (select f.fx_currency from public.membership_fees f where f.user_id = p.id and f.fx_currency in ('USD', 'JPY') order by f.paid_at desc, f.created_at desc limit 1),
             case when (to_jsonb(p) ->> 'currency_prev') in ('USD', 'JPY') then to_jsonb(p) ->> 'currency_prev' end,
             nullif(p.currency, ''), 'KRW') as cur,
           coalesce(p.membership_joined_at, (p.created_at at time zone 'Asia/Seoul')::date) as joined,
           case when p.membership_joined_at is not null then 'manual' else 'app' end as jk,
           (select count(*) from public.membership_fees f where f.user_id = p.id)::int
         + (select count(distinct coalesce(t.payment_id::text, to_char(t.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD')))
              from public.deposit_transactions t where t.user_id = p.id and t.change_type = 'membership_payment')::int as paid,
           (select max(f.paid_at) from public.membership_fees f where f.user_id = p.id) as last_paid,
           coalesce(p.fee_exempt, false) as ex, p.fee_exempt_note as exn
      from public.profiles p
     where p.deleted_at is null
       and p.membership_tier in ('M', 'T')
       and coalesce(p.role, '') not in ('superadmin', 'super_admin', 'admin')
       and (p_include_exempt or not coalesce(p.fee_exempt, false))
       and (p_uid is null or p.id = p_uid)
  ), c as (
    select m.*, public._taam_fee_years(m.joined, v_today) as yrs,
           (m.joined + make_interval(years => m.paid))::date as due
      from m
  )
  select c.id, c.display_name, c.tier, c.cur, c.joined, c.jk, c.yrs, c.paid, c.due, (c.due - v_today)::int,
         greatest(0, c.yrs - c.paid), greatest(0, c.paid - c.yrs), c.last_paid,
         case when c.cur = 'KRW' then (case when c.tier = 'M' then '₩1,125,000' else '₩630,000' end)
              when c.cur = 'USD' then (case when c.tier = 'M' then '$990' else '$300' end)
              else c.cur || ' — 규정 없음' end,
         c.ex, c.exn
    from c
   order by c.ex, c.due nulls last, c.display_name;
end $$;
revoke all on function public.taam_membership_fee_due(uuid, date, boolean) from public, anon;
grant execute on function public.taam_membership_fee_due(uuid, date, boolean) to authenticated;

-- ── 확인 — 한 표 ──
select '① profiles.fee_exempt 칸' as 항목,
       case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='fee_exempt') then '✅' else '❌' end as 결과
union all select '② 가드 트리거 trg_taam_guard_fee_exempt',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_fee_exempt' and not tgisinternal) then '✅' else '❌' end
union all select '③ 보고 함수 (uuid, date, boolean)',
       case when to_regprocedure('public.taam_membership_fee_due(uuid,date,boolean)') is not null
             and to_regprocedure('public.taam_membership_fee_due(uuid,date)') is null then '✅' else '❌' end
union all select '④ anon 실행 권한 없음',
       case when has_function_privilege('anon', 'public.taam_membership_fee_due(uuid,date,boolean)', 'execute') then '❌' else '✅' end
union all select '⑤ 알림 함수가 새 보고 함수를 부른다 (오늘 · notified 는 이미 알린 회원이면 0)',
       public.taam_membership_fee_notify()::text
union all select '⑥ 지금 제외된 회원 수 / 대상',
       (select count(*) from public.taam_membership_fee_due(null, null, true) d where d.fee_exempt)::text || '명 / ' || (select count(*) from public.taam_membership_fee_due())::text || '명';
