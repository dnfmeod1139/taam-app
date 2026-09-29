-- ============================================================================
-- 20260929_pay_venue_i18n.sql — 결제 페이지 매장 이름을 손님 언어로 (2026-09-29 밤)
-- ============================================================================
-- 정산·링크 결제 페이지(/pay/)는 KO/EN/JA 전환이 있지만 매장 이름만 회차의 한글 스냅샷을 그대로 썼다.
-- 공개 RPC 가 restaurants 의 영문·일본어 표기(name_en / name_jp)를 같이 돌려주고, 페이지가 언어에 맞춰 고른다.
-- 달러 청구는 EN, 엔 청구는 JA 를 기본 언어로 잡는다(손님이 버튼으로 바꿀 수 있다). 번역이 빈 매장은 한글 그대로.
-- 금액 컬럼은 종전과 같다 — 새로 내보내는 건 매장 이름 표기 둘뿐이다.
-- ============================================================================
create or replace function public.taam_kashikiri_charge_public(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;

  select jsonb_build_object(
    'id',           c.id,
    'label',        c.label,
    'amount_krw',   c.amount_krw,
    'amount_jpy',   c.amount_jpy,
    'pay_currency', coalesce(c.pay_currency, 'KRW'),
    'pay_amount',   coalesce(c.pay_amount, c.amount_krw),
    'pay_fx',       c.pay_fx,
    'status',       c.status,
    'expires_at',   c.expires_at,
    'paid_at',      c.approved_at,
    'receipt_url',  c.receipt_url,
    'venue_name',   e.venue_name,
    -- 🆕 2026-09-29 결제 페이지가 손님 언어로 매장 이름을 보여 준다 (restaurants 의 영문·일본어 표기 — 비어 있으면 한글)
    'venue_name_en', nullif(btrim(coalesce(r.name_en, '')), ''),
    'venue_name_jp', nullif(btrim(coalesce(r.name_jp, '')), ''),
    'event_date',   e.event_date,
    'event_time',   e.event_time,
    'fx_rate',      e.fx_rate,
    'fx_note',      e.fx_note,
    'team_seq',     t.seq,
    'team_pax',     t.pax,
    'split_count', case
      when c.team_id is not null then
        (select count(*) from public.kashikiri_charges x
          where x.team_id = c.team_id and x.status <> 'cancelled')
      else
        (select count(*) from public.kashikiri_charges x
          where x.event_id = c.event_id and x.status <> 'cancelled')
    end
  ) into v
  from public.kashikiri_charges c
  join public.kashikiri_events e on e.id = c.event_id
  left join public.kashikiri_teams t on t.id = c.team_id
  left join public.restaurants r on r.id::text = e.venue_id
  where c.token = p_token;

  return v;
end;
$$;

revoke all on function public.taam_kashikiri_charge_public(text) from public;
grant execute on function public.taam_kashikiri_charge_public(text) to anon, authenticated;

-- ── 확인 ──
select '① 결제 페이지 RPC 가 매장 EN·JA 이름을 돌려준다' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_charge_public') and prosrc like '%venue_name_jp%') then '✅' else '❌ 옛 판' end as result;
