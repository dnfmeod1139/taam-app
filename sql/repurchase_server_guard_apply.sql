-- ═══════════════════════════════════════════════════════════════
-- TAAM — 재구매 제한 서버 가드 (적용용) · 2026-08-30
-- ═══════════════════════════════════════════════════════════════
-- ⚠ 이 파일은 **적용만** 한다. 진단은 sql/repurchase_server_guard.sql 의
--   ①② 에서 이미 마쳤다. 그 결과가 이랬다:
--
--     ② 앞으로 막힐 예정 예약 — 2건, 둘 다 「같은 날」
--        유수봉 · 시마즈    2026-12-19 (간격 0)
--        이창훈 · 스시 아라이 2027-01-25 (간격 0)
--
--   트리거는 간격 0(같은 날 인원추가·동반)을 명시적으로 통과시킨다.
--   따라서 이 트리거를 올려도 **막히는 회원은 0명**이다.
--
-- 만료 홀드와의 관계
--   taam_expire_seat_holds() 가 5분 지난 홀드를 status='cancelled' 로 바꾼다.
--   이 트리거는 취소된 행을 근거로 삼지 않으므로, 결제하다 만 홀드가
--   나중에 정상 구매를 막는 일이 없다.
--
-- 되돌리려면
--   drop trigger if exists trg_taam_repurchase_guard on public.tickets;
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포와 무관하다 — 지금 돌려도 결제가 안 멈춘다.
-- ═══════════════════════════════════════════════════════════════

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
