-- ═══════════════════════════════════════════════════════════════
-- TAAM — 「정산 링크 보내기」로 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 바뀌나
--   화면의 이름이 「대관 정산」에서 「정산 링크 보내기」가 된다. 이름만
--   바뀌는 게 아니라 하는 일이 바뀐다 — 조를 짜고 나누는 게 아니라,
--   **받을 사람 목록을 만들어 한 번에 보내는** 것이 중심이 된다.
--
--   ① 청구가 조(team) 없이도 설 수 있어야 한다
--      티켓 구매자가 아닌 사람에게도 보낸다(동행·별도 정산). 그 사람은
--      어느 조에도 속하지 않는다. team_id 를 NOT NULL 로 둔 채로는
--      그 사람을 담을 곳이 없다.
--   ② 보낼 번호를 청구에 담는다
--      ⚠ kashikiri_guests 에는 여전히 전화번호 컬럼을 만들지 않는다.
--        그 표는 셰프에게 나가는 게스트 시트의 재료다. 번호는 **보내기
--        위한 것**이라 청구에만 있으면 된다. 두 표를 갈라 두는 이유다.
--   ③ 발송은 「덮어쓰기」가 아니라 「추가」다
--      taam_kashikiri_split 은 팀 청구를 통째로 지우고 다시 만들었다.
--      보내기에는 그 의미가 안 맞는다 — 이미 보낸 링크를 지우면 그걸
--      받은 사람은 「없는 링크입니다」를 보게 된다. 한 명이 더 생기면
--      그 한 명만 더한다.
--   ④ 회차에 정산 총액을 둔다
--      총액을 적어 두면 합계가 어긋날 때 서버가 막는다. 안 적으면 대조할
--      기준이 없으므로 막지 않는다 — 없는 기준으로 막는 시늉을 하지 않는다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ sql/kashikiri.sql · sql/kashikiri_link.sql 다음에 실행한다.
--   읽는 법: 맨 아래 표에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════

alter table public.kashikiri_charges alter column team_id drop not null;
alter table public.kashikiri_charges add column if not exists payer_phone text;
alter table public.kashikiri_events  add column if not exists total_jpy integer;
alter table public.kashikiri_events  add column if not exists total_krw integer;

comment on column public.kashikiri_charges.team_id is
  '어느 조에서 나온 청구인가. 구매자가 아닌 사람(추가 발송)은 null.';
comment on column public.kashikiri_charges.payer_phone is
  '링크를 보낼 번호. 게스트 시트에는 나가지 않는다 — 그 표에는 컬럼 자체가 없다.';
comment on column public.kashikiri_events.total_krw is
  '이 회차의 정산 총액(원). 적어 두면 청구 합계가 어긋날 때 서버가 막는다.';


-- ─────────────────────────────────────────────────────────────
-- 보내기 — 받을 사람들을 청구로 만든다 (추가만 한다)
-- ─────────────────────────────────────────────────────────────
--   p_rows: [{"label":"김우종","phone":"01000000000","amount_krw":1051875,
--             "user_id":null,"team_id":null,"guest_id":null,"amount_jpy":112500}, …]
--
--   ⚠ 지우지 않는다. 이미 보낸 링크는 그대로 살아 있다.
--     빼야 할 사람은 taam_kashikiri_charge_cancel 로 한 건씩 끊는다.
create or replace function public.taam_kashikiri_send(
  p_event_id uuid,
  p_rows     jsonb
)
returns setof public.kashikiri_charges
language plpgsql volatile security definer set search_path = public
as $$
declare
  e        public.kashikiri_events%rowtype;
  r        jsonb;
  v_new    bigint := 0;
  v_have   bigint := 0;
  v_exp    timestamptz;
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
    v_new := v_new + (r->>'amount_krw')::bigint;
  end loop;

  -- 총액을 적어 둔 회차만 대조한다. 없으면 대조할 기준이 없다 —
  -- 없는 기준으로 막는 시늉을 하지 않는다.
  if coalesce(e.total_krw, 0) > 0 then
    select coalesce(sum(amount_krw), 0) into v_have
      from public.kashikiri_charges
     where event_id = e.id and status <> 'cancelled';
    if (v_have + v_new) <> e.total_krw then
      raise exception '보낼 합계가 정산 총액과 다릅니다 (이미 % + 이번 % = %, 총액 %)',
        v_have, v_new, v_have + v_new, e.total_krw using errcode = '22023';
    end if;
  end if;

  -- 링크 만료는 방문일 + 3일. 짧으면 못 낸 사람이 생기고, 길면 잊힌다.
  v_exp := (e.event_date + interval '3 day');

  return query
  insert into public.kashikiri_charges
    (event_id, team_id, guest_id, label, user_id, payer_phone,
     amount_krw, amount_jpy, expires_at)
  select
    e.id,
    nullif(x->>'team_id','')::uuid,
    nullif(x->>'guest_id','')::uuid,
    trim(x->>'label'),
    nullif(x->>'user_id','')::uuid,
    nullif(regexp_replace(coalesce(x->>'phone',''), '[^0-9]', '', 'g'), ''),
    (x->>'amount_krw')::int,
    nullif(x->>'amount_jpy','')::int,
    v_exp
  from jsonb_array_elements(p_rows) as x
  returning *;
end;
$$;

revoke all on function public.taam_kashikiri_send(uuid, jsonb) from public;
grant execute on function public.taam_kashikiri_send(uuid, jsonb) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 한 건 끊기 — 잘못 보낸 링크를 죽인다
-- ─────────────────────────────────────────────────────────────
--   지우지 않고 cancelled 로 남긴다. 지워 버리면 「그런 링크 받았는데요」
--   에 답할 근거가 사라진다.
create or replace function public.taam_kashikiri_charge_cancel(p_charge_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare c public.kashikiri_charges%rowtype;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into c from public.kashikiri_charges where id = p_charge_id;
  if not found then raise exception '청구를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if c.status = 'paid' then
    raise exception '이미 결제된 건은 끊을 수 없습니다 — 환불로 처리하세요' using errcode = '55000';
  end if;
  update public.kashikiri_charges set status = 'cancelled' where id = c.id;
  return jsonb_build_object('ok', true, 'label', c.label);
end;
$$;

revoke all on function public.taam_kashikiri_charge_cancel(uuid) from public;
grant execute on function public.taam_kashikiri_charge_cancel(uuid) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 링크로 청구 읽기 — 조가 없어도 열려야 한다 ⚠ 고침
-- ─────────────────────────────────────────────────────────────
--   sql/kashikiri.sql 의 것은 kashikiri_teams 를 **inner join** 했다.
--   그때는 모든 청구가 조에서 나왔으니 문제가 없었다. 이제 구매자가
--   아닌 사람에게도 보내는데, 그 청구는 team_id 가 null 이라 조인에서
--   통째로 떨어져 **링크가 아예 안 열린다.** 새 흐름의 핵심이 막히는 자리다.
--   left join 으로 바꾸고, 조가 없을 때의 표시를 따로 정한다.
create or replace function public.taam_kashikiri_charge_public(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;

  select jsonb_build_object(
    'id',          c.id,
    'label',       c.label,
    'amount_krw',  c.amount_krw,
    'amount_jpy',  c.amount_jpy,
    'status',      c.status,
    'expires_at',  c.expires_at,
    'paid_at',     c.approved_at,
    'receipt_url', c.receipt_url,
    'venue_name',  e.venue_name,
    'event_date',  e.event_date,
    'event_time',  e.event_time,
    'fx_rate',     e.fx_rate,
    'fx_note',     e.fx_note,
    'team_seq',    t.seq,
    'team_pax',    t.pax,
    -- 「4인 중 1인 몫」을 위한 최소한. 조가 없으면 회차 전체에서 센다.
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
  left join public.kashikiri_teams t on t.id = c.team_id   -- ⚠ left
  where c.token = p_token;

  return v;
end;
$$;

revoke all on function public.taam_kashikiri_charge_public(text) from public;
grant execute on function public.taam_kashikiri_charge_public(text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 티켓 구매자 읽기 — 화면이 받는 사람 목록을 채울 재료
-- ─────────────────────────────────────────────────────────────
--   tickets 를 앱에서 직접 조회하면 RLS 에 걸린다(회원 소유 행이다).
--   슈퍼어드민만 부를 수 있는 함수로 필요한 것만 돌려준다.
--   ⚠ 금액은 돌려주지 않는다. 티켓 가격은 「예약금」이고 정산 금액은
--     현장에서 나온다 — 화면에 같이 띄우면 반드시 섞인다.
create or replace function public.taam_kashikiri_buyers(p_ticket_product_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  if coalesce(p_ticket_product_id, '') = '' then return '[]'::jsonb; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'ticket_id', t.id,
           'user_id',   t.user_id,
           'name',      coalesce(nullif(trim(t.buyer_name), ''),
                                 nullif(trim(p.display_name), ''), '구매자'),
           'phone',     coalesce(nullif(trim(t.buyer_phone), ''), nullif(trim(p.phone), '')),
           'pax',       coalesce(t.party_size, 1),
           'visit_date', t.reservation_date
         ) order by t.created_at), '[]'::jsonb)
    into v
    from public.tickets t
    left join public.profiles p on p.id = t.user_id
   where t.ticket_product_id = p_ticket_product_id
     and coalesce(t.status, '') = 'active';

  return v;
end;
$$;

revoke all on function public.taam_kashikiri_buyers(text) from public;
grant execute on function public.taam_kashikiri_buyers(text) to authenticated;

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
  from (values ('kashikiri_charges','payer_phone'),
               ('kashikiri_events','total_krw'),
               ('kashikiri_events','total_jpy')) as c(t, n)

union all
select '② team_id 가 비어도 되나', 'kashikiri_charges.team_id',
       case when a.attnotnull then '❌ 아직 NOT NULL' else '✅ 가능' end
  from pg_attribute a
 where a.attrelid = 'public.kashikiri_charges'::regclass and a.attname = 'team_id'

union all
select '③ 함수', p.name,
       case when not exists (
              select 1 from pg_proc pr
               where pr.pronamespace = 'public'::regnamespace and pr.proname = p.name)
            then '❌ 없음' else '✅' end
  from (values ('taam_kashikiri_send'),
               ('taam_kashikiri_charge_cancel'),
               ('taam_kashikiri_buyers')) as p(name)

union all
select '④ 게스트 시트에 번호 컬럼 없음', 'kashikiri_guests',
       case when exists (
              select 1 from pg_attribute a
               where a.attrelid = 'public.kashikiri_guests'::regclass
                 and a.attname ilike '%phone%' and a.attnum > 0 and not a.attisdropped)
            then '❌ 생겼다' else '✅ 없음' end

 order by 1, 2;
