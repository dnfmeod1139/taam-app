-- ═══════════════════════════════════════════════════════════════
-- TAAM — 취소된 예약은 방문으로 세지 않는다 (2026-09-01)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 잘못돼 있었나
--   taam_visit_count 의 주석은 「취소·노쇼는 세지 않는다」인데, 실제 쿼리는
--   visit_status='attended' 만 보고 **status 를 안 봤다.**
--
--   노쇼는 visit_status 가 'no_show' 라 자연히 빠진다. 문제는 취소다:
--     ① 매장이 방문을 찍는다        → visit_status='attended'
--     ② 나중에 취소·환불이 된다      → status='cancelled' (visit_status 는 그대로)
--     ③ 그 방문이 계속 등급에 잡힌다 ← 여기
--
--   방문 횟수는 「이 매장 단골에게만 보이는 티켓」의 재료다. 취소된 건이 섞이면
--   오지 않은 사람이 단골이 되고, 그 사람에게 티켓이 열린다.
--
-- 무엇을 바꾸나
--   세는 쿼리에 상태 조건을 더한다. **함수 하나만 바꾼다** — 표도, 데이터도
--   건드리지 않는다. 되돌리려면 이 파일의 옛 버전을 다시 올리면 된다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ 확인 쿼리는 맨 아래 하나로 합쳤다 (SQL Editor 는 마지막 결과만 보여준다).
--   읽는 법: ③ 에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_visit_count(
  p_user       uuid,
  p_restaurant text
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  -- 남의 방문 횟수를 아무나 못 본다.
  if not (
       p_user = auth.uid()
    or public.taam_can_mark_visit(p_restaurant)
  ) then
    raise exception '조회 권한이 없습니다' using errcode = '42501';
  end if;

  select
    -- 🆕 2026.09-01: 취소된 건은 세지 않는다.
    --   방문을 찍은 뒤에 취소·환불되면 status 만 바뀌고 visit_status 는 남는다.
    --   그대로 세면 오지 않은 사람이 단골이 된다.
    (select count(*) from public.tickets t
      where t.user_id = p_user
        and t.restaurant_id = p_restaurant
        and t.visit_status = 'attended'
        and coalesce(t.status, '') not in ('cancelled', 'canceled'))
  + (select count(*) from public.reservation_requests r
      where r.user_id = p_user
        and r.venue_id = p_restaurant
        and r.visit_status = 'attended'
        and coalesce(r.status, '') not in ('cancelled', 'canceled'))
  into v_n;

  return coalesce(v_n, 0);
end;
$$;

revoke all on function public.taam_visit_count(uuid, text) from public;
grant execute on function public.taam_visit_count(uuid, text) to authenticated;

comment on function public.taam_visit_count(uuid, text) is
  '이 회원이 이 매장에 몇 번 왔나 (티켓 + 예약요청). attended 만 세고, 취소·노쇼는 뺀다.';

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 함수에 상태 조건이 들어갔나' as "구분",
       case when prosrc like '%not in (''cancelled'', ''canceled'')%'
            then '✅ 들어감' else '❌ 없음' end                     as "값1",
       ''                                                            as "값2"
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_visit_count'

union all
-- 이 변경으로 실제 몇 건이 방문에서 빠지나 (0 이면 지금은 영향 없음 — 앞으로를 막는 것)
select '② 이번에 빠지는 방문',
       count(*)::text || ' 건',
       coalesce(string_agg(distinct coalesce(restaurant_name, '(매장 미상)'), ' · '), '—')
  from public.tickets
 where visit_status = 'attended'
   and coalesce(status, '') in ('cancelled', 'canceled')

union all
-- 남는 방문 (매장별)
select '③ 남는 방문 (매장별)',
       coalesce(restaurant_name, '(매장 미상)'),
       count(*)::text || ' 건'
  from public.tickets
 where visit_status = 'attended'
   and coalesce(status, '') not in ('cancelled', 'canceled')
 group by restaurant_name

 order by 1, 2;
