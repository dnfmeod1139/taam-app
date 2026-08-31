-- ═══════════════════════════════════════════════════════════════
-- TAAM — 방문 기록 · 공개 대상을 만들기 전 실측 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 먼저 재나
--   ① tickets 에 방문 기록(visit_status)을 붙이고
--   ② ticket_products 에 공개 대상 조건을 붙일 참인데,
--   둘 다 기존 컬럼 타입을 알아야 캐스팅이 정해진다.
--
--   같은 날 sale_open_at(text 인데 timestamptz 로 가정)과
--   invite_codes.member_id(text 인데 uuid 로 가정)를 짐작으로 짜다
--   두 번 라이브를 깨뜨렸다. 그래서 짐작하지 않는다.
--
-- 무엇을 보나
--   ① tickets 전체 컬럼           — visit_status 를 붙일 자리, restaurant_id 타입
--   ② ticket_products 전체 컬럼   — min_tier 옆에 공개 대상을 둘지 판단
--   ③ reservation_requests 방문   — 이미 있는 것을 그대로 따라가려고
--   ④ tickets.status 실제 값      — 어떤 상태에서 방문 기록이 가능한지
--
-- 실행: Supabase SQL Editor. **읽기만 한다.**
--   ⚠ 확인 쿼리는 하나로 합쳤다 — SQL Editor 는 마지막 결과만 보여준다.
-- ═══════════════════════════════════════════════════════════════

select '① tickets 컬럼'                  as "구분",
       column_name                        as "값1",
       data_type                          as "값2",
       coalesce(column_default, '—')      as "값3"
  from information_schema.columns
 where table_schema = 'public' and table_name = 'tickets'

union all
select '② ticket_products 컬럼',
       column_name, data_type, coalesce(column_default, '—')
  from information_schema.columns
 where table_schema = 'public' and table_name = 'ticket_products'

union all
select '③ reservation_requests 방문',
       column_name, data_type, coalesce(column_default, '—')
  from information_schema.columns
 where table_schema = 'public' and table_name = 'reservation_requests'
   and column_name in ('visit_status', 'venue_id', 'user_id', 'reserve_date', 'status')

union all
select '④ tickets.status 실제 값',
       coalesce(status::text, '(null)'),
       count(*)::text || ' 건',
       '—'
  from public.tickets
 group by status

 order by 1, 2;
