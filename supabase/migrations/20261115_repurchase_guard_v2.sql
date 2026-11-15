-- ============================================================================
-- 20261115_repurchase_guard_v2.sql — 재구매 제한 가드 v2 (2026-11-15 전수 점검 반영)
-- ============================================================================
-- 왜 (라이브 점검 · 36 에이전트 · 반박 검증 통과 — 실제 위반은 0건이었고, 아래는 「열려 있던 길」)
--   ① 카드 결제 확정 폴백이 검사를 통째로 비켜 갔다.
--      toss-confirm · toss-billing-charge 는 홀드가 사라졌으면(결제창 5분 초과 → 홀드 만료, 또는 홀드 없이 만든 주문)
--      service_role 로 PAY* 행을 새로 INSERT 한다(reservation_date = null). 옛 가드는 첫 줄
--      `current_user not in ('authenticated','anon') → 통과` 와 `reservation_date is null → 통과` 로 이 행을 보지 않았다.
--      그 행은 방문일이 비어 있어 그 뒤 구매에서도 기준으로 안 잡혔다.
--   ② 판매 뒤 회차 날짜(ticket_products.date)를 고치면 이미 팔린 티켓의 reservation_date 는 따라가지 않는다.
--      옛 가드는 티켓 행의 날짜만 비교해, 막아야 할 구매를 통과시키거나 허용해야 할 구매를 막았다.
--   ③ 연도 없는 날짜가 살아 있는 행에 있으면 ::date 변환 오류로 그 매장의 모든 구매가 깨졌다(지금 0건 · 잠재).
--
-- 어떻게 — 규칙(같은 매장 · 방문일 간격 0 초과 N일 미만 · 같은 날 허용 · 운영 행·해제 회차·면제 계정 예외)은 그대로다
--   · 회원 결제 행(purchase_id 가 PAY 로 시작)은 누가 넣든(Edge service_role · 보안 정의자 함수 · SQL Editor) 검사한다.
--     그 밖의 서버 INSERT(초대 INV-/INVH- · 정산 KSK- · 결제 링크 LINK- · 수동 MAN-)는 종전대로 통과.
--     SQL Editor 에서 일부러 넣어야 하면: set local taam.repurchase_bypass = '1';
--   · 서버 경로의 면제는 세션이 아니라 그 티켓 주인으로 본다(주인이 슈퍼어드민·어드민·면제 계정이면 통과 — 시험 결제).
--   · 회원 결제 행의 방문일이 비어 있으면 회차 날짜·시각으로 채운다(카드 폴백 행 — 리마인드·캘린더도 이 칸을 읽는다).
--   · 방문일·매장은 **회차 값이 먼저**, 회차가 없으면 티켓 행 값(옛 초대의 가짜 회차 등). 날짜는 _taam_pu_visit_date 로 안전하게 읽는다
--     (못 읽으면 근거 없음 = 그 행은 세지 않는다 — 중복·시간대 가드와 같은 규칙).
--   · 같은 purchase_id 의 다른 행도 기존 예약으로 센다(홀드 id 재사용 우회 — 검토).
--   · 막히면 같은 문구 'REPURCHASE_BLOCKED: 이 매장은 N 일 재구매 제한이 있습니다 (기존 방문일 YYYY.MM.DD)' — 앱이 이 모양을 읽는다.
--   · 카드 폴백 INSERT 가 여기서 막히면 Edge 가 예치금을 되돌리고 카드를 자동 취소한다(seat_lost · 기존 흐름).
--
-- 라이브 함수 본문이 저장소 판(sql/repurchase_release_7days.sql · md5 538def2887ae9d9395b88b87512d11d6)일 때만 바꾼다.
--   이미 v2 면 ✅ 그대로 · 모르는 판이면 건드리지 않고 ❌.
-- 되돌리기: sql/repurchase_release_7days.sql 의 taam_guard_repurchase() 를 다시 실행.
-- ============================================================================

do $mig$
declare v_src text; v_md5 text;
begin
  select p.prosrc into v_src from pg_proc p where p.oid = to_regprocedure('public.taam_guard_repurchase()');
  if v_src is null then
    raise warning '[repurchase v2] taam_guard_repurchase() 가 없습니다 — 건너뜀';
    return;
  end if;
  if v_src like '%REPURCHASE_V2_20261115%' then
    raise notice '[repurchase v2] 이미 v2 — 그대로';
    return;
  end if;
  v_md5 := md5(v_src);
  if v_md5 <> '538def2887ae9d9395b88b87512d11d6' then
    raise warning '[repurchase v2] 라이브 본문이 저장소 판과 다릅니다(md5 %) — 건드리지 않음', v_md5;
    return;
  end if;

  execute $fn$
create or replace function public.taam_guard_repurchase()
returns trigger
language plpgsql
set search_path = public
as $rep$
declare
  -- REPURCHASE_V2_20261115
  v_member  boolean := current_user in ('authenticated', 'anon');
  v_days    int;
  v_prev    record;
  v_exempt  boolean := false;
  v_role    text;
  v_tp_date text; v_tp_time text; v_tp_rest text;
  v_new     date;
  v_rest    text;
begin
  -- 서버 경로(Edge service_role · 보안 정의자 함수 · SQL Editor): 회원 결제 행(PAY*)만 본다
  if not v_member then
    if coalesce(new.purchase_id, '') !~ '^PAY' then return new; end if;
    if coalesce(current_setting('taam.repurchase_bypass', true), '') = '1' then return new; end if;
  end if;

  if new.user_id is null then return new; end if;

  -- 운영 행(어드민이 만든 좌석·초대 홀드·초대 확정)
  if coalesce(new.purchase_id, '') like 'MAN-%'
     or coalesce(new.purchase_id, '') like 'INVH-%'
     or coalesce(new.purchase_id, '') like 'INV-%'
     or coalesce(new.extra_data ->> 'manualEntry', '') in ('true','1')
     or coalesce(new.extra_data ->> 'inviteHold',  '') in ('true','1') then
    return new;
  end if;

  if coalesce(new.status, '') in ('cancelled','canceled') then return new; end if;

  -- 회차 — 방문일·매장의 기준
  if new.ticket_product_id is not null then
    select tp.date, tp.time, tp.rest_id::text into v_tp_date, v_tp_time, v_tp_rest
      from public.ticket_products tp where tp.id::text = new.ticket_product_id::text;
  end if;

  -- 회원 결제 행의 방문일이 비어 있으면 회차 날짜·시각으로 채운다(카드 확정 폴백 — 그 뒤 구매의 기준이 되게)
  if coalesce(btrim(new.reservation_date), '') = '' and coalesce(new.purchase_id, '') ~ '^PAY'
     and public._taam_pu_visit_date(v_tp_date) is not null then
    new.reservation_date := to_char(public._taam_pu_visit_date(v_tp_date), 'YYYY.MM.DD');
    if coalesce(btrim(new.visit_time), '') = '' and coalesce(btrim(v_tp_time), '') <> '' then
      new.visit_time := v_tp_time;
    end if;
  end if;

  v_new  := coalesce(public._taam_pu_visit_date(v_tp_date), public._taam_pu_visit_date(new.reservation_date));
  v_rest := coalesce(nullif(v_tp_rest, ''), nullif(new.restaurant_id::text, ''));
  if v_new is null or v_rest is null then return new; end if;   -- 판정할 근거가 없으면 막지 않는다

  -- 면제 — 회원 세션은 그 세션, 서버 경로는 티켓 주인
  if v_member then
    if public._taam_uid_is_super() then return new; end if;
    if exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin') then return new; end if;
  else
    select p.role into v_role from public.profiles p where p.id = new.user_id;
    if coalesce(v_role, '') in ('superadmin', 'super_admin', 'admin') then return new; end if;
  end if;
  select coalesce(p.single_device_exempt, false) into v_exempt from public.profiles p where p.id = new.user_id;
  if coalesce(v_exempt, false) then return new; end if;

  -- 회차별 수동 해제(슈퍼어드민 「재구매 해제」)
  if new.ticket_product_id is not null and public.taam_repurchase_released(new.ticket_product_id::text) then
    return new;
  end if;

  select r.repurchase_day into v_days from public.restaurants r where r.id::text = v_rest;
  if coalesce(v_days, 0) = 0 then return new; end if;

  -- 같은 매장의 살아 있는 예약 — 회차가 있으면 회차의 지금 날짜·매장으로(판매 뒤 회차 날짜를 고쳐도 맞게)
  select k.purchase_id, d.vd
    into v_prev
    from public.tickets k
    left join public.ticket_products tp2 on tp2.id::text = k.ticket_product_id::text
    cross join lateral (select coalesce(public._taam_pu_visit_date(tp2.date), public._taam_pu_visit_date(k.reservation_date)) as vd) d
   where k.user_id = new.user_id
     and coalesce(nullif(tp2.rest_id::text, ''), k.restaurant_id::text) = v_rest
     -- ⚠ 같은 purchase_id 의 행을 빼지 않는다(검토) — 카드 확정 폴백은 주문에 적힌 홀드 id 를 새 행에 그대로 쓰는데,
     --   회원이 자기의 살아 있는 다른 구매 id 를 홀드 id 로 보내면 그 구매가 비교에서 빠져 창 안의 두 번째 예약이 들어갔다.
     --   같은 회차의 옛 행은 간격 0(허용)이고, 만료된 같은 id 홀드는 cancelled 라 어차피 안 센다.
     and coalesce(k.status, '') not in ('cancelled','canceled')
     and coalesce(k.purchase_id, '') not like 'MAN-%'
     and coalesce(k.purchase_id, '') not like 'INVH-%'
     and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
     and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
     and d.vd is not null
     and abs(d.vd - v_new) > 0
     and abs(d.vd - v_new) < v_days
   order by abs(d.vd - v_new)
   limit 1;

  if found then
    raise exception
      'REPURCHASE_BLOCKED: 이 매장은 % 일 재구매 제한이 있습니다 (기존 방문일 %)',
      v_days, to_char(v_prev.vd, 'YYYY.MM.DD')
      using errcode = '42501';
  end if;

  return new;
end;
$rep$;
$fn$;
  raise notice '[repurchase v2] 교체했습니다';
end $mig$;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① 재구매 가드 v2 (회원 결제 행은 서버 경로도 검사 · 회차 날짜 기준)' as what,
       case when exists (select 1 from pg_proc where oid = to_regprocedure('public.taam_guard_repurchase()') and prosrc like '%REPURCHASE_V2_20261115%')
            then '✅' else '❌ 바뀌지 않음 — 라이브 본문이 저장소 판과 다릅니다(알림 메시지 확인)' end as result
union all
select '② 트리거 trg_taam_repurchase_guard 켜짐',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_repurchase_guard' and tgrelid = 'public.tickets'::regclass and tgenabled = 'O')
            then '✅' else '❌' end
union all
select '③ 의존 함수 (_taam_pu_visit_date · taam_repurchase_released · _taam_uid_is_super)',
       case when to_regprocedure('public._taam_pu_visit_date(text)') is not null
             and to_regprocedure('public.taam_repurchase_released(text)') is not null
             and to_regprocedure('public._taam_uid_is_super()') is not null then '✅' else '❌' end
union all
select '④ 방문일이 빈 살아 있는 회원 결제 행(정보)',
       (select count(*)::text from public.tickets
         where coalesce(purchase_id,'') ~ '^PAY' and coalesce(status,'') not in ('cancelled','canceled')
           and coalesce(btrim(reservation_date),'') = '')
union all
select '⑤ 회차 날짜와 다른 살아 있는 회원 결제 행(정보 — 회차 날짜를 판매 뒤에 고친 흔적)',
       (select count(*)::text from public.tickets k join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
         where coalesce(k.purchase_id,'') ~ '^PAY' and coalesce(k.status,'') not in ('cancelled','canceled')
           and public._taam_pu_visit_date(tp.date) is distinct from public._taam_pu_visit_date(k.reservation_date));
