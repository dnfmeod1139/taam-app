-- ═══════════════════════════════════════════════════════════════
-- TAAM — 판매 오픈 7일이 지나면 재구매 제한을 푼다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 만드나
--   재구매 제한의 목적은 귀한 자리를 여러 회원에게 고루 나누는 것이다.
--   그런데 7일이 지나도록 안 팔린 자리는 **나눌 경쟁자가 없다는 뜻**이다.
--   그 자리를 비워 두면 아무도 이득이 아니다 — 매장은 매출을 잃고,
--   가고 싶은 회원은 못 가고, 탐은 수수료를 못 받는다.
--   규칙의 전제가 사라졌으면 규칙도 풀리는 게 맞다.
--
-- 좌석 조건은 넣지 않는다 (운영 판단)
--   「7일 + 자리가 많이 남았을 때만」을 제안했으나 사장님이 그럴 필요가 없다고
--   했다. 인기 있는 곳은 바로 완판되고, 아닌 곳은 몇 자리든 그대로 남는다는
--   경험이다. 실제로 완판이면 살 자리가 없으니 해제해도 아무 일이 없다.
--   조건이 하나면 회원에게 설명하기도 쉽다 — 「7일 지나면 열립니다」.
--
-- 기준 시각은 「등록일」이 아니라 「판매 오픈 시각」이다
--   ticket_products 에 sale_state='scheduled' + sale_open_at 이 있다.
--   3주 전에 만들어 두고 어제 오픈한 티켓을 등록일로 세면 **오픈하자마자
--   풀린다.** 그건 사고다. coalesce(sale_open_at, reg_date) 로 센다.
--
-- ⚠ 세 곳이 같은 규칙이어야 한다
--   ① 이 트리거              — 서버의 마지막 그물
--   ② 앱 checkRepurchaseLimit() — 회원이 실제로 보는 첫 관문 (index.html)
--   ③ 알림                   — 풀린 것을 알려준다 (이 파일 ③)
--   앱이 먼저 막으므로, ②를 안 고치면 이 트리거를 고쳐도 **아무 일도 안 난다.**
--   반대로 ②만 고치면 앱은 열어주는데 서버가 막아 결제 직전에 튕긴다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포(BUILD 2026.08.31-b 이상)와 **같이** 나가야 짝이 맞는다.
-- ═══════════════════════════════════════════════════════════════

-- 며칠로 풀 것인가. 여기 한 곳만 고치면 서버 전체가 따라온다.
--   ⚠ 앱에도 같은 값이 있다 — index.html 의 REPURCHASE_RELEASE_DAYS.
--     한쪽만 바꾸면 앱과 서버 판정이 어긋난다.
create or replace function public.taam_repurchase_release_days()
returns int language sql immutable as $$ select 7 $$;

comment on function public.taam_repurchase_release_days() is
  '재구매 제한 자동 해제 일수. 앱의 REPURCHASE_RELEASE_DAYS 와 같아야 한다.';


-- 이 티켓의 「판매 오픈 시각」. 모르면 null 을 준다.
create or replace function public.taam_ticket_sale_opened_at(p_ticket_id text)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select case
           -- 오픈 예약이면 그 시각이 진짜 판매 시작이다
           when tp.sale_open_at is not null then tp.sale_open_at::timestamptz
           -- 아니면 등록일 (날짜만 있으므로 그날 0시로 본다)
           when tp.reg_date is not null then (tp.reg_date::date)::timestamptz
           else null
         end
    from public.ticket_products tp
   where tp.id::text = p_ticket_id
$$;


-- 이 티켓은 재구매 제한이 풀렸는가
create or replace function public.taam_repurchase_released(p_ticket_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.taam_ticket_sale_opened_at(p_ticket_id)
      <= now() - (public.taam_repurchase_release_days() || ' days')::interval,
    false   -- ⚠ 오픈 시각을 모르면 풀지 않는다. 제한이 기본이고 해제가 예외다
  )
$$;

comment on function public.taam_repurchase_released(text) is
  '판매 오픈 후 N일이 지났는가. 오픈 시각을 모르면 false(제한 유지).';


-- ═══════════════════════════════════════════════════════════════
-- ① 서버 가드에 해제를 넣는다
-- ═══════════════════════════════════════════════════════════════
--   기존 taam_guard_repurchase() 에 한 조각만 더한다. 나머지 예외
--   (같은 날·MAN-·INVH-·INV-·취소·어드민·면제)는 그대로다.
create or replace function public.taam_guard_repurchase()
returns trigger
language plpgsql
set search_path = public
as $rep$
declare
  v_days   int;
  v_prev   record;
  v_exempt boolean := false;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if new.user_id is null or new.restaurant_id is null
     or new.reservation_date is null then
    return new;
  end if;

  if new.purchase_id like 'MAN-%'
     or new.purchase_id like 'INVH-%'
     or new.purchase_id like 'INV-%'
     or coalesce(new.extra_data ->> 'manualEntry', '') in ('true','1')
     or coalesce(new.extra_data ->> 'inviteHold',  '') in ('true','1') then
    return new;
  end if;

  if coalesce(new.status, '') in ('cancelled','canceled') then
    return new;
  end if;

  if public._taam_uid_is_super() then
    return new;
  end if;
  if exists (select 1 from public.profiles p
              where p.id = auth.uid() and p.role = 'admin') then
    return new;
  end if;

  select coalesce(p.single_device_exempt, false) into v_exempt
    from public.profiles p where p.id = new.user_id;
  if coalesce(v_exempt, false) then
    return new;
  end if;

  -- 🆕 2026.08-31: 판매 오픈 7일이 지난 티켓은 제한을 풀어 준다.
  --   ⚠ 이 검사를 「기존 예약 찾기」보다 먼저 한다. 어차피 통과시킬 건데
  --     굳이 훑을 이유가 없고, 순서가 앞에 있어야 읽는 사람이 바로 안다.
  if new.ticket_product_id is not null
     and public.taam_repurchase_released(new.ticket_product_id::text) then
    return new;
  end if;

  select r.repurchase_day into v_days
    from public.restaurants r
   where r.id::text = new.restaurant_id::text;
  if coalesce(v_days, 0) = 0 then
    return new;
  end if;

  select k.purchase_id, k.reservation_date
    into v_prev
    from public.tickets k
   where k.user_id = new.user_id
     and k.restaurant_id::text = new.restaurant_id::text
     and k.purchase_id is distinct from new.purchase_id
     and k.reservation_date is not null
     and coalesce(k.status,'') not in ('cancelled','canceled')
     and k.purchase_id not like 'MAN-%'
     and k.purchase_id not like 'INVH-%'
     and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
     and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
     and abs(k.reservation_date::date - new.reservation_date::date) > 0
     and abs(k.reservation_date::date - new.reservation_date::date) < v_days
   order by abs(k.reservation_date::date - new.reservation_date::date)
   limit 1;

  if found then
    raise exception
      'REPURCHASE_BLOCKED: 이 매장은 % 일 재구매 제한이 있습니다 (기존 방문일 %)',
      v_days, v_prev.reservation_date
      using errcode = '42501';
  end if;

  return new;
end;
$rep$;

drop trigger if exists trg_taam_repurchase_guard on public.tickets;
create trigger trg_taam_repurchase_guard
  before insert on public.tickets
  for each row execute function public.taam_guard_repurchase();


-- ═══════════════════════════════════════════════════════════════
-- ② 누가 풀렸는지 — 알림 대상을 찾는다
-- ═══════════════════════════════════════════════════════════════
--   「이 티켓 때문에 막혀 있던 회원」이다. 조건이 셋 다 맞아야 한다.
--     · 같은 매장에 살아 있는 예약이 있다
--     · 그 방문일과 이 티켓 날짜의 간격이 제한 안이다 (= 막혀 있었다)
--     · 아직 이 티켓을 사지 않았다
create or replace function public.taam_repurchase_release_targets(p_ticket_id text)
returns table (user_id uuid, display_name text, prev_visit date, gap int)
language sql
stable
security definer
set search_path = public
as $$
  with tk as (
    select tp.id::text as tid, tp.rest_id::text as rid, tp.date as tdate
    from public.ticket_products tp
    where tp.id::text = p_ticket_id
  ),
  tgt as (
    select distinct on (k.user_id)
           k.user_id,
           k.reservation_date::date as prev_visit,
           abs(k.reservation_date::date - (tk.tdate)::date) as gap
    from public.tickets k
    join tk on k.restaurant_id::text = tk.rid
    join public.restaurants r on r.id::text = tk.rid
    where k.user_id is not null
      and k.reservation_date is not null
      and tk.tdate is not null
      and coalesce(k.status,'') not in ('cancelled','canceled')
      and k.purchase_id not like 'MAN-%'
      and k.purchase_id not like 'INVH-%'
      and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
      and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
      and coalesce(r.repurchase_day, 0) > 0
      and abs(k.reservation_date::date - (tk.tdate)::date) > 0
      and abs(k.reservation_date::date - (tk.tdate)::date) < r.repurchase_day
      -- 이미 이 티켓을 산 사람은 뺀다
      and not exists (
        select 1 from public.tickets b
         where b.user_id = k.user_id
           and b.ticket_product_id::text = tk.tid
           and coalesce(b.status,'') not in ('cancelled','canceled')
      )
    order by k.user_id, abs(k.reservation_date::date - (tk.tdate)::date)
  )
  select t.user_id,
         coalesce(p.display_name, '(이름 없음)'),
         t.prev_visit,
         t.gap
  from tgt t
  left join public.profiles p on p.id = t.user_id
$$;

revoke all on function public.taam_repurchase_release_targets(text) from public;
grant execute on function public.taam_repurchase_release_targets(text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- ③ 알림 — 풀린 날 하루 한 번, 자동으로
-- ═══════════════════════════════════════════════════════════════
--   푸시(잠금화면)는 Edge Function 을 거쳐야 하지만, 인앱 알림은 notifications
--   테이블에 넣으면 종 아이콘에 바로 뜬다. 초대 홀드 만료가 이미 그렇게 한다.
--   pg_cron 만으로 완결되므로 실패할 곳이 적다.
--
--   ⚠ 같은 사람에게 같은 티켓으로 두 번 넣지 않는다. payload 로 확인한다.
create or replace function public.taam_notify_repurchase_released()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int := 0;
begin
  with opened as (
    -- 판매 오픈 7일이 막 지난 티켓 (아직 방문 전 · 판매중)
    select tp.id::text as tid, tp.rest_name, tp.date as tdate
    from public.ticket_products tp
    where public.taam_repurchase_released(tp.id::text)
      and coalesce(tp.status,'') <> 'soldout'
      and tp.date is not null
      and (tp.date)::date >= current_date
  ),
  ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select g.user_id,
           'repurchase_released',
           '예약이 열렸습니다',
           coalesce(o.rest_name,'') || ' · ' || coalesce(o.tdate,'')
             || ' — 재구매 제한이 풀려 지금 예약하실 수 있습니다',
           '/',
           jsonb_build_object('ticket_product_id', o.tid, 'kind', 'repurchase_released')
    from opened o
    cross join lateral public.taam_repurchase_release_targets(o.tid) g
    where not exists (
      select 1 from public.notifications n
       where n.user_id = g.user_id
         and n.type = 'repurchase_released'
         and n.payload ->> 'ticket_product_id' = o.tid
    )
    returning 1
  )
  select count(*) into v_n from ins;
  return v_n;
end;
$$;

comment on function public.taam_notify_repurchase_released() is
  '판매 오픈 7일이 지나 재구매 제한이 풀린 티켓을, 막혀 있던 회원에게 알린다. 같은 티켓으로 두 번 보내지 않는다.';

-- 하루 한 번 (한국시간 오전 10시 = UTC 01:00)
--   자주 돌 이유가 없다. 7일이 지나는 순간을 분 단위로 맞출 필요도 없고,
--   회원에게 새벽에 알림이 가면 안 된다.
--   ⚠ pg_cron 이 없는 환경(로컬 검증용 Postgres 등)에서도 파일 전체가 죽지
--     않게 감싼다. 운영 Supabase 에는 이미 깔려 있다 — 좌석 홀드 스윕이 쓴다.
do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice '[repurchase] pg_cron 이 없어 자동 알림 예약을 건너뜁니다.';
    return;
  end if;
  execute 'create extension if not exists pg_cron';
  perform cron.unschedule('taam_notify_repurchase_released')
    where exists (select 1 from cron.job where jobname = 'taam_notify_repurchase_released');
  perform cron.schedule(
    'taam_notify_repurchase_released',
    '0 1 * * *',                                 -- UTC 01:00 = KST 10:00
    'select public.taam_notify_repurchase_released();'
  );
  raise notice '[repurchase] 자동 알림 예약 완료 — 매일 한국시간 오전 10시';
end
$cron$;


-- ═══════════════════════════════════════════════════════════════
-- ④ 확인 — 지금 무엇이 풀려 있고 누가 알림을 받나
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 크론이 처음 도는 내일 오전 10시에 이 사람들에게 알림이 간다.
--     명단이 이상하면 크론을 먼저 끄고 이야기한다:
--       select cron.unschedule('taam_notify_repurchase_released');
select coalesce(tp.rest_name,'(매장 없음)')            as "매장",
       tp.date                                        as "티켓 날짜",
       (public.taam_ticket_sale_opened_at(tp.id::text))::date as "판매 오픈",
       case when public.taam_repurchase_released(tp.id::text)
            then '✅ 풀림' else '제한 유지' end        as "상태",
       g.display_name                                 as "알림 받을 회원",
       g.prev_visit                                   as "그 회원의 기존 방문일",
       g.gap                                          as "간격(일)"
from public.ticket_products tp
left join lateral public.taam_repurchase_release_targets(tp.id::text) g on true
where tp.date is not null
  and (tp.date)::date >= current_date
  and coalesce(tp.status,'') <> 'soldout'
  and public.taam_repurchase_released(tp.id::text)
order by tp.date, g.display_name;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   select cron.unschedule('taam_notify_repurchase_released');   -- 알림만 끈다
--   create or replace function public.taam_repurchase_release_days()
--     returns int language sql immutable as $$ select 99999 $$;  -- 해제를 사실상 끈다
--
--   두 번째 것은 트리거를 안 건드리고 해제만 무력화한다. 앱은 여전히
--   7일로 판단하므로 「앱은 열어주는데 서버가 막는」 상태가 된다 —
--   급할 때 쓰고, 오래 두지 않는다.
