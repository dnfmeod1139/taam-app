-- ═══════════════════════════════════════════════════════════════
-- TAAM — 링크 발급이 통째로 실패하던 것 + 합계 검사 완화 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- ① function gen_random_bytes(integer) does not exist
--   토큰을 pgcrypto 의 gen_random_bytes 로 만들고 있었다. Supabase 는
--   확장을 **extensions 스키마**에 두는데, 우리 함수들은 search_path 가
--   public 이라 그 함수를 못 찾는다. create extension 을 해 뒀어도 마찬가지다.
--   → 결제 링크도, 게스트 시트 링크도 발급 자체가 안 됐다.
--
--   search_path 에 extensions 를 더하는 방법도 있지만, 그러면 이 파일이
--   「Supabase 가 확장을 어디에 두느냐」에 계속 매이게 된다.
--   gen_random_uuid() 는 PostgreSQL 13 부터 **코어**다. 확장이 필요 없다.
--   uuid 하나 = 128비트 = hex 32자. 토큰으로 충분하고도 남는다.
--
-- ② 합계가 총액과 「같아야」 하던 것을 「넘지 않으면」으로
--   보내기는 더하기인데 총액을 정확히 맞추라고 하면, 4명 중 2명만 먼저
--   보낼 수가 없다. 실제로 그렇게 막혔다.
--   막아야 하는 건 **총액을 넘기는 것**이지 모자란 것이 아니다.
--   모자란 건 「아직 덜 보냈다」는 뜻이고, 그건 정상적인 중간 상태다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   읽는 법: 맨 아래 ①②③ 이 전부 ✅ 여야 정상.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 토큰 — 확장에 기대지 않는다 ────────────────────────────
create or replace function public.taam_kashikiri_token()
returns text
language sql volatile
as $$
  -- gen_random_uuid() 는 PG13+ 코어. pgcrypto 가 없어도 된다.
  select replace(gen_random_uuid()::text, '-', '')
$$;

comment on function public.taam_kashikiri_token() is
  '링크 토큰 32자 hex. gen_random_uuid()(코어)로 만든다 — pgcrypto 에 기대지 않는다.';


-- ── ② 보내기 — 총액을 「넘지만」 않으면 된다 ──────────────────
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
    if v_cur = 'JPY' and coalesce(e.fx_rate, 0) <= 0 then
      raise exception '엔화로 보내려면 회차에 엔 환율을 먼저 넣으세요' using errcode = '22023';
    end if;
    if v_cur = 'USD' and coalesce(e.fx_usd, 0) <= 0 then
      raise exception '달러로 보내려면 회차에 달러 환율을 먼저 넣으세요' using errcode = '22023';
    end if;
    v_new := v_new + (r->>'amount_krw')::bigint;
  end loop;

  -- 🔧 2026-09-02: 「같아야」 → 「넘지 않으면」.
  --   보내기는 더하기다. 4명 중 2명만 먼저 보내는 건 정상적인 중간 상태고,
  --   그때 합계는 당연히 총액보다 적다. 막아야 하는 건 **넘기는 것**뿐이다.
  --   총액을 안 적어 둔 회차는 대조하지 않는다 — 기준이 없다.
  if coalesce(e.total_krw, 0) > 0 then
    select coalesce(sum(amount_krw), 0) into v_have
      from public.kashikiri_charges
     where event_id = e.id and status <> 'cancelled';
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
    trim(x->>'label'),
    nullif(x->>'user_id','')::uuid,
    nullif(regexp_replace(coalesce(x->>'phone',''), '[^0-9]', '', 'g'), ''),
    (x->>'amount_krw')::int,
    case when upper(coalesce(nullif(x->>'currency',''),'KRW')) = 'JPY'
         then round((x->>'amount_krw')::numeric / e.fx_rate)::int end,
    upper(coalesce(nullif(x->>'currency',''), 'KRW')),
    case upper(coalesce(nullif(x->>'currency',''),'KRW'))
      when 'JPY' then e.fx_rate when 'USD' then e.fx_usd else 1 end,
    case upper(coalesce(nullif(x->>'currency',''),'KRW'))
      when 'JPY' then round((x->>'amount_krw')::numeric / e.fx_rate)
      when 'USD' then round((x->>'amount_krw')::numeric / e.fx_usd, 2)
      else (x->>'amount_krw')::numeric end,
    v_exp
  from jsonb_array_elements(p_rows) as x
  returning *;
end;
$$;

revoke all on function public.taam_kashikiri_send(uuid, jsonb) from public;
grant execute on function public.taam_kashikiri_send(uuid, jsonb) to authenticated;


-- ── ③ 아직 안 보낸 금액 — 화면이 「얼마 남았나」를 보여줄 수 있게 ──
create or replace function public.taam_kashikiri_remaining(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare e public.kashikiri_events%rowtype; v_sent bigint; v_paid bigint;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into e from public.kashikiri_events where id = p_event_id;
  if not found then return null; end if;

  select coalesce(sum(amount_krw) filter (where status <> 'cancelled'), 0),
         coalesce(sum(amount_krw) filter (where status = 'paid'), 0)
    into v_sent, v_paid
    from public.kashikiri_charges where event_id = e.id;

  return jsonb_build_object(
    'total_krw', e.total_krw,
    'sent_krw',  v_sent,
    'paid_krw',  v_paid,
    -- 총액을 안 적었으면 「남은 금액」이라는 것도 없다
    'left_krw',  case when coalesce(e.total_krw,0) > 0
                      then e.total_krw - v_sent end
  );
end;
$$;

revoke all on function public.taam_kashikiri_remaining(uuid) from public;
grant execute on function public.taam_kashikiri_remaining(uuid) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 토큰이 만들어지나' as "구분",
       case when length(public.taam_kashikiri_token()) = 32 then '✅ 32자'
            else '❌ ' || coalesce(public.taam_kashikiri_token(), 'null') end as "상태",
       '' as "값"

union all
select '② pgcrypto 에 안 기대나',
       case when prosrc like '%gen_random_uuid%' and prosrc not like '%gen_random_bytes%'
            then '✅' else '❌ 아직 gen_random_bytes' end, ''
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_kashikiri_token'

union all
select '③ 합계는 넘을 때만 막나',
       case when prosrc like '%정산 총액을 넘습니다%' then '✅' else '❌ 아직 「같아야」' end, ''
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_kashikiri_send'

union all
select '④ 남은 금액 함수',
       case when exists (select 1 from pg_proc
                          where pronamespace='public'::regnamespace
                            and proname='taam_kashikiri_remaining')
            then '✅' else '❌ 없음' end, ''

 order by 1;
