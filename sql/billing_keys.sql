-- ═══════════════════════════════════════════════════════════════
-- TAAM — 결제수단(빌링키) 저장 테이블 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 왜 필요한가
--   결제수단 관리 화면(loadMyCards/deleteCard/setDefaultCard)과
--   account_delete.sql 이 이미 public.billing_keys 를 참조하고 있는데,
--   정작 테이블을 만드는 스크립트가 없었다. 그래서 카드 등록창은 열려도
--   저장할 곳이 없었고, 화면은 "카드 목록을 불러올 수 없습니다"로 끝났다.
--
-- 무엇을 저장하는가
--   토스 빌링키 = "이 회원의 이 카드로 승인해도 된다"는 자격증명이다.
--   카드번호 전체·CVC·유효기간은 토스가 보관하고 우리는 받지도 않는다.
--   여기 남기는 건 마스킹 번호와 카드사명뿐이다 (화면 표시용).
--
-- ⚠ INSERT 는 Edge Function(service_role)만 한다.
--   빌링키는 결제 자격증명이라 브라우저가 직접 넣게 두면
--   임의의 키를 남의 계정에 심을 수 있다.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.billing_keys (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  customer_key  text not null,             -- 토스 customerKey (= auth.users.id)
  billing_key   text not null,             -- 토스 빌링키 (승인 자격증명)
  card_company  text,                      -- 카드사명 (표시용)
  card_number   text,                      -- 마스킹 번호만 (예: 1234-****-****-5678)
  card_type     text,                      -- 신용/체크
  is_default    boolean not null default false,
  created_at    timestamptz not null default now(),
  deleted_at    timestamptz
);

-- 같은 빌링키가 두 번 저장되지 않게 (재등록 시 upsert 기준)
create unique index if not exists uq_billing_keys_key
  on public.billing_keys(billing_key);

create index if not exists idx_billing_keys_user
  on public.billing_keys(user_id) where deleted_at is null;

-- 회원당 기본 카드는 1장만
create unique index if not exists uq_billing_keys_default
  on public.billing_keys(user_id) where is_default and deleted_at is null;

alter table public.billing_keys enable row level security;

-- 본인 카드만 조회 (billing_key 컬럼까지 보이지만, 결제는 서버만 할 수 있으므로
--  이 값 자체로 브라우저에서 승인을 일으킬 수는 없다 — 승인은 시크릿 키가 필요하다)
drop policy if exists billing_keys_select_own on public.billing_keys;
create policy billing_keys_select_own on public.billing_keys
  for select to authenticated
  using (user_id = auth.uid());

-- 기본카드 지정 / 소프트 삭제 — 본인 것만
drop policy if exists billing_keys_update_own on public.billing_keys;
create policy billing_keys_update_own on public.billing_keys
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- INSERT 정책은 두지 않는다 → service_role(Edge Function) 만 삽입 가능

-- 확인
select count(*) as 등록된_카드수 from public.billing_keys where deleted_at is null;

do $$ begin raise notice '✅ billing_keys 테이블 준비 완료'; end $$;
