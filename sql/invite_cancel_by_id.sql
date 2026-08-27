-- ═══════════════════════════════════════════════════════════════
-- 초대 취소 (호스트/슈퍼어드민용) — 앱에는 없는 기능
-- ═══════════════════════════════════════════════════════════════
-- 앱의 「초대 취소」는 초대받은 회원만 누를 수 있다(cancelMyInvite 가
-- invitee_user_id 를 확인한다). 보낸 쪽에서 되돌릴 방법이 없어서,
-- 테스트로 보낸 초대를 정리하려면 여기서 한다.
--
-- 하는 일
--   ① reservation_invites.status = 'cancelled' + cancelled_at
--   ② 그 초대가 잡고 있던 좌석 홀드(INVH-)를 'cancelled' 로 → 잔여석 즉시 복구
--
-- ⚠ 이미 결제된(paid) 초대는 건드리지 않는다. 돈이 오간 건은 환불 흐름을 타야 한다.
-- ═══════════════════════════════════════════════════════════════


-- ── ① 먼저 확인 — 취소할 초대가 맞는지 눈으로 본다 ──
-- 초대ID 앞 8자리를 여기에 넣는다 (진단 쿼리의 「초대ID앞8」 값).
with target as (
  select unnest(array[
    '111699c6'      -- ← 취소할 초대. 여러 건이면 콤마로 나열: '111699c6', '457aa780'
  ]) as pfx
)
select
  left(inv.id::text, 8)   as "초대ID앞8",
  inv.created_at          as "보낸시각",
  inv.status              as "상태",
  inv.restaurant_name     as "매장",
  inv.visit_date          as "방문일",
  inv.visit_time          as "시간",
  inv.pax                 as "인원",
  inv.total_amount        as "금액",
  coalesce(inv.ticket_product_id::text, '(연결없음)') as "연결티켓",
  (select coalesce(sum(t.party_size),0) from public.tickets t
    where coalesce(t.status,'') = 'hold'
      and ( coalesce(t.extra_data->>'inviteId','') = inv.id::text
         or t.purchase_id like 'INVH-' || left(inv.id::text,8) || '-%' )) as "잡고있는좌석"
from public.reservation_invites inv
join target on left(inv.id::text, 8) = target.pfx;


-- ── ② 취소 실행 — ① 결과를 확인한 뒤에 ──
-- ⚠ 위 target 목록과 같은 값을 쓸 것.
do $$
declare
  v_pfx  text[] := array['111699c6'];   -- ← ① 과 동일하게
  r      record;
  v_rel  int;
  v_n    int := 0;
begin
  for r in
    select inv.* from public.reservation_invites inv
     where left(inv.id::text, 8) = any(v_pfx)
  loop
    if r.status = 'paid' then
      raise notice '건너뜀 % — 이미 결제됨(paid). 환불 흐름으로 처리할 것', left(r.id::text,8);
      continue;
    end if;
    if r.status = 'cancelled' then
      raise notice '건너뜀 % — 이미 취소됨', left(r.id::text,8);
      continue;
    end if;

    update public.reservation_invites
       set status = 'cancelled', cancelled_at = now()
     where id = r.id;

    -- 좌석 홀드 해제 → 본 티켓 잔여석 즉시 복구
    update public.tickets
       set status = 'cancelled'
     where coalesce(status,'') = 'hold'
       and ( coalesce(extra_data->>'inviteId','') = r.id::text
          or purchase_id like 'INVH-' || left(r.id::text,8) || '-%' );
    get diagnostics v_rel = row_count;

    raise notice '취소 % (%· %· %인) — 홀드 %행 해제',
      left(r.id::text,8), r.restaurant_name, r.visit_date, r.pax, v_rel;
    v_n := v_n + 1;
  end loop;
  raise notice '───────── 취소 %건 ─────────', v_n;
end $$;


-- ── ③ 확인 — 해당 티켓의 잔여석이 돌아왔는지 ──
select
  tp.rest_name   as "매장",
  tp.date        as "날짜",
  tp.total_pax   as "정원",
  (select coalesce(sum(x.party_size),0) from public.tickets x
    where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') as "점유",
  tp.status      as "상태"
from public.ticket_products tp
where coalesce(tp.total_pax,0) > 0
  and length(tp.date) = 10
  and to_date(tp.date,'YYYY.MM.DD') >= current_date
order by tp.date;
