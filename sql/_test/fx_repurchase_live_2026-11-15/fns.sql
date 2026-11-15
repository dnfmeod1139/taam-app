-- taam_guard_purchase_unique from supabase/migrations/20261022_purchase_rule_exception.sql md5 ed27df3b771cb0aa866e3ce50227b0f4
create or replace function public.taam_guard_purchase_unique()
returns trigger
language plpgsql
security definer
set search_path = public
as $b$
declare
  v_prev     record;
  v_date     date;
  v_time     text;
  v_slot     text;
  v_tp       text;
  v_d2       date;
  v_t2       text;
  v_upd_live boolean := false;
  v_old_date date;
  v_old_slot text;
  v_old_t    text;
  v_old_tp   text;
  v_cnt      int;
  v_exc      uuid;
  v_dup_exc  uuid;      -- 🆕 2026-10-22 같은 회차 추가 구매를 허락한 예외 (있으면 ② 에서 같은 회차 행은 안 센다)
begin
  if new.user_id is null then return new; end if;
  if coalesce(new.status, '') in ('cancelled','canceled','expired') then return new; end if;
  if public._taam_ticket_is_ops(new.purchase_id, new.extra_data) then return new; end if;

  -- 회원 세션이 남의 user_id 로 넣는 행은 소유권 가드의 몫 (남의 예약이 거절 문구에 실리지 않게)
  if auth.uid() is not null
     and new.user_id is distinct from auth.uid()
     and not public._taam_uid_is_super() then
    return new;
  end if;

  v_tp := nullif(btrim(coalesce(new.ticket_product_id::text, '')), '');

  if tg_op = 'UPDATE' then
    v_upd_live := coalesce(old.status, '') not in ('cancelled','canceled','expired');
    if v_upd_live
       and old.user_id is not distinct from new.user_id
       and old.ticket_product_id::text is not distinct from new.ticket_product_id::text
       and old.reservation_date is not distinct from new.reservation_date
       and old.visit_time is not distinct from new.visit_time then
      return new;
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('tkuniq_' || new.user_id::text));

  -- ① 같은 회차 중복 — 슈퍼어드민이 허락한 예외(같은 회차 추가 · 건수 안)면 통과
  if v_tp is not null
     and not (v_upd_live and old.user_id is not distinct from new.user_id
              and old.ticket_product_id::text is not distinct from new.ticket_product_id::text) then
    select k.purchase_id, k.status
      into v_prev
      from public.tickets k
     where k.user_id = new.user_id
       and k.ticket_product_id::text = v_tp
       and k.id is distinct from new.id
       and coalesce(k.status, '') not in ('cancelled','canceled','expired')
       and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
     order by k.created_at
     limit 1;
    if found then
      select count(*) into v_cnt
        from public.tickets k
       where k.user_id = new.user_id
         and k.ticket_product_id::text = v_tp
         and k.id is distinct from new.id
         and coalesce(k.status, '') not in ('cancelled','canceled','expired')
         and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data);
      v_dup_exc := public._taam_purchase_exc_find(new.user_id, v_tp, 'dup', v_cnt);
      if v_dup_exc is null then
        raise exception 'DUPLICATE_PURCHASE: 이미 구매한 회차입니다 (기존 % · %)', v_prev.purchase_id, v_prev.status
          using errcode = '42501';
      end if;
      perform public._taam_purchase_exc_use(v_dup_exc, new.user_id, v_tp, new.purchase_id, 'dup');
      if new.extra_data is null or jsonb_typeof(new.extra_data) = 'object' then
        new.extra_data := coalesce(new.extra_data, '{}'::jsonb) || jsonb_build_object('ruleException', v_dup_exc::text);
      end if;
    end if;
  end if;

  -- ② 같은 날 같은 시간대
  v_date := public._taam_pu_visit_date(new.reservation_date);
  v_time := nullif(btrim(coalesce(new.visit_time, '')), '');
  if (v_date is null or v_time is null) and v_tp is not null then
    select public._taam_pu_visit_date(tp.date), nullif(btrim(coalesce(tp.time, '')), '')
      into v_d2, v_t2
      from public.ticket_products tp
     where tp.id::text = v_tp;
    v_date := coalesce(v_date, v_d2);
    v_time := coalesce(v_time, v_t2);
  end if;
  if v_date is null then return new; end if;
  v_slot := public.taam_time_slot(v_time);

  if v_upd_live and old.user_id is not distinct from new.user_id then
    v_old_tp   := nullif(btrim(coalesce(old.ticket_product_id::text, '')), '');
    v_old_date := public._taam_pu_visit_date(old.reservation_date);
    v_old_t    := nullif(btrim(coalesce(old.visit_time, '')), '');
    if (v_old_date is null or v_old_t is null) and v_old_tp is not null then
      select public._taam_pu_visit_date(tp.date), nullif(btrim(coalesce(tp.time, '')), '')
        into v_d2, v_t2
        from public.ticket_products tp
       where tp.id::text = v_old_tp;
      v_old_date := coalesce(v_old_date, v_d2);
      v_old_t    := coalesce(v_old_t, v_t2);
    end if;
    v_old_slot := public.taam_time_slot(v_old_t);
    if v_old_date = v_date and v_old_slot is not distinct from v_slot then
      return new;
    end if;
  end if;

  select k.purchase_id, k.restaurant_name, k.reservation_date, k.visit_time
    into v_prev
    from public.tickets k
    left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
   where k.user_id = new.user_id
     and k.id is distinct from new.id
     and coalesce(k.status, '') not in ('cancelled','canceled','expired')
     and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
     and (v_dup_exc is null or k.ticket_product_id::text is distinct from v_tp)
     and public._taam_purchase_exc_find(new.user_id, k.ticket_product_id::text, 'time', 0) is null   -- 그 회차가 시간대 예외면 이 회원에겐 겹침으로 안 센다(예외는 양쪽으로)
     and coalesce(public._taam_pu_visit_date(k.reservation_date), public._taam_pu_visit_date(tp.date)) = v_date
     and ( v_slot is null
           or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) is null
           or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) = v_slot )
   order by k.created_at
   limit 1;
  if found then
    v_exc := public._taam_purchase_exc_find(new.user_id, v_tp, 'time', 0);
    if v_exc is null then
      raise exception 'TIME_CONFLICT: 같은 날 같은 시간대에 이미 예약이 있습니다 (% · % %)',
        coalesce(v_prev.restaurant_name, '다른 매장'), coalesce(v_prev.reservation_date, v_date::text), coalesce(v_prev.visit_time, '')
        using errcode = '42501';
    end if;
    perform public._taam_purchase_exc_use(v_exc, new.user_id, v_tp, new.purchase_id, 'time');
    if new.extra_data is null or jsonb_typeof(new.extra_data) = 'object' then
      new.extra_data := coalesce(new.extra_data, '{}'::jsonb) || jsonb_build_object('ruleException', v_exc::text);
    end if;
  end if;

  return new;
end $b$;

-- taam_guard_ticket_payfacts_ins from supabase/migrations/20261022_card_refund_quote2.sql md5 c02d56be9e8714889f086f9654dfc79c
create or replace function public.taam_guard_ticket_payfacts_ins()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_keys text[] := array['card_refund_pending','server_cancelled_at','order_id','cardPaid','depositUsed','paidBy','card_currency','card_amount_fx',
                         'super_admin_processed_at','super_admin_processed_by','deposit_return'];
  k text; v_tp jsonb;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if v_uid = new.user_id then
    v_keys := v_keys || array['pax_changes', 'card_refund_queue'];
    -- 회원은 이미 있는 구매 id 로 행을 못 넣는다 — 취소된 구매 id 로 홀드를 다시 넣어 금액·인원·방문일을 바꿔 읽히게 하던 길(배포 전 2차 검증) · 앱은 언제나 새 id(PAYH-<회차>_<시각>)
    if coalesce(new.purchase_id, '') <> '' and exists (select 1 from public.tickets x where x.purchase_id = new.purchase_id) then
      raise exception 'PURCHASE_ID_TAKEN: 이미 있는 구매 번호입니다' using errcode = '23505';
    end if;
  end if;
  if new.extra_data is not null and jsonb_typeof(new.extra_data) = 'object' then
    foreach k in array v_keys loop new.extra_data := new.extra_data - k; end loop;
  end if;
  -- 회원 홀드의 방문일·시간은 회차 값 — 환불 규정(D-31)·견적이 이 칸을 읽는다
  if coalesce(new.purchase_id, '') like 'PAYH-%' and coalesce(new.ticket_product_id::text, '') <> '' then
    select to_jsonb(tp) into v_tp from public.ticket_products tp where tp.id::text = new.ticket_product_id::text;
    if v_tp is not null and coalesce(v_tp->>'date', '') ~ '^\d{4}[.\-/]\d{1,2}[.\-/]\d{1,2}' then
      new.reservation_date := v_tp->>'date';
      if coalesce(v_tp->>'time', '') <> '' then new.visit_time := v_tp->>'time'; end if;
    end if;
  end if;
  return new;
end $$;

-- taam_guard_ticket_rest_pin from supabase/migrations/20261113_ticket_hold_rest_pin.sql md5 98e2d0f0a70f3b3bcdcda3341ac67675
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

-- taam_guard_ticket_row from sql/audit_hardening_2026-09-13.sql md5 c34e544b9c52f6732de9d46003cd763b
create or replace function public.taam_guard_ticket_row()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 서버(service_role · postgres · SECURITY DEFINER RPC · 좌석 트리거)는 막지 않는다
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;

  -- ── 여기부터 회원·매장어드민 세션 ──────────────────────────────
  if new.user_id     is distinct from old.user_id
     or new.purchase_id is distinct from old.purchase_id then
    raise exception '예약의 소유자·구매ID 는 바꿀 수 없습니다' using errcode = '42501';
  end if;

  if coalesce(new.party_size, 0) is distinct from coalesce(old.party_size, 0) then
    raise exception '인원은 직접 바꿀 수 없습니다 (taam_change_party_size 를 쓰세요)'
      using errcode = '42501';
  end if;

  if new.restaurant_id is distinct from old.restaurant_id
     or new.reservation_date is distinct from old.reservation_date then
    raise exception '예약의 매장·날짜는 직접 바꿀 수 없습니다' using errcode = '42501';
  end if;

  if old.status = 'cancelled' and new.status is distinct from old.status then
    raise exception '취소된 예약은 되살릴 수 없습니다' using errcode = '42501';
  end if;

  -- 🔒 2026-09-13: 상태 전환은 「취소」만. 확정(hold→active)은 서버가 한다.
  --   종전에는 hold→active 를 회원에게 열어 두고 그 순간 price 변경도 허용했다 —
  --   price=0 으로 결제 없이 좌석을 확정할 수 있었다.
  if new.status is distinct from old.status and new.status <> 'cancelled' then
    raise exception '예약 상태는 취소만 직접 할 수 있습니다 (확정은 서버가 합니다)'
      using errcode = '42501';
  end if;

  -- 🔒 금액은 회원 세션에서 절대 바뀌지 않는다
  if coalesce(new.price, 0) is distinct from coalesce(old.price, 0) then
    raise exception '금액은 서버만 정합니다' using errcode = '42501';
  end if;

  return new;
end;
$$;

-- taam_guard_ticket_payfacts from supabase/migrations/20261022_card_refund_quote2.sql md5 b43c845c1f011217df199853564ddcd7
create or replace function public.taam_guard_ticket_payfacts()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_keys text[] := array['card_refund_pending','server_cancelled_at','order_id','cardPaid','depositUsed','paidBy','card_currency','card_amount_fx',
                         'super_admin_processed_at','super_admin_processed_by','deposit_return'];
  v_cx   boolean;
  v_old  jsonb; v_new jsonb; k text; v_member_owner boolean := false;
begin
  v_cx := lower(coalesce(new.status, '')) in ('cancelled', 'canceled') and lower(coalesce(old.status, '')) not in ('cancelled', 'canceled');
  if v_cx then
    new.extra_data := coalesce(new.extra_data, '{}'::jsonb) || jsonb_build_object('server_cancelled_at', now());
  end if;
  v_old := coalesce(old.extra_data, '{}'::jsonb); v_new := coalesce(new.extra_data, '{}'::jsonb);

  if v_uid is null then return new; end if;
  if coalesce(public.is_super_admin(v_uid), false) then
    if jsonb_typeof(v_new->'card_refund_pending') = 'object'
       and (v_old->'card_refund_pending' is null
            or (v_new->'card_refund_pending'->>'amount') is distinct from (v_old->'card_refund_pending'->>'amount')) then
      new.extra_data := jsonb_set(v_new, '{card_refund_pending,set_by_role}', '"superadmin"');
    end if;
    return new;
  end if;

  -- 소유자가 회원(어드민 아님)이면 더 막는다 — 인원 변경 기록 · 운영 행 표시(이것을 켜면 중복·시간대 가드가 그 행을 안 센다) · 회차·방문 시각
  --   (배포 전 리뷰: 회원이 자기 INV-/LINK- 행에 inviteHold 를 켜거나 memberUid 를 지우거나 회차·시각을 옮겨 같은 회차를 또 사던 길 · 앱의 회원 흐름은 이 칸들을 안 쓴다)
  --   매장 어드민의 인원 변경 함수 · 보낸 사람의 초대 시간 변경(INVH- 는 보낸 어드민 소유) · 초대 확정(소유자가 바뀌는 갱신)은 그대로.
  if v_uid = old.user_id and v_uid = new.user_id then
    select coalesce(role, 'user') not in ('admin', 'superadmin', 'super_admin') into v_member_owner from public.profiles where id = v_uid;
    v_member_owner := coalesce(v_member_owner, true);
  end if;
  if v_member_owner then
    v_keys := v_keys || array['pax_changes', 'card_refund_queue', 'inviteHold', 'manualEntry', 'kashikiri', 'linkInvite', 'memberUid'];
    if new.ticket_product_id::text is distinct from old.ticket_product_id::text then new.ticket_product_id := old.ticket_product_id; end if;
    if new.visit_time is distinct from old.visit_time then new.visit_time := old.visit_time; end if;
  end if;
  foreach k in array v_keys loop
    if k = 'server_cancelled_at' and v_cx then continue; end if;
    if k = 'card_refund_pending' and v_cx and v_old->'card_refund_pending' is null then
      if jsonb_typeof(v_new->'card_refund_pending') = 'object' then
        v_new := jsonb_set(v_new, '{card_refund_pending,set_by_role}', '"member"');
      end if;
      continue;
    end if;
    if (v_new->k) is distinct from (v_old->k) then
      if v_old ? k then v_new := jsonb_set(v_new, array[k], v_old->k); else v_new := v_new - k; end if;
    end if;
  end loop;
  new.extra_data := v_new;
  return new;
end $$;

-- _taam_ticket_is_ops from supabase/migrations/20261018_pay_link.sql md5 0833f46be29199689edb1d494ba47894
create or replace function public._taam_ticket_is_ops(p_purchase_id text, p_extra jsonb)
returns boolean
language sql immutable
as $$
  select case when coalesce(p_purchase_id, '') ~ '^PAY' then false
         else (coalesce(p_purchase_id, '') ~ '^(KSK|MAN|INVH)-'
               or (coalesce(p_purchase_id, '') ~ '^LINK-' and coalesce(nullif(p_extra ->> 'memberUid', ''), '') = '')
               or coalesce(p_extra ->> 'manualEntry', '') in ('true','1')
               or coalesce(p_extra ->> 'inviteHold',  '') in ('true','1')
               or coalesce(p_extra ->> 'kashikiri',   '') in ('true','1')
               or (coalesce(p_extra ->> 'linkInvite',  '') in ('true','1') and coalesce(nullif(p_extra ->> 'memberUid', ''), '') = ''))
         end
$$;

-- _taam_pu_visit_date from supabase/migrations/20261014_purchase_uniqueness.sql md5 b200c9f08dce087dcb74cf0632859a25
create or replace function public._taam_pu_visit_date(p_text text)
returns date
language plpgsql immutable
as $$
declare m text[]; d date;
begin
  if p_text is null then return null; end if;
  m := regexp_match(btrim(p_text), '^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})');
  if m is null then return null; end if;
  d := make_date(m[1]::int, m[2]::int, m[3]::int);
  if d < date '2020-01-01' or d > date '2100-01-01' then return null; end if;
  return d;
exception when others then
  return null;
end $$;

-- taam_time_slot from supabase/migrations/20261014_purchase_uniqueness.sql md5 d7ecede66431a3e408eae8e636bd7bc7
create or replace function public.taam_time_slot(p_time text)
returns text
language plpgsql immutable
as $$
declare m text[]; h int;
begin
  if p_time is null or btrim(p_time) = '' then return null; end if;
  m := regexp_match(p_time, '(\d{1,2}):(\d{2})');
  if m is null then m := regexp_match(p_time, '(\d{1,2})'); end if;
  if m is null then return null; end if;
  h := m[1]::int;
  if p_time ~* '(pm|오후|저녁|밤)' and h < 12 then h := h + 12; end if;
  if p_time ~* '(am|오전)' and h = 12 then h := 0; end if;
  if h < 0 or h > 23 then return null; end if;
  return case when h < 16 then 'lunch' else 'dinner' end;
end $$;

-- _taam_purchase_exc_find from supabase/migrations/20261022_purchase_rule_exception.sql md5 2cc9e4a71c8c9ff6b5c3dda0f9de0217
create or replace function public._taam_purchase_exc_find(p_uid uuid, p_tp text, p_kind text, p_others int default 0)
returns uuid
language sql stable security definer set search_path = public
as $$
  select e.id
    from public.purchase_rule_exceptions e
   where p_uid is not null
     and nullif(btrim(coalesce(p_tp, '')), '') is not null
     and e.user_id = p_uid
     and e.ticket_product_id = btrim(p_tp)
     and e.revoked_at is null
     and e.expires_at > now()
     and case p_kind when 'dup'  then e.allow_dup and coalesce(p_others, 0) <= e.extra
                     when 'time' then e.allow_time
                     else false end
   order by e.created_at desc
   limit 1
$$;

-- _taam_purchase_exc_use from supabase/migrations/20261022_purchase_rule_exception.sql md5 af4a0518630cac63648565c98e661ee2
create or replace function public._taam_purchase_exc_use(p_exc uuid, p_uid uuid, p_tp text, p_pid text, p_kind text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  insert into public.purchase_rule_exception_uses (exception_id, user_id, ticket_product_id, purchase_id, kind)
  values (p_exc, p_uid, p_tp, p_pid, p_kind)
  on conflict on constraint preu_once do nothing;
exception when others then
  raise warning '[purchase_exc] 사용 기록 실패 %: %', p_exc, sqlerrm;
end $$;

-- taam_guard_ticket_insert from supabase/migrations/20261029_partner_grants.sql md5 9ef7a943d0c9b5b74930c08d579f06c3
create or replace function public.taam_guard_ticket_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_adm boolean := false; v_chk text;
begin
  -- TAAM_GUARD_TICKET_INSERT_V2 (2026-10-29): 매장 어드민 판정 = 승인 권한(taam_rest_admin_ok) · profiles.role 글자는 안 본다
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;

  if new.user_id is distinct from auth.uid() then
    raise exception '남의 이름으로 예약을 넣을 수 없습니다' using errcode = '42501';
  end if;

  -- 이 행의 매장에 승인된 어드민인가 · 연결 회차가 있으면 그 회차가 **있고** 같은 매장이어야 한다(다른 매장 회차·숨은 회차에 좌석을 잡던 길)
  v_adm := public.taam_rest_admin_ok(new.restaurant_id::text);
  if v_adm and coalesce(new.ticket_product_id::text, '') <> '' then
    v_chk := public._taam_tp_seat_check(new.ticket_product_id::text, new.restaurant_id::text);
    if v_chk = 'bad' then
      raise exception 'TICKET_REST_MISMATCH: 연결 회차가 없거나 다른 매장의 회차입니다' using errcode = '42501';
    end if;
  end if;

  if new.status = 'hold' then
    -- 회원의 홀드는 PAYH- 뿐 · 승인된 매장 어드민은 자기 매장 회차의 초대 홀드(INVH-)도
    if coalesce(new.purchase_id, '') like 'PAYH-%' then return new; end if;
    if v_adm and coalesce(new.purchase_id, '') like 'INVH-%' then return new; end if;
    raise exception 'HOLD_PREFIX: 회원 좌석 홀드는 PAYH- 로만 만들 수 있습니다' using errcode = '42501';
  end if;

  if new.status = 'manual' and v_adm and coalesce(new.purchase_id, '') like 'MAN-%' then
    return new;                               -- 승인된 매장 어드민의 수동 연동 행(MAN-)
  end if;

  raise exception '예약은 서버가 확정합니다 — 직접 넣을 수 없는 상태: %', coalesce(new.status, '(없음)')
    using errcode = '42501';
end;
$$;

-- taam_guard_repurchase from sql/repurchase_release_7days.sql md5 538def2887ae9d9395b88b87512d11d6
create or replace function public.taam_guard_repurchase()
returns trigger
language plpgsql
set search_path = public
as $rep$
declare
  v_days   int;
  v_prev   record;
  v_exempt boolean := false;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if new.user_id is null or new.restaurant_id is null
     or new.reservation_date is null then
    return new;
  end if;

  if new.purchase_id like 'MAN-%'
     or new.purchase_id like 'INVH-%'
     or new.purchase_id like 'INV-%'
     or coalesce(new.extra_data ->> 'manualEntry', '') in ('true','1')
     or coalesce(new.extra_data ->> 'inviteHold',  '') in ('true','1') then
    return new;
  end if;

  if coalesce(new.status, '') in ('cancelled','canceled') then
    return new;
  end if;

  if public._taam_uid_is_super() then
    return new;
  end if;
  if exists (select 1 from public.profiles p
              where p.id = auth.uid() and p.role = 'admin') then
    return new;
  end if;

  select coalesce(p.single_device_exempt, false) into v_exempt
    from public.profiles p where p.id = new.user_id;
  if coalesce(v_exempt, false) then
    return new;
  end if;

  -- 🆕 2026.08-31: 판매 오픈 7일이 지난 티켓은 제한을 풀어 준다.
  --   ⚠ 이 검사를 「기존 예약 찾기」보다 먼저 한다. 어차피 통과시킬 건데
  --     굳이 훑을 이유가 없고, 순서가 앞에 있어야 읽는 사람이 바로 안다.
  if new.ticket_product_id is not null
     and public.taam_repurchase_released(new.ticket_product_id::text) then
    return new;
  end if;

  select r.repurchase_day into v_days
    from public.restaurants r
   where r.id::text = new.restaurant_id::text;
  if coalesce(v_days, 0) = 0 then
    return new;
  end if;

  select k.purchase_id, k.reservation_date
    into v_prev
    from public.tickets k
   where k.user_id = new.user_id
     and k.restaurant_id::text = new.restaurant_id::text
     and k.purchase_id is distinct from new.purchase_id
     and k.reservation_date is not null
     and coalesce(k.status,'') not in ('cancelled','canceled')
     and k.purchase_id not like 'MAN-%'
     and k.purchase_id not like 'INVH-%'
     and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
     and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
     and abs(k.reservation_date::date - new.reservation_date::date) > 0
     and abs(k.reservation_date::date - new.reservation_date::date) < v_days
   order by abs(k.reservation_date::date - new.reservation_date::date)
   limit 1;

  if found then
    raise exception
      'REPURCHASE_BLOCKED: 이 매장은 % 일 재구매 제한이 있습니다 (기존 방문일 %)',
      v_days, v_prev.reservation_date
      using errcode = '42501';
  end if;

  return new;
end;
$rep$;

-- taam_repurchase_released from supabase/migrations/20261014_repurchase_manual_release.sql md5 af2d11f6ea98c3477ad05f38f8145c49
create or replace function public.taam_repurchase_released(p_ticket_id text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select tp.repurchase_open from public.ticket_products tp where tp.id::text = p_ticket_id), false)
$$;
