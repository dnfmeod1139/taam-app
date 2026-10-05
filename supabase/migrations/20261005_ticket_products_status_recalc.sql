-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — ticket_products.status 는 저장할 때도 좌석으로 다시 센다 · 2026-10-05
--
-- 사고: 시마즈 3/19 를 비공개로 올려 초대로 8/8 을 채운 뒤(soldout) 어드민이
--   「즉시 공개」로 재편집해 저장했다. 앱의 저장 경로(uploadTicket → saveTicketProductToSupabase)는
--   status 를 언제나 getUploadStatus()='active' 로 보내므로 soldout 이 active 로 덮였다.
--   매진 동기화(trg_sync_ticket_soldout)는 **tickets 가 바뀔 때만** 돌기 때문에 아무도
--   되돌리지 않았다. 상세 팝업은 taam_ticket_sold_slots 로 좌석을 직접 세서 「매진」이 뜨는데,
--   캘린더·목록은 status 만 보므로 색이 살아 있는 「판매중」으로 보였다.
--
-- 고침: ticket_products 에 BEFORE INSERT/UPDATE OF status, total_pax 트리거.
--   · 점유(취소 제외 party_size 합) ≥ 정원 인데 status='active' 로 쓰려 하면 → 'soldout' + auto_soldout=true
--   · soldout(자동) 인 행의 정원을 늘려 자리가 생기면 → 'active'  (어드민이 정원을 키운 경우)
--   · 그 밖(수동 잠금 auto_soldout=false · pending · 정원 미설정)은 건드리지 않는다
--   ⚠ 되돌림(soldout→active)은 「정원을 늘렸을 때」만이다. 저장할 때마다 자리가 있다고 풀면
--     어드민이 손으로 잠근 매진(앱은 status 를 먼저 쓰고 auto_soldout=false 를 뒤에 쓴다)을 매번 풀어 버린다.
--   취소표 알림(trg_ticket_restock)은 soldout→active 전이만 보므로, BEFORE 에서 다시 soldout 으로
--   돌려 놓으면 전이 자체가 없어 가짜 알림도 없다.
-- 마지막에 지금 어긋나 있는 행(점유 ≥ 정원인데 active)을 같은 규칙으로 한 번 맞춘다.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.taam_tp_status_recalc()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_occ int;
begin
  if coalesce(new.total_pax, 0) <= 0 then return new; end if;   -- 정원 없는 티켓은 매진 개념 없음

  select coalesce(sum(party_size), 0) into v_occ
    from public.tickets
   where ticket_product_id = new.id
     and coalesce(status, '') <> 'cancelled';

  if v_occ >= new.total_pax then
    -- 꽉 찼는데 판매중으로 쓰려 한다 → 매진으로 되돌린다 (재편집·연장·토글 모두)
    if coalesce(new.status, '') = 'active' then
      new.status := 'soldout';
      new.auto_soldout := true;
    end if;
  elsif tg_op = 'UPDATE'
        and coalesce(new.status, '') = 'soldout'
        and coalesce(new.auto_soldout, true)
        and coalesce(old.total_pax, 0) < new.total_pax then
    -- 자동 매진이었는데 정원을 늘려 자리가 생겼다 → 판매중
    new.status := 'active';
  end if;
  return new;
end $$;

drop trigger if exists trg_taam_tp_status_recalc on public.ticket_products;
create trigger trg_taam_tp_status_recalc
  before insert or update of status, total_pax on public.ticket_products
  for each row execute function public.taam_tp_status_recalc();

-- 취소표 알림 트리거는 「UPDATE OF status」라 SET 에 status 가 없는 갱신(정원만 늘림)에서는 돌지 않는다 —
-- BEFORE 가 status 를 active 로 바꿔도 마찬가지(UPDATE OF 는 SET 목록으로 판정). total_pax 를 더한다.
-- WHEN(soldout→active)은 그대로이므로 다른 갱신에서 더 울리지 않는다.
do $$
begin
  if to_regproc('public.taam_ticket_restock_on_status') is not null then
    execute 'drop trigger if exists trg_ticket_restock on public.ticket_products';
    execute $t$create constraint trigger trg_ticket_restock
      after update of status, total_pax on public.ticket_products
      deferrable initially deferred
      for each row
      when (old.status = 'soldout' and new.status = 'active')
      execute function public.taam_ticket_restock_on_status()$t$;
  end if;
end $$;

-- ── 지금 어긋난 행 맞추기 — 점유 ≥ 정원인데 active (트리거와 같은 규칙) ──
drop table if exists _tp_fixed;
create temp table _tp_fixed as
  with fixed as (
    update public.ticket_products tp
       set status = 'soldout', auto_soldout = true
     where coalesce(tp.total_pax, 0) > 0
       and coalesce(tp.status, '') = 'active'
       and (select coalesce(sum(x.party_size), 0) from public.tickets x
             where x.ticket_product_id = tp.id and coalesce(x.status, '') <> 'cancelled') >= tp.total_pax
    returning tp.id, tp.rest_name, tp.date, tp.time
  )
  select * from fixed;

-- ── 확인 (한 표) — ❌ 가 없어야 정상 ──
select '① 저장 시 재계산 트리거' as what,
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_tp_status_recalc') then '✅' else '❌' end as result
union all
select '①-2 취소표 알림 트리거가 total_pax 도 본다',
       case when to_regproc('public.taam_ticket_restock_on_status') is null then '⚠ 취소표 마이그레이션 없음'
            when exists (select 1 from pg_trigger t where t.tgname = 'trg_ticket_restock'
                          and pg_get_triggerdef(t.oid) ilike '%update of status, total_pax%') then '✅' else '❌' end
union all
select '② 이번에 매진으로 맞춘 행',
       '✅ ' || (select count(*) from _tp_fixed) || '건'
       || coalesce(' — ' || (select string_agg(rest_name || ' ' || coalesce(date,'') || ' ' || coalesce(time,''), ' · ') from _tp_fixed), '')
union all
select '③ 아직 어긋난 행(점유≥정원인데 active)',
       case when not exists (
         select 1 from public.ticket_products tp
          where coalesce(tp.total_pax,0) > 0 and coalesce(tp.status,'') = 'active'
            and (select coalesce(sum(x.party_size),0) from public.tickets x
                  where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') >= tp.total_pax)
       then '✅ 0건' else '❌ 있음' end;

drop table if exists _tp_fixed;
