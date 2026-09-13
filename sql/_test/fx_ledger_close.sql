-- ═══════════════════════════════════════════════════════════════
-- 원장 4단계(회원 INSERT 닫기) 재보기용 — fx_ledger.sql 위에 덧댄다 (2026-09-14)
-- ═══════════════════════════════════════════════════════════════
--   라이브 모양을 베낀다:
--     · deposit_transactions 에 RLS + 옛 정책(deposit_tx_insert_own · deposit_tx_select_own)
--     · _taam_uid_is_super() · is_superadmin()  (audit_hardening · 기존)
--     · 역할 service_role · authenticator(login) — PostgREST 는 authenticator 로
--       접속해 set role 한다. session_user 가 postgres 가 아니어야 서버 길이
--       제대로 재보인다.
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator login; end if;
end $$;
grant authenticated, service_role, anon to authenticator;
grant usage on schema public, auth to service_role, anon;
grant select, insert, update on all tables in schema public to service_role;

create or replace function public._taam_uid_is_super()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p
                  where p.id = auth.uid() and p.role in ('super_admin','superadmin'))
$$;
create or replace function public.is_superadmin()
returns boolean language sql stable security definer set search_path = public as $$
  select public._taam_uid_is_super()
$$;

alter table public.deposit_transactions enable row level security;
create policy deposit_tx_select_own on public.deposit_transactions
  for select to authenticated using ((auth.uid() = user_id) or public.is_superadmin());
create policy deposit_tx_insert_own on public.deposit_transactions
  for insert to authenticated with check ((auth.uid() = user_id) or public.is_superadmin());

-- 부여 누적(granted_*) — 라이브의 trg_sync_split_balance 와 같은 뜻 (sql/admin_grant_via_rpc.sql 과 동일)
alter table public.profiles
  add column if not exists granted_membership_balance bigint default 0,
  add column if not exists granted_general_balance    bigint default 0,
  add column if not exists charged_membership_balance bigint default 0,
  add column if not exists charged_general_balance    bigint default 0;
create or replace function public.sync_split_balance_on_deposit_trx()
returns trigger language plpgsql security definer set search_path = public as $$
declare field_name text; is_granted boolean;
begin
  is_granted := new.change_type in ('admin_grant', 'admin_deduct');
  if new.deposit_type = 'membership' then
    field_name := case when is_granted then 'granted_membership_balance' else 'charged_membership_balance' end;
  elsif new.deposit_type = 'general' then
    field_name := case when is_granted then 'granted_general_balance' else 'charged_general_balance' end;
  else return new; end if;
  execute format('update public.profiles set %I = greatest(0, coalesce(%I, 0) + $1) where id = $2', field_name, field_name)
    using new.amount, new.user_id;
  return new;
end $$;
drop trigger if exists trg_sync_split_balance on public.deposit_transactions;
create trigger trg_sync_split_balance after insert on public.deposit_transactions
  for each row execute function public.sync_split_balance_on_deposit_trx();
