-- ═══════════════════════════════════════════════════════════════
-- TAAM — 이메일 초대 인증 버그 fix (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 증상:
--   처음 가입하는 이메일인데 "이미 가입된 이메일입니다" 로 차단됨.
--
-- 원인:
--   email_exists_in_auth() RPC 가 auth.users 에 row 만 있으면 true 반환.
--   그런데 signInWithOtp({ shouldCreateUser:true }) 는 OTP 발송 시점에
--   auth.users 에 "미인증(unconfirmed)" user 를 즉시 생성한다.
--   → OTP 한 번 발송하면 그때부터 email_exists_in_auth = true
--   → verify-invite 가 재호출되면 "이미 가입" 으로 자기 자신을 차단.
--
-- 수정:
--   email_confirmed_at IS NOT NULL 조건 추가.
--   = 실제로 이메일 인증을 완료한 user 만 "이미 가입" 으로 판단.
--   = OTP 발송만 하고 미완료한 unconfirmed user 는 "미가입" 으로 처리 → 통과.
--
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (1회). 앱/Edge Function 재배포 불필요.
-- ═══════════════════════════════════════════════════════════════

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
      and email_confirmed_at is not null   -- 🆕 인증 완료된 사용자만 "이미 가입" 으로 간주
  );
$$;

comment on function public.email_exists_in_auth(text) is
  'auth.users 에 해당 이메일이 인증 완료(email_confirmed_at IS NOT NULL) 상태로 등록되어 있는지 검사. OTP 발송만 한 미인증 user 는 false (미가입) 처리. verify-invite Edge Function 용.';

-- 권한 재확인 (재정의 후에도 유지되지만 명시)
revoke execute on function public.email_exists_in_auth(text) from public;
revoke execute on function public.email_exists_in_auth(text) from anon;
revoke execute on function public.email_exists_in_auth(text) from authenticated;
grant  execute on function public.email_exists_in_auth(text) to service_role;

do $$ begin raise notice '✅ email_exists_in_auth() 수정 완료 — 인증 완료 user 만 "이미 가입" 판단'; end $$;

-- ═══════════════════════════════════════════════════════════════
-- (선택) 진단 — 현재 막혀있는 unconfirmed user 확인
-- ═══════════════════════════════════════════════════════════════
-- 아래 쿼리로 "OTP 발송만 하고 미완료" 상태로 남은 이메일 확인 가능.
-- 이 user 들은 위 수정 후 "미가입" 으로 처리되어 정상적으로 재가입 가능.

select
  id,
  email,
  email_confirmed_at,
  created_at,
  case when email_confirmed_at is null then '⚠ 미인증 (재가입 가능)' else '✓ 인증완료' end as status
from auth.users
where email_confirmed_at is null
order by created_at desc
limit 50;

-- ═══════════════════════════════════════════════════════════════
-- (선택) 고아 unconfirmed user 정리 — 필요 시에만 실행
-- ═══════════════════════════════════════════════════════════════
-- 위 수정만으로 버그는 해결되지만, 오래된 미인증 user 를 청소하고 싶으면
-- 아래 주석을 풀어 24시간 이상 지난 미인증 user 삭제 (profiles 트리거 cascade 주의).
--
-- delete from auth.users
-- where email_confirmed_at is null
--   and created_at < now() - interval '24 hours';
