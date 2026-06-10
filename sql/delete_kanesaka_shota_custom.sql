-- ═══════════════════════════════════════════════════════════════
-- chefs.shota (카네사카) 동적 노드 row 삭제
-- 작성일: 2026-05-22
--
-- 배경:
--   하드코딩 nKshota 노드 (원래 문경환 쉐프 자리) 가 카네사카 SVG 에 있는 상태에서
--   사용자가 같은 id 'shota' 로 동적 노드를 만들고 좌표 (90, 820), 이름 "스시 문 (오픈예정)" 으로
--   chefs 테이블에 row 를 저장 → 결과적으로 같은 노드가 두 위치에 동시 표시됨.
--
-- 해결:
--   하드코딩 노드 자체를 (90, 820) 로 이동 + 이름 "스시 문 (오픈예정)" 으로 갱신함 (코드 수정 완료).
--   이제 chefs.shota 동적 row 는 더 이상 필요 없음 → 삭제.
--   loadCustomNodes 가 chefs 에서 이 row 를 안 가져오게 됨 → 이중 표시 해소.
-- ═══════════════════════════════════════════════════════════════

-- 1) 삭제 전 확인 (참고용 — sec1/sec2 등에 사용자가 입력한 정보가 있는지)
select
  id, lineage_id, name, sub_title,
  is_custom,
  geometry,
  sec1_data->>'desc'  as sec1_desc,
  sec2_data->>'desc'  as sec2_desc,
  updated_at
from public.chefs
where id = 'shota' and lineage_id = 'kanesaka';

-- 2) 삭제
--    ⚠ 이 row 가 가지고 있는 sec1/sec2 내용도 함께 사라짐.
--      만약 사용자가 입력한 정보가 있다면 다시 입력해야 함.
--      운영상 중요한 내용이 없다고 판단되면 진행.
delete from public.chefs
where id = 'shota' and lineage_id = 'kanesaka';

-- 3) 확인 — 0 rows 면 삭제 성공
select count(*) as remaining
from public.chefs
where id = 'shota' and lineage_id = 'kanesaka';

-- 완료
do $$ begin
  raise notice '✅ chefs.shota (kanesaka) 동적 row 삭제 완료';
end $$;
