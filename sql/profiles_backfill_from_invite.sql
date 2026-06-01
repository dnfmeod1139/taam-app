-- ═══════════════════════════════════════════════════════════════
-- TAAM — 기존 회원 이름/등급 일괄 백필 (invite_codes 매칭) — 2026-06-01
-- ═══════════════════════════════════════════════════════════════
-- 시나리오: verify-invite 의 already_member 차단으로 인해 _pendingInviteCode 가
-- 안 채워진 채로 로그인 우회 가입한 케이스, 또는 슈퍼어드민이 부여로 만든
-- 회원 — display_name / membership_tier 가 비어있음.
--
-- 이 SQL 은 멱등적으로 invite_codes 의 invitee_name / invitee_tier 를
-- 매칭(email or phone)해서 profiles 를 보강. 이미 채워진 값은 건드리지 않음.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 진단: 현재 이름·등급 비어있는 회원 미리보기 ──
select p.id, p.email, p.phone, p.display_name, p.membership_tier,
       ic.code as matching_code, ic.invitee_name, ic.invitee_tier
from public.profiles p
left join public.invite_codes ic
  on  (p.email is not null and ic.used_by_email is not null
        and lower(btrim(p.email)) = lower(btrim(ic.used_by_email)))
   or (p.email is not null and ic.invitee_email is not null
        and lower(btrim(p.email)) = lower(btrim(ic.invitee_email)))
   or (p.phone is not null and ic.used_by_phone is not null
        and regexp_replace(p.phone, '[^0-9]', '', 'g')
            = regexp_replace(ic.used_by_phone, '[^0-9]', '', 'g'))
   or (p.phone is not null and ic.invitee_phone is not null
        and regexp_replace(p.phone, '[^0-9]', '', 'g')
            = regexp_replace(ic.invitee_phone, '[^0-9]', '', 'g'))
where (p.display_name is null or btrim(p.display_name) = '' or p.membership_tier is null)
  and p.deleted_at is null
order by p.created_at desc
limit 30;

-- ── ② 이름 백필 (display_name 비어있는 회원만) ──
update public.profiles p
set display_name = ic.invitee_name
from public.invite_codes ic
where (p.display_name is null or btrim(p.display_name) = '')
  and ic.invitee_name is not null
  and btrim(ic.invitee_name) <> ''
  and (
    (p.email is not null and ic.used_by_email is not null
      and lower(btrim(p.email)) = lower(btrim(ic.used_by_email)))
    or (p.email is not null and ic.invitee_email is not null
      and lower(btrim(p.email)) = lower(btrim(ic.invitee_email)))
    or (p.phone is not null and ic.used_by_phone is not null
      and regexp_replace(p.phone, '[^0-9]', '', 'g')
          = regexp_replace(ic.used_by_phone, '[^0-9]', '', 'g'))
    or (p.phone is not null and ic.invitee_phone is not null
      and regexp_replace(p.phone, '[^0-9]', '', 'g')
          = regexp_replace(ic.invitee_phone, '[^0-9]', '', 'g'))
  );

-- ── ③ 등급 백필 (membership_tier 비어있는 회원만) ──
update public.profiles p
set membership_tier = ic.invitee_tier,
    membership_expires_at = case
      when ic.invitee_tier = 'M' and p.membership_expires_at is null
        then now() + interval '365 days'
      else p.membership_expires_at
    end
from public.invite_codes ic
where p.membership_tier is null
  and ic.invitee_tier in ('M', 'T')
  and (
    (p.email is not null and ic.used_by_email is not null
      and lower(btrim(p.email)) = lower(btrim(ic.used_by_email)))
    or (p.email is not null and ic.invitee_email is not null
      and lower(btrim(p.email)) = lower(btrim(ic.invitee_email)))
    or (p.phone is not null and ic.used_by_phone is not null
      and regexp_replace(p.phone, '[^0-9]', '', 'g')
          = regexp_replace(ic.used_by_phone, '[^0-9]', '', 'g'))
    or (p.phone is not null and ic.invitee_phone is not null
      and regexp_replace(p.phone, '[^0-9]', '', 'g')
          = regexp_replace(ic.invitee_phone, '[^0-9]', '', 'g'))
  );

-- ── ④ 백필 후 확인 ──
select count(*) filter (where display_name is not null and btrim(display_name) <> '') as named,
       count(*) filter (where membership_tier is not null) as tiered,
       count(*) as total_active
from public.profiles
where deleted_at is null;

-- ── ⑤ 남은 미보정 회원 (수동 점검용) ──
select id, email, phone, created_at
from public.profiles
where (display_name is null or btrim(display_name) = '')
  and deleted_at is null
order by created_at desc
limit 20;

do $$ begin raise notice '✅ profiles 이름/등급 일괄 백필 완료'; end $$;
