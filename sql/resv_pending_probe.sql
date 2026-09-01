-- ═══════════════════════════════════════════════════════════════
-- TAAM — 대시보드의 「파트너 예약 요청 1」이 무엇인지 (2026-09-01)
-- ═══════════════════════════════════════════════════════════════
-- 왜 보나
--   대시보드가 세는 건 reservation_requests 에서 status='pending' 인 행이다.
--   화면에는 요청이 안 보이는데 숫자가 1이면, 대개 셋 중 하나다.
--     ① 지난 날짜의 옛 요청이 pending 인 채로 남아 있다
--     ② 테스트로 만든 행이 안 지워졌다
--     ③ 예약 관리 화면이 자기 기준(날짜·매장)으로 걸러서 안 보여 준다
--
--   ①②는 그 행을 거절/삭제하면 숫자가 사라진다. ③이면 화면 쪽을 고쳐야 한다.
--
-- 실행: Supabase SQL Editor. **읽기만 한다.**
--   ⚠ 확인 쿼리는 하나로 합쳤다 — SQL Editor 는 마지막 결과만 보여준다.
--
-- 읽는 법
--   ① 이 숫자가 대시보드의 「파트너 예약 요청」과 같아야 정상
--   ② pending 행이 하나씩 나온다. 날짜가 오늘보다 **과거**면 ①번 경우다
--   ③ 상태별 개수 — pending 말고 무엇이 얼마나 있는지
-- ═══════════════════════════════════════════════════════════════

select '① pending 개수'                    as "구분",
       count(*)::text                       as "값1",
       ''                                   as "값2",
       ''                                   as "값3"
  from public.reservation_requests
 where status = 'pending'

union all
select '② pending 한 건씩',
       coalesce(to_char(created_at, 'YYYY-MM-DD'), '?') || ' 접수',
       coalesce(nullif(reserve_date::text, ''), '(날짜 없음)'),
       left(coalesce(id::text, ''), 8) || '… / ' || coalesce(status, '?')
  from public.reservation_requests
 where status = 'pending'

union all
select '③ 상태별 개수',
       coalesce(status, '(null)'),
       count(*)::text || ' 건',
       ''
  from public.reservation_requests
 group by status

 order by 1, 2;
