-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원 결제·표시 통화 지정 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   회원마다 화면 표시·카드 결제 통화(₩/$/¥)를 슈퍼어드민이 지정한다.
--   회원이 스스로 고르게 하지 않는 이유: 해외 요율(대행비 $정액)이 통화에
--   붙어 있어서, 선택권을 주면 모두가 싼 쪽을 골라 마진이 한쪽으로 샌다.
--   NULL(미지정)이면 앱이 종전 규칙(화면 언어: ko→KRW, ja→JPY, 그 외→USD)
--   으로 폴백한다 — 기존 회원은 이 SQL 만으로는 아무것도 바뀌지 않는다.
--
-- 지정하는 곳: 슈퍼어드민 → 회원 원장 → 회원 상세의 통화 버튼
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists currency text;

-- 허용값 제한 (NULL = 미지정 → 언어 폴백)
do $$ begin
  alter table public.profiles
    add constraint profiles_currency_chk check (currency in ('KRW','USD','JPY'));
exception when duplicate_object then null; end $$;

comment on column public.profiles.currency is
  '회원 결제·표시 통화. 슈퍼어드민만 지정(KRW/USD/JPY). NULL 이면 앱이 화면 언어로 폴백(ko→KRW, ja→JPY, 그 외→USD).';

-- ── 본인 변경 차단 ──
--   profiles 는 회원 본인이 UPDATE 할 수 있는 테이블이라(이름 등),
--   RLS 만으로는 currency 컬럼만 막을 수 없다. 트리거로 컬럼 단위로 막는다:
--   슈퍼어드민이 아닌 요청이 currency 를 바꾸면 조용히 원래 값으로 되돌린다.
--   (에러를 던지면 이름 수정 같은 정상 저장까지 통째로 실패하므로 되돌리기만 한다)
create or replace function public.taam_guard_profile_currency()
returns trigger language plpgsql security definer as $$
begin
  if new.currency is distinct from old.currency then
    if not exists (
      select 1 from public.profiles p
       where p.id = auth.uid()
         and p.role in ('superadmin','super_admin')
    ) then
      new.currency := old.currency;   -- 몰래 바꾼 값은 무시
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_taam_guard_profile_currency on public.profiles;
create trigger trg_taam_guard_profile_currency
  before update on public.profiles
  for each row execute function public.taam_guard_profile_currency();

-- ── 확인 ──────────────────────────────────────────────────────
select column_name, data_type from information_schema.columns
 where table_schema='public' and table_name='profiles' and column_name='currency';

do $$ begin raise notice '✅ 회원 통화 지정 준비 완료 — profiles.currency + 본인 변경 차단 트리거'; end $$;
