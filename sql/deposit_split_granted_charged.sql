-- ═══════════════════════════════════════════════════════════════
-- TAAM — 예치금 부여/충전 구분
-- 작성일: 2026-05-18
--
-- 목적:
--   기존 단일 컬럼 (membership_deposit_balance, general_deposit_balance) 을
--   "부여(granted) vs 충전(charged)" 로 구분해서 추적.
--
--   - 슈퍼어드민이 부여한 예치금: granted_*_balance
--   - 회원이 직접 충전(결제)한 예치금: charged_*_balance
--   - 합계 = 기존 *_balance (호환성 유지, 자동 합계 트리거로 동기화)
-- ═══════════════════════════════════════════════════════════════

do $$
begin
  if to_regclass('public.profiles') is not null then
    alter table public.profiles
      -- 부여(granted): 슈퍼어드민이 admin_grant 한 누적 잔액
      add column if not exists granted_membership_balance bigint default 0,
      add column if not exists granted_general_balance    bigint default 0,
      -- 충전(charged): 회원이 결제로 충전한 누적 잔액 (사용 시 차감)
      add column if not exists charged_membership_balance bigint default 0,
      add column if not exists charged_general_balance    bigint default 0;

    comment on column public.profiles.granted_membership_balance is
      '슈퍼어드민이 부여한 멤버십 예치금 잔액 (admin_grant 누적, admin_deduct 차감)';
    comment on column public.profiles.granted_general_balance is
      '슈퍼어드민이 부여한 일반 예치금 잔액';
    comment on column public.profiles.charged_membership_balance is
      '회원이 충전한 멤버십 예치금 잔액 (charge 누적, use/refund 차감)';
    comment on column public.profiles.charged_general_balance is
      '회원이 충전한 일반 예치금 잔액';

    raise notice '✓ profiles 분리 컬럼 4개 추가 완료';
  end if;
end $$;

-- ── 변동 트리거: deposit_transactions INSERT 시 자동 분기 ──
-- change_type 에 따라 granted_* 또는 charged_* 잔액 업데이트
create or replace function public.sync_split_balance_on_deposit_trx()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  field_name text;
  is_granted boolean;
begin
  -- change_type 분류
  is_granted := new.change_type in ('admin_grant', 'admin_deduct');

  -- 분리 컬럼 이름 결정
  if new.deposit_type = 'membership' then
    field_name := case when is_granted then 'granted_membership_balance' else 'charged_membership_balance' end;
  elsif new.deposit_type = 'general' then
    field_name := case when is_granted then 'granted_general_balance' else 'charged_general_balance' end;
  else
    return new;  -- 알 수 없는 type 은 분리 안 함
  end if;

  -- 분리 컬럼 업데이트 (음수 방지)
  execute format(
    'update public.profiles set %I = greatest(0, coalesce(%I, 0) + $1) where id = $2',
    field_name, field_name
  ) using new.amount, new.user_id;

  return new;
end;
$$;

drop trigger if exists trg_sync_split_balance on public.deposit_transactions;
create trigger trg_sync_split_balance
after insert on public.deposit_transactions
for each row execute function public.sync_split_balance_on_deposit_trx();

-- ── 일회성 보정: 기존 데이터 재집계 (선택, 첫 실행 시) ──
-- 이미 발생한 거래들을 분리 컬럼에 반영
do $$
declare
  r record;
begin
  for r in
    select
      user_id,
      deposit_type,
      change_type,
      sum(amount) as total
    from public.deposit_transactions
    group by user_id, deposit_type, change_type
  loop
    if r.deposit_type = 'membership' then
      if r.change_type in ('admin_grant', 'admin_deduct') then
        update public.profiles
          set granted_membership_balance = greatest(0, coalesce(granted_membership_balance, 0) + r.total)
        where id = r.user_id;
      else
        update public.profiles
          set charged_membership_balance = greatest(0, coalesce(charged_membership_balance, 0) + r.total)
        where id = r.user_id;
      end if;
    elsif r.deposit_type = 'general' then
      if r.change_type in ('admin_grant', 'admin_deduct') then
        update public.profiles
          set granted_general_balance = greatest(0, coalesce(granted_general_balance, 0) + r.total)
        where id = r.user_id;
      else
        update public.profiles
          set charged_general_balance = greatest(0, coalesce(charged_general_balance, 0) + r.total)
        where id = r.user_id;
      end if;
    end if;
  end loop;
  raise notice '✓ 과거 거래 재집계 완료';
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 검증 (실행 후):
--   select id, display_name,
--          membership_deposit_balance, granted_membership_balance, charged_membership_balance,
--          general_deposit_balance, granted_general_balance, charged_general_balance
--   from public.profiles
--   where role in ('super_admin','admin')
--   limit 10;
-- ═══════════════════════════════════════════════════════════════
