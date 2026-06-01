-- ═══════════════════════════════════════════════════════════════
-- TAAM — 로그인 보안 검증용 RPC (2026-06-01)
-- ═══════════════════════════════════════════════════════════════
-- 클라이언트는 invite_codes 의 RLS 정책에 막혀 빈 결과를 받을 수 있음.
-- 이 RPC 는 service_role 권한으로 실제 매칭 여부를 boolean 으로 반환.
-- false 면 클라이언트가 signOut() 강제.
--
-- 보안: 호출자 본인의 인증된 이메일/전화에 매칭되는 invite_codes 만 카운트.
--      auth.uid() 기반 — 임의 이메일 조회 차단.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.user_has_invite_match()
returns boolean
language plpgsql
stable security definer
set search_path to 'public', 'auth'
as $$
declare
  my_email text;
  my_phone text;
  my_phone_digits text;
  my_id uuid;
  cnt integer;
begin
  my_id := auth.uid();
  if my_id is null then
    return false;
  end if;

  -- auth.users 의 이메일/전화 (가장 정확)
  select lower(coalesce(email, '')), coalesce(phone, '')
    into my_email, my_phone
  from auth.users where id = my_id;

  -- profiles 의 phone 도 폴백
  if my_phone is null or my_phone = '' then
    select coalesce(phone, '') into my_phone from public.profiles where id = my_id;
  end if;

  my_phone_digits := regexp_replace(coalesce(my_phone, ''), '[^0-9]', '', 'g');
  -- 한국번호 정규화: 선행 82 제거, 선행 0 제거
  my_phone_digits := regexp_replace(my_phone_digits, '^82', '');
  my_phone_digits := regexp_replace(my_phone_digits, '^0+', '');

  select count(*) into cnt
  from public.invite_codes ic
  where
    (my_email <> '' and (
      lower(coalesce(ic.invitee_email,'')) = my_email
      or lower(coalesce(ic.used_by_email,'')) = my_email))
    or (length(my_phone_digits) >= 4 and (
      regexp_replace(coalesce(ic.invitee_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%'
      or regexp_replace(coalesce(ic.used_by_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%'));

  return cnt > 0;
end;
$$;

-- 사용 예: select public.user_has_invite_match();
-- 본인 세션 컨텍스트에서 호출 → 자기 invite_codes 매칭 여부 반환
-- (SQL Editor 는 service_role 이라 auth.uid() = NULL → 항상 false. 정상)

do $$ begin raise notice '✅ user_has_invite_match RPC 생성 완료'; end $$;
