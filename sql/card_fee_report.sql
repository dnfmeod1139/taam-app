-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 카드 수수료 계산 (내부용 · 슈퍼어드민) · 2026-10-13
--   카드로 받은 결제를 한 표로 돌려주는 RPC. 수수료율은 앱(app_config.card_fee_settings)에서 곱한다 — 서버는 금액만 센다.
--   ⚠ 회원에게 수수료를 청구하는 기능이 **아니다**(여신전문금융업법 제19조④ 금지). 우리가 내는 비용을 내부에서 보기 위한 것.
--   출처 둘: ① payment_orders(status paid) — 티켓 부족분 카드 결제(card) · 등록 카드 결제(billing, metadata.paid_via)
--           ② kashikiri_charges(status paid) — 정산 결제(kashikiri) · 링크 초대(link). 외화는 pay_currency/pay_amount, 원화 환산은 amount_krw.
--   실행: Supabase SQL Editor 에 통째로. 마지막 표 ❌ 0.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.taam_card_fee_report(p_from timestamptz, p_to timestamptz)
returns table(kind text, paid_at timestamptz, user_id uuid, who text, label text, currency text,
              amount numeric, amount_krw bigint, method text, ref text)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public._taam_uid_is_super() then
    raise exception '슈퍼어드민만 볼 수 있습니다' using errcode = '42501';
  end if;
  return query
  select * from (
    select case when coalesce(o.metadata ->> 'paid_via', '') = 'billing_key' then 'billing' else 'card' end as kind,
           coalesce(o.approved_at, o.updated_at)                                as paid_at,
           o.user_id,
           coalesce(nullif(btrim(p.display_name), ''), '(이름없음)')             as who,
           coalesce(nullif(o.metadata ->> 'restaurant_name', ''), o.purpose)
             || case when o.purpose = 'ticket_topup' then ' · 티켓 부족분' else ' · ' || o.purpose end as label,
           upper(coalesce(o.currency, 'KRW'))                                    as currency,
           o.amount::numeric                                                     as amount,
           coalesce(o.settle_krw, case when upper(coalesce(o.currency, 'KRW')) = 'KRW' then o.amount end)::bigint as amount_krw,
           o.method,
           o.order_id                                                            as ref
      from public.payment_orders o
      left join public.profiles p on p.id = o.user_id
     where o.status = 'paid'
       and coalesce(o.approved_at, o.updated_at) >= p_from
       and coalesce(o.approved_at, o.updated_at) <  p_to
    union all
    select case when c.link_invite then 'link' else 'kashikiri' end,
           coalesce(c.approved_at, c.created_at),
           c.user_id,
           coalesce(nullif(btrim(p.display_name), ''), nullif(btrim(c.payer_name), ''), c.label, '(이름없음)'),
           coalesce(e.venue_name, '정산') || ' · ' || to_char(e.event_date, 'YYYY-MM-DD')
             || coalesce(' ' || to_char(e.event_time, 'HH24:MI'), ''),
           upper(coalesce(c.pay_currency, 'KRW')),
           coalesce(c.pay_amount, c.amount_krw)::numeric,
           c.amount_krw::bigint,
           c.method,
           c.order_id
      from public.kashikiri_charges c
      left join public.kashikiri_events e on e.id = c.event_id
      left join public.profiles p on p.id = c.user_id
     where c.status = 'paid'
       and coalesce(c.approved_at, c.created_at) >= p_from
       and coalesce(c.approved_at, c.created_at) <  p_to
  ) x
  order by x.paid_at desc;
end $$;
revoke all on function public.taam_card_fee_report(timestamptz, timestamptz) from public, anon;
grant execute on function public.taam_card_fee_report(timestamptz, timestamptz) to authenticated;

-- ── 확인 (한 표) — ❌ 0 ──
select '① RPC taam_card_fee_report' as what,
       case when to_regproc('public.taam_card_fee_report') is not null then '✅' else '❌' end as result
union all
select '② 최근 30일 카드 결제 건수 (paid · 두 출처 합)',
       '✅ ' || ((select count(*) from public.payment_orders where status = 'paid' and coalesce(approved_at, updated_at) > now() - interval '30 days')
               + (select count(*) from public.kashikiri_charges where status = 'paid' and coalesce(approved_at, created_at) > now() - interval '30 days'))::text || '건';
