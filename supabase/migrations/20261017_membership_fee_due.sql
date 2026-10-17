-- ═══════════════════════════════════════════════════════════════
-- 연회비 납부 시기 — 보고 RPC + 매일 슈퍼어드민 알림 (2026-10-17)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 결과 표에 ❌ 가 한 줄도 없어야 정상 (④ 는 pg_cron 이 없으면 ⚠).
-- 왜: 연회비는 가입 기념일마다 받는데(국내 M 1,125,000 · T 630,000 · 해외 M $990 · T $300) 아무도 시기를 알려 주지 않았다.
--     회원 원장 연회비 탭의 「다음 납부 기준일」(앱 _mlFeeDue)과 **같은 규칙**을 서버에 두고, 전원을 한 표로 보고 매일 알린다.
-- 규칙: 가입일 = profiles.membership_joined_at(실제 가입일) 우선, 없으면 created_at 의 KST 날짜 (= taam_member_start().joined_at 과 같다).
--       연차 수 = 가입일부터 오늘(KST)까지 지난 기념일 수(가입일 자체 포함). 납부 건수 = membership_fees 행 + 원장 membership_payment **결제 수**(같은 payment_id · 없으면 같은 KST 날짜는 한 건 · 멤버십+일반 두 주머니를 쓴 결제는 줄이 둘이다).
--       예상액 통화 = 그 회원의 연회비 기록 외화(최근) → 잠금 전 통화(profiles.currency_prev) → profiles.currency → KRW. (라이브 currency 는 전원 KRW 로 잠겨 있어 그것만 보면 해외 회원이 원화로 나온다)
--       기준일 = 가입일 + 납부 건수 년. 오늘 이전이면 밀린 것(부족 = 연차 − 납부), 아니면 다음 납부일. 2/29 가입은 평년 2/28 (date + interval 이 그렇게 자른다 · 앱과 같음).
-- 대상: 탈퇴 아님 · 등급 M/T · 운영 계정(superadmin/super_admin/admin) 제외.
-- 알림: 매일 09:00 KST 크론 `taam-membership-fee-due` → taam_membership_fee_notify(). 회원·기준일마다 30일 전 · 7일 전 · 당일 · 7일 뒤 · 30일 뒤 **한 번씩**
--       (membership_fee_notices 가 기억한다 · 첫 실행에 밀린 회원은 가장 급한 단계 하나만). 한 번 실행 = 슈퍼어드민마다 인앱 알림 1줄(type membership_fee_due · 대상 전원 나열)
--       + taam_admin_push 로 푸시 1번(8줄 + 외 N명 · url /?feedue=1 → 앱 「연회비 납부 시기」 화면). 푸시 실패는 알림을 막지 않는다.
-- 안 하는 것: 예치금 차감·원장·membership_fees 에 쓰지 않는다 — 알리기만 한다. 차감·기록은 사람이 회원 원장에서.
-- 호출 권한: 슈퍼어드민(auth.uid) · SQL Editor(postgres) · 크론(postgres) · service_role. 회원·anon 은 FORBIDDEN.
-- 회귀: bash sql/_test/t_fee_due.sh
-- ═══════════════════════════════════════════════════════════════

-- ── 0) 연차 수 — 앱 _mlFeeDue 의 while 루프와 같다 ──
create or replace function public._taam_fee_years(p_joined date, p_today date)
returns int
language plpgsql immutable
as $$
declare y int := 0;
begin
  if p_joined is null or p_today is null or p_joined > p_today then return 0; end if;
  y := 1;
  while y < 200 and (p_joined + make_interval(years => y))::date <= p_today loop
    y := y + 1;
  end loop;
  return y;
end $$;
revoke all on function public._taam_fee_years(date, date) from public, anon;

-- ── 1) 호출자 판별 — 로그인 세션이면 슈퍼어드민만, 세션이 없으면(SQL Editor · 크론 · Edge) postgres/service_role 만 ──
--      ⚠ security definer 안의 current_user 는 소유자다 — session_user 와 auth.uid() 로만 가른다 (CLAUDE.md)
create or replace function public._taam_fee_caller_ok()
returns boolean
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if;
  return session_user = 'postgres'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then
  return false;
end $$;
revoke all on function public._taam_fee_caller_ok() from public, anon;

-- ── 2) 보고 — 전원(또는 한 명)의 다음 납부 기준일 ──
drop function if exists public.taam_membership_fee_due(uuid, date);
create or replace function public.taam_membership_fee_due(p_uid uuid default null, p_today date default null)
returns table (
  user_id uuid, display_name text, tier text, currency text, joined_at date, joined_kind text,
  years int, paid int, due_date date, days_left int, short int, ahead int, last_paid date, fee_hint text
)
language plpgsql stable security definer set search_path = public
as $$
declare v_today date := coalesce(p_today, (now() at time zone 'Asia/Seoul')::date);
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
  with m as (
    select p.id, p.display_name, p.membership_tier as tier,
           -- 통화: 라이브 profiles.currency 는 2026-09-14 부터 전원 'KRW' 로 잠겨 있다(sql/currency_krw_only.sql · 원래 값은 currency_prev).
           --       그래서 그 회원이 실제로 낸 연회비의 외화(membership_fees.fx_currency 최근 것) → 잠금 전 통화(currency_prev · 컬럼이 없는 DB 에서도 to_jsonb 로 안전) → currency → KRW 순으로 고른다(적대 리뷰)
           coalesce(
             (select f.fx_currency from public.membership_fees f where f.user_id = p.id and f.fx_currency in ('USD', 'JPY') order by f.paid_at desc, f.created_at desc limit 1),
             case when (to_jsonb(p) ->> 'currency_prev') in ('USD', 'JPY') then to_jsonb(p) ->> 'currency_prev' end,
             nullif(p.currency, ''), 'KRW') as cur,
           coalesce(p.membership_joined_at, (p.created_at at time zone 'Asia/Seoul')::date) as joined,
           case when p.membership_joined_at is not null then 'manual' else 'app' end as jk,
           (select count(*) from public.membership_fees f where f.user_id = p.id)::int
         + (select count(distinct coalesce(t.payment_id::text, to_char(t.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD')))
              from public.deposit_transactions t where t.user_id = p.id and t.change_type = 'membership_payment')::int as paid,   -- 한 결제가 두 주머니면 원장 줄이 둘 — 결제 단위로(payment_id · 없으면 같은 KST 날짜) 센다
           (select max(f.paid_at) from public.membership_fees f where f.user_id = p.id) as last_paid
      from public.profiles p
     where p.deleted_at is null
       and p.membership_tier in ('M', 'T')
       and coalesce(p.role, '') not in ('superadmin', 'super_admin', 'admin')
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
              else c.cur || ' — 규정 없음' end
    from c
   order by c.due nulls last, c.display_name;
end $$;
revoke all on function public.taam_membership_fee_due(uuid, date) from public, anon;
grant execute on function public.taam_membership_fee_due(uuid, date) to authenticated;

-- ── 3) 알림 기록 — (회원 · 기준일 · 단계) 한 번씩 ──
create table if not exists public.membership_fee_notices (
  user_id     uuid not null references auth.users(id) on delete cascade,
  due_date    date not null,
  stage       int  not null,                       -- 30 · 7 · 0 · -7 · -30 (days_left 가 이 값 이하가 된 날)
  notified_at timestamptz not null default now(),
  primary key (user_id, due_date, stage)
);
alter table public.membership_fee_notices enable row level security;
drop policy if exists membership_fee_notices_super_read on public.membership_fee_notices;
create policy membership_fee_notices_super_read on public.membership_fee_notices
  for select to authenticated using (public.is_super_admin(auth.uid()));
grant select on public.membership_fee_notices to authenticated;

-- ── 4) 매일 알림 ──
create or replace function public.taam_membership_fee_notify(p_today date default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_today   date  := coalesce(p_today, (now() at time zone 'Asia/Seoul')::date);
  v_stages  int[] := array[30, 7, 0, -7, -30];
  r record; v_stage int; v_new int;
  v_lines text[] := '{}'; v_members jsonb := '[]'::jsonb; v_cnt int := 0;
  v_title text; v_body text := ''; v_push_body text; v_n int := 0; v_push jsonb := null; v_line text; v_shown int := 0;
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for r in
    select * from public.taam_membership_fee_due(null, v_today) d
     where d.due_date is not null and d.days_left <= 30
     order by d.due_date, d.display_name
  loop
    -- 도달한 단계 중 가장 급한 것 하나만 알리고, 그 위 단계는 알린 것으로 적는다 — 첫 실행에 밀린 회원이 다섯 번 쌓이지 않게
    select min(s) into v_stage from unnest(v_stages) s where r.days_left <= s;
    if v_stage is null then continue; end if;
    insert into public.membership_fee_notices (user_id, due_date, stage)
      select r.user_id, r.due_date, s from unnest(v_stages) s where s >= v_stage
      on conflict do nothing;
    get diagnostics v_new = row_count;
    if v_new = 0 then continue; end if;                 -- 이 단계는 이미 알렸다
    v_cnt := v_cnt + 1;
    v_lines := v_lines || (coalesce(nullif(r.display_name, ''), left(r.user_id::text, 8)) || ' · ' || coalesce(r.tier, '?') || ' · '
      || to_char(r.due_date, 'YYYY.MM.DD') || ' '
      || case when r.days_left > 0 then 'D-' || r.days_left when r.days_left = 0 then '오늘' else abs(r.days_left) || '일 지남' end
      || ' · ' || r.years || '년차 · ' || r.fee_hint);
    v_members := v_members || jsonb_build_object('uid', r.user_id, 'name', r.display_name, 'tier', r.tier, 'due', r.due_date,
                                                 'days_left', r.days_left, 'stage', v_stage, 'short', r.short);
  end loop;
  if v_cnt = 0 then return jsonb_build_object('ok', true, 'today', v_today, 'notified', 0); end if;
  v_title     := '💰 연회비 납부 시기 ' || v_cnt || '명';
  -- 인앱 본문: 벨이 body 를 그대로 그리므로 1000자 안에서 **줄 단위**로 넣고, 넘치면 「외 N명」(줄 중간 절단 금지 · 적대 리뷰). 전원은 /?feedue=1 화면과 payload.members 에
  foreach v_line in array v_lines loop
    exit when length(v_body) + length(v_line) + 1 > 940;
    v_body := v_body || case when v_body = '' then '' else E'\n' end || v_line;
    v_shown := v_shown + 1;
  end loop;
  if v_shown < v_cnt then v_body := v_body || E'\n외 ' || (v_cnt - v_shown) || '명 — 전원은 「연회비 납부 시기」 화면에서'; end if;
  v_push_body := array_to_string(v_lines[1:8], E'\n') || case when v_cnt > 8 then E'\n외 ' || (v_cnt - 8) || '명' else '' end;
  insert into public.notifications (user_id, type, title, body, url, payload)
  select p.id, 'membership_fee_due', v_title, v_body, '/?feedue=1',
         jsonb_build_object('today', v_today, 'count', v_cnt, 'members', v_members, 'via', 'taam_membership_fee_notify')
    from public.profiles p
   where p.role in ('superadmin', 'super_admin') and p.deleted_at is null;
  get diagnostics v_n = row_count;
  begin
    v_push := public.taam_admin_push(v_title, v_push_body, '/?feedue=1', 'mfee-' || to_char(v_today, 'YYYYMMDD'), 'admin');
  exception when others then
    v_push := jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;
  return jsonb_build_object('ok', true, 'today', v_today, 'notified', v_cnt, 'superadmins', v_n, 'push', v_push);
end $$;
revoke all on function public.taam_membership_fee_notify(date) from public, anon;
grant execute on function public.taam_membership_fee_notify(date) to authenticated;

-- ── 5) 크론 — 매일 00:00 UTC = 09:00 KST (게스트 10시 · 방문 11시와 겹치지 않게). 함수가 DB 안에서 돌므로 Edge·JWT 가 필요 없다 ──
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') or exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
    begin perform cron.unschedule('taam-membership-fee-due'); exception when others then null; end;
    perform cron.schedule('taam-membership-fee-due', '0 0 * * *', $job$ select public.taam_membership_fee_notify(); $job$);
  else
    raise notice '⚠ pg_cron 없음 — 매일 자동 알림은 등록하지 못했다 (함수는 설치됨)';
  end if;
end $$;

create or replace function public._taam_fee_cron_registered()
returns boolean
language plpgsql stable
as $$
declare v boolean := false;
begin
  execute $q$select exists (select 1 from cron.job where jobname = 'taam-membership-fee-due')$q$ into v;
  return v;
exception when others then
  return false;
end $$;
revoke all on function public._taam_fee_cron_registered() from public, anon;

-- ── 6) 확인 — 한 표. ❌ 가 없어야 정상. ⑦ 은 이 자리에서 첫 알림을 한 번 실제로 보낸다(대상이 있으면 슈퍼어드민에게 인앱+푸시) ──
select '① 보고 RPC taam_membership_fee_due' as 항목,
       case when to_regprocedure('public.taam_membership_fee_due(uuid,date)') is not null then '✅' else '❌' end as 결과
union all select '② 알림 함수 taam_membership_fee_notify',
       case when to_regprocedure('public.taam_membership_fee_notify(date)') is not null then '✅' else '❌' end
union all select '③ 알림 기록 표 membership_fee_notices (RLS)',
       case when to_regclass('public.membership_fee_notices') is not null
             and exists (select 1 from pg_class c where c.oid = 'public.membership_fee_notices'::regclass and c.relrowsecurity) then '✅' else '❌' end
union all select '④ 매일 09:00 KST 크론 taam-membership-fee-due',
       case when public._taam_fee_cron_registered() then '✅' else '⚠ 없음 — pg_cron 미설치(함수는 설치됨)' end
union all select '⑤ anon 실행 권한 없음',
       case when has_function_privilege('anon', 'public.taam_membership_fee_due(uuid,date)', 'execute')
              or has_function_privilege('anon', 'public.taam_membership_fee_notify(date)', 'execute') then '❌ anon 이 부를 수 있음' else '✅' end
union all select '⑥ 지금 기준일 30일 내·밀린 회원',
       (select count(*) from public.taam_membership_fee_due() d where d.days_left <= 30)::text || '명 / 대상 ' || (select count(*) from public.taam_membership_fee_due())::text || '명'
union all select '⑦ 첫 알림 실행 결과 (notified = 알린 회원 수 · push.ok)',
       public.taam_membership_fee_notify()::text;
