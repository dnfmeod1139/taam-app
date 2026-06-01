-- ═══════════════════════════════════════════════════════════════
-- TAAM — 본인 매칭 invite_codes 자동 used 처리 RPC (2026-06-01)
-- ═══════════════════════════════════════════════════════════════
-- 시나리오: verify-invite already_member 차단으로 로그인 우회한 경우,
-- 또는 _doProfileAndConsume 의 consume-invite 호출이 실패한 경우 —
-- 회원은 가입됐지만 invite_codes 의 used 가 false 로 남음.
--
-- 이 RPC 는 본인 (auth.uid()) 의 email/phone 으로 매칭되는
-- used=false invite_codes 를 자동으로 used=true + 메타정보 채움.
-- 멱등성: 이미 used=true 면 건드리지 않음.
--
-- 호출: 클라이언트가 _backfillProfileFromInvite 끝에서 window.sb.rpc(...).
-- ═══════════════════════════════════════════════════════════════

create or replace function public.consume_invite_by_self()
returns integer
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  my_id           uuid;
  my_email        text;
  my_phone        text;
  my_phone_digits text;
  my_name         text;
  updated_count   integer := 0;
begin
  my_id := auth.uid();
  if my_id is null then
    return 0;  -- 인증 없는 호출은 무시
  end if;

  -- auth.users 의 email/phone (가장 정확한 소스)
  select lower(coalesce(email,'')), coalesce(phone,'')
    into my_email, my_phone
  from auth.users where id = my_id;

  -- profiles 폴백
  if my_phone is null or my_phone = '' then
    select coalesce(phone,'') into my_phone from public.profiles where id = my_id;
  end if;
  select coalesce(nullif(btrim(display_name),''), '')
    into my_name
  from public.profiles where id = my_id;

  -- 한국번호 정규화: 숫자만 + 선행 82 제거 + 선행 0 제거
  my_phone_digits := regexp_replace(coalesce(my_phone,''), '[^0-9]', '', 'g');
  my_phone_digits := regexp_replace(my_phone_digits, '^82', '');
  my_phone_digits := regexp_replace(my_phone_digits, '^0+', '');

  -- 본인 매칭 + 미사용 invite_codes 를 자동 used=true 처리
  -- 🔧 member_id 는 text 타입이라 uuid 캐스팅 필요
  update public.invite_codes ic
  set
    used         = true,
    used_at      = coalesce(ic.used_at, now()),
    used_by_email = coalesce(nullif(btrim(ic.used_by_email),''), nullif(my_email,'')),
    used_by_phone = coalesce(nullif(btrim(ic.used_by_phone),''), nullif(my_phone,'')),
    used_by_name  = coalesce(nullif(btrim(ic.used_by_name),''), nullif(my_name,''), ic.invitee_name),
    member_id     = coalesce(nullif(btrim(ic.member_id),''), my_id::text)
  where ic.used = false
    and (
      (my_email <> '' and (
        lower(coalesce(ic.invitee_email,'')) = my_email
        or lower(coalesce(ic.used_by_email,'')) = my_email))
      or (length(my_phone_digits) >= 4 and (
        regexp_replace(coalesce(ic.invitee_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%'
        or regexp_replace(coalesce(ic.used_by_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%'))
    );

  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;

-- ═══════════════════════════════════════════════════════════════
-- 기존 미사용 invite_codes 일괄 보정 (구자호/유수봉 같은 케이스)
-- profiles 에 가입돼 있고 invite_codes 에 매칭 row 가 있는데
-- used=false 로 남은 경우 → used=true 일괄 처리
-- ═══════════════════════════════════════════════════════════════
update public.invite_codes ic
set
  used = true,
  used_at = coalesce(ic.used_at, p.created_at, now()),
  used_by_email = coalesce(nullif(btrim(ic.used_by_email),''), p.email),
  used_by_phone = coalesce(nullif(btrim(ic.used_by_phone),''), p.phone),
  used_by_name  = coalesce(nullif(btrim(ic.used_by_name),''), nullif(btrim(p.display_name),''), ic.invitee_name),
  -- 🔧 member_id 는 text 타입 — uuid 캐스팅 필요
  member_id     = coalesce(nullif(btrim(ic.member_id),''), p.id::text)
from public.profiles p
where ic.used = false
  and p.deleted_at is null
  and (
    (p.email is not null and ic.invitee_email is not null
      and lower(btrim(p.email)) = lower(btrim(ic.invitee_email)))
    or (p.email is not null and ic.used_by_email is not null
      and lower(btrim(p.email)) = lower(btrim(ic.used_by_email)))
    or (p.phone is not null and ic.invitee_phone is not null
      and regexp_replace(p.phone, '[^0-9]', '', 'g')
          = regexp_replace(ic.invitee_phone, '[^0-9]', '', 'g'))
    or (p.phone is not null and ic.used_by_phone is not null
      and regexp_replace(p.phone, '[^0-9]', '', 'g')
          = regexp_replace(ic.used_by_phone, '[^0-9]', '', 'g'))
  );

-- ── 통계 ──
select count(*) filter (where used = true) as used_now,
       count(*) filter (where used = false) as unused_now,
       count(*) as total
from public.invite_codes;

do $$ begin raise notice '✅ consume_invite_by_self RPC 생성 + 일괄 보정 완료'; end $$;
