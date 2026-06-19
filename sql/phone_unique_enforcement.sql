-- ═══════════════════════════════════════════════════════════════
-- TAAM — 휴대폰 번호 유니크 강제 (중복 가입 방지) (2026-06-19)
-- ═══════════════════════════════════════════════════════════════
-- 배경:
--   현재는 이메일 기반 가입(폰 인증 미구현). 한 사람이 다른 이메일로 2번
--   가입하면 별도 계정이 생김. 폰 인증 + 결제(토스페이먼츠)는 1~2개월 내 도입 예정.
-- 설계:
--   · 지금은 profiles.phone 이 비어 있어 RPC 가 false → "무영향(잠복)".
--   · 폰 인증 도입으로 profiles.phone 이 채워지면 → 같은 번호의 다른 활성
--     계정 존재 시 로그인 보안검증에서 자동 차단(앱 코드 이미 연결).
--   · 번호 정규화는 앱과 동일: 숫자만 → 선행 '82' 제거 → 선행 '0' 제거.
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (멱등). 폰 인증 전 미리 깔아둬도 안전.
-- ═══════════════════════════════════════════════════════════════

-- 1) 번호 정규화 헬퍼 (앱 클라이언트와 동일 규칙)
create or replace function public._norm_phone(p text)
returns text
language sql immutable
as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'),  -- 숫자만
             '^82', ''),                                          -- 국가코드 82 제거
           '^0+', '')                                             -- 선행 0 제거
$$;

-- 2) 내 휴대폰이 "다른 활성 계정"과 겹치는가 (RLS 우회 — 본인 외 profiles 조회 필요)
--    · 본인 번호가 비었거나 너무 짧으면(< 9자리) 판단 불가 → false (현재 이메일 가입 = 항상 false)
create or replace function public.phone_dup_other_account()
returns boolean
language sql stable security definer set search_path = public
as $$
  with me as (
    select id, public._norm_phone(phone) as ph
    from public.profiles
    where id = auth.uid()
  )
  select exists (
    select 1
    from public.profiles p, me
    where p.id <> me.id
      and me.ph <> ''
      and length(me.ph) >= 9
      and public._norm_phone(p.phone) = me.ph
      and p.deleted_at is null
  );
$$;

revoke all on function public.phone_dup_other_account() from public;
grant execute on function public.phone_dup_other_account() to authenticated;

-- 3) (폰 인증 도입 시 권장) 특정 번호가 이미 사용 중인지 — 가입/인증 단계 사전 체크용.
--    반환: 같은 번호의 다른 활성 계정 존재 여부.
create or replace function public.phone_in_use(p_phone text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where public._norm_phone(p.phone) = public._norm_phone(p_phone)
      and public._norm_phone(p_phone) <> ''
      and length(public._norm_phone(p_phone)) >= 9
      and (auth.uid() is null or p.id <> auth.uid())
      and p.deleted_at is null
  );
$$;
revoke all on function public.phone_in_use(text) from public;
grant execute on function public.phone_in_use(text) to authenticated;

do $$ begin
  raise notice '✅ 폰 유니크 RPC 생성 — 현재 무영향(폰 미수집), 폰 인증 도입 후 자동 활성';
end $$;
