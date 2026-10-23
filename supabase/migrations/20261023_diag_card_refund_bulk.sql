-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 카드 환불 「완료 표시」 한 번에 두 건이 완료된 건 (2026-10-23)
-- 왜: 「예치금 관리 → 카드환불」에서 위 카드(10/22 · ₩125,000)의 「💳 토스 승인취소 실행」 → 「토스에 앱 밖 취소」 확인창에서 「확인」만 눌렀는데,
--     아래 카드(8/15 · ₩2,000 · 슈퍼어드민 예외 환불)까지 「✓ 카드 환불 완료」가 됐다. 화면 머리 「미처리 ₩127,…」 = 둘 다 대기였다.
-- 무엇: SELECT 만 · 이름·번호·이메일 없음(구매 id 앞 12자리 · 주문 끝 6자리 · 금액 · 시각 · 경로 · 건수).
--   ① 카드 환불 대기/완료 행 전부: 상태 · 금액 · 완료 시각(KST) · 경로(via manual|toss_api) · 처리자 역할 · 요청 시각 · 같은 구매 id 행 수 · 같은 회원 대기 수
--   ② 최근 3일 「카드 환불 완료」 회원 알림: 시각 · 구매 id · 금액 (= tkMarkCardRefundDone 이 불린 횟수)
--   ③ 그 주문들의 앱 취소 기록(payment_orders.metadata.app_cancels) 개수
-- ═══════════════════════════════════════════════════════════════
create or replace function pg_temp.safe_ts(x text) returns timestamptz language plpgsql immutable as $$
begin return x::timestamptz; exception when others then return null; end $$;
create or replace function pg_temp.diag_crf_bulk()
returns table(sec text, info text)
language plpgsql as $$
declare r record;
begin
  for r in
    select left(t.purchase_id, 12) pid, t.status tst,
           t.extra_data->'card_refund_pending' crp,
           right(coalesce(t.extra_data->'card_refund_pending'->>'order_id', t.extra_data->>'order_id', ''), 6) ord,
           to_char(t.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') made,
           (select count(*) from public.tickets t2 where t2.purchase_id = t.purchase_id) same_pid,
           (select count(*) from public.tickets t3 where t3.user_id = t.user_id and t3.extra_data ? 'card_refund_pending') same_user_crp,
           (select p.role from public.profiles p where coalesce(t.extra_data->'card_refund_pending'->>'done_by', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                               and p.id = (t.extra_data->'card_refund_pending'->>'done_by')::uuid) done_role,
           md5(coalesce(t.user_id::text, ''))::text uhash
      from public.tickets t
     where t.extra_data ? 'card_refund_pending'
     order by t.created_at
  loop
    sec := '① ' || r.pid || ' · 티켓 ' || coalesce(r.tst, '-');
    info := '대기 ' || coalesce(r.crp->>'status', '-') || ' · 금액 ₩' || coalesce(r.crp->>'amount', '-')
         || ' · 환불액 ₩' || coalesce(r.crp->>'refunded_amount', '-')
         || ' · 완료 ' || coalesce(to_char(pg_temp.safe_ts(r.crp->>'refunded_at') at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS'), '-')
         || ' · 경로 ' || coalesce(r.crp->>'via', '-') || ' · 처리자 ' || coalesce(r.done_role, '-')
         || ' · 요청 ' || coalesce(to_char(pg_temp.safe_ts(r.crp->>'requested_at') at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), '-')
         || ' · set_by ' || coalesce(r.crp->>'set_by_role', '-')
         || ' · 주문 …' || r.ord || ' · 만듦 ' || coalesce(r.made, '-')
         || ' · 같은 구매id 행 ' || r.same_pid || ' · 같은 회원 대기행 ' || r.same_user_crp || ' · 회원 ' || left(r.uhash, 6);
    return next;
  end loop;

  for r in
    select to_char(n.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') at_, left(coalesce(n.payload->>'purchase_id', '-'), 12) pid,
           coalesce(n.payload->>'amount', '-') amt, left(md5(coalesce(n.user_id::text, '')), 6) uh
      from public.notifications n
     where coalesce(n.type, '') = 'card_refund_done' and n.created_at > now() - interval '3 days'
     order by n.created_at
  loop
    sec := '② 완료 알림 ' || r.at_;
    info := '구매 ' || r.pid || ' · ₩' || r.amt || ' · 회원 ' || r.uh;
    return next;
  end loop;

  for r in
    select right(po.order_id, 6) ord, po.status, jsonb_array_length(coalesce(po.metadata->'app_cancels', '[]'::jsonb)) n_app
      from public.payment_orders po
     where po.order_id in (select coalesce(t.extra_data->'card_refund_pending'->>'order_id', t.extra_data->>'order_id')
                             from public.tickets t where t.extra_data ? 'card_refund_pending')
  loop
    sec := '③ 주문 …' || r.ord;
    info := '상태 ' || coalesce(r.status, '-') || ' · 앱 취소 기록 ' || r.n_app || '건';
    return next;
  end loop;
end $$;

select sec as 구분, info as 내용 from pg_temp.diag_crf_bulk();
