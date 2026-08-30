-- ═══════════════════════════════════════════════════════════════
-- TAAM — 재구매 제한을 서버에서도 지킨다 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제인가
--   재구매 제한(레스토랑별 30·60·90일)을 판정하는 곳이 **앱뿐**이다.
--   checkRepurchaseLimit() 이 브라우저 메모리의 purchaseHistory 를 뒤진다.
--   서버에는 이 규칙이 아예 없다.
--
--   ① 앱을 거치지 않으면 그냥 통과한다
--   ② 앱을 거쳐도 purchaseHistory 가 덜 실려 있으면 **조용히 안 걸린다**
--
--   ②가 특히 나쁘다. 아무도 잘못한 게 없는데 규칙이 안 걸리고, 나중에
--   「왜 두 번 팔렸지」로 발견된다. 오늘 아침 구자호 회원 건이 연도 문제였지만
--   이 구조 자체가 같은 사고를 계속 만든다.
--
-- ⚠ 이 파일은 순서가 있다. ①②를 먼저 보고, 숫자를 확인한 뒤에 ③을 올린다.
--    ③을 먼저 올리면 정상 구매가 막힐 수 있다.
--
--    ① 지금 규칙이면 막혔을 「과거」 구매를 센다   ← 먼저 본다
--    ② 앞으로 막힐 「예정된」 구매가 있는지 본다   ← 먼저 본다
--    ③ 트리거를 올린다                             ← 숫자를 보고 결정
--
-- 실행: Supabase SQL Editor. ①② 는 읽기만 한다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 지금 규칙이면 막혔을 과거 구매 — 몇 건인가
-- ═══════════════════════════════════════════════════════════════
--   이미 지나간 것은 트리거가 건드리지 않는다. 다만 「이 규칙이 얼마나
--   자주 걸리는가」를 보려고 센다. 여기가 수십 건이면 규칙 자체가
--   현실과 안 맞는다는 뜻이라, 트리거를 올리기 전에 규칙을 먼저 이야기해야 한다.
--
--   ⚠ 오늘 아침 감사에서 배운 제외 조건을 그대로 쓴다.
--     · MAN-  수동 추가는 어드민이 만든 것이라 회원 구매가 아니다
--     · INVH- 초대 좌석 홀드도 마찬가지
--     · user_id 가 없는 행끼리 묶으면 남남이 한 사람이 된다
--     · 같은 날 두 건은 인원추가·동반이라 위반이 아니다
with t as (
  select k.user_id, k.restaurant_id, k.purchase_id,
         k.reservation_date::date as vd, k.status
  from public.tickets k
  where k.reservation_date is not null
    and k.purchase_id not like 'MAN-%'
    and k.purchase_id not like 'INVH-%'
    and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
    and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
    and k.user_id is not null
    and k.status not in ('cancelled','canceled')
)
select count(*) filter (where gap > 0)  as "⚠ 위반 (같은 날 제외)",
       count(*) filter (where gap = 0)  as "같은 날 (정상 · 인원추가)",
       count(*)                          as "합계"
from (
  select abs(a.vd - b.vd) as gap
  from t a
  join t b on a.user_id = b.user_id
          and a.restaurant_id = b.restaurant_id
          and a.purchase_id < b.purchase_id
  join public.restaurants r on r.id::text = a.restaurant_id::text
  where coalesce(r.repurchase_day, 0) > 0
    and abs(a.vd - b.vd) < r.repurchase_day
) x;


-- ═══════════════════════════════════════════════════════════════
-- ② 앞으로 막힐 예정된 구매 — 이게 진짜 중요하다
-- ═══════════════════════════════════════════════════════════════
--   ①은 과거라 트리거와 무관하다. ②는 다르다 —
--   **아직 방문하지 않은 예약끼리** 제한에 걸리는 쌍이 있으면, 그 회원이
--   앞으로 무언가를 고치거나 다시 살 때 새 트리거에 막힐 수 있다.
--
--   여기가 0건이면 트리거를 올려도 아무도 안 막힌다.
with t as (
  select k.user_id, k.restaurant_id, k.restaurant_name,
         k.purchase_id, k.reservation_date::date as vd
  from public.tickets k
  where k.reservation_date is not null
    and k.reservation_date::date >= current_date      -- 앞으로 올 것만
    and k.purchase_id not like 'MAN-%'
    and k.purchase_id not like 'INVH-%'
    and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
    and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
    and k.user_id is not null
    and k.status not in ('cancelled','canceled')
)
select coalesce(p.display_name, '(이름 없음)') as "회원",
       a.restaurant_name                    as "매장",
       r.repurchase_day                     as "제한(일)",
       abs(a.vd - b.vd)                     as "실제 간격(일)",
       a.vd                                 as "방문일 ①",
       b.vd                                 as "방문일 ②",
       case when abs(a.vd - b.vd) = 0 then '같은 날 — 정상'
            else '⚠ 앞으로 막힐 수 있음' end as "판정"
from t a
join t b on a.user_id = b.user_id
        and a.restaurant_id = b.restaurant_id
        and a.purchase_id < b.purchase_id
join public.restaurants r on r.id::text = a.restaurant_id::text
left join public.profiles p on p.id = a.user_id
where coalesce(r.repurchase_day, 0) > 0
  and abs(a.vd - b.vd) < r.repurchase_day
order by (abs(a.vd - b.vd) = 0), abs(a.vd - b.vd);


-- ═══════════════════════════════════════════════════════════════
-- ③ ⚠ ①② 를 보고 나서 올린다
-- ═══════════════════════════════════════════════════════════════
-- 아래 블록만 따로 복사해서 실행하세요.
--
-- 무엇을 막나
--   회원이 같은 매장에 제한 기간 안으로 예약을 하나 더 만드는 것.
--   앞뒤를 가리지 않는다 — 4월을 먼저 사고 1월을 사도 똑같이 막힌다
--   (앱의 Math.abs 와 같은 규칙이다).
--
-- 무엇을 안 막나 (여기가 핵심이다 — 하나라도 빠뜨리면 정상 구매가 막힌다)
--   · 같은 날 예약        — 인원추가·동반이다. 실제로 그런 행이 있다
--   · MAN- 수동 추가      — 어드민이 만든 것
--   · INVH- 초대 좌석 홀드 — 결제 전 자리맡기
--   · INV-  초대 결제      — 어드민이 보낸 초대를 받은 것이라 회원의 재구매가 아니다
--   · 취소된 예약          — 방문이 아니다
--   · 슈퍼어드민·매장 어드민이 만드는 것
--   · 면제 계정(single_device_exempt) — 심사·데모 계정
--   · 방문일이 없는 행     — 판정할 근거가 없으면 막지 않는다
--   · restaurants 에 없는 매장 / repurchase_day = 0
--
-- 되돌리려면
--   drop trigger if exists trg_taam_repurchase_guard on public.tickets;
-- ───────────────────────────────────────────────────────────────
/*

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
  -- 서버가 하는 일은 막지 않는다 (service_role · RPC · 마이그레이션)
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- 판정할 근거가 없으면 막지 않는다
  if new.user_id is null or new.restaurant_id is null
     or new.reservation_date is null then
    return new;
  end if;

  -- 회원 구매가 아닌 것들 — 어드민이 만든 행·초대·홀드
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

  -- 어드민이 만드는 것은 통과 (수동 예약·대리 구매)
  if public._taam_uid_is_super() then
    return new;
  end if;
  if exists (select 1 from public.profiles p
              where p.id = auth.uid() and p.role = 'admin') then
    return new;
  end if;

  -- 면제 계정 (심사·데모) — 앱의 _tkRepurchaseExempt() 와 같은 뜻
  select coalesce(p.single_device_exempt, false) into v_exempt
    from public.profiles p where p.id = new.user_id;
  if coalesce(v_exempt, false) then
    return new;
  end if;

  -- 이 매장의 제한 일수
  select r.repurchase_day into v_days
    from public.restaurants r
   where r.id::text = new.restaurant_id::text;
  if coalesce(v_days, 0) = 0 then
    return new;
  end if;

  -- 같은 매장의 살아 있는 예약 중, 방문일 간격이 제한 안에 드는 것
  --   ⚠ 간격 0(같은 날)은 뺀다 — 인원추가·동반이라 정상이다
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

comment on function public.taam_guard_repurchase() is
  '재구매 제한을 서버에서 지킨다. 같은 날·초대·수동·취소·어드민·면제는 통과.';

-- 붙었는지
select tgname as "트리거"
from pg_trigger
where tgrelid = 'public.tickets'::regclass
  and tgname = 'trg_taam_repurchase_guard';

*/
-- ───────────────────────────────────────────────────────────────
-- 남은 것
-- ───────────────────────────────────────────────────────────────
--   앱은 계속 checkRepurchaseLimit() 으로 **먼저** 막는다. 그게 맞다 —
--   서버 예외는 「결제 직전에 튕김」이지만 앱 판정은 「누르기 전에 안내」다.
--   서버는 마지막 그물이지 첫 그물이 아니다. 둘 다 있는 게 맞다.
--
--   앱 쪽 에러 문구는 배포가 필요하다. REPURCHASE_BLOCKED 를 만나면
--   재구매 팝업을 띄우도록 index.html 에서 잡아 주는 게 다음 단계다.
