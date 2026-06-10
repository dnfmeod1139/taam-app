-- ═══════════════════════════════════════════════════════════════
-- TAAM — 사용자 결제 카드 메타데이터 (법인카드 지원)
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-20
-- 목적:
--   ① 카드 등록 정보 클라우드 저장 (기기 간 동기화)
--   ② 법인카드 별도 분류 (cardType + 법인명 + 사업자번호)
--   ③ RLS: 본인 카드만 조회/수정 가능, 슈퍼어드민은 전체 조회
-- 보안:
--   - 카드번호 전체 저장 금지 → PortOne 빌링키(billing_key)만 저장
--   - 마지막 4자리(last4) + 브랜드만 표시용으로 저장
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 테이블 생성 ──
create table if not exists public.user_cards (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,

  -- 표시용 메타데이터
  name        text not null,                  -- "김우종님 KB국민카드" / "[법인] 주식회사 쓰리피프틴 ..."
  brand       text,                            -- Visa / Mastercard / Amex / 국내사
  last4       text,                            -- 마지막 4자리 (•••• 표시용)
  expiry      text,                            -- MM/YY (표시용)
  holder      text,                            -- 카드 소유자 이름 (영문)

  -- 카드 종류 분기
  card_type   text not null default 'individual' check (card_type in ('individual', 'corporate')),

  -- 법인카드 정보 (card_type = 'corporate' 일 때만 채움)
  corp_name   text,                            -- 법인명
  corp_biz_no text,                            -- 사업자등록번호 (000-00-00000 포맷)
  corp_consent_at timestamptz,                 -- 법인카드 사용 권한 동의 시각

  -- PortOne 빌링키 (실제 결제용 — 카드번호 대신 사용)
  billing_key text,                            -- PortOne 빌링키

  -- 상태
  is_primary  boolean default false,
  is_active   boolean default true,

  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

comment on table public.user_cards is 'TAAM 회원 결제 카드 메타데이터 — 카드번호 전체는 절대 저장 안 함, 빌링키만 저장';

-- ── 2. 인덱스 ──
create index if not exists idx_user_cards_user_id on public.user_cards(user_id);
create index if not exists idx_user_cards_card_type on public.user_cards(card_type);
create index if not exists idx_user_cards_is_primary on public.user_cards(user_id, is_primary) where is_primary = true;

-- ── 3. updated_at 자동 갱신 트리거 ──
create or replace function public.touch_user_cards_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_user_cards_updated_at on public.user_cards;
create trigger trg_user_cards_updated_at
before update on public.user_cards
for each row execute function public.touch_user_cards_updated_at();

-- ── 4. 사용자당 주카드는 1개만 — 트리거 ──
create or replace function public.enforce_single_primary_card()
returns trigger language plpgsql as $$
begin
  if new.is_primary = true then
    -- 같은 사용자의 다른 카드를 모두 is_primary = false 로 변경
    update public.user_cards
    set is_primary = false
    where user_id = new.user_id and id <> new.id and is_primary = true;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_single_primary on public.user_cards;
create trigger trg_enforce_single_primary
after insert or update of is_primary on public.user_cards
for each row when (new.is_primary = true)
execute function public.enforce_single_primary_card();

-- ── 5. RLS 활성화 ──
alter table public.user_cards enable row level security;

-- ── 6. 정책: 본인 카드만 조회/수정 ──
drop policy if exists "users can view own cards" on public.user_cards;
create policy "users can view own cards"
on public.user_cards for select
to authenticated
using (user_id = auth.uid() or public.is_super_admin(auth.uid()));

drop policy if exists "users can insert own cards" on public.user_cards;
create policy "users can insert own cards"
on public.user_cards for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "users can update own cards" on public.user_cards;
create policy "users can update own cards"
on public.user_cards for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "users can delete own cards" on public.user_cards;
create policy "users can delete own cards"
on public.user_cards for delete
to authenticated
using (user_id = auth.uid());

-- ── 7. 법인카드 동의 체크 — corp 카드는 corp_consent_at 필수 ──
alter table public.user_cards
  drop constraint if exists chk_corporate_consent;

alter table public.user_cards
  add constraint chk_corporate_consent
  check (
    card_type = 'individual'
    or (card_type = 'corporate' and corp_name is not null and corp_biz_no is not null and corp_consent_at is not null)
  );

-- ── 8. (옵션) 사용자 프로필에 영문 이름 컬럼 추가 ──
-- 카드 소유자 이름(영문)과 매칭 검증용
alter table public.profiles
  add column if not exists display_name_en text;

comment on column public.profiles.display_name_en is
  '영문 이름 (예: KIM WOOJONG) — 카드 소유자 이름과 매칭 검증에 사용. 한글 이름과는 별도.';

-- ── 완료 ──
do $$ begin raise notice '✅ user_cards 테이블 + RLS + 트리거 + display_name_en 컬럼 설치 완료'; end $$;
