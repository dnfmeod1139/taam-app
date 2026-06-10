-- 지로 vs 오노 요시카즈 (긴자 본점) 노드 동기화 진단 (2026-05-24)
--
-- 사용자 보고: 두 노드 (jiro, yoshi) 가 동기화되어 한 노드 편집 시 다른 노드도 같이 바뀐다.
-- 가설 확인:
--   A) 한 row 만 존재 → 둘 다 같은 데이터 → 분리 필요
--   B) 두 row 존재하지만 데이터 (name/sub/photo/desc) 가 동일 → 사용자 입력 실수
--   C) 두 row 존재 + 데이터 다름 → 코드 레벨 동기화 문제 (다른 진단 필요)

SELECT
  id,
  lineage_id,
  name,
  sub_title,
  (node_photo IS NOT NULL AND length(node_photo) > 0) AS has_photo,
  length(node_photo) AS photo_size,
  sec1_data->>'title' AS sec1_title,
  left(sec1_data->>'desc', 60) AS sec1_desc_preview,
  sec2_data->>'title' AS sec2_title,
  left(sec2_data->>'desc', 60) AS sec2_desc_preview,
  ticket_status,
  updated_at
FROM chefs
WHERE lineage_id = 'jiro' AND id IN ('jiro', 'yoshi')
ORDER BY id;

-- 기대 정상 결과: row 2개, id='jiro' 와 id='yoshi' 별개 데이터.
-- 만약 row 1개만 나오거나, 두 row 의 nodePhoto/sec1_data 가 같으면 그게 동기화 원인.
