-- ═══════════════════════════════════════════════════════════════
-- 연회비 기준일 — 회원은 두 부류다 (2026-10-19 운영 결정)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 종전 「납부 시기」는 전원에게 가입일(실제 가입일 → 없으면 앱 가입일)을 기준으로 삼았다. 그런데 앱 이후 가입자는 가입 뒤 한참 지나 첫 구매·초대 결제가
--     이뤄지는 일이 많고, 가입 때 예치금을 부여하면서 첫해 연회비(10%)를 이미 제외하고 넣어 준다. 그래서 두 부류를 가른다 —
--     ① **앱 이전 계약 회원**(슈퍼어드민이 적은 실제 가입일 membership_joined_at 이 있는 회원): 그 날이 기준. 프로모션(2027.12.31) 과 무관.
--     ② **앱 이후 가입자**(실제 가입일이 없는 회원): **첫 구매 또는 초대 결제일**(예치금·카드·링크 무관 — taam_member_start 와 같은 식 · 회원 소유 LINK- 포함)이 기준이고,
--        첫해 연회비는 가입 때 제외돼 받은 것으로 보아 기록이 없어도 납부 1건으로 센다(implicit_first). 첫 구매·초대가 아직 없으면 「시작 전」 — 기준일·알림 없음.
--     둘 다 보이게 앱 가입일(app_signup_date)·실제 가입일(membership_joined_at)·시작일(start_at)·기준 종류(anchor_kind)를 함께 돌려준다.
-- 무엇: ① 도우미 _taam_member_start_at(uid) — 첫 구매(tickets · 원장 ticket_purchase)·첫 초대 결제(reservation_invites paid) 중 빠른 시각. 서버 전용(호출자 검사 없음 · execute 회수).
--     ② taam_membership_fee_due 를 **같은 이름·같은 인자**로 다시 만든다 — 반환 표에 칸이 늘어 drop → create. 종전 칸(joined_at·paid·due_date·days_left·short·ahead…)은 그대로라
--        taam_membership_fee_notify(매일 알림)·앱 화면은 손대지 않아도 돈다. paid 는 「실효 납부 건수」(implicit 포함) · paid_recorded 가 기록 건수.
--     ⚠ 라이브 함수 교체 — 본문 md5 가 저장소 원본(20261017_membership_fee_exempt.sql 판)과 같을 때만. 다르면 ❌ 로 건너뛴다.
-- 영향: ②부류 회원의 기준일이 바뀌면 membership_fee_notices 의 열쇠(회원·기준일·단계)가 새것이 되어 **한 번 다시 알린다** — 예상된 일.
--     멤버십 종료일(profiles.member_until · 「회원 멤버십 만료일 관리」)은 이 파일이 건드리지 않는다 — 화면이 기준일을 나란히 보여 주고 바꾸는 건 사람이.
-- 회귀: bash sql/_test/t_fee_due_anchor.sh
-- ═══════════════════════════════════════════════════════════════

-- ── ① 첫 구매·초대 결제 시각 (서버 전용) ──
create or replace function public._taam_member_start_at(p_uid uuid)
returns timestamptz
language plpgsql stable security definer set search_path = public
as $$
declare v_tk timestamptz; v_led timestamptz; v_inv timestamptz;
begin
  if p_uid is null then return null; end if;
  select min(t.created_at) into v_tk
    from public.tickets t
   where t.user_id = p_uid
     and coalesce(t.status, '') not in ('cancelled', 'hold', 'expired')
     and coalesce(t.purchase_id, '') not like 'PAYH-%'
     and coalesce(t.purchase_id, '') not like 'INVH-%'
     and coalesce(t.purchase_id, '') not like 'KSK-%'
     and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
     and coalesce(t.purchase_id, '') not like 'MAN-%';
  if to_regclass('public.deposit_transactions') is not null then
    select min(d.created_at) into v_led from public.deposit_transactions d where d.user_id = p_uid and d.change_type = 'ticket_purchase';
  end if;
  if to_regclass('public.reservation_invites') is not null then
    select min(i.created_at) into v_inv from public.reservation_invites i where i.invitee_user_id = p_uid and i.status = 'paid';
  end if;
  return least(v_tk, v_led, v_inv);
end $$;
revoke all on function public._taam_member_start_at(uuid) from public, anon, authenticated;

-- ── ② 보고 함수 (md5 가드 · drop → create) ──
drop table if exists _fda; create temp table _fda(name text primary key, status text);
do $do$
declare v_live text;
begin
  select md5(p.prosrc) into v_live from pg_proc p where p.oid = to_regprocedure('public.taam_membership_fee_due(uuid,date,boolean)');
  if v_live is null then
    insert into _fda values ('taam_membership_fee_due', '❌ 라이브에 함수가 없다 — 20261017_membership_fee_due.sql · 20261017_membership_fee_exempt.sql 먼저');
  elsif v_live <> '04af3457c5e06ccec06359ffc9f55c95' then
    if exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_membership_fee_due(uuid,date,boolean)') and p.prosrc like '%implicit_first%') then
      insert into _fda values ('taam_membership_fee_due', '✅ 이미 새 판(두 부류)');
    else
      insert into _fda values ('taam_membership_fee_due', '❌ 라이브 본문이 저장소 원본(20261017 exempt 판)과 다르다 — 건너뜀 (md5 ' || v_live || ')');
    end if;
  else
    execute 'drop function public.taam_membership_fee_due(uuid, date, boolean)';
    execute $fn$
create or replace function public.taam_membership_fee_due(p_uid uuid default null, p_today date default null, p_include_exempt boolean default false)
returns table (
  user_id uuid, display_name text, tier text, currency text, joined_at date, joined_kind text,
  years int, paid int, due_date date, days_left int, short int, ahead int, last_paid date, fee_hint text,
  fee_exempt boolean, fee_exempt_note text,
  anchor_kind text, anchor_date date, app_signup_date date, membership_joined_at date, start_at date, implicit_first boolean, paid_recorded int
)
language plpgsql stable security definer set search_path = public
as $b$
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
           p.membership_joined_at as mj,
           (p.created_at at time zone 'Asia/Seoul')::date as appd,
           (public._taam_member_start_at(p.id) at time zone 'Asia/Seoul')::date as sd,
           (select count(*) from public.membership_fees f where f.user_id = p.id)::int
         + (select count(distinct coalesce(t.payment_id::text, to_char(t.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD')))
              from public.deposit_transactions t where t.user_id = p.id and t.change_type = 'membership_payment')::int as paid_rec,
           (select max(f.paid_at) from public.membership_fees f where f.user_id = p.id) as last_paid,
           coalesce(p.fee_exempt, false) as ex, p.fee_exempt_note as exn
      from public.profiles p
     where p.deleted_at is null
       and p.membership_tier in ('M', 'T')
       and coalesce(p.role, '') not in ('superadmin', 'super_admin', 'admin')
       and (p_include_exempt or not coalesce(p.fee_exempt, false))
       and (p_uid is null or p.id = p_uid)
  ), a as (
    -- 🆕 2026-10-19 두 부류 (운영 결정)
    --   ① 앱 이전 계약 회원 = 실제 가입일(membership_joined_at)이 적힌 회원 → 그 날이 기준. 프로모션 무관.
    --   ② 앱 이후 가입자 = 첫 구매 또는 초대 결제일(예치금·카드 무관)이 기준. 첫해 연회비는 가입 때 예치금 부여에서 제외돼 받았으므로 기록이 없어도 1건으로 본다(implicit_first).
    --      아직 첫 구매·초대가 없으면 「시작 전」 — 기준일 없음(알림 없음), 앱 가입일만 보여 준다.
    select m.*,
           case when m.mj is not null then 'joined' when m.sd is not null then 'start' else 'none' end as kind,
           case when m.mj is not null then m.mj else m.sd end as anchor,
           case when m.mj is null and m.sd is not null then greatest(m.paid_rec, 1) else m.paid_rec end as paid_eff,
           (m.mj is null and m.sd is not null and m.paid_rec = 0) as implicit
      from m
  ), c as (
    select a.*,
           case when a.anchor is null then 0 else public._taam_fee_years(a.anchor, v_today) end as yrs,
           case when a.anchor is null then null else (a.anchor + make_interval(years => a.paid_eff))::date end as due
      from a
  )
  select c.id, c.display_name, c.tier, c.cur,
         coalesce(c.mj, c.appd) as joined_at, case when c.mj is not null then 'manual' else 'app' end as joined_kind,
         c.yrs, c.paid_eff, c.due, case when c.due is null then null else (c.due - v_today)::int end,
         greatest(0, c.yrs - c.paid_eff), greatest(0, c.paid_eff - c.yrs), c.last_paid,
         case when c.cur = 'KRW' then (case when c.tier = 'M' then '₩1,125,000' else '₩630,000' end)
              when c.cur = 'USD' then (case when c.tier = 'M' then '$990' else '$300' end)
              else c.cur || ' — 규정 없음' end,
         c.ex, c.exn,
         c.kind, c.anchor, c.appd, c.mj, c.sd, c.implicit, c.paid_rec
    from c
   order by c.ex, c.due nulls last, c.display_name;
end $b$;
$fn$;
    execute 'revoke all on function public.taam_membership_fee_due(uuid, date, boolean) from public, anon';
    execute 'grant execute on function public.taam_membership_fee_due(uuid, date, boolean) to authenticated';
    insert into _fda values ('taam_membership_fee_due', '✅ 교체 (두 부류 기준)');
  end if;
end $do$;

-- ── 확인 — 한 표 ──
select '① ' || name as 항목, status as 결과 from _fda
union all select '② 도우미 _taam_member_start_at · 서버 전용', case when to_regproc('public._taam_member_start_at') is not null and not has_function_privilege('authenticated', 'public._taam_member_start_at(uuid)', 'execute') then '✅' else '❌' end
union all select '③ 새 칸(anchor_kind · start_at · implicit_first)', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_membership_fee_due(uuid,date,boolean)') and p.prosrc like '%implicit_first%') then '✅' else '❌' end
union all select '④ 매일 알림 함수는 그대로 돈다 (select * 로 읽는다)', case when to_regproc('public.taam_membership_fee_notify') is not null then '✅' else '❌ 20261017_membership_fee_due.sql' end
union all select '⑤ 지금 분포 (정보) — 실제 가입일 기준 · 첫 구매 기준 · 시작 전', coalesce((select count(*) filter (where anchor_kind = 'joined') || ' · ' || count(*) filter (where anchor_kind = 'start') || ' · ' || count(*) filter (where anchor_kind = 'none') from public.taam_membership_fee_due(null, null, true)), '-')
order by 1;
