-- ═══════════════════════════════════════════════════════════════
-- 회원 가입일을 셋으로 나눈다 — 앱 가입일 · 실제 멤버십 가입일 · 멤버십 시작일 (2026-10-15)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   멤버십은 앱이 생기기 전(2024-12)부터 받았다. 앱은 초대코드로 가입한 날(profiles.created_at)을 가입일로 보여 주니,
--   옛 회원에게는 「가입일」이 실제보다 1년 넘게 늦게 보인다. 운영 결정(2026-10-15):
--     ① 앱 가입일        = profiles.created_at (초대코드를 받아 가입한 날) — 그대로 둔다
--     ② 실제 멤버십 가입일 = profiles.membership_joined_at (이 파일이 만든다) — 슈퍼어드민만 적는다 (앱 이전 가입자)
--     ③ 멤버십 시작일     = 첫 초대 또는 첫 구매 (taam_member_start · 2026-10-13) — 그대로
--   회원에게는 둘만: 「가입일」(② 가 있으면 ②, 없으면 ①) · 「멤버십 시작일」(③). 셋을 따로 보는 건 슈퍼어드민 회원 원장뿐.
--
-- 무엇
--   · profiles.membership_joined_at date + 누가·언제(membership_joined_set_by/at — 트리거가 적는다, 앱은 못 적는다)
--   · trg_taam_guard_membership_joined — 회원 세션은 이 칸을 못 바꾼다(되돌림 · 예외 아님: 같은 UPDATE 의 다른 칸을 날리지 않게 role 가드와 같은 방식).
--     슈퍼어드민·서버만. 날짜는 2015-01-01 ~ 오늘(KST) 사이.
--   · taam_member_start 에 키 넷 추가: membership_joined_at · app_signup_date(KST 날짜) · joined_at(둘 중 회원에게 보여 줄 「가입일」) · joined_kind('manual'|'app').
--     날짜는 'YYYY-MM-DD' 문자열 — 해외 회원 기기에서 하루 밀리지 않게 앱이 시간대 변환 없이 그대로 찍는다.
--   앱 이전 가입자 22명의 실제 가입일은 sql/membership_joined_seed_2026-10-15.sql (SQL Editor · 이름으로 맞춘다).
-- 회귀: bash sql/_test/t_member_start.sh
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles add column if not exists membership_joined_at     date;
alter table public.profiles add column if not exists membership_joined_set_at timestamptz;
alter table public.profiles add column if not exists membership_joined_set_by uuid;
comment on column public.profiles.membership_joined_at is
  '실제 멤버십 가입일(앱 이전 가입자) — 슈퍼어드민만. 없으면 앱 가입일(created_at)을 가입일로 보여 준다. 2026-10-15';

-- ── 가드: 회원은 못 바꾼다 · 누가 언제 적었는지는 서버가 적는다 ──
create or replace function public.taam_guard_membership_joined()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_member boolean := (current_user in ('authenticated', 'anon') and not public._taam_uid_is_super());
begin
  if tg_op = 'INSERT' then
    if new.membership_joined_at is null then
      new.membership_joined_set_at := null; new.membership_joined_set_by := null;
      return new;
    end if;
    if v_member then
      raise warning '[guard] membership_joined_at 는 슈퍼어드민만 적습니다 (insert · uid=%)', auth.uid();
      new.membership_joined_at := null; new.membership_joined_set_at := null; new.membership_joined_set_by := null;
      return new;
    end if;
  else
    if new.membership_joined_at is not distinct from old.membership_joined_at then
      -- 날짜가 그대로면 누가·언제 칸도 그대로 — 앱이 실수로 비워 보내도 기록이 안 지워진다
      new.membership_joined_set_at := old.membership_joined_set_at;
      new.membership_joined_set_by := old.membership_joined_set_by;
      return new;
    end if;
    if v_member then
      raise warning '[guard] membership_joined_at 변경 차단: % → % (uid=%)', old.membership_joined_at, new.membership_joined_at, auth.uid();
      new.membership_joined_at     := old.membership_joined_at;
      new.membership_joined_set_at := old.membership_joined_set_at;
      new.membership_joined_set_by := old.membership_joined_set_by;
      return new;
    end if;
    if new.membership_joined_at is null then
      new.membership_joined_set_at := now(); new.membership_joined_set_by := auth.uid();   -- 지운 것도 기록
      return new;
    end if;
  end if;
  if new.membership_joined_at < date '2015-01-01' or new.membership_joined_at > v_today then
    raise exception 'BAD_JOINED_DATE: 실제 가입일은 2015-01-01 ~ 오늘(%) 사이여야 합니다', v_today using errcode = 'P0001';
  end if;
  new.membership_joined_set_at := now();
  new.membership_joined_set_by := auth.uid();     -- SQL Editor(postgres) 에서 적으면 null
  return new;
end;
$$;

drop trigger if exists trg_taam_guard_membership_joined on public.profiles;
create trigger trg_taam_guard_membership_joined
  before insert or update on public.profiles
  for each row execute function public.taam_guard_membership_joined();

comment on function public.taam_guard_membership_joined() is
  'profiles.membership_joined_at 는 슈퍼어드민·서버만(회원은 되돌림). 날짜 범위 검사 · set_by/set_at 는 트리거가 적는다. SECURITY DEFINER 로 바꾸지 말 것 — current_user 판정이 무너진다. 2026-10-15';

-- ── taam_member_start — 가입일 키 넷 추가 (나머지는 2026-10-13 그대로) ──
create or replace function public.taam_member_start(p_uid uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  u uuid := coalesce(p_uid, auth.uid());
  v_signup timestamptz; v_mj date; v_tk timestamptz; v_led timestamptz; v_inv timestamptz;
  v_buy timestamptz; v_start timestamptz; v_kind text; v_app date;
begin
  if u is null then return null; end if;
  if u <> auth.uid() and not public._taam_uid_is_super() then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select p.created_at, p.membership_joined_at into v_signup, v_mj from public.profiles p where p.id = u;
  if not found then return null; end if;
  select min(t.created_at) into v_tk
    from public.tickets t
   where t.user_id = u
     and coalesce(t.status, '') not in ('cancelled', 'hold', 'expired')
     and coalesce(t.purchase_id, '') not like 'PAYH-%'
     and coalesce(t.purchase_id, '') not like 'INVH-%'
     and coalesce(t.purchase_id, '') not like 'KSK-%'
     and coalesce(t.purchase_id, '') not like 'LINK-%'
     and coalesce(t.purchase_id, '') not like 'MAN-%';
  if to_regclass('public.deposit_transactions') is not null then
    select min(d.created_at) into v_led
      from public.deposit_transactions d
     where d.user_id = u and d.change_type = 'ticket_purchase';
  end if;
  if to_regclass('public.reservation_invites') is not null then
    select min(i.created_at) into v_inv
      from public.reservation_invites i
     where i.invitee_user_id = u and i.status = 'paid';
  end if;
  v_buy   := least(v_tk, v_led);           -- least 는 null 을 건너뛴다
  v_start := least(v_buy, v_inv);
  v_kind  := case when v_start is null then null
                  when v_inv is not null and v_inv <= coalesce(v_buy, v_inv) then 'invite'
                  else 'purchase' end;
  v_app   := case when v_signup is null then null else (v_signup at time zone 'Asia/Seoul')::date end;
  return jsonb_build_object(
    'uid',                  u,
    'signup_at',            v_signup,
    'app_signup_date',      v_app,                                   -- ① 앱 가입일 (KST 날짜)
    'membership_joined_at', v_mj,                                    -- ② 실제 멤버십 가입일 (슈퍼어드민이 적은 것 · 없으면 null)
    'joined_at',            coalesce(v_mj, v_app),                   -- 회원에게 보여 줄 「가입일」 = ② 있으면 ②, 없으면 ①
    'joined_kind',          case when v_mj is not null then 'manual' else 'app' end,
    'first_purchase_at',    v_buy,
    'first_invite_at',      v_inv,
    'start_at',             v_start,                                 -- ③ 멤버십 시작일
    'start_kind',           v_kind,
    'started',              (v_start is not null),
    'year_end_at',          case when v_start is null then null else v_start + interval '1 year' end
  );
end $$;

revoke all on function public.taam_member_start(uuid) from public;
grant execute on function public.taam_member_start(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 확인 (하나로) — ❌ 가 한 줄도 없어야 정상
-- ═══════════════════════════════════════════════════════════════
select '① profiles.membership_joined_at 컬럼' as 항목,
       case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='membership_joined_at') then '✅' else '❌' end as 결과
union all
select '② 가드 트리거 trg_taam_guard_membership_joined',
       case when exists (select 1 from pg_trigger where tgname='trg_taam_guard_membership_joined' and not tgisinternal) then '✅' else '❌' end
union all
select '③ taam_member_start 가 joined_at 을 돌려줌',
       case when (select prosrc from pg_proc where oid = to_regprocedure('public.taam_member_start(uuid)')) like '%joined_kind%' then '✅' else '❌' end
union all
select '④ 실제 가입일이 적힌 회원 수 (참고 · 시드 전엔 0)',
       '✅ ' || (select count(*) from public.profiles where membership_joined_at is not null)::text;
