-- ═══════════════════════════════════════════════════════════════
-- TAAM — 대관 회차를 판매 티켓에 연결한다 (2026-09-01)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   대관은 결국 그 날짜 티켓을 산 사람들이 오는 자리다. 그런데 지금은
--   회차를 손으로 만들면서 매장·날짜·인원·호스트를 **다시 적고** 있다.
--   티켓을 산 사람이 곧 호스트다 — 이미 아는 것을 두 번 묻고 있었다.
--
--   더 큰 구멍이 하나 있었다. 손으로 만든 회차는 venue_id 가
--   'manual-…' 이라, 게스트 시트의 「그 매장에서의 지난 회계」가
--   **영영 안 잡힌다.** 티켓에 연결하면 venue_id 가 진짜 매장이 되어
--   그것까지 같이 풀린다.
--
-- 무엇을 넣나
--   ① kashikiri_events.ticket_product_id  — 어느 티켓의 대관인가
--   ② kashikiri_teams.ticket_id           — 어느 구매 건에서 온 조인가
--      (같은 구매를 두 번 불러오지 않기 위한 표식)
--   ③ taam_kashikiri_import_teams()       — 구매자들을 조로 만든다
--
--   ⚠ 두 컬럼 다 text 다. tickets.id 의 실제 타입을 라이브에서 확인하지
--     않고 uuid 로 못 박았다가 두 번 깨뜨린 적이 있다(sale_open_at ·
--     invite_codes.member_id). 링크용 컬럼은 FK 가 아니므로 text 로 두고
--     비교할 때 캐스팅한다 — 어느 쪽이든 안전하다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ sql/kashikiri.sql 을 먼저 돌린 뒤에 실행한다.
--   읽는 법: 맨 아래 표에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════

alter table public.kashikiri_events
  add column if not exists ticket_product_id text;
alter table public.kashikiri_teams
  add column if not exists ticket_id text;

create index if not exists idx_ke_ticket on public.kashikiri_events(ticket_product_id);
create index if not exists idx_kt_ticket on public.kashikiri_teams(ticket_id);

comment on column public.kashikiri_events.ticket_product_id is
  '이 대관이 어느 판매 티켓의 자리인가. 있으면 구매자를 조로 불러올 수 있다.';
comment on column public.kashikiri_teams.ticket_id is
  '이 조가 어느 구매 건에서 왔나. 같은 구매를 두 번 불러오지 않기 위한 표식.';


-- ─────────────────────────────────────────────────────────────
-- 구매자 → 조 불러오기
-- ─────────────────────────────────────────────────────────────
--   한 구매 = 한 조다. 티켓은 「몇 명이서 온다」로 팔리므로
--   party_size 가 곧 그 조의 인원이고, 산 사람이 곧 호스트다.
--
--   ⚠ 여러 번 눌러도 안전하다. 이미 불러온 구매(ticket_id)는 건너뛴다.
--   ⚠ 금액은 건드리지 않는다. 티켓 가격은 「예약금」이고 대관 확정 금액은
--     현장에서 나온다 — 둘은 다른 숫자다. 섞으면 정산이 어긋난다.
create or replace function public.taam_kashikiri_import_teams(p_event_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  e        public.kashikiri_events%rowtype;
  r        record;
  v_seq    int;
  v_made   int := 0;
  v_skip   int := 0;
  v_label  text;
  v_team   uuid;
  v_visits int;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;

  select * into e from public.kashikiri_events where id = p_event_id;
  if not found then raise exception '회차를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if coalesce(e.ticket_product_id, '') = '' then
    raise exception '이 회차에 연결된 판매 티켓이 없습니다' using errcode = '22023';
  end if;

  select coalesce(max(seq), 0) into v_seq
    from public.kashikiri_teams where event_id = e.id;

  for r in
    select t.id, t.user_id, t.party_size, t.buyer_name
      from public.tickets t
     where t.ticket_product_id = e.ticket_product_id
       and coalesce(t.status, '') = 'active'
     order by t.created_at
  loop
    -- 이미 불러온 구매는 건너뛴다
    if exists (select 1 from public.kashikiri_teams kt
                where kt.event_id = e.id and kt.ticket_id = r.id::text) then
      v_skip := v_skip + 1;
      continue;
    end if;

    -- 게스트 시트는 姓 + 様 만 적는다. 한글 이름이라 그대로는 셰프가 못 읽으므로
    -- 첫 글자만 남긴다. 어드민이 조 수정에서 손볼 수 있는 초안이다.
    v_label := nullif(trim(coalesce(r.buyer_name, '')), '');
    v_label := case when v_label is null then '게스트'
                    else substr(v_label, 1, 1) || '様' end;

    -- 그 매장 방문 횟수 — taam_visit_count 를 부르지 않는다.
    --   그 함수는 호출자 권한을 따로 보므로 여기서 예외가 날 수 있다.
    --   같은 규칙을 그대로 센다 (attended · 취소 제외).
    select count(*) into v_visits
      from public.tickets t2
     where t2.user_id = r.user_id
       and t2.restaurant_id = e.venue_id
       and t2.visit_status = 'attended'
       and coalesce(t2.status, '') not in ('cancelled', 'canceled');

    v_seq := v_seq + 1;
    insert into public.kashikiri_teams
      (event_id, seq, host_user_id, host_label, pax, ticket_id)
    values
      (e.id, v_seq, r.user_id, v_label, greatest(1, coalesce(r.party_size, 1)), r.id::text)
    returning id into v_team;

    insert into public.kashikiri_guests
      (team_id, seq, display_name, user_id, is_host, visit_count)
    values
      (v_team, 1, v_label, r.user_id, true, coalesce(v_visits, 0));

    v_made := v_made + 1;
  end loop;

  -- 총 인원은 조 합계로 다시 맞춘다 (손으로 적어 둔 값이 어긋나 있을 수 있다)
  update public.kashikiri_events
     set total_pax = coalesce((select sum(pax) from public.kashikiri_teams where event_id = e.id), 0),
         updated_at = now()
   where id = e.id;

  return jsonb_build_object('created', v_made, 'skipped', v_skip,
    'total_pax', (select coalesce(sum(pax),0) from public.kashikiri_teams where event_id = e.id));
end;
$$;

revoke all on function public.taam_kashikiri_import_teams(uuid) from public;
grant execute on function public.taam_kashikiri_import_teams(uuid) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 컬럼' as "구분", c.t || '.' || c.n as "이름",
       case when not exists (
              select 1 from pg_attribute a
               where a.attrelid = ('public.' || c.t)::regclass
                 and a.attname = c.n and a.attnum > 0 and not a.attisdropped)
            then '❌ 없음' else '✅' end as "상태"
  from (values ('kashikiri_events','ticket_product_id'),
               ('kashikiri_teams','ticket_id')) as c(t, n)

union all
select '② 함수', 'taam_kashikiri_import_teams',
       case when not exists (
              select 1 from pg_proc pr
               where pr.pronamespace = 'public'::regnamespace
                 and pr.proname = 'taam_kashikiri_import_teams')
            then '❌ 없음' else '✅' end

union all
select '③ 연결된 회차', count(*)::text || ' 건', '✅'
  from public.kashikiri_events where ticket_product_id is not null

 order by 1, 2;
