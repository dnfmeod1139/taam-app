-- ═══════════════════════════════════════════════════════════════
-- TAAM — 정산 링크를 달러·엔으로도 받는다 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   대관에는 해외 손님이 섞인다. 원화로만 청구하면 그 사람 카드가
--   해외 원화 결제로 처리돼 카드사 환가료가 붙고, 명세서에 얼마가 찍힐지
--   본인도 모른다. 앱에는 이미 해외 MID(USD·JPY)가 열려 있는데
--   (2026.08.21 승인) 정산 링크만 원화 전용이었다.
--
-- 무엇을 기준으로 두나 — **원화가 기준이다**
--   amount_krw = 우리가 받을 돈(매출 기록). 통화를 바꿔도 이 값은 안 바뀐다.
--   pay_currency / pay_amount = **승인만** 그 통화로 한다.
--   기존 toss-order 가 amount(외화) + settle_krw(원화)를 한 주문에 얼려두는
--   것과 같은 구조다. 둘을 섞으면 원장이 통째로 어긋난다.
--
--   ⚠ 외화로 승인하면 실제 입금 원화는 카드사 환율에 따라 조금 다르다.
--     amount_krw 는 「기준」이지 「실수령」이 아니다. 정산서를 만들 때
--     이 차이를 흡수할 곳이 필요하다 — 지금은 기록만 해 둔다.
--
-- 환율은 회차에 못 박는다
--   전역 환율 설정(app_config.fx_settings)을 그때그때 읽으면, 나중에
--   「왜 이 금액이냐」를 재현할 수 없다. 회차에 적어 둔 값만 쓴다.
--   앱이 폼을 열 때 전역 설정값을 기본값으로 채워 주므로 손은 안 간다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ kashikiri.sql · kashikiri_link.sql · kashikiri_send.sql 다음에.
--   ⚠ 앱·Edge Function 보다 **먼저** 실행한다.
--   읽는 법: 맨 아래 표에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════

alter table public.kashikiri_charges
  add column if not exists pay_currency text not null default 'KRW';
alter table public.kashikiri_charges
  add column if not exists pay_amount numeric(14,2);
alter table public.kashikiri_charges
  add column if not exists pay_fx numeric(12,4);
alter table public.kashikiri_events
  add column if not exists fx_usd numeric(12,4);

-- 통화는 셋뿐이다. 오타로 'krw' 가 들어가면 결제창이 안 열린다.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'kashikiri_charges_cur_chk') then
    alter table public.kashikiri_charges
      add constraint kashikiri_charges_cur_chk check (pay_currency in ('KRW','USD','JPY'));
  end if;
end $$;

-- 이미 있는 청구는 전부 원화다
update public.kashikiri_charges
   set pay_currency = 'KRW', pay_amount = amount_krw, pay_fx = 1
 where pay_amount is null;

comment on column public.kashikiri_charges.amount_krw is
  '정산 기준 원화 — 우리가 받을 돈. 통화를 바꿔도 이 값은 안 바뀐다.';
comment on column public.kashikiri_charges.pay_currency is
  '실제 승인 통화 (KRW/USD/JPY). 승인만 이 통화로 한다.';
comment on column public.kashikiri_charges.pay_amount is
  '그 통화로 승인할 금액. 서버가 amount_krw ÷ pay_fx 로 계산한다 — 브라우저가 정하지 않는다.';
comment on column public.kashikiri_events.fx_usd is
  '이 회차에 못 박은 달러 환율 (1 USD = ?원).';


-- ─────────────────────────────────────────────────────────────
-- 보내기 — 통화까지 받는다
-- ─────────────────────────────────────────────────────────────
--   p_rows: [{"label":"…","phone":"…","amount_krw":1051875,"currency":"JPY", …}]
--   ⚠ 외화 금액은 **서버가 계산한다.** 브라우저가 준 값을 쓰면 그걸로 끝이다.
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
    if coalesce((r->>'amount_krw')::bigint, 0) <= 0 then
      raise exception '「%」의 금액이 0원 이하입니다', r->>'label' using errcode = '22023';
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
    v_new := v_new + (r->>'amount_krw')::bigint;
  end loop;

  -- 총액을 적어 둔 회차만 대조한다 (원화 기준 — 통화가 섞여도 기준은 하나다)
  if coalesce(e.total_krw, 0) > 0 then
    select coalesce(sum(amount_krw), 0) into v_have
      from public.kashikiri_charges
     where event_id = e.id and status <> 'cancelled';
    if (v_have + v_new) <> e.total_krw then
      raise exception '보낼 합계가 정산 총액과 다릅니다 (이미 % + 이번 % = %, 총액 %)',
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
    trim(x->>'label'),
    nullif(x->>'user_id','')::uuid,
    nullif(regexp_replace(coalesce(x->>'phone',''), '[^0-9]', '', 'g'), ''),
    (x->>'amount_krw')::int,
    -- 엔화 청구면 승인 엔이 곧 표시 엔이다. 그 밖에는 안 적는다.
    case when upper(coalesce(nullif(x->>'currency',''),'KRW')) = 'JPY'
         then round((x->>'amount_krw')::numeric / e.fx_rate)::int end,
    upper(coalesce(nullif(x->>'currency',''), 'KRW')),
    case upper(coalesce(nullif(x->>'currency',''),'KRW'))
      when 'JPY' then e.fx_rate when 'USD' then e.fx_usd else 1 end,
    -- ⚠ 여기가 요점 — 외화 금액은 서버가 만든다
    case upper(coalesce(nullif(x->>'currency',''),'KRW'))
      when 'JPY' then round((x->>'amount_krw')::numeric / e.fx_rate)        -- 엔은 정수
      when 'USD' then round((x->>'amount_krw')::numeric / e.fx_usd, 2)      -- 달러는 센트
      else (x->>'amount_krw')::numeric end,
    v_exp
  from jsonb_array_elements(p_rows) as x
  returning *;
end;
$$;

revoke all on function public.taam_kashikiri_send(uuid, jsonb) from public;
grant execute on function public.taam_kashikiri_send(uuid, jsonb) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 링크로 읽기 — 통화를 함께 준다
-- ─────────────────────────────────────────────────────────────
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
  where c.token = p_token;

  return v;
end;
$$;

revoke all on function public.taam_kashikiri_charge_public(text) from public;
grant execute on function public.taam_kashikiri_charge_public(text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 결제 시작 — 승인할 통화·금액을 서버가 준다
-- ─────────────────────────────────────────────────────────────
create or replace function public.taam_kashikiri_order_start(
  p_token text,
  p_name  text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare c public.kashikiri_charges%rowtype; v_order text; e_row public.kashikiri_events%rowtype;
begin
  select * into c from public.kashikiri_charges where token = p_token;
  if not found then raise exception '없는 링크입니다' using errcode = 'P0002'; end if;
  if c.status = 'paid' then
    return jsonb_build_object('already_paid', true, 'order_id', c.order_id);
  end if;
  if c.status in ('cancelled','expired') then
    return jsonb_build_object('blocked', c.status);
  end if;
  if c.expires_at is not null and now() > c.expires_at then
    update public.kashikiri_charges set status = 'expired' where id = c.id;
    return jsonb_build_object('blocked', 'expired');
  end if;

  select * into e_row from public.kashikiri_events where id = c.event_id;
  v_order := coalesce(c.order_id, 'KSK-' || replace(c.id::text, '-', ''));

  update public.kashikiri_charges
     set order_id   = v_order,
         payer_name = coalesce(nullif(trim(p_name), ''), payer_name)
   where id = c.id;

  return jsonb_build_object(
    'order_id',   v_order,
    'currency',   coalesce(c.pay_currency, 'KRW'),
    -- 승인 금액. 원화면 정수로, 외화면 소수 그대로 넘긴다.
    'amount',     coalesce(c.pay_amount, c.amount_krw),
    'amount_krw', c.amount_krw,
    'order_name', '[TAAM] ' || to_char(e_row.event_date, 'MM/DD')
                  || ' ' || coalesce(e_row.venue_name, 'TAAM')
  );
end;
$$;

revoke all on function public.taam_kashikiri_order_start(text, text) from public;
grant execute on function public.taam_kashikiri_order_start(text, text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 결제 확정 — 통화까지 대조한다 (service_role 만)
-- ─────────────────────────────────────────────────────────────
--   ⚠ 옛 taam_kashikiri_mark_paid(bigint) 는 그대로 둔다. 달러는 센트가 있어
--     bigint 에 안 담기므로 numeric 을 받는 새 이름을 쓴다. Edge Function 이
--     이걸 먼저 부르고, 없으면 옛 것으로 내려간다(원화 전용).
create or replace function public.taam_kashikiri_mark_paid_v2(
  p_order_id    text,
  p_payment_key text,
  p_amount      numeric,
  p_currency    text,
  p_method      text default null,
  p_receipt     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare c public.kashikiri_charges%rowtype; v_want numeric; v_cur text;
begin
  select * into c from public.kashikiri_charges where order_id = p_order_id;
  if not found then raise exception '주문을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if c.status = 'paid' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  v_cur  := upper(coalesce(c.pay_currency, 'KRW'));
  v_want := coalesce(c.pay_amount, c.amount_krw);

  if upper(coalesce(p_currency, 'KRW')) <> v_cur then
    raise exception '승인 통화(%)가 청구 통화(%)와 다릅니다', p_currency, v_cur
      using errcode = '22023';
  end if;
  -- 원 단위·센트 단위까지 같아야 한다. 반올림 차이도 통과시키지 않는다.
  if round(coalesce(p_amount, -1), 2) <> round(v_want, 2) then
    raise exception '승인 금액(%)이 청구 금액(%)과 다릅니다', p_amount, v_want
      using errcode = '22023';
  end if;

  update public.kashikiri_charges
     set status = 'paid', payment_key = p_payment_key, method = p_method,
         receipt_url = p_receipt, approved_at = now()
   where id = c.id;

  return jsonb_build_object('ok', true, 'charge_id', c.id,
                            'currency', v_cur, 'amount', v_want, 'settle_krw', c.amount_krw);
end;
$$;

revoke all on function public.taam_kashikiri_mark_paid_v2(text, text, numeric, text, text, text) from public;
-- authenticated 에게도 주지 않는다. service_role 만 부른다.

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 컬럼' as "구분", c.t || '.' || c.n as "이름",
       case when not exists (
              select 1 from pg_attribute a
               where a.attrelid = ('public.' || c.t)::regclass
                 and a.attname = c.n and a.attnum > 0 and not a.attisdropped)
            then '❌ 없음' else '✅' end as "상태"
  from (values ('kashikiri_charges','pay_currency'),
               ('kashikiri_charges','pay_amount'),
               ('kashikiri_charges','pay_fx'),
               ('kashikiri_events','fx_usd')) as c(t, n)

union all
select '② 함수', p.name,
       case when not exists (
              select 1 from pg_proc pr
               where pr.pronamespace = 'public'::regnamespace and pr.proname = p.name)
            then '❌ 없음' else '✅' end
  from (values ('taam_kashikiri_send'),
               ('taam_kashikiri_order_start'),
               ('taam_kashikiri_mark_paid_v2')) as p(name)

union all
select '③ 옛 청구가 원화로 채워졌나', 'pay_amount 비어 있는 건',
       case when count(*) = 0 then '✅ 없음' else '❌ ' || count(*)::text || '건' end
  from public.kashikiri_charges where pay_amount is null

union all
select '④ 통화 제약', 'KRW/USD/JPY 만',
       case when exists (select 1 from pg_constraint where conname = 'kashikiri_charges_cur_chk')
            then '✅' else '❌ 없음' end

 order by 1, 2;
