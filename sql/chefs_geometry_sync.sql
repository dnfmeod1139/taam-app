-- ═══════════════════════════════════════════════════════════════
-- chefs 테이블 — 노드 좌표/부모/연결 정보 동기화
-- 작성일: 2026-05-22
--
-- 문제:
--   기존 saveCustomNodes 는 IDB(IndexedDB) 에만 좌표를 저장.
--   슈퍼어드민이 노드 추가하면 그 브라우저에만 보이고, 다른 기기에서는 안 보임.
--
-- 해결:
--   chefs 테이블에 geometry jsonb 컬럼 추가 → 좌표/부모/연결 정보 클라우드 sync.
--   { x, y, parentId, parentX, parentY, connection, lineageId, custom: true }
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 컬럼 추가 (idempotent) ──
alter table public.chefs
  add column if not exists geometry jsonb default '{}'::jsonb,
  add column if not exists is_custom boolean default false;

comment on column public.chefs.geometry is '동적 노드 좌표/부모/연결 정보 (x, y, parentId, parentX, parentY, connection)';
comment on column public.chefs.is_custom is '슈퍼어드민이 동적으로 추가한 노드 여부 (true=customNodes 출처)';

-- ── 2. 인덱스 (성능) ──
create index if not exists idx_chefs_lineage_custom on public.chefs(lineage_id, is_custom);
create index if not exists idx_chefs_lineage on public.chefs(lineage_id);

-- ── 3. 진단: 동적 노드 현황 + 스시문 검색 ──
select
  id,
  lineage_id,
  name,
  sub_title,
  is_custom,
  geometry,
  updated_at
from public.chefs
where is_custom = true
   or name ilike '%스시문%'
   or name ilike '%스시 문%'
   or name ilike '%sushimun%'
order by updated_at desc nulls last
limit 30;

-- ── 4. 스시문 좌표 보정 (이름으로 검색해서 카네사카 계보의 노드를 90,820 으로) ──
--    ⚠ 결과 row 개수가 1개인지 확인 후 실행할 것.
--    여러 개면 정확한 ID로 좁혀서 update.
update public.chefs
set
  geometry = coalesce(geometry, '{}'::jsonb)
           || jsonb_build_object('x', 90, 'y', 820),
  is_custom = true,
  updated_at = now()
where lineage_id = 'kanesaka'
  and (name ilike '%스시문%' or name ilike '%스시 문%')
returning id, lineage_id, name, geometry;

-- ── 5. 검증 ──
select
  id, lineage_id, name, geometry->>'x' as x, geometry->>'y' as y, geometry->>'parentId' as parent_id
from public.chefs
where lineage_id = 'kanesaka' and is_custom = true
order by updated_at desc nulls last
limit 10;

-- 완료
do $$ begin
  raise notice '✅ chefs.geometry / is_custom 컬럼 추가 완료 + 스시문 보정 시도';
end $$;
