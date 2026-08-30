-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원이 자기 예약을 고쳐 쓰지 못하게 한다 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 열려 있나
--   tickets_update_own : (auth.uid() = user_id) OR is_superadmin()
--   자기 예약 행을 고칠 수 있다는 뜻인데, 그 행에 price·party_size·status 가 있다.
--
--       update tickets set party_size = 8   where purchase_id = '내 것'   -- 좌석을 더 가져간다
--       update tickets set status = 'active' where purchase_id = '내 취소건'  -- 취소를 되살린다
--       update tickets set price = 0        where purchase_id = '내 것'   -- 매출 기록을 지운다
--
--   돈이 그 자리에서 빠져나가진 않는다. 대신 **좌석이 실제로 줄고**, 매출·정산
--   기록이 어긋나고, 취소된 예약이 되살아난다. 예치금보다 조용해서 더 늦게 들킨다.
--
-- 왜 지금 막을 수 있나
--   예치금은 앱이 그 경로에 기대고 있어서 먼저 서버 함수로 옮겨야 했다.
--   tickets 는 다르다. 앱이 회원 세션으로 하는 UPDATE 는 딱 두 가지뿐이다.
--     ① 결제 확정   : status 'hold' → 'active' + price 를 실제 결제액으로
--     ② 취소        : status → 'cancelled' + extra_data 에 환불 기록
--   그 외에는 슈퍼어드민이나 RPC(taam_change_party_size 등)가 한다.
--   그래서 「이 두 가지만 허용」으로 막으면 앱이 안 멈춘다.
--
-- 무엇을 막나 (회원 세션 · 슈퍼어드민 아님 기준)
--   · party_size 변경        → 전면 차단. 인원 변경은 taam_change_party_size 로만 한다
--                              (그 RPC 는 차액 정산까지 같이 한다)
--   · 취소된 건 되살리기     → 차단
--   · price 를 아무 때나 변경 → 차단. 'hold' → 'active' 확정 순간만 허용
--   · restaurant_id · reservation_date · user_id · purchase_id 변경 → 차단
--
-- ⚠ 예외를 던진다. 정상 경로가 이 조건에 안 걸리므로, 걸렸다면 앱 밖에서 온 것이다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포와 무관하다 — 지금 돌려도 결제가 멈추지 않는다.
--          (지금 라이브 코드가 하는 UPDATE 두 가지를 그대로 허용하기 때문)
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 막는 트리거
-- ═══════════════════════════════════════════════════════════════
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

create or replace function public.taam_guard_ticket_row()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 서버가 하는 일은 막지 않는다.
  --   service_role · postgres · SECURITY DEFINER RPC(taam_change_party_size 등) ·
  --   좌석 트리거 · 마이그레이션은 전부 다른 롤로 돈다.
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

  -- 매장·방문일 갈아타기 (재구매 제한·좌석 집계가 통째로 어긋난다)
  if new.restaurant_id is distinct from old.restaurant_id
     or new.reservation_date is distinct from old.reservation_date then
    raise exception '예약의 매장·날짜는 직접 바꿀 수 없습니다' using errcode = '42501';
  end if;

  -- 취소된 건을 되살리기
  if old.status = 'cancelled' and new.status is distinct from old.status then
    raise exception '취소된 예약은 되살릴 수 없습니다' using errcode = '42501';
  end if;

  -- 금액은 「결제 확정」 순간에만 정해진다.
  --   앱의 정상 경로: status 'hold' → 'active' 로 바뀌면서 price 가 실제 결제액이 된다.
  --   그 순간이 아니면 회원이 금액을 건드릴 이유가 없다.
  if coalesce(new.price, 0) is distinct from coalesce(old.price, 0) then
    if not (old.status = 'hold' and new.status = 'active') then
      raise exception '금액은 결제 확정 때만 정해집니다' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_taam_guard_ticket_row on public.tickets;
create trigger trg_taam_guard_ticket_row
  before update on public.tickets
  for each row execute function public.taam_guard_ticket_row();

comment on function public.taam_guard_ticket_row() is
  '회원이 자기 예약의 인원·금액·매장·날짜·소유자를 직접 고치지 못하게 막는다. 결제 확정(hold→active)과 취소만 통과.';


-- ═══════════════════════════════════════════════════════════════
-- ② 붙었는지 + 지금 정책
-- ═══════════════════════════════════════════════════════════════
select 'ⓐ 트리거'   as "구분", tgname as "이름", '설치됨' as "내용"
from pg_trigger
where tgrelid = 'public.tickets'::regclass
  and tgname = 'trg_taam_guard_ticket_row'

union all
select 'ⓑ tickets 정책', policyname, cmd || ' · ' || coalesce(with_check, qual, '(없음)')
from pg_policies
where schemaname = 'public' and tablename = 'tickets'
order by 1, 2;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면 (구매·취소가 막히면 즉시)
-- ═══════════════════════════════════════════════════════════════
--   drop trigger if exists trg_taam_guard_ticket_row on public.tickets;
--
-- ═══════════════════════════════════════════════════════════════
-- 남은 것 — INSERT
-- ═══════════════════════════════════════════════════════════════
--   tickets_insert_own 이 (auth.uid() = user_id) 라, 회원이 결제 없이 자기
--   예약 행을 만들 수 있다. 다만 좌석 트리거(TICKET_SOLD_OUT·SLOT_SOLD_OUT·
--   SOLO_LIMIT·FRAGMENT_BLOCKED)가 이미 서버에서 좌석을 지키고 있어서,
--   없는 좌석을 만들어 낼 수는 없다. 「돈 안 내고 남은 좌석을 차지」는 가능하다.
--   이건 구매 흐름을 서버 RPC 로 옮겨야 제대로 막힌다 — 예치금과 같은 순서다.
--   먼저 UPDATE 를 막아 두고, INSERT 는 그다음에 한다.
