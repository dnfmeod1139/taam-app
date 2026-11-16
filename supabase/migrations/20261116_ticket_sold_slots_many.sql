-- ============================================================================
-- 20261116_ticket_sold_slots_many.sql — 여러 회차의 좌석 수를 한 번에 (회원 캘린더 「예약 가능」 탭 · 2026-11-16)
-- ============================================================================
-- 왜: 회원 캘린더에 「예약 가능」 탭(자리 남은 회차만 날짜순 · 2자리 이하면 「마지막 N자리」)을 만든다(2026-11-16 운영 결정).
--   지금 앱은 회차마다 taam_ticket_sold_slots 를 한 번씩 부른다 — 회차 수십 개를 그렇게 부르면 느리다.
-- 무엇: taam_ticket_sold_slots(회차 하나)와 같은 수를 여러 회차에 한 번에 — {"회차 id": {total, s1, s2, s4}}.
--   센 방식은 같다(취소 아닌 행의 인원 합 · 1·2·4인 행 수). 공개 범위도 같다(비로그인·회원 — 회차 하나짜리가 이미 그렇다).
--   덧붙인 것: 한 번에 400개까지 · 승인 대기·숨김·삭제 신청 회차는 슈퍼어드민에게만 센다(회원 화면에 안 나오는 회차의 판매 수를 주지 않는다).
--   읽기만 한다.
-- ============================================================================
create or replace function public.taam_ticket_sold_slots_many(p_ids text[])
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_object_agg(x.id, x.v), '{}'::jsonb)
    from (
      select tp.id::text as id,
             jsonb_build_object(
               'total', coalesce(sum(k.party_size) filter (where k.id is not null), 0)::int,
               's1', count(k.id) filter (where k.party_size = 1)::int,
               's2', count(k.id) filter (where k.party_size = 2)::int,
               's4', count(k.id) filter (where k.party_size = 4)::int) as v
        from public.ticket_products tp
        left join public.tickets k on k.ticket_product_id = tp.id::text and coalesce(k.status, '') <> 'cancelled'
       where tp.id::text = any(p_ids[1:400])
         and (lower(coalesce(tp.status, '')) not in ('pending', 'hidden', 'deleterequest') or public._taam_uid_is_super())
       group by tp.id
    ) x
$$;
revoke all on function public.taam_ticket_sold_slots_many(text[]) from public;
grant execute on function public.taam_ticket_sold_slots_many(text[]) to anon, authenticated, service_role;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① taam_ticket_sold_slots_many 있음 · 읽기 전용(stable)' as what,
       case when exists (select 1 from pg_proc where oid = to_regprocedure('public.taam_ticket_sold_slots_many(text[])') and provolatile = 's' and prosecdef)
            then '✅' else '❌' end as result
union all
select '② 회차 하나짜리와 같은 수(살아 있는 회차 하나로 대조)',
       case when not exists (select 1 from public.ticket_products) then '✅ 회차 없음'
            when coalesce((select (public.taam_ticket_sold_slots_many(array[tp.id::text]) -> tp.id::text) = public.taam_ticket_sold_slots(tp.id::text)::jsonb
                    from public.ticket_products tp
                   where lower(coalesce(tp.status, '')) not in ('pending', 'hidden', 'deleterequest')
                   order by tp.updated_at desc nulls last limit 1), true) then '✅' else '❌ 수가 다르다' end
union all
select '③ 의존 함수 _taam_uid_is_super',
       case when to_regprocedure('public._taam_uid_is_super()') is not null then '✅' else '❌' end;
