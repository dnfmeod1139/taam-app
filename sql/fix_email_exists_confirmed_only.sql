-- ═══════════════════════════════════════════════════════════════
-- TAAM — "이미 가입된 메일" 오탐 종합 fix v2 (2026-07-17)
-- ═══════════════════════════════════════════════════════════════
-- 증상: 초대받은 신규 회원이 가입한 적 없는데 "이미 가입된 이메일" 로 반복 차단.
--
-- 원인 (3중):
--   1) signInWithOtp(shouldCreateUser:true) 가 OTP "발송 시점"에 auth.users 에
--      미인증(unconfirmed) 유령 계정을 즉시 생성 → 가입 미완 후 재시도하면
--      email_exists_in_auth() 가 유령을 보고 "이미 가입" 차단.
--   2) OTP 입력 직후 2단계 검증(verify-invite)이 같은 RPC 로 재검사 →
--      방금 본인이 인증 완료됐으므로 "자기 자신"에게 차단당함.
--   3) invite_codes_dedupe_constraint.sql 에 구버전 정의(미인증 포함 판정)가
--      남아 있어, 그 파일을 재실행하면 수정이 원복됨 (반복 재발의 원인).
--
-- 수정:
--   · email_exists_in_auth(): 인증 완료(email_confirmed_at IS NOT NULL) 계정만 true
--   · 🆕 email_exists_in_auth_other(): + 특정 user(본인) 제외 — 2단계 검증용
--   · verify-invite Edge Function 도 함께 수정됨 (재배포 필요)
--   · dedupe 파일의 구버전 정의도 저장소에서 동기화됨 (재발 차단)
--
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent).
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 인증 완료 계정만 "이미 가입" 판정 ──
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
      and email_confirmed_at is not null   -- 인증 완료된 사용자만 (OTP 발송만 된 유령 제외)
  );
$$;
comment on function public.email_exists_in_auth(text) is
  '인증 완료(email_confirmed_at IS NOT NULL) 계정만 "이미 가입"으로 판정. 미인증 유령 제외.';
revoke execute on function public.email_exists_in_auth(text) from public;
revoke execute on function public.email_exists_in_auth(text) from anon;
revoke execute on function public.email_exists_in_auth(text) from authenticated;
grant  execute on function public.email_exists_in_auth(text) to service_role;

-- ── 2) 🆕 본인 제외 버전 — OTP 인증 직후 2단계 검증용 (자기차단 방지) ──
create or replace function public.email_exists_in_auth_other(email_to_check text, exclude_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1 from auth.users
    where lower(email) = lower(email_to_check)
      and email_confirmed_at is not null
      and (exclude_id is null or id <> exclude_id)   -- 호출자 본인 제외
  );
$$;
comment on function public.email_exists_in_auth_other(text, uuid) is
  '해당 이메일을 쓰는 "다른" 인증완료 계정 존재 여부. exclude_id=검사에서 제외할 본인 user id. verify-invite 2단계용.';
revoke execute on function public.email_exists_in_auth_other(text, uuid) from public;
revoke execute on function public.email_exists_in_auth_other(text, uuid) from anon;
revoke execute on function public.email_exists_in_auth_other(text, uuid) from authenticated;
grant  execute on function public.email_exists_in_auth_other(text, uuid) to service_role;

do $$ begin raise notice '✅ 이메일 가입 판정 fix v2 — 인증완료만 판정 + 본인 제외 RPC 추가'; end $$;

-- ═══════════════════════════════════════════════════════════════
-- 진단 — OTP 발송만 되고 가입 미완으로 남은 유령 계정 (fix 후 자동 재가입 가능)
-- ═══════════════════════════════════════════════════════════════
select id, email, created_at,
       case when email_confirmed_at is null then '⚠ 미인증 유령 (재가입 가능)' else '✓ 인증완료' end as status
from auth.users
where email_confirmed_at is null
order by created_at desc
limit 50;

-- ═══════════════════════════════════════════════════════════════
-- (선택) 청소 — 24시간 이상 지난 미인증 유령 삭제. 필요 시 주석 해제 후 실행.
-- ═══════════════════════════════════════════════════════════════
-- delete from auth.users
-- where email_confirmed_at is null
--   and created_at < now() - interval '24 hours';
