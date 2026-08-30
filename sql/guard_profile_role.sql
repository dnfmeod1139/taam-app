-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원이 스스로 슈퍼어드민이 되는 길을 막는다 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 열려 있었나
--   profiles 의 UPDATE 정책이 이렇다.
--       profiles_update_own : (auth.uid() = id) OR is_superadmin()
--   자기 행은 고칠 수 있다는 뜻인데, role 컬럼도 자기 행에 있다.
--   그리고 role 변경을 막는 트리거가 없었다(2026-08-30 확인).
--
--   그래서 로그인한 회원이 앱을 거치지 않고 이 한 줄을 보내면 끝이었다.
--       update profiles set role = 'super_admin' where id = <내 id>
--   그 뒤로는 is_superadmin() 이 참이 되어 전 회원 명부·예치금·티켓이
--   전부 열린다. RLS 를 잘 짜 뒀는데 그 판정의 근거를 본인이 쓸 수 있었다.
--
-- 무엇을 막나
--   회원이 자기 role 을 바꾸는 것 하나만 막는다. 나머지는 손대지 않는다.
--
--   ⚠ 예치금(membership_deposit_balance 등)은 여기서 막지 않는다.
--     지금 앱은 구매·취소 때 회원 세션이 직접 자기 잔액을 고친다.
--     여기서 막으면 구매와 취소가 그 자리에서 멈춘다. 그건 서버로 옮기는
--     별도 작업이고, 오늘 급히 할 일이 아니다. 아래 「남은 것」 참고.
--
-- 어떻게
--   BEFORE UPDATE 트리거로 role 이 바뀌려 하면 옛 값으로 되돌린다.
--   · 예외를 던지지 않는다 — 다른 필드를 같이 고치는 정상 요청까지 죽으면
--     회원이 이름도 못 바꾼다. role 만 조용히 되돌리고 경고를 남긴다.
--   · 슈퍼어드민은 그대로 통과 (다른 회원 등급 관리는 계속 돼야 한다)
--   · 앱에서 온 요청(current_user 가 authenticated · anon)일 때만 본다.
--     service_role, 그리고 SECURITY DEFINER RPC(소유자 권한으로 도는 것)는
--     서버가 스스로 하는 일이라 막을 대상이 아니다.
--
--   ⚠ 트리거 함수는 일부러 SECURITY DEFINER 가 아니다.
--     DEFINER 로 만들면 함수 안에서 current_user 가 소유자(postgres)로 바뀌어
--     「앱에서 온 요청인가」를 영영 판별할 수 없다. 실제로 그렇게 짰다가
--     로컬 재현에서 회원 승격이 그대로 통과하는 것을 확인했다 — 트리거는
--     붙어 있는데 아무것도 막지 못하는, 제일 나쁜 모양이었다.
--     대신 슈퍼어드민 판정만 별도 DEFINER 함수(_taam_uid_is_super)로 뺐다.
--
-- ⚠ UPDATE 만 막는다. INSERT(가입) 는 auto_promote_super_admin 트리거가
--   이메일로 판정하므로 건드리지 않았다 — 아래 ③ 으로 확인할 것.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 막는 트리거
-- ═══════════════════════════════════════════════════════════════
-- 지금 요청자가 슈퍼어드민인가.
--   이것만 SECURITY DEFINER 다 — RLS·권한과 무관하게 profiles 를 읽어야 하므로.
create or replace function public._taam_uid_is_super()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.role in ('super_admin','superadmin')
  )
$$;

-- 트리거 본체는 SECURITY INVOKER (기본) — current_user 가 실제 요청자여야 한다.
create or replace function public.taam_guard_profile_role()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.role is not distinct from old.role then
    return new;                      -- 안 바뀌면 볼 것 없다
  end if;

  -- 서버가 하는 일은 막지 않는다.
  --   PostgREST 로 들어온 앱 요청은 current_user 가 authenticated(로그인) ·
  --   anon(비로그인) 이다. service_role · postgres · SECURITY DEFINER RPC ·
  --   마이그레이션은 다른 롤로 돌기 때문에 여기서 걸러진다.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- 슈퍼어드민은 통과 (다른 회원 등급을 관리해야 한다)
  if public._taam_uid_is_super() then
    return new;
  end if;

  -- 여기까지 왔으면 회원이 자기 role 을 바꾸려 한 것이다. 되돌린다.
  raise warning '[guard] role 변경 차단: % → % (uid=%)', old.role, new.role, auth.uid();
  new.role := old.role;
  return new;
end;
$$;

drop trigger if exists trg_taam_guard_profile_role on public.profiles;
create trigger trg_taam_guard_profile_role
  before update on public.profiles
  for each row execute function public.taam_guard_profile_role();

comment on function public.taam_guard_profile_role() is
  '회원이 자기 profiles.role 을 바꾸지 못하게 막는다. 슈퍼어드민·서버는 통과. SECURITY DEFINER 로 바꾸지 말 것 — current_user 판정이 무너진다.';
comment on function public._taam_uid_is_super() is
  '요청자가 슈퍼어드민인지 (RLS 우회). taam_guard_profile_role 전용.';


-- ═══════════════════════════════════════════════════════════════
-- ② 확인 — 네 가지를 한 표로 본다
-- ═══════════════════════════════════════════════════════════════
--   ⚠ Supabase SQL Editor 는 여러 SELECT 를 돌려도 「마지막 결과 하나」만
--     보여준다. 그래서 확인 쿼리를 나눠 쓰면 앞엣것이 화면에서 사라진다.
--     실제로 그렇게 만들었다가 트리거 결과만 보였다. 그래서 합쳐 둔다.
--
--   무엇을 보나
--     ⓐ 트리거    — 붙었는지
--     ⓑ 슈퍼어드민 — 이미 올라간 사람이 있는지. 아는 계정만 있어야 한다
--     ⓒ INSERT 정책 — WITH CHECK 가 가입 때 role 을 막는지
--     ⓓ auto_promote — 가입 때 role 을 무엇으로 덮어쓰는지
--
--   ⚠ ⓒ 의 WITH CHECK 가 그냥 true 인데 ⓓ 가 role 을 덮어쓰지 않으면,
--     가입할 때 role='super_admin' 으로 넣어 만들 수 있다는 뜻이다.
--     그러면 INSERT 도 같이 막아야 한다 — 결과를 보고 판단한다.
select 'ⓐ 트리거'                    as "구분",
       tgname                        as "이름",
       '설치됨'                      as "내용"
from pg_trigger
where tgrelid = 'public.profiles'::regclass
  and tgname = 'trg_taam_guard_profile_role'

union all
select 'ⓑ 슈퍼어드민',
       coalesce(display_name, '(이름 없음)'),
       coalesce(email, phone, '(연락처 없음)') || '  ·  ' || role
         || '  ·  가입 ' || (created_at at time zone 'UTC')::date::text
from public.profiles
where role in ('super_admin','superadmin')

union all
select 'ⓒ INSERT 정책',
       policyname,
       'WITH CHECK: ' || coalesce(with_check, '(없음)')
from pg_policies
where schemaname = 'public' and tablename = 'profiles' and cmd = 'INSERT'

union all
select 'ⓓ auto_promote',
       proname,
       pg_get_functiondef(oid)
from pg_proc
where proname = 'auto_promote_super_admin'

order by 1, 2;

-- 모르는 슈퍼어드민이 있으면 그 자리에서 내린다 (id 를 넣어 실행):
--   update public.profiles set role = 'member' where id = '<그 id>';
--
-- ⚠ ⓐ 줄이 아예 안 나오면 트리거가 안 붙은 것이다. 위 ① 을 다시 돌린다.


-- ═══════════════════════════════════════════════════════════════
-- 남은 것 — 오늘 하지 않는다, 다만 잊지 않는다
-- ═══════════════════════════════════════════════════════════════
--   ⓐ 예치금 잔액을 회원 세션이 직접 고치고 있다.
--      profiles_update_own 이 자기 행 UPDATE 를 허용하므로, 앱을 거치지
--      않고 자기 잔액을 올릴 수 있다. 지금 구매·취소가 그 경로에 기대고
--      있어서 막으면 즉시 멈춘다. 결제·환불을 SECURITY DEFINER RPC 로
--      옮긴 뒤에 막아야 한다 (taam_change_party_size 가 그 본보기다).
--   ⓑ tickets_update_own 도 같은 모양이라 자기 구매의 price·party_size·
--      status 를 직접 고칠 수 있다. 돈이 바로 움직이진 않지만 기록이 어긋난다.
--   ⓒ membership_tier · membership_expires_at 도 자기 행이라 바꿀 수 있다.
--      가입 흐름이 초대코드 등급을 여기에 쓰고 있어 같이 막으면 가입이 깨진다.
--      이것도 서버로 옮긴 뒤 막는다.
