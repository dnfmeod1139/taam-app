-- ═══════════════════════════════════════════════════════════════
-- TAAM 멤버십 — 오퍼 (심사 통과 안내) 2026-09-02
-- ═══════════════════════════════════════════════════════════════
-- 무엇
--   심사를 통과한 사람에게 보내는 토큰 링크. **가격이 처음 공개되는 곳**이다.
--   7일 유효(설정값). 열면 열었다고 기록하고, 결제하면 회원이 된다.
--
-- 왜 금액을 오퍼에 박제하나
--   설정값(annual_fee_cash/card)은 바뀐다. 그런데 이미 보낸 오퍼의 금액이
--   같이 흔들리면, 어제 1,125만이라고 안내받은 사람이 오늘 열었을 때
--   다른 숫자를 본다. **보낸 순간의 금액이 그 사람의 금액이다.**
--   (대관 정산에서 pay_fx 를 박제한 것과 같은 이유다)
--
-- 왜 통과를 여기서 세우나
--   심사 큐에서 상태만 'offered' 로 올릴 수 있게 두면 「통과인데 보낼 게
--   없는」 사람이 생긴다. 링크를 만드는 이 함수만 offered 를 세운다.
--
-- ⚠ 공개 페이지에는 **전화번호를 주지 않는다.** 토큰을 아는 사람이
--   신청자의 번호까지 보게 할 이유가 없다. 이름도 성만 준다.
--
-- 실행: Supabase SQL Editor. ⚠ membership_apply.sql · membership_settings.sql 다음.
--   읽는 법: 맨 아래가 전부 ✅ 여야 정상.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.membership_offers (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid references public.membership_applications(id) on delete set null,
  token          text unique not null,
  name           text,
  phone          text,
  -- 보낸 순간의 금액. 설정값이 바뀌어도 이 오퍼는 안 흔들린다.
  deposit_amount   int,
  annual_fee_cash  int,
  annual_fee_card  int,
  seats_left       int,
  expires_at     timestamptz not null,
  status         text not null default 'sent',   -- sent|opened|accepted|paid|declined|cancelled
  opened_at      timestamptz,
  accepted_at    timestamptz,
  paid_at        timestamptz,
  admin_memo     text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);

create index if not exists idx_mship_offer_status on public.membership_offers (status, created_at desc);
create index if not exists idx_mship_offer_app    on public.membership_offers (application_id);

alter table public.membership_offers enable row level security;
-- 표는 통째로 잠근다. 공개 페이지는 아래 RPC 하나로만 읽는다 —
-- 그래야 「무엇을 보여줄지」를 한 곳에서 정할 수 있다.
revoke all on public.membership_offers from anon, authenticated;

comment on table public.membership_offers is
  '심사 통과 안내(오퍼). 금액은 보낸 순간의 값으로 박제한다. 읽기는 RPC 로만.';


-- ── ① 오퍼 만들기 (= 통과) ────────────────────────────────────
create or replace function public.taam_mship_offer_create(p_application_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  a public.membership_applications%rowtype;
  o public.membership_offers%rowtype;
  v_days int; v_seat int;
  v_dep int; v_fc int; v_fk int;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into a from public.membership_applications where id = p_application_id;
  if not found then raise exception '신청을 찾을 수 없습니다' using errcode = 'P0002'; end if;

  -- 이미 살아 있는 오퍼가 있으면 새로 만들지 않는다. 두 장을 보내면
  -- 그 사람은 어느 것이 진짜인지 모른다.
  select * into o from public.membership_offers
   where application_id = a.id and status in ('sent','opened','accepted')
     and expires_at > now()
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'already', true, 'id', o.id,
                              'token', o.token, 'expires_at', o.expires_at);
  end if;

  select (s.v#>>'{}')::int into v_days from public.membership_settings s where s.k = 'offer_days';
  select (s.v#>>'{}')::int into v_dep  from public.membership_settings s where s.k = 'deposit_amount';
  select (s.v#>>'{}')::int into v_fc   from public.membership_settings s where s.k = 'annual_fee_cash';
  select (s.v#>>'{}')::int into v_fk   from public.membership_settings s where s.k = 'annual_fee_card';
  select greatest(0, capacity - taken) into v_seat from public.membership_seats where id = 1;

  -- ⚠ 금액이 없으면 만들지 않는다. 금액 없는 오퍼는 「가격을 공개하는
  --   페이지」인데 가격이 없다 — 보내면 그 자리에서 신뢰를 잃는다.
  if coalesce(v_dep,0) <= 0 or (coalesce(v_fc,0) <= 0 and coalesce(v_fk,0) <= 0) then
    raise exception '금액이 설정되지 않았습니다 — 설정에서 예치금·연회비를 먼저 넣으세요'
      using errcode = '22023';
  end if;

  insert into public.membership_offers
    (application_id, token, name, phone,
     deposit_amount, annual_fee_cash, annual_fee_card, seats_left,
     expires_at, created_by)
  values
    (a.id, replace(gen_random_uuid()::text, '-', ''), a.name, a.phone,
     v_dep, v_fc, v_fk, v_seat,
     now() + (coalesce(v_days, 7) || ' day')::interval, auth.uid())
  returning * into o;

  -- 통과는 링크가 생겼을 때 성립한다
  update public.membership_applications
     set status = 'offered', decided_at = now(), decided_by = auth.uid()
   where id = a.id;

  return jsonb_build_object('ok', true, 'already', false, 'id', o.id,
                            'token', o.token, 'expires_at', o.expires_at,
                            'deposit_amount', o.deposit_amount,
                            'annual_fee_cash', o.annual_fee_cash,
                            'annual_fee_card', o.annual_fee_card);
end;
$$;
revoke all on function public.taam_mship_offer_create(uuid) from public;
grant execute on function public.taam_mship_offer_create(uuid) to authenticated;


-- ── ② 공개 — 링크로 열기 ──────────────────────────────────────
--   ⚠ 전화번호를 안 준다. 이름은 **성만** 준다.
create or replace function public.taam_mship_offer_public(p_token text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare o public.membership_offers%rowtype; v_seat int; v_surname text;
begin
  select * into o from public.membership_offers where token = p_token;
  if not found then return jsonb_build_object('found', false); end if;

  if o.status in ('cancelled','declined') then
    return jsonb_build_object('found', true, 'blocked', 'cancelled');
  end if;
  if o.expires_at <= now() then
    return jsonb_build_object('found', true, 'blocked', 'expired', 'expires_at', o.expires_at);
  end if;
  if o.status = 'paid' then
    return jsonb_build_object('found', true, 'blocked', 'paid');
  end if;

  -- 열었다고 기록. 처음 열 때만 시각을 남긴다.
  if o.status = 'sent' then
    update public.membership_offers
       set status = 'opened', opened_at = now() where id = o.id;
    o.status := 'opened';
  end if;

  -- 잔여석은 **지금 값**을 보여준다. 금액과 달리 이건 오늘의 사실이다.
  select greatest(0, capacity - taken) into v_seat from public.membership_seats where id = 1;
  v_surname := nullif(left(btrim(coalesce(o.name,'')), 1), '');

  return jsonb_build_object(
    'found', true, 'blocked', null,
    'surname', v_surname,
    'status', o.status,
    'expires_at', o.expires_at,
    'deposit_amount', o.deposit_amount,
    'annual_fee_cash', o.annual_fee_cash,
    'annual_fee_card', o.annual_fee_card,
    'seats_left', coalesce(v_seat, o.seats_left)
  );
end;
$$;
revoke all on function public.taam_mship_offer_public(text) from public;
grant execute on function public.taam_mship_offer_public(text) to anon, authenticated;


-- ── ③ 공개 — 시작하겠다고 누르기 ──────────────────────────────
--   결제까지 여기서 하지 않는다. 「하겠다」를 남기고 담당자가 잇는다.
--   ⚠ 이 함수는 돈을 움직이지 않는다. 회원 등급도 올리지 않는다.
create or replace function public.taam_mship_offer_accept(p_token text, p_method text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare o public.membership_offers%rowtype; v_m text;
begin
  select * into o from public.membership_offers where token = p_token;
  if not found then raise exception '링크를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if o.expires_at <= now() then raise exception '안내 기간이 종료되었습니다' using errcode = '55000'; end if;
  if o.status in ('cancelled','declined') then raise exception '종료된 안내입니다' using errcode = '55000'; end if;
  if o.status = 'paid' then return jsonb_build_object('ok', true, 'already', true); end if;

  v_m := lower(coalesce(nullif(btrim(p_method),''), ''));
  if v_m not in ('', 'cash', 'card') then
    raise exception '결제 방법을 알 수 없습니다' using errcode = '22023';
  end if;

  update public.membership_offers
     set status = 'accepted', accepted_at = coalesce(accepted_at, now()),
         admin_memo = case when v_m = '' then admin_memo
                           else coalesce(admin_memo || ' / ', '') || '희망 결제: ' || v_m end
   where id = o.id;

  return jsonb_build_object('ok', true, 'already', false, 'method', nullif(v_m,''));
end;
$$;
revoke all on function public.taam_mship_offer_accept(text, text) from public;
grant execute on function public.taam_mship_offer_accept(text, text) to anon, authenticated;


-- ── ④ 어드민 — 오퍼 목록 · 취소 · 결제 확정 ───────────────────
create or replace function public.taam_mship_offer_list(p_limit int default 200)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_out jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_out
    from (select o.id, o.application_id, o.token, o.name, o.phone,
                 o.deposit_amount, o.annual_fee_cash, o.annual_fee_card,
                 o.expires_at, o.status, o.opened_at, o.accepted_at, o.paid_at,
                 o.admin_memo, o.created_at,
                 (o.expires_at <= now()) as expired
            from public.membership_offers o
           order by o.created_at desc
           limit greatest(1, least(coalesce(p_limit,200), 500))) x;
  return v_out;
end;
$$;
revoke all on function public.taam_mship_offer_list(int) from public;
grant execute on function public.taam_mship_offer_list(int) to authenticated;

create or replace function public.taam_mship_offer_cancel(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare o public.membership_offers%rowtype;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into o from public.membership_offers where id = p_id;
  if not found then raise exception '오퍼를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if o.status = 'paid' then
    raise exception '이미 결제된 오퍼는 끊을 수 없습니다' using errcode = '55000';
  end if;
  update public.membership_offers set status = 'cancelled' where id = o.id;
  -- 신청은 심사 중으로 되돌린다. 링크가 죽었는데 「통과」로 남으면
  -- 큐에서 사라진 채 아무 일도 안 일어난다.
  if o.application_id is not null then
    update public.membership_applications
       set status = 'screening', decided_at = null, decided_by = null
     where id = o.application_id and status = 'offered';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.taam_mship_offer_cancel(uuid) from public;
grant execute on function public.taam_mship_offer_cancel(uuid) to authenticated;

-- 결제 확정 — 입금·카드 승인을 눈으로 확인한 뒤 슈퍼어드민이 누른다.
--   ⚠ 예치금 잔액은 여기서 건드리지 않는다. 잔액은 기존 RPC
--     (taam_apply_deposit_delta) 로만 움직인다 — 돈이 두 곳에서
--     움직이기 시작하면 어느 쪽이 맞는지 아무도 모르게 된다.
create or replace function public.taam_mship_offer_paid(p_id uuid, p_memo text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare o public.membership_offers%rowtype;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  update public.membership_offers
     set status = 'paid', paid_at = now(),
         admin_memo = coalesce(nullif(btrim(p_memo),''), admin_memo)
   where id = p_id returning * into o;
  if not found then raise exception '오퍼를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if o.application_id is not null then
    update public.membership_applications set status = 'paid' where id = o.application_id;
  end if;
  return jsonb_build_object('ok', true, 'name', o.name);
end;
$$;
revoke all on function public.taam_mship_offer_paid(uuid, text) from public;
grant execute on function public.taam_mship_offer_paid(uuid, text) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 오퍼 표' as "구분",
       case when to_regclass('public.membership_offers') is not null then '✅' else '❌' end as "상태", '' as "메모"
union all
select '② 표가 통째로 잠겼나 ⭐',
       case when not has_table_privilege('anon','public.membership_offers','select')
             and not has_table_privilege('authenticated','public.membership_offers','select')
            then '✅ RPC 로만 읽는다' else '❌ 표가 열려 있다' end, ''
union all
select '③ 공개 함수 2개 (열기·시작)',
       case when count(*) = 2 then '✅' else '❌ ' || count(*)::text || '/2' end,
       coalesce(string_agg(proname, ' · ' order by proname), '—')
  from pg_proc
 where pronamespace='public'::regnamespace
   and proname in ('taam_mship_offer_public','taam_mship_offer_accept')
union all
select '④ 어드민 함수 4개',
       case when count(*) = 4 then '✅' else '❌ ' || count(*)::text || '/4' end,
       coalesce(string_agg(proname, ' · ' order by proname), '—')
  from pg_proc
 where pronamespace='public'::regnamespace
   and proname in ('taam_mship_offer_create','taam_mship_offer_list',
                   'taam_mship_offer_cancel','taam_mship_offer_paid')
union all
select '⑤ 금액을 박제하나',
       case when count(*) = 3 then '✅' else '❌ ' || count(*)::text || '/3' end,
       coalesce(string_agg(column_name, ' · ' order by column_name), '—')
  from information_schema.columns
 where table_schema='public' and table_name='membership_offers'
   and column_name in ('deposit_amount','annual_fee_cash','annual_fee_card')
 order by 1;
