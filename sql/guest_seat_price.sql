-- ═══════════════════════════════════════════════════════════════
-- TAAM — 게스트석은 게스트가로 받는다 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 문제
--   게스트가 게스트석을 사도 **회원가로 결제**되고 있었다.
--   guest_price 를 어드민이 적어 뒀는데 아무도 안 읽었다.
--
-- 금액은 서버가 정한다
--   앱이 보낸 price 를 믿지 않는다. 게스트 구매면 서버가
--   **guest_price × 인원** 으로 덮어쓴다. 앱을 거치지 않고 tickets 에
--   직접 INSERT 해도 같은 금액이 박힌다.
--
-- ⚠ guest_price 는 **1인당** 금액이다.
--   회원가도 1인당(식사비+대행비+주류 미니멈)이라 같은 단위로 맞춘다.
--   tickets.price 는 **총액**이다(초대 홀드 행과 같은 규칙) — 그래서 곱한다.
--
-- ⚠ 이 파일은 카드 승인 금액을 바꾸지 못한다.
--   승인은 앱이 결제창에 넘긴 금액으로 이미 났다. 그래서 앱도 같이 고쳤다
--   (fxTicketCharge). 여기는 **앱이 틀렸을 때 기록이라도 맞게** 남기는 겹이고,
--   두 값이 어긋나면 어드민이 볼 수 있도록 extra_data 에 흔적을 남긴다.
--
-- 실행: Supabase SQL Editor. ⚠ guest_seat.sql 다음.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_guard_ticket_tier()
returns trigger
language plpgsql security definer set search_path = public
as $tier$
declare
  v_need text; v_mine text;
  tp public.ticket_products%rowtype;
  v_allowed boolean; v_sold int;
  v_pax int; v_should int;
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
      raise exception 'GUEST_BLOCKED: 이 자리는 멤버십 회원만 예약할 수 있습니다'
        using errcode = '42501';
    end if;
    if coalesce(btrim(tp.guest_open_reason), '') = '' then
      raise exception 'GUEST_BLOCKED: 게스트석 안내가 준비되지 않았습니다'
        using errcode = '42501';
    end if;
    select coalesce(r.guest_seat_allowed, false) into v_allowed
      from public.restaurants r where r.id::text = tp.rest_id::text;
    if not coalesce(v_allowed, false) then
      raise exception 'GUEST_BLOCKED: 이 매장은 게스트석을 열지 않습니다'
        using errcode = '42501';
    end if;
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

    -- 🆕 금액은 서버가 정한다. 앱이 보낸 price 를 믿지 않는다.
    --   ⚠ guest_price 는 1인당. tickets.price 는 총액이다 — 그래서 곱한다.
    v_pax := greatest(1, coalesce(new.party_size, 1));
    v_should := coalesce(tp.guest_price, 0) * v_pax;
    if v_should > 0 then
      -- 앱이 다른 금액을 보냈으면 그 사실을 남긴다. 카드 승인은 이미
      -- 그 금액으로 났을 수 있어서, 어드민이 확정 전에 볼 수 있어야 한다.
      if coalesce(new.price, 0) <> v_should then
        new.extra_data := coalesce(new.extra_data, '{}'::jsonb)
          || jsonb_build_object(
               'guest_price_fixed', true,
               'guest_price_app',    coalesce(new.price, 0),
               'guest_price_server', v_should,
               'guest_price_per',    tp.guest_price);
      end if;
      new.price := v_should;
    end if;

    -- 게스트 구매는 확정 대기로. 앱이 보낸 status 도 믿지 않는다.
    new.status := 'pending_confirm';
    return new;
  end if;

  -- ── 회원 (기존 규칙 그대로) ──────────────────────────────
  if v_need is null or public.taam_tier_rank(v_need) = 0 then
    return new;
  end if;

  -- ⚠ 「일반공개(min_tier=A)」는 하한이 아니라 개방이다. 게스트가 아닌
  --   사람에게는 그대로 열려 있어야 한다. 이 줄을 빼면 등급이 아예 없는
  --   옛 회원이 튕긴다 — 열어 놓고 못 사게 되는 정반대의 결과다.
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
  '게스트(A)는 게스트석만 — 이유·매장 허락·수량을 서버가 본다. 금액은 guest_price×인원으로 서버가 덮어쓰고, 앱이 다른 값을 보냈으면 extra_data 에 남긴다. 상태는 pending_confirm.';


-- 어드민 큐에 「앱이 다른 금액을 보냈나」를 함께 준다.
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
                 r.name as venue_name,
                 -- ⚠ 앱이 보낸 금액과 서버가 정한 금액이 달랐던 건.
                 --   카드 승인은 앱 금액으로 났을 수 있으니 확정 전에 봐야 한다.
                 coalesce((t.extra_data->>'guest_price_fixed')::boolean, false) as price_fixed,
                 (t.extra_data->>'guest_price_app')::int as price_app
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

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 가드가 금액을 정하나 ⭐' as "구분",
       case when prosrc like '%guest_price%' and prosrc like '%new.price := v_should%'
            then '✅' else '❌ 옛 가드' end as "상태", '' as "메모"
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guard_ticket_tier'
union all
select '② 어긋나면 흔적을 남기나',
       case when prosrc like '%guest_price_fixed%' then '✅' else '❌' end, ''
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guard_ticket_tier'
union all
select '③ 큐가 그 사실을 보여주나',
       case when prosrc like '%price_fixed%' then '✅' else '❌' end, ''
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guest_seat_queue'
union all
select '④ 게스트가가 적힌 회차',
       coalesce((select count(*)::text from public.ticket_products
                  where guest_open and coalesce(guest_price,0) > 0), '0') || '개',
       '게스트석인데 가격이 없는 것: ' ||
       coalesce((select count(*)::text from public.ticket_products
                  where guest_open and coalesce(guest_price,0) <= 0), '0') || '개 (0이어야 정상)'
 order by 1;
