-- ═══════════════════════════════════════════════════════════════
-- TAAM — ① 티켓에 방문 기록을 남긴다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   「이 매장 단골에게만 보이는 티켓」을 만들려면 방문 횟수를 세야 하고,
--   방문 횟수를 세려면 **왔다는 사실**이 DB 에 있어야 한다.
--   지금 그게 갈라져 있다.
--
--     reservation_requests   visit_status = attended / no_show  ✅ 있다
--     tickets                결제 상태뿐                        ❌ 없다
--
--   TAAM 의 본체는 티켓이다. 이대로면 모든 회원이 영원히 「첫 방문」이다.
--
-- 왜 status 를 쓰지 않고 새 컬럼을 만드나
--   status='completed' 가 이미 「방문 완료」 뜻으로 쓰이고 있다(앱 주석·화면).
--   그런데 status 는 **결제 상태**다. 방문 상태를 겸하면 두 가지가 깨진다.
--     · 노쇼를 넣을 자리가 없다. status='no_show' 로 하면 유효한 결제 건이
--       구매 내역·매출 집계에서 통째로 사라진다. 노쇼도 돈은 받은 건이다.
--     · status === 'active' 로 거르는 코드가 앱 곳곳에 있다. 값을 늘리면
--       그 필터가 전부 흔들린다.
--   그래서 결제 상태와 방문 상태를 분리한다.
--
-- ⚠ 이 SQL 은 **앱 배포와 무관하다.** 지금 돌려도 앱은 그대로 돈다 —
--   새 컬럼은 비어 있고, 새 함수는 아무도 부르지 않는다.
--   (원장 서버화 때와 같은 모양: 앱이 안 넘기면 아무 일도 안 일어난다)
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══════════════════════════════════════════════════════════════
-- ① 컬럼
-- ═══════════════════════════════════════════════════════════════
--   실측한 타입 (2026-08-31):
--     tickets.id uuid · user_id uuid · restaurant_id **text** · status text
--     tickets.reservation_date **text** (YYYY-MM-DD 문자열)
--     restaurant_admins.user_id uuid · restaurant_id **text**
--     reservation_requests.user_id uuid · venue_id text · reserve_date date
--   restaurants.id 만 uuid 다. tickets 는 그걸 text 로 들고 있다.

alter table public.tickets
  add column if not exists visit_status    text,
  add column if not exists visit_marked_at timestamptz,
  add column if not exists visit_marked_by uuid;

-- null = 아직 기록 안 함. 그게 기본이고 정상이다.
alter table public.tickets drop constraint if exists tickets_visit_status_chk;
alter table public.tickets add constraint tickets_visit_status_chk
  check (visit_status is null or visit_status in ('attended', 'no_show'));

-- 방문 횟수는 (회원 × 매장)으로 센다. 그 조합에 인덱스를 준다.
create index if not exists idx_tickets_visit_count
  on public.tickets (user_id, restaurant_id)
  where visit_status = 'attended';

comment on column public.tickets.visit_status is
  '방문 결과: null(미기록) | attended(방문) | no_show(노쇼). 결제 상태(status)와 별개다.';


-- ═══════════════════════════════════════════════════════════════
-- ② 회원이 자기 방문을 스스로 찍지 못하게 막는다
-- ═══════════════════════════════════════════════════════════════
--   tickets_update_own 정책이 (auth.uid() = user_id) 로 열려 있다.
--   가드에 안 넣으면 회원이 자기 티켓을 attended 로 찍어 방문 횟수를 늘리고,
--   그걸로 「단골 전용」 티켓을 연다. 새 컬럼을 만들 때마다 이걸 봐야 한다.
--
--   ⚠ 기존 가드를 그대로 유지하고 방문 검사만 더한다.
--     (덮어쓰는 것이라 기존 조건을 하나라도 빠뜨리면 그게 구멍이 된다)

create or replace function public.taam_guard_ticket_row()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 서버가 하는 일은 막지 않는다.
  --   service_role · postgres · SECURITY DEFINER RPC · 좌석 트리거 · 마이그레이션
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- 슈퍼어드민은 통과 (환불 처리·인원 조정·수동 예약을 계속 해야 한다)
  if public._taam_uid_is_super() then
    return new;
  end if;

  -- ── 여기부터는 회원 세션이다 ──────────────────────────────────

  -- 남의 것으로 옮기기·구매ID 갈아치우기
  if new.user_id     is distinct from old.user_id
     or new.purchase_id is distinct from old.purchase_id then
    raise exception '예약의 소유자·구매ID 는 바꿀 수 없습니다' using errcode = '42501';
  end if;

  -- 좌석 수를 바꾸는 것은 돈이 움직이는 일이다. 전용 RPC 로만 한다.
  if coalesce(new.party_size, 0) is distinct from coalesce(old.party_size, 0) then
    raise exception '인원은 직접 바꿀 수 없습니다 (taam_change_party_size 를 쓰세요)'
      using errcode = '42501';
  end if;

  -- 🆕 방문 기록은 매장·운영자가 남기는 것이다. 회원이 스스로 못 찍는다.
  if new.visit_status is distinct from old.visit_status
     or new.visit_marked_at is distinct from old.visit_marked_at
     or new.visit_marked_by is distinct from old.visit_marked_by then
    raise exception '방문 기록은 직접 바꿀 수 없습니다 (taam_set_ticket_visit 를 쓰세요)'
      using errcode = '42501';
  end if;

  -- 매장·방문일 갈아타기 (재구매 제한·좌석 집계가 통째로 어긋난다)
  if new.restaurant_id is distinct from old.restaurant_id
     or new.reservation_date is distinct from old.reservation_date then
    raise exception '예약의 매장·날짜는 직접 바꿀 수 없습니다' using errcode = '42501';
  end if;

  -- 취소된 건을 되살리기
  if old.status = 'cancelled' and new.status is distinct from old.status then
    raise exception '취소된 예약은 되살릴 수 없습니다' using errcode = '42501';
  end if;

  -- 금액은 「결제 확정」 순간에만 정해진다 (status 'hold' → 'active').
  if coalesce(new.price, 0) is distinct from coalesce(old.price, 0) then
    if not (old.status = 'hold' and new.status = 'active') then
      raise exception '금액은 결제 확정 때만 정해집니다' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- 트리거도 같이 건다. 함수만 갈아 끼우면 트리거가 없는 DB 에서는 아무 일도
-- 안 일어난다 — 그리고 그걸 알아채기가 어렵다. 이 파일 하나로 완결되게 한다.
drop trigger if exists trg_taam_guard_ticket_row on public.tickets;
create trigger trg_taam_guard_ticket_row
  before update on public.tickets
  for each row execute function public.taam_guard_ticket_row();

comment on function public.taam_guard_ticket_row() is
  '회원이 자기 예약의 인원·금액·매장·날짜·소유자·방문기록을 직접 고치지 못하게 막는다. 결제 확정(hold→active)과 취소만 통과.';


-- ═══════════════════════════════════════════════════════════════
-- ③ 누가 이 티켓의 방문을 기록할 수 있나
-- ═══════════════════════════════════════════════════════════════
--   슈퍼어드민 · 그 매장 어드민. 다른 매장 어드민은 안 된다.
--   restaurant_admins.restaurant_id 는 text 다 — 캐스팅하지 않는다.

create or replace function public.taam_can_mark_visit(p_restaurant_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._taam_uid_is_super()
      or exists (
           select 1 from public.restaurant_admins ra
            where ra.user_id = auth.uid()
              and ra.restaurant_id = p_restaurant_id
         )
$$;


-- ═══════════════════════════════════════════════════════════════
-- ④ 방문 · 노쇼를 남긴다
-- ═══════════════════════════════════════════════════════════════
--   p_status: 'attended' | 'no_show' | null(기록 취소 — 잘못 눌렀을 때)

create or replace function public.taam_set_ticket_visit(
  p_ticket_id uuid,
  p_status    text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_t      public.tickets%rowtype;
  v_today  text;
begin
  if p_status is not null and p_status not in ('attended', 'no_show') then
    raise exception '방문 상태는 attended · no_show · 비움만 가능합니다' using errcode = '22023';
  end if;

  select * into v_t from public.tickets where id = p_ticket_id;
  if not found then
    raise exception '예약을 찾을 수 없습니다' using errcode = 'P0002';
  end if;

  if not public.taam_can_mark_visit(v_t.restaurant_id) then
    raise exception '이 매장의 방문을 기록할 권한이 없습니다' using errcode = '42501';
  end if;

  -- 취소된 건에는 방문이 없다.
  if v_t.status = 'cancelled' then
    raise exception '취소된 예약에는 방문을 기록할 수 없습니다' using errcode = '42501';
  end if;

  -- 아직 오지 않은 날을 미리 찍지 못하게.
  --   ⚠ reservation_date 는 **text** 다. 날짜로 캐스팅하면 형식이 어긋난 옛 행에서
  --     통째로 터진다. ISO 문자열끼리는 사전순이 곧 날짜순이라 그대로 비교한다.
  --     형식이 아닌 값은 막지 않는다 — 수동 입력 건을 잠그면 안 된다.
  v_today := to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD');
  if p_status is not null
     and v_t.reservation_date ~ '^\d{4}-\d{2}-\d{2}$'
     and v_t.reservation_date > v_today then
    raise exception '아직 방문일이 지나지 않았습니다 (%)', v_t.reservation_date
      using errcode = '42501';
  end if;

  update public.tickets
     set visit_status    = p_status,
         visit_marked_at = case when p_status is null then null else now() end,
         visit_marked_by = case when p_status is null then null else auth.uid() end
   where id = p_ticket_id;

  return jsonb_build_object(
    'ok', true,
    'ticket_id', p_ticket_id,
    'visit_status', p_status,
    'restaurant_id', v_t.restaurant_id,
    'user_id', v_t.user_id
  );
end;
$$;

revoke all on function public.taam_set_ticket_visit(uuid, text) from public;
grant execute on function public.taam_set_ticket_visit(uuid, text) to authenticated;

comment on function public.taam_set_ticket_visit(uuid, text) is
  '티켓에 방문·노쇼를 기록한다. 슈퍼어드민·그 매장 어드민만. 취소건·미래 날짜는 거부.';


-- ═══════════════════════════════════════════════════════════════
-- ⑤ 이 회원이 이 매장에 몇 번 왔나
-- ═══════════════════════════════════════════════════════════════
--   티켓 방문 + 예약 요청 방문을 같이 센다.
--
--   ⚠ 두 표의 매장 id 공간이 다르다.
--       tickets.restaurant_id            restaurants.id 를 text 로 (uuid 문자열)
--       reservation_requests.venue_id    대개 venue 슬러그 (sushi-ao-tokyo-b …)
--     같은 값일 때만 예약 요청이 합산된다. 어긋나면 0 을 더할 뿐 —
--     **틀린 수가 나오지는 않는다.** 덜 셀 뿐이다.
--     (venue ↔ restaurant 매핑이 정리되면 그때 완전해진다)

create or replace function public.taam_visit_count(
  p_user       uuid,
  p_restaurant text
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  -- 남의 방문 횟수를 아무나 못 본다.
  if not (
       p_user = auth.uid()
    or public.taam_can_mark_visit(p_restaurant)
  ) then
    raise exception '조회 권한이 없습니다' using errcode = '42501';
  end if;

  select
    (select count(*) from public.tickets t
      where t.user_id = p_user
        and t.restaurant_id = p_restaurant
        and t.visit_status = 'attended')
  + (select count(*) from public.reservation_requests r
      where r.user_id = p_user
        and r.venue_id = p_restaurant
        and r.visit_status = 'attended')
  into v_n;

  return coalesce(v_n, 0);
end;
$$;

revoke all on function public.taam_visit_count(uuid, text) from public;
grant execute on function public.taam_visit_count(uuid, text) to authenticated;

comment on function public.taam_visit_count(uuid, text) is
  '이 회원이 이 매장에 몇 번 왔나 (티켓 + 예약요청, attended 만). 취소·노쇼는 세지 않는다.';


-- ═══════════════════════════════════════════════════════════════
-- ⑥ 이미 있는 것을 옮긴다 — status='completed' 는 「방문 완료」였다
-- ═══════════════════════════════════════════════════════════════
--   앱 주석과 화면이 그렇게 쓰고 있었다 (index.html:27790 · 32632).
--   status 는 건드리지 않는다. 방문 기록만 채운다.
--   ⚠ 언제 방문했는지는 남아 있지 않아 created_at 으로 근사한다.

update public.tickets
   set visit_status    = 'attended',
       visit_marked_at = coalesce(visit_marked_at, created_at)
 where status = 'completed'
   and visit_status is null;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다 (SQL Editor 는 마지막 결과만 보여준다)
-- ═══════════════════════════════════════════════════════════════
select '① 컬럼'          as "구분",
       string_agg(column_name, ' · ' order by column_name) as "값1",
       count(*)::text || ' / 3'                            as "값2"
  from information_schema.columns
 where table_schema = 'public' and table_name = 'tickets'
   and column_name in ('visit_status', 'visit_marked_at', 'visit_marked_by')
union all
select '② 함수',
       string_agg(proname, ' · ' order by proname),
       count(*)::text || ' / 3'
  from pg_proc
 where pronamespace = 'public'::regnamespace
   and proname in ('taam_set_ticket_visit', 'taam_visit_count', 'taam_can_mark_visit')
union all
select '③ 가드에 방문 검사 들어갔나',
       case when prosrc like '%visit_status%' then '✅ 들어감' else '❌ 없음' end,
       '—'
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_guard_ticket_row'
union all
select '④ 방문 기록된 티켓',
       coalesce(visit_status, '(미기록)'),
       count(*)::text || ' 건'
  from public.tickets
 group by visit_status
 order by 1, 2;
