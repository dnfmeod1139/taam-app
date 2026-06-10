-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 요청 (Phase 1) — 어드민 처리 RPC (수락/거절/방문) + 정책
-- 작성: 2026-06-10  (reservation_requests_phase1.sql 실행 후 적용)
-- ═══════════════════════════════════════════════════════════════
-- 예치금: change_type='reservation_payment' (스키마에 이미 허용됨),
--         멤버십 예치금 우선 → 일반 순으로 차감. 음수 방지 트리거 존중.
-- 실행: Supabase SQL Editor 에 통째로 Run (idempotent).
-- ═══════════════════════════════════════════════════════════════


-- ── 어드민이 요청자(회원)의 기본 프로필을 읽을 수 있게 (이름 표시용) ──
--   본인 매핑 매장에 요청을 넣은 회원에 한해 SELECT 허용 (additive 정책).
drop policy if exists "profiles read by venue admin for requesters" on public.profiles;
create policy "profiles read by venue admin for requesters" on public.profiles
  for select to authenticated
  using (
    exists (
      select 1 from public.reservation_requests rr
      where rr.user_id = profiles.id
        and ( public.is_super_admin(auth.uid()) or public.is_venue_admin_of(rr.venue_id) )
    )
  );


-- ── 1) 수락 — status=confirmed + 예치금 차감 ──
create or replace function public.confirm_reservation(p_request_id uuid)
returns public.reservation_requests
language plpgsql security definer set search_path = public
as $$
declare
  r        public.reservation_requests%rowtype;
  v_mem    bigint;
  v_gen    bigint;
  v_need   bigint;
  v_from_m bigint;
  v_from_g bigint;
  v_after  bigint;
begin
  select * into r from public.reservation_requests where id = p_request_id;
  if not found then raise exception 'NOT_FOUND' using errcode='P0001'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(r.venue_id)) then
    raise exception 'FORBIDDEN' using errcode='P0001';
  end if;
  if r.status <> 'pending' then raise exception 'NOT_PENDING' using errcode='P0001'; end if;

  v_need := coalesce(r.deposit_amount, 0);

  select coalesce(membership_deposit_balance,0), coalesce(general_deposit_balance,0)
    into v_mem, v_gen
    from public.profiles where id = r.user_id;

  if v_need > 0 and (v_mem + v_gen) >= v_need then
    -- 예치금 충분 → 멤버십 우선 차감
    v_from_m := least(v_mem, v_need);
    v_from_g := v_need - v_from_m;
    v_after  := (v_mem - v_from_m) + (v_gen - v_from_g);

    update public.profiles
      set membership_deposit_balance = v_mem - v_from_m,
          general_deposit_balance    = v_gen - v_from_g,
          deposit_balance            = v_after
      where id = r.user_id;

    if v_from_m > 0 then
      insert into public.deposit_transactions
        (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
      values (r.user_id, 'membership', 'reservation_payment', -v_from_m, v_after,
              '예약 확정 예치금 차감 (멤버십)',
              jsonb_build_object('reservation_id', r.id, 'venue_id', r.venue_id));
    end if;
    if v_from_g > 0 then
      insert into public.deposit_transactions
        (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
      values (r.user_id, 'general', 'reservation_payment', -v_from_g, v_after,
              '예약 확정 예치금 차감 (일반)',
              jsonb_build_object('reservation_id', r.id, 'venue_id', r.venue_id));
    end if;

    update public.reservation_requests
      set status='confirmed', handled_by=auth.uid(), handled_at=now(), deposit_status='paid'
      where id = p_request_id returning * into r;
  else
    -- 예치금 0원이거나 잔액 부족 → 확정은 하되 결제상태 표시
    update public.reservation_requests
      set status='confirmed', handled_by=auth.uid(), handled_at=now(),
          deposit_status = case when v_need = 0 then 'none' else 'unpaid' end
      where id = p_request_id returning * into r;
  end if;

  return r;
end;
$$;
comment on function public.confirm_reservation is '예약 수락: status=confirmed + 예치금(reservation_payment) 차감. 잔액부족 시 unpaid.';


-- ── 2) 거절 — status=declined (pending 카운트 자동 복구) ──
create or replace function public.decline_reservation(p_request_id uuid)
returns public.reservation_requests
language plpgsql security definer set search_path = public
as $$
declare r public.reservation_requests%rowtype;
begin
  select * into r from public.reservation_requests where id = p_request_id;
  if not found then raise exception 'NOT_FOUND' using errcode='P0001'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(r.venue_id)) then
    raise exception 'FORBIDDEN' using errcode='P0001';
  end if;
  if r.status <> 'pending' then raise exception 'NOT_PENDING' using errcode='P0001'; end if;

  update public.reservation_requests
    set status='declined', handled_by=auth.uid(), handled_at=now()
    where id = p_request_id returning * into r;
  return r;
end;
$$;
comment on function public.decline_reservation is '예약 거절: status=declined.';


-- ── 3) 식사 후 방문/노쇼 1탭 (트리거가 profiles 신뢰카운트 갱신) ──
create or replace function public.mark_reservation_visit(p_request_id uuid, p_status text)
returns public.reservation_requests
language plpgsql security definer set search_path = public
as $$
declare r public.reservation_requests%rowtype;
begin
  if p_status not in ('attended','no_show') then
    raise exception 'BAD_STATUS' using errcode='P0001';
  end if;
  select * into r from public.reservation_requests where id = p_request_id;
  if not found then raise exception 'NOT_FOUND' using errcode='P0001'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(r.venue_id)) then
    raise exception 'FORBIDDEN' using errcode='P0001';
  end if;
  if r.status <> 'confirmed' then raise exception 'NOT_CONFIRMED' using errcode='P0001'; end if;

  update public.reservation_requests
    set visit_status = p_status
    where id = p_request_id returning * into r;
  return r;
end;
$$;
comment on function public.mark_reservation_visit is '방문/노쇼 기록. 트리거가 taam_visit_count/no_show_count 갱신.';
