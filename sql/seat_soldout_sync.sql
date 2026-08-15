-- ═══════════════════════════════════════════════════════════════
-- TAAM — 좌석이 다 차면 즉시 매진 표시 (2026-08) · v2 (flex 안전)
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
--   → 이 버전은 flex 티켓을 건드리지 않는다.
--     · 고정 구성(비 flex): 다 차면 soldout, 자리 나면 active 자동 전환
--     · flex: 아무것도 안 함 (좌석 엔진·구매 로직·홀드 해제가 관리)
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

  -- flex 티켓은 좌석 엔진이 매진을 판단한다 — 여기서 손대지 않는다.
  v_isflex := (v_slots ? 'mode' and v_slots->>'mode' = 'flex');
  if v_isflex then
    return coalesce(new, old);
  end if;

  -- 취소된 행 제외 전 회원 합산 (hold·active 모두 좌석을 차지)
  select coalesce(sum(party_size), 0) into v_sold
    from public.tickets
   where ticket_product_id = v_pid
     and coalesce(status, '') <> 'cancelled';

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

-- ── 기존 데이터 보정 (비 flex 만) ──
--   ① 다 찼는데 soldout 아닌 것 → soldout
update public.ticket_products tp
   set status = 'soldout'
 where coalesce(tp.total_pax, 0) > 0
   and coalesce(tp.status, '') <> 'soldout'
   and not (to_jsonb(tp.slots) ? 'mode' and to_jsonb(tp.slots)->>'mode' = 'flex')
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

do $$ begin raise notice '✅ 좌석 매진 자동 동기화 v2 (flex 안전) 적용 완료'; end $$;
