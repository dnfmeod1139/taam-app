-- ═══════════════════════════════════════════════════════════════
-- TAAM — 감사 보강 묶음 ① · 서버가 막는다 (2026-09-13)
-- ═══════════════════════════════════════════════════════════════
-- 2026-09-13 자가 감사(렌즈 12개 · 발견 90건) 중 **SQL 만으로 닫히는 것**을
-- 한 파일에 모았다. 앱 배포와 무관하다 — 지금 돌려도 정상 동선은 그대로 돈다.
-- (예치금 자가 충전 핫픽스 = ledger_server_side.sql, 파트너 증서 토큰 =
--  partner_cert_token.sql 은 별도 파일. 이 파일은 그 둘 **다음**에 돌려도, 먼저
--  돌려도 된다 — 겹치는 정의는 같은 내용을 다시 쓴다.)
--
-- 무엇을 막나
--   ① push_subscriptions.role — 클라이언트가 준 값을 버리고 profiles 로 정한다.
--      회원이 role='super_admin' 으로 구독하면 구매자 이름·금액 푸시를 전부 받았다.
--   ② tickets — 회원은 status='hold' 만 INSERT 할 수 있다. UPDATE 는 취소만.
--      · 종전 가드는 hold→active 전환과 그 순간의 price 변경을 회원에게 허용했다
--        → price=0 으로 결제 없이 확정. 확정은 이제 서버(RPC·toss-confirm)만 한다.
--      · INSERT 에는 가드가 없어서 회원이 active·price 0 행을 직접 넣을 수 있었다
--        (앱의 savePurchase 가 실제로 그 경로를 쓴다 — 로컬 저장소에 심으면 그대로 올라갔다).
--      · 매장 어드민(role='admin')은 수동 연동 행(status='manual') 을 계속 넣을 수 있다.
--   ③ get_requester_info — 매장 어드민은 **자기 매장에 요청·예약한 회원**만 본다.
--      종전에는 임의 uuid 로 전 회원의 전화번호·등급을 뽑을 수 있었다.
--   ④ chef_lineage_knowledge — 쓰기(INSERT·UPDATE·DELETE)는 슈퍼어드민만.
--      종전 WITH CHECK (true) 로 회원 아무나 컨시어지 계보 지식을 고치거나 지울 수 있었다.
--   ⑤ invite_codes — 회원은 사용 표시(used·used_by_*)만 바꿀 수 있다.
--      invitee_tier 를 'M' 으로 고치면 등급 가드(taam_invited_tier)가 속아 M 을 줬다.
--   ⑥ app_config — RLS 를 켠다. 읽기는 전원, 쓰기는 슈퍼어드민만.
--      환율(fx_settings)을 아무 회원이 덮어쓰면 toss-order 가 그 환율로 청구했다.
--   ⑦ 공개(anon) 쓰기 RPC 에 속도 제한 — partner_agree · taam_mship_apply ·
--      taam_corp_inquire. 같은 번호 시간당 6회, 전체 시간당 30~120회.
--      partner_agree 는 모르는 코드를 거부한다 (아무 매장·셰프 이름으로 TAAM 증서를 만들 수 있었다).
--   ⑧ taam_notify_admins — 한 사람이 시간당 30건 넘게 운영진 알림함에 꽂지 못한다.
--   ⑪ 파트너 증서 조회는 id + 토큰 (partner_cert_token.sql 을 따로 돌릴 필요 없음)
--   ⑫ single_device_exempt 회원 변경 차단 (guard_profile_exempt.sql 을 따로 돌릴 필요 없음)
--   ⑬ 오류 리포팅 표·RPC (app_errors.sql 을 따로 돌릴 필요 없음)
--   ⑨ taam_ref_consume — 실행 권한 회수. 저장소 어디에도 호출하는 코드가 없는데
--      anon 에게 열려 있어 코드만 알면 남의 추천권을 태울 수 있었다 (추천 기능은 숨김 상태).
--
-- ⚠ 되돌리기 — 구매가 막히면 ② 만 즉시 끈다:
--      drop trigger if exists trg_taam_guard_ticket_insert on public.tickets;
--   hold→active 확정은 taam_purchase_confirm_deposit(예치금) · toss-confirm(카드) 이
--   한다. 둘 다 서버 롤이라 이 가드에 걸리지 않는다. 앱의 「RPC 미설치 폴백」
--   (회원 세션의 UPDATE) 만 막힌다 — RPC 가 설치된 지금은 쓰이지 않는 길이다.
--
-- 실행: Supabase SQL Editor 에 통째로. 여러 번 돌려도 안전.
--       맨 아래 확인 쿼리에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- 0. 공통 — 속도 제한 · 역할 조회
-- ═══════════════════════════════════════════════════════════════
create table if not exists public.taam_rate_limits (
  key          text primary key,
  window_start timestamptz not null default now(),
  hits         integer not null default 0
);
alter table public.taam_rate_limits enable row level security;
revoke all on public.taam_rate_limits from anon, authenticated;

-- 창(p_window) 안에서 p_limit 번째까지 true, 넘으면 false.
-- SECURITY DEFINER 함수 안에서만 부른다 (앱에 노출하지 않는다).
create or replace function public.taam_rate_hit(p_key text, p_limit integer, p_window interval)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_hits integer;
begin
  insert into public.taam_rate_limits as r (key, window_start, hits)
  values (p_key, now(), 1)
  on conflict (key) do update set
    hits         = case when r.window_start + p_window < now() then 1 else r.hits + 1 end,
    window_start = case when r.window_start + p_window < now() then now() else r.window_start end
  returning hits into v_hits;
  -- 오래된 키는 가끔 치운다 (표가 자라지 않게)
  if random() < 0.01 then
    delete from public.taam_rate_limits where window_start < now() - interval '2 day';
  end if;
  return v_hits <= p_limit;
end;
$$;
revoke all on function public.taam_rate_hit(text, integer, interval) from public, anon, authenticated;

create or replace function public._taam_uid_is_super()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.role in ('super_admin','superadmin')
  )
$$;

-- 호출자의 profiles.role ('' 이면 로그인 안 됨 / 프로필 없음)
create or replace function public._taam_uid_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')
$$;
-- 트리거 함수(호출자 권한으로 돈다)가 부르므로 authenticated 에게 실행 권한이 있어야 한다.
-- 돌려주는 것은 호출자 자신의 role 뿐이다.
revoke all on function public._taam_uid_role() from public;
grant execute on function public._taam_uid_role() to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- ① 푸시 구독 — role 은 서버가 정한다
-- ═══════════════════════════════════════════════════════════════
--   p_role 은 시그니처 호환을 위해 남기지만 **무시한다.**
--   send-push 는 push_subscriptions.role 로도 대상을 고르므로(role:superadmin),
--   이 칸이 클라이언트 말대로 저장되면 회원이 운영진 푸시를 받는다.
-- 이 함수가 쓰는 컬럼은 여기서 보장한다 (push_subscriptions_fix.sql·push_lang.sql 과 같은 정의 — 라이브가 옛 판일 수 있다)
alter table public.push_subscriptions add column if not exists user_agent   text;
alter table public.push_subscriptions add column if not exists device_label text;
alter table public.push_subscriptions add column if not exists role         text;
alter table public.push_subscriptions add column if not exists topics       text[] default array[]::text[];
alter table public.push_subscriptions add column if not exists lang         text;
alter table public.push_subscriptions add column if not exists last_seen_at timestamptz default now();

-- ⚠ 판이 둘이다. 앱은 **8인자(p_lang, push_lang.sql)** 를 먼저 부르고, 그게 없을 때만 7인자로 내려간다
--   (index.html 「save_push_subscription」 호출부). 7인자만 고치면 실제 호출 경로에 닿지 않는다 —
--   그래서 8인자를 본체로 두고 7인자는 지운다. (2026-09-14 라이브 호환 검사에서 잡힘)
create or replace function public.save_push_subscription(
  p_endpoint     text,
  p_p256dh       text,
  p_auth         text,
  p_user_agent   text   default null,
  p_device_label text   default null,
  p_role         text   default null,
  p_topics       text[] default '{}',
  p_lang         text   default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_lang text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if coalesce(p_endpoint, '') = '' or length(p_endpoint) > 2000 then
    raise exception 'endpoint invalid';
  end if;

  -- 앱 내부 표기(superadmin/admin/user)로 맞춘다 — send-push 의 roleAliases 와 같은 축. p_role 은 무시.
  select case
           when p.role in ('super_admin','superadmin') then 'superadmin'
           when p.role = 'admin'                        then 'admin'
           else 'user'
         end
    into v_role
    from public.profiles p where p.id = auth.uid();
  v_role := coalesce(v_role, 'user');

  -- 아는 언어만 받는다 ('ko-KR' 같은 변형은 앞 두 글자로)
  v_lang := lower(coalesce(p_lang, ''));
  v_lang := case
              when v_lang like 'ja%' then 'ja'
              when v_lang like 'en%' then 'en'
              when v_lang like 'ko%' then 'ko'
              else null
            end;

  insert into public.push_subscriptions
    (user_id, endpoint, p256dh, auth, user_agent, device_label, role, topics, lang, last_seen_at)
  values
    (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 400), left(p_device_label, 120),
     v_role, coalesce(p_topics, '{}'), v_lang, now())
  on conflict (endpoint) do update set
    user_id      = excluded.user_id,        -- 같은 기기를 다른 회원이 쓰게 됐다 (공용 기기·재로그인)
    p256dh       = excluded.p256dh,
    auth         = excluded.auth,
    user_agent   = excluded.user_agent,
    device_label = excluded.device_label,
    role         = excluded.role,
    topics       = excluded.topics,
    -- 새 값이 없으면 알던 언어를 지우지 않는다 (옛 앱이 저장해도 언어가 안 날아간다)
    lang         = coalesce(excluded.lang, public.push_subscriptions.lang),
    last_seen_at = now();
end;
$$;
revoke all on function public.save_push_subscription(text,text,text,text,text,text,text[],text) from public, anon;
grant execute on function public.save_push_subscription(text,text,text,text,text,text,text[],text) to authenticated;

-- 7인자 판은 지운다. 8인자에 p_lang 기본값이 있어 둘이 공존하면 7인자 호출이
--   「function is not unique」로 실패한다(로컬 테스트에서 재현). 앱은 항상 p_lang 을 실어 부르고,
--   PostgREST 의 이름 인자 호출은 p_lang 을 빼도 8인자 하나로 유일하게 풀린다.
drop function if exists public.save_push_subscription(text,text,text,text,text,text,text[]);

-- 이미 잘못 저장된 role 을 profiles 기준으로 한 번 바로잡는다
update public.push_subscriptions s
   set role = case when p.role in ('super_admin','superadmin') then 'superadmin'
                   when p.role = 'admin' then 'admin' else 'user' end
  from public.profiles p
 where p.id = s.user_id
   and coalesce(s.role,'') is distinct from
       case when p.role in ('super_admin','superadmin') then 'superadmin'
            when p.role = 'admin' then 'admin' else 'user' end;


-- ═══════════════════════════════════════════════════════════════
-- ② tickets — 회원은 hold 만 넣고, 취소만 한다
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_ticket_row()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 서버(service_role · postgres · SECURITY DEFINER RPC · 좌석 트리거)는 막지 않는다
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;

  -- ── 여기부터 회원·매장어드민 세션 ──────────────────────────────
  if new.user_id     is distinct from old.user_id
     or new.purchase_id is distinct from old.purchase_id then
    raise exception '예약의 소유자·구매ID 는 바꿀 수 없습니다' using errcode = '42501';
  end if;

  if coalesce(new.party_size, 0) is distinct from coalesce(old.party_size, 0) then
    raise exception '인원은 직접 바꿀 수 없습니다 (taam_change_party_size 를 쓰세요)'
      using errcode = '42501';
  end if;

  if new.restaurant_id is distinct from old.restaurant_id
     or new.reservation_date is distinct from old.reservation_date then
    raise exception '예약의 매장·날짜는 직접 바꿀 수 없습니다' using errcode = '42501';
  end if;

  if old.status = 'cancelled' and new.status is distinct from old.status then
    raise exception '취소된 예약은 되살릴 수 없습니다' using errcode = '42501';
  end if;

  -- 🔒 2026-09-13: 상태 전환은 「취소」만. 확정(hold→active)은 서버가 한다.
  --   종전에는 hold→active 를 회원에게 열어 두고 그 순간 price 변경도 허용했다 —
  --   price=0 으로 결제 없이 좌석을 확정할 수 있었다.
  if new.status is distinct from old.status and new.status <> 'cancelled' then
    raise exception '예약 상태는 취소만 직접 할 수 있습니다 (확정은 서버가 합니다)'
      using errcode = '42501';
  end if;

  -- 🔒 금액은 회원 세션에서 절대 바뀌지 않는다
  if coalesce(new.price, 0) is distinct from coalesce(old.price, 0) then
    raise exception '금액은 서버만 정합니다' using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_taam_guard_ticket_row on public.tickets;
create trigger trg_taam_guard_ticket_row
  before update on public.tickets
  for each row execute function public.taam_guard_ticket_row();

comment on function public.taam_guard_ticket_row() is
  '회원 세션의 tickets UPDATE 가드 — 인원·금액·매장·날짜·소유자 변경 차단, 상태는 취소만. 확정은 서버 RPC·toss-confirm.';

-- INSERT — 회원은 hold 만, 매장 어드민은 hold·manual
create or replace function public.taam_guard_ticket_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_role text;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;

  if new.user_id is distinct from auth.uid() then
    raise exception '남의 이름으로 예약을 넣을 수 없습니다' using errcode = '42501';
  end if;

  if new.status = 'hold' then
    return new;                               -- 좌석 홀드(5분) — 확정은 서버가 한다
  end if;

  v_role := public._taam_uid_role();
  if new.status = 'manual' and v_role = 'admin' then
    return new;                               -- 매장 어드민의 수동 연동 행(MAN-)
  end if;

  raise exception '예약은 서버가 확정합니다 — 직접 넣을 수 없는 상태: %', coalesce(new.status, '(없음)')
    using errcode = '42501';
end;
$$;

drop trigger if exists trg_taam_guard_ticket_insert on public.tickets;
create trigger trg_taam_guard_ticket_insert
  before insert on public.tickets
  for each row execute function public.taam_guard_ticket_insert();

comment on function public.taam_guard_ticket_insert() is
  '회원 세션의 tickets INSERT 가드 — 회원은 status=hold 만, 매장 어드민은 hold·manual. 확정 행은 서버만 만든다.';


-- ═══════════════════════════════════════════════════════════════
-- ③ get_requester_info — 자기 매장과 관계 있는 회원만
-- ═══════════════════════════════════════════════════════════════
create or replace function public.get_requester_info(p_user_id uuid, p_venue_id text)
returns table (
  display_name   text,
  phone          text,
  nationality    text,
  membership_tier text,
  purchase_count integer,
  cancel_count   integer,
  venue_visits   integer,
  last_visit     date
)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_ticket_buy integer := 0; v_ticket_cancel integer := 0;
  v_resv_conf  integer := 0; v_resv_noshow   integer := 0;
  v_related    boolean := false;
begin
  if not (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(p_venue_id)) then
    raise exception 'FORBIDDEN' using errcode='P0001';
  end if;

  -- 🔒 2026-09-13: 매장 어드민은 그 매장에 요청·예약한 회원만 볼 수 있다.
  --   종전에는 임의 uuid 를 넣어 전 회원의 전화번호·국적·등급을 뽑을 수 있었다.
  if not public.is_super_admin(auth.uid()) then
    v_related := exists (select 1 from public.reservation_requests rr
                          where rr.user_id = p_user_id and rr.venue_id = p_venue_id);
    if not v_related then
      begin
        v_related := exists (select 1 from public.tickets t
                              where t.user_id = p_user_id and t.restaurant_id::text = p_venue_id);
      exception when undefined_table or undefined_column then v_related := false;
      end;
    end if;
    if not v_related then
      raise exception 'FORBIDDEN' using errcode='P0001';
    end if;
  end if;

  begin
    select count(*) filter (where coalesce(status,'') <> 'cancelled'),
           count(*) filter (where status = 'cancelled')
      into v_ticket_buy, v_ticket_cancel
      from public.tickets where user_id = p_user_id;
  exception when undefined_table then v_ticket_buy := 0; v_ticket_cancel := 0;
  end;

  select count(*) filter (where status = 'confirmed'),
         count(*) filter (where visit_status = 'no_show')
    into v_resv_conf, v_resv_noshow
    from public.reservation_requests where user_id = p_user_id;

  return query
  select
    p.display_name,
    p.phone,
    p.nationality,
    p.membership_tier,
    (v_ticket_buy + v_resv_conf)::int,
    (v_ticket_cancel + v_resv_noshow)::int,
    (select count(*)::int from public.reservation_requests rr
       where rr.user_id = p_user_id and rr.venue_id = p_venue_id and rr.visit_status = 'attended'),
    (select max(rr.reserve_date) from public.reservation_requests rr
       where rr.user_id = p_user_id and rr.venue_id = p_venue_id and rr.visit_status = 'attended')
  from public.profiles p where p.id = p_user_id;
end;
$$;
comment on function public.get_requester_info is
  '어드민용 요청자 집계. 매장 어드민은 자기 매장에 요청·예약한 회원만, 슈퍼어드민은 전원.';


-- ═══════════════════════════════════════════════════════════════
-- ④ chef_lineage_knowledge — 쓰기는 슈퍼어드민만
-- ═══════════════════════════════════════════════════════════════
do $$
begin
  if to_regclass('public.chef_lineage_knowledge') is null then
    raise notice 'chef_lineage_knowledge 없음 — ④ 건너뜀';
    return;
  end if;
  execute 'drop policy if exists "Auth users insert lineage knowledge" on public.chef_lineage_knowledge';
  execute 'drop policy if exists "Auth users update lineage knowledge" on public.chef_lineage_knowledge';
  execute 'drop policy if exists "Auth users delete lineage knowledge" on public.chef_lineage_knowledge';
  execute 'drop policy if exists "superadmin writes lineage knowledge" on public.chef_lineage_knowledge';
  execute $p$create policy "superadmin writes lineage knowledge"
             on public.chef_lineage_knowledge for all to authenticated
             using (public.is_super_admin(auth.uid()))
             with check (public.is_super_admin(auth.uid()))$p$;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑤ invite_codes — 회원은 사용 표시만 바꾼다
-- ═══════════════════════════════════════════════════════════════
--   컬럼 이름을 나열하지 않고 to_jsonb 로 비교한다 — 표 모양이 달라도 깨지지 않는다.
create or replace function public.taam_guard_invite_code_row()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_allowed text[] := array['used','used_at','used_by','used_by_email','used_by_name',
                            'used_by_phone','used_by_user_id','used_by_uid','updated_at'];
  v_old jsonb := to_jsonb(old) - v_allowed;
  v_new jsonb := to_jsonb(new) - v_allowed;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;
  if v_new <> v_old then
    raise exception '초대코드는 사용 표시만 바꿀 수 있습니다' using errcode = '42501';
  end if;
  -- 사용됨 → 미사용 되돌리기 금지 (코드 재사용)
  if coalesce((to_jsonb(old)->>'used')::boolean, false)
     and not coalesce((to_jsonb(new)->>'used')::boolean, false) then
    raise exception '사용된 초대코드는 되살릴 수 없습니다' using errcode = '42501';
  end if;
  return new;
end;
$$;

do $$
begin
  if to_regclass('public.invite_codes') is null then
    raise notice 'invite_codes 없음 — ⑤ 건너뜀';
    return;
  end if;
  execute 'drop trigger if exists trg_taam_guard_invite_code_row on public.invite_codes';
  execute 'create trigger trg_taam_guard_invite_code_row before update on public.invite_codes
           for each row execute function public.taam_guard_invite_code_row()';
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑥ app_config — 읽기 전원 · 쓰기 슈퍼어드민
-- ═══════════════════════════════════════════════════════════════
do $$
declare p record;
begin
  if to_regclass('public.app_config') is null then
    raise notice 'app_config 없음 — ⑥ 건너뜀';
    return;
  end if;
  execute 'alter table public.app_config enable row level security';
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'app_config' loop
    execute format('drop policy if exists %I on public.app_config', p.policyname);
  end loop;
  execute 'create policy "app_config read" on public.app_config for select to anon, authenticated using (true)';
  execute $p$create policy "app_config super write" on public.app_config for all to authenticated
             using (public.is_super_admin(auth.uid())) with check (public.is_super_admin(auth.uid()))$p$;
  execute 'grant select on public.app_config to anon, authenticated';
  execute 'grant insert, update, delete on public.app_config to authenticated';
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑦ 공개 쓰기 RPC — 속도 제한 · 코드 검증
-- ═══════════════════════════════════════════════════════════════
-- ⑦-a partner_agree — 토큰(partner_cert_token.sql 과 같은 정의) + 모르는 코드 거부 + 제한
-- ⚠ 2026-09-14: 라이브 partner_agreements 에 agreed_meal 이 없었다 (repo 의 partner_qr.sql 은
--   나중에 add column 을 넣었지만 라이브는 그 전 판이었다). SQL 함수는 만들 때 컬럼을 검사하므로
--   ⑪ 에서 42703 으로 통째로 실패했다. 이 파일이 쓰는 컬럼은 여기서 직접 보장한다.
alter table public.partner_agreements add column if not exists user_agent     text;
alter table public.partner_agreements add column if not exists signature_data text;
alter table public.partner_agreements add column if not exists agreed_meal    text;
alter table public.partner_agreements add column if not exists agreed_min     text;
alter table public.partner_agreements add column if not exists cert_token text;
update public.partner_agreements
   set cert_token = replace(gen_random_uuid()::text, '-', '')
 where cert_token is null;
alter table public.partner_agreements
  alter column cert_token set default replace(gen_random_uuid()::text, '-', '');
create unique index if not exists idx_partner_agreements_token on public.partner_agreements (cert_token);

create or replace function public.partner_agree(p_code text, p_restaurant text, p_chef text, p_name text, p_ua text default null, p_signature text default null, p_min text default null, p_meal text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare new_id bigint; ts timestamptz; tok text; v_code text;
begin
  if not public.taam_rate_hit('partner_agree', 30, interval '1 hour') then
    return json_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if coalesce(trim(p_name),'') = '' then
    return json_build_object('ok', false, 'error', 'name required');
  end if;
  if length(coalesce(p_signature,'')) > 600000 then
    return json_build_object('ok', false, 'error', 'signature too large');
  end if;
  -- 코드가 있으면 발급된 코드여야 한다. 빈 코드·GENERIC(일반 랜딩)은 허용 — 슈퍼어드민이 확인한다.
  v_code := nullif(upper(trim(coalesce(p_code,''))), '');
  if v_code is not null and v_code <> 'GENERIC'
     and not exists (select 1 from public.partner_qr_codes q where upper(q.code) = v_code) then
    return json_build_object('ok', false, 'error', 'code_invalid');
  end if;

  insert into public.partner_agreements(code, restaurant_name, chef_name, signer_name, user_agent, signature_data, agreed_min, agreed_meal)
  values (v_code, left(nullif(trim(p_restaurant),''), 200), left(nullif(trim(p_chef),''), 200), left(trim(p_name), 120),
          left(coalesce(p_ua,''),400), p_signature, left(nullif(trim(p_min),''), 120), left(nullif(trim(p_meal),''), 120))
  returning id, agreed_at, cert_token into new_id, ts, tok;
  return json_build_object('ok', true, 'id', new_id, 'agreed_at', ts, 'token', tok);
end;
$$;
revoke execute on function public.partner_agree(text,text,text,text,text,text,text,text) from public;
grant  execute on function public.partner_agree(text,text,text,text,text,text,text,text) to anon;
grant  execute on function public.partner_agree(text,text,text,text,text,text,text,text) to authenticated;

-- ⑦-b taam_mship_apply — 같은 번호 시간당 6회 · 전체 시간당 120회
do $$
begin
  if to_regclass('public.membership_applications') is null then
    raise notice 'membership_applications 없음 — ⑦-b 건너뜀';
    return;
  end if;
  execute $fn$
create or replace function public.taam_mship_apply(
  p_name     text,
  p_phone    text,
  p_answers  jsonb,
  p_lang     text default 'ko',
  p_referral text default null,
  p_source   text default 'app'
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $body$
declare
  v_phone text;
  v_uid   uuid := auth.uid();
  v_row   public.membership_applications%rowtype;
begin
  v_phone := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  if v_phone is null or length(v_phone) < 8 then
    raise exception '연락처를 확인해 주세요' using errcode = '22023';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception '이름을 적어 주세요' using errcode = '22023';
  end if;
  if not public.taam_rate_hit('mship_apply', 120, interval '1 hour')
     or not public.taam_rate_hit('mship_apply:' || v_phone, 6, interval '1 hour') then
    raise exception '잠시 후 다시 시도해 주세요' using errcode = '54000';
  end if;
  if length(coalesce(p_answers::text, '')) > 20000 then
    raise exception '답변이 너무 깁니다' using errcode = '22023';
  end if;

  select * into v_row
    from public.membership_applications
   where phone = v_phone and status in ('applied','screening')
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'already', true, 'id', v_row.id,
                              'status', v_row.status, 'created_at', v_row.created_at);
  end if;

  insert into public.membership_applications
    (user_id, name, phone, answers, referral_code, lang, source)
  values
    (v_uid, left(btrim(p_name), 80), v_phone,
     coalesce(p_answers, '{}'::jsonb),
     left(nullif(btrim(upper(coalesce(p_referral,''))), ''), 32),
     lower(coalesce(nullif(btrim(p_lang),''), 'ko')),
     left(lower(coalesce(nullif(btrim(p_source),''), 'app')), 32))
  returning * into v_row;

  return jsonb_build_object('ok', true, 'already', false, 'id', v_row.id,
                            'status', v_row.status, 'created_at', v_row.created_at);
end;
$body$;
revoke all on function public.taam_mship_apply(text, text, jsonb, text, text, text) from public;
grant execute on function public.taam_mship_apply(text, text, jsonb, text, text, text) to anon, authenticated;
  $fn$;
end $$;


-- ⑦-c taam_corp_inquire — 같은 번호 시간당 6회 · 전체 시간당 30회
do $$
begin
  if to_regclass('public.corporate_inquiries') is null then
    raise notice 'corporate_inquiries 없음 — ⑦-c 건너뜀';
    return;
  end if;
  execute $fn$
create or replace function public.taam_corp_inquire(
  p_company text, p_contact text, p_phone text,
  p_email text default null, p_memo text default null, p_lang text default 'ko'
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $body$
declare v_phone text; r public.corporate_inquiries%rowtype;
begin
  v_phone := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  if coalesce(btrim(p_company),'') = '' then
    raise exception '회사명을 적어 주세요' using errcode = '22023';
  end if;
  if coalesce(btrim(p_contact),'') = '' then
    raise exception '담당자를 적어 주세요' using errcode = '22023';
  end if;
  if v_phone is null or length(v_phone) < 8 then
    raise exception '연락처를 확인해 주세요' using errcode = '22023';
  end if;
  if not public.taam_rate_hit('corp_inquire', 30, interval '1 hour')
     or not public.taam_rate_hit('corp_inquire:' || v_phone, 6, interval '1 hour') then
    raise exception '잠시 후 다시 시도해 주세요' using errcode = '54000';
  end if;

  select * into r from public.corporate_inquiries
   where phone = v_phone and status in ('new','talking')
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'already', true, 'id', r.id);
  end if;

  insert into public.corporate_inquiries (company, contact, phone, email, memo, lang)
  values (left(btrim(p_company), 120), left(btrim(p_contact), 80), v_phone,
          left(nullif(btrim(coalesce(p_email,'')), ''), 200), left(nullif(btrim(coalesce(p_memo,'')), ''), 2000),
          lower(coalesce(nullif(btrim(p_lang),''), 'ko')))
  returning * into r;
  return jsonb_build_object('ok', true, 'already', false, 'id', r.id);
end;
$body$;
revoke all on function public.taam_corp_inquire(text,text,text,text,text,text) from public;
grant execute on function public.taam_corp_inquire(text,text,text,text,text,text) to anon, authenticated;
  $fn$;
end $$;



-- ═══════════════════════════════════════════════════════════════
-- ⑧ taam_notify_admins — 한 사람 시간당 30건
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_notify_admins(
  p_type    text,
  p_title   text,
  p_body    text  default null,
  p_url     text  default null,
  p_payload jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n     int := 0;
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception '로그인이 필요합니다';
  end if;
  if coalesce(p_title, '') = '' then
    raise exception '제목이 필요합니다';
  end if;
  -- 넘치면 조용히 0 — 정상 동선(시간변경 확인·자동환불 통지)은 시간당 몇 건이다
  if not public._taam_uid_is_super()
     and not public.taam_rate_hit('notify_admins:' || v_actor::text, 30, interval '1 hour') then
    return 0;
  end if;

  insert into public.notifications (user_id, type, title, body, url, payload)
  select
    p.id,
    left(coalesce(p_type, 'system'), 60),
    left(p_title, 200),
    left(coalesce(p_body, ''), 1000),
    left(coalesce(p_url, '/'), 500),
    coalesce(p_payload, '{}'::jsonb)
      || jsonb_build_object('actor_id', v_actor, 'via', 'taam_notify_admins')
  from public.profiles p
  where p.role in ('superadmin', 'super_admin')
    and p.id <> v_actor;

  get diagnostics v_n = row_count;
  return v_n;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑨ taam_ref_consume — 호출하는 코드가 없다. 권한 회수.
-- ═══════════════════════════════════════════════════════════════
do $$
begin
  if to_regprocedure('public.taam_ref_consume(text, uuid)') is not null then
    execute 'revoke all on function public.taam_ref_consume(text, uuid) from public, anon, authenticated';
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑩ Edge Function 과 짝 — 예약 알림 1회 표시 · 제한기 실행 권한
-- ═══════════════════════════════════════════════════════════════
--   notify-reservation 이 한 예약에 한 번만 보내도록 notified_at 을 찍는다.
--   verify-invite · consume-invite · taam-chat 은 service_role 로 taam_rate_hit 를 부른다.
do $$
begin
  if to_regclass('public.reservation_requests') is not null then
    execute 'alter table public.reservation_requests add column if not exists notified_at timestamptz';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.taam_rate_hit(text, integer, interval) to service_role';
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑪ 파트너 증서 조회 — id + 토큰 (partner_cert_token.sql 과 같은 정의)
-- ═══════════════════════════════════════════════════════════════
--   이 파일 하나로 끝나게 같이 넣었다. partner/ 페이지 배포와 짝 — 옛 링크(?cert=<id>)는
--   더 열리지 않으니 파트너에게 새 링크(확인 쿼리 ③)를 다시 보낸다.
-- ── 조회 — id + 토큰. 1인자 판은 항상 거부 ────────────────────────
create or replace function public.partner_agreement_get(p_id bigint)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object('ok', false, 'reason', 'token_required');
$$;
revoke execute on function public.partner_agreement_get(bigint) from public;
grant  execute on function public.partner_agreement_get(bigint) to anon;
grant  execute on function public.partner_agreement_get(bigint) to authenticated;

create or replace function public.partner_agreement_get(p_id bigint, p_token text)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select json_build_object(
        'ok', true,
        'restaurant_name', coalesce(restaurant_name,''),
        'chef_name', coalesce(chef_name,''),
        'signer_name', coalesce(signer_name,''),
        'agreed_at', agreed_at,
        'signature_data', signature_data,
        'agreed_meal', coalesce(agreed_meal,''),
        'agreed_min', coalesce(agreed_min,'')
      )
      from public.partner_agreements
     where id = p_id
       and length(coalesce(p_token,'')) >= 16
       and cert_token = p_token),
    json_build_object('ok', false)
  );
$$;
revoke execute on function public.partner_agreement_get(bigint, text) from public;
grant  execute on function public.partner_agreement_get(bigint, text) to anon;
grant  execute on function public.partner_agreement_get(bigint, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- ⑫ single_device_exempt 는 회원이 못 켠다 (guard_profile_exempt.sql 과 같은 정의)
-- ═══════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists single_device_exempt boolean not null default false;   -- single_device_exempt.sql 과 같은 정의

create or replace function public.taam_guard_profile_exempt()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.single_device_exempt is distinct from old.single_device_exempt then
    if auth.uid() is not null and not public.is_super_admin(auth.uid()) then
      new.single_device_exempt := old.single_device_exempt;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_taam_guard_profile_exempt on public.profiles;
create trigger trg_taam_guard_profile_exempt
  before update of single_device_exempt on public.profiles
  for each row execute function public.taam_guard_profile_exempt();

comment on function public.taam_guard_profile_exempt() is
  'single_device_exempt 는 슈퍼어드민·서버만 바꾼다. 회원이 바꾸면 조용히 원래 값으로 되돌린다.';


-- ═══════════════════════════════════════════════════════════════
-- ⑬ 오류 리포팅 표·RPC (app_errors.sql 과 같은 정의) — 앱이 taam_report_error 로 보낸다
-- ═══════════════════════════════════════════════════════════════
create table if not exists public.app_errors (
  id          bigserial primary key,
  created_at  timestamptz not null default now(),
  user_id     uuid,                       -- 비로그인이면 null
  role        text,
  build       text,
  platform    text,                       -- web / ios / android
  kind        text not null,              -- js · promise · boot_stuck · cdn_fallback · ledger_fallback · …
  message     text not null,
  stack       text,
  url         text,
  extra       jsonb not null default '{}'::jsonb
);
create index if not exists idx_app_errors_at   on public.app_errors (created_at desc);
create index if not exists idx_app_errors_kind on public.app_errors (kind, created_at desc);
create index if not exists idx_app_errors_user on public.app_errors (user_id, created_at desc);

alter table public.app_errors enable row level security;
revoke all on public.app_errors from anon, authenticated;
grant select on public.app_errors to authenticated;   -- 정책이 슈퍼어드민만 통과시킨다

drop policy if exists app_errors_read_super on public.app_errors;
create policy app_errors_read_super on public.app_errors
  for select to authenticated
  using (public.is_super_admin(auth.uid()));
-- INSERT/UPDATE/DELETE 정책은 두지 않는다 — 함수(definer)만 쓴다.

comment on table public.app_errors is
  '회원 기기에서 올라온 오류. 앱은 taam_report_error() 로만 쓰고, 슈퍼어드민만 읽는다. 30일 뒤 taam_error_prune() 로 지운다.';


-- ── 적기 — 누구나(익명 포함), 한 시간 60건까지 ─────────────────
create or replace function public.taam_report_error(
  p_kind     text,
  p_message  text,
  p_stack    text  default null,
  p_url      text  default null,
  p_build    text  default null,
  p_platform text  default null,
  p_extra    jsonb default '{}'::jsonb
)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
  v_n    int;
begin
  -- 폭주 방지. 같은 사람이 한 시간에 60건을 넘기면 그 뒤는 버린다.
  --   익명은 구분할 열쇠가 없어 한 묶음으로 센다 — 익명 폭주도 60건에서 선다.
  if v_uid is not null then
    select count(*) into v_n from public.app_errors
     where user_id = v_uid and created_at > now() - interval '1 hour';
  else
    select count(*) into v_n from public.app_errors
     where user_id is null and created_at > now() - interval '1 hour';
  end if;
  if v_n >= 60 then return; end if;

  if v_uid is not null then
    select p.role into v_role from public.profiles p where p.id = v_uid;
  end if;

  insert into public.app_errors (user_id, role, build, platform, kind, message, stack, url, extra)
  values (
    v_uid, v_role,
    left(p_build, 40), left(p_platform, 20),
    left(coalesce(nullif(btrim(p_kind), ''), 'js'), 40),
    left(coalesce(p_message, ''), 500),
    left(p_stack, 2000),
    left(p_url, 300),
    case when jsonb_typeof(p_extra) = 'object' then p_extra else '{}'::jsonb end
  );
exception when others then
  -- 오류를 적다가 난 오류로 앱을 죽이지 않는다
  return;
end;
$$;
revoke all on function public.taam_report_error(text,text,text,text,text,text,jsonb) from public;
grant execute on function public.taam_report_error(text,text,text,text,text,text,jsonb) to anon, authenticated;


-- ── 요약 — 슈퍼어드민만. 대시보드 카드가 부른다 ─────────────────
create or replace function public.taam_error_summary(p_hours int default 24)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v     jsonb;
  since timestamptz := now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 720)));
begin
  if not public.is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'hours',  extract(epoch from (now() - since))::int / 3600,
    'total',  (select count(*) from public.app_errors where created_at > since),
    'users',  (select count(distinct user_id) from public.app_errors where created_at > since and user_id is not null),
    'anon',   (select count(*) from public.app_errors where created_at > since and user_id is null),
    'by_kind',(select coalesce(jsonb_object_agg(kind, n), '{}'::jsonb)
                 from (select kind, count(*) n from public.app_errors
                        where created_at > since group by kind) k),
    'top',    (select coalesce(jsonb_agg(jsonb_build_object(
                 'kind', kind, 'message', message, 'n', n, 'last', last, 'platforms', platforms)), '[]'::jsonb)
                 from (select kind, message, count(*) n, max(created_at) last,
                              array_agg(distinct coalesce(platform,'?')) platforms
                         from public.app_errors where created_at > since
                        group by kind, message order by n desc, last desc limit 8) t)
  ) into v;
  return v;
end;
$$;
revoke all on function public.taam_error_summary(int) from public;
grant execute on function public.taam_error_summary(int) to authenticated;


-- ── 정리 — 30일 지난 것. 자동으로 걸지 않는다(필요하면 대시보드 Cron) ──
create or replace function public.taam_error_prune()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not public.is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  delete from public.app_errors where created_at < now() - interval '30 day';
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.taam_error_prune() from public;
grant execute on function public.taam_error_prune() to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다. ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════
select '① 푸시 role 을 서버가 정하나' as "구분",
       case when pg_get_functiondef(to_regprocedure('public.save_push_subscription(text,text,text,text,text,text,text[],text)'))
                 like '%from public.profiles p where p.id = auth.uid()%'
             and to_regprocedure('public.save_push_subscription(text,text,text,text,text,text,text[])') is null
             then '✅' else '❌' end as "결과",
       (select count(*)::text || '건' from public.push_subscriptions where role not in ('superadmin','admin','user')) || ' 비표준 role 남음' as "메모"
union all
select '② tickets INSERT 가드',
       case when exists (select 1 from pg_trigger where tgrelid=to_regclass('public.tickets') and tgname='trg_taam_guard_ticket_insert') then '✅' else '❌' end,
       '회원은 hold 만 · 어드민은 hold·manual'
union all
select '② tickets UPDATE 가드 (확정 차단)',
       case when pg_get_functiondef(to_regprocedure('public.taam_guard_ticket_row()')) like '%확정은 서버가 합니다%' then '✅' else '❌' end,
       '회원 hold→active · price 변경 차단'
union all
select '③ 요청자 정보 범위',
       case when pg_get_functiondef(to_regprocedure('public.get_requester_info(uuid,text)')) like '%v_related%' then '✅' else '❌' end,
       '매장 어드민은 자기 매장 관련 회원만'
union all
select '④ 계보 지식 쓰기 정책',
       case when to_regclass('public.chef_lineage_knowledge') is null then '— (표 없음)'
            when exists (select 1 from pg_policies where tablename='chef_lineage_knowledge' and policyname like 'Auth users % lineage knowledge' and cmd <> 'SELECT') then '❌ 옛 정책 남음'
            when exists (select 1 from pg_policies where tablename='chef_lineage_knowledge' and policyname='superadmin writes lineage knowledge') then '✅' else '❌' end,
       '쓰기는 슈퍼어드민만'
union all
select '⑤ invite_codes 가드',
       case when to_regclass('public.invite_codes') is null then '— (표 없음)'
            when exists (select 1 from pg_trigger where tgrelid=to_regclass('public.invite_codes') and tgname='trg_taam_guard_invite_code_row') then '✅' else '❌' end,
       '회원은 used·used_by_* 만'
union all
select '⑥ app_config RLS',
       case when to_regclass('public.app_config') is null then '— (표 없음)'
            when (select relrowsecurity from pg_class where oid=to_regclass('public.app_config'))
                 and (select count(*) from pg_policies where tablename='app_config') = 2 then '✅'
            else '❌' end,
       (select string_agg(policyname, ' / ') from pg_policies where tablename='app_config')
union all
select '⑦ 속도 제한 표',
       case when to_regclass('public.taam_rate_limits') is not null then '✅' else '❌' end,
       'partner_agree · mship_apply · corp_inquire · notify_admins'
union all
select '⑦ partner_agree 코드 검증',
       case when pg_get_functiondef(to_regprocedure('public.partner_agree(text,text,text,text,text,text,text,text)')) like '%code_invalid%' then '✅' else '❌' end,
       '모르는 코드 거부 · 토큰 반환'
union all
select '⑩ 예약 알림 1회 표시 컬럼',
       case when to_regclass('public.reservation_requests') is null then '— (표 없음)'
            when exists (select 1 from information_schema.columns where table_schema='public' and table_name='reservation_requests' and column_name='notified_at') then '✅' else '❌' end,
       'notify-reservation 이 두 번 보내지 않게'
union all
select '⑪ 증서 id 만으로 열리나 ⭐',
       case when to_regclass('public.partner_agreements') is null then '— (표 없음)'
            when (select count(*) from public.partner_agreements) = 0 then '✅ (행 없음)'
            when (public.partner_agreement_get((select min(id) from public.partner_agreements)))->>'ok' = 'true'
            then '❌ 아직 열린다' else '✅ 막힘' end,
       '1인자 조회는 항상 ok:false'
union all
select '⑪ 다시 보낼 증서 링크 (id=토큰)',
       coalesce((select string_agg(id || '=' || cert_token, ' / ' order by id) from public.partner_agreements), '(없음)'),
       '?cert=<id>&t=<토큰>'
union all
select '⑫ 면제 플래그 가드',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_profile_exempt' and not tgisinternal) then '✅' else '❌' end,
       (select count(*)::text from public.profiles where single_device_exempt = true) || '명 면제 중 — 심사·데모·파트너만이어야 정상'
union all
select '⑬ 오류 표·RPC',
       case when to_regclass('public.app_errors') is not null
             and to_regprocedure('public.taam_report_error(text,text,text,text,text,text,jsonb)') is not null
             and not exists (select 1 from pg_policies where tablename='app_errors' and cmd='INSERT') then '✅' else '❌' end,
       '회원은 RPC 로만 쓰고 슈퍼어드민만 읽는다'
union all
select '⑨ taam_ref_consume anon 권한',
       case when to_regprocedure('public.taam_ref_consume(text, uuid)') is null then '— (함수 없음)'
            when has_function_privilege('anon', 'public.taam_ref_consume(text, uuid)', 'execute') then '❌ 아직 열림' else '✅ 회수됨' end,
       '호출 코드 없음 — 추천 기능은 숨김'
order by 1;
