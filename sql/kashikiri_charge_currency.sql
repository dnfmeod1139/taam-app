-- ═══════════════════════════════════════════════════════════════
-- TAAM — QR 을 내밀면서 국내·해외를 확정한다 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   통화는 링크를 만들 때 정해진다. 그런데 「이분 해외카드시네」를
--   알게 되는 건 QR 을 내미는 그 순간이다. 그때 고칠 수 없으면
--   ① 링크를 끊고 ② 다시 만들고 ③ 다시 내밀어야 한다 — 자리에서.
--
--   토큰은 그대로 둔다. 손님이 이미 QR 을 찍었을 수도 있고, 찍은 링크가
--   죽으면 그 사람은 「결제가 안 되는 링크」를 본다. 바꾸는 건 통화뿐이다.
--
-- 무엇을 바꾸나 — 함수 하나. 표도 데이터도 안 건드린다.
--   ⚠ 금액(amount_krw)은 손대지 않는다. 원화가 언제나 기준이고,
--     외화는 회차 환율로 서버가 다시 만든다. 앱이 만들면 앱과 서버가
--     어긋나고, 어긋난 금액으로 승인이 나면 되돌릴 방법이 없다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ 안 돌려도 앱은 돈다 — QR 에서 통화를 바꾸려 하면 「함수가 없다」고
--     알려주고 아무 일도 안 한다. 종전대로 링크를 다시 만들면 된다.
--   읽는 법: 맨 아래 ①②③ 이 전부 ✅ 여야 정상.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_kashikiri_charge_currency(
  p_charge_id uuid,
  p_currency  text
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  c   public.kashikiri_charges%rowtype;
  e   public.kashikiri_events%rowtype;
  v_cur text;
  v_fx  numeric;
  v_amt numeric;
  v_jpy int;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;

  v_cur := upper(coalesce(nullif(btrim(p_currency), ''), ''));
  if v_cur not in ('KRW','USD','JPY') then
    raise exception '통화(%)를 알 수 없습니다', p_currency using errcode = '22023';
  end if;

  select * into c from public.kashikiri_charges where id = p_charge_id;
  if not found then raise exception '청구를 찾을 수 없습니다' using errcode = 'P0002'; end if;

  -- 이미 낸 건은 못 바꾼다. 승인이 난 통화가 곧 그 사람 명세서다.
  if c.status = 'paid' then
    raise exception '이미 결제된 건은 통화를 바꿀 수 없습니다' using errcode = '55000';
  end if;
  if c.status = 'cancelled' then
    raise exception '끊긴 링크입니다' using errcode = '55000';
  end if;

  select * into e from public.kashikiri_events where id = c.event_id;
  if not found then raise exception '회차를 찾을 수 없습니다' using errcode = 'P0002'; end if;

  -- 환율이 없으면 금액을 지어내지 않는다
  if v_cur = 'JPY' then
    v_fx := e.fx_rate;
    if coalesce(v_fx, 0) <= 0 then
      raise exception '엔화로 바꾸려면 회차에 엔 환율을 먼저 넣으세요' using errcode = '22023';
    end if;
    v_amt := round(c.amount_krw::numeric / v_fx);
    v_jpy := v_amt::int;
  elsif v_cur = 'USD' then
    v_fx := e.fx_usd;
    if coalesce(v_fx, 0) <= 0 then
      raise exception '달러로 바꾸려면 회차에 달러 환율을 먼저 넣으세요' using errcode = '22023';
    end if;
    v_amt := round(c.amount_krw::numeric / v_fx, 2);
    v_jpy := null;
  else
    v_fx  := 1;
    v_amt := c.amount_krw::numeric;
    v_jpy := null;
  end if;

  update public.kashikiri_charges
     set pay_currency = v_cur,
         pay_fx       = v_fx,
         pay_amount   = v_amt,
         amount_jpy   = v_jpy
   where id = c.id;

  return jsonb_build_object(
    'ok', true, 'label', c.label,
    'pay_currency', v_cur, 'pay_fx', v_fx, 'pay_amount', v_amt,
    'amount_krw', c.amount_krw
  );
end;
$$;

revoke all on function public.taam_kashikiri_charge_currency(uuid, text) from public;
grant execute on function public.taam_kashikiri_charge_currency(uuid, text) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 함수가 있나' as "구분",
       case when exists (select 1 from pg_proc
                          where pronamespace='public'::regnamespace
                            and proname='taam_kashikiri_charge_currency')
            then '✅' else '❌ 없음' end as "상태"

union all
select '② 결제된 건은 막나',
       case when prosrc like '%이미 결제된 건은 통화를%' then '✅' else '❌' end
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_kashikiri_charge_currency'

union all
select '③ 원화 금액은 안 건드리나',
       case when prosrc not like '%set amount_krw%' then '✅' else '❌ 원화를 고친다' end
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_kashikiri_charge_currency'

 order by 1;
