-- 라이브 본문 그대로 (2026-11-13 pg_get_functiondef) — 저장소 sql/refund_policy_server.sql 과 md5 가 다르다(라이브가 더 새 판).
--   테스트 픽스처가 올린다 · md5(prosrc): taam_apply_deposit_delta 36230be09e2560b57c7dd871a9acbe48 · taam_refund_cap cc340b5fa74ef009040cef829364a44b
--   ⚠ 라이브에 돌리지 말 것 — 테스트 전용 사본이다.
CREATE OR REPLACE FUNCTION public._taam_refund_visit_date(p_raw text)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare s text; d date;
begin
  s := btrim(coalesce(p_raw, ''));
  if s = '' then return null; end if;
  s := btrim(regexp_replace(s, '[^0-9]+', '-', 'g'), '-');
  begin d := to_date(s, 'YYYY-MM-DD'); exception when others then return null; end;
  if d < date '2020-01-01' or d > date '2100-01-01' then return null; end if;
  return d;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_refund_cap(p_user_id uuid, p_purchase_id text)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c_min_days constant int := 31;
  v_paid   bigint := 0;
  v_paid_at timestamptz;
  v_back   bigint := 0;
  v_base   bigint;
  v_total  bigint;
  v_tk     record;
  v_agency bigint := 0;
  v_vd     date;
  v_days   int;
begin
  select coalesce(-sum(amount), 0), min(created_at) into v_paid, v_paid_at
    from public.deposit_transactions
   where user_id = p_user_id and change_type = 'ticket_purchase'
     and metadata->>'purchase_id' = p_purchase_id and amount < 0;
  select coalesce(sum(amount), 0) into v_back
    from public.deposit_transactions
   where user_id = p_user_id and change_type = 'ticket_refund'
     and metadata->>'purchase_id' = p_purchase_id and amount > 0;
  v_base := greatest(0, v_paid - v_back);

  if to_regclass('public.tickets') is null then return v_base; end if;
  select t.created_at, t.party_size, t.reservation_date, t.price, t.ticket_product_id::text as tpid
    into v_tk
    from public.tickets t
   where t.purchase_id = p_purchase_id and t.user_id = p_user_id
   order by t.created_at desc nulls last
   limit 1;
  if not found then return v_base; end if;

  v_paid_at := coalesce(v_paid_at, v_tk.created_at);
  if v_paid_at is not null and now() - v_paid_at <= interval '30 minutes' then
    return v_base;
  end if;

  begin
    select coalesce(tp.agency_fee, 0)::bigint * greatest(coalesce(v_tk.party_size, 1), 1)
      into v_agency
      from public.ticket_products tp
     where tp.id::text = v_tk.tpid;
  exception when others then v_agency := 0; end;
  v_agency := coalesce(v_agency, 0);

  v_total := coalesce(nullif(v_tk.price, 0)::bigint, v_paid);
  v_vd := public._taam_refund_visit_date(v_tk.reservation_date);
  if v_vd is null then
    return greatest(0, least(v_base, v_total - v_agency - v_back));
  end if;
  v_days := v_vd - (now() at time zone 'Asia/Seoul')::date;
  if v_days >= c_min_days then
    return greatest(0, least(v_base, v_total - v_agency - v_back));
  end if;
  return 0;
end $function$
;
CREATE OR REPLACE FUNCTION public.taam_apply_deposit_delta(p_user_id uuid, p_mem_delta bigint, p_gen_delta bigint, p_entries jsonb DEFAULT NULL::jsonb)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_jwt   text := '';
  v_super boolean := false;
  v_mem   bigint;
  v_gen   bigint;
  v_nmem  bigint;
  v_ngen  bigint;
  v_sum   bigint := 0;
  v_run   bigint;
  v_n     int := 0;
  e       jsonb;
  v_type  text;
  v_amt   bigint;
  v_pid_t text;
  v_pid   uuid;
  v_extra jsonb;
  v_paid  bigint;
  v_back  bigint;
  v_cap   bigint;
  r_ref   record;
begin
  if v_uid is null then
    begin
      v_jwt := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '');
    exception when others then
      v_jwt := '';
    end;
    if v_jwt = 'service_role' or session_user = 'postgres' then
      v_super := true;
    else
      raise exception '로그인이 필요합니다' using errcode = '42501';
    end if;
  else
    v_super := exists (select 1 from public.profiles p
                        where p.id = v_uid and p.role in ('super_admin','superadmin'));
  end if;

  if not v_super and p_user_id <> v_uid then
    raise exception '다른 회원의 예치금은 바꿀 수 없습니다' using errcode = '42501';
  end if;

  if p_entries is not null then
    if jsonb_typeof(p_entries) <> 'array' then
      raise exception 'LEDGER_BAD_SHAPE: entries 는 배열이어야 합니다' using errcode = '22023';
    end if;

    for e in select * from jsonb_array_elements(p_entries) loop
      v_type := lower(coalesce(e->>'deposit_type', ''));
      if v_type not in ('membership', 'general') then
        raise exception 'LEDGER_BAD_TYPE: deposit_type 은 membership/general 만 (받은 값 %)',
          coalesce(e->>'deposit_type','(없음)') using errcode = '22023';
      end if;
      if coalesce(e->>'change_type', '') = '' then
        raise exception 'LEDGER_NO_CHANGE_TYPE: change_type 이 비어 있습니다' using errcode = '22023';
      end if;
      begin
        v_amt := (e->>'amount')::bigint;
      exception when others then
        raise exception 'LEDGER_BAD_AMOUNT: amount 가 숫자가 아닙니다 (받은 값 %)',
          coalesce(e->>'amount','(없음)') using errcode = '22023';
      end;
      v_sum := v_sum + v_amt;
      v_n := v_n + 1;
    end loop;

    if v_sum <> coalesce(p_mem_delta,0) + coalesce(p_gen_delta,0) then
      raise exception 'LEDGER_MISMATCH: 원장 합계(%)가 잔액 변동(%)과 다릅니다',
        v_sum, coalesce(p_mem_delta,0) + coalesce(p_gen_delta,0)
        using errcode = '22023';
    end if;
  end if;

  if not v_super then
    if p_entries is null and coalesce(p_mem_delta,0) + coalesce(p_gen_delta,0) > 0 then
      raise exception 'LEDGER_CREDIT_DENIED: 잔액을 늘리려면 환불 원장이 필요합니다' using errcode = '42501';
    end if;
    if p_entries is null and (coalesce(p_mem_delta,0) > 0 or coalesce(p_gen_delta,0) > 0) then
      raise exception 'LEDGER_CREDIT_DENIED: 주머니를 늘리려면 환불 원장이 필요합니다' using errcode = '42501';
    end if;
    if p_entries is not null then
      for e in select * from jsonb_array_elements(p_entries) loop
        v_amt := (e->>'amount')::bigint;
        if v_amt > 0 then
          if coalesce(e->>'change_type','') <> 'ticket_refund'
             or coalesce(nullif(btrim(e->'metadata'->>'purchase_id'), ''), '') = '' then
            raise exception 'LEDGER_CREDIT_DENIED: 회원의 양수 원장은 환불(ticket_refund + purchase_id)만 됩니다 (받은 값 %)',
              coalesce(e->>'change_type','(없음)') using errcode = '42501';
          end if;
        end if;
      end loop;
      for r_ref in
        select x->'metadata'->>'purchase_id' as pur, sum((x->>'amount')::bigint) as amt
          from jsonb_array_elements(p_entries) x
         where (x->>'amount')::bigint > 0
         group by 1
      loop
        select coalesce(-sum(amount), 0) into v_paid
          from public.deposit_transactions
         where user_id = p_user_id and change_type = 'ticket_purchase'
           and metadata->>'purchase_id' = r_ref.pur and amount < 0;
        select coalesce(sum(amount), 0) into v_back
          from public.deposit_transactions
         where user_id = p_user_id and change_type = 'ticket_refund'
           and metadata->>'purchase_id' = r_ref.pur and amount > 0;
        if r_ref.amt > v_paid - v_back then
          raise exception 'LEDGER_REFUND_EXCEEDS: 구매 % 로 낸 돈 %, 이미 환불 %, 이번 요청 % — 한도를 넘습니다',
            r_ref.pur, v_paid, v_back, r_ref.amt using errcode = '42501';
        end if;
        -- 🆕 2026-09-14 환불 정책도 서버가 센다 — 앱이 계산한 금액을 믿지 않는다.
        v_cap := public.taam_refund_cap(p_user_id, r_ref.pur);
        if r_ref.amt > v_cap then
          raise exception 'LEDGER_REFUND_POLICY: 구매 % 환불 한도 % (결제 30분 내 전액 · D-31 이상 대행비 제외 · 그 뒤 불가), 이번 요청 %',
            r_ref.pur, v_cap, r_ref.amt using errcode = '42501';
        end if;
      end loop;
    end if;
  end if;

  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0)
    into v_mem, v_gen
    from public.profiles
   where id = p_user_id
     for update;

  if not found then
    raise exception '회원을 찾을 수 없습니다' using errcode = 'P0002';
  end if;

  if p_entries is not null and v_n > 0
     and (v_mem + coalesce(p_mem_delta,0) < 0 or v_gen + coalesce(p_gen_delta,0) < 0) then
    raise exception 'LEDGER_INSUFFICIENT: 잔액(멤버십 %, 일반 %)이 요청(%, %)에 못 미칩니다',
      v_mem, v_gen, coalesce(p_mem_delta,0), coalesce(p_gen_delta,0) using errcode = '42501';
  end if;

  v_nmem := greatest(0, v_mem + coalesce(p_mem_delta, 0));
  v_ngen := greatest(0, v_gen + coalesce(p_gen_delta, 0));

  update public.profiles
     set membership_deposit_balance = v_nmem,
         general_deposit_balance    = v_ngen
   where id = p_user_id;

  if p_entries is not null and v_n > 0 then
    v_run := v_mem + v_gen;
    for e in select * from jsonb_array_elements(p_entries) loop
      v_amt := (e->>'amount')::bigint;
      v_run := v_run + v_amt;

      v_pid_t := nullif(btrim(coalesce(e->>'payment_id', '')), '');
      if v_pid_t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_pid   := v_pid_t::uuid;
        v_extra := '{}'::jsonb;
      else
        v_pid   := null;
        v_extra := case when v_pid_t is null then '{}'::jsonb
                        else jsonb_build_object('payment_ref', v_pid_t) end;
      end if;

      insert into public.deposit_transactions
        (user_id, deposit_type, change_type, amount, balance_after,
         description, payment_id, metadata)
      values (
        p_user_id,
        lower(e->>'deposit_type'),
        e->>'change_type',
        v_amt,
        v_run,
        nullif(e->>'description', ''),
        v_pid,
        coalesce(e->'metadata', '{}'::jsonb)
          || v_extra
          || jsonb_build_object('server_written', true)
          || case when v_uid is null then jsonb_build_object('server_caller', coalesce(nullif(v_jwt,''), session_user::text))
                  else '{}'::jsonb end
      );
    end loop;
  end if;

  return json_build_object(
    'mem',      v_nmem,
    'gen',      v_ngen,
    'total',    v_nmem + v_ngen,
    'prev_mem', v_mem,
    'prev_gen', v_gen,
    'entries',  v_n
  );
end;
$function$
;
