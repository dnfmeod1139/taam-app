-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 결제 링크로 낸 티켓이 회원 구매내역에 안 보이는 건 (에릭 · 스시 사이토 2027.03.15 2인 $1,800) · 같은 모양이 몇 건인가 (2026-10-23)
-- 무엇: SELECT 만 · 이름·번호·이메일 없음(청구 id 앞 8자리 · 매장·날짜 · 금액 · 상태 · 「있다/없다」와 건수만).
-- ═══════════════════════════════════════════════════════════════
create or replace function pg_temp.diag_link_member()
returns table(sec text, info text)
language plpgsql as $$
declare r record;
begin
  -- ① 결제된 티켓 링크(청구) 전부 — 회원 연결 상태
  for r in
    select left(c.id::text, 8) cid, c.status, coalesce(c.purpose, '-') purpose, c.link_invite,
           coalesce(c.title, '-') title, coalesce(c.subtitle, '-') subtitle,
           coalesce(c.pay_currency, 'KRW') cur, c.pay_amount, c.amount_krw,
           to_char(c.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') made, to_char(c.approved_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') paid,
           c.user_id is not null as charge_member,
           nullif(c.payload->>'member_uid', '') is not null as payload_member,
           (select count(*) from public.tickets t where t.extra_data->>'chargeId' = c.id::text) n_rows,
           (select string_agg(left(t.purchase_id, 5) || ':' || t.status
                              || ':owner=' || coalesce((select p.role from public.profiles p where p.id = t.user_id), '?')
                              || case when coalesce(t.extra_data->>'memberUid', '') <> '' then ':memberUid' else '' end
                              || case when coalesce(t.extra_data->>'memberUidPending', '') <> '' then ':pending' else '' end
                              || coalesce(':err=' || nullif(t.extra_data->>'ownerTransferError', ''), ''), ' | ')
              from public.tickets t where t.extra_data->>'chargeId' = c.id::text) rows,
           (select count(*) from public.profiles p
             where p.deleted_at is null and coalesce(p.role, 'user') = 'user'
               and nullif(regexp_replace(coalesce(c.payer_phone, ''), '\D', '', 'g'), '') is not null
               and right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 9) = right(regexp_replace(c.payer_phone, '\D', '', 'g'), 9)) phone_match,
           coalesce(c.payer_phone, '') <> '' has_phone,
           c.payload ? 'guest_invite_code' as guest_inv
      from public.kashikiri_charges c
     where c.status in ('paid', 'refunded') and (c.link_invite or coalesce(c.purpose, '') = 'ticket')
     order by c.created_at
  loop
    sec := '① ' || r.cid || ' · ' || r.status;
    info := r.title || ' ' || r.subtitle || ' · ' || r.cur || ' ' || coalesce(r.pay_amount::text, '-') || ' (₩' || coalesce(r.amount_krw::text, '-') || ') · 만듦 ' || coalesce(r.made, '-') || ' · 결제 ' || coalesce(r.paid, '-')
         || ' · purpose ' || r.purpose || ' · 청구 회원 ' || case when r.charge_member then '있음' else '없음' end || ' · payload 회원 ' || case when r.payload_member then '있음' else '없음' end
         || ' · 좌석 행 ' || r.n_rows || ' [' || coalesce(r.rows, '-') || '] · 번호 ' || case when r.has_phone then '있음' else '없음' end || ' · 번호 같은 회원 ' || r.phone_match || '명'
         || case when r.guest_inv then ' · 게스트 초대장' else '' end;
    return next;
  end loop;
  -- ② 요약
  for r in
    select count(*) total,
           count(*) filter (where c.user_id is null) no_member,
           count(*) filter (where c.user_id is null and exists (select 1 from public.profiles p where p.deleted_at is null and coalesce(p.role,'user') = 'user'
                                 and nullif(regexp_replace(coalesce(c.payer_phone,''), '\D', '', 'g'), '') is not null
                                 and right(regexp_replace(coalesce(p.phone,''), '\D', '', 'g'), 9) = right(regexp_replace(c.payer_phone, '\D', '', 'g'), 9))) no_member_phone_match
      from public.kashikiri_charges c
     where c.status = 'paid' and (c.link_invite or coalesce(c.purpose, '') = 'ticket')
  loop
    sec := '② 결제된 티켓 링크'; info := r.total || '건 · 회원 미연결 ' || r.no_member || '건 · 그중 번호가 회원과 같은 것 ' || r.no_member_phone_match || '건'; return next;
  end loop;
  -- ③ 회원 앱이 읽는 길 — kc_mine 정책 · tickets 회원 select 정책 이름
  for r in select polname, pg_get_expr(polqual, polrelid) q from pg_policy where polrelid = 'public.kashikiri_charges'::regclass loop
    sec := '③ kashikiri_charges 정책'; info := r.polname || ' : ' || left(coalesce(r.q, '-'), 160); return next;
  end loop;
  for r in select tgname from pg_trigger where tgrelid = 'public.kashikiri_charges'::regclass and not tgisinternal order by 1 loop
    sec := '③ kashikiri_charges 트리거'; info := r.tgname; return next;
  end loop;
end $$;
select sec as 구간, info as 내용 from pg_temp.diag_link_member();
