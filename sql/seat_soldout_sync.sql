-- ═══════════════════════════════════════════════════════════════
-- TAAM — 좌석이 다 차면 즉시 매진 표시 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent)
--
-- 왜 필요한가
--   지금은 ticket_products.status='soldout' 이 "다음 구매자가 거부당할 때"
--   비로소 켜진다. 그래서 마지막 좌석이 팔려도 목록/카드는 계속 판매중으로 보인다.
--   (좌석 차감·오버셀 차단은 이미 정상 — enforce_ticket_capacity 트리거가 막는다.
--    문제는 화면 표시가 늦는 것뿐이다.)
--
--   → tickets 가 바뀔 때마다 잔여석을 다시 세어, 다 차면 soldout, 자리가 나면
--     다시 판매중(active)으로 자동 전환한다. 결제 수단(예치금·카드·초대) 무관하게,
--     좌석이 잡히는(hold) 순간·풀리는 순간 즉시 반영된다.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.sync_ticket_soldout()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_pid  text;
  v_cap  int;
  v_sold int;
  v_status text;
begin
  -- INSERT/UPDATE/DELETE 어느 쪽이든 대상 티켓 id 를 잡는다
  v_pid := coalesce(new.ticket_product_id, old.ticket_product_id);
  if v_pid is null then return coalesce(new, old); end if;

  select total_pax, status into v_cap, v_status
    from public.ticket_products where id = v_pid;
  if v_cap is null or v_cap <= 0 then
    return coalesce(new, old);   -- 정원 미설정 티켓은 매진 개념 없음
  end if;

  -- 취소된 행 제외한 전 회원 합산 (hold·active 모두 좌석을 차지한다)
  select coalesce(sum(party_size), 0) into v_sold
    from public.tickets
   where ticket_product_id = v_pid
     and coalesce(status, '') <> 'cancelled';

  if v_sold >= v_cap and coalesce(v_status,'') <> 'soldout' then
    update public.ticket_products set status = 'soldout' where id = v_pid;
  elsif v_sold < v_cap and coalesce(v_status,'') = 'soldout' then
    -- 자리가 다시 났다 → 판매중으로 되돌린다
    update public.ticket_products set status = 'active' where id = v_pid;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_ticket_soldout on public.tickets;
create trigger trg_sync_ticket_soldout
  after insert or update or delete on public.tickets
  for each row execute function public.sync_ticket_soldout();

-- ── 기존 데이터 일괄 보정 ──
--   이미 팔려서 꽉 찼는데 아직 soldout 이 아닌 티켓을 지금 시점 기준으로 맞춘다.
update public.ticket_products tp
   set status = 'soldout'
 where coalesce(tp.total_pax, 0) > 0
   and coalesce(tp.status, '') <> 'soldout'
   and (select coalesce(sum(t.party_size), 0)
          from public.tickets t
         where t.ticket_product_id = tp.id
           and coalesce(t.status, '') <> 'cancelled') >= tp.total_pax;

-- ── 확인 ──
select id, rest_name, total_pax, status,
       (select coalesce(sum(t.party_size),0) from public.tickets t
         where t.ticket_product_id = tp.id and coalesce(t.status,'') <> 'cancelled') as "판매/홀드"
from public.ticket_products tp
where coalesce(total_pax,0) > 0
order by updated_at desc
limit 20;

do $$ begin raise notice '✅ 좌석 매진 자동 동기화 트리거 적용 완료'; end $$;
