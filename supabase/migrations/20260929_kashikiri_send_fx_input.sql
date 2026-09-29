-- ============================================================================
-- 20260929_kashikiri_send_fx_input.sql — 정산 링크: 외화는 외화로 적는다 (2026-09-29 밤)
-- ============================================================================
-- 종전엔 금액 칸이 언제나 원화였고 서버가 원화 ÷ 환율로 달러·엔을 만들었다. 그래서 「$1,680 을 보내고 싶다」면 원화를
-- 역산해 넣어야 했고, 나눗셈 끝수 때문에 $1,679.85 가 나갔다 (Takiya · Trina). 이제 통화를 $·¥ 로 고르면 **그 통화로
-- 금액을 적고**, 서버는 그 금액을 그대로 승인액(pay_amount)으로 쓰며 원화(amount_krw)를 곱셈으로 만든다.
--   달러: 센트 둘째 자리까지 · 엔: 정수 · 원화 = round(외화 × 회차 환율)
-- 같이 고친 것: 총액 대조는 「넘을 때만」 막는다 (종전엔 정확히 같아야 해서 나눠 보내기가 막혔다).
-- 원칙은 그대로다 — 환율은 회차(kashikiri_events.fx_usd / fx_rate)에 못 박힌 값만 쓰고, 브라우저가 보낸 원화는 믿지 않는다
-- (외화를 적은 줄은 원화를 서버가 다시 만든다). 외화 입력이 없는 줄은 종전대로 원화 → 외화 나눗셈.
-- ============================================================================
create or replace function public.taam_kashikiri_send(
  p_event_id uuid,
  p_rows     jsonb
)
returns setof public.kashikiri_charges
language plpgsql volatile security definer set search_path = public
as $$
declare
  e      public.kashikiri_events%rowtype;
  r      jsonb;
  v_new  bigint := 0;
  v_have bigint := 0;
  v_exp  timestamptz;
  v_cur  text;
  v_pay  numeric;
  v_krw  bigint;
  v_fx   numeric;
  v_rows jsonb := '[]'::jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;

  select * into e from public.kashikiri_events where id = p_event_id;
  if not found then raise exception '회차를 찾을 수 없습니다' using errcode = 'P0002'; end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception '보낼 사람이 없습니다' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(nullif(trim(r->>'label'), ''), '') = '' then
      raise exception '이름이 빈 줄이 있습니다' using errcode = '22023';
    end if;
    v_cur := upper(coalesce(nullif(r->>'currency',''), 'KRW'));
    if v_cur not in ('KRW','USD','JPY') then
      raise exception '「%」의 통화(%)를 알 수 없습니다', r->>'label', v_cur using errcode = '22023';
    end if;
    -- 환율이 없으면 그 통화로 못 보낸다. 없는 환율로 금액을 지어내지 않는다.
    if v_cur = 'JPY' and coalesce(e.fx_rate, 0) <= 0 then
      raise exception '엔화로 보내려면 회차에 엔 환율을 먼저 넣으세요' using errcode = '22023';
    end if;
    if v_cur = 'USD' and coalesce(e.fx_usd, 0) <= 0 then
      raise exception '달러로 보내려면 회차에 달러 환율을 먼저 넣으세요' using errcode = '22023';
    end if;
    v_fx := case v_cur when 'JPY' then e.fx_rate when 'USD' then e.fx_usd else 1 end;

    if v_cur <> 'KRW' and coalesce((r->>'pay_amount')::numeric, 0) > 0 then
      -- 🆕 외화를 적은 줄: 승인액은 적은 그대로, 원화는 곱셈으로
      v_pay := case v_cur when 'JPY' then round((r->>'pay_amount')::numeric) else round((r->>'pay_amount')::numeric, 2) end;
      v_krw := round(v_pay * v_fx)::bigint;
    else
      -- 종전 경로: 원화를 적은 줄
      v_krw := coalesce((r->>'amount_krw')::bigint, 0);
      v_pay := case v_cur when 'JPY' then round(v_krw / v_fx) when 'USD' then round(v_krw / v_fx, 2) else v_krw end;
    end if;
    if v_krw <= 0 or v_pay <= 0 then
      raise exception '「%」의 금액이 0 이하입니다', r->>'label' using errcode = '22023';
    end if;
    v_new := v_new + v_krw;
    v_rows := v_rows || jsonb_build_object(
      'team_id', r->>'team_id', 'guest_id', r->>'guest_id', 'label', trim(r->>'label'),
      'user_id', r->>'user_id', 'phone', r->>'phone',
      'currency', v_cur, 'fx', v_fx, 'amount_krw', v_krw, 'pay_amount', v_pay);
  end loop;

  -- 총액을 적어 둔 회차만 대조한다 (원화 기준 — 통화가 섞여도 기준은 하나다)
  if coalesce(e.total_krw, 0) > 0 then
    select coalesce(sum(amount_krw), 0) into v_have
      from public.kashikiri_charges
     where event_id = e.id and status <> 'cancelled';
    -- 🔧 2026-09-29 종전엔 「정확히 같아야」 통과시켰다 — 화면 안내(「총액을 넘기면 막는다 · 모자란 건 괜찮다」)와 달랐고,
    --   나눠 보내는 첫 링크가 전부 막혔다. 넘길 때만 막는다.
    if (v_have + v_new) > e.total_krw then
      raise exception '보낼 합계가 정산 총액을 넘습니다 (이미 % + 이번 % = %, 총액 %)',
        v_have, v_new, v_have + v_new, e.total_krw using errcode = '22023';
    end if;
  end if;

  v_exp := (e.event_date + interval '3 day');

  return query
  insert into public.kashikiri_charges
    (event_id, team_id, guest_id, label, user_id, payer_phone,
     amount_krw, amount_jpy, pay_currency, pay_fx, pay_amount, expires_at)
  select
    e.id,
    nullif(x->>'team_id','')::uuid,
    nullif(x->>'guest_id','')::uuid,
    x->>'label',
    nullif(x->>'user_id','')::uuid,
    nullif(regexp_replace(coalesce(x->>'phone',''), '[^0-9]', '', 'g'), ''),
    (x->>'amount_krw')::int,
    case when x->>'currency' = 'JPY' then (x->>'pay_amount')::numeric::int end,   -- 엔화 청구면 승인 엔이 곧 표시 엔
    x->>'currency',
    (x->>'fx')::numeric,
    (x->>'pay_amount')::numeric,
    v_exp
  from jsonb_array_elements(v_rows) as x
  returning *;
end;
$$;
revoke all on function public.taam_kashikiri_send(uuid, jsonb) from public;
grant execute on function public.taam_kashikiri_send(uuid, jsonb) to authenticated;

-- ── 확인 ──
select '① 정산 보내기: 외화 입력 받음' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_send') and prosrc like '%외화를 적은 줄%') then '✅' else '❌ 옛 판' end as result;
