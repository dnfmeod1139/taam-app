-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원이 자기 등급을 올리지 못하게 막는다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제였나
--   오늘 등급 제한 서버 가드(trg_taam_guard_ticket_tier)를 넣었다. 그런데
--   그 가드는 profiles.membership_tier 를 읽어서 판정하고,
--   **회원은 그 컬럼을 직접 쓸 수 있다.**
--
--     profiles 의 UPDATE 정책 = 「본인 행이면 통과」 (컬럼을 안 가린다)
--     → 회원이 앱을 안 거치고 membership_tier='M' 으로 바꾸면
--       서버 가드가 그 값을 그대로 믿는다. 가드가 무의미해진다.
--
--   role(자기 승격)과 예치금 잔액은 오늘 막았는데 이것만 남아 있었다.
--   가드를 넣을 때 같이 확인했어야 했다.
--
-- 왜 통째로 막으면 안 되나
--   가입 흐름이 초대코드 등급을 **회원 세션에서** 여기에 쓴다.
--     index.html:17399   가입 직후 invite_codes.invitee_tier 적용
--     index.html:15440   백필 — 비어 있으면 나중에 채운다
--   통째로 막으면 가입한 회원의 등급이 영영 안 붙는다.
--
-- 그래서 「비어 있을 때, 자기 초대코드가 말하는 값으로만」 허용한다
--   · 이미 등급이 있으면 회원은 못 바꾼다 (올리는 것도 내리는 것도)
--   · 비어 있어도 **아무 값이나** 못 넣는다 — 자기 초대코드의 invitee_tier 와
--     같아야 한다. 초대코드가 T 인데 M 을 넣으면 막힌다.
--   · M 을 처음 받을 때 만료일은 서버가 365일로 정한다. 회원이 10년 뒤로
--     밀어 넣는 길을 같이 막는다.
--
-- ⚠ 막을 때 예외를 던지지 않고 **값만 되돌린다.**
--   가입 UPDATE 는 membership_tier · country · membership_expires_at 을
--   한 문장에 같이 쓴다(index.html:17398). 예외를 던지면 country 까지
--   통째로 날아가서, 등급 하나 막으려다 가입 정보가 안 들어간다.
--   role 가드에서 이미 같은 이유로 「조용히 되돌리기」를 골랐다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포 필요 없음 — 앱은 이 트리거를 몰라도 그대로 돈다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 전화번호 정규화 — 앱과 같은 규칙
-- ═══════════════════════════════════════════════════════════════
--   앱: replace(/[^0-9]/g,'') → replace(/^82/,'') → replace(/^0+/,'')
--   저장된 값이 '010-1234-5678' 처럼 들어 있어서 양쪽을 다 정규화해야 맞는다.
create or replace function public._taam_phone_key(p_text text)
returns text
language sql
immutable
as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(coalesce(p_text, ''), '[^0-9]', '', 'g'),
           '^82', ''),
         '^0+', '')
$$;


-- ═══════════════════════════════════════════════════════════════
-- ② 이 회원의 초대코드가 말하는 등급
-- ═══════════════════════════════════════════════════════════════
--   앱이 쓰는 매칭과 같은 축이다 — member_id · used_by_* · invitee_*.
--   못 찾으면 null (= 아무 등급도 허용하지 않는다).
create or replace function public.taam_invited_tier(p_user_id uuid, p_email text, p_phone text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_pkey  text := public._taam_phone_key(p_phone);
  v_tier  text;
begin
  select upper(btrim(ic.invitee_tier))
    into v_tier
    from public.invite_codes ic
   where upper(btrim(coalesce(ic.invitee_tier,''))) in ('M','T','A')
     and (
          -- ⚠ invite_codes.member_id 는 uuid 가 아니라 **text** 다.
          --   그냥 비교하면 42883 (operator does not exist: text = uuid) 로 죽는다.
          ic.member_id::text = p_user_id::text
       or (v_email <> '' and lower(btrim(coalesce(ic.used_by_email,''))) = v_email)
       or (v_email <> '' and lower(btrim(coalesce(ic.invitee_email,''))) = v_email)
       or (length(v_pkey) >= 8 and public._taam_phone_key(ic.used_by_phone) = v_pkey)
       or (length(v_pkey) >= 8 and public._taam_phone_key(ic.invitee_phone) = v_pkey)
     )
   order by ic.used_at desc nulls last
   limit 1;

  return v_tier;
end;
$$;

comment on function public.taam_invited_tier(uuid, text, text) is
  '이 회원의 초대코드가 지정한 등급. 등급 가드가 「가입 시 첫 설정」을 대조할 때 쓴다.';


-- ═══════════════════════════════════════════════════════════════
-- ③ 가드 — 회원은 자기 등급을 올릴 수 없다
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_membership_tier()
returns trigger
language plpgsql
set search_path = public
as $tier$
declare
  v_old   text := upper(btrim(coalesce(old.membership_tier, '')));
  v_new   text := upper(btrim(coalesce(new.membership_tier, '')));
  v_want  text;
begin
  -- 등급도 만료일도 그대로면 볼 것 없다
  if new.membership_tier is not distinct from old.membership_tier
     and new.membership_expires_at is not distinct from old.membership_expires_at then
    return new;
  end if;

  -- 서버가 하는 일은 막지 않는다 (RPC · Edge Function · service_role · 크론)
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- 슈퍼어드민의 등급 조정은 계속 돼야 한다 (회원 관리 화면)
  if public._taam_uid_is_super() then
    return new;
  end if;

  -- 여기부터는 회원이 자기 행을 건드린 것이다.
  --
  -- 허용되는 단 하나의 경우: 등급이 **비어 있었고**, 새 값이 자기 초대코드가
  -- 말하는 등급과 같을 때. 가입 직후 한 번만 성립한다.
  if v_old = '' and v_new in ('M','T','A') then
    v_want := public.taam_invited_tier(new.id, new.email, new.phone);

    if v_want is not null and v_want = v_new then
      -- 만료일은 서버가 정한다. 회원이 실어 보낸 값은 쓰지 않는다 —
      -- M 을 받으면서 만료일을 10년 뒤로 밀어 넣는 길을 막는다.
      if v_new = 'M' then
        new.membership_expires_at := now() + interval '365 days';
      else
        new.membership_expires_at := old.membership_expires_at;
      end if;
      return new;
    end if;

    raise warning '[guard] 초대 등급과 불일치 — 되돌림 (uid=% 요청=% 초대=%)',
      new.id, v_new, coalesce(v_want, '없음');
  elsif v_old <> '' and v_new <> v_old then
    raise warning '[guard] 등급 변경 차단 (uid=% % → %)', new.id, v_old, v_new;
  elsif new.membership_expires_at is distinct from old.membership_expires_at then
    raise warning '[guard] 만료일 변경 차단 (uid=%)', new.id;
  end if;

  -- 되돌린다. 예외를 던지지 않는다 — 같은 문장의 다른 컬럼(country 등)은 살린다.
  new.membership_tier       := old.membership_tier;
  new.membership_expires_at := old.membership_expires_at;
  return new;
end;
$tier$;

drop trigger if exists trg_taam_guard_membership_tier on public.profiles;
create trigger trg_taam_guard_membership_tier
  before update on public.profiles
  for each row execute function public.taam_guard_membership_tier();

comment on function public.taam_guard_membership_tier() is
  '회원이 자기 등급·만료일을 바꾸지 못하게 막는다. 가입 시 초대코드 등급 첫 설정만 허용. 슈퍼어드민·서버는 예외.';


-- ═══════════════════════════════════════════════════════════════
-- ④ 확인
-- ═══════════════════════════════════════════════════════════════
select tgname as "트리거",
       case when tgenabled = 'O' then '켜짐' else tgenabled::text end as "상태"
from pg_trigger
where tgrelid = 'public.profiles'::regclass
  and tgname in ('trg_taam_guard_membership_tier',
                 'trg_taam_guard_deposit_balance',
                 'trg_taam_guard_profile_role')
order by 1;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   drop trigger if exists trg_taam_guard_membership_tier on public.profiles;
--
--   ⚠ 이 트리거를 내리면 오늘 넣은 등급 제한(trg_taam_guard_ticket_tier)도
--     같이 무의미해진다. 등급 값을 회원이 직접 쓸 수 있게 되기 때문이다.
--
-- ═══════════════════════════════════════════════════════════════
-- 남은 것
-- ═══════════════════════════════════════════════════════════════
--   ⓐ 가입 시 초대코드를 못 찾으면 등급이 안 붙는다. 종전에는 앱이 그냥 썼다.
--      실제로 그런 회원이 생기는지 아래로 확인하고, 있으면 슈퍼어드민이
--      회원 관리에서 직접 지정한다 (그 경로는 이 가드를 통과한다).
--
--      select p.display_name, p.phone, p.membership_tier,
--             public.taam_invited_tier(p.id, p.email, p.phone) as 초대등급
--        from public.profiles p
--       where coalesce(p.membership_tier,'') = ''
--       order by p.created_at desc;
