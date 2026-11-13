-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원 구매 행(PAY*)은 있는 회차의 것이고, 매장은 「회차의 매장」이다 — 회원이 적은 값을 믿지 않는다 (2026-11-13)
-- ═══════════════════════════════════════════════════════════════
--   회원은 「결제하기」를 누를 때 자기 세션으로 좌석 홀드(PAYH-)를 넣는다. 그 INSERT 의 restaurant_id · restaurant_name 은
--   앱이 적는 칸이고 서버는 회차(ticket_products)와 대조하지 않았다(INSERT 가드는 소유자·상태·접두어만 본다 · UPDATE 는 행 가드가 막는다).
--   그래서 REST 로 직접 넣으면 아무 글자나 들어갔다:
--     · 재구매 제한(trg_taam_repurchase_guard)은 new.restaurant_id 로 매장을 본다 → 다른 값을 적으면 「같은 매장 N일」을 비켜 간다
--     · 매장 어드민의 RLS·캘린더는 restaurant_id 로 자기 매장 행을 고른다 → 남의 매장 캘린더에 홀드가 뜨거나, 자기 매장에서 안 보인다
--     · 티켓 캘린더 머리줄이 매장 id 를 onclick 에 그대로 넣던 자리(2026-11-13 앱에서 이스케이프)에 따옴표가 든 값이 닿았다
--   (2026-11-12 결제 전 홀드 표시의 적대 리뷰가 찾았다 · 라이브 PAY* 152행은 전부 회차와 같다 — 악용 흔적 없음)
--
--   규칙(별도 트리거 둘 · 종전 가드 본문은 안 건드린다) — 로그인 호출(슈퍼어드민 제외)의 회원 구매 행(PAY*)만 본다:
--     INSERT (trg_taam_guard_ticket_rest_pin · security definer — 회원은 RLS 로 승인 대기·숨김 회차를 못 읽는다)
--       ① 회차(ticket_product_id)가 비었거나 없는 회차면 **거절**(TICKET_NOT_FOUND) — 회차 없는 홀드는 정원·등급·매장 어느 가드도 못 보고,
--          확정 함수가 금액을 못 세어 ₩0 로 확정될 수 있었다(아무 매장·날짜의 「앱구매」 유령 예약 · 2차 검증). 정상 앱은 언제나 있는 회차를 보낸다
--          (라이브 최근 30일 회원 홀드 29건 전부 회차 있음).
--       ② restaurant_id · restaurant_name 을 **회차 값으로 맞춘다**(예외 아님 — 정상 앱은 이미 같은 값 · 회차에 그 칸이 비어 있으면 보낸 값 그대로)
--       ③ 운영 행 표시(manualEntry · inviteHold · kashikiri · linkInvite · memberUid)를 extra_data 에서 **지운다** — 재구매 가드는 그 표시가 있으면
--          검사를 건너뛴다(회원이 홀드에 적어 재구매 제한을 비켜 가던 길 · 2차 검증). 회원 구매 행은 운영 행이 아니다(앱은 seatHold · heldAt · pkg 만 보낸다 · 라이브 0건)
--     UPDATE OF restaurant_name (trg_taam_guard_ticket_rest_name · security invoker — 앱이 직접 보낸 문장만)
--       회원 구매 행의 매장 이름을 바꾸면 **되돌린다**(id 는 행 가드가 막는다) — 확정 함수가 그 이름을 원장 설명에 옮겨 적는다
--     · 서버(auth.uid() null — Edge · SQL Editor · 크론) · 슈퍼어드민 · 운영 행(MAN-·INVH-·LINK-·KSK- — INSERT 가드가 매장 권한을 본다)은 그대로
--     · 이름 순으로 재구매 가드(trg_taam_repurchase_guard) · 중복 가드(…ticket_unique)보다 먼저 돈다(…ticket_rest_pin < …ticket_round_open < trg_taam_r…)
--   회귀: bash sql/_test/t_hold_rest_pin.sh
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_guard_ticket_rest_pin()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_tp jsonb; v_super boolean := false; k text;
begin
  if auth.uid() is null then return new; end if;                                   -- 서버 호출
  if coalesce(new.purchase_id, '') not like 'PAY%' then return new; end if;         -- 회원 구매 행만
  begin
    v_super := coalesce(public._taam_uid_is_super(), false);
  exception when others then
    raise warning 'taam_guard_ticket_rest_pin: % — 손대지 않는다', sqlerrm;        -- 판정을 못 하면 아무것도 안 한다(구매를 막지 않는다)
    return new;
  end;
  if v_super then return new; end if;

  -- ① 회차가 있어야 한다
  if coalesce(new.ticket_product_id::text, '') <> '' then
    select to_jsonb(tp) into v_tp from public.ticket_products tp where tp.id::text = new.ticket_product_id::text;
  end if;
  if v_tp is null then
    raise exception 'TICKET_NOT_FOUND: 판매 중인 회차가 아닙니다' using errcode = '42501';
  end if;

  -- ② 매장은 회차의 매장
  if coalesce(v_tp->>'rest_id', '') <> '' then new.restaurant_id := v_tp->>'rest_id'; end if;
  if coalesce(v_tp->>'rest_name', '') <> '' then new.restaurant_name := v_tp->>'rest_name'; end if;

  -- ③ 운영 행 표시는 회원 구매 행에 없다
  if new.extra_data is not null and jsonb_typeof(new.extra_data) = 'object' then
    foreach k in array array['manualEntry', 'inviteHold', 'kashikiri', 'linkInvite', 'memberUid'] loop
      new.extra_data := new.extra_data - k;
    end loop;
  end if;
  return new;
end;
$$;
comment on function public.taam_guard_ticket_rest_pin() is
  '티켓 INSERT: 로그인 호출(슈퍼어드민 제외)의 회원 구매 행(PAY*)은 ① 있는 회차여야 하고(TICKET_NOT_FOUND) ② restaurant_id·restaurant_name 을 회차 값으로 맞추고 ③ 운영 행 표시를 지운다 — 재구매 가드·매장 어드민 범위가 이 칸들을 본다. 2026-11-13';
revoke all on function public.taam_guard_ticket_rest_pin() from public, anon, authenticated;

create or replace function public.taam_guard_ticket_rest_name()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 서버(service_role · postgres · SECURITY DEFINER 함수)는 막지 않는다 — 앱이 직접 보낸 문장만
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.restaurant_name is not distinct from old.restaurant_name then return new; end if;
  if coalesce(old.purchase_id, '') not like 'PAY%' then return new; end if;         -- 운영 행(수동·초대 홀드)은 넣은 어드민의 것
  if public._taam_uid_is_super() then return new; end if;
  new.restaurant_name := old.restaurant_name;                                       -- 되돌림(같은 UPDATE 의 다른 칸 — 취소 등 — 은 그대로)
  return new;
end;
$$;
comment on function public.taam_guard_ticket_rest_name() is
  '티켓 UPDATE: 회원·매장 어드민 세션이 직접 보낸 문장은 회원 구매 행(PAY*)의 restaurant_name 을 못 바꾼다(되돌림) — 확정 함수가 이 이름을 원장 설명에 적는다. 2026-11-13';

-- 슈퍼어드민 판정 함수가 없는 DB 에는 걸지 않는다(확인 표 ①② 가 ❌) — 가드가 구매를 막는 일은 없어야 한다
do $do$
begin
  execute 'drop trigger if exists trg_taam_guard_ticket_rest_pin on public.tickets';
  execute 'drop trigger if exists trg_taam_guard_ticket_rest_name on public.tickets';
  if to_regproc('public._taam_uid_is_super') is null then
    raise notice '_taam_uid_is_super 가 없다 — 트리거를 걸지 않는다';
    return;
  end if;
  execute 'create trigger trg_taam_guard_ticket_rest_pin before insert on public.tickets for each row execute function public.taam_guard_ticket_rest_pin()';
  execute 'create trigger trg_taam_guard_ticket_rest_name before update of restaurant_name on public.tickets for each row execute function public.taam_guard_ticket_rest_name()';
end $do$;

-- ── 확인 — 한 표 (건수만 · 공개 로그) ──
select '① 트리거 trg_taam_guard_ticket_rest_pin (before insert on tickets)' as 항목,
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_guard_ticket_rest_pin' and c.relname = 'tickets' and not t.tgisinternal
                            and (t.tgtype::int & 2) = 2 and (t.tgtype::int & 4) = 4) then '✅' else '❌' end as 결과
union all select '② 함수 security definer · _taam_uid_is_super 존재',
       case when (select prosecdef from pg_proc where oid = to_regproc('public.taam_guard_ticket_rest_pin'))
             and to_regproc('public._taam_uid_is_super') is not null then '✅' else '❌' end
union all select '③ 이름 순서 — 재구매 가드·중복 가드보다 먼저 돈다',
       case when 'trg_taam_guard_ticket_rest_pin' < 'trg_taam_guard_ticket_unique' and 'trg_taam_guard_ticket_rest_pin' < 'trg_taam_repurchase_guard' then '✅' else '❌' end
union all select '④ 정보 — 지금 회차와 매장 id 가 다른 회원 구매 행(PAY*) 수(0 이어야 정상 · 있으면 원장에서 확인)',
       (select count(*) from public.tickets t join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
         where t.purchase_id like 'PAY%' and coalesce(to_jsonb(tp)->>'rest_id', '') <> ''
           and t.restaurant_id::text is distinct from (to_jsonb(tp)->>'rest_id'))::text
union all select '⑥ 트리거 trg_taam_guard_ticket_rest_name (before update of restaurant_name · security invoker)',
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_guard_ticket_rest_name' and c.relname = 'tickets' and not t.tgisinternal
                            and (t.tgtype::int & 2) = 2 and (t.tgtype::int & 16) = 16)
             and (select not prosecdef from pg_proc where oid = to_regproc('public.taam_guard_ticket_rest_name')) then '✅' else '❌' end
union all select '⑦ 정보 — 최근 30일 회원 홀드(PAYH-) 중 회차가 없는 행 수(0 이어야 정상 — 이제 이런 홀드는 거절된다)',
       (select count(*) from public.tickets t
         where t.purchase_id like 'PAYH-%' and t.created_at > now() - interval '30 days'
           and not exists (select 1 from public.ticket_products tp where tp.id::text = t.ticket_product_id::text))::text
union all select '⑧ 정보 — 운영 행 표시(manualEntry·inviteHold·kashikiri·linkInvite·memberUid)가 붙은 회원 구매 행(PAY*) 수(0 이어야 정상)',
       (select count(*) from public.tickets t
         where t.purchase_id like 'PAY%' and jsonb_typeof(t.extra_data) = 'object'
           and (t.extra_data ? 'manualEntry' or t.extra_data ? 'inviteHold' or t.extra_data ? 'kashikiri' or t.extra_data ? 'linkInvite' or t.extra_data ? 'memberUid'))::text
union all select '⑤ 정보 — 행 가드(taam_guard_ticket_row)가 UPDATE 의 restaurant_id 변경을 본다',
       case when to_regproc('public.taam_guard_ticket_row') is null then '⚠ 함수 없음'
            when (select prosrc from pg_proc where oid = to_regproc('public.taam_guard_ticket_row')) like '%restaurant_id%' then '✅' else '⚠ 안 본다 — UPDATE 로 매장을 바꿀 수 있는지 확인' end;
