-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) 2 — 결제된 청구 **전부**(용도 무관 · 정산 포함): 회원 연결 · 좌석 행 · 회차 (2026-10-23)
-- 왜: 1차(20261023_diag_link_member.sql)에서 결제된 「티켓 링크」가 0건 — 에릭의 스시 사이토 2027.03.15 2인 $1,800 은 다른 길(정산 · 자유 금액)로 결제됐다.
-- 무엇: SELECT 만 · 이름·번호·이메일 없음(청구 id 앞 8자리 · 매장·날짜 · 금액 · 「있다/없다」와 건수만).
-- ═══════════════════════════════════════════════════════════════
create or replace function pg_temp.diag_link_member2()
returns table(sec text, info text)
language plpgsql as $$
declare r record;
begin
  for r in
    select left(c.id::text, 8) cid, c.status, coalesce(c.purpose, '-') purpose, c.link_invite,
           coalesce(c.title, '-') title, coalesce(c.subtitle, '-') subtitle,
           coalesce(e.venue_name, '-') venue, coalesce(to_char(e.event_date, 'YYYY.MM.DD'), '-') ev_date, coalesce(to_char(e.event_time, 'HH24:MI'), '') ev_time,
           e.ticket_product_id is not null as ev_linked, coalesce(tm.pax, 0) team_pax,
           coalesce(c.pay_currency, 'KRW') cur, c.pay_amount, c.amount_krw,
           to_char(c.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') made, to_char(c.approved_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') paid,
           c.user_id is not null as charge_member,
           (select p.role from public.profiles p where p.id = c.user_id) charge_member_role,
           nullif(c.payload->>'member_uid', '') is not null as payload_member,
           coalesce(c.payer_phone, '') <> '' has_phone,
           (select count(*) from public.profiles p
             where p.deleted_at is null and coalesce(p.role, 'user') = 'user'
               and nullif(regexp_replace(coalesce(c.payer_phone, ''), '\D', '', 'g'), '') is not null
               and right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 9) = right(regexp_replace(c.payer_phone, '\D', '', 'g'), 9)) phone_match,
           (select string_agg(left(t.purchase_id, 5) || ':' || t.status || ':pax' || coalesce(t.party_size::text, '?')
                              || ':owner=' || coalesce((select p.role from public.profiles p where p.id = t.user_id), '?')
                              || case when coalesce(t.extra_data->>'memberUid', '') <> '' then ':memberUid' else '' end, ' | ')
              from public.tickets t where t.extra_data->>'chargeId' = c.id::text) rows
      from public.kashikiri_charges c
      left join public.kashikiri_events e on e.id = c.event_id
      left join public.kashikiri_teams tm on tm.id = c.team_id
     where c.status in ('paid', 'refunded')
     order by c.created_at
  loop
    sec := '① ' || r.cid || ' · ' || r.status || ' · ' || r.purpose || case when r.link_invite then '·link' else '' end;
    info := '회차 ' || r.venue || ' ' || r.ev_date || ' ' || r.ev_time || case when r.ev_linked then '(티켓 연결)' else '(티켓 미연결)' end || ' · 조 ' || r.team_pax || '인'
         || ' · 제목 ' || r.title || ' / ' || r.subtitle
         || ' · ' || r.cur || ' ' || coalesce(r.pay_amount::text, '-') || ' (₩' || coalesce(r.amount_krw::text, '-') || ') · 만듦 ' || coalesce(r.made, '-') || ' · 결제 ' || coalesce(r.paid, '-')
         || ' · 청구 회원 ' || case when r.charge_member then '있음(' || coalesce(r.charge_member_role, '?') || ')' else '없음' end
         || ' · payload 회원 ' || case when r.payload_member then '있음' else '없음' end
         || ' · 좌석 행 [' || coalesce(r.rows, '-') || '] · 번호 ' || case when r.has_phone then '있음' else '없음' end || ' · 번호 같은 회원 ' || r.phone_match || '명';
    return next;
  end loop;
  for r in select count(*) n, count(*) filter (where c.user_id is null) nm from public.kashikiri_charges c where c.status = 'paid' loop
    sec := '② 결제된 청구 전부'; info := r.n || '건 · 청구 회원 없음 ' || r.nm || '건'; return next;
  end loop;
  -- ③ 스시 사이토 2027 회차(티켓 상품) — 좌석 행 모양(살아 있는 것) · 운영 행 종류
  for r in
    select tp.id::text tpid, tp.date, tp.time, tp.rest_name,
           (select string_agg(left(t.purchase_id, 5) || ':' || t.status || ':pax' || coalesce(t.party_size::text, '?') || ':owner=' || coalesce((select p.role from public.profiles p where p.id = t.user_id), '?')
                              || case when coalesce(t.extra_data->>'memberUid', '') <> '' then ':memberUid' else '' end
                              || case when coalesce(t.extra_data->>'chargeId', '') <> '' then ':charge' else '' end, ' | ')
              from public.tickets t where t.ticket_product_id::text = tp.id::text and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired')) rows
      from public.ticket_products tp
     where tp.rest_name ilike '%사이토%' and tp.date like '2027.03%'
  loop
    sec := '③ ' || r.rest_name || ' ' || r.date || ' ' || coalesce(r.time, ''); info := '회차 ' || left(r.tpid, 8) || ' · 좌석 행 [' || coalesce(r.rows, '-') || ']'; return next;
  end loop;
end $$;
select sec as 구간, info as 내용 from pg_temp.diag_link_member2();
