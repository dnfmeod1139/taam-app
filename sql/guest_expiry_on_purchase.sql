-- ═══════════════════════════════════════════════════════════════
-- TAAM — 게스트는 「3개월 구매 없으면」 만료 (2026-09-03)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 달랐나
--   지금까지 게스트 기한은 **구매와 무관한 고정 90일**이었다.
--   가입하고 90일이 지나면 티켓을 몇 번을 샀든 만료됐다.
--
--   정한 규칙은 그게 아니다 — **3개월 동안 구매가 없으면** 만료다.
--   사면 시계가 다시 0부터 간다.
--
-- 어떻게
--   게스트가 티켓을 사면 guest_expires_at 을 「지금 + guest_days」로 민다.
--   ⚠ 날짜를 앱이 넘기게 하지 않는다. 앱이 보낸 값을 믿으면 기한을
--     원하는 만큼 미룰 수 있다. 서버가 now() 로 직접 정한다.
--
-- ⚠ 만료된 게스트는 스스로 못 돌아온다.
--   만료되면 로그인이 막히므로 구매를 할 수가 없다. 이건 의도한 것이다 —
--   되살리는 길은 슈퍼어드민의 [+90일](taam_guest_extend) 하나뿐이다.
--   자동으로 열어 두면 「만료」가 아무 의미가 없어진다.
--
-- 실행: Supabase SQL Editor. ⚠ membership_settings.sql 다음.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_guest_touch_on_purchase()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_days int; v_tier text;
begin
  -- 취소된 건은 구매로 치지 않는다. 사고 취소해서 기한만 미는 길을 막는다.
  if coalesce(new.status, '') in ('cancelled','canceled') then return new; end if;

  -- 홀드·수동입력 행은 실제 구매가 아니다 (초대 홀드·어드민 수기).
  if coalesce(new.purchase_id, '') like 'INVH-%' then return new; end if;

  select upper(coalesce(membership_tier,'')) into v_tier
    from public.profiles where id = new.user_id;
  if v_tier is distinct from 'A' then return new; end if;   -- 게스트만

  select coalesce((v#>>'{}')::int, 90) into v_days
    from public.membership_settings where k = 'guest_days';

  -- ⚠ 기존 값에 더하지 않는다. 「마지막 구매로부터 90일」이지
  --   「살 때마다 90일씩 쌓기」가 아니다.
  update public.profiles
     set guest_expires_at = now() + (coalesce(v_days, 90) || ' day')::interval
   where id = new.user_id;

  return new;
end;
$$;

comment on function public.taam_guest_touch_on_purchase() is
  '게스트가 티켓을 사면 만료일을 「지금 + guest_days」로 다시 잡는다. 3개월 동안 구매가 없어야 만료된다.';

drop trigger if exists trg_taam_guest_touch_on_purchase on public.tickets;
create trigger trg_taam_guest_touch_on_purchase
  after insert on public.tickets
  for each row execute function public.taam_guest_touch_on_purchase();


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 트리거가 붙었나 ⭐' as "구분",
       case when count(*) = 1 then '✅' else '❌ 없음' end as "상태",
       '티켓이 들어오면 게스트 기한을 민다' as "메모"
  from pg_trigger
 where tgname = 'trg_taam_guest_touch_on_purchase' and not tgisinternal
union all
select '② 기간 설정값',
       coalesce((select (v#>>'{}') from public.membership_settings where k='guest_days'), '?') || '일',
       '이 값을 바꾸면 규칙이 바뀐다 (코드 수정 없음)'
union all
select '③ 연장 수단이 남아 있나 ⭐',
       case when count(*) = 1 then '✅' else '❌' end,
       '만료된 게스트는 이것으로만 되살아난다'
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guest_extend'
union all
select '④ 지금 기한이 있는 게스트',
       (select count(*)::text from public.profiles
         where upper(coalesce(membership_tier,'')) = 'A'
           and guest_expires_at is not null) || '명',
       '그중 만료됨: ' ||
       (select count(*)::text from public.profiles
         where upper(coalesce(membership_tier,'')) = 'A'
           and guest_expires_at is not null and guest_expires_at <= now()) || '명'
 order by 1;
