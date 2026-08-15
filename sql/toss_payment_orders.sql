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
--   그래서 결제창을 열기 **전에** toss-order 가 티켓 가격과 예치금 잔액을 서버에서
--   다시 계산해 여기 한 행을 박아두고, confirm 할 때 이 행의 amount 와 대조한다.
--   적립도 이 행의 amount 로 한다. 브라우저는 orderId 만 받아 결제창을 연다.
--
-- 멱등성
--   결제창 복귀는 새로고침·뒤로가기로 여러 번 일어날 수 있다.
--   status='paid' 인 주문은 confirm 을 다시 호출해도 적립이 두 번 되지 않는다
--   (Edge Function 에서 status 로 판정 + payment_key 유니크 인덱스로 이중 방어).
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.payment_orders (
  order_id     text primary key,                    -- 토스 orderId (toss-order 가 생성)
  user_id      uuid not null references auth.users(id) on delete cascade,
  purpose      text not null default 'deposit_charge',  -- deposit_charge | ticket_topup | membership
  amount       bigint not null check (amount > 0),  -- 토스가 승인할 금액 (currency 기준)
  currency     text not null default 'KRW',
  -- 🆕 해외 결제 대비 (USD/JPY MID 승인 후 사용).
  --   원장은 원화 단일이므로 "승인 금액(amount·currency)" 과 "적립 금액(settle_krw)" 을
  --   한 주문 안에 각각 고정해 둔다. 주문 생성 시점의 적용환율을 fx_rate 에 얼려두면
  --   나중에 환율이 움직여도 이 주문의 두 숫자는 변하지 않아 정산·환불이 어긋나지 않는다.
  --   KRW 결제면 settle_krw = amount, fx_rate = null.
  settle_krw   bigint,                              -- 실제 예치금에 적립할 원화 금액
  fx_rate      numeric(12,4),                       -- 적용환율 = 매매기준율 × (1 - 마진%)
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
  '토스가 승인할 금액(currency 기준). 승인 시 토스가 돌려준 금액과 반드시 일치해야 한다';
comment on column public.payment_orders.settle_krw is
  '예치금에 적립할 원화 금액. KRW 결제면 amount 와 같고, 외화 결제면 주문 시점 적용환율로 환산한 값';
comment on column public.payment_orders.fx_rate is
  '주문 생성 시점의 적용환율(매매기준율 × (1 - 마진%)). 외화 결제만 채워진다';

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
-- RLS — 회원은 "자기 주문 조회"만 할 수 있다.
--   주문 생성(toss-order) · 상태 변경 · 예치금 적립은 전부 service_role 을 쓰는
--   Edge Function 이 한다. service_role 은 RLS 를 우회하므로 별도 정책이 없다.
--   → 브라우저는 결제 금액을 정할 수도, 스스로 결제를 완료 처리할 수도 없다.
-- ═══════════════════════════════════════════════════════════════
alter table public.payment_orders enable row level security;

drop policy if exists payment_orders_select_own on public.payment_orders;
create policy payment_orders_select_own on public.payment_orders
  for select using (auth.uid() = user_id);

-- ⚠ INSERT 정책은 일부러 만들지 않는다.
--   주문은 Edge Function toss-order 가 service_role 로만 만든다.
--   브라우저가 주문을 만들 수 있으면 금액을 스스로 정할 수 있게 되는데,
--   그건 결제 금액을 브라우저가 정하던 예전 구조와 똑같아진다.
--   (기존에 이 정책이 있었다면 아래에서 제거된다)
drop policy if exists payment_orders_insert_own on public.payment_orders;

-- UPDATE / DELETE 정책도 만들지 않는다 (= 회원은 수정·삭제 불가).
-- service_role 은 RLS 를 우회하므로 Edge Function 만 전 권한을 갖는다.

-- ⚠ settle_krw / fx_rate 도 마찬가지로 서버가 정한다.
--   외화 결제를 열 때 toss-confirm 이 app_config.fx_settings 를 읽어
--   settle_krw 를 서버에서 계산하고, 그 값으로만 적립한다.

-- ── 확인 ──
select
  (select count(*) from public.payment_orders)                          as "주문 수",
  (select count(*) from public.payment_orders where status = 'pending') as "미완료",
  (select count(*) from public.payment_orders where status = 'paid')    as "승인 완료";

select policyname as "정책", cmd as "동작"
from pg_policies
where schemaname = 'public' and tablename = 'payment_orders'
order by policyname;

do $$ begin raise notice '✅ payment_orders 준비 완료 — 다음: Edge Function toss-order · toss-confirm 배포 + TOSS_SECRET_KEY 시크릿 등록'; end $$;
