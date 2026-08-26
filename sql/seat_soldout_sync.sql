-- ═══════════════════════════════════════════════════════════════
-- TAAM — 좌석이 다 차면 즉시 매진 표시 (2026-08) · v3 (flex 꽉참 포함)
-- Supabase SQL Editor 에서 실행 (idempotent — 함수 교체)
--
-- 왜 필요한가
--   ticket_products.status='soldout' 이 "다음 구매자가 거부당할 때"만 켜져서,
--   마지막 좌석이 팔려도 목록/카드는 계속 판매중으로 보였다.
--   (좌석 차감·오버셀 차단은 이미 정상 — enforce_ticket_capacity 가 막는다.)
--
-- ⚠ v1 의 문제
--   자유 구성(flex) 티켓은 raw 합계가 정원 미만이어도 "남은 좌석을 못 채우면"
--   좌석 엔진이 매진 처리한다 (5/7 이지만 매진 등). v1 의 되돌리기가 이것을
--   raw 합계만 보고 판매중으로 되살려 엔진 판단을 깼다.
--
-- ⚠ v2 의 문제 (2026-08-26 발견)
--   그걸 피하려고 v2 는 flex 를 통째로 건드리지 않았다. 그 결과 7/7 로 꽉 찬
--   flex 티켓이 status='active' 로 남았고, 캘린더 타일이 컬러로 살아 있는데
--   눌러 들어가면 "매진" 이 뜨는 상태가 됐다.
--
--   → v3 은 방향을 나눈다. 되돌리기만 위험했지, 올리는 건 안전하다.
--     · 고정 구성(비 flex): 다 차면 soldout, 자리 나면 active (양방향)
--     · flex: 꽉 찼을 때만 soldout 으로 올린다. 되돌리기는 하지 않는다
--             (7/7 은 어떤 기준으로도 매진이다. 5/7 매진은 엔진 판단이라 존중한다)
-- ═══════════════════════════════════════════════════════════════

create or replace function public.sync_ticket_soldout()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_pid    text;
  v_cap    int;
  v_sold   int;
  v_status text;
  v_slots  jsonb;
  v_isflex boolean;
begin
  v_pid := coalesce(new.ticket_product_id, old.ticket_product_id);
  if v_pid is null then return coalesce(new, old); end if;

  select total_pax, status, to_jsonb(slots)
    into v_cap, v_status, v_slots
    from public.ticket_products where id = v_pid;
  if v_cap is null or v_cap <= 0 then
    return coalesce(new, old);   -- 정원 미설정 티켓은 매진 개념 없음
  end if;

  -- 취소된 행 제외 전 회원 합산 (hold·active 모두 좌석을 차지)
  select coalesce(sum(party_size), 0) into v_sold
    from public.tickets
   where ticket_product_id = v_pid
     and coalesce(status, '') <> 'cancelled';

  v_isflex := (v_slots ? 'mode' and v_slots->>'mode' = 'flex');

  -- flex: 올리는 방향만 한다. 되돌리기는 좌석 엔진 몫이다 (v1 사고의 원인).
  if v_isflex then
    if v_sold >= v_cap and coalesce(v_status,'') <> 'soldout' then
      update public.ticket_products set status = 'soldout' where id = v_pid;
    end if;
    return coalesce(new, old);
  end if;

  -- 고정 구성: 양방향
  if v_sold >= v_cap and coalesce(v_status,'') <> 'soldout' then
    update public.ticket_products set status = 'soldout' where id = v_pid;
  elsif v_sold < v_cap and coalesce(v_status,'') = 'soldout' then
    update public.ticket_products set status = 'active' where id = v_pid;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_ticket_soldout on public.tickets;
create trigger trg_sync_ticket_soldout
  after insert or update or delete on public.tickets
  for each row execute function public.sync_ticket_soldout();

-- ── 기존 데이터 보정 ──
--   ① 다 찼는데 soldout 아닌 것 → soldout  (flex 포함 — 꽉 찬 건 어느 쪽이든 매진)
update public.ticket_products tp
   set status = 'soldout'
 where coalesce(tp.total_pax, 0) > 0
   and coalesce(tp.status, '') <> 'soldout'
   and (select coalesce(sum(t.party_size), 0) from public.tickets t
         where t.ticket_product_id = tp.id
           and coalesce(t.status, '') <> 'cancelled') >= tp.total_pax;

--   ② 비 flex 인데 자리가 남아있는데 soldout 인 것 → active 로 되돌림
--      (테스트/수동 토글로 잘못 잠긴 티켓 복구. flex 는 손대지 않는다.)
update public.ticket_products tp
   set status = 'active'
 where coalesce(tp.total_pax, 0) > 0
   and coalesce(tp.status, '') = 'soldout'
   and not (to_jsonb(tp.slots) ? 'mode' and to_jsonb(tp.slots)->>'mode' = 'flex')
   and (select coalesce(sum(t.party_size), 0) from public.tickets t
         where t.ticket_product_id = tp.id
           and coalesce(t.status, '') <> 'cancelled') < tp.total_pax;

-- ── 확인 ──
select id, rest_name, total_pax, status,
       (to_jsonb(slots)->>'mode') as mode,
       (select coalesce(sum(t.party_size),0) from public.tickets t
         where t.ticket_product_id = tp.id and coalesce(t.status,'') <> 'cancelled') as "판매/홀드"
from public.ticket_products tp
where coalesce(total_pax,0) > 0
order by updated_at desc
limit 25;

do $$ begin raise notice '✅ 좌석 매진 자동 동기화 v3 (flex 꽉참 포함) 적용 완료'; end $$;
