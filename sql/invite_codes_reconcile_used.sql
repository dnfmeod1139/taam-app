-- ═══════════════════════════════════════════════════════════════
-- TAAM — invite_codes used 상태 자동 보정 (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 증상: 회원이 정상 가입했는데 invite_codes.used 가 false 로 남음.
--   원인: consume-invite Edge Function 호출이 어떤 이유로 실패
--         (네트워크, 페이지 이탈, verify-invite 의 already_member 분기 등).
--
-- 이 SQL 은:
--   ① 진단 — used=false 인데 매칭 profile 있는 코드 목록
--   ② 보정 — 그 코드들을 자동으로 used=true + used_at/by_email/by_name 채움
--
-- 실행: Supabase SQL Editor 1회.
-- 멱등성: 이미 used=true 인 코드는 건드리지 않음. 여러 번 실행해도 안전.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 진단: 보정 대상 미리 보기 ──
select
  ic.code,
  ic.invitee_name,
  ic.invitee_email,
  ic.invitee_phone,
  ic.used as current_used,
  p.id        as matched_profile_id,
  p.email     as matched_email,
  p.phone     as matched_phone,
  p.created_at as profile_created_at
from public.invite_codes ic
left join public.profiles p on
  (p.email is not null and ic.invitee_email is not null
     and lower(btrim(p.email)) = lower(btrim(ic.invitee_email)))
  or (p.email is not null and ic.used_by_email is not null
     and lower(btrim(p.email)) = lower(btrim(ic.used_by_email)))
  or (p.phone is not null and ic.invitee_phone is not null
     and regexp_replace(p.phone, '[^0-9]', '', 'g') = regexp_replace(ic.invitee_phone, '[^0-9]', '', 'g'))
  or (p.phone is not null and ic.used_by_phone is not null
     and regexp_replace(p.phone, '[^0-9]', '', 'g') = regexp_replace(ic.used_by_phone, '[^0-9]', '', 'g'))
where ic.used = false
  and p.id is not null
order by p.created_at desc nulls last;

-- ── ② 보정 ──
-- used=false 인데 매칭 profile 이 있는 코드 → 자동 used=true 처리.
-- 부수적으로 used_at, used_by_email, used_by_name 채움 (비어있으면).
update public.invite_codes ic
set
  used         = true,
  used_at      = coalesce(ic.used_at, p.created_at, now()),
  used_by_email = coalesce(nullif(btrim(ic.used_by_email), ''), p.email),
  used_by_phone = coalesce(nullif(btrim(ic.used_by_phone), ''), p.phone),
  used_by_name  = coalesce(nullif(btrim(ic.used_by_name), ''), nullif(btrim(p.display_name), ''), ic.invitee_name)
from public.profiles p
where ic.used = false
  and (
    (p.email is not null and ic.invitee_email is not null
       and lower(btrim(p.email)) = lower(btrim(ic.invitee_email)))
    or (p.email is not null and ic.used_by_email is not null
       and lower(btrim(p.email)) = lower(btrim(ic.used_by_email)))
    or (p.phone is not null and ic.invitee_phone is not null
       and regexp_replace(p.phone, '[^0-9]', '', 'g') = regexp_replace(ic.invitee_phone, '[^0-9]', '', 'g'))
    or (p.phone is not null and ic.used_by_phone is not null
       and regexp_replace(p.phone, '[^0-9]', '', 'g') = regexp_replace(ic.used_by_phone, '[^0-9]', '', 'g'))
  );

-- ── 보정 후 통계 ──
select
  count(*) filter (where used = true) as used_now,
  count(*) filter (where used = false) as unused_now,
  count(*) as total
from public.invite_codes;

do $$ begin raise notice '✅ invite_codes.used 자동 보정 완료'; end $$;
