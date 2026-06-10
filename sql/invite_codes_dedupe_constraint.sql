-- ═══════════════════════════════════════════════════════════════
-- TAAM — invite_codes 중복 발급 방지 인덱스
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-20
-- 목적:
--   ① 동일 이메일에 활성(used=false) 초대코드 2개 이상 생성 차단 (부분 UNIQUE 인덱스)
--   ② 동일 휴대폰에 활성 초대코드 2개 이상 생성 차단
--   ③ 사용된 코드(used=true)는 히스토리 보존 — UNIQUE 제외
-- 클라이언트 측 검증 + Edge Function 검증과 함께 3중 안전망 구성
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 활성(미사용) 코드의 이메일 UNIQUE ──
-- 비어있지 않은 이메일 + used=false 인 경우만 적용
create unique index if not exists uniq_invite_active_email
  on public.invite_codes (lower(trim(invitee_email)))
  where used = false
    and invitee_email is not null
    and length(trim(invitee_email)) > 0;

comment on index uniq_invite_active_email is
  '동일 이메일로 활성(미사용) 초대코드 중복 발급 차단. 사용된 코드는 히스토리로 보존.';

-- ── 2) 활성(미사용) 코드의 휴대폰 UNIQUE ──
-- 숫자만 추출한 값으로 정규화 (010-1234-5678 vs 01012345678 동일 처리)
create unique index if not exists uniq_invite_active_phone
  on public.invite_codes (regexp_replace(coalesce(invitee_phone, ''), '[^0-9]', '', 'g'))
  where used = false
    and invitee_phone is not null
    and length(regexp_replace(invitee_phone, '[^0-9]', '', 'g')) > 0;

comment on index uniq_invite_active_phone is
  '동일 휴대폰 번호로 활성 초대코드 중복 발급 차단. 자릿수 다른 표기(010-vs01x) 도 동일 처리.';

-- ── 3) 검증 쿼리 ──
-- 현재 활성 코드 중에 동일 이메일이 여러 개 있는지 확인 (있으면 정리 필요)
select 'duplicate_active_email' as kind, lower(trim(invitee_email)) as key, count(*) as cnt
from public.invite_codes
where used = false and invitee_email is not null and length(trim(invitee_email)) > 0
group by lower(trim(invitee_email))
having count(*) > 1

union all

select 'duplicate_active_phone' as kind, regexp_replace(invitee_phone, '[^0-9]', '', 'g') as key, count(*) as cnt
from public.invite_codes
where used = false and invitee_phone is not null
  and length(regexp_replace(invitee_phone, '[^0-9]', '', 'g')) > 0
group by regexp_replace(invitee_phone, '[^0-9]', '', 'g')
having count(*) > 1;

-- 위 쿼리 결과가 0 row 면 인덱스 생성 즉시 성공.
-- 1 row 이상이면 중복 발급된 코드가 이미 있다는 뜻 → 인덱스 생성 실패.
--   대응: 중복된 코드 중 하나를 used=true 로 막아두거나 삭제 후 다시 인덱스 생성.

-- ═══════════════════════════════════════════════════════════════
-- 4) 🆕 verify-invite Edge Function 용 RPC — auth.users 이메일 존재 검사
-- ═══════════════════════════════════════════════════════════════
-- security definer 로 auth 스키마 접근 (Service Role Key 없이도 호출 가능)
-- Edge Function 에서 supabase.rpc('email_exists_in_auth', {...}) 호출
create or replace function public.email_exists_in_auth(email_to_check text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1 from auth.users
    where lower(email) = lower(email_to_check)
  );
$$;

comment on function public.email_exists_in_auth(text) is
  'auth.users 에 해당 이메일이 이미 등록되어 있는지 검사. verify-invite Edge Function 에서 사용.';

-- 익명/일반 사용자는 호출 불가 — Service Role 만 허용
revoke execute on function public.email_exists_in_auth(text) from public;
revoke execute on function public.email_exists_in_auth(text) from anon;
revoke execute on function public.email_exists_in_auth(text) from authenticated;
grant execute on function public.email_exists_in_auth(text) to service_role;

-- ── 완료 ──
do $$ begin raise notice '✅ invite_codes 활성 코드 중복 방지 인덱스 + email_exists_in_auth() RPC 설치 완료'; end $$;
