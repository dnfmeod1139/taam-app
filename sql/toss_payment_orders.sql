-- ═══════════════════════════════════════════════════════════════
-- TAAM — 토스페이먼츠 결제 주문 원장 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 실행해도 안전)
--
-- 왜 필요한가
--   토스 V2 결제는 2단계다.
--     ① 결제창 인증 (브라우저, 클라이언트 키)
--     ② 서버 승인 confirm (시크릿 키)
--   ②에서 "이 주문의 금액이 얼마여야 하는가"를 서버가 알고 있어야 한다.
--   브라우저가 보낸 금액을 그대로 믿으면, 회원이 ₩1,000 을 결제하고
--   ₩1,000,000 을 적립받는 위변조가 가능하다.
--
--   그래서 결제창을 열기 **전에** 여기 한 행을 박아두고,
--   confirm 할 때 이 행의 amount 와 대조한다. 적립도 이 행의 amount 로 한다.
--
-- 멱등성
--   결제창 복귀는 새로고침·뒤로가기로 여러 번 일어날 수 있다.
--   status='paid' 인 주문은 confirm 을 다시 호출해도 적립이 두 번 되지 않는다
--   (Edge Function 에서 status 로 판정 + payment_key 유니크 인덱스로 이중 방어).
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.payment_orders (
  order_id     text primary key,                    -- 토스 orderId (클라이언트가 생성)
  user_id      uuid not null references auth.users(id) on delete cascade,
  purpose      text not null default 'deposit_charge',  -- deposit_charge | ticket_topup | membership
  amount       bigint not null check (amount > 0),  -- 기대 금액 (원화 최소단위)
  currency     text not null default 'KRW',
  status       text not null default 'pending',     -- pending | paid | failed | canceled
  payment_key  text,                                -- 토스 paymentKey (승인 후 기록)
  method       text,                                -- 카드 / 계좌이체 …
  receipt_url  text,
  approved_at  timestamptz,
  fail_reason  text,
  metadata     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 상태 값 오타 방지
alter table public.payment_orders drop constraint if exists payment_orders_status_chk;
alter table public.payment_orders add constraint payment_orders_status_chk
  check (status in ('pending','paid','failed','canceled'));

-- 용도 값 오타 방지
alter table public.payment_orders drop constraint if exists payment_orders_purpose_chk;
alter table public.payment_orders add constraint payment_orders_purpose_chk
  check (purpose in ('deposit_charge','ticket_topup','membership'));

-- 같은 paymentKey 로 두 번 적립되는 것을 DB 차원에서 막는다
create unique index if not exists payment_orders_payment_key_uniq
  on public.payment_orders (payment_key)
  where payment_key is not null;

create index if not exists payment_orders_user_created_idx
  on public.payment_orders (user_id, created_at desc);

comment on table public.payment_orders is
  '토스 결제 주문 원장. 결제창 열기 전에 pending 으로 만들고, toss-confirm 이 승인 후 paid 로 바꾼다';
comment on column public.payment_orders.amount is
  '기대 금액. 승인 시 토스가 돌려준 금액과 반드시 일치해야 하며, 예치금 적립도 이 값으로 한다';

-- ── updated_at 자동 갱신 ──
create or replace function public.touch_payment_orders_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_touch_payment_orders on public.payment_orders;
create trigger trg_touch_payment_orders
before update on public.payment_orders
for each row execute function public.touch_payment_orders_updated_at();

-- ═══════════════════════════════════════════════════════════════
-- RLS — 회원은 "자기 주문을 pending 으로 만들고 조회"만 할 수 있다.
--   상태 변경(paid 로 바꾸기)과 예치금 적립은 service_role 을 쓰는
--   Edge Function 만 한다. service_role 은 RLS 를 우회하므로 별도 정책이 없다.
--   → 브라우저에서는 어떤 방법으로도 스스로 결제를 완료 처리할 수 없다.
-- ═══════════════════════════════════════════════════════════════
alter table public.payment_orders enable row level security;

drop policy if exists payment_orders_select_own on public.payment_orders;
create policy payment_orders_select_own on public.payment_orders
  for select using (auth.uid() = user_id);

drop policy if exists payment_orders_insert_own on public.payment_orders;
create policy payment_orders_insert_own on public.payment_orders
  for insert with check (
    auth.uid() = user_id
    and status = 'pending'
    and payment_key is null
    and approved_at is null
    -- 충전 금액 상·하한. 오타로 ₩1 이나 ₩10억이 들어가는 것을 막는다.
    and amount between 1000 and 10000000
  );

-- UPDATE / DELETE 정책은 일부러 만들지 않는다 (= 회원은 수정·삭제 불가)

-- ── 확인 ──
select
  (select count(*) from public.payment_orders)                          as "주문 수",
  (select count(*) from public.payment_orders where status = 'pending') as "미완료",
  (select count(*) from public.payment_orders where status = 'paid')    as "승인 완료";

select policyname as "정책", cmd as "동작"
from pg_policies
where schemaname = 'public' and tablename = 'payment_orders'
order by policyname;

do $$ begin raise notice '✅ payment_orders 준비 완료 — 다음: Edge Function toss-confirm 배포 + TOSS_SECRET_KEY 시크릿 등록'; end $$;
