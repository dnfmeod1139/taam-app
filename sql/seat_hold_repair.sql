-- ═══════════════════════════════════════════════════════════════
-- TAAM — 「결제하지도 않았는데 좌석이 차감되고 매진이 됐다」 진단 + 복구 · 2026-08
-- Supabase SQL Editor 에 붙여넣고 RUN (idempotent — 여러 번 실행해도 안전)
--
-- 무슨 일이 있었나 (2026-08-27, 10/3 타카미츠)
--   결제하기를 누르면 좌석을 먼저 잡는다(HOLD). 카드 결제창을 왕복하는 1~3분 동안
--   남이 그 자리를 가져가지 못하게 하는 장치다. 홀드는 tickets 에 status='hold' 로
--   들어가고, 결제를 안 하고 나가면 5분 뒤 자동 해제된다.
--
--   그 '자동 해제' 와 '즉시 반납' 이 둘 다 동작하지 않으면 이렇게 된다:
--     결제하기만 눌러도 좌석이 잡힌다 → 정원이 차면 매진으로 바뀐다
--     → 아무도 사지 않았는데 매진 → 본인조차 "남은 좌석이 없습니다" 로 거절된다
--
--   거기에 하나가 더 겹쳤다. 매진 동기화 트리거(v3)는 자유석(flex) 티켓을
--   **올리기만 하고 되돌리지 않았다.** 그래서 홀드가 풀려 자리가 다시 비어도
--   status 는 'soldout' 그대로 굳었다.
--
-- 이 파일이 하는 일
--   1) 진단   — 홀드 해제 장치(함수·크론)가 실제로 살아 있는지, 지금 잡혀 있는 홀드가 무엇인지
--   2) 청소   — 5분이 지난 홀드를 전부 해제
--   3) v4 트리거 — 자유석도 되돌린다. 단 어드민이 손으로 매진시킨 것은 건드리지 않는다
--   4) 복구   — 자리가 비었는데 매진으로 굳어 있는 티켓을 판매중으로 되돌린다
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- 1) 진단 — 먼저 이것부터 본다
-- ═══════════════════════════════════════════════════════════════

-- ① 홀드 해제 장치가 있는가
--    taam_release_seat_hold(즉시 반납) · taam_expire_seat_holds(5분 스윕)
--    하나라도 없으면 sql/seat_hold_5min.sql 을 실행하지 않은 것이다 — 그게 원인이다.
select
  to_regprocedure('public.taam_release_seat_hold(text)') is not null as "즉시반납 RPC 있음",
  to_regprocedure('public.taam_expire_seat_holds()')     is not null as "5분 스윕 함수 있음";

-- ② 5분 스윕이 실제로 '돌고' 있는가 (함수가 있어도 크론이 없으면 아무 일도 안 일어난다)
select jobname, schedule, active
  from cron.job
 where jobname in ('taam_expire_seat_holds', 'taam_expire_invite_holds');

-- ③ 지금 잡혀 있는 결제 홀드 — 5분이 지난 것은 이미 풀렸어야 하는 것들이다
select t.purchase_id,
       t.ticket_product_id,
       tp.rest_name,
       t.party_size                                   as "좌석",
       t.created_at,
       round(extract(epoch from (now() - t.created_at)) / 60)::int as "경과(분)",
       (now() - t.created_at > interval '5 minutes')   as "만료됐어야 함"
  from public.tickets t
  left join public.ticket_products tp on tp.id = t.ticket_product_id
 where t.status = 'hold'
   and t.purchase_id like 'PAYH-%'
 order by t.created_at desc
 limit 50;

-- ④ 자리가 비었는데 매진으로 굳어 있는 티켓 (3·4번이 이걸 푼다)
select tp.id, tp.rest_name, tp.total_pax as "정원", tp.status,
       (to_jsonb(tp.slots)->>'mode') as "구성",
       coalesce(tp.auto_soldout, true) as "자동매진",
       (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') as "점유"
  from public.ticket_products tp
 where coalesce(tp.total_pax,0) > 0
   and coalesce(tp.status,'') = 'soldout'
   and (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') < tp.total_pax
 order by tp.updated_at desc;


-- ═══════════════════════════════════════════════════════════════
-- 2) 청소 — 5분이 지난 결제 홀드를 지금 전부 해제
--    (스윕 함수가 없어도 여기서 직접 푼다)
-- ═══════════════════════════════════════════════════════════════
with rel as (
  update public.tickets
     set status = 'cancelled'
   where status = 'hold'
     and purchase_id like 'PAYH-%'
     and created_at < now() - interval '5 minutes'
  returning purchase_id, ticket_product_id, party_size
)
select count(*) as "해제한 홀드", coalesce(sum(party_size),0) as "돌려준 좌석" from rel;


-- ═══════════════════════════════════════════════════════════════
-- 3) 매진 동기화 트리거 v4 — 자유석도 되돌린다
--
--   v3 는 flex 를 '올리기만' 했다. 되돌리면 좌석 엔진의 판단(5/7 인데 매진 등)을
--   깨뜨릴까 봐서였다. 그런데 그 판단은 앱 화면에서 하는 것이지 status 에 쓰지 않는다.
--   status='soldout' 을 쓰는 건 이 트리거(꽉 찼을 때)와 어드민의 수동 토글뿐이다.
--
--   그래서 안전하게 가를 수 있다:
--     · auto_soldout = false  → 어드민이 손으로 매진시킨 것. 절대 건드리지 않는다.
--     · 그 외                 → 이 트리거가 올린 것. 자리가 비면 되돌린다.
--   올릴 때 auto_soldout = true 를 같이 남겨, 다음에 되돌려도 되는지 알 수 있게 한다.
-- ═══════════════════════════════════════════════════════════════

alter table public.ticket_products
  add column if not exists auto_soldout boolean not null default true;

create or replace function public.sync_ticket_soldout()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_pid    text;
  v_cap    int;
  v_sold   int;
  v_status text;
  v_auto   boolean;
begin
  v_pid := coalesce(new.ticket_product_id, old.ticket_product_id);
  if v_pid is null then return coalesce(new, old); end if;

  select total_pax, status, coalesce(auto_soldout, true)
    into v_cap, v_status, v_auto
    from public.ticket_products where id = v_pid;
  if v_cap is null or v_cap <= 0 then
    return coalesce(new, old);   -- 정원 미설정 티켓은 매진 개념 없음
  end if;

  -- 취소된 행 제외 전 회원 합산 (hold·active 모두 좌석을 차지한다)
  select coalesce(sum(party_size), 0) into v_sold
    from public.tickets
   where ticket_product_id = v_pid
     and coalesce(status, '') <> 'cancelled';

  if v_sold >= v_cap then
    -- 꽉 찼다 → 매진. 자동으로 올렸다는 표시를 남긴다.
    if coalesce(v_status,'') <> 'soldout' then
      update public.ticket_products
         set status = 'soldout', auto_soldout = true
       where id = v_pid;
    end if;
  else
    -- 자리가 있다 → 자동으로 올린 매진만 되돌린다 (어드민 수동 매진은 존중)
    if coalesce(v_status,'') = 'soldout' and v_auto then
      update public.ticket_products
         set status = 'active'
       where id = v_pid;
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_ticket_soldout on public.tickets;
create trigger trg_sync_ticket_soldout
  after insert or update or delete on public.tickets
  for each row execute function public.sync_ticket_soldout();


-- ═══════════════════════════════════════════════════════════════
-- 4) 복구 — 자리가 비었는데 매진으로 굳은 티켓을 판매중으로
--    (어드민이 손으로 매진시킨 것 auto_soldout=false 는 그대로 둔다)
-- ═══════════════════════════════════════════════════════════════
with fixed as (
  update public.ticket_products tp
     set status = 'active'
   where coalesce(tp.total_pax,0) > 0
     and coalesce(tp.status,'') = 'soldout'
     and coalesce(tp.auto_soldout, true)
     and (select coalesce(sum(x.party_size),0) from public.tickets x
           where x.ticket_product_id = tp.id
             and coalesce(x.status,'') <> 'cancelled') < tp.total_pax
  returning tp.id, tp.rest_name, tp.total_pax
)
select count(*) as "판매중으로 되돌린 티켓" from fixed;


-- ═══════════════════════════════════════════════════════════════
-- 5) 확인 — 여기서 「점유」가 「정원」보다 작은데 status='soldout' 인 줄이
--    남아 있으면 안 된다 (auto_soldout=false 인 수동 매진은 예외)
-- ═══════════════════════════════════════════════════════════════
select tp.id, tp.rest_name, tp.total_pax as "정원", tp.status,
       (to_jsonb(tp.slots)->>'mode') as "구성",
       coalesce(tp.auto_soldout, true) as "자동매진",
       (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') as "점유"
  from public.ticket_products tp
 where coalesce(tp.total_pax,0) > 0
 order by tp.updated_at desc
 limit 30;

do $$ begin
  raise notice '✅ 좌석 홀드 청소 + 매진 동기화 v4 (자유석 되돌리기 포함) 적용 완료';
  raise notice 'ℹ️  1번 진단에서 「즉시반납 RPC 있음」이 false 였다면 sql/seat_hold_5min.sql 을 반드시 실행하세요';
end $$;
