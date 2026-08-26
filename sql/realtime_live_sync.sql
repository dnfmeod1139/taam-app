-- ═══════════════════════════════════════════════════════════════
-- TAAM — 실시간 반영 (예치금 · 좌석/매진) · 2026-08
-- Supabase SQL Editor 에 붙여넣고 RUN (idempotent — 여러 번 실행해도 안전)
--
-- 무엇을 하는가
--   ① profiles · ticket_products · tickets 를 Realtime 발행 목록에 넣는다
--   ② 좌석이 움직일 때마다 ticket_products.updated_at 을 건드리는 트리거를 단다
--
-- 왜 ②가 필요한가 — 이게 핵심이다
--   회원은 RLS 때문에 '남의 tickets 행' 을 읽을 수 없다. Realtime 도 같은 RLS 를
--   그대로 적용하므로, 다른 회원이 좌석을 사도 그 이벤트는 내 기기에 오지 않는다.
--   그래서 "누가 마지막 좌석을 샀다" 를 회원 기기가 알 방법이 원래 없다.
--
--   대신 좌석이 움직일 때마다 '모두가 읽을 수 있는' ticket_products 를 한 번
--   건드려두면, 그 테이블의 UPDATE 이벤트 하나로 전 기기가 같이 갱신된다.
--   앱은 이 이벤트를 받으면 티켓과 예치금을 다시 읽고 화면을 다시 그린다.
--
--   기존 sync_ticket_soldout 트리거는 '매진으로 바뀔 때만' ticket_products 를
--   건드린다. 3/7 → 5/7 같은 중간 변화는 아무 이벤트도 만들지 않았다.
--   이 파일이 그 빈칸을 메운다.
--
-- ⚠ 이게 없어도 앱은 정상 동작한다 — 화면 복귀·탭 이동·당겨서 새로고침이
--   같은 일을 한다. 이 파일은 '더 빠르게' 를 담당한다.
-- ═══════════════════════════════════════════════════════════════

-- ── 0) ticket_products.updated_at 보장 ──
alter table public.ticket_products
  add column if not exists updated_at timestamptz not null default now();

-- ── 1) 좌석이 움직이면 ticket_products 를 한 번 건드린다 ──
--   security definer: 구매자는 ticket_products 쓰기 권한이 없다. 트리거가 대신 쓴다.
create or replace function public.touch_ticket_product_on_seat_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_pid text;
begin
  v_pid := coalesce(new.ticket_product_id, old.ticket_product_id);
  if v_pid is null then
    return coalesce(new, old);
  end if;

  update public.ticket_products
     set updated_at = now()
   where id = v_pid;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_touch_ticket_product on public.tickets;
create trigger trg_touch_ticket_product
  after insert or update or delete on public.tickets
  for each row execute function public.touch_ticket_product_on_seat_change();

-- ── 2) Realtime 발행 목록에 넣는다 ──
--   이미 들어 있으면 42710(duplicate_object)이 난다 — 무시하고 넘어간다.
do $$
declare
  t text;
begin
  foreach t in array array['profiles','ticket_products','tickets'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
      raise notice '발행 추가: %', t;
    exception
      when duplicate_object then raise notice '이미 발행 중: %', t;
      when undefined_object then raise notice '발행(supabase_realtime) 없음 — 대시보드에서 Realtime 을 켜세요';
    end;
  end loop;
end $$;

-- ── 3) RLS 가 걸린 테이블은 REPLICA IDENTITY FULL 이어야 필터·정책이 정확히 평가된다 ──
--   세 테이블 모두 변경 빈도가 낮아 WAL 부담이 거의 없다.
alter table public.profiles        replica identity full;
alter table public.ticket_products replica identity full;
alter table public.tickets         replica identity full;

-- ═══════════════════════════════════════════════════════════════
-- 확인
--   1) 발행 목록
--        select tablename from pg_publication_tables
--         where pubname = 'supabase_realtime' order by 1;
--      → profiles · ticket_products · tickets 가 보이면 정상
--
--   2) 트리거
--        select tgname from pg_trigger
--         where tgrelid = 'public.tickets'::regclass and not tgisinternal;
--      → trg_touch_ticket_product 가 보이면 정상
--
--   3) 앱에서 (기기 2대 또는 시크릿창 + 일반창)
--      · A 회원 화면을 켜둔 채 슈퍼어드민이 예치금 부여 → A 잔액이 그 자리에서 바뀐다
--      · 캘린더를 켜둔 채 마지막 좌석을 수동 추가 → 타일이 흑백으로 바뀐다
-- ═══════════════════════════════════════════════════════════════
