-- ═══════════════════════════════════════════════════════════════
-- TAAM — ② 공개 대상: 누가 이 티켓을 볼 수 있나 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- ①(ticket_visit_record.sql)이 먼저다. taam_visit_count 를 쓴다.
--
-- 이미 있는 것 위에 얹는다 — 두 벌 만들지 않는다
--   ticket_access_lists   티켓별 allow(전용) / block(차단) 명단.  ✅ 그대로 쓴다
--   ticket_products.min_tier  등급 하한.                          ✅ 그대로 쓴다
--
-- 없어서 만드는 것
--   visit_tier_rules      매장별 「단골 몇 회부터」 기준
--   member_bans           계정 단위 이용 제한 — 모든 티켓에서 자동 제외
--   ticket_products.audience  조건(등급 × 방문 이력)
--
-- ⚠ 같이 고치는 보안 구멍
--   can_manage_ticket_access(p_ticket_id) 가 **인자를 안 쓴다.**
--   role in ('admin','partner') 이기만 하면 남의 매장 티켓 명단도 관리된다.
--   원본 주석에 「앱 측 가드 신뢰」라고 적혀 있다 — 앱을 거치지 않은 요청은
--   그대로 통과한다. 실제 매장 소유를 확인하도록 바꾼다.
--
-- ⚠ 이 SQL 은 앱 배포와 무관하다. audience 가 비어 있으면 지금과 똑같이 돈다.
--
-- 실행: Supabase SQL Editor. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══════════════════════════════════════════════════════════════
-- ① 매장별 방문 등급 기준
-- ═══════════════════════════════════════════════════════════════
--   restaurant_id = '*' 행이 기본값이다. 매장 행이 있으면 그것이 이긴다.
--   한 달에 한 번 여는 가게와 매주 여는 가게에서 「단골」이 같은 수일 수 없다.

create table if not exists public.visit_tier_rules (
  restaurant_id text primary key,          -- restaurants.id 를 text 로. '*' = 기본
  repeat_min    integer not null default 1,   -- 재방문: 이 횟수 이상
  regular_min   integer not null default 3,   -- 단골:   이 횟수 이상
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint visit_tier_rules_order check (regular_min >= repeat_min and repeat_min >= 1)
);

insert into public.visit_tier_rules (restaurant_id, repeat_min, regular_min)
values ('*', 1, 3)
on conflict (restaurant_id) do nothing;

comment on table public.visit_tier_rules is
  '매장별 방문 등급 기준. restaurant_id=''*'' 가 기본값. 첫방문=repeat_min 미만, 재방문=repeat_min 이상, 단골=regular_min 이상.';

alter table public.visit_tier_rules enable row level security;
drop policy if exists vtr_read  on public.visit_tier_rules;
drop policy if exists vtr_write on public.visit_tier_rules;
-- 읽기는 로그인한 모두 (앱이 「나는 이 매장 단골인가」를 물을 수 있어야 한다)
create policy vtr_read on public.visit_tier_rules
  for select to authenticated using (true);
-- 쓰기는 슈퍼어드민만. 파트너가 자기 매장 기준을 낮추면 조건이 의미를 잃는다.
create policy vtr_write on public.visit_tier_rules
  for all to authenticated
  using ( public._taam_uid_is_super() )
  with check ( public._taam_uid_is_super() );


-- ═══════════════════════════════════════════════════════════════
-- ② 이용 제한 — 계정 단위
-- ═══════════════════════════════════════════════════════════════
--   ticket_access_lists 의 block 은 **티켓별**이라, 새 티켓마다 다시 넣어야 한다.
--   노쇼 반복·결제 분쟁처럼 계정 자체를 막아야 하는 경우가 그것으로는 안 된다.

create table if not exists public.member_bans (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  reason     text,
  banned_at  timestamptz not null default now(),
  banned_by  uuid,
  until      date                              -- null = 무기한
);

comment on table public.member_bans is
  '계정 단위 이용 제한. 여기 있는 회원은 모든 티켓에서 자동 제외된다 (until 이 지나면 자동 해제).';

alter table public.member_bans enable row level security;
drop policy if exists mb_read  on public.member_bans;
drop policy if exists mb_write on public.member_bans;
-- 본인은 자기 제한을 볼 수 있어야 한다 (왜 안 보이는지 물을 때 답할 수 있게)
create policy mb_read on public.member_bans
  for select to authenticated
  using ( user_id = auth.uid() or public._taam_uid_is_super() );
-- 만드는 것은 슈퍼어드민만. 매장별 블랙리스트가 생기면 관리가 갈라진다.
create policy mb_write on public.member_bans
  for all to authenticated
  using ( public._taam_uid_is_super() )
  with check ( public._taam_uid_is_super() );

create or replace function public.taam_is_banned(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.member_bans b
     where b.user_id = p_user
       and (b.until is null or b.until >= (now() at time zone 'Asia/Seoul')::date)
  )
$$;


-- ═══════════════════════════════════════════════════════════════
-- ③ 티켓의 공개 대상 조건
-- ═══════════════════════════════════════════════════════════════
--   ticket_products 에 이미 jsonb 가 넷 있다(cancel_policy·home_section·
--   ovs_prices·slots). 1:1 이라 표를 새로 파지 않고 컬럼으로 붙인다.
--
--   { "mode": "all" | "conditions",
--     "tiers": ["M"],                    // 비었으면 등급 무관
--     "visit": ["repeat","regular"] }    // 비었으면 방문 이력 무관
--                                        // first | repeat | regular
--   null 이거나 mode 가 없으면 = 지금까지와 똑같이 동작한다.

alter table public.ticket_products
  add column if not exists audience jsonb;

comment on column public.ticket_products.audience is
  '공개 대상 조건. {mode:all|conditions, tiers:[], visit:[first|repeat|regular]}. null = 전체 공개(기존 동작).';


-- ═══════════════════════════════════════════════════════════════
-- ④ 이 회원은 이 매장에서 어느 방문 등급인가
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_visit_tier(
  p_user       uuid,
  p_restaurant text
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n int;
  v_rep int;
  v_reg int;
begin
  v_n := public.taam_visit_count(p_user, p_restaurant);

  select repeat_min, regular_min into v_rep, v_reg
    from public.visit_tier_rules where restaurant_id = p_restaurant;
  if not found then
    select repeat_min, regular_min into v_rep, v_reg
      from public.visit_tier_rules where restaurant_id = '*';
  end if;
  v_rep := coalesce(v_rep, 1);
  v_reg := coalesce(v_reg, 3);

  if v_n >= v_reg then return 'regular';
  elsif v_n >= v_rep then return 'repeat';
  else return 'first';
  end if;
end;
$$;

revoke all on function public.taam_visit_tier(uuid, text) from public;
grant execute on function public.taam_visit_tier(uuid, text) to authenticated;

comment on function public.taam_visit_tier(uuid, text) is
  '이 매장에서 이 회원의 방문 등급: first | repeat | regular. 매장 기준이 없으면 ''*'' 기본을 쓴다.';


-- ═══════════════════════════════════════════════════════════════
-- ⑤ 남의 매장 명단을 못 건드리게 — 기존 함수를 고친다
-- ═══════════════════════════════════════════════════════════════
--   원본은 p_ticket_id 를 받고도 쓰지 않았다. 실제로 그 티켓의 매장을 본다.
--   ticket_products.rest_id 는 uuid, restaurant_admins.restaurant_id 는 text.

--   ⚠ 「누구로서」를 인자로 받는 판이 따로 있어야 한다.
--     visible() 이 남의 가시성을 판정할 때 auth.uid()(호출자)로 어드민 우회를
--     계산하면, 어드민이 인원수를 세는 순간 **전원이 보이는 것으로** 나온다.
--     발행 화면의 「47명」이 통째로 틀리는 종류의 버그다 (로컬 테스트에서 잡았다).

create or replace function public.taam_can_manage_ticket_as(
  p_ticket_id text,
  p_user      uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
           select 1 from public.profiles p
            where p.id = p_user and p.role in ('super_admin', 'superadmin')
         )
      or exists (
           select 1
             from public.ticket_products tp
             join public.restaurant_admins ra
               on ra.restaurant_id = coalesce(tp.rest_id, tp.uploader_rest_id)::text
            where tp.id = p_ticket_id
              and ra.user_id = p_user
         )
$$;

comment on function public.taam_can_manage_ticket_as(text, uuid) is
  '「이 사람이」 이 티켓을 관리할 수 있나. 남의 가시성을 판정할 때 쓴다.';

create or replace function public.can_manage_ticket_access(p_ticket_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.taam_can_manage_ticket_as(p_ticket_id, auth.uid())
$$;

comment on function public.can_manage_ticket_access(text) is
  '티켓 명단 관리 권한: 슈퍼어드민 OR **그 티켓 매장의** 어드민. 2026-08-31: 인자를 안 쓰던 것을 고쳤다.';


-- ═══════════════════════════════════════════════════════════════
-- ⑥ 이 회원이 이 티켓을 볼 수 있나
-- ═══════════════════════════════════════════════════════════════
--   순서가 곧 규칙이다. 위가 이긴다.
--     1) 관리 권한자        → 보인다 (검수해야 하므로)
--     2) 계정 이용 제한     → 안 보인다
--     3) 티켓 block 명단    → 안 보인다
--     4) 티켓 allow 명단 존재 → 그 안에 있어야 보인다
--     5) min_tier 미달      → 안 보인다
--     6) audience 조건      → 등급·방문 이력이 맞아야 보인다
--     7) 그 외              → 보인다

create or replace function public.taam_ticket_visible(
  p_ticket_id text,
  p_user      uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tp   public.ticket_products%rowtype;
  v_rest text;
  v_aud  jsonb;
  v_tiers jsonb;
  v_visit jsonb;
  v_my_tier text;
  v_my_visit text;
  v_need int;
  v_have int;
begin
  select * into v_tp from public.ticket_products where id = p_ticket_id;
  if not found then return false; end if;

  -- 1) 관리 권한자는 다 본다
  --    ⚠ auth.uid() 가 아니라 **p_user 로서** 따진다. 호출자로 따지면
  --      어드민이 인원수를 셀 때 전원이 통과한다.
  if public.taam_can_manage_ticket_as(p_ticket_id, p_user) then
    return true;
  end if;

  -- 2) 계정 이용 제한 — 모든 티켓에서 빠진다
  if public.taam_is_banned(p_user) then
    return false;
  end if;

  -- 3) 이 티켓의 차단 명단
  if exists (select 1 from public.ticket_access_lists
              where ticket_id = p_ticket_id and user_id = p_user
                and access_type = 'block') then
    return false;
  end if;

  -- 4) 전용(allow) 명단이 하나라도 있으면 그 명단만 본다
  if exists (select 1 from public.ticket_access_lists
              where ticket_id = p_ticket_id and access_type = 'allow') then
    return exists (select 1 from public.ticket_access_lists
                    where ticket_id = p_ticket_id and user_id = p_user
                      and access_type = 'allow');
  end if;

  v_rest := coalesce(v_tp.rest_id, v_tp.uploader_rest_id)::text;

  -- 회원 등급 (M=2 · T=1 · 그 외=0). 랭크를 여기 두어 다른 함수에 기대지 않는다.
  select case upper(coalesce(p.membership_tier, ''))
           when 'M' then 2 when 'T' then 1 else 0 end,
         upper(coalesce(p.membership_tier, ''))
    into v_have, v_my_tier
    from public.profiles p where p.id = p_user;
  v_have := coalesce(v_have, 0);

  -- 5) min_tier 하한
  if coalesce(v_tp.min_tier, '') <> '' then
    v_need := case upper(v_tp.min_tier) when 'M' then 2 when 'T' then 1 else 0 end;
    if v_have < v_need then return false; end if;
  end if;

  -- 6) audience 조건
  v_aud := v_tp.audience;
  if v_aud is null or coalesce(v_aud->>'mode', 'all') <> 'conditions' then
    return true;
  end if;

  v_tiers := v_aud->'tiers';
  if v_tiers is not null and jsonb_typeof(v_tiers) = 'array'
     and jsonb_array_length(v_tiers) > 0 then
    if not (v_tiers ? v_my_tier) then return false; end if;
  end if;

  v_visit := v_aud->'visit';
  if v_visit is not null and jsonb_typeof(v_visit) = 'array'
     and jsonb_array_length(v_visit) > 0 then
    if v_rest is null then return false; end if;
    v_my_visit := public.taam_visit_tier(p_user, v_rest);
    if not (v_visit ? v_my_visit) then return false; end if;
  end if;

  return true;
end;
$$;

revoke all on function public.taam_ticket_visible(text, uuid) from public;
grant execute on function public.taam_ticket_visible(text, uuid) to authenticated;

comment on function public.taam_ticket_visible(text, uuid) is
  '이 회원이 이 티켓을 볼 수 있나. 이용제한 → block → allow명단 → min_tier → audience 조건 순.';


-- ═══════════════════════════════════════════════════════════════
-- ⑦ 지금 조건이면 몇 명이 보나 (발행 화면의 「47명」)
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 회원 전체를 훑는다. 발행 화면에서 조건을 바꿀 때만 부른다.
--     목록을 그릴 때마다 부르면 안 된다.

create or replace function public.taam_ticket_audience_count(p_ticket_id text)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n int := 0;
begin
  if not public.can_manage_ticket_access(p_ticket_id) then
    raise exception '이 티켓의 공개 대상을 볼 권한이 없습니다' using errcode = '42501';
  end if;

  select count(*) into v_n
    from public.profiles p
   where coalesce(p.role, 'member') not in ('super_admin', 'superadmin')
     and public.taam_ticket_visible(p_ticket_id, p.id);

  return coalesce(v_n, 0);
end;
$$;

revoke all on function public.taam_ticket_audience_count(text) from public;
grant execute on function public.taam_ticket_audience_count(text) to authenticated;

comment on function public.taam_ticket_audience_count(text) is
  '지금 조건으로 이 티켓을 볼 수 있는 회원 수. 발행 화면에서 조건을 바꿀 때만 부른다 (전체 스캔).';

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 새 표'                 as "구분",
       string_agg(table_name, ' · ' order by table_name) as "값1",
       count(*)::text || ' / 2'                          as "값2"
  from information_schema.tables
 where table_schema = 'public' and table_name in ('visit_tier_rules', 'member_bans')
union all
select '② audience 컬럼',
       coalesce(string_agg(column_name || ' (' || data_type || ')', ' · '), '❌ 없음'),
       count(*)::text || ' / 1'
  from information_schema.columns
 where table_schema = 'public' and table_name = 'ticket_products' and column_name = 'audience'
union all
select '③ 함수',
       string_agg(proname, ' · ' order by proname),
       count(*)::text || ' / 5'
  from pg_proc
 where pronamespace = 'public'::regnamespace
   and proname in ('taam_visit_tier', 'taam_ticket_visible',
                   'taam_ticket_audience_count', 'taam_is_banned',
                   'taam_can_manage_ticket_as')
union all
select '④ 남의 매장 명단 구멍 막혔나',
       case when prosrc like '%restaurant_admins%' then '✅ 매장을 확인함'
            else '❌ 아직 인자를 안 씀' end,
       '—'
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_can_manage_ticket_as'
union all
select '⑤ 기본 방문 기준',
       '재방문 ' || repeat_min || '회+ · 단골 ' || regular_min || '회+',
       '매장별 ' || (select count(*)::text from public.visit_tier_rules where restaurant_id <> '*') || '곳'
  from public.visit_tier_rules where restaurant_id = '*'
 order by 1;
