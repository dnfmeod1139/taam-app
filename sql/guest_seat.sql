-- ═══════════════════════════════════════════════════════════════
-- TAAM — 게스트 초대석 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 무엇
--   게스트(A)가 살 수 있는 유일한 자리. 회차당 1~2석, 비정기적으로 연다.
--   ⚠ 「일반 판매」가 아니다. 화면에도 그렇게 안 적는다 —
--     한 번 「아무나 살 수 있는 곳」이 되면 되돌릴 수 없다.
--
-- 왜 새 축을 안 만드나
--   이미 min_tier='A'(일반공개)로 게스트가 살 수 있는 티켓을 가르고 있다.
--   여기에 guest_open 이라는 두 번째 축을 세우면 둘이 어긋나는 순간
--   「보이는데 못 사는」 또는 그 반대가 된다. **같은 자리를 승격시킨다** —
--   min_tier='A' 였던 티켓은 그대로 게스트석이 되고, 여기에 이유·가격·
--   수량이 붙는다.
--
-- 서버가 지키는 것 (앱이 아니라)
--   ① 이유 없이는 못 연다        — 이유는 서사다. 빠지면 그냥 할인이 된다
--   ② 매장이 허락해야 연다        — 핵심 관계 매장은 기본 잠김
--   ③ 정한 수량을 넘겨 못 판다
--   ④ 게스트 구매는 **확정 대기**로 들어간다 — 대표 확인 뒤 확정
--   ⑤ 게스트는 예치금을 못 쓴다  — 애초에 잔액이 없다(별도 가드)
--
-- 실행: Supabase SQL Editor. ⚠ general_member_tier.sql 다음.
--   읽는 법: 맨 아래가 전부 ✅ 여야 정상.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 칸 ──────────────────────────────────────────────────────
alter table public.ticket_products add column if not exists guest_open        boolean not null default false;
alter table public.ticket_products add column if not exists guest_open_reason text;
alter table public.ticket_products add column if not exists guest_price       int;
alter table public.ticket_products add column if not exists guest_seat_qty    int not null default 0;
alter table public.ticket_products add column if not exists guest_opened_at   timestamptz;
alter table public.ticket_products add column if not exists guest_opened_by   uuid;

comment on column public.ticket_products.guest_open_reason is
  '게스트석을 여는 이유. 필수다 — 「셰프의 요청으로」「○주년을 기념해」. 이유가 빠지면 그냥 할인이 된다.';

-- ⚠ 매장이 허락해야 연다. **기본은 잠김**이다 —
--   핵심 관계 매장(스기타·사이토급)이 실수로 열리는 쪽이 훨씬 비싸다.
alter table public.restaurants add column if not exists guest_seat_allowed boolean not null default false;

-- 지금까지 min_tier='A' 로 열어 둔 티켓을 게스트석으로 옮긴다.
--   ⚠ 이유가 없으니 **닫힌 채로** 옮긴다. 어드민이 이유를 적어야 열린다.
--     열린 채로 옮기면 이유 없는 게스트석이 라이브에 생긴다.
update public.ticket_products
   set guest_open = false
 where upper(coalesce(btrim(min_tier), '')) = 'A'
   and guest_open is not true;


-- ── ② 지금 이 티켓의 게스트석 상태 ────────────────────────────
create or replace function public.taam_guest_seat_state(p_ticket_product_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare tp public.ticket_products%rowtype; v_allowed boolean; v_sold int;
begin
  select * into tp from public.ticket_products where id::text = p_ticket_product_id;
  if not found then return jsonb_build_object('found', false); end if;

  select coalesce(r.guest_seat_allowed, false) into v_allowed
    from public.restaurants r where r.id::text = tp.rest_id::text;

  -- 게스트가 산 자리만 센다. 회원이 산 자리는 게스트석 수량과 무관하다.
  select count(*) into v_sold
    from public.tickets t
    join public.profiles p on p.id = t.user_id
   where t.ticket_product_id::text = p_ticket_product_id
     and coalesce(t.status,'') not in ('cancelled','canceled')
     and upper(coalesce(p.membership_tier,'')) = 'A';

  return jsonb_build_object(
    'found',   true,
    'open',    coalesce(tp.guest_open, false),
    'allowed', coalesce(v_allowed, false),
    'reason',  tp.guest_open_reason,
    'price',   tp.guest_price,
    'qty',     coalesce(tp.guest_seat_qty, 0),
    'sold',    coalesce(v_sold, 0),
    'left',    greatest(0, coalesce(tp.guest_seat_qty,0) - coalesce(v_sold,0)),
    'opened_at', tp.guest_opened_at
  );
end;
$$;
revoke all on function public.taam_guest_seat_state(text) from public;
grant execute on function public.taam_guest_seat_state(text) to anon, authenticated;


-- ── ③ 가드 — 게스트는 게스트석만, 수량 안에서만 ───────────────
--   기존 등급 가드를 갈아 끼운다. 종전에는 min_tier='A' 면 통과였는데,
--   이제 **게스트석으로 열려 있어야** 한다(이유·수량·매장 허락 포함).
create or replace function public.taam_guard_ticket_tier()
returns trigger
language plpgsql security definer set search_path = public
as $tier$
declare
  v_need text; v_mine text;
  tp public.ticket_products%rowtype;
  v_allowed boolean; v_sold int;
begin
  if new.ticket_product_id is null or btrim(new.ticket_product_id::text) = '' then
    return new;
  end if;
  if coalesce(new.purchase_id, '') like 'MAN-%'  then return new; end if;
  if coalesce(new.purchase_id, '') like 'INV-%'  then return new; end if;
  if coalesce(new.purchase_id, '') like 'INVH-%' then return new; end if;
  if coalesce(new.status, '') in ('cancelled','canceled') then return new; end if;

  -- 슈퍼어드민만 면제. 운영·검수에서 모든 티켓을 열어봐야 한다.
  if public._taam_uid_is_super() then return new; end if;

  select * into tp from public.ticket_products where id::text = new.ticket_product_id::text;
  v_need := upper(coalesce(btrim(tp.min_tier), ''));
  v_mine := public.taam_user_tier(new.user_id);

  -- ── 게스트(A) ────────────────────────────────────────────
  if upper(coalesce(v_mine, '')) = 'A' then
    if tp.id is null or not coalesce(tp.guest_open, false) then
      raise exception
        'GUEST_BLOCKED: 이 자리는 멤버십 회원만 예약할 수 있습니다'
        using errcode = '42501';
    end if;
    -- 이유 없는 게스트석은 열린 것으로 치지 않는다
    if coalesce(btrim(tp.guest_open_reason), '') = '' then
      raise exception 'GUEST_BLOCKED: 게스트석 안내가 준비되지 않았습니다'
        using errcode = '42501';
    end if;
    -- 매장이 허락해야 한다
    select coalesce(r.guest_seat_allowed, false) into v_allowed
      from public.restaurants r where r.id::text = tp.rest_id::text;
    if not coalesce(v_allowed, false) then
      raise exception 'GUEST_BLOCKED: 이 매장은 게스트석을 열지 않습니다'
        using errcode = '42501';
    end if;
    -- 정한 수량 안에서만. ⚠ 여기서 세지 않으면 두 사람이 동시에 눌러
    --   한 석짜리 게스트석이 두 장 나간다.
    select count(*) into v_sold
      from public.tickets t
      join public.profiles p on p.id = t.user_id
     where t.ticket_product_id::text = new.ticket_product_id::text
       and coalesce(t.status,'') not in ('cancelled','canceled')
       and upper(coalesce(p.membership_tier,'')) = 'A';
    if coalesce(v_sold,0) >= coalesce(tp.guest_seat_qty, 0) then
      raise exception 'GUEST_BLOCKED: 게스트석이 모두 나갔습니다 (%/%)',
        v_sold, coalesce(tp.guest_seat_qty,0) using errcode = '42501';
    end if;

    -- ⚠ 게스트 구매는 **확정 대기**로 들어간다. 대표가 확인한 뒤 확정한다.
    --   앱이 아니라 여기서 세운다 — 앱이 보낸 status 를 믿지 않는다.
    new.status := 'pending_confirm';
    return new;
  end if;

  -- ── 회원 (기존 규칙 그대로) ──────────────────────────────
  if v_need is null or public.taam_tier_rank(v_need) = 0 then
    return new;
  end if;

  -- ⚠ 「일반공개(min_tier=A)」는 **하한이 아니라 개방**이다. 게스트가 아닌
  --   사람에게는 그대로 열려 있어야 한다.
  --   이 줄을 빼면 등급이 아예 없는 옛 회원(rank 0)이 min_tier='A' 티켓에서
  --   튕긴다 — 열어 놓고 못 사게 되는 정반대의 결과가 된다.
  --   (게스트석 가드를 새로 쓰면서 한 번 빠뜨렸고, t_tier 가 잡았다)
  if public.taam_tier_is_open(v_need) then
    return new;
  end if;
  if public.taam_tier_rank(v_mine) >= public.taam_tier_rank(v_need) then
    return new;
  end if;

  raise exception
    'TIER_BLOCKED: 이 티켓은 % 등급 이상만 구매할 수 있습니다 (회원 등급 %)',
    v_need, coalesce(v_mine, '없음')
    using errcode = '42501';
end;
$tier$;

comment on function public.taam_guard_ticket_tier() is
  '게스트(A)는 게스트석만 — 이유·매장 허락·수량까지 서버가 본다. 게스트 구매는 pending_confirm 으로 들어간다. 슈퍼어드민·초대·수동입력은 예외.';


-- ── ④ 어드민 — 게스트석 열기 ──────────────────────────────────
--   ⚠ 이유 없이는 못 연다. 이유가 서사이고, 빠지면 그냥 할인이 된다.
create or replace function public.taam_guest_seat_open(
  p_ticket_product_id text,
  p_reason text,
  p_price  int,
  p_qty    int
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare tp public.ticket_products%rowtype; v_allowed boolean;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into tp from public.ticket_products where id::text = p_ticket_product_id;
  if not found then raise exception '티켓을 찾을 수 없습니다' using errcode = 'P0002'; end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception '여는 이유를 적어 주세요 — 「셰프의 요청으로」처럼 손님에게 그대로 보입니다'
      using errcode = '22023';
  end if;
  if coalesce(p_qty, 0) <= 0 then
    raise exception '몇 석을 열지 적어 주세요' using errcode = '22023';
  end if;
  if coalesce(p_price, 0) <= 0 then
    raise exception '게스트가를 적어 주세요' using errcode = '22023';
  end if;

  select coalesce(r.guest_seat_allowed, false) into v_allowed
    from public.restaurants r where r.id::text = tp.rest_id::text;
  if not coalesce(v_allowed, false) then
    raise exception '이 매장은 게스트석을 허용하지 않습니다 — 매장 설정에서 먼저 켜세요'
      using errcode = '42501';
  end if;

  update public.ticket_products
     set guest_open = true,
         guest_open_reason = btrim(p_reason),
         guest_price = p_price,
         guest_seat_qty = p_qty,
         guest_opened_at = now(),
         guest_opened_by = auth.uid()
   where id::text = p_ticket_product_id;

  return public.taam_guest_seat_state(p_ticket_product_id);
end;
$$;
revoke all on function public.taam_guest_seat_open(text, text, int, int) from public;
grant execute on function public.taam_guest_seat_open(text, text, int, int) to authenticated;

create or replace function public.taam_guest_seat_close(p_ticket_product_id text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  -- ⚠ 이유·가격·수량은 지우지 않는다. 다시 열 때 그대로 쓰고,
  --   이미 산 사람에게 「무슨 이유로 샀는지」가 남아 있어야 한다.
  update public.ticket_products set guest_open = false
   where id::text = p_ticket_product_id;
  return public.taam_guest_seat_state(p_ticket_product_id);
end;
$$;
revoke all on function public.taam_guest_seat_close(text) from public;
grant execute on function public.taam_guest_seat_close(text) to authenticated;

-- 매장별 허용 스위치
create or replace function public.taam_guest_seat_allow(p_rest_id text, p_on boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  update public.restaurants set guest_seat_allowed = coalesce(p_on, false)
   where id::text = p_rest_id;
  get diagnostics n = row_count;
  if n = 0 then raise exception '매장을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  -- 끄면 열려 있던 게스트석도 같이 닫는다. 매장이 안 된다는데 자리가
  -- 열려 있으면, 팔린 뒤에야 알게 된다.
  if not coalesce(p_on, false) then
    update public.ticket_products set guest_open = false
     where rest_id::text = p_rest_id and guest_open;
  end if;
  return jsonb_build_object('ok', true, 'allowed', coalesce(p_on,false));
end;
$$;
revoke all on function public.taam_guest_seat_allow(text, boolean) from public;
grant execute on function public.taam_guest_seat_allow(text, boolean) to authenticated;


-- ── ⑤ 어드민 — 확정 대기 큐 ───────────────────────────────────
create or replace function public.taam_guest_seat_queue(p_limit int default 200)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_out jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_out
    from (select t.id, t.user_id, t.ticket_product_id, t.purchase_id,
                 t.price, t.party_size, t.reservation_date, t.created_at, t.status,
                 p.display_name, p.phone,
                 tp.guest_open_reason, tp.guest_price,
                 r.name as venue_name
            from public.tickets t
            left join public.profiles p on p.id = t.user_id
            left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
            left join public.restaurants r on r.id::text = tp.rest_id::text
           where coalesce(t.status,'') = 'pending_confirm'
           order by t.created_at desc
           limit greatest(1, least(coalesce(p_limit,200), 500))) x;
  return v_out;
end;
$$;
revoke all on function public.taam_guest_seat_queue(int) from public;
grant execute on function public.taam_guest_seat_queue(int) to authenticated;

-- 확정 — 대표가 확인한 뒤
create or replace function public.taam_guest_seat_confirm(p_ticket_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare t public.tickets%rowtype;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into t from public.tickets where id = p_ticket_id;
  if not found then raise exception '티켓을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if coalesce(t.status,'') <> 'pending_confirm' then
    raise exception '확정 대기 상태가 아닙니다 (지금 %)', coalesce(t.status,'없음')
      using errcode = '55000';
  end if;
  update public.tickets set status = 'active' where id = p_ticket_id;
  return jsonb_build_object('ok', true, 'id', t.id);
end;
$$;
revoke all on function public.taam_guest_seat_confirm(uuid) from public;
grant execute on function public.taam_guest_seat_confirm(uuid) to authenticated;

-- 취소 — 자리를 못 드릴 때. ⚠ 환불은 여기서 하지 않는다.
--   카드 취소는 토스에서 따로 해야 하고, 여기서 「환불했다」고 기록해 버리면
--   실제로 안 빠진 돈을 빠진 것으로 세게 된다. 상태만 내리고 사람이 잇는다.
create or replace function public.taam_guest_seat_reject(p_ticket_id uuid, p_memo text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare t public.tickets%rowtype;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into t from public.tickets where id = p_ticket_id;
  if not found then raise exception '티켓을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if coalesce(t.status,'') <> 'pending_confirm' then
    raise exception '확정 대기 상태가 아닙니다 (지금 %)', coalesce(t.status,'없음')
      using errcode = '55000';
  end if;
  update public.tickets
     set status = 'cancelled', cancelled_at = now(),
         extra_data = coalesce(extra_data, '{}'::jsonb)
                      || jsonb_build_object('guest_reject', true,
                                            'guest_reject_memo', nullif(btrim(coalesce(p_memo,'')), ''))
   where id = p_ticket_id;
  return jsonb_build_object('ok', true, 'id', t.id, 'refund_needed', true);
end;
$$;
revoke all on function public.taam_guest_seat_reject(uuid, text) from public;
grant execute on function public.taam_guest_seat_reject(uuid, text) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 티켓 칸 6개' as "구분",
       case when count(*) = 6 then '✅' else '❌ ' || count(*)::text || '/6' end as "상태",
       coalesce(string_agg(column_name, ' · ' order by column_name), '—') as "메모"
  from information_schema.columns
 where table_schema='public' and table_name='ticket_products'
   and column_name in ('guest_open','guest_open_reason','guest_price',
                       'guest_seat_qty','guest_opened_at','guest_opened_by')
union all
select '② 매장 허용 스위치 (기본 잠김) ⭐',
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='restaurants'
                            and column_name='guest_seat_allowed'
                            and column_default like '%false%')
            then '✅ 기본 false' else '❌' end, ''
union all
select '③ 함수 7개',
       case when count(*) = 7 then '✅' else '❌ ' || count(*)::text || '/7' end,
       coalesce(string_agg(proname, ' · ' order by proname), '—')
  from pg_proc
 where pronamespace='public'::regnamespace
   and proname in ('taam_guest_seat_state','taam_guest_seat_open','taam_guest_seat_close',
                   'taam_guest_seat_allow','taam_guest_seat_queue',
                   'taam_guest_seat_confirm','taam_guest_seat_reject')
union all
select '④ 가드가 게스트석을 보나 ⭐',
       case when prosrc like '%guest_open%' and prosrc like '%pending_confirm%'
            then '✅' else '❌ 옛 가드' end, ''
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guard_ticket_tier'
union all
select '⑤ 열린 게스트석',
       coalesce((select count(*)::text from public.ticket_products where guest_open), '0') || '개',
       '이유 없이 열린 것: ' ||
       coalesce((select count(*)::text from public.ticket_products
                  where guest_open and coalesce(btrim(guest_open_reason),'') = ''), '0') || '개 (0이어야 정상)'
 order by 1;
