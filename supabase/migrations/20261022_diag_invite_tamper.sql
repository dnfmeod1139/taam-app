-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 초대받은 회원이 초대 값을 고친 흔적이 있나 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 20261022_invite_payment_guard.sql 전까지 받는 회원은 자기 초대 행의 모든 칸(금액·인원·회차·날짜…)을 바꿀 수 있었다. 변경 이력 칸은 없다.
--     그래서 「보낼 때 어드민 세션이 남긴 기록」·「결제 때 남은 기록」과 지금 값을 대조한다.
--       ① 슈퍼어드민 알림 invite_sent(어드민 세션이 씀 · 회원은 못 고친다) payload {amount, pax, invitee_id, ticket_product_id}
--       ② 받는 회원 알림 reservation_invite payload {total_amount, pax} (보낼 때 어드민 세션이 씀)
--       ③ 초대 행 안의 일치: 합계 = (식사+대행+주류) × 인원 (보낼 때 앱이 이 식으로 만든다)
--       ④ 결제 원장(이 초대의 ticket_purchase 합 · metadata 의 인원·날짜·시간)
--       ⑤ 확정 좌석(INV-)·아직 홀드(INVH-)의 인원·금액·날짜·시간
--       ⑥ 연결 회차 정가와의 차이(정보 — 어드민이 보낼 때 바꿀 수 있다)
--     시간은 어드민이 캘린더에서 바꿀 수 있어 「시간만 다름」은 따로 센다.
-- 무엇: SELECT 만. 이름·번호·uid 를 찍지 않는다(초대 id 앞 8자리 · 상태 · 값만). 결과는 Actions 로그.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_inv_tamper()
returns table(sec text, info text)
language plpgsql as $$
declare r record; n_bad int := 0;
begin
  drop table if exists _it;
  create temp table _it as
  select i.id, left(i.id::text, 8) as sid, coalesce(i.status, '?') as st, i.pax, i.meal_fee, i.agency_fee, i.wine_min, i.total_amount,
         i.visit_date, i.visit_time, i.invitee_user_id, coalesce(i.ticket_product_id, '') as tpid, i.created_at, i.paid_at,
         -- ① 슈퍼어드민 알림 (여러 슈퍼어드민에게 같은 값 — 가장 이른 한 줄)
         (select n.payload from public.notifications n where n.type = 'invite_sent' and n.payload->>'invite_id' = i.id::text order by n.created_at limit 1) as sent,
         -- ② 받는 회원 알림
         (select n.payload from public.notifications n where n.type = 'reservation_invite' and n.payload->>'invite_id' = i.id::text order by n.created_at limit 1) as recv,
         -- ④ 결제 원장
         (select -sum(d.amount) from public.deposit_transactions d
           where d.user_id = i.invitee_user_id and d.change_type = 'ticket_purchase' and d.amount < 0
             and (d.metadata->>'invite_id' = i.id::text or coalesce(d.metadata->>'purchase_id','') like 'INV-' || left(i.id::text, 8) || '-%')) as led_paid,
         (select d.metadata from public.deposit_transactions d
           where d.user_id = i.invitee_user_id and d.change_type = 'ticket_purchase' and d.amount < 0 and d.metadata->>'invite_id' = i.id::text
           order by d.created_at limit 1) as led_meta,
         -- ⑤ 좌석 행
         (select to_jsonb(t) from public.tickets t where t.extra_data->>'inviteId' = i.id::text and t.purchase_id like 'INV-%' and coalesce(t.status,'') <> 'cancelled' order by t.created_at desc limit 1) as tk_inv,
         (select to_jsonb(t) from public.tickets t where t.extra_data->>'inviteId' = i.id::text and t.purchase_id like 'INVH-%' and coalesce(t.status,'') = 'hold' order by t.created_at desc limit 1) as tk_hold,
         -- ⑥ 연결 회차
         (select to_jsonb(tp) from public.ticket_products tp where tp.id::text = i.ticket_product_id::text) as tp
    from public.reservation_invites i;

  for r in select st, count(*) n from _it group by 1 order by 1 loop
    sec := '0 초대 상태 ' || r.st; info := r.n || '건'; return next;
  end loop;

  -- ③ 행 안의 일치
  for r in select sid, st, pax, meal_fee, agency_fee, wine_min, total_amount from _it
            where coalesce(total_amount,0) <> (coalesce(meal_fee,0) + coalesce(agency_fee,0) + coalesce(wine_min,0)) * coalesce(pax,0) order by created_at loop
    n_bad := n_bad + 1;
    sec := '③ 합계 ≠ (식사+대행+주류)×인원'; info := r.sid || ' · ' || r.st || ' · 합계 ' || coalesce(r.total_amount,0) || ' vs (' || coalesce(r.meal_fee,0) || '+' || coalesce(r.agency_fee,0) || '+' || coalesce(r.wine_min,0) || ')×' || coalesce(r.pax,0); return next;
  end loop;

  -- ① 슈퍼어드민 발송 알림과 대조
  sec := '① 발송 알림(invite_sent) 있는 초대'; info := (select count(*) from _it where sent is not null) || '건 / ' || (select count(*) from _it) || '건'; return next;
  for r in select sid, st, sent, total_amount, pax, invitee_user_id, tpid from _it
            where sent is not null and (
                  (sent ? 'amount' and (sent->>'amount')::numeric is distinct from total_amount::numeric)
               or (sent ? 'pax' and (sent->>'pax')::numeric is distinct from pax::numeric)
               or (sent ? 'invitee_id' and sent->>'invitee_id' is distinct from invitee_user_id::text)
               or (coalesce(sent->>'ticket_product_id','') <> '' and sent->>'ticket_product_id' <> tpid)) loop
    n_bad := n_bad + 1;
    sec := '① 발송 값 ≠ 지금 값'; info := r.sid || ' · ' || r.st
      || case when (r.sent->>'amount')::numeric is distinct from r.total_amount::numeric then ' · 합계 ' || (r.sent->>'amount') || ' → ' || coalesce(r.total_amount::text,'-') else '' end
      || case when (r.sent->>'pax')::numeric is distinct from r.pax::numeric then ' · 인원 ' || (r.sent->>'pax') || ' → ' || coalesce(r.pax::text,'-') else '' end
      || case when r.sent ? 'invitee_id' and r.sent->>'invitee_id' is distinct from r.invitee_user_id::text then ' · 받는 회원이 바뀜' else '' end
      || case when coalesce(r.sent->>'ticket_product_id','') <> '' and r.sent->>'ticket_product_id' <> r.tpid then ' · 연결 회차가 바뀜' else '' end;
    return next;
  end loop;

  -- ② 받는 회원 알림과 대조
  sec := '② 회원 알림(reservation_invite) 있는 초대'; info := (select count(*) from _it where recv is not null) || '건'; return next;
  for r in select sid, st, recv, total_amount, pax from _it
            where recv is not null and ((recv ? 'total_amount' and (recv->>'total_amount')::numeric is distinct from total_amount::numeric)
                                     or (recv ? 'pax' and (recv->>'pax')::numeric is distinct from pax::numeric)) loop
    n_bad := n_bad + 1;
    sec := '② 회원 알림 값 ≠ 지금 값'; info := r.sid || ' · ' || r.st || ' · 합계 ' || coalesce(r.recv->>'total_amount','-') || ' → ' || coalesce(r.total_amount::text,'-')
      || ' · 인원 ' || coalesce(r.recv->>'pax','-') || ' → ' || coalesce(r.pax::text,'-'); return next;
  end loop;

  -- ④ 결제 원장과 대조 (paid · 결제가 있는 초대)
  for r in select sid, st, led_paid, total_amount, pax, visit_date, visit_time, led_meta from _it
            where led_paid is not null and (led_paid <> coalesce(total_amount,0)
               or (led_meta ? 'pax' and (led_meta->>'pax')::numeric is distinct from pax::numeric)
               or (coalesce(led_meta->>'visit_date','') <> '' and led_meta->>'visit_date' is distinct from visit_date)) loop
    n_bad := n_bad + 1;
    sec := '④ 결제 기록 ≠ 지금 값'; info := r.sid || ' · ' || r.st || ' · 원장 결제 ' || r.led_paid || ' / 합계 ' || coalesce(r.total_amount::text,'-')
      || ' · 결제 때 인원 ' || coalesce(r.led_meta->>'pax','-') || ' / 지금 ' || coalesce(r.pax::text,'-')
      || ' · 결제 때 날짜 ' || coalesce(r.led_meta->>'visit_date','-') || ' / 지금 ' || coalesce(r.visit_date,'-'); return next;
  end loop;
  for r in select sid, st, led_meta, visit_time from _it
            where led_meta is not null and coalesce(led_meta->>'visit_time','') <> '' and led_meta->>'visit_time' is distinct from visit_time loop
    sec := '④ 시간만 다름 (어드민이 캘린더에서 바꿀 수 있다)'; info := r.sid || ' · ' || r.st || ' · 결제 때 ' || (r.led_meta->>'visit_time') || ' → 지금 ' || coalesce(r.visit_time,'-'); return next;
  end loop;

  -- ⑤ 좌석 행과 대조
  for r in select sid, st, tk_inv, tk_hold, pax, total_amount, visit_date from _it
            where (tk_inv is not null and ((tk_inv->>'party_size')::numeric is distinct from pax::numeric or (tk_inv->>'price')::numeric is distinct from total_amount::numeric))
               or (tk_hold is not null and ((tk_hold->>'party_size')::numeric is distinct from pax::numeric or (tk_hold->>'price')::numeric is distinct from total_amount::numeric)) loop
    n_bad := n_bad + 1;
    sec := '⑤ 좌석 행 ≠ 지금 값'; info := r.sid || ' · ' || r.st
      || case when r.tk_inv is not null then ' · 확정 좌석 인원 ' || (r.tk_inv->>'party_size') || ' 금액 ' || (r.tk_inv->>'price') else '' end
      || case when r.tk_hold is not null then ' · 홀드(보낼 때) 인원 ' || (r.tk_hold->>'party_size') || ' 금액 ' || (r.tk_hold->>'price') else '' end
      || ' · 지금 인원 ' || coalesce(r.pax::text,'-') || ' 합계 ' || coalesce(r.total_amount::text,'-'); return next;
  end loop;

  -- ⑥ 연결 회차 정가와 차이 (정보 — 보낼 때 어드민이 바꿀 수 있다)
  for r in select count(*) filter (where tp is not null) n_link,
                  count(*) filter (where tp is not null and coalesce(meal_fee,0) + coalesce(agency_fee,0) + coalesce(wine_min,0)
                                    <> coalesce((tp->>'meal_fee')::numeric,0) + coalesce((tp->>'agency_fee')::numeric,0) + coalesce((tp->>'wine_min')::numeric,0)) n_diff
             from _it loop
    sec := '⑥ 회차 연결 초대 · 1인 금액이 회차 정가와 다름 (정보)'; info := r.n_link || '건 중 ' || r.n_diff || '건'; return next;
  end loop;

  sec := '⑨ 결론'; info := case when n_bad = 0 then '의심 0건 — 회원이 값을 바꾼 흔적이 없다(남은 기록 기준)' else '의심 ' || n_bad || '줄 — 위 목록 확인' end; return next;
  drop table if exists _it;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_inv_tamper();
