-- ════════════════════════════════════════════════════════════════
-- 번역 상태 진단 (2026-09-07)  ⚠ Supabase SQL Editor 에서 RUN
--
-- 왜 보는가
--   일괄 번역(_i18nBatch)은 「i18n_status_en 이 pending 인 행」만 집는다.
--   그런데 번역이 비어 있는데도 상태가 ai_draft 로 찍혀 있으면, 배치는
--   이미 처리한 행으로 보고 영원히 건너뛴다. 그러면 아무리 돌려도
--   그 행의 일본어·영어는 채워지지 않는다.
--
--   i18n_jp_open.sql 결과에서 restaurants 가 146 중 80 만 번역돼 있었다.
--   나머지 66 이 pending 인지(=배치를 돌리면 채워진다) ai_draft 인지
--   (=상태만 찍히고 내용이 없다 → 갇혔다) 이 쿼리로 가른다.
--
-- 읽는 법
--   상태 = pending      → 정상. 배치를 돌리면 채워진다
--   상태 = ai_draft 인데 en_없음/jp_없음 이 0 이 아니다 → ⚠ 갇힌 행.
--     아래 「복구」 블록을 실행해 pending 으로 되돌려야 한다
-- ════════════════════════════════════════════════════════════════

select 'restaurants' as 테이블,
       coalesce(i18n_status_en,'(null)')                as 상태,
       count(*)                                          as 행수,
       count(*) filter (where name_en    is null or btrim(name_en)    = '') as en_없음,
       count(*) filter (where name_jp    is null or btrim(name_jp)    = '') as jp_없음
  from public.restaurants
 where coalesce(super_admin_only,false) = false
 group by 1,2
union all
select 'ticket_products',
       coalesce(i18n_status_en,'(null)'),
       count(*),
       count(*) filter (where ticket_desc_en is null or btrim(ticket_desc_en) = ''),
       count(*) filter (where ticket_desc_jp is null or btrim(ticket_desc_jp) = '')
  from public.ticket_products
 group by 1,2
union all
select 'venue_partners',
       coalesce(i18n_status_en,'(null)'),
       count(*),
       count(*) filter (where custom_name_en is null or btrim(custom_name_en) = ''),
       count(*) filter (where custom_name_jp is null or btrim(custom_name_jp) = '')
  from public.venue_partners
 group by 1,2
 order by 1,2;


-- ════════════════════════════════════════════════════════════════
-- 복구 — 「상태는 완료인데 번역이 비어 있는 행」만 pending 으로 되돌린다
--
-- ⚠ 위 진단에서 ai_draft 인데 en_없음/jp_없음 이 0 이 아닐 때만 실행한다.
--   이미 번역이 채워진 행은 건드리지 않는다(다시 번역하면 비용만 든다).
--   아래 3줄의 주석(--)을 풀고 RUN.
-- ════════════════════════════════════════════════════════════════

-- update public.restaurants set i18n_status_en='pending', i18n_status_jp='pending'
--  where coalesce(super_admin_only,false)=false
--    and coalesce(btrim(name),'') <> ''
--    and ((name_en is null or btrim(name_en)='') or (name_jp is null or btrim(name_jp)=''));

-- update public.ticket_products set i18n_status_en='pending', i18n_status_jp='pending'
--  where coalesce(btrim(ticket_desc),'') <> ''
--    and ((ticket_desc_en is null or btrim(ticket_desc_en)='') or (ticket_desc_jp is null or btrim(ticket_desc_jp)=''));

-- update public.venue_partners set i18n_status_en='pending', i18n_status_jp='pending'
--  where coalesce(btrim(custom_name),'') <> ''
--    and ((custom_name_en is null or btrim(custom_name_en)='') or (custom_name_jp is null or btrim(custom_name_jp)=''));
