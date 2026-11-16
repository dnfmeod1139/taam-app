-- 라이브 원장 가드 본문(2026-11-16 읽기 전용으로 가져옴 · 적대 리뷰 검증자) — 카드 정리 테스트(t_card_order_settle.sh) 픽스처.
--   taam_guard_ledger_invite_open 은 초대 갈래를 줄였다(카드 테스트와 무관 · 실제 본문은 20261113_invite_card_pay.sql).
CREATE OR REPLACE FUNCTION public.is_super_admin(uid uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ select coalesce((select role in ('super_admin', 'superadmin') from public.profiles where id = uid), false); $function$;
CREATE OR REPLACE FUNCTION public.taam_guard_ledger_change_type() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if auth.uid() is not null and not coalesce(public.is_super_admin(auth.uid()), false)
     and lower(coalesce(new.change_type, '')) like 'admin\_%' escape '\' then
    raise exception 'LEDGER_TYPE_FORBIDDEN' using errcode = '42501';
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.taam_guard_ledger_refund_active()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_pid text;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(new.amount, 0) <= 0 then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is not null and exists (select 1 from public.tickets t
              where t.purchase_id = v_pid and t.user_id = new.user_id
                and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'failed', 'refunded')) then
    raise exception 'REFUND_TICKET_ACTIVE (구매 %)', v_pid using errcode = '42501';
  end if;
  if exists (
       select 1
         from public.deposit_transactions d
         join public.tickets t on t.extra_data->>'inviteId' = case when nullif(d.metadata->>'invite_id', '') is not null then d.metadata->>'invite_id' end
        where d.user_id = new.user_id and d.change_type = 'ticket_purchase' and d.amount < 0
          and ((v_pid is not null and d.metadata->>'purchase_id' = v_pid)
               or (nullif(new.metadata->>'invite_id', '') is not null and d.metadata->>'invite_id' = new.metadata->>'invite_id'))
          and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'failed', 'refunded'))
     or (nullif(new.metadata->>'invite_id', '') is not null and exists (
          select 1 from public.tickets t where t.extra_data->>'inviteId' = new.metadata->>'invite_id'
             and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'failed', 'refunded'))) then
    raise exception 'REFUND_TICKET_ACTIVE invite' using errcode = '42501';
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.taam_guard_ledger_refund_nonpos() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if auth.uid() is not null and not coalesce(public.is_super_admin(auth.uid()), false)
     and coalesce(new.change_type, '') = 'ticket_refund' and coalesce(new.amount, 0) <= 0 then
    raise exception 'LEDGER_REFUND_NONPOSITIVE' using errcode = '42501';
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.taam_guard_ledger_refund_paid()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_pid text; v_paid bigint; v_back bigint;
        v_kept bigint := 0; v_tk record; v_ag bigint := 0; pc jsonb; v_from int; v_to int; v_pb numeric; v_rf numeric; v_at timestamptz;
        v_paid_at timestamptz; v_base timestamptz;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(new.amount, 0) <= 0 then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is null then return new; end if;
  select coalesce(-sum(d.amount), 0), min(d.created_at) into v_paid, v_paid_at from public.deposit_transactions d
   where d.user_id = new.user_id and d.change_type = 'ticket_purchase' and d.amount < 0 and d.metadata->>'purchase_id' = v_pid;
  select coalesce(sum(d.amount), 0) into v_back from public.deposit_transactions d
   where d.user_id = new.user_id and d.change_type in ('ticket_refund', 'ticket_pax_change') and d.amount > 0 and d.metadata->>'purchase_id' = v_pid;
  begin
    select tk.created_at, tk.extra_data, tk.ticket_product_id, tk.party_size into v_tk
      from public.tickets tk where tk.user_id = new.user_id and tk.purchase_id = v_pid limit 1;
    if found and jsonb_typeof(v_tk.extra_data -> 'pax_changes') = 'array'
       and not ((coalesce(v_tk.extra_data->>'cardPaid', '') ~ '^\d{1,12}$' and (v_tk.extra_data->>'cardPaid')::bigint > 0)
                or coalesce(v_tk.extra_data->>'paidBy', '') in ('card+deposit', 'card')) then
      v_base := coalesce(v_paid_at, v_tk.created_at);
      select coalesce(tp.agency_fee, 0) into v_ag from public.ticket_products tp where tp.id::text = v_tk.ticket_product_id::text;
      v_ag := greatest(coalesce(v_ag, 0), case when coalesce(v_tk.extra_data->>'agencyFee', '') ~ '^\d{1,9}$' then (v_tk.extra_data->>'agencyFee')::bigint else 0 end);
      for pc in select value from jsonb_array_elements(v_tk.extra_data -> 'pax_changes') loop
        if coalesce(pc->>'from', '') !~ '^\d{1,4}$' or coalesce(pc->>'to', '') !~ '^\d{1,4}$' then continue; end if;
        v_from := (pc->>'from')::int; v_to := (pc->>'to')::int;
        if v_from <= v_to then continue; end if;
        v_at := null;
        begin v_at := (pc->>'at')::timestamptz; exception when others then v_at := null; end;
        if v_at is not null and v_base is not null and v_at <= v_base + interval '30 minutes' then continue; end if;
        v_pb := case when coalesce(pc->>'price_before', '') ~ '^\d{1,12}$' then (pc->>'price_before')::numeric else null end;
        v_rf := case when coalesce(pc->>'refund', '') ~ '^\d{1,12}$' then (pc->>'refund')::numeric else 0 end;
        v_kept := v_kept + case when v_pb is null then (v_from - v_to) * v_ag
                                else least((v_from - v_to) * v_ag, greatest(0, (v_from - v_to) * floor(v_pb / v_from) - v_rf))::bigint end;
      end loop;
      if v_kept > 0 and (v_base is null or now() > v_base + interval '30 minutes') then
        v_kept := v_kept + v_ag * greatest(coalesce(v_tk.party_size, 1), 1);
      end if;
    end if;
  exception when others then v_kept := 0;
  end;
  if v_back + new.amount > v_paid - v_kept then
    raise exception 'LEDGER_REFUND_EXCEEDS_PAID: 구매 % 예치금 % · 이미 % · 남긴 % · 이번 %', v_pid, v_paid, v_back, v_kept, new.amount using errcode = '42501';
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.taam_guard_ledger_refund_processed()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_pid text;
begin
  if v_uid is null then return new; end if;
  if coalesce(new.amount, 0) <= 0 then return new; end if;
  if coalesce(new.change_type, '') = 'ticket_pax_change' then null;
  elsif coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is null then return new; end if;
  if exists (select 1 from public.tickets t where t.purchase_id = v_pid and t.user_id = new.user_id
                and (coalesce(t.extra_data->>'super_admin_processed_at', '') <> '' or jsonb_typeof(t.extra_data->'deposit_return') = 'object')) then
    raise exception 'REFUND_ALREADY_PROCESSED' using errcode = '42501';
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.taam_guard_ledger_invite_open() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
declare v_uid uuid := auth.uid(); v_iid text;
begin
  if v_uid is null then return new; end if;
  if new.change_type is distinct from 'ticket_purchase' or coalesce(new.amount, 0) >= 0 then return new; end if;
  v_iid := nullif(new.metadata->>'invite_id', '');
  if v_iid is null or v_iid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return new; end if;
  raise exception 'invite path not modeled';
end $function$;
create trigger trg_taam_guard_ledger_change_type before insert on public.deposit_transactions for each row execute function taam_guard_ledger_change_type();
create trigger trg_taam_guard_ledger_invite_open before insert on public.deposit_transactions for each row execute function taam_guard_ledger_invite_open();
create trigger trg_taam_guard_ledger_refund_active before insert on public.deposit_transactions for each row execute function taam_guard_ledger_refund_active();
create trigger trg_taam_guard_ledger_refund_nonpos before insert on public.deposit_transactions for each row execute function taam_guard_ledger_refund_nonpos();
create trigger trg_taam_guard_ledger_refund_paid before insert on public.deposit_transactions for each row execute function taam_guard_ledger_refund_paid();
create trigger trg_taam_guard_ledger_refund_processed before insert on public.deposit_transactions for each row execute function taam_guard_ledger_refund_processed();
