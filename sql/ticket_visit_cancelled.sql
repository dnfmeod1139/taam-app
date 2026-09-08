-- ═══════════════════════════════════════════════════════════════
-- 방문 기록에 「취소」를 더한다 (2026-09-08)
--
-- ⚠ 저장소에 두는 것만으로는 반영되지 않는다.
--   Supabase SQL Editor 에서 직접 RUN 해야 한다.
--   ⚠ sql/ticket_visit_record.sql 다음에 실행한다.
--
-- 왜 필요한가
--   방문 기록 화면(밀린 지난 예약)에 「방문」·「노쇼」 둘뿐이었다. 그런데
--   실제로는 **오지 않기로 미리 연락이 온 건**이 섞여 있다. 그걸 노쇼로
--   찍으면 그 회원에게 없는 잘못을 남기게 되고, 안 찍으면 목록에 영원히
--   남아 다른 밀린 건을 가린다. 그래서 세 번째 값을 둔다.
--
-- 무엇이 아닌가 — 중요
--   ⚠ 이것은 **결제 취소가 아니다.** 환불도, 예치금 반환도 하지 않는다.
--     「무슨 일이 있었나」를 적는 기록일 뿐이고, 돈은 한 푼도 움직이지 않는다.
--     결제를 되돌려야 하는 건이면 기존 취소·환불 흐름을 따로 밟아야 한다.
--   ⚠ 방문 횟수(taam_visit_count_*)는 attended 만 센다. cancelled 는 안 센다 —
--     그 함수는 손대지 않는다. 「단골에게만 보이는 티켓」 조건은 그대로다.
--
-- 미래 날짜를 막지 않는 이유
--   방문·노쇼는 그날이 지나야 알 수 있어 미래 날짜를 막았다. 그런데
--   **취소는 방문일 전에 일어난다.** 같은 잣대를 대면 정작 필요한 때에
--   기록을 못 한다. 그래서 cancelled 만 그 검사를 지나간다.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 허용 값에 cancelled 를 더한다 ────────────────────────────
alter table public.tickets drop constraint if exists tickets_visit_status_chk;
alter table public.tickets add constraint tickets_visit_status_chk
  check (visit_status is null
         or visit_status in ('attended', 'no_show', 'cancelled'));

comment on column public.tickets.visit_status is
  '방문 결과: null(미기록) | attended(방문) | no_show(노쇼) | cancelled(취소된 예약).
   결제 상태(status)와 별개다. cancelled 는 기록일 뿐 환불을 뜻하지 않는다.';


-- ── ② 기록 함수 ────────────────────────────────────────────────
--   p_status: 'attended' | 'no_show' | 'cancelled' | null(기록 취소 — 잘못 눌렀을 때)
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
  v_key    text;
begin
  if p_status is not null and p_status not in ('attended', 'no_show', 'cancelled') then
    raise exception '방문 상태는 attended · no_show · cancelled · 비움만 가능합니다'
      using errcode = '22023';
  end if;

  select * into v_t from public.tickets where id = p_ticket_id;
  if not found then
    raise exception '예약을 찾을 수 없습니다' using errcode = 'P0002';
  end if;

  if not public.taam_can_mark_visit(v_t.restaurant_id) then
    raise exception '이 매장의 방문을 기록할 권한이 없습니다' using errcode = '42501';
  end if;

  -- 결제가 이미 취소된 건에는 아무것도 적지 않는다.
  --   (그런 건은 애초에 방문 기록 목록에 올라오지도 않는다)
  if v_t.status = 'cancelled' then
    raise exception '취소된 예약에는 방문을 기록할 수 없습니다' using errcode = '42501';
  end if;

  -- 아직 오지 않은 날을 미리 찍지 못하게.
  --   ⚠ reservation_date 는 **text** 이고 실제 값은 '2026.04.22' 처럼 점이다.
  --     형식을 짐작하지 않고 숫자만 뽑아 비교한다. 8자리가 안 나오면 막지 않는다.
  --   🆕 cancelled 는 이 검사를 지나간다 — 취소는 방문일 전에 일어난다.
  v_today := to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDD');
  v_key   := regexp_replace(coalesce(v_t.reservation_date, ''), '[^0-9]', '', 'g');
  if p_status is not null
     and p_status <> 'cancelled'
     and length(v_key) = 8
     and v_key > v_today then
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
  '티켓에 방문·노쇼·취소를 기록한다. 슈퍼어드민·그 매장 어드민만.
   결제 취소건은 거부. 미래 날짜는 취소만 허용.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 제약이 세 값을 받나 ⭐' as "구분",
       case when pg_get_constraintdef(oid) like '%cancelled%' then '✅' else '❌' end as "상태",
       'attended · no_show · cancelled' as "메모"
  from pg_constraint
 where conname = 'tickets_visit_status_chk'
union all
select '② 함수가 cancelled 를 아나 ⭐',
       case when prosrc like '%cancelled%' then '✅' else '❌' end,
       'taam_set_ticket_visit'
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_set_ticket_visit'
union all
select '③ 방문 횟수는 attended 만 세나 ⭐',
       case when prosrc not like '%cancelled%' then '✅ 안 셈' else '❌ 취소를 센다' end,
       '단골 티켓 조건이 헐거워지면 안 된다'
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname like 'taam_visit_count%'
 limit 1
union all
select '④ 지금까지 기록된 것',
       coalesce(visit_status, '(미기록)'),
       count(*)::text || '건'
  from public.tickets
 group by visit_status
 order by 1;
