-- ═══════════════════════════════════════════════════════════════
-- TAAM — invite_codes.invitee_tier 컬럼 추가 (2026-06-01)
-- ═══════════════════════════════════════════════════════════════
-- 슈퍼어드민이 초대 코드 발급 시 받는 회원의 등급(M/T)을 미리 지정.
-- 가입 시 consume-invite 또는 클라이언트에서 profiles.membership_tier 로
-- 그 등급 자동 설정 → 등급별 우선 공개 기능과 일관성 유지.
--
-- 등급 정책:
--   M (Members): 멤버십 등급, 우선 공개 대상, 결제 시 만료일 자동 설정
--   T (Tier-T):  티켓 등급, M 공개 이후 N시간/일 뒤에 티켓 접근 가능
-- ═══════════════════════════════════════════════════════════════

alter table public.invite_codes
  add column if not exists invitee_tier text default 'T';

comment on column public.invite_codes.invitee_tier is
  '초대받는 회원의 등급. M=멤버십(우선공개), T=티켓등급(기본). 가입 시 profiles.membership_tier 로 복사됨.';

-- CHECK 제약 (M 또는 T 만 허용)
do $$ begin
  begin
    alter table public.invite_codes
      add constraint invite_codes_tier_check check (invitee_tier in ('M','T'));
  exception when duplicate_object then
    null; -- 이미 있으면 skip
  end;
end $$;

create index if not exists idx_invite_codes_tier on public.invite_codes(invitee_tier);

-- ── 기존 미사용 코드는 기본값 T 유지, 이미 사용된 것은 그대로 ──
update public.invite_codes set invitee_tier = 'T'
where invitee_tier is null;

-- ── 검증 ──
select column_name, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='invite_codes'
  and column_name='invitee_tier';

do $$ begin raise notice '✅ invite_codes.invitee_tier 컬럼 추가 완료'; end $$;
