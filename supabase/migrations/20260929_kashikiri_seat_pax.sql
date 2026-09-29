-- ============================================================================
-- 20260929_kashikiri_seat_pax.sql — 정산 좌석 인원 바꾸기 (2026-09-29 밤)
-- ============================================================================
-- 정산 좌석(KSK-)의 인원은 그 청구가 속한 조(kashikiri_teams.pax)가 정한다. 조가 없는 청구(임의 수신자 — Trina 처럼
-- 정산 링크로 바로 보낸 사람)는 1명으로 잡힌다. 실제로는 2명인데 바꿀 길이 없었다 — 캘린더의 「인원」 버튼은
-- 회원 결제 건(돈 재계산)용이라 KSK- 행에서는 감췄고, 조 편집은 정산 화면의 구매자 불러오기 경로에만 있다.
--
-- 이 RPC 하나로 맞춘다: 조가 없으면 그 청구 하나짜리 조를 만들어 붙이고, 있으면 조 인원을 고친다. 그러면
-- 조 pax 트리거 + 여기서 한 번 더 부르는 동기화가 좌석 party_size 를 따라 고친다 (늘릴 땐 총 정원 검사 → 넘치면 short).
-- 게스트 시트에도 그 조가 N명으로 나타난다 — 셰프에게 가는 인원과 좌석 카운팅이 같은 숫자를 본다.
-- 캘린더 KSK- 행의 「인원」 버튼이 이걸 부른다. SQL Editor(postgres)·service_role 도 부를 수 있다.
-- ============================================================================
create or replace function public.taam_ksk_seat_set_pax(p_purchase_id text, p_pax int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_role text := coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role', '');
  v_srv  boolean := (v_role = 'service_role' or session_user = 'postgres');
  v_t    public.tickets%rowtype;
  v_ch   public.kashikiri_charges%rowtype;
  v_ev   public.kashikiri_events%rowtype;
  v_team uuid;
begin
  if v_uid is null and not v_srv then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  if coalesce(p_pax, 0) < 1 or p_pax > 50 then raise exception 'PAX_RANGE: 인원은 1~50 사이여야 합니다' using errcode = '22023'; end if;

  select * into v_t from public.tickets
   where purchase_id = p_purchase_id and purchase_id like 'KSK-%' and coalesce(status, '') <> 'cancelled'
   order by created_at desc limit 1;
  if not found then raise exception 'SEAT_NOT_FOUND: 살아 있는 정산 좌석이 아닙니다' using errcode = 'P0002'; end if;
  select * into v_ch from public.kashikiri_charges where id::text = coalesce(v_t.extra_data->>'chargeId', '');
  if not found then raise exception 'CHARGE_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into v_ev from public.kashikiri_events where id = v_ch.event_id;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;

  if not (v_srv or public._taam_uid_is_super() or exists (
        select 1 from public.admin_grants g where g.user_id = v_uid
           and (g.rest_id::text = v_ev.venue_id or g.venue_id::text = v_ev.venue_id))) then
    raise exception '이 매장의 어드민만 바꿀 수 있습니다' using errcode = '42501';
  end if;

  if v_ch.team_id is null then
    insert into public.kashikiri_teams (event_id, seq, host_label, pax)
    values (v_ev.id,
            coalesce((select max(seq) from public.kashikiri_teams where event_id = v_ev.id), 0) + 1,
            coalesce(nullif(v_ch.payer_name, ''), v_ch.label, '정산'),
            p_pax)
    returning id into v_team;
    update public.kashikiri_charges set team_id = v_team where id = v_ch.id;
  else
    update public.kashikiri_teams set pax = p_pax where id = v_ch.team_id;   -- 조 pax 트리거가 동기화한다
  end if;
  -- 결과를 돌려주기 위해 한 번 더 (멱등). 정원을 넘으면 short 에 RESIZE_OVER_CAPACITY 가 담겨 온다.
  return public._taam_ksk_seat_sync(v_ev.id);
end $$;
revoke all on function public.taam_ksk_seat_set_pax(text, int) from public;
grant execute on function public.taam_ksk_seat_set_pax(text, int) to authenticated, service_role;

-- ── 확인 ──
select '① 인원 RPC' as what,
       case when to_regprocedure('public.taam_ksk_seat_set_pax(text,integer)') is not null then '✅' else '❌' end as result;
