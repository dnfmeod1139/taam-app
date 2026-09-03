-- ═══════════════════════════════════════════════════════════════
-- TAAM — 「매장을 찾을 수 없습니다」 (2026-09-03)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 났나
--   게스트석 시트에서 「이 매장 게스트석 허용」을 누르면
--   ❌ 매장을 찾을 수 없습니다 로 튕겼다.
--
-- 왜
--   앱이 매장 id 를 **자기가 골라서** 보내고 있었다. 그런데 ticketDB 의
--   매장 id 는 `restId` 이고 `rest` 는 **매장 이름**이다. 이름을 id 자리에
--   넣어 보냈으니 서버는 그런 매장을 못 찾는다.
--
-- 어떻게 고치나 — 앱이 매장을 고르지 않게 한다
--   시트는 언제나 **회차** 를 열어 놓고 있다. 그 회차가 어느 매장인지는
--   서버가 ticket_products.rest_id 로 이미 안다 (taam_guest_seat_state 가
--   그렇게 매장 허용 여부를 읽고 있었고, 그건 처음부터 잘 됐다).
--   그러니 매장 id 를 주고받지 말고 **회차 id 만** 넘긴다.
--
--   ⚠ 옛 taam_guest_seat_allow(text, boolean) 은 그대로 둔다.
--     지우면 배포 순서에 따라 앱이 없는 함수를 부르는 구간이 생긴다.
--
-- 실행: Supabase SQL Editor. guest_seat.sql 다음이면 순서 무관.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 상태에 매장 id·이름을 같이 준다 ──────────────────────────
--   앱이 매장을 짐작할 일이 없어진다. 시트 제목도 이 이름을 쓴다.
create or replace function public.taam_guest_seat_state(p_ticket_product_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare tp public.ticket_products%rowtype; v_allowed boolean; v_sold int;
        v_rname text;
begin
  select * into tp from public.ticket_products where id::text = p_ticket_product_id;
  if not found then return jsonb_build_object('found', false); end if;

  select coalesce(r.guest_seat_allowed, false), r.name into v_allowed, v_rname
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
    'opened_at', tp.guest_opened_at,
    -- 🆕 매장은 서버가 알려준다. 앱이 고르면 이름을 id 자리에 넣는 사고가 난다.
    'rest_id',   tp.rest_id,
    'rest_name', v_rname
  );
end;
$$;
revoke all on function public.taam_guest_seat_state(text) from public;
grant execute on function public.taam_guest_seat_state(text) to anon, authenticated;


-- ── ② 회차 id 로 매장을 연다·잠근다 ───────────────────────────
--   매장 id 를 주고받지 않는다. 서버가 회차에서 매장을 찾는다.
create or replace function public.taam_guest_seat_allow_for(
  p_ticket_product_id text, p_on boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_rest text;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select tp.rest_id::text into v_rest
    from public.ticket_products tp where tp.id::text = p_ticket_product_id;
  if v_rest is null or btrim(v_rest) = '' then
    -- 회차가 없는 건지, 회차에 매장이 안 붙어 있는 건지 구별해 준다.
    -- 「매장을 찾을 수 없습니다」 하나로 뭉뚱그리면 또 헤맨다.
    if not exists (select 1 from public.ticket_products where id::text = p_ticket_product_id) then
      raise exception '회차를 찾을 수 없습니다' using errcode = 'P0002';
    end if;
    raise exception '이 회차에 매장이 연결돼 있지 않습니다' using errcode = 'P0002';
  end if;
  return public.taam_guest_seat_allow(v_rest, p_on);
end;
$$;
revoke all on function public.taam_guest_seat_allow_for(text, boolean) from public;
grant execute on function public.taam_guest_seat_allow_for(text, boolean) to authenticated;

comment on function public.taam_guest_seat_allow_for(text, boolean) is
  '회차 id 로 그 매장의 게스트석 허용을 켜고 끈다. 앱이 매장 id 를 고르지 않게 하려는 것 — ticketDB.rest 는 이름이라 id 자리에 넣으면 못 찾는다.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 상태가 매장 id 를 주나 ⭐' as "구분",
       case when prosrc like '%rest_id%' and prosrc like '%rest_name%'
            then '✅' else '❌ 옛 함수' end as "상태", '' as "메모"
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guest_seat_state'
union all
select '② 회차로 매장을 여는 함수 ⭐',
       case when count(*) = 1 then '✅' else '❌ 없음' end, ''
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guest_seat_allow_for'
union all
select '③ 옛 함수도 남아 있나',
       case when count(*) = 1 then '✅' else '❌' end,
       '배포 순서 때문에 지우지 않는다'
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guest_seat_allow'
union all
select '④ 매장이 안 붙은 회차',
       coalesce((select count(*)::text from public.ticket_products
                  where rest_id is null or btrim(rest_id::text) = ''), '0') || '개',
       '있으면 그 회차는 게스트석을 못 연다 (0이어야 정상)'
 order by 1;
