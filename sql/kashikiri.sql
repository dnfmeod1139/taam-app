-- ═══════════════════════════════════════════════════════════════
-- TAAM — 대관(貸切): 회차 · 팀 · 분할 청구 · 게스트 시트 (2026-09-01)
-- ═══════════════════════════════════════════════════════════════
-- 무엇을 푸는가
--   대관이 끝나면 한 팀이 한 장으로 나온다. 그런데 그 팀에서 탐 회원은
--   보통 한 명이다. 나머지는 현금을 꺼내야 하고 그 순간이 제일 어색하다.
--   카드는 「1건 = 1명 = 1승인」이라 나눠 낼 방법은 하나뿐이다 —
--   **결제를 N개로 쪼개 각자에게 링크를 보낸다.**
--
-- 왜 payment_orders 를 쓰지 않는가
--   payment_orders.user_id 가 NOT NULL 이다. 동행 비회원은 user_id 가 없다.
--   그 컬럼을 nullable 로 바꾸면 실결제로 검증된 티켓·충전 경로까지 흔들린다.
--   그래서 **청구 행이 곧 주문**이다 (order_id·payment_key 를 자기가 들고 있다).
--   기존 결제 경로는 한 줄도 건드리지 않는다.
--
-- 셰프에게 돈을 감추는 방법
--   화면에서 숨기는 건 방어가 아니다. **venue_admins 에게는 RLS 정책을
--   아예 만들지 않는다** — 이 표들은 매장 어드민 세션에서 조회 자체가 안 된다.
--   게스트 시트는 아래 taam_kashikiri_sheet_public() 이 **필요한 컬럼만 골라**
--   돌려준다. 개발자 도구를 열어도 금액이 없다.
--   단 하나 예외: 「그 매장에서의 지난 회계」는 원래 그 매장 매출이라 보여준다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ 앱보다 **먼저** 실행한다. 반대로 하면 앱이 없는 함수를 부른다.
--   읽는 법: 맨 아래 표에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- 링크 토큰. 32자 hex — 눌러서 여는 것이라 길이는 문제가 안 되고,
-- 짧게 만들어 얻는 것보다 추측당해 잃는 것이 훨씬 크다.
create or replace function public.taam_kashikiri_token()
returns text language sql volatile as $$
  select encode(gen_random_bytes(16), 'hex');
$$;


-- ─────────────────────────────────────────────────────────────
-- 1) kashikiri_events — 대관 회차
-- ─────────────────────────────────────────────────────────────
create table if not exists public.kashikiri_events (
  id             uuid primary key default gen_random_uuid(),
  venue_id       text not null,                    -- restaurantDB.id (text)
  venue_name     text,                             -- 스냅샷 (매장이 이름을 바꿔도 회차는 그대로)
  event_date     date not null,
  event_time     time,
  total_pax      integer not null default 0,
  -- 인솔 여부는 **회차마다 반드시 값이 있다.** 없는 회차가 생기면
  -- 게스트 시트의 그 표시 자체가 의미를 잃는다.
  escort         boolean not null default true,
  status         text not null default 'draft'
                   check (status in ('draft','open','settling','closed','cancelled')),
  -- 환율은 회차에 못 박는다. 나중에 환율이 변해도 이 회차의 숫자는 안 변한다.
  fx_rate        numeric(12,4),
  fx_note        text,
  venue_paid_jpy integer,                          -- 매장에 실제로 지급한 엔화 총액
  -- 게스트 시트 토큰. 회차 단위로 만료된다.
  sheet_token    text unique,
  sheet_expires  timestamptz,
  memo           text,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_ke_venue on public.kashikiri_events(venue_id, event_date desc);
create index if not exists idx_ke_date  on public.kashikiri_events(event_date desc);
comment on table public.kashikiri_events is '대관 회차. 팀·청구·게스트 시트가 여기에 매달린다.';


-- ─────────────────────────────────────────────────────────────
-- 2) kashikiri_teams — 회차 안의 조(組)
-- ─────────────────────────────────────────────────────────────
create table if not exists public.kashikiri_teams (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.kashikiri_events(id) on delete cascade,
  seq           integer not null default 1,        -- 1組 · 2組 … 착석 순서
  host_user_id  uuid references auth.users(id) on delete set null,
  host_label    text,                              -- 게스트 시트 표기 (예: 'K様')
  pax           integer not null default 1 check (pax > 0),
  total_jpy     integer,                           -- 현장 확정 엔화
  total_krw     integer,                           -- 환율 적용 결과 (분할 합계는 이 값과 같아야 한다)
  drink_note    text,                              -- 주류 성향 (금액 아님)
  allergy_note  text,
  memo          text,
  created_at    timestamptz not null default now(),
  unique (event_id, seq)
);
create index if not exists idx_kt_event on public.kashikiri_teams(event_id, seq);
create index if not exists idx_kt_host  on public.kashikiri_teams(host_user_id);
comment on table public.kashikiri_teams is '대관 회차의 조. 확정 금액과 분할의 단위.';


-- ─────────────────────────────────────────────────────────────
-- 3) kashikiri_guests — 게스트 시트용 인원 (결제와 무관)
-- ─────────────────────────────────────────────────────────────
--   ⚠ 전화번호 컬럼을 두지 않는다. 없는 것은 샐 수 없다.
create table if not exists public.kashikiri_guests (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.kashikiri_teams(id) on delete cascade,
  seq           integer not null default 1,
  display_name  text not null,                     -- 姓 + 様 만. 'P様'
  user_id       uuid references auth.users(id) on delete set null,
  is_host       boolean not null default false,
  visit_count   integer default 0,                 -- **그 매장** 방문 횟수 (스냅샷)
  drink_note    text,
  allergy_note  text,
  memo          text,                              -- 지난 방문 시 제공 내역·반응
  created_at    timestamptz not null default now()
);
create index if not exists idx_kg_team on public.kashikiri_guests(team_id, seq);
comment on table public.kashikiri_guests is
  '게스트 시트에 나가는 인원. 姓+様 만 적고 전화번호는 컬럼 자체가 없다.';


-- ─────────────────────────────────────────────────────────────
-- 4) kashikiri_charges — 개인별 청구 = 결제 링크 1건 = 주문 1건
-- ─────────────────────────────────────────────────────────────
create table if not exists public.kashikiri_charges (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.kashikiri_events(id) on delete cascade,
  team_id      uuid not null references public.kashikiri_teams(id) on delete cascade,
  guest_id     uuid references public.kashikiri_guests(id) on delete set null,
  label        text not null,                      -- 'K様' · '동행 1'
  -- 회원이면 user_id 가 있고 앱 푸시 → 등록카드(빌링).
  -- 비회원이면 null 이고 링크로 결제한다. 이 하나로 두 경로가 갈린다.
  user_id      uuid references auth.users(id) on delete set null,
  amount_krw   integer not null check (amount_krw > 0),
  amount_jpy   integer,
  token        text not null unique default public.taam_kashikiri_token(),
  status       text not null default 'pending'
                 check (status in ('pending','paid','cancelled','expired','failed')),
  -- 이 행이 곧 주문이다 (payment_orders 를 쓰지 않는 이유는 파일 머리말 참고)
  order_id     text unique,
  payment_key  text,
  method       text,
  receipt_url  text,
  fail_reason  text,
  payer_name   text,                               -- 결제자가 링크에서 직접 적는다
  approved_at  timestamptz,
  expires_at   timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists idx_kc_event on public.kashikiri_charges(event_id);
create index if not exists idx_kc_team  on public.kashikiri_charges(team_id);
create index if not exists idx_kc_user  on public.kashikiri_charges(user_id, status);
comment on table public.kashikiri_charges is
  '대관 분할 청구. 한 행 = 한 사람 = 한 결제. 회원은 빌링, 비회원은 링크.';


-- ─────────────────────────────────────────────────────────────
-- 5) RLS — 매장 어드민에게는 정책을 만들지 않는다
-- ─────────────────────────────────────────────────────────────
--   ⚠ 먼저 테이블 권한을 명시로 준다. Supabase 는 public 스키마에 기본
--     권한을 걸어두지만, 그건 「그렇게 설정돼 있을 것」에 기대는 것이다.
--     RLS 는 권한이 있는 다음에 거르는 체다 — 권한이 없으면 정책을 아무리
--     잘 써도 42501 만 난다. 실제로 이 검증에서 그렇게 막혔다.
grant select on public.kashikiri_events, public.kashikiri_teams,
                public.kashikiri_charges to authenticated;
grant insert, update, delete on public.kashikiri_events, public.kashikiri_teams,
                public.kashikiri_guests, public.kashikiri_charges to authenticated;
grant select on public.kashikiri_guests to authenticated;
-- anon 에게는 표 권한을 주지 않는다. 링크 페이지는 SECURITY DEFINER 함수로만 읽는다.

alter table public.kashikiri_events  enable row level security;
alter table public.kashikiri_teams   enable row level security;
alter table public.kashikiri_guests  enable row level security;
alter table public.kashikiri_charges enable row level security;

-- 슈퍼어드민: 전부
drop policy if exists "ke_super" on public.kashikiri_events;
create policy "ke_super" on public.kashikiri_events for all
  using (is_super_admin(auth.uid())) with check (is_super_admin(auth.uid()));
drop policy if exists "kt_super" on public.kashikiri_teams;
create policy "kt_super" on public.kashikiri_teams for all
  using (is_super_admin(auth.uid())) with check (is_super_admin(auth.uid()));
drop policy if exists "kg_super" on public.kashikiri_guests;
create policy "kg_super" on public.kashikiri_guests for all
  using (is_super_admin(auth.uid())) with check (is_super_admin(auth.uid()));
drop policy if exists "kc_super" on public.kashikiri_charges;
create policy "kc_super" on public.kashikiri_charges for all
  using (is_super_admin(auth.uid())) with check (is_super_admin(auth.uid()));

-- 회원: **읽기만.** 자기 청구와 자기가 호스트인 팀·회차까지.
--   금액을 회원이 고치면 안 되므로 update 정책은 아예 주지 않는다.
drop policy if exists "kc_mine" on public.kashikiri_charges;
create policy "kc_mine" on public.kashikiri_charges for select
  using (user_id = auth.uid());

drop policy if exists "kt_host" on public.kashikiri_teams;
create policy "kt_host" on public.kashikiri_teams for select
  using (
    host_user_id = auth.uid()
    or exists (select 1 from public.kashikiri_charges c
                where c.team_id = kashikiri_teams.id and c.user_id = auth.uid())
  );

drop policy if exists "ke_host" on public.kashikiri_events;
create policy "ke_host" on public.kashikiri_events for select
  using (
    exists (select 1 from public.kashikiri_teams t
             where t.event_id = kashikiri_events.id and t.host_user_id = auth.uid())
    or exists (select 1 from public.kashikiri_charges c
                where c.event_id = kashikiri_events.id and c.user_id = auth.uid())
  );

-- kashikiri_guests 에는 회원 정책도 두지 않는다.
--   남의 알레르기·주류 취향은 같은 자리에 있었다고 볼 권리가 생기지 않는다.
--   셰프에게는 아래 sheet_public() 이 골라서 준다.


-- ─────────────────────────────────────────────────────────────
-- 6) 분할 — 팀 하나를 N개 청구로 쪼갠다 (슈퍼어드민)
-- ─────────────────────────────────────────────────────────────
--   p_rows: [{"label":"K様","user_id":"…또는 null","amount_krw":1051875,"guest_id":null}, …]
--   합계가 팀 확정액과 **1원이라도 다르면 통째로 거절**한다.
--   이미 결제된 청구가 있으면 거절한다 — 낸 사람 몫을 조용히 지우지 않는다.
create or replace function public.taam_kashikiri_split(
  p_team_id uuid,
  p_rows    jsonb
)
returns setof public.kashikiri_charges
language plpgsql volatile security definer set search_path = public
as $$
declare
  t         public.kashikiri_teams%rowtype;
  v_sum     bigint := 0;
  v_paid    int;
  r         jsonb;
  v_exp     timestamptz;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;

  select * into t from public.kashikiri_teams where id = p_team_id;
  if not found then raise exception '팀을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if coalesce(t.total_krw, 0) <= 0 then
    raise exception '팀 확정 금액이 없습니다 — 먼저 금액을 입력하세요' using errcode = '22023';
  end if;

  select count(*) into v_paid from public.kashikiri_charges
   where team_id = p_team_id and status = 'paid';
  if v_paid > 0 then
    raise exception '이미 결제된 청구가 있습니다 (%건). 먼저 취소한 뒤 다시 나누세요', v_paid
      using errcode = '55000';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception '나눌 내역이 없습니다' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce((r->>'amount_krw')::bigint, 0) <= 0 then
      raise exception '0원 이하 청구는 만들 수 없습니다' using errcode = '22023';
    end if;
    v_sum := v_sum + (r->>'amount_krw')::bigint;
  end loop;

  if v_sum <> t.total_krw then
    raise exception '분할 합계(%)가 팀 확정 금액(%)과 다릅니다', v_sum, t.total_krw
      using errcode = '22023';
  end if;

  -- 아직 아무도 안 냈으므로 통째로 지우고 다시 만든다
  delete from public.kashikiri_charges where team_id = p_team_id;

  -- 링크 만료는 방문일 + 3일. 짧으면 못 낸 사람이 생기고, 길면 잊힌다.
  select (e.event_date + interval '3 day') into v_exp
    from public.kashikiri_events e where e.id = t.event_id;

  return query
  insert into public.kashikiri_charges
    (event_id, team_id, guest_id, label, user_id, amount_krw, amount_jpy, expires_at)
  select
    t.event_id, t.id,
    nullif(x->>'guest_id','')::uuid,
    coalesce(nullif(x->>'label',''), '동행'),
    nullif(x->>'user_id','')::uuid,
    (x->>'amount_krw')::int,
    nullif(x->>'amount_jpy','')::int,
    v_exp
  from jsonb_array_elements(p_rows) as x
  returning *;
end;
$$;

revoke all on function public.taam_kashikiri_split(uuid, jsonb) from public;
grant execute on function public.taam_kashikiri_split(uuid, jsonb) to authenticated;


-- ─────────────────────────────────────────────────────────────
-- 7) 링크로 청구 하나 읽기 (로그인 없음)
-- ─────────────────────────────────────────────────────────────
--   anon 이 부른다. 토큰을 아는 사람에게만, **그 청구 한 건만** 준다.
--   회차의 다른 팀·다른 사람·매장 지급액은 한 글자도 나가지 않는다.
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
    -- 「4인 중 1인 몫」을 보여주기 위한 최소한. 남의 금액은 안 준다.
    'split_count', (select count(*) from public.kashikiri_charges x where x.team_id = t.id)
  ) into v
  from public.kashikiri_charges c
  join public.kashikiri_events e on e.id = c.event_id
  join public.kashikiri_teams  t on t.id = c.team_id
  where c.token = p_token;

  return v;
end;
$$;

revoke all on function public.taam_kashikiri_charge_public(text) from public;
grant execute on function public.taam_kashikiri_charge_public(text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 8) 결제 시작 — 주문번호와 금액을 **서버가** 정한다
-- ─────────────────────────────────────────────────────────────
--   브라우저가 금액을 정하면 그걸로 끝이다. 금액은 언제나 DB 에서 나온다.
--   이미 낸 건이면 아무 일도 안 일어난다(멱등).
create or replace function public.taam_kashikiri_order_start(
  p_token text,
  p_name  text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare c public.kashikiri_charges%rowtype; v_order text;
begin
  select * into c from public.kashikiri_charges where token = p_token;
  if not found then raise exception '없는 링크입니다' using errcode = 'P0002'; end if;
  if c.status = 'paid' then
    return jsonb_build_object('already_paid', true, 'order_id', c.order_id);
  end if;
  if c.status in ('cancelled','expired') then
    return jsonb_build_object('blocked', c.status);
  end if;
  -- ⚠ 기간이 지났으면 상태를 'expired' 로 굳히고 **돌려준다.**
  --   종전엔 update 한 뒤 raise 했는데, 예외가 그 update 까지 되돌려서
  --   상태가 영영 pending 으로 남았다 (같은 트랜잭션이니 당연한 일인데
  --   「기록은 남겠지」라고 착각하기 쉽다). 막는 건 값으로 알린다.
  if c.expires_at is not null and now() > c.expires_at then
    update public.kashikiri_charges set status = 'expired' where id = c.id;
    return jsonb_build_object('blocked', 'expired');
  end if;

  -- 주문번호는 한 번만 만든다. 결제창을 닫았다 다시 열어도 같은 번호로 이어진다.
  v_order := coalesce(c.order_id, 'KSK-' || replace(c.id::text, '-', '') );

  update public.kashikiri_charges
     set order_id   = v_order,
         payer_name = coalesce(nullif(trim(p_name), ''), payer_name)
   where id = c.id;

  return jsonb_build_object(
    'order_id',   v_order,
    'amount_krw', c.amount_krw,
    'order_name', '[TAAM] ' || to_char((select event_date from public.kashikiri_events where id = c.event_id), 'MM/DD')
                  || ' ' || coalesce((select venue_name from public.kashikiri_events where id = c.event_id), '대관')
  );
end;
$$;

revoke all on function public.taam_kashikiri_order_start(text, text) from public;
grant execute on function public.taam_kashikiri_order_start(text, text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────
-- 9) 결제 확정 — service_role 만 (Edge Function 이 승인 뒤 부른다)
-- ─────────────────────────────────────────────────────────────
create or replace function public.taam_kashikiri_mark_paid(
  p_order_id   text,
  p_payment_key text,
  p_amount     bigint,
  p_method     text default null,
  p_receipt    text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare c public.kashikiri_charges%rowtype;
begin
  select * into c from public.kashikiri_charges where order_id = p_order_id;
  if not found then raise exception '주문을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if c.status = 'paid' then
    return jsonb_build_object('ok', true, 'already', true);   -- 멱등
  end if;
  -- 승인 금액이 청구 금액과 다르면 확정하지 않는다.
  if p_amount is distinct from c.amount_krw::bigint then
    raise exception '승인 금액(%)이 청구 금액(%)과 다릅니다', p_amount, c.amount_krw
      using errcode = '22023';
  end if;

  update public.kashikiri_charges
     set status = 'paid', payment_key = p_payment_key, method = p_method,
         receipt_url = p_receipt, approved_at = now()
   where id = c.id;

  return jsonb_build_object('ok', true, 'charge_id', c.id);
end;
$$;

revoke all on function public.taam_kashikiri_mark_paid(text, text, bigint, text, text) from public;
-- authenticated 에게도 주지 않는다. service_role 만 부른다.


-- ─────────────────────────────────────────────────────────────
-- 10) 게스트 시트 — 셰프에게 나가는 유일한 창구
-- ─────────────────────────────────────────────────────────────
--   ⚠ 여기서 **한 번도 금액 컬럼을 select 하지 않는다.**
--     kashikiri_teams.total_jpy / total_krw · kashikiri_charges 전체가 빠져 있다.
--     화면에서 감추는 게 아니라 데이터가 아예 안 나간다.
--   ⚠ 딱 하나 나가는 금액은 「그 매장에서의 지난 회계」다. 그건 원래
--     그 매장 매출이라 매장이 이미 아는 숫자이고, 셰프에게 가장 쓸모 있다.
create or replace function public.taam_kashikiri_sheet_public(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare e public.kashikiri_events%rowtype; v jsonb;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;
  select * into e from public.kashikiri_events where sheet_token = p_token;
  if not found then return null; end if;
  if e.sheet_expires is not null and now() > e.sheet_expires then
    return jsonb_build_object('expired', true);
  end if;

  select jsonb_build_object(
    'venue_name', e.venue_name,
    'event_date', e.event_date,
    'event_time', e.event_time,
    'total_pax',  e.total_pax,
    'escort',     e.escort,
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq',          t.seq,
               'pax',          t.pax,
               'host_label',   t.host_label,
               'drink_note',   t.drink_note,
               'allergy_note', t.allergy_note,
               'guests', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'name',        g.display_name,
                          'is_host',     g.is_host,
                          'visit_count', g.visit_count,
                          'drink_note',  g.drink_note,
                          'allergy',     g.allergy_note,
                          'memo',        g.memo,
                          -- 그 매장에서의 지난 회계만. 타 매장은 조회 자체를 안 한다.
                          'last_spend',  (
                            select tk.price from public.tickets tk
                             where tk.user_id = g.user_id
                               and tk.restaurant_id = e.venue_id
                               and tk.visit_status = 'attended'
                               and coalesce(tk.status,'') not in ('cancelled','canceled')
                             order by tk.reservation_date desc limit 1),
                          'last_visit',  (
                            select tk.reservation_date from public.tickets tk
                             where tk.user_id = g.user_id
                               and tk.restaurant_id = e.venue_id
                               and tk.visit_status = 'attended'
                               and coalesce(tk.status,'') not in ('cancelled','canceled')
                             order by tk.reservation_date desc limit 1)
                        ) order by g.seq)
                 from public.kashikiri_guests g where g.team_id = t.id), '[]'::jsonb)
             ) order by t.seq)
      from public.kashikiri_teams t where t.event_id = e.id), '[]'::jsonb)
  ) into v;

  return v;
end;
$$;

revoke all on function public.taam_kashikiri_sheet_public(text) from public;
grant execute on function public.taam_kashikiri_sheet_public(text) to anon, authenticated;


-- 게스트 시트 링크 발급 (슈퍼어드민). 다시 부르면 토큰이 새로 나온다 —
-- 셰프가 남에게 넘긴 링크를 끊는 유일한 방법이다.
create or replace function public.taam_kashikiri_sheet_link(
  p_event_id uuid,
  p_days     integer default 3
)
returns text
language plpgsql volatile security definer set search_path = public
as $$
declare v_tok text; v_date date;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select event_date into v_date from public.kashikiri_events where id = p_event_id;
  if not found then raise exception '회차를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  v_tok := public.taam_kashikiri_token();
  update public.kashikiri_events
     set sheet_token = v_tok,
         sheet_expires = (v_date + make_interval(days => greatest(1, coalesce(p_days,3))))
   where id = p_event_id;
  return v_tok;
end;
$$;

revoke all on function public.taam_kashikiri_sheet_link(uuid, integer) from public;
grant execute on function public.taam_kashikiri_sheet_link(uuid, integer) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다 (SQL Editor 는 마지막 결과만 보여준다)
-- ═══════════════════════════════════════════════════════════════
select '① 표' as "구분", c.name as "이름",
       case when to_regclass('public.' || c.name) is null then '❌ 없음' else '✅' end as "상태"
  from (values ('kashikiri_events'),('kashikiri_teams'),
               ('kashikiri_guests'),('kashikiri_charges')) as c(name)

union all
select '② 함수', p.name,
       case when not exists (
              select 1 from pg_proc pr
               where pr.pronamespace = 'public'::regnamespace and pr.proname = p.name)
            then '❌ 없음' else '✅' end
  from (values ('taam_kashikiri_token'),('taam_kashikiri_split'),
               ('taam_kashikiri_charge_public'),('taam_kashikiri_order_start'),
               ('taam_kashikiri_mark_paid'),('taam_kashikiri_sheet_public'),
               ('taam_kashikiri_sheet_link')) as p(name)

union all
select '③ RLS 켜짐', c.relname,
       case when c.relrowsecurity then '✅' else '❌ 꺼짐' end
  from pg_class c
 where c.relnamespace = 'public'::regnamespace
   and c.relname in ('kashikiri_events','kashikiri_teams','kashikiri_guests','kashikiri_charges')

union all
-- 매장 어드민용 정책이 하나라도 있으면 안 된다 (셰프에게 돈이 새는 길)
select '④ 매장 어드민 정책 없음', 'kashikiri_*',
       case when count(*) = 0 then '✅ 없음' else '❌ ' || count(*)::text || '건 있음' end
  from pg_policies
 where schemaname = 'public'
   and tablename like 'kashikiri_%'
   and qual ilike '%venue_admin%'

 order by 1, 2;
