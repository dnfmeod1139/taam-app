-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원 자격 종료일 (member_until) 컬럼 + 자동 계산 (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 정책:
--   ① 가입일(created_at) 기준 1년 후 = 기본 종료일
--   ② 프로모션: 2026-12-31 이전 가입 → 종료일 = 2027-12-31 23:59:59 (한국 시간)
--   ③ 슈퍼어드민이 개별 수정 가능 (admin_deposit_grant_policies 의
--     "super_admin can update any profile balance" 정책이 모든 컬럼 update 허용)
--
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (1회).
-- 트리거 + 함수 + 기존 회원 backfill 까지 한 번에 처리.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. member_until 컬럼 추가 ──
alter table public.profiles
  add column if not exists member_until timestamptz;

comment on column public.profiles.member_until is
  '회원 자격 종료일. 가입일+1년 또는 프로모션 적용 시 2027-12-31. 슈퍼어드민이 수정 가능.';

-- ── 2. 종료일 자동 계산 함수 ──
create or replace function public.calc_member_until(signup_at timestamptz)
returns timestamptz
language sql
immutable
as $$
  select case
    -- 프로모션: 2026-12-31 이전 가입 → 2027-12-31 23:59:59 한국시간 (= UTC 2027-12-31 14:59:59)
    when signup_at < timestamptz '2027-01-01 00:00:00+09'
      then timestamptz '2027-12-31 23:59:59+09'
    -- 기본: 가입일 + 1년
    else signup_at + interval '1 year'
  end;
$$;

comment on function public.calc_member_until(timestamptz) is
  '가입일 기준 회원 종료일 자동 계산. 2026-12-31 이전 가입은 프로모션 (2027-12-31), 그 외 +1년.';

-- ── 3. 신규 가입 트리거 (BEFORE INSERT) ──
create or replace function public.trg_set_member_until()
returns trigger
language plpgsql
as $$
begin
  if new.member_until is null then
    new.member_until := public.calc_member_until(coalesce(new.created_at, now()));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_member_until on public.profiles;
create trigger trg_profiles_member_until
  before insert on public.profiles
  for each row execute function public.trg_set_member_until();

-- ── 4. 기존 회원 backfill (member_until 비어있는 row 만) ──
update public.profiles
set member_until = public.calc_member_until(coalesce(created_at, now()))
where member_until is null;

-- ── 검증 쿼리 (실행 후 확인용) ──
-- 전체 분포 — 프로모션 vs 일반
select
  case
    when member_until = timestamptz '2027-12-31 23:59:59+09' then '프로모션 (2027-12-31)'
    else '일반 (가입+1년)'
  end as category,
  count(*) as cnt
from public.profiles
where member_until is not null
group by 1
order by 1;

-- 샘플 10명
select
  id,
  display_name,
  email,
  phone,
  created_at,
  member_until,
  case
    when member_until = timestamptz '2027-12-31 23:59:59+09' then '프로모션'
    else '일반'
  end as type
from public.profiles
order by created_at desc nulls last
limit 10;

do $$ begin raise notice '✅ profiles.member_until 컬럼 + 트리거 + backfill 설치 완료'; end $$;
