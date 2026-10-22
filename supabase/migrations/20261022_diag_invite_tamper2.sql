-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 초대 값 변경 흔적 2: 회차 정가와 다른 7건 · 보낼 때 홀드 행 · 알림이 왜 없나 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 20261022_diag_invite_tamper.sql — 61건 모두 합계=(식사+대행+주류)×인원 · 결제=합계 · 확정 좌석=초대 값. 그런데 보낼 때의 알림(invite_sent · reservation_invite)이
--     0건이라 「보낼 때 값」과 직접 대조하지 못했다. 남은 의심은 1인 금액이 회차 정가와 다른 7건(회원이 금액을 낮췄다면 여기 보인다).
--   ① 7건: 초대 1인(식사·대행·주류) vs 회차 · 어느 쪽이 싼가 · 회차가 초대 뒤에 고쳐졌나(updated_at) · 같은 회차의 다른 초대들 값
--   ② 보낼 때 어드민 세션이 만든 INVH- 홀드 행(확정되지 않아 덮이지 않은 것)의 인원·금액 vs 초대 지금 값
--   ③ notifications 표 — 종류별 건수·가장 이른 날짜(알림이 지워지는지)
-- 무엇: SELECT 만. 이름·번호·uid 없음(초대 id 앞 8자리 · 값만). 결과는 Actions 로그.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_inv_tamper2()
returns table(sec text, info text)
language plpgsql as $$
declare r record;
begin
  -- ① 회차 정가와 1인 금액이 다른 초대
  for r in
    select left(i.id::text, 8) sid, i.status, i.pax, i.meal_fee, i.agency_fee, i.wine_min, i.total_amount,
           to_char(i.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') sent_at,
           tp.id::text tpid, (to_jsonb(tp)->>'meal_fee')::numeric tm, (to_jsonb(tp)->>'agency_fee')::numeric ta, (to_jsonb(tp)->>'wine_min')::numeric tw,
           to_char(nullif(to_jsonb(tp)->>'updated_at','')::timestamptz at time zone 'Asia/Seoul', 'MM-DD HH24:MI') tp_upd,
           nullif(to_jsonb(tp)->>'updated_at','')::timestamptz > i.created_at as tp_after,
           (select string_agg(distinct (coalesce(j.meal_fee,0) || '+' || coalesce(j.agency_fee,0) || '+' || coalesce(j.wine_min,0)), ' / ')
              from public.reservation_invites j where j.ticket_product_id = i.ticket_product_id and j.id <> i.id) other_invites
      from public.reservation_invites i join public.ticket_products tp on tp.id::text = i.ticket_product_id::text
     where coalesce(i.meal_fee,0) + coalesce(i.agency_fee,0) + coalesce(i.wine_min,0)
           <> coalesce((to_jsonb(tp)->>'meal_fee')::numeric,0) + coalesce((to_jsonb(tp)->>'agency_fee')::numeric,0) + coalesce((to_jsonb(tp)->>'wine_min')::numeric,0)
     order by i.created_at
  loop
    sec := '① ' || r.sid || ' · ' || r.status;
    info := '초대 1인 ' || coalesce(r.meal_fee,0) || '+' || coalesce(r.agency_fee,0) || '+' || coalesce(r.wine_min,0) || '=' || (coalesce(r.meal_fee,0)+coalesce(r.agency_fee,0)+coalesce(r.wine_min,0))
         || ' · 회차 ' || coalesce(r.tm,0) || '+' || coalesce(r.ta,0) || '+' || coalesce(r.tw,0) || '=' || (coalesce(r.tm,0)+coalesce(r.ta,0)+coalesce(r.tw,0))
         || ' · ' || case when (coalesce(r.meal_fee,0)+coalesce(r.agency_fee,0)+coalesce(r.wine_min,0)) < (coalesce(r.tm,0)+coalesce(r.ta,0)+coalesce(r.tw,0)) then '초대가 쌈' else '초대가 비쌈' end
         || ' · ' || r.pax || '명 합계 ' || r.total_amount || ' · 보낸 때 ' || r.sent_at
         || ' · 회차 마지막 수정 ' || coalesce(r.tp_upd,'?') || case when r.tp_after then '(초대 뒤 수정)' else '' end
         || ' · 같은 회차 다른 초대 1인: ' || coalesce(r.other_invites, '없음');
    return next;
  end loop;

  -- ② 보낼 때 홀드 행(INVH-) — 확정되지 않아 보낼 때 값이 그대로 남은 것
  for r in
    select left(i.id::text, 8) sid, i.status, i.pax, i.total_amount, t.party_size, t.price, t.status tst
      from public.reservation_invites i
      join public.tickets t on t.extra_data->>'inviteId' = i.id::text and t.purchase_id like 'INVH-%'
     order by i.created_at
  loop
    if r.party_size is distinct from r.pax or r.price is distinct from r.total_amount then
      sec := '② 보낼 때 홀드 ≠ 초대 지금 값'; info := r.sid || ' · ' || r.status || ' · 홀드(' || r.tst || ') 인원 ' || r.party_size || ' 금액 ' || r.price || ' → 지금 인원 ' || r.pax || ' 합계 ' || r.total_amount; return next;
    end if;
  end loop;
  for r in
    select count(*) n, count(*) filter (where t.party_size = i.pax and t.price = i.total_amount) same
      from public.reservation_invites i join public.tickets t on t.extra_data->>'inviteId' = i.id::text and t.purchase_id like 'INVH-%'
  loop
    sec := '② 보낼 때 홀드 행이 남은 초대'; info := r.n || '건 중 값이 같은 것 ' || r.same || '건'; return next;
  end loop;

  -- ③ 알림 표
  for r in
    select coalesce(type,'(없음)') t, count(*) n, to_char(min(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') first
      from public.notifications where type ilike '%invite%' or type in ('reservation_invite','invite_sent') group by 1 order by 2 desc
  loop
    sec := '③ 알림 종류 ' || r.t; info := r.n || '건 · 가장 이른 ' || r.first; return next;
  end loop;
  for r in select count(*) n, to_char(min(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') first from public.notifications loop
    sec := '③ 알림 전체'; info := r.n || '건 · 가장 이른 ' || coalesce(r.first,'-'); return next;
  end loop;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_inv_tamper2();
