-- 카네사카 아오야마 노드 원본 위치 복원 (2026-05-23)
--
-- 문제: 사용자가 앱 편집 모드로 아오야마 노드를 이동했는데, 일부 path 끝점만
--       transform 으로 이동되고 일부 path 는 매칭 실패해서 그대로 남아
--       파이프라인이 끊기고 잔상 (3개) 발생.
--
-- 원인: applyGeometryOverrides 가 chefs.geometry 의 x/y 를 기준으로 노드 g 에
--       transform=translate(dx, dy) 적용 + 연결된 path 끝점 자동 이동 시도.
--       path 끝점 매칭 (35px 내) 이 실패하면 일부만 이동 → 끊김.
--
-- 해결: chefs.aoyama row 의 geometry 컬럼을 null 로 set →
--       applyGeometryOverrides 가 transform 적용 안 함 → 원본 SVG 위치 그대로.
--       원본 좌표: rect(x=271, y=906, w=58, h=58) → 중심 (300, 935)
--
-- 적용 후: 페이지 새로고침 + SW 강제 재시작 (Ctrl+Shift+R) 하면 복원됨.

-- 1) 현재 상태 확인 (diagnostic)
SELECT id, lineage_id, name, geometry, updated_at
FROM chefs
WHERE id = 'aoyama' AND lineage_id = 'kanesaka';

-- 2) geometry override 제거 — null 로 set
UPDATE chefs
SET geometry = NULL,
    updated_at = NOW()
WHERE id = 'aoyama' AND lineage_id = 'kanesaka';

-- 3) 결과 확인
SELECT id, lineage_id, name, geometry, updated_at
FROM chefs
WHERE id = 'aoyama' AND lineage_id = 'kanesaka';
-- 기대 결과: geometry 컬럼이 NULL
