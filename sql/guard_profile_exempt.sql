-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원이 single_device_exempt 를 스스로 켜지 못한다 (2026-09-13)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   profiles 의 「update own」 정책(notif_prefs_server.sql)은 컬럼을 가리지 않는다.
--   그래서 회원이
--     update profiles set single_device_exempt = true where id = auth.uid()
--   한 줄이면 ① 단일 기기 로그인 규칙에서 빠지고(계정 공유 가능)
--   ② repurchase_server_guard 가 같은 플래그를 면제 조건으로 읽어 **재구매
--   제한도 같이 풀린다.** 감사(2026-09-13)에서 렌즈 둘이 짚었다.
--
--   role · membership_tier · guest_expires_at · 잔액은 이미 트리거가 지키는데
--   이 플래그만 빠져 있었다. 같은 모양으로 막는다.
--
-- 규칙
--   플래그를 바꿀 수 있는 것은 슈퍼어드민(is_super_admin)과 서버(auth.uid() 가
--   null — service_role · SQL Editor · Edge Function)뿐이다.
--   파트너 계정 발급(partner-account Edge Function)이 이 플래그를 켜 주므로
--   서버는 막지 않는다.
--
--   ⚠ 예외를 던지지 않고 **값을 되돌린다.** 같은 UPDATE 에 다른 컬럼(알림
--     설정·이름)이 실려 있으면 예외는 그것까지 날린다 (CLAUDE.md 금전 규칙 5).
--     회원이 이 컬럼을 건드릴 정당한 이유가 없으니 조용히 무시하는 편이 맞다.
--
-- 실행: Supabase SQL Editor. 여러 번 돌려도 안전.
--       ⚠ is_super_admin(uuid) 가 먼저 있어야 한다.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_guard_profile_exempt()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.single_device_exempt is distinct from old.single_device_exempt then
    if auth.uid() is not null and not public.is_super_admin(auth.uid()) then
      new.single_device_exempt := old.single_device_exempt;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_taam_guard_profile_exempt on public.profiles;
create trigger trg_taam_guard_profile_exempt
  before update of single_device_exempt on public.profiles
  for each row execute function public.taam_guard_profile_exempt();

comment on function public.taam_guard_profile_exempt() is
  'single_device_exempt 는 슈퍼어드민·서버만 바꾼다. 회원이 바꾸면 조용히 원래 값으로 되돌린다.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 트리거가 있나 ⭐' as "구분",
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_profile_exempt' and not tgisinternal)
            then '✅' else '❌ 회원이 스스로 면제할 수 있다' end as "상태",
       'profiles.single_device_exempt' as "메모"
union all
select '② 지금 면제된 계정',
       (select count(*)::text from public.profiles where single_device_exempt = true) || '명',
       '심사·데모·파트너 계정만이어야 정상 — 모르는 이름이 있으면 그게 사고다'
 order by 1;
