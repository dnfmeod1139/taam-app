-- ═══════════════════════════════════════════════════════════════
-- TAAM — 새로 들어온 게스트에게도 기한을 세운다 (2026-09-03)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 비어 있었나
--   membership_settings.sql 의 기한 채우기는 **설치할 때 한 번 도는
--   백필**이었다 (update ... where guest_expires_at is null).
--   그 뒤로 가입하는 게스트에게는 기한을 세워 주는 곳이 없다.
--
--   guest_expires_at 이 null 이면 taam_guest_state 는 expired=false 를
--   돌려준다. 즉 **영영 만료되지 않는다.**
--   90일 규칙도, 구매 리셋도, [+90일] 도 전부 아무에게도 적용되지 않는다.
--   조용히 아무 일도 안 일어나는 종류의 고장이라 늦게 발견된다.
--
-- 어떻게
--   게스트(A)가 되는 순간 「오늘 + guest_days」로 세운다.
--   ⚠ 가입일 기준으로 계산하지 않는다. 옛 회원을 A 로 바꾸는 순간
--     이미 만료된 사람이 되어 버린다.
--   등급이 A 를 벗어나면 기한을 지운다 — M·T 에게는 없는 값이다.
--
-- 실행: Supabase SQL Editor. ⚠ membership_settings.sql 다음.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_guest_expiry_init()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_days int;
begin
  if upper(coalesce(new.membership_tier, '')) = 'A' then
    -- 이미 있으면 손대지 않는다. 어드민이 [+90일] 로 늘려 둔 값을
    -- 덮으면 안 된다 — 프로필을 저장할 때마다 연장이 취소된다.
    if new.guest_expires_at is null then
      select coalesce((v#>>'{}')::int, 90) into v_days
        from public.membership_settings where k = 'guest_days';
      new.guest_expires_at := now() + (coalesce(v_days, 90) || ' day')::interval;
      new.guest_status := coalesce(new.guest_status, 'active');
    end if;
  else
    -- A 를 벗어나면(M·T 로 승급) 게스트 기한은 의미가 없다.
    new.guest_expires_at := null;
  end if;
  return new;
end;
$$;

comment on function public.taam_guest_expiry_init() is
  '게스트(A)가 되는 순간 만료일을 세운다. 없으면 영영 만료되지 않아 90일 규칙이 아무에게도 적용되지 않는다.';

-- ⚠ 이름을 guard 뒤로 둔다. 같은 타이밍의 트리거는 이름순으로 도는데,
--   trg_taam_guard_membership_tier 가 등급을 확정한 **뒤에** 봐야 한다.
--   ('guard' < 'guest' 이므로 이 이름이면 뒤에 돈다)
drop trigger if exists trg_taam_guest_expiry_init on public.profiles;
create trigger trg_taam_guest_expiry_init
  before insert or update of membership_tier, guest_expires_at on public.profiles
  for each row execute function public.taam_guest_expiry_init();

-- 지금 비어 있는 게스트를 채운다 (백필 이후에 들어온 사람들)
update public.profiles
   set guest_expires_at = now() + (
         (select coalesce((v#>>'{}')::int, 90)
            from public.membership_settings where k = 'guest_days') || ' day')::interval,
       guest_status = coalesce(guest_status, 'active')
 where upper(coalesce(membership_tier,'')) = 'A'
   and guest_expires_at is null;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 트리거가 붙었나 ⭐' as "구분",
       case when count(*) = 1 then '✅' else '❌ 없음' end as "상태",
       '게스트가 되는 순간 기한이 선다' as "메모"
  from pg_trigger
 where tgname = 'trg_taam_guest_expiry_init' and not tgisinternal
union all
select '② 기한 없는 게스트 ⭐',
       (select count(*)::text from public.profiles
         where upper(coalesce(membership_tier,'')) = 'A'
           and guest_expires_at is null) || '명',
       '0명이어야 정상 — 있으면 그 사람은 영영 안 만료된다'
union all
select '③ 기한이 선 게스트',
       (select count(*)::text from public.profiles
         where upper(coalesce(membership_tier,'')) = 'A'
           and guest_expires_at is not null) || '명',
       '그중 만료됨: ' ||
       (select count(*)::text from public.profiles
         where upper(coalesce(membership_tier,'')) = 'A'
           and guest_expires_at is not null and guest_expires_at <= now()) || '명'
union all
select '④ 회원에게 잘못 남은 기한',
       (select count(*)::text from public.profiles
         where upper(coalesce(membership_tier,'')) in ('M','T')
           and guest_expires_at is not null) || '명',
       '0명이어야 정상'
 order by 1;
