-- ═══════════════════════════════════════════════════════════════
-- 멤버십 연회비 기록 — 회원 원장의 「멤버십 연회비」 탭 (2026-10-15)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   연회비는 티켓 구매·초대 결제와 별개의 돈인데, 어디에도 「연회비」로 적히지 않았다. 앱의 카드 결제 흐름(payments.type='membership' ·
--   deposit_transactions.change_type='membership_payment')은 포트원 시절 것이고, 실제 회원 대부분은 송금(해외는 외화)·정산 링크로 냈다 —
--   그 돈은 「예치금 부여」 원장 줄로만 남아 연회비인지 구분이 안 됐다. 그래서 연회비만 따로 적는 표를 둔다. 슈퍼어드민이 회원 원장 탭에서 적는다.
-- 무엇
--   membership_fees — 회원 · 납부일 · 원화 금액 · (외화면 통화·외화 금액) · 수단 · 기간(시작~종료, 보통 1년) · 등급 · 메모 · 출처.
--   RLS: 슈퍼어드민만 읽고 쓴다(회원 화면엔 이 탭이 없다 · 정책 없음 = 거부). created_by / updated_at 는 트리거가 적는다.
--   잔액·원장(deposit_transactions)은 건드리지 않는다 — 이 표는 「언제 얼마를 연회비로 받았나」의 기록이다. 예치금 부여는 종전대로 부여 화면에서.
-- 회귀: bash sql/_test/t_membership_fees.sh
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.membership_fees (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  paid_at     date not null,
  amount_krw  integer not null default 0 check (amount_krw >= 0),
  fx_currency text check (fx_currency is null or fx_currency in ('USD', 'JPY')),
  fx_amount   numeric(14,2) check (fx_amount is null or fx_amount >= 0),
  method      text not null default 'transfer' check (method in ('transfer', 'card', 'link', 'deposit', 'cash', 'other')),
  period_from date,
  period_to   date,
  tier        text check (tier is null or tier in ('M', 'T')),
  note        text,
  source      text not null default 'manual',      -- manual | app_payment | ledger
  source_ref  text,                                -- 앱 결제·원장 줄의 id 등
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  constraint membership_fees_period_ck check (period_from is null or period_to is null or period_to >= period_from)
);
comment on table public.membership_fees is
  '멤버십 연회비 납부 기록 — 회원 원장 「멤버십 연회비」 탭. 슈퍼어드민만. 잔액·원장과 별개의 기록. 2026-10-15';
create index if not exists idx_membership_fees_user on public.membership_fees(user_id, paid_at desc);

create or replace function public.taam_membership_fees_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.created_by is null then new.created_by := auth.uid(); end if;
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := null;
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.updated_at := now();
  end if;
  return new;
end;
$$;
drop trigger if exists trg_taam_membership_fees_stamp on public.membership_fees;
create trigger trg_taam_membership_fees_stamp
  before insert or update on public.membership_fees
  for each row execute function public.taam_membership_fees_stamp();

alter table public.membership_fees enable row level security;
drop policy if exists "membership_fees_super_all" on public.membership_fees;
create policy "membership_fees_super_all" on public.membership_fees
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );
grant select, insert, update, delete on public.membership_fees to authenticated;   -- RLS 가 슈퍼어드민만 통과시킨다

-- ═══════════════════════════════════════════════════════════════
-- 확인 (하나로) — ❌ 가 한 줄도 없어야 정상
-- ═══════════════════════════════════════════════════════════════
select '① membership_fees 표' as 항목,
       case when to_regclass('public.membership_fees') is not null then '✅' else '❌' end as 결과
union all
select '② RLS 켜짐',
       case when (select relrowsecurity from pg_class where oid = 'public.membership_fees'::regclass) then '✅' else '❌' end
union all
select '③ 슈퍼어드민 정책',
       case when exists (select 1 from pg_policies where schemaname='public' and tablename='membership_fees' and policyname='membership_fees_super_all') then '✅' else '❌' end
union all
select '④ created_by/updated_at 트리거',
       case when exists (select 1 from pg_trigger where tgname='trg_taam_membership_fees_stamp' and not tgisinternal) then '✅' else '❌' end
union all
select '⑤ 기록 수 (참고)', '✅ ' || (select count(*) from public.membership_fees)::text;
