-- ═══════════════════════════════════════════════════════════════
-- TAAM — 슈퍼어드민 예치금 부여/차감 RLS 정책
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-15
-- 목적:
--   슈퍼어드민(profiles.role = 'super_admin' 또는 'superadmin') 만
--   다른 사용자의 profiles.{membership,general}_deposit_balance UPDATE 와
--   deposit_transactions INSERT(타인 명의) 가 가능하도록 RLS 정책 추가.
-- 안전장치:
--   ① 일반 회원/관리자는 본인 외 잔액 변경 불가
--   ② 모든 변경은 deposit_transactions 에 admin_grant / admin_deduct 로 기록
--   ③ 잔액 음수 방지는 클라이언트 + 트리거(선택) 양쪽에서
-- ═══════════════════════════════════════════════════════════════

-- ── 0. 사전 조건 — profiles.role 컬럼 + super_admin 값 ──
-- (이미 있는 경우 if not exists 로 skip)
do $$
begin
  if to_regclass('public.profiles') is not null then
    alter table public.profiles
      add column if not exists role text default 'member';
    comment on column public.profiles.role is '사용자 역할: member | admin | partner | super_admin';
    raise notice '✓ profiles.role 컬럼 확인 / 추가 완료';
  end if;
end $$;

-- ── 1. 슈퍼어드민 식별 헬퍼 함수 (security definer 로 RLS 우회) ──
create or replace function public.is_super_admin(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select role in ('super_admin', 'superadmin') from public.profiles where id = uid),
    false
  );
$$;

comment on function public.is_super_admin(uuid) is
  '주어진 user_id 의 role 이 super_admin / superadmin 인지 검사. RLS 정책에서 사용.';

-- ── 2. profiles UPDATE 정책 — 슈퍼어드민이 다른 사용자 잔액 변경 허용 ──
-- 기존 정책이 있으면 drop 후 재생성 (idempotent)
drop policy if exists "super_admin can update any profile balance" on public.profiles;

create policy "super_admin can update any profile balance"
on public.profiles
for update
to authenticated
using ( public.is_super_admin(auth.uid()) )
with check ( public.is_super_admin(auth.uid()) );

-- ── 3. deposit_transactions INSERT 정책 — 슈퍼어드민이 타인 명의 기록 허용 ──
drop policy if exists "super_admin can insert any deposit transaction" on public.deposit_transactions;

create policy "super_admin can insert any deposit transaction"
on public.deposit_transactions
for insert
to authenticated
with check (
  -- 본인 거래는 항상 허용 (depositTransaction 함수)
  user_id = auth.uid()
  -- 슈퍼어드민은 다른 사용자 명의로도 기록 가능
  or public.is_super_admin(auth.uid())
);

-- ── 4. deposit_transactions SELECT 정책 — 슈퍼어드민은 전체 조회 가능 ──
drop policy if exists "super_admin can read all deposit transactions" on public.deposit_transactions;

create policy "super_admin can read all deposit transactions"
on public.deposit_transactions
for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_super_admin(auth.uid())
);

-- ── 5. profiles SELECT 정책 — 슈퍼어드민은 전체 조회 가능 (회원 검색용) ──
drop policy if exists "super_admin can read all profiles" on public.profiles;

create policy "super_admin can read all profiles"
on public.profiles
for select
to authenticated
using (
  id = auth.uid()
  or public.is_super_admin(auth.uid())
);

-- ═══════════════════════════════════════════════════════════════
-- 검증 쿼리 (실행 후):
--
-- 1) 정책 목록 확인:
--    select schemaname, tablename, policyname, cmd
--    from pg_policies
--    where tablename in ('profiles','deposit_transactions')
--    order by tablename, policyname;
--
-- 2) 슈퍼어드민 지정 (사용자 본인 user_id 로 변경):
--    update public.profiles
--    set role = 'super_admin'
--    where id = '<본인 user_id (auth.users.id)>';
--
-- 3) 슈퍼어드민 함수 동작 확인:
--    select public.is_super_admin(auth.uid()) as am_i_super;
-- ═══════════════════════════════════════════════════════════════

-- ── 6. (옵션) 잔액 음수 방지 트리거 ──
-- 클라이언트에서 이미 가드하지만, DB 레벨에서도 보호.
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

-- 완료
do $$ begin raise notice '✅ 슈퍼어드민 예치금 부여 RLS 정책 + 트리거 설치 완료'; end $$;
