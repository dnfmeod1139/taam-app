-- ═══════════════════════════════════════════════════════════════
-- TAAM — 슈퍼어드민 예치금 부여도 RPC 로 (2026-09-14)
-- ═══════════════════════════════════════════════════════════════
-- 앱의 adminGrantDeposit 이 마지막까지 profiles 를 직접 update 하고 원장을 따로
-- INSERT 하던 금전 경로였다. 이제 taam_apply_deposit_delta 에 admin_grant /
-- admin_deduct 원장을 실어 한 트랜잭션으로 보낸다 (빌드 2026.09.14-i).
--
-- 이 파일이 하는 것
--   ① 「부여 누적」(granted_*_balance) 을 맞추는 트리거를 확실히 둔다.
--      종전 앱은 granted_* 를 손으로 더했다. RPC 는 그 컬럼을 모른다 — 원장
--      INSERT 에 붙은 trg_sync_split_balance 가 대신 더한다. 이 트리거가 없으면
--      부여 누적이 멈추므로, 있든 없든 같은 모양으로 다시 만든다(멱등).
--      ⚠ sql/deposit_split_granted_charged.sql 은 돌리지 말 것 — 끝에 「과거 거래
--        재집계」가 있어 두 번 돌리면 누적이 두 배가 된다.
--   ② 진단: 부여 누적이 원장 합계와 맞는지 회원별로 본다.
--      앱이 손으로 더하는 동안 트리거도 살아 있었다면 **두 배**로 쌓여 있을 수
--      있다. 여기서는 보기만 한다 — 고치는 SQL 은 결과를 본 뒤 따로 준다.
--
-- 실행: Supabase SQL Editor 에 통째로. 여러 번 돌려도 안전.
-- 결과: 마지막 표 — 위 3줄(구분 ①~③)은 ✅ 여야 하고, 그 아래 회원 줄은
--       「차이」가 0 이 아닌 회원만 나온다 (한 줄도 없으면 정상).
-- ═══════════════════════════════════════════════════════════════

begin;

do $$
begin
  if to_regclass('public.profiles') is not null then
    alter table public.profiles
      add column if not exists granted_membership_balance bigint default 0,
      add column if not exists granted_general_balance    bigint default 0,
      add column if not exists charged_membership_balance bigint default 0,
      add column if not exists charged_general_balance    bigint default 0;
  end if;
end $$;

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
  is_granted := new.change_type in ('admin_grant', 'admin_deduct');
  if new.deposit_type = 'membership' then
    field_name := case when is_granted then 'granted_membership_balance' else 'charged_membership_balance' end;
  elsif new.deposit_type = 'general' then
    field_name := case when is_granted then 'granted_general_balance' else 'charged_general_balance' end;
  else
    return new;
  end if;
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

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 + 진단 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
with led as (
  select user_id,
         sum(amount) filter (where deposit_type = 'membership' and change_type in ('admin_grant','admin_deduct')) as mem,
         sum(amount) filter (where deposit_type = 'general'    and change_type in ('admin_grant','admin_deduct')) as gen
    from public.deposit_transactions
   group by user_id
)
select '① 부여 누적 트리거' as "구분",
       case when count(*) = 1 then '✅' else '❌ 없음' end as "상태",
       'trg_sync_split_balance (after insert on deposit_transactions)' as "메모"
  from pg_trigger where tgname = 'trg_sync_split_balance' and not tgisinternal
union all
select '② RPC 가 4인자·서버 호출 길',
       case when max(p.prosrc) like '%LEDGER_INSUFFICIENT%' then '✅' else '❌ ledger_close_member_insert.sql 먼저' end,
       ''
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
union all
select '③ 원장 INSERT 정책 = 슈퍼어드민만',
       case when count(*) filter (where policyname = 'deposit_tx_insert_server') = 1 then '✅' else '❌' end,
       ''
  from pg_policies where schemaname = 'public' and tablename = 'deposit_transactions'
union all
select '회원 ' || coalesce(p.display_name, left(p.id::text, 8)),
       '⚠ 차이',
       '멤버십 누적 ' || coalesce(p.granted_membership_balance,0) || ' vs 원장 ' || greatest(0, coalesce(l.mem,0))
       || ' · 일반 누적 ' || coalesce(p.granted_general_balance,0) || ' vs 원장 ' || greatest(0, coalesce(l.gen,0))
  from public.profiles p left join led l on l.user_id = p.id
 where coalesce(p.granted_membership_balance,0) <> greatest(0, coalesce(l.mem,0))
    or coalesce(p.granted_general_balance,0)    <> greatest(0, coalesce(l.gen,0))
order by 1;
