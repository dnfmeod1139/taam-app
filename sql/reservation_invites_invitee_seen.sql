-- ═══════════════════════════════════════════════════════════════
-- TAAM — reservation_invites.invitee_seen 컬럼 추가 (2026-06-01)
-- ═══════════════════════════════════════════════════════════════
-- 받은 회원이 "초대받은 티켓" 페이지에서 본 적 있는지 추적.
-- 미확인 = invitee_seen=false → 마이페이지/홈 GNB 에 숫자 배지·레드닷 표시.
-- 페이지 진입 시 본인의 모든 row 를 invitee_seen=true 처리 → 카운트 사라짐.
-- ═══════════════════════════════════════════════════════════════

alter table public.reservation_invites
  add column if not exists invitee_seen boolean not null default false;

comment on column public.reservation_invites.invitee_seen is
  '받은 회원이 받은 초대 페이지에서 본 적 있나. false=새 도착 (배지 카운트), true=확인됨.';

create index if not exists idx_resinv_invitee_unseen
  on public.reservation_invites(invitee_user_id, invitee_seen);

-- ── 검증 ──
select column_name, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='reservation_invites'
  and column_name='invitee_seen';

do $$ begin raise notice '✅ reservation_invites.invitee_seen 컬럼 추가 완료'; end $$;
