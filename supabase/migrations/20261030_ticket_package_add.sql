-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 연계(패키지) 2 — 기존 패키지에 회차 더하기 · 예약 있는 회차는 연계 못 함 · 업로드하면서 연계 (2026-10-30)
-- ═══════════════════════════════════════════════════════════════
--   운영 요청: 「기존 티켓도 (구매자가 없다는 전제로) 연계에 추가 · 새로 티켓 만들면서도 연계로 만들 수 있게(티켓 업로드)」.
--   20261029_ticket_package.sql 위에 덧댄다 — 그 파일의 함수는 바꾸지 않는다(새 함수·트리거만).
--
--   A. 연계는 **예약이 하나도 없는 회차만** — ticket_package_rounds BEFORE INSERT 트리거(trg_taam_guard_pkg_round_booked).
--      만들기(taam_package_save) · 더하기(아래 B) 어느 길로 넣든 같은 검사. 살아 있는 좌석 행(취소·만료가 아닌 것 — 회원 구매 · 홀드 ·
--      초대 · 결제 링크 · 정산 · 수동 좌석) 이 하나라도 있으면 ROUND_HAS_BOOKINGS. 회원 홀드와 엇갈리지 않게 정원 트리거와 같은 잠금(tkcap_<회차>)을 먼저 잡는다
--      — 홀드가 먼저면 여기서 세어 거절하고, 연계가 먼저면 홀드 쪽 가드가 PACKAGE_ONLY 로 거절한다.
--      SQL Editor 에서 꼭 넣어야 하면 `set local taam.pkg_allow_booked = '1'`(운영 판단 · 그 예약은 단일로 남는다).
--   B. taam_package_add_rounds(패키지, 회차들, 공개할 회차) — 슈퍼어드민·서버. **구매자가 없는 패키지만**
--      (결제된 묶음 · 결제 중인 홀드 · 결과를 모르는 카드 주문이 하나도 없을 때 — 취소된 묶음은 괜찮다) · 회차 검사는 만들기와 같다
--      (없는 회차 · 승인 대기·숨김·삭제 · 연도 없음 · 지난 회차 · 다른 패키지 · 합쳐서 2~8개 · 같은 날 같은 시간대 · 재구매 제한 · 예약 있음) ·
--      회차 순서를 방문일 순으로 다시 매기고 패키지의 회차 목록(rounds)도 고친다.
--   C. 업로드하면서 연계 — 앱이 새 회차를 **숨김(hidden)으로 올리고** 연계 함수가 같은 트랜잭션에서 공개(active)한다(p_reveal).
--      연계가 실패하면 숨긴 채 남는다 — 단일로 잠깐이라도 팔리지 않는다. 새 패키지는 taam_package_save_reveal(만들기와 같은 인자 + 공개할 회차).
--      숨김 회차에는 회원 구매 행(PAY*)을 못 넣는다(trg_taam_guard_ticket_hidden_round) — 앱만 숨기던 것을 서버도 막는다.
--      로그인 호출의 운영 좌석(초대·수동·결제 링크 · 슈퍼어드민 포함)도 못 넣는다 — 좌석이 하나라도 서면 그 회차는 연계할 수 없게 된다(A).
--      숨김은 매진 동기화(중첩 갱신)가 바꾸지 못한다(trg_taam_tp_keep_hidden — pending 과 같은 지킴) — 종전엔 운영 좌석이 꽉 차면
--      hidden → soldout, 빠지면 soldout → active(취소표 알림까지)로 연계 없이 공개됐다(적대 리뷰 · 재현). 공개는 연계 함수(_taam_pkg_reveal) ·
--      슈퍼어드민의 직접 「연계 없이 공개」(깊이 1)만.
--   D. taam_package_round_bookings(회차들) — 회차마다 살아 있는 예약 수(화면의 「예약 N건 — 연계 불가」).
-- ═══════════════════════════════════════════════════════════════
create temp table if not exists _pka(항목 text, 결과 text);
truncate _pka;

-- ── 0. 숨김(hidden) 값을 status 가 받는가(제약이 있으면 더한다 — 앱은 이미 숨김을 거른다) ──
do $do$
declare c record; v_n int := 0; v_fixed int := 0; v_bad int := 0;
begin
  for c in select con.conname, pg_get_constraintdef(con.oid) as def from pg_constraint con
            where con.conrelid = 'public.ticket_products'::regclass and con.contype = 'c' and pg_get_constraintdef(con.oid) ~* '\mstatus\M' loop
    v_n := v_n + 1;
    if c.def ~* '''hidden''' then continue; end if;
    if c.def like '%ARRAY[%' then
      execute format('alter table public.ticket_products drop constraint %I', c.conname);
      execute format('alter table public.ticket_products add constraint %I %s', c.conname, replace(c.def, 'ARRAY[', 'ARRAY[''hidden''::text, '));
      v_fixed := v_fixed + 1;
    else
      v_bad := v_bad + 1;
    end if;
  end loop;
  insert into _pka values ('0 ticket_products.status 에 hidden',
    case when v_bad > 0 then '❌ 모양을 모르는 status 제약 ' || v_bad || '개 — 손으로 hidden 을 더해야 업로드 연계가 된다'
         when v_n = 0 then '✅ 제약 없음' when v_fixed > 0 then '✅ 제약에 hidden 더함(' || v_fixed || ')' else '✅ 이미 받음' end);
end $do$;

-- ── A. 예약 있는 회차는 연계 못 한다 ──
-- 회차의 살아 있는 좌석 행(취소·만료·환불·실패가 아닌 것) — 수·인원
create or replace function public._taam_pkg_round_live(p_tp text)
returns table (n int, pax int) language sql stable security definer set search_path = public as $$
  select count(*)::int, coalesce(sum(greatest(coalesce(t.party_size, 1), 1)), 0)::int
    from public.tickets t
   where t.ticket_product_id::text = p_tp
     and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'refunded', 'failed')
$$;
revoke all on function public._taam_pkg_round_live(text) from public, anon, authenticated;

create or replace function public.taam_guard_pkg_round_booked()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_n int; v_pax int; v_rn text; v_d text; v_tm text;
begin
  if coalesce(current_setting('taam.pkg_allow_booked', true), '') = '1' then return new; end if;
  -- 정원 트리거와 같은 잠금 — 같은 회차에 동시에 들어오는 회원 홀드와 순서를 정한다
  perform pg_advisory_xact_lock(hashtext('tkcap_' || new.ticket_product_id));
  select l.n, l.pax into v_n, v_pax from public._taam_pkg_round_live(new.ticket_product_id) l;
  if coalesce(v_n, 0) > 0 then
    select coalesce(tp.rest_name, tp.id::text), coalesce(tp.date, ''), coalesce(tp.time, '') into v_rn, v_d, v_tm
      from public.ticket_products tp where tp.id::text = new.ticket_product_id;
    raise exception 'ROUND_HAS_BOOKINGS: % % % — 예약 %건(%명)이 있어 연계할 수 없습니다(예약이 없는 회차만)',
      coalesce(v_rn, new.ticket_product_id), v_d, v_tm, v_n, v_pax using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_pkg_round_booked() from public, anon, authenticated;
drop trigger if exists trg_taam_guard_pkg_round_booked on public.ticket_package_rounds;
create trigger trg_taam_guard_pkg_round_booked before insert on public.ticket_package_rounds
  for each row execute function public.taam_guard_pkg_round_booked();
insert into _pka values ('A 예약 있는 회차는 연계 못 함(만들기·더하기 공통 트리거)', '✅');

-- ── C'. 숨김 회차에는 회원 구매 행을 못 넣는다 ──
create or replace function public.taam_guard_ticket_hidden_round()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_dead text[] := array['cancelled', 'canceled', 'expired', 'refunded', 'failed'];
begin
  if lower(coalesce(new.status, '')) = any(v_dead) then return new; end if;
  -- 이 갱신이 새로 「숨김 회차의 살아 있는 좌석」을 만드는 경우만 — 회차를 옮기거나 · 죽은 행을 되살릴 때
  if tg_op = 'UPDATE' and new.ticket_product_id is not distinct from old.ticket_product_id
     and not (lower(coalesce(old.status, '')) = any(v_dead)) then return new; end if;
  -- 회원 구매 행(PAY*)은 누가 넣든 · 운영 좌석(초대·수동·결제 링크·정산)은 로그인 호출(슈퍼어드민 포함)만 막는다 — 서버(Edge·SQL Editor)는 그대로
  if coalesce(new.purchase_id, '') !~ '^PAY' and auth.uid() is null then return new; end if;
  if exists (select 1 from public.ticket_products tp where tp.id::text = new.ticket_product_id::text and lower(coalesce(tp.status, '')) = 'hidden') then
    raise exception 'TICKET_NOT_OPEN: 지금 판매하지 않는 일정입니다(숨김 — 패키지 연계 대기) — 📦 티켓 패키지에서 연계하거나 「연계 없이 공개」 뒤에'
      using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_ticket_hidden_round() from public, anon, authenticated;
drop trigger if exists trg_taam_guard_ticket_hidden_round on public.tickets;
create trigger trg_taam_guard_ticket_hidden_round before insert or update of ticket_product_id, status on public.tickets
  for each row execute function public.taam_guard_ticket_hidden_round();
insert into _pka values ('C'' 숨김 회차에 좌석 막음(회원 구매 행 · 로그인 호출의 운영 좌석)', '✅');

-- ── C''. 숨김은 매진 동기화(중첩 갱신)가 못 바꾼다 — pending 과 같은 지킴 ──
--   공개는 깊이 1 의 갱신만(연계 함수 _taam_pkg_reveal · 슈퍼어드민의 직접 「연계 없이 공개」).
--   그리고 **연계된 회차는 다시 숨기지 않는다** — 로컬에 아직 hidden 으로 남은 낡은 사본(연계 응답을 잃음)을 「수정」해 저장하면
--   upsert 가 hidden 을 보내 이미 공개·연계된 회차를 숨겼고, 그러면 패키지 전체가 ROUND_CLOSED 로 안 팔렸다(2차 리뷰).
--   그 저장의 다른 칸은 그대로 두고 상태만 지킨다. 숨기려면 연계를 먼저 푼다.
create or replace function public.taam_guard_tp_keep_hidden()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 and lower(coalesce(old.status, '')) = 'hidden' and lower(coalesce(new.status, '')) <> 'hidden' then
    new.status := old.status;
  elsif lower(coalesce(old.status, '')) <> 'hidden' and lower(coalesce(new.status, '')) = 'hidden'
        and exists (select 1 from public.ticket_package_rounds r where r.ticket_product_id = new.id::text) then
    new.status := old.status;
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_tp_keep_hidden() from public, anon, authenticated;
drop trigger if exists trg_taam_tp_keep_hidden on public.ticket_products;
create trigger trg_taam_tp_keep_hidden before update of status on public.ticket_products
  for each row execute function public.taam_guard_tp_keep_hidden();
insert into _pka values ('C'''' 숨김은 매진 동기화가 못 바꾼다 · 연계된 회차는 다시 숨기지 않는다', '✅');

-- ── C. 숨김으로 올린 회차를 연계와 같은 트랜잭션에서 공개 ──
create or replace function public._taam_pkg_reveal(p_rounds text[], p_reveal text[])
returns int language plpgsql volatile security definer set search_path = public as $$
declare v_bad text; v_n int := 0;
begin
  if coalesce(array_length(p_reveal, 1), 0) = 0 then return 0; end if;
  select x into v_bad from unnest(p_reveal) x where not (x = any(coalesce(p_rounds, '{}'))) limit 1;
  if v_bad is not null then raise exception 'BAD_REVEAL: 공개할 회차가 연계 목록에 없습니다 (%)', v_bad using errcode = '22023'; end if;
  update public.ticket_products set status = 'active', updated_at = now()
   where id::text = any(p_reveal) and lower(coalesce(status, '')) = 'hidden';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public._taam_pkg_reveal(text[], text[]) from public, anon, authenticated;

create or replace function public.taam_package_save_reveal(p_reveal text[], p_title text, p_rounds text[],
                                                           p_title_en text default null, p_title_ja text default null,
                                                           p_desc text default null, p_desc_en text default null, p_desc_ja text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb; v_n int;
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  v_n := public._taam_pkg_reveal(p_rounds, p_reveal);
  v := public.taam_package_save(null, p_title, p_rounds, p_title_en, p_title_ja, p_desc, p_desc_en, p_desc_ja);
  return v || jsonb_build_object('revealed', v_n);
end $$;

-- ── B. 기존 패키지에 회차 더하기 ──
create or replace function public.taam_package_add_rounds(p_id text, p_rounds text[], p_reveal text[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_pkg public.ticket_packages%rowtype; v_new text[]; v_all text[]; v_n int; r record; v_conf jsonb;
  v_today date := (now() at time zone 'Asia/Seoul')::date; v_paid int; v_hold int; v_card int; v_rev int := 0; v_i int := 0; v_rid text;
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_pkg from public.ticket_packages where id = p_id for update;
  if not found then raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_pkg.status <> 'active' then raise exception 'PACKAGE_NOT_ACTIVE: 연계가 풀린 패키지입니다' using errcode = 'P0002'; end if;

  -- 구매자가 없는 패키지만 — 결제된 묶음 · 결제 중인 홀드 · 결과를 모르는 카드 주문
  select count(*) filter (where o.status = 'paid'), count(*) filter (where o.status = 'hold' and o.expires_at > now())
    into v_paid, v_hold from public.ticket_package_orders o where o.package_id = p_id;
  select count(*) into v_card
    from public.payment_orders po join public.ticket_package_orders o on o.id = po.metadata->>'group_id'
   where po.purpose = 'package_topup' and o.package_id = p_id
     and ((po.status = 'pending' and po.created_at > now() - interval '3 days')
       or (po.status = 'paid' and not (o.status in ('paid', 'cancelled') and o.order_id = po.order_id)));
  if coalesce(v_paid, 0) > 0 or coalesce(v_hold, 0) > 0 or coalesce(v_card, 0) > 0 then
    raise exception 'PACKAGE_HAS_BUYERS: 구매자가 있는 패키지에는 회차를 더할 수 없습니다 (결제 %건 · 결제 중 %건 · 카드 확인 중 %건) — 결제 중이면 몇 분 뒤 다시 · 결제된 패키지는 구성을 바꿀 수 없습니다(풀어도 판 좌석이 남아 다시 묶이지 않는다)',
      coalesce(v_paid, 0), coalesce(v_hold, 0), coalesce(v_card, 0) using errcode = '22023';
  end if;

  select array_agg(distinct btrim(x)) into v_new from unnest(coalesce(p_rounds, '{}')) x where btrim(coalesce(x, '')) <> '';
  if coalesce(array_length(v_new, 1), 0) = 0 then raise exception 'BAD_ROUNDS: 더할 회차를 고르세요' using errcode = '22023'; end if;
  select array_agg(ticket_product_id order by sort) into v_all from public.ticket_package_rounds where package_id = p_id;
  if exists (select 1 from unnest(v_new) x where x = any(coalesce(v_all, '{}'))) then
    raise exception 'ROUND_IN_PACKAGE: 이미 이 패키지에 있는 회차입니다' using errcode = '23505';
  end if;
  v_n := coalesce(array_length(v_all, 1), 0) + array_length(v_new, 1);
  if v_n < 2 or v_n > 8 then raise exception 'BAD_ROUNDS: 회차는 합쳐서 2~8개 (지금 % + 더할 %)', coalesce(array_length(v_all, 1), 0), array_length(v_new, 1) using errcode = '22023'; end if;

  v_rev := public._taam_pkg_reveal(v_new, p_reveal);

  for r in select u.id, tp.id as tid, tp.status, public._taam_pu_visit_date(tp.date) as d, coalesce(tp.rest_name, u.id) as rn
             from unnest(v_new) u(id) left join public.ticket_products tp on tp.id::text = u.id loop
    if r.tid is null then raise exception 'ROUND_NOT_FOUND: %', r.id using errcode = 'P0002'; end if;
    if coalesce(r.status, '') in ('pending', 'deleteRequest', 'hidden', 'deleted', 'cancelled') then
      raise exception 'ROUND_NOT_SELLABLE: % (상태 %)', r.rn, r.status using errcode = '22023';
    end if;
    if r.d is null then raise exception 'ROUND_NO_YEAR: % — 방문일에 연도가 없습니다', r.rn using errcode = '22023'; end if;
    if r.d < v_today then raise exception 'ROUND_PAST: % — 지난 회차', r.rn using errcode = '22023'; end if;
    if exists (select 1 from public.ticket_package_rounds pr where pr.ticket_product_id = r.id) then
      raise exception 'ROUND_IN_PACKAGE: % — 이미 다른 패키지에 있습니다', r.rn using errcode = '23505';
    end if;
  end loop;

  v_all := coalesce(v_all, '{}') || v_new;
  select array_agg(u.id order by public._taam_pu_visit_date(tp.date), tp.time, u.id) into v_all
    from unnest(v_all) u(id) left join public.ticket_products tp on tp.id::text = u.id;
  v_conf := public._taam_pkg_conflicts(v_all);
  if jsonb_array_length(v_conf) > 0 then
    raise exception 'PACKAGE_CONFLICT: %', (select string_agg(e->>'msg', ' / ') from jsonb_array_elements(v_conf) e) using errcode = '22023';
  end if;

  -- 새 회차를 넣고(트리거가 예약 여부를 본다) 전체를 방문일 순으로 다시 매긴다
  foreach v_rid in array v_all loop
    v_i := v_i + 1;
    if v_rid = any(v_new) then
      insert into public.ticket_package_rounds(ticket_product_id, package_id, sort) values (v_rid, p_id, v_i);
    else
      update public.ticket_package_rounds set sort = v_i where ticket_product_id = v_rid and package_id = p_id;
    end if;
  end loop;
  update public.ticket_packages set rounds = v_all, updated_at = now() where id = p_id;
  update public.ticket_products set updated_at = now() where id::text = any(v_new);
  return jsonb_build_object('ok', true, 'id', p_id, 'rounds', to_jsonb(v_all), 'added', to_jsonb(v_new), 'revealed', v_rev);
end $$;

-- ── D. 회차마다 살아 있는 예약 수 ──
create or replace function public.taam_package_round_bookings(p_rounds text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(array_length(p_rounds, 1), 0) > 400 then raise exception 'BAD_ROUNDS: 한 번에 400개까지' using errcode = '22023'; end if;
  return coalesce((select jsonb_object_agg(x.id, jsonb_build_object('n', l.n, 'pax', l.pax))
                     from (select distinct u as id from unnest(coalesce(p_rounds, '{}')) u where btrim(coalesce(u, '')) <> '') x
                     cross join lateral public._taam_pkg_round_live(x.id) l
                    where l.n > 0), '{}'::jsonb);
end $$;

revoke all on function public.taam_package_add_rounds(text, text[], text[]), public.taam_package_save_reveal(text[], text, text[], text, text, text, text, text),
                       public.taam_package_round_bookings(text[]) from public, anon;
grant execute on function public.taam_package_add_rounds(text, text[], text[]), public.taam_package_save_reveal(text[], text, text[], text, text, text, text, text),
                          public.taam_package_round_bookings(text[]) to authenticated;
insert into _pka values ('B·C·D 더하기 · 숨김 공개 · 예약 수 함수', '✅');

-- ── 확인 (하나로 · ❌ 가 없어야 정상) ──
select 항목, 결과 from _pka
union all select '필요한 20261029 함수(taam_package_save · _taam_pkg_conflicts · _taam_pkg_super_ok)',
       case when to_regprocedure('public.taam_package_save(text, text, text[], text, text, text, text, text)') is not null
             and to_regprocedure('public._taam_pkg_conflicts(text[])') is not null and to_regproc('public._taam_pkg_super_ok') is not null
            then '✅' else '❌ 20261029_ticket_package.sql 먼저' end
union all select '트리거 셋', case when (select count(*) from pg_trigger where not tgisinternal
                                         and tgname in ('trg_taam_guard_pkg_round_booked', 'trg_taam_guard_ticket_hidden_round', 'trg_taam_tp_keep_hidden')) = 3 then '✅' else '❌' end
union all select '회원·비로그인이 도우미를 못 부른다',
       case when has_function_privilege('authenticated', 'public._taam_pkg_reveal(text[], text[])', 'execute')
              or has_function_privilege('authenticated', 'public._taam_pkg_round_live(text)', 'execute')
              or has_function_privilege('anon', 'public.taam_package_add_rounds(text, text[], text[])', 'execute') then '❌' else '✅' end
union all select '지금 연계 중인 패키지 · 회차(정보)',
       (select count(*)::text from public.ticket_packages where status = 'active') || '개 · '
       || (select count(*)::text from public.ticket_package_rounds pr join public.ticket_packages p on p.id = pr.package_id and p.status = 'active') || '회차'
union all select '지금 숨김(hidden) 회차(정보)', (select count(*)::text from public.ticket_products where lower(coalesce(status, '')) = 'hidden') || '개';
