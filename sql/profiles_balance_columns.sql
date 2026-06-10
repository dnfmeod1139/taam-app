-- ═══════════════════════════════════════════════════════════════
-- TAAM — profiles 테이블에 예치금 추적 컬럼 추가
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-21
-- 목적:
--   ① 멤버십 예치금 / 일반 예치금 현재 잔액
--   ② 슈퍼어드민이 부여한 예치금 누적
--   ③ 회원이 충전한 예치금 누적
-- 사용처:
--   - 슈퍼어드민 회원 예치금 부여/차감 모달
--   - 마이페이지 잔액 표시
--   - 결제 시 잔액 차감
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 6개 컬럼 추가 (idempotent) ──
alter table public.profiles
  add column if not exists membership_deposit_balance bigint default 0,
  add column if not exists general_deposit_balance bigint default 0,
  add column if not exists granted_membership_balance bigint default 0,
  add column if not exists granted_general_balance bigint default 0,
  add column if not exists charged_membership_balance bigint default 0,
  add column if not exists charged_general_balance bigint default 0;

-- ── 2. 컬럼 설명 ──
comment on column public.profiles.membership_deposit_balance is '멤버십 예치금 현재 잔액 (부여 + 충전 - 사용)';
comment on column public.profiles.general_deposit_balance is '일반 예치금 현재 잔액';
comment on column public.profiles.granted_membership_balance is '슈퍼어드민이 부여한 멤버십 예치금 누적';
comment on column public.profiles.granted_general_balance is '슈퍼어드민이 부여한 일반 예치금 누적';
comment on column public.profiles.charged_membership_balance is '회원이 충전한 멤버십 예치금 누적';
comment on column public.profiles.charged_general_balance is '회원이 충전한 일반 예치금 누적';

-- ── 3. 기존 NULL → 0 정리 ──
update public.profiles set
  membership_deposit_balance = coalesce(membership_deposit_balance, 0),
  general_deposit_balance = coalesce(general_deposit_balance, 0),
  granted_membership_balance = coalesce(granted_membership_balance, 0),
  granted_general_balance = coalesce(granted_general_balance, 0),
  charged_membership_balance = coalesce(charged_membership_balance, 0),
  charged_general_balance = coalesce(charged_general_balance, 0);

-- ── 4. 음수 방지 트리거 (기존에 있을 수 있음) ──
-- 멤버십/일반 예치금 잔액이 음수가 되지 않도록 보호
create or replace function public.guard_deposit_balance_non_negative()
returns trigger
language plpgsql
as $$
begin
  if new.membership_deposit_balance is not null and new.membership_deposit_balance < 0 then
    raise exception '멤버십 예치금 잔액은 음수일 수 없습니다 (값: %)', new.membership_deposit_balance;
  end if;
  if new.general_deposit_balance is not null and new.general_deposit_balance < 0 then
    raise exception '일반 예치금 잔액은 음수일 수 없습니다 (값: %)', new.general_deposit_balance;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_deposit_balance on public.profiles;
create trigger trg_guard_deposit_balance
before insert or update on public.profiles
for each row execute function public.guard_deposit_balance_non_negative();

-- ── 5. 검증 ──
select column_name, data_type, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'profiles'
  and column_name like '%balance%'
order by column_name;

-- ── 완료 ──
do $$ begin
  raise notice '✅ profiles 예치금 컬럼 6개 + 음수 방지 트리거 설치 완료';
end $$;
