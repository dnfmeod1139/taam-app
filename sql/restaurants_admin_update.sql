-- ═══════════════════════════════════════════════════════════════
-- TAAM — 어드민이 본인 매장(restaurants) 정보 수정 허용 (선택)
-- ⚠ "나의 레스토랑" 저장 시 'permission/RLS' 에러가 날 때만 실행하세요.
--    (restaurants 에 RLS 가 켜져 있고 슈퍼어드민만 쓰기 가능한 경우 필요)
-- 실행: Supabase SQL Editor (idempotent). admin_grants.sql 실행 후 사용.
-- ═══════════════════════════════════════════════════════════════
-- admin_grants.rest_id = 레스토랑 id(텍스트) 이므로 is_ticket_admin_of(id::text) 로 판정.

drop policy if exists "restaurants admin update own" on public.restaurants;
create policy "restaurants admin update own" on public.restaurants
  for update to authenticated
  using (
    public.is_super_admin(auth.uid())
    or public.is_ticket_admin_of(id::text)
    or public.is_restaurant_admin_of(id::text)
  )
  with check (
    public.is_super_admin(auth.uid())
    or public.is_ticket_admin_of(id::text)
    or public.is_restaurant_admin_of(id::text)
  );
