-- 라이브 pg_get_functiondef 원문(2026-11-16 조회) — 테스트가 md5 를 라이브 값과 대조한다
CREATE OR REPLACE FUNCTION public._taam_text_bad(v jsonb, p_old jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select exists (
    select 1 from jsonb_path_query(v, 'strict $.** ? (@.type() == "string")') x
     where ((x #>> '{}') ~* '<\s*[a-z/!?]' or (x #>> '{}') ~* 'javascript\s*:')
       and (p_old is null or not exists (select 1 from jsonb_path_query(p_old, 'strict $.** ? (@.type() == "string")') y where (y #>> '{}') = (x #>> '{}'))))
$function$
;
CREATE OR REPLACE FUNCTION public._taam_tp_date_year()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text; o text; o_created timestamptz; anchor date; src text; v_new text;
begin
  s := btrim(coalesce(NEW.date, ''));
  if s !~ '^\d{1,2}\.\d{1,2}$' then return NEW; end if;
  -- 저장된 같은 id 의 행 — UPDATE 는 OLD, INSERT 는 직접 읽는다(upsert 의 INSERT 가지 · 아직 없는 새 행이면 null)
  if TG_OP = 'UPDATE' then
    o := btrim(coalesce(OLD.date, '')); o_created := (to_jsonb(OLD)->>'created_at')::timestamptz;
  else
    select btrim(coalesce(tp.date, '')), (to_jsonb(tp)->>'created_at')::timestamptz into o, o_created
      from public.ticket_products tp where tp.id = NEW.id;
  end if;
  if o ~ '^\d{4}\.\d{1,2}\.\d{1,2}$'
     and split_part(o, '.', 2)::int = split_part(s, '.', 1)::int
     and split_part(o, '.', 3)::int = split_part(s, '.', 2)::int then
    v_new := split_part(o, '.', 1) || '.' || s; src := 'guard:keep';                                   -- 옛 앱의 다시 저장 — 저장된 연도를 지킨다
  elsif o ~ '^\d{1,2}\.\d{1,2}$' and split_part(o, '.', 1)::int = split_part(s, '.', 1)::int and split_part(o, '.', 2)::int = split_part(s, '.', 2)::int then
    v_new := public._taam_mmdd_year(s, (coalesce(o_created, now()) at time zone 'Asia/Seoul')::date); src := 'guard:created';   -- 아직 연도 없는 옛 행 — 그 행의 올린 날
  elsif o is not null and o <> '' then
    v_new := public._taam_mmdd_year(s, (now() at time zone 'Asia/Seoul')::date); src := 'guard:moved';   -- 옛 앱의 날짜 수정 — 지금 기준
  else
    v_new := public._taam_mmdd_year(s, (coalesce((to_jsonb(NEW)->>'created_at')::timestamptz, now()) at time zone 'Asia/Seoul')::date); src := 'guard:new';
  end if;
  if v_new is not null then
    begin
      insert into public.ticket_date_year_log(tbl, row_id, old_date, new_date, source) values ('ticket_products', NEW.id::text, s, v_new, src);
    exception when others then null; end;   -- 기록 실패가 저장을 막지 않는다
    NEW.date := v_new;
  end if;
  return NEW;
end $function$
;
CREATE OR REPLACE FUNCTION public.sync_ticket_soldout()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_text_input()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_new jsonb; v_old jsonb; k text; v jsonb;
begin
  if auth.uid() is null or public.is_super_admin(auth.uid()) then return new; end if;
  v_new := to_jsonb(new); v_old := case when TG_OP = 'UPDATE' then to_jsonb(old) else null end;
  for k, v in select e.key, e.value from jsonb_each(v_new) e loop
    if v_old is not null and (v_old -> k) is not distinct from v then continue; end if;
    if v is null or jsonb_typeof(v) = 'null' then continue; end if;
    if TG_TABLE_NAME = 'tickets' and k = 'purchase_id' and not (v #>> '{}' ~ '^[0-9A-Za-z_.:-]{1,100}$') then
      raise exception 'BAD_INPUT: 구매 id 모양이 아닙니다' using errcode = '22023';
    end if;
    if public._taam_text_bad(v, case when v_old is null then null else v_old -> k end) then
      raise exception 'BAD_INPUT: % 칸에 HTML 태그 모양의 글자는 쓸 수 없습니다', k using errcode = '22023';
    end if;
  end loop;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_ticket_crp_member()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_crp jsonb;
  v_done_keys text[] := array['done_by','done_at','refunded_at','refunded_amount','requested_amount','toss_tx','toss_canceled_at','toss_balance_after','via','policy'];
begin
  if v_uid is null then return new; end if;                                   -- 서버(service_role · SQL Editor · Edge)는 그대로
  if coalesce(public.is_super_admin(v_uid), false) then return new; end if;  -- 슈퍼어드민 「완료 표시」·반환 화면은 그대로
  v_crp := new.extra_data -> 'card_refund_pending';
  if v_crp is null or jsonb_typeof(v_crp) <> 'object' then return new; end if;
  if (old.extra_data -> 'card_refund_pending') is not distinct from v_crp then return new; end if;   -- 이 갱신이 바꾼 것만 본다
  if (v_crp ->> 'status') is not distinct from 'pending' and not (v_crp ?| v_done_keys) then return new; end if;
  new.extra_data := jsonb_set(new.extra_data, '{card_refund_pending}', (v_crp - v_done_keys) || jsonb_build_object('status', 'pending'));
  return new;
exception when others then
  raise warning 'taam_guard_ticket_crp_member: % — 손대지 않고 통과', sqlerrm;
  return new;   -- 취소를 막지 않는다
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_ticket_linkfacts()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_keys text[] := array['chargeId','token','currency','payAmount','fx','agencyFee','agencyPay','priceOverride','ovsFixed','eventId','convertedFrom',
                         'inviteId','memberUidPending','ownerTransferError','createdBy',
                         'paidAt','paymentKey','confirmed_at','confirmed_by','invitePaid','inserted'];
  v_ins  text[] := array['chargeId','token','eventId','convertedFrom','inviteId'];
  v_old jsonb; v_new jsonb; k text;
begin
  -- 앱이 직접 보낸 문장만 — 서버 함수(security definer 안에서는 current_user 가 함수 소유자)·Edge·SQL Editor 는 그대로
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if coalesce(public._taam_uid_is_super(), false) then return new; end if;
  if tg_op = 'INSERT' then
    if coalesce(new.purchase_id, '') ~ '^(LINK|KSK)-' then
      raise exception 'LINK_SEAT_SERVER_ONLY: 결제 링크·정산 좌석은 서버만 만듭니다' using errcode = '42501';
    end if;
    if new.extra_data is not null and jsonb_typeof(new.extra_data) = 'object' then
      foreach k in array v_ins loop
        if k = 'inviteId' and coalesce(new.purchase_id, '') like 'INVH-%' then continue; end if;   -- 매장 어드민의 초대 홀드
        new.extra_data := new.extra_data - k;
      end loop;
    end if;
    return new;
  end if;
  v_old := coalesce(old.extra_data, '{}'::jsonb);
  v_new := coalesce(new.extra_data, '{}'::jsonb);
  if jsonb_typeof(v_new) <> 'object' then new.extra_data := old.extra_data; return new; end if;
  if jsonb_typeof(v_old) <> 'object' then v_old := '{}'::jsonb; end if;
  foreach k in array v_keys loop
    if (v_new->k) is distinct from (v_old->k) then
      if v_old ? k then v_new := jsonb_set(v_new, array[k], v_old->k); else v_new := v_new - k; end if;
    end if;
  end loop;
  new.extra_data := v_new;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_ticket_processed_cardq()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then return new; end if;
  if not (coalesce(old.extra_data->>'super_admin_processed_at', '') <> '' or coalesce(jsonb_typeof(old.extra_data->'deposit_return') = 'object', false)) then return new; end if;   -- coalesce: deposit_return 이 없으면 NULL 이 되어 처리 안 된 예약까지 막았다
  if jsonb_array_length(case when jsonb_typeof(new.extra_data->'card_refund_queue') = 'array' then new.extra_data->'card_refund_queue' else '[]'::jsonb end)
     > jsonb_array_length(case when jsonb_typeof(old.extra_data->'card_refund_queue') = 'array' then old.extra_data->'card_refund_queue' else '[]'::jsonb end) then
    raise exception 'REFUND_ALREADY_PROCESSED: 이미 TAAM 이 반환·환불을 처리한 예약입니다 — 인원만 바꾸고(돌려줄 금액 0) 더 줄 몫은 「예치금 부여」로 (구매 %)', old.purchase_id
      using errcode = '42501';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_tp_keep_hidden()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if pg_trigger_depth() > 1 and lower(coalesce(old.status, '')) = 'hidden' and lower(coalesce(new.status, '')) <> 'hidden' then
    new.status := old.status;
  elsif lower(coalesce(old.status, '')) <> 'hidden' and lower(coalesce(new.status, '')) = 'hidden'
        and exists (select 1 from public.ticket_package_rounds r where r.ticket_product_id = new.id::text) then
    new.status := old.status;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_ticket_sold_slots(p_ticket_id text)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select json_build_object(
    'total', coalesce(sum(party_size), 0)::int,
    's1', count(*) filter (where party_size = 1)::int,
    's2', count(*) filter (where party_size = 2)::int,
    's4', count(*) filter (where party_size = 4)::int
  )
    from public.tickets
   where ticket_product_id = p_ticket_id
     and coalesce(status, '') <> 'cancelled';
$function$
;
CREATE OR REPLACE FUNCTION public.taam_tp_status_recalc()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_occ int;
begin
  if coalesce(new.total_pax, 0) <= 0 then return new; end if;   -- 정원 없는 티켓은 매진 개념 없음

  select coalesce(sum(party_size), 0) into v_occ
    from public.tickets
   where ticket_product_id = new.id
     and coalesce(status, '') <> 'cancelled';

  if v_occ >= new.total_pax then
    -- 꽉 찼는데 판매중으로 쓰려 한다 → 매진으로 되돌린다 (재편집·연장·토글 모두)
    if coalesce(new.status, '') = 'active' then
      new.status := 'soldout';
      new.auto_soldout := true;
    end if;
  elsif tg_op = 'UPDATE'
        and coalesce(new.status, '') = 'soldout'
        and coalesce(new.auto_soldout, true)
        and coalesce(old.total_pax, 0) < new.total_pax then
    -- 자동 매진이었는데 정원을 늘려 자리가 생겼다 → 판매중
    new.status := 'active';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.touch_ticket_product_on_seat_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public._taam_pu_clash_other(p_uid uuid, p_tp text, p_date date, p_slot text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p_date is not null and exists (
    select 1
      from public.tickets k
      left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
     where k.user_id = p_uid
       and coalesce(k.status, '') not in ('cancelled','canceled','expired')
       and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
       and k.ticket_product_id::text is distinct from nullif(btrim(coalesce(p_tp, '')), '')
       and public._taam_purchase_exc_find(p_uid, k.ticket_product_id::text, 'time', 0) is null
       and coalesce(public._taam_pu_visit_date(k.reservation_date), public._taam_pu_visit_date(tp.date)) = p_date
       and ( p_slot is null
             or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) is null
             or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) = p_slot ))
$function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_invite_host()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or public.is_super_admin(v_uid) or pg_trigger_depth() > 1 then return NEW; end if;
  if TG_OP = 'INSERT' then
    if v_uid = NEW.host_user_id and v_uid is distinct from NEW.invitee_user_id then
      NEW.status := 'sent'; NEW.paid_at := null; NEW.cancelled_at := null;
    end if;
    return NEW;
  end if;
  if v_uid = OLD.host_user_id and v_uid is distinct from OLD.invitee_user_id then
    if coalesce(OLD.status, '') <> 'paid' and coalesce(NEW.status, '') = 'paid' then
      raise exception 'INVITE_HOST_PAID_FORBIDDEN: 결제는 받는 회원이 합니다' using errcode = '42501';
    end if;
    if coalesce(OLD.status, '') <> 'paid' then NEW.paid_at := OLD.paid_at; end if;
    if coalesce(OLD.status, '') = 'paid' then
      NEW.invitee_user_id := OLD.invitee_user_id; NEW.total_amount := OLD.total_amount; NEW.pax := OLD.pax;
      NEW.meal_fee := OLD.meal_fee; NEW.agency_fee := OLD.agency_fee; NEW.wine_min := OLD.wine_min;
      NEW.ticket_product_id := OLD.ticket_product_id; NEW.restaurant_id := OLD.restaurant_id; NEW.paid_at := OLD.paid_at;
      if NEW.status is distinct from OLD.status and coalesce(NEW.status, '') <> 'cancelled' then NEW.status := OLD.status; end if;
    end if;
  end if;
  return NEW;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_invite_rest()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tp_rest text;
begin
  if auth.uid() is null or public.is_super_admin(auth.uid()) then return NEW; end if;
  if pg_trigger_depth() > 1 then return NEW; end if;   -- 서버 함수(초대 확정 등)가 보낸 중첩 갱신은 그대로
  -- UPDATE 는 회차·매장이 바뀔 때만 본다(회원의 결제·취소 갱신이 옛 줄의 불일치로 막히지 않게)
  if TG_OP = 'UPDATE' and NEW.ticket_product_id::text is not distinct from OLD.ticket_product_id::text
     and NEW.restaurant_id::text is not distinct from OLD.restaurant_id::text then return NEW; end if;
  if coalesce(NEW.ticket_product_id::text, '') <> '' then
    select tp.rest_id::text into v_tp_rest from public.ticket_products tp where tp.id::text = NEW.ticket_product_id::text;
    if v_tp_rest is null then
      raise exception 'TICKET_NOT_FOUND: 연결 회차가 없습니다' using errcode = '42501';
    end if;
    if v_tp_rest <> coalesce(NEW.restaurant_id::text, '') then
      raise exception 'TICKET_REST_MISMATCH: 다른 매장의 회차입니다' using errcode = '42501';
    end if;
    if exists (select 1 from public.ticket_products tp where tp.id::text = NEW.ticket_product_id::text and lower(coalesce(tp.status, '')) = 'pending') then
      raise exception 'TICKET_NOT_APPROVED: 승인 대기 회차에는 초대를 보낼 수 없습니다' using errcode = '42501';
    end if;
  end if;
  if TG_OP = 'UPDATE' and NEW.restaurant_id::text is distinct from OLD.restaurant_id::text
     and not public.taam_rest_admin_ok(NEW.restaurant_id::text) then
    raise exception 'NOT_YOUR_RESTAURANT' using errcode = '42501';
  end if;
  return NEW;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_guard_invite_row()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_net bigint;
begin
  if v_uid is null then return new; end if;                                       -- 서버 · SQL Editor
  if coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if v_uid is distinct from old.invitee_user_id or v_uid = old.host_user_id then return new; end if;   -- 받는 회원 본인 세션만 (보낸 사람은 그대로)

  -- 받는 회원이 바꿀 수 있는 칸만 남기고 나머지는 되돌린다 (표에 칸이 늘어도 기본은 「못 바꿈」)
  new := jsonb_populate_record(new, to_jsonb(old) - array['status', 'paid_at', 'cancelled_at', 'invitee_seen']);

  if new.status is distinct from old.status then
    if lower(coalesce(old.status, '')) in ('cancelled', 'canceled', 'expired') then
      raise exception 'INVITE_CLOSED: 취소·만료된 초대는 되살릴 수 없습니다 (상태 %)', old.status using errcode = '42501';
    end if;
    if lower(coalesce(new.status, '')) = 'paid' then
      v_net := public._taam_invite_net_paid(old.id, old.invitee_user_id);
      if v_net < coalesce(old.total_amount, 0) then
        raise exception 'INVITE_NOT_PAID: 결제가 확인되지 않았습니다 (원장 결제 %원 · 초대 합계 %원)', v_net, coalesce(old.total_amount, 0)
          using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_ksk_seat_on_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res json;
begin
  if tg_op = 'DELETE' then
    -- 회차가 지워지면 그 좌석은 근거가 없다 (청구는 cascade 로 같이 지워진다)
    begin
      update public.tickets set status = 'cancelled',
             extra_data = coalesce(extra_data,'{}'::jsonb) || jsonb_build_object('cancelledBy','ksk_event_deleted','cancelledAt',now())
       where purchase_id like 'KSK-%' and extra_data->>'eventId' = old.id::text and coalesce(status,'') <> 'cancelled';
    exception when query_canceled or others then raise warning '[ksk_seat] event % 삭제 정리 실패: % %', old.id, sqlstate, sqlerrm; end;
    return old;
  end if;
  if coalesce(current_setting('taam.ksk_sync_skip', true), '') = '1' then return new; end if;
  if new.ticket_product_id is distinct from old.ticket_product_id
     or new.event_date is distinct from old.event_date or new.event_time is distinct from old.event_time then
    begin
      v_res := public._taam_ksk_seat_sync(new.id);
      if jsonb_array_length(coalesce((v_res->'short')::jsonb, '[]'::jsonb)) > 0 then
        raise warning '[ksk_seat] event % 좌석 못 잡음: %', new.id, v_res->'short';
      end if;
    exception when query_canceled or others then
      raise warning '[ksk_seat] event % 동기화 실패: % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public._taam_fee_caller_ok()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if;
  return session_user = 'postgres'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then
  return false;
end $function$
;
-- ── 저장소 판(라이브와 같은 것 확인됨) ──
create or replace function public._taam_mmdd_year(p_mmdd text, p_anchor date)
returns text
language plpgsql immutable
as $$
declare s text := btrim(coalesce(p_mmdd, '')); m int; d int; y int; base date;
begin
  if p_anchor is null then return null; end if;
  if s !~ '^\d{1,2}\.\d{1,2}$' then return null; end if;
  m := split_part(s, '.', 1)::int; d := split_part(s, '.', 2)::int;
  if m < 1 or m > 12 or d < 1 or d > 31 then return null; end if;
  base := p_anchor - 30;
  y := extract(year from base)::int;
  if d > extract(day from (make_date(y, m, 1) + interval '1 month - 1 day'))::int then return null; end if;
  if make_date(y, m, d) < base then y := y + 1; end if;
  return y::text || '.' || s;
end $$;
create or replace function public._taam_rest_name_l10n(p_ticket_id text, p_lang text)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(case lower(coalesce(p_lang,'ko'))
                    when 'en' then nullif(btrim(coalesce(to_jsonb(r)->>'name_en', '')), '')
                    when 'ja' then nullif(btrim(coalesce(to_jsonb(r)->>'name_jp', '')), '')
                    else null end,
                  tp.rest_name)
    from public.ticket_products tp
    left join public.restaurants r on r.id::text = tp.rest_id::text
   where tp.id::text = p_ticket_id
$$;
-- ── 대역(stub) ── 라이브는 pg_net 으로 send-push 를 부른다 · 원장 순결제 · 파트너 승인
create or replace function public._taam_member_push(p_uid uuid, p_title text, p_body text, p_url text default '/', p_tag text default null,
                                                    p_category text default 'system', p_i18n jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles p where p.id = p_uid and coalesce(to_jsonb(p)->'notif_prefs'->>'all', '') = 'false') then
    return jsonb_build_object('ok', false, 'reason', 'prefs_off');
  end if;
  insert into public._push_calls(uid, title, body, url, tag, category, i18n) values (p_uid, p_title, p_body, p_url, p_tag, p_category, p_i18n);
  return jsonb_build_object('ok', true);
end $$;
create or replace function public._taam_invite_net_paid(p uuid, u uuid) returns bigint language sql stable as $$ select 0::bigint $$;
-- 승인 트리거 대역 — 라이브(e4679a78…)는 파트너의 승인된 회차 수정을 되돌려 큐로 보낸다. 여기선 그 효과(날짜·시간 되돌림)만
create or replace function public.enforce_ticket_approval() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if auth.uid() is null or public.is_super_admin(auth.uid()) then return new; end if;
  if tg_op = 'UPDATE' and coalesce(old.status, '') <> 'pending' then new.date := old.date; new.time := old.time; end if;
  return new;
end $$;
