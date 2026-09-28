-- ═════════════════════════════════════════════════
-- 계보 노드 이름 번역이 빈 행 (읽기 전용) · 2026-09-28
-- ═════════════════════════════════════════════════
-- 배경: JA 화면에 「스시 큐베이 1대」가 한글로 뜬 데는 코드 쪽 원인(존재하지 않는 컬럼을 select 해
--   조용히 실패)과 데이터 쪽 원인(name_jp 가 비어 있음)이 같이 있었다. 코드는 고쳤고, 이 표는 데이터 쪽이다.
--   본문(desc_jp)은 번역됐는데 이름만 빈 행은 「AI 가 이름 항목을 빼고 돌려준 것」이라 ai_draft 로 찍혀
--   일괄 번역이 건너뛰던 행이다 — 이제 일괄 번역이 이런 행도 잡는다(앱 2026.09.28-c).
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 결과가 0행이면 할 일 없음.
-- 채우는 법 ① 어드민 메뉴 → 「🌳 계보도 노드 일괄 AI 번역」(이름이 빈 행을 이제 잡는다)
--          ② 한자·로마자 표기가 음차와 달라야 하는 매장(久兵衛 등)은 노드 편집에서 name_en/name_jp 를 직접 적고
--             i18n_status_* 를 'manual' 로 (AI 가 덮어쓰지 않는다)
select lineage_id, id, name,
       coalesce(name_en,'')  as name_en,
       coalesce(name_jp,'')  as name_jp,
       coalesce(sub_title,'') as sub_title,
       coalesce(sub_en,'')   as sub_en,
       coalesce(sub_jp,'')   as sub_jp,
       coalesce(i18n_status_en,'') as st_en,
       coalesce(i18n_status_jp,'') as st_jp,
       case when coalesce(sec1_data->>'desc_jp','') <> '' then '본문은 JA 번역됨 — 이름만 빔' else '' end as note
  from public.chefs
 where coalesce(name,'') <> ''
   and (coalesce(name_jp,'') = '' or coalesce(name_en,'') = '')
 order by lineage_id, id;
