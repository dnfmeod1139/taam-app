-- ═══════════════════════════════════════════════════════════════
-- 원장 서버화를 재보기 위한 최소 표 (2026-09-04)
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 타입을 **짐작하지 않는다.** 2026-09-04 사고가 정확히 그것이었다 —
--     `deposit_transactions.payment_id` 가 uuid 인데 함수는 text 를 넣었다.
--     로컬 픽스처를 text 로 만들어 두면 그 사고가 여기서 **재현되지 않는다.**
--     라이브에서 확인한 모양 그대로 적는다.
-- ═══════════════════════════════════════════════════════════════
-- ⚠ auth 도 같이 지운다. 남겨 두면 두 번째 실행에서 「users 가 이미 있다」로
--   픽스처가 죽고, 그걸 함수 문제로 착각하게 된다.
drop schema if exists public cascade; create schema public;
drop schema if exists auth   cascade; create schema auth;
create table auth.users(id uuid primary key);

create table public.profiles(
  id uuid primary key, role text, display_name text,
  membership_deposit_balance bigint default 0,
  general_deposit_balance    bigint default 0,
  deposit_balance            bigint default 0,
  created_at timestamptz default now());

create table public.deposit_transactions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  deposit_type  text,
  change_type   text,
  amount        bigint,
  balance_after bigint,
  description   text,
  payment_id    uuid,          -- ⭐ 여기가 uuid 다. text 로 바꾸지 말 것.
  metadata      jsonb,
  created_at timestamptz default now());

-- 합계는 서버가 맞춘다 (라이브의 trg_taam_sync_deposit_balance 와 같은 뜻)
create or replace function public._fx_sync_total() returns trigger
language plpgsql as $$
begin
  new.deposit_balance := coalesce(new.membership_deposit_balance,0)
                       + coalesce(new.general_deposit_balance,0);
  return new;
end $$;
create trigger _fx_sync_total before insert or update on public.profiles
  for each row execute function public._fx_sync_total();

-- auth.uid() 흉내
create or replace function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('taam.uid', true), '')::uuid $$;

-- 역할은 DB 에 남는다 — 두 번째 실행에서 「이미 있다」로 죽지 않게
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated;
  end if;
end $$;
grant usage on schema public, auth to authenticated;
grant select, insert, update on all tables in schema public to authenticated;
