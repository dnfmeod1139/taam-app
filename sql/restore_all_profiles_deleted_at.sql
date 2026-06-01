-- ═══════════════════════════════════════════════════════════════
-- TAAM — profiles.deleted_at 전체 NULL 복구 + 진단 (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 증상: v1.53.16 적용 후 회원 목록이 비어있음 (모든 회원이 탈퇴 상태로 보임).
-- 원인 추정: 의도치 않게 모든 row 에 deleted_at 이 set 됨.
--
-- 이 SQL 은 두 단계:
--   ① 진단 — 현재 deleted_at 상태 확인 (먼저 실행해서 영향 범위 파악)
--   ② 복구 — 모든 deleted_at 을 NULL 로 되돌림 (의도적으로 탈퇴시킨 회원이 없다는 전제)
-- ═══════════════════════════════════════════════════════════════

-- ── ① 진단: 현재 상태 확인 ──
select
  count(*) filter (where deleted_at is null) as active_count,
  count(*) filter (where deleted_at is not null) as deleted_count,
  count(*) as total
from public.profiles;

-- 어떤 deleted_at 값들이 있는지 (분포 확인)
select
  date_trunc('minute', deleted_at) as bucket,
  count(*) as cnt
from public.profiles
where deleted_at is not null
group by 1
order by 1 desc
limit 10;

-- ── ② 복구 (위 진단 확인 후 실행. 실수로 set 된 거면 전체 NULL 로) ──
update public.profiles
set deleted_at = null
where deleted_at is not null;

-- 복구 후 확인
select count(*) as active_after
from public.profiles
where deleted_at is null;

do $$ begin raise notice '✅ profiles.deleted_at 전체 NULL 복구 완료'; end $$;
