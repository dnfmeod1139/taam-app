-- ═══════════════════════════════════════════════════════════════
-- TAAM — 「일반공개」는 게스트도 산다 (2026-09-03)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 바뀌나
--   티켓 이용 등급을 **「일반공개」(min_tier = 'A')** 로 지정한 회차는
--   게스트(A 등급)도 회원과 똑같이 산다. 바로 확정되고, 가격도 회원가다.
--
--   어드민 화면은 처음부터 「일반공개」만 게스트(A)가 살 수 있습니다 라고
--   적어 놓고 있었다. 약속만 하고 서버가 안 지키던 것을 이제 지킨다.
--
-- ⚠ 비어 있는 min_tier 는 일반공개가 **아니다**
--   대부분의 옛 회차가 빈 값이다. 빈 값까지 열면 티켓이 통째로 열린다.
--   taam_tier_is_open 이 'A' 하나만 일반공개로 치고, 그 줄을 그대로 쓴다.
--   → 어드민이 회차마다 「일반공개」를 눌러 준 것만 열린다.
--
-- ⚠ 게스트석은 지우지 않았다
--   앱에서 입구(버튼)만 닫았고 규칙은 그대로 살아 있다. 이미 열려 있는
--   자리가 있으면 계속 동작해야 하고, 되돌리고 싶어질 때 다시 켜면 된다.
--   순서가 중요하다 — **일반공개를 먼저 본다.** 게스트석 분기를 먼저 타면
--   일반공개 회차인데도 pending_confirm 으로 들어가고 게스트가로 덮인다.
--
-- 실행: Supabase SQL Editor. guest_seat_price.sql 다음.
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

    -- ① 🆕 「일반공개」로 지정한 회차 — 회원과 완전히 같다.
    --    금액도 상태도 손대지 않는다. 확정 대기로 돌리지 않는다.
    --    ⚠ 반드시 게스트석 분기보다 **먼저** 본다.
    if public.taam_tier_is_open(v_need) then
      return new;
    end if;

    -- ② 게스트 초대석 (입구는 닫혔지만 규칙은 살아 있다)
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

    -- 금액은 서버가 정한다. 앱이 보낸 price 를 믿지 않는다.
    --   ⚠ guest_price 는 1인당. tickets.price 는 총액이다 — 그래서 곱한다.
    v_pax := greatest(1, coalesce(new.party_size, 1));
    v_should := coalesce(tp.guest_price, 0) * v_pax;
    if v_should > 0 then
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
  '게스트(A)는 「일반공개(min_tier=A)」 회차를 회원과 똑같이 산다 — 바로 확정, 회원가. 게스트 초대석 규칙도 남아 있으나 일반공개를 먼저 본다. 빈 min_tier 는 일반공개가 아니다.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ⚠ ④ 가 이번에 **게스트에게 열린 회차**다. 의도한 것만 있는지 본다.
-- ═══════════════════════════════════════════════════════════════
select '① 일반공개를 먼저 보나 ⭐' as "구분",
       case when prosrc like '%taam_tier_is_open(v_need)%' then '✅' else '❌ 옛 가드' end as "상태",
       '' as "메모"
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guard_ticket_tier'
union all
select '② 게스트석 규칙도 남아 있나',
       case when prosrc like '%GUEST_BLOCKED%' then '✅' else '❌ 지워짐' end,
       '입구만 닫았다 — 규칙은 살아 있어야 한다'
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guard_ticket_tier'
union all
select '③ 빈 등급은 안 열리나 ⭐',
       case when public.taam_tier_is_open('') then '❌ 열림' else '✅ 안 열림' end,
       '옛 회차 ' || (select count(*)::text from public.ticket_products
                       where coalesce(btrim(min_tier),'') = '') || '개가 여기 해당'
union all
select '④ 게스트에게 열린 회차 ⭐',
       (select count(*)::text from public.ticket_products
         where public.taam_tier_is_open(min_tier)) || '개',
       -- ⚠ 회차 컬럼(date 등)을 짐작해 쓰지 않는다. id 는 확실히 있다.
       coalesce((select string_agg(coalesce(r.name,'(매장없음)') || ' · ' || tp.id,
                                   ', ' order by tp.id)
                   from public.ticket_products tp
                   left join public.restaurants r on r.id::text = tp.rest_id::text
                  where public.taam_tier_is_open(tp.min_tier)), '없음')
union all
select '⑤ 아직 열려 있는 게스트석',
       (select count(*)::text from public.ticket_products
         where coalesce(guest_open,false)) || '개',
       '0이 아니면 티켓 목록에 게스트석 ● 버튼이 남아 있다'
 order by 1;
