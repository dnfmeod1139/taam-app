-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원 탈퇴 (soft-delete) + 이름 백필 (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 두 작업 한 번에:
--   ① profiles.deleted_at timestamptz 컬럼 추가 (soft-delete)
--      슈퍼어드민이 회원 탈퇴 시 set. 회원 목록에서 숨김 처리.
--   ② display_name 비어있는 기존 가입자를 invite_codes.invitee_name 으로 backfill
--      ("이형주" 초대 → 가입 후 이름 빈 문제 케이스 보정)
--
-- 실행: Supabase SQL Editor 1회.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. deleted_at 컬럼 추가 ──
alter table public.profiles
  add column if not exists deleted_at timestamptz;

comment on column public.profiles.deleted_at is
  '회원 탈퇴 시점. NULL=활성. 슈퍼어드민이 soft-delete 처리. 데이터 자체는 보존.';

create index if not exists idx_profiles_deleted_at on public.profiles(deleted_at) where deleted_at is null;

-- ── 2. display_name 백필 (invite_codes 매칭) ──
-- 이메일 또는 휴대폰으로 매칭해서 invitee_name 을 display_name 에 보충.
-- 이미 이름이 있는 회원은 건드리지 않음.
update public.profiles p
set display_name = ic.invitee_name
from public.invite_codes ic
where (p.display_name is null or btrim(p.display_name) = '')
  and ic.used = true
  and ic.invitee_name is not null
  and btrim(ic.invitee_name) <> ''
  and (
    -- 이메일 매칭
    (p.email is not null and ic.used_by_email is not null
       and lower(btrim(p.email)) = lower(btrim(ic.used_by_email)))
    -- 또는 invitee_email 매칭 (used_by_email 미설정 케이스 대비)
    or (p.email is not null and ic.invitee_email is not null
       and lower(btrim(p.email)) = lower(btrim(ic.invitee_email)))
    -- 휴대폰 매칭 (숫자만 추출 비교)
    or (p.phone is not null and ic.used_by_phone is not null
       and regexp_replace(p.phone, '[^0-9]', '', 'g') = regexp_replace(ic.used_by_phone, '[^0-9]', '', 'g'))
    or (p.phone is not null and ic.invitee_phone is not null
       and regexp_replace(p.phone, '[^0-9]', '', 'g') = regexp_replace(ic.invitee_phone, '[^0-9]', '', 'g'))
  );

-- ── 검증 쿼리 (실행 후 확인용) ──
-- 1) 백필 결과 — display_name 채워진 회원 수:
select count(*) as named_members
from public.profiles
where display_name is not null and btrim(display_name) <> '' and deleted_at is null;

-- 2) 여전히 이름 비어있는 회원 (수동 입력 필요):
select id, email, phone, created_at
from public.profiles
where (display_name is null or btrim(display_name) = '')
  and deleted_at is null
order by created_at desc
limit 20;

-- 3) deleted_at 컬럼 + 인덱스 확인:
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='profiles' and column_name='deleted_at';

do $$ begin raise notice '✅ profiles.deleted_at 추가 + display_name 백필 완료'; end $$;
