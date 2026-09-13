-- ═══════════════════════════════════════════════════════════════
-- TAAM — 큐레이션 표 RLS 기록 + restaurants 「전원 삭제」 정책 제거 (2026-09-14)
-- ═══════════════════════════════════════════════════════════════
-- 라이브 실측(pg_policies, 2026-09-14):
--   chefs           : chefs_read[SELECT] true · chefs_superadmin_all[ALL] is_superadmin()
--   ticket_products : ticket_products_read[SELECT] true · ticket_products_superadmin_all[ALL] is_superadmin()
--                     · partner_insert/update/delete — 자기 매장(profiles.admin_rest_id) 의 status='pending' 회차만
--   restaurants     : restaurants_read[SELECT] true · restaurants_superadmin_all[ALL] is_superadmin()
--                     · ⚠ "Allow delete for all"[DELETE] true  ← 로그인한 누구나 어떤 매장이든 삭제 가능
--   deposit_transactions : deposit_tx_insert_own · deposit_tx_select_own (본인 또는 슈퍼어드민)
--                     · 회원 직접 INSERT 는 원장 서버화 마무리 뒤에 닫는다 (앱이 아직 직접 쓰는 곳이 있다)
--
-- 이 파일이 하는 일: restaurants 의 전원 삭제 정책만 지운다. 슈퍼어드민은 superadmin_all 로 이미 삭제할 수 있다.
-- 실행: Supabase SQL Editor. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════
drop policy if exists "Allow delete for all" on public.restaurants;

select tablename as "표", policyname as "정책", cmd as "명령", coalesce(qual, with_check) as "조건"
  from pg_policies
 where schemaname = 'public' and tablename = 'restaurants'
 order by 2;
