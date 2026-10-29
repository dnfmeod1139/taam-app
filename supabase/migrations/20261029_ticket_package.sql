-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 연계(패키지) — 여러 매장의 회차를 묶어 한 번에 판다 (2026-10-29)
-- ═══════════════════════════════════════════════════════════════
--   운영 요청: 「연계하면 단일 상품으로는 못 사고(연계를 풀어야 단일 구매) · 연계된 동안은 패키지로 산다」.
--   운영 결정(2026-10-29): 가격 = 회차 정가 합계((식사+대행+주류)×인원의 합 · 할인 없음) · 결제 = 예치금 먼저 + 모자라면 카드 ·
--     취소 = 패키지 통째로만(회차마다 지금 규정 — 결제 30분 내 전액 · 방문 D-31 이상 대행비 제외 · 그 뒤 0 — 의 합) ·
--     같은 시기 여러 매장을 연속으로 묶는다(슈퍼어드민이 만든다 · 파트너는 못 묶는다).
--
--   구조 — 돈과 좌석은 **회차마다 종전 그대로** 한 줄씩(PAYH- 구매 id · 회차·방문일·대행비·정원·리마인드·파트너 화면이 그대로 돈다),
--     묶음은 서버 표가 안다(회원이 못 쓰는 표):
--     · ticket_packages        — 패키지(이름 세 벌 · 설명 · 상태 active|unlinked · 회차 목록 스냅샷)
--     · ticket_package_rounds  — 지금 연계된 회차(회차 하나는 한 패키지에만 · 풀면 줄을 지운다)
--     · ticket_package_orders  — 회원의 패키지 구매 한 건(hold → paid → cancelled | failed) · 회차 줄의 구매 id 목록 · 줄마다 예치금·카드 몫
--   지키는 것(서버 · 트리거 trg_taam_guard_ticket_package):
--     ① 연계된 회차에는 회원 구매 행(PAY*)을 **패키지 홀드로만** 넣는다 — 그 밖의 홀드·카드 확정 폴백(PAYC-)은 PACKAGE_ONLY
--     ② 연계 회차 · 패키지 홀드 · 패키지 구매에 든 행이 확정(active)되는 것은 **패키지 확정 함수 안에서만**(GUC taam.pkg_confirm) —
--        단일 예치금 확정(taam_purchase_confirm_deposit) · 단일 카드 확정(toss-confirm · toss-billing-charge)이 그 홀드를 집어도 PACKAGE_ONLY → 롤백·카드 자동 취소
--     ③ 결제된 패키지의 회차 한 줄만 취소 · 인원 변경 — 회원·파트너는 PACKAGE_CANCEL_WHOLE / PACKAGE_PAX_LOCKED (슈퍼어드민 판단은 취소만 허용)
--     ④ 연계된 회차는 지울 수 없다(PACKAGE_ROUND_LOCKED — 먼저 연계를 푼다)
--   운영 채널(수동 MAN- · 초대 INVH-/INV- · 결제 링크 LINK- · 정산 KSK-)은 막지 않는다 — 어드민의 판단이다.
--   홀드 넣기는 **앱이 회원 세션으로** 회차마다(정원·등급·중복·같은 시간대·재구매 가드가 그대로 돈다) — 패키지 홀드는 extra_data.pkg = 패키지 id.
--   카드 몫은 새 Edge toss-package-pay 가 이 파일의 서버 함수(_prepare · _confirm_card · _fail)를 부른다 — 옛 toss-order/toss-confirm 은 건드리지 않는다.
-- ═══════════════════════════════════════════════════════════════
create temp table if not exists _pk(항목 text, 결과 text);
truncate _pk;

-- ── A. 표 ──
create table if not exists public.ticket_packages (
  id             text primary key,
  title          text not null,
  title_en       text,
  title_ja       text,
  description    text,
  description_en text,
  description_ja text,
  status         text not null default 'active' check (status in ('active', 'unlinked')),
  rounds         text[] not null default '{}',          -- 만들 때의 회차 순서(스냅샷 · 풀어도 남는다)
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unlinked_by    uuid,
  unlinked_at    timestamptz
);
create table if not exists public.ticket_package_rounds (
  ticket_product_id text primary key,                   -- 회차 하나는 한 패키지에만
  package_id        text not null references public.ticket_packages(id) on delete cascade,
  sort              int  not null default 0
);
create index if not exists ticket_package_rounds_pkg_idx on public.ticket_package_rounds(package_id);
create table if not exists public.ticket_package_orders (
  id            text primary key,
  package_id    text not null references public.ticket_packages(id),
  user_id       uuid not null,
  pax           int  not null check (pax between 1 and 20),
  status        text not null default 'hold' check (status in ('hold', 'paid', 'cancelled', 'failed')),
  purchase_ids  text[] not null,
  items         jsonb not null default '[]'::jsonb,     -- [{purchase_id, ticket_product_id, rest_id, rest_name, date, time, price, agency_per, dep, mem, gen, card}]
  total         bigint not null default 0,
  deposit_used  bigint not null default 0,
  card_paid     bigint not null default 0,
  order_id      text,                                   -- payment_orders(package_topup)
  fail_reason   text,
  cancel        jsonb,                                  -- {at, by, role, refund, deposit_refund, card_refund, rows:[…]}
  card_refund   jsonb,                                  -- {amount, order_id, status pending|done, requested_at, done_at, via, toss_tx}
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '20 minutes',
  paid_at       timestamptz,
  cancelled_at  timestamptz,
  updated_at    timestamptz not null default now()
);
create index if not exists ticket_package_orders_pids_idx on public.ticket_package_orders using gin (purchase_ids);
create index if not exists ticket_package_orders_user_idx on public.ticket_package_orders(user_id, created_at desc);
create index if not exists ticket_package_orders_pkg_idx  on public.ticket_package_orders(package_id);

alter table public.ticket_packages enable row level security;
alter table public.ticket_package_rounds enable row level security;
alter table public.ticket_package_orders enable row level security;
drop policy if exists tpk_read on public.ticket_packages;
drop policy if exists tpk_read_anon on public.ticket_packages;
create policy tpk_read_anon on public.ticket_packages for select to anon using (status = 'active');
create policy tpk_read on public.ticket_packages for select to authenticated
  using (status = 'active' or public.is_super_admin(auth.uid()));
drop policy if exists tpkr_read on public.ticket_package_rounds;
create policy tpkr_read on public.ticket_package_rounds for select to anon, authenticated using (true);
drop policy if exists tpko_read on public.ticket_package_orders;
create policy tpko_read on public.ticket_package_orders for select to authenticated
  using (user_id = auth.uid() or public.is_super_admin(auth.uid()));
revoke all on public.ticket_packages, public.ticket_package_rounds, public.ticket_package_orders from anon, authenticated;
grant select on public.ticket_packages, public.ticket_package_rounds to anon, authenticated;
grant select on public.ticket_package_orders to authenticated;
insert into _pk values ('A 표 셋 · RLS(읽기만 · 쓰기는 서버 함수)', '✅');

-- ── B. payment_orders 용도에 package_topup ──
do $do$
declare v_def text;
begin
  if to_regclass('public.payment_orders') is null then insert into _pk values ('B payment_orders', '⚠ 표 없음'); return; end if;
  select pg_get_constraintdef(c.oid) into v_def from pg_constraint c
   where c.conrelid = 'public.payment_orders'::regclass and c.conname = 'payment_orders_purpose_chk';
  if v_def is null then insert into _pk values ('B payment_orders 용도 제약', '✅ 제약 없음(그대로)'); return; end if;
  if v_def like '%package_topup%' then insert into _pk values ('B payment_orders 용도 제약', '✅ 이미 있음'); return; end if;
  if v_def not like '%ARRAY[%' then insert into _pk values ('B payment_orders 용도 제약', '⚠ 모양이 다르다 — 손으로: ' || left(v_def, 120)); return; end if;
  execute 'alter table public.payment_orders drop constraint payment_orders_purpose_chk';
  execute 'alter table public.payment_orders add constraint payment_orders_purpose_chk ' || replace(v_def, 'ARRAY[', 'ARRAY[''package_topup''::text, ');
  insert into _pk values ('B payment_orders 용도에 package_topup', '✅');
exception when others then insert into _pk values ('B payment_orders 용도 제약', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- B'. 패키지 주문은 toss-package-pay 만 paid 로 만든다 — 옛 toss-confirm / toss-billing-charge 가 패키지 주문번호를 받으면
--     카드는 승인하고 좌석은 확정하지 않은 채 paid 로 끝낸다(용도를 모른다). 그 갱신을 막아 둔다(확정 표시 pkg_claim 은 새 함수만 적는다).
create or replace function public.taam_guard_pkg_order_claim()
returns trigger language plpgsql as $$
begin
  if new.purpose = 'package_topup' and new.status = 'paid' and old.status is distinct from 'paid'
     and coalesce(new.metadata->>'pkg_claim', '') <> 'toss-package-pay' then
    raise exception 'PACKAGE_ORDER_CLAIM: 패키지 주문은 toss-package-pay 로만 확정합니다' using errcode = '42501';
  end if;
  return new;
end $$;
do $do$ begin
  if to_regclass('public.payment_orders') is not null then
    execute 'drop trigger if exists trg_taam_guard_pkg_order_claim on public.payment_orders';
    execute 'create trigger trg_taam_guard_pkg_order_claim before update of status on public.payment_orders for each row execute function public.taam_guard_pkg_order_claim()';
    insert into _pk values ('B'' 패키지 주문은 새 함수만 paid 로', '✅');
  end if;
end $do$;

-- ── C. 도우미 ──
create or replace function public._taam_pkg_super_ok()
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null then return coalesce(public.is_super_admin(auth.uid()), false); end if;
  return session_user = 'postgres'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then return false;
end $$;
create or replace function public._taam_pkg_server_ok()
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null then return false; end if;
  return session_user = 'postgres'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then return false;
end $$;
-- 글자 검사(이름·설명) — HTML 태그 모양·javascript: 금지
create or replace function public._taam_pkg_text_ok(p text)
returns boolean language sql immutable as $$
  select p is null or (p !~* '<\s*[a-z/!?]' and p !~* 'javascript\s*:')
$$;
-- 회차의 KST 방문일(연도 있는 날짜만)
create or replace function public._taam_pkg_visit(p_tp text)
returns date language sql stable security definer set search_path = public as $$
  select public._taam_pu_visit_date(tp.date) from public.ticket_products tp where tp.id::text = p_tp
$$;
-- 회차가 지금 팔 수 없는 상태인가 — 승인 대기·숨김·삭제 신청 · **어드민이 손으로 잠근 매진**(auto_soldout=false — 앱 밖에서 자리가 나간 것).
--   자동 매진(좌석이 다 찬 것)은 좌석 가드가 판단하므로 여기서 막지 않는다. 컬럼이 없는 DB 에서도 돈다(to_jsonb).
create or replace function public._taam_pkg_round_closed(p_tp text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select lower(coalesce(tp.status, '')) in ('pending', 'hidden', 'deleterequest', 'deleted')
                          or (lower(coalesce(tp.status, '')) = 'soldout' and coalesce((to_jsonb(tp)->>'auto_soldout')::boolean, true) = false)
                     from public.ticket_products tp where tp.id::text = p_tp), true)
$$;
revoke all on function public._taam_pkg_super_ok(), public._taam_pkg_server_ok(), public._taam_pkg_visit(text), public._taam_pkg_round_closed(text) from public, anon, authenticated;

-- 회차 묶음의 충돌(같은 날 같은 시간대 · 같은 매장 재구매 제한 안) — 만들 때 거절 · 목록에서 경고
create or replace function public._taam_pkg_conflicts(p_rounds text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  a record; b record; v_out jsonb := '[]'::jsonb; v_days int; v_rel boolean;
begin
  for a in select tp.id::text as id, tp.rest_id::text as rest, coalesce(tp.rest_name, '') as rn, tp.time as tm,
                  public._taam_pu_visit_date(tp.date) as d, public.taam_time_slot(tp.time) as slot, i
             from unnest(p_rounds) with ordinality u(id, i) join public.ticket_products tp on tp.id::text = u.id loop
    for b in select tp.id::text as id, tp.rest_id::text as rest, coalesce(tp.rest_name, '') as rn, tp.time as tm,
                    public._taam_pu_visit_date(tp.date) as d, public.taam_time_slot(tp.time) as slot, i
               from unnest(p_rounds) with ordinality u(id, i) join public.ticket_products tp on tp.id::text = u.id where i > a.i loop
      if a.d is not null and a.d = b.d and (a.slot is null or b.slot is null or a.slot = b.slot) then
        v_out := v_out || jsonb_build_object('kind', 'time', 'a', a.id, 'b', b.id,
                 'msg', a.rn || ' · ' || b.rn || ' — 같은 날 같은 시간대(' || to_char(a.d, 'YYYY.MM.DD') || ')');
      end if;
      if a.rest is not null and a.rest = b.rest and a.d is not null and b.d is not null and a.d <> b.d then
        select coalesce(r.repurchase_day, 0) into v_days from public.restaurants r where r.id::text = a.rest;
        v_rel := false;
        begin
          v_rel := coalesce(public.taam_repurchase_released(a.id), false) or coalesce(public.taam_repurchase_released(b.id), false);
        exception when others then v_rel := false; end;
        if coalesce(v_days, 0) > 0 and abs(a.d - b.d) < v_days and not v_rel then
          v_out := v_out || jsonb_build_object('kind', 'repurchase', 'a', a.id, 'b', b.id,
                   'msg', a.rn || ' — 재구매 제한 ' || v_days || '일 안에 두 회차(' || to_char(a.d, 'MM.DD') || ' · ' || to_char(b.d, 'MM.DD') || ')');
        end if;
      end if;
    end loop;
  end loop;
  return v_out;
end $$;
revoke all on function public._taam_pkg_conflicts(text[]) from public, anon, authenticated;
insert into _pk values ('C 도우미', '✅');

-- ── D. 슈퍼어드민 — 만들기·이름 고치기 · 풀기 · 목록 ──
create or replace function public.taam_package_save(p_id text, p_title text, p_rounds text[] default null,
                                                    p_title_en text default null, p_title_ja text default null,
                                                    p_desc text default null, p_desc_en text default null, p_desc_ja text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_id text := nullif(btrim(coalesce(p_id, '')), ''); v_pkg public.ticket_packages%rowtype;
  v_rounds text[]; v_n int; r record; v_conf jsonb; v_today date := (now() at time zone 'Asia/Seoul')::date; v_i int := 0; v_rid text;
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  p_title := btrim(coalesce(p_title, ''));
  if p_title = '' or char_length(p_title) > 80 then raise exception 'BAD_TITLE: 이름은 1~80자' using errcode = '22023'; end if;
  if not (public._taam_pkg_text_ok(p_title) and public._taam_pkg_text_ok(p_title_en) and public._taam_pkg_text_ok(p_title_ja)
          and public._taam_pkg_text_ok(p_desc) and public._taam_pkg_text_ok(p_desc_en) and public._taam_pkg_text_ok(p_desc_ja)) then
    raise exception 'BAD_INPUT: 글자에 태그 모양을 쓸 수 없습니다' using errcode = '22023';
  end if;
  if char_length(coalesce(p_title_en, '')) > 120 or char_length(coalesce(p_title_ja, '')) > 120
     or char_length(coalesce(p_desc, '')) > 600 or char_length(coalesce(p_desc_en, '')) > 900 or char_length(coalesce(p_desc_ja, '')) > 900 then
    raise exception 'BAD_TITLE: 글자가 너무 깁니다' using errcode = '22023';
  end if;

  if v_id is not null then
    -- 고치기 — 이름·설명만(회차는 바꾸지 않는다: 풀고 새로 만든다)
    select * into v_pkg from public.ticket_packages where id = v_id for update;
    if not found then raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0002'; end if;
    update public.ticket_packages
       set title = p_title, title_en = nullif(btrim(coalesce(p_title_en, '')), ''), title_ja = nullif(btrim(coalesce(p_title_ja, '')), ''),
           description = nullif(btrim(coalesce(p_desc, '')), ''), description_en = nullif(btrim(coalesce(p_desc_en, '')), ''),
           description_ja = nullif(btrim(coalesce(p_desc_ja, '')), ''), updated_at = now()
     where id = v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'updated', true);
  end if;

  select array_agg(distinct x) into v_rounds from unnest(coalesce(p_rounds, '{}')) x where btrim(coalesce(x, '')) <> '';
  v_n := coalesce(array_length(v_rounds, 1), 0);
  if v_n < 2 or v_n > 8 then raise exception 'BAD_ROUNDS: 회차는 2~8개' using errcode = '22023'; end if;
  -- 방문일 순서로 정렬(같은 날은 시각)
  select array_agg(u.id order by public._taam_pu_visit_date(tp.date), tp.time, u.id) into v_rounds
    from unnest(v_rounds) u(id) left join public.ticket_products tp on tp.id::text = u.id;
  for r in select u.id, tp.id as tid, tp.status, public._taam_pu_visit_date(tp.date) as d, coalesce(tp.rest_name, u.id) as rn
             from unnest(v_rounds) u(id) left join public.ticket_products tp on tp.id::text = u.id loop
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
  v_conf := public._taam_pkg_conflicts(v_rounds);
  if jsonb_array_length(v_conf) > 0 then
    raise exception 'PACKAGE_CONFLICT: %', (select string_agg(e->>'msg', ' / ') from jsonb_array_elements(v_conf) e) using errcode = '22023';
  end if;

  v_id := 'pk_' || to_char(now() at time zone 'Asia/Seoul', 'YYMMDDHH24MISS') || '_' || substr(md5(random()::text || clock_timestamp()::text), 1, 5);
  insert into public.ticket_packages(id, title, title_en, title_ja, description, description_en, description_ja, rounds, created_by)
  values (v_id, p_title, nullif(btrim(coalesce(p_title_en, '')), ''), nullif(btrim(coalesce(p_title_ja, '')), ''),
          nullif(btrim(coalesce(p_desc, '')), ''), nullif(btrim(coalesce(p_desc_en, '')), ''), nullif(btrim(coalesce(p_desc_ja, '')), ''),
          v_rounds, v_uid);
  foreach v_rid in array v_rounds loop
    v_i := v_i + 1;
    insert into public.ticket_package_rounds(ticket_product_id, package_id, sort) values (v_rid, v_id, v_i);
  end loop;
  -- 회차 updated_at 을 올려 앱 Realtime(ticket_products)이 다시 읽게 한다 — 중첩 갱신이라 승인 가드는 통과
  update public.ticket_products set updated_at = now() where id::text = any(v_rounds);
  return jsonb_build_object('ok', true, 'id', v_id, 'rounds', to_jsonb(v_rounds));
end $$;

create or replace function public.taam_package_unlink(p_id text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_rounds text[]; v_hold int;
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select array_agg(ticket_product_id) into v_rounds from public.ticket_package_rounds where package_id = p_id;
  update public.ticket_packages set status = 'unlinked', unlinked_by = auth.uid(), unlinked_at = now(), updated_at = now()
   where id = p_id and status = 'active';
  if not found then raise exception 'PACKAGE_NOT_ACTIVE' using errcode = 'P0002'; end if;
  delete from public.ticket_package_rounds where package_id = p_id;
  select count(*) into v_hold from public.ticket_package_orders where package_id = p_id and status = 'hold' and expires_at > now();
  if v_rounds is not null then update public.ticket_products set updated_at = now() where id::text = any(v_rounds); end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'rounds', to_jsonb(coalesce(v_rounds, '{}')), 'holds_in_flight', v_hold);
end $$;

create or replace function public.taam_package_list(p_include_unlinked boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'title', p.title, 'title_en', p.title_en, 'title_ja', p.title_ja,
             'description', p.description, 'description_en', p.description_en, 'description_ja', p.description_ja,
             'status', p.status, 'created_at', p.created_at, 'unlinked_at', p.unlinked_at,
             'rounds', (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', u.id, 'rest_id', tp.rest_id, 'rest_name', tp.rest_name, 'date', tp.date, 'time', tp.time,
                          'status', tp.status, 'total_pax', tp.total_pax,
                          'price1', public.taam_ticket_price_krw(u.id, 1), 'gone', tp.id is null) order by u.i), '[]'::jsonb)
                          from unnest(p.rounds) with ordinality u(id, i) left join public.ticket_products tp on tp.id::text = u.id),
             'orders', (select jsonb_build_object(
                          'paid', count(*) filter (where o.status = 'paid'),
                          'cancelled', count(*) filter (where o.status = 'cancelled'),
                          'hold', count(*) filter (where o.status = 'hold' and o.expires_at > now()),
                          'pax_paid', coalesce(sum(o.pax) filter (where o.status = 'paid'), 0),
                          'amount_paid', coalesce(sum(o.total) filter (where o.status = 'paid'), 0),
                          'card_refund_pending', count(*) filter (where o.card_refund->>'status' = 'pending'))
                          from public.ticket_package_orders o where o.package_id = p.id),
             'conflicts', case when p.status = 'active' then public._taam_pkg_conflicts(p.rounds) else '[]'::jsonb end
           ) order by (p.status = 'active') desc, p.created_at desc)
      from public.ticket_packages p
     where p.status = 'active' or p_include_unlinked
  ), '[]'::jsonb);
end $$;

create or replace function public.taam_package_orders_admin(p_package text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
           'id', o.id, 'user_id', o.user_id, 'name', pr.display_name, 'phone', pr.phone, 'pax', o.pax, 'status', o.status,
           'total', o.total, 'deposit_used', o.deposit_used, 'card_paid', o.card_paid, 'order_id', o.order_id,
           'paid_at', o.paid_at, 'cancelled_at', o.cancelled_at, 'cancel', o.cancel, 'card_refund', o.card_refund,
           'purchase_ids', to_jsonb(o.purchase_ids), 'created_at', o.created_at,
           'card_issue', ci.j) order by o.created_at desc)
    from public.ticket_package_orders o left join public.profiles pr on pr.id = o.user_id
    -- 카드는 승인됐는데 이 묶음이 그 주문으로 확정되지 않았거나 · 결과를 모르는(unknown:) · 취소가 실패한 카드 주문 — 「카드 결제 확인」 대상(2차 검증)
    left join lateral (select jsonb_build_object('order_id', po.order_id, 'status', po.status, 'fail_reason', po.fail_reason, 'amount', po.amount, 'created_at', po.created_at) as j
                         from public.payment_orders po
                        where po.purpose = 'package_topup' and po.metadata->>'group_id' = o.id
                          and ((po.status = 'paid' and not (o.status in ('paid', 'cancelled') and o.order_id = po.order_id))
                            or (po.status = 'pending' and coalesce(po.fail_reason, '') like 'unknown:%')
                            or (po.status = 'canceled' and (coalesce(po.fail_reason, '') like '%refund_failed' or coalesce(po.fail_reason, '') like '%canceling')))
                        order by po.created_at desc limit 1) ci on true
   where o.package_id = p_package and (o.status in ('paid', 'cancelled') or (o.status = 'hold' and o.expires_at > now()) or ci.j is not null)), '[]'::jsonb);
end $$;
revoke all on function public.taam_package_save(text, text, text[], text, text, text, text, text), public.taam_package_unlink(text),
                       public.taam_package_list(boolean), public.taam_package_orders_admin(text) from public, anon;
grant execute on function public.taam_package_save(text, text, text[], text, text, text, text, text), public.taam_package_unlink(text),
                          public.taam_package_list(boolean), public.taam_package_orders_admin(text) to authenticated;
insert into _pk values ('D 슈퍼어드민 함수(만들기·풀기·목록·구매자)', '✅');

-- ── E. 가드 — 연계 회차의 단일 구매 · 패키지 행 확정·취소·인원 ──
create or replace function public.taam_guard_ticket_package()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pkg  text;
  v_conf text := nullif(current_setting('taam.pkg_confirm', true), '');
  v_cx   text := nullif(current_setting('taam.pkg_cancel', true), '');
  v_gid  text;
  v_ns   text := lower(coalesce(new.status, ''));
  v_os   text;
begin
  if coalesce(new.purchase_id, '') !~ '^PAY' then return new; end if;
  if tg_op = 'INSERT' then
    if v_ns in ('cancelled', 'canceled', 'expired') then return new; end if;
    select r.package_id into v_pkg from public.ticket_package_rounds r join public.ticket_packages p on p.id = r.package_id and p.status = 'active'
     where r.ticket_product_id = new.ticket_product_id::text;
    if v_pkg is null then
      if new.extra_data ? 'pkg' and v_ns = 'hold' then new.extra_data := new.extra_data - 'pkg'; end if;   -- 연계 안 된 회차의 패키지 표시는 지운다(단일 홀드로)
      return new;
    end if;
    if v_ns = 'hold' and coalesce(new.extra_data->>'pkg', '') = v_pkg then return new; end if;
    if v_conf is not null and exists (select 1 from public.ticket_package_orders o where o.id = v_conf and new.purchase_id = any(o.purchase_ids)) then
      return new;
    end if;
    raise exception 'PACKAGE_ONLY: 이 회차는 패키지로만 구매할 수 있습니다' using errcode = '42501';
  end if;

  v_os := lower(coalesce(old.status, ''));
  -- ② 확정(active)으로 바뀌는 것 — 연계 회차 · 패키지 홀드 · 패키지 구매에 든 행은 패키지 확정 함수 안에서만
  if v_ns = 'active' and v_os <> 'active'
     -- 결제된 패키지 줄의 방문 표시(used·noshow …)를 되돌리는 것은 그대로 — 홀드 확정·취소 되살리기만 막는다
     and not (v_os not in ('hold', 'cancelled', 'canceled', 'expired', '')
              and exists (select 1 from public.ticket_package_orders o where o.purchase_ids @> array[new.purchase_id::text]
                                                                        and o.status = 'paid' and o.user_id = new.user_id)) then
    if exists (select 1 from public.ticket_package_rounds r join public.ticket_packages p on p.id = r.package_id and p.status = 'active'
                where r.ticket_product_id = new.ticket_product_id::text)
       or coalesce(old.extra_data, '{}'::jsonb) ? 'pkg'
       or exists (select 1 from public.ticket_package_orders o where o.purchase_ids @> array[new.purchase_id::text] and o.status in ('hold', 'paid')) then
      if v_conf is null or not exists (select 1 from public.ticket_package_orders o
                                         where o.id = v_conf and o.user_id = new.user_id and new.purchase_id = any(o.purchase_ids)) then
        raise exception 'PACKAGE_ONLY: 이 회차는 패키지로만 구매할 수 있습니다' using errcode = '42501';
      end if;
    end if;
  end if;

  -- ③ 결제된 패키지의 한 줄만 취소 · 인원 변경
  if (v_ns in ('cancelled', 'canceled') and v_os not in ('cancelled', 'canceled'))
     or new.party_size is distinct from old.party_size then
    select o.id into v_gid from public.ticket_package_orders o where o.purchase_ids @> array[new.purchase_id::text] and o.status = 'paid' limit 1;
    if v_gid is not null and v_cx is distinct from v_gid and auth.uid() is not null then
      if new.party_size is distinct from old.party_size then
        raise exception 'PACKAGE_PAX_LOCKED: 패키지 예약은 인원을 바꿀 수 없습니다 — 패키지를 취소하고 다시 예약해 주세요' using errcode = '42501';
      end if;
      if not coalesce(public.is_super_admin(auth.uid()), false) then
        raise exception 'PACKAGE_CANCEL_WHOLE: 패키지는 통째로만 취소할 수 있습니다' using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_taam_guard_ticket_package on public.tickets;
create trigger trg_taam_guard_ticket_package
  before insert or update of status, party_size, ticket_product_id on public.tickets
  for each row execute function public.taam_guard_ticket_package();

create or replace function public.taam_guard_tp_package_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.ticket_package_rounds r where r.ticket_product_id = old.id::text) then
    raise exception 'PACKAGE_ROUND_LOCKED: 패키지에 연계된 회차입니다 — 먼저 연계를 풀어 주세요' using errcode = '42501';
  end if;
  return old;
end $$;
drop trigger if exists trg_taam_guard_tp_package_delete on public.ticket_products;
create trigger trg_taam_guard_tp_package_delete before delete on public.ticket_products
  for each row execute function public.taam_guard_tp_package_delete();
revoke all on function public.taam_guard_ticket_package(), public.taam_guard_tp_package_delete() from public, anon, authenticated;
insert into _pk values ('E 가드(단일 구매 막음 · 패키지 확정만 · 한 줄 취소·인원 막음 · 회차 삭제 막음)', '✅');

-- ── F. 회원 — 홀드 등록 · 예치금 확정 · 홀드 반납 ──
-- 패키지 줄(회차 순)을 홀드로부터 만든다 — 확정·카드 주문이 같은 식을 쓴다
create or replace function public._taam_pkg_rows(p_group text)
returns table (purchase_id text, ticket_product_id text, rest_id text, rest_name text, vdate text, vtime text,
               party_size int, status text, user_id uuid, price bigint, agency_per bigint, created_at timestamptz, ord int)
language sql stable security definer set search_path = public as $$
  select t.purchase_id, t.ticket_product_id::text, coalesce(t.restaurant_id::text, tp.rest_id::text), coalesce(t.restaurant_name, tp.rest_name),
         coalesce(tp.date, t.reservation_date::text), coalesce(tp.time, t.visit_time), t.party_size, lower(coalesce(t.status, '')), t.user_id,
         public.taam_ticket_price_krw(t.ticket_product_id::text, greatest(coalesce(t.party_size, 1), 1)), coalesce(tp.agency_fee, 0)::bigint,
         t.created_at, u.i::int
    from public.ticket_package_orders o
    cross join lateral unnest(o.purchase_ids) with ordinality u(pid, i)
    join public.tickets t on t.purchase_id = u.pid
    left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
   where o.id = p_group
   order by u.i
$$;
revoke all on function public._taam_pkg_rows(text) from public, anon, authenticated;

create or replace function public.taam_package_start(p_package text, p_pax int, p_holds text[], p_expect bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_rounds text[]; v_n int; v_h record; v_total bigint := 0; v_price bigint;
  v_pids text[] := '{}'; v_items jsonb := '[]'::jsonb; v_gid text; v_mem bigint; v_gen bigint; v_seen text[] := '{}';
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  if p_pax is null or p_pax < 1 or p_pax > 20 then raise exception 'BAD_PAX' using errcode = '22023'; end if;
  perform 1 from public.ticket_packages where id = p_package and status = 'active';
  if not found then raise exception 'PACKAGE_NOT_ACTIVE: 판매가 끝난 패키지입니다' using errcode = 'P0002'; end if;
  select array_agg(ticket_product_id order by sort) into v_rounds from public.ticket_package_rounds where package_id = p_package;
  v_n := coalesce(array_length(v_rounds, 1), 0);
  if v_n < 2 then raise exception 'PACKAGE_NOT_ACTIVE: 판매가 끝난 패키지입니다' using errcode = 'P0002'; end if;
  if coalesce(array_length(p_holds, 1), 0) <> v_n then raise exception 'HOLDS_MISMATCH: 회차 수와 좌석 확보 수가 다릅니다' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_rounds) x where public._taam_pkg_round_closed(x)) then
    raise exception 'ROUND_CLOSED: 지금 판매하지 않는 일정이 있습니다' using errcode = '22023';
  end if;

  for v_h in select t.* from public.tickets t where t.purchase_id = any(p_holds) order by t.purchase_id for update loop
    if v_h.user_id is distinct from v_uid then raise exception '내 예약이 아닙니다' using errcode = '42501'; end if;
    if lower(coalesce(v_h.status, '')) <> 'hold' or coalesce(v_h.purchase_id, '') not like 'PAYH-%' then
      raise exception 'HOLD_GONE: 좌석 확보가 만료되었습니다 (상태: %)', coalesce(v_h.status, '') using errcode = 'P0002';
    end if;
    if coalesce(v_h.extra_data->>'pkg', '') <> p_package then raise exception 'HOLDS_MISMATCH: 패키지 좌석이 아닙니다' using errcode = '22023'; end if;
    if coalesce(v_h.party_size, 0) <> p_pax then raise exception 'HOLDS_MISMATCH: 인원이 다릅니다' using errcode = '22023'; end if;
    if not (v_h.ticket_product_id::text = any(v_rounds)) or v_h.ticket_product_id::text = any(v_seen) then
      raise exception 'HOLDS_MISMATCH: 회차가 맞지 않습니다' using errcode = '22023';
    end if;
    v_seen := v_seen || v_h.ticket_product_id::text;
  end loop;
  if coalesce(array_length(v_seen, 1), 0) <> v_n then raise exception 'HOLD_GONE: 좌석 확보를 찾지 못했습니다' using errcode = 'P0002'; end if;

  -- 회차 순서대로 줄을 만든다
  for v_h in select t.purchase_id, t.ticket_product_id::text as tpid, coalesce(t.restaurant_id::text, tp.rest_id::text) as rest_id,
                    coalesce(t.restaurant_name, tp.rest_name) as rest_name, tp.date, tp.time, coalesce(tp.agency_fee, 0) as ag, u.i
               from unnest(v_rounds) with ordinality u(rid, i)
               join public.tickets t on t.ticket_product_id::text = u.rid and t.purchase_id = any(p_holds)
               left join public.ticket_products tp on tp.id::text = u.rid
              order by u.i loop
    v_price := public.taam_ticket_price_krw(v_h.tpid, p_pax);
    if v_price is null or v_price <= 0 then raise exception 'PRICE_NOT_SET: % 의 가격이 없습니다', coalesce(v_h.rest_name, v_h.tpid) using errcode = '22023'; end if;
    v_total := v_total + v_price;
    v_pids := v_pids || v_h.purchase_id;
    v_items := v_items || jsonb_build_object('purchase_id', v_h.purchase_id, 'ticket_product_id', v_h.tpid, 'rest_id', v_h.rest_id,
                                             'rest_name', v_h.rest_name, 'date', v_h.date, 'time', v_h.time, 'price', v_price, 'agency_per', v_h.ag);
  end loop;
  if p_expect is not null and p_expect <> v_total then
    raise exception 'PRICE_CHANGED: 금액이 바뀌었습니다 (화면 %원 · 현재 %원)', p_expect, v_total using errcode = '22023';
  end if;

  -- 이 홀드를 쥔 옛 시도(같은 회원의 hold 묶음)는 버린다
  update public.ticket_package_orders set status = 'failed', fail_reason = 'superseded', updated_at = now()
   where user_id = v_uid and status = 'hold' and purchase_ids && v_pids;

  v_gid := 'PKO-' || to_char(now() at time zone 'Asia/Seoul', 'YYMMDDHH24MISS') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  insert into public.ticket_package_orders(id, package_id, user_id, pax, status, purchase_ids, items, total)
  values (v_gid, p_package, v_uid, p_pax, 'hold', v_pids, v_items, v_total);
  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0) into v_mem, v_gen from public.profiles where id = v_uid;
  return jsonb_build_object('ok', true, 'group_id', v_gid, 'total', v_total, 'balance', coalesce(v_mem, 0) + coalesce(v_gen, 0),
                            'shortfall', greatest(0, v_total - coalesce(v_mem, 0) - coalesce(v_gen, 0)), 'items', v_items);
end $$;

-- 확정 공통 — 예치금 차감(줄마다 · 주머니마다 원장) + 홀드 → 확정. p_order 가 있으면 카드 몫(줄 순서대로 예치금을 먼저 채우고 남는 것이 카드)
create or replace function public._taam_pkg_confirm(p_group text, p_uid uuid, p_expect bigint, p_dep_want bigint, p_order text, p_card bigint)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  o public.ticket_package_orders%rowtype; v_title text; v_rows jsonb := '[]'::jsonb; r record;
  v_total bigint := 0; v_n int := 0; v_live int := 0; v_mem bigint; v_gen bigint; v_rm bigint; v_rg bigint;
  v_dep_left bigint; v_dep bigint; v_m bigint; v_g bigint; v_card bigint; v_after bigint; v_i int := 0;
begin
  select * into o from public.ticket_package_orders where id = p_group for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
  if o.user_id is distinct from p_uid then raise exception '내 예약이 아닙니다' using errcode = '42501'; end if;
  if o.status = 'paid' then
    -- 같은 결제로 다시 부른 것만 「이미」 — 다른 길(예치금 · 다른 주문)로 이미 낸 묶음에 늦게 온 카드 승인은 거절(Edge 가 그 카드를 취소한다)
    if (p_order is null and o.card_paid = 0) or (p_order is not null and o.order_id = p_order and o.card_paid > 0) then
      return jsonb_build_object('ok', true, 'already', true, 'group_id', o.id, 'total', o.total);
    end if;
    raise exception 'ORDER_SUPERSEDED: 이미 다른 결제로 확정된 패키지입니다' using errcode = 'P0002';
  end if;
  if o.status <> 'hold' then raise exception 'GROUP_CLOSED: 결제를 이어갈 수 없는 주문입니다 (상태 %)', o.status using errcode = 'P0002'; end if;
  select title into v_title from public.ticket_packages where id = o.package_id and status = 'active';
  if not found then raise exception 'PACKAGE_NOT_ACTIVE: 판매가 끝난 패키지입니다' using errcode = 'P0002'; end if;
  if (select count(*) from public.ticket_package_rounds pr where pr.package_id = o.package_id) <> coalesce(array_length(o.purchase_ids, 1), 0) then
    raise exception 'PACKAGE_CHANGED: 패키지 구성이 바뀌었습니다' using errcode = 'P0002';
  end if;
  perform 1 from public.tickets t where t.purchase_id = any(o.purchase_ids) order by t.purchase_id for update;
  for r in select * from public._taam_pkg_rows(p_group) loop
    v_n := v_n + 1;
    if r.status <> 'hold' then raise exception 'HOLD_GONE: 좌석 확보가 만료되었습니다 — 다시 시도해 주세요' using errcode = 'P0002'; end if;
    if r.user_id is distinct from p_uid or r.party_size <> o.pax then raise exception 'HOLDS_MISMATCH' using errcode = '22023'; end if;
    if not exists (select 1 from public.ticket_package_rounds pr where pr.package_id = o.package_id and pr.ticket_product_id = r.ticket_product_id) then
      raise exception 'PACKAGE_CHANGED: 패키지 구성이 바뀌었습니다' using errcode = 'P0002';
    end if;
    if r.price is null or r.price <= 0 then raise exception 'PRICE_NOT_SET' using errcode = '22023'; end if;
    if public._taam_pkg_round_closed(r.ticket_product_id::text) then   -- 결제 사이 어드민이 손으로 잠갔다(앱 밖 판매) — 카드 확정이면 Edge 가 취소
      raise exception 'ROUND_CLOSED: 지금 판매하지 않는 일정이 있습니다' using errcode = '22023';
    end if;
    v_total := v_total + r.price;
  end loop;
  if v_n <> coalesce(array_length(o.purchase_ids, 1), 0) then raise exception 'HOLD_GONE: 좌석 확보를 찾지 못했습니다' using errcode = 'P0002'; end if;
  if p_expect is not null and p_expect <> v_total then
    raise exception 'PRICE_CHANGED: 금액이 바뀌었습니다 (화면 %원 · 현재 %원)', p_expect, v_total using errcode = '22023';
  end if;
  if coalesce(p_dep_want, 0) + coalesce(p_card, 0) <> v_total then
    raise exception 'PRICE_CHANGED: 결제 금액이 맞지 않습니다 (예치금 % + 카드 % ≠ %)', coalesce(p_dep_want, 0), coalesce(p_card, 0), v_total using errcode = '22023';
  end if;

  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0) into v_mem, v_gen
    from public.profiles where id = p_uid for update;
  if not found then raise exception '회원 정보를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if v_mem + v_gen < coalesce(p_dep_want, 0) then
    raise exception 'INSUFFICIENT_DEPOSIT: 예치금이 부족합니다 (잔액 %원 · 필요 %원)', v_mem + v_gen, p_dep_want using errcode = '22023';
  end if;
  v_rm := least(v_mem, coalesce(p_dep_want, 0)); v_rg := coalesce(p_dep_want, 0) - v_rm;   -- 멤버십 먼저
  update public.profiles set membership_deposit_balance = v_mem - v_rm, general_deposit_balance = v_gen - v_rg where id = p_uid;
  v_after := (v_mem + v_gen) - coalesce(p_dep_want, 0);

  perform set_config('taam.pkg_confirm', p_group, true);
  v_dep_left := coalesce(p_dep_want, 0);
  for r in select * from public._taam_pkg_rows(p_group) loop
    v_i := v_i + 1;
    v_dep := least(r.price, v_dep_left); v_dep_left := v_dep_left - v_dep;
    v_m := least(v_dep, v_rm); v_rm := v_rm - v_m; v_g := v_dep - v_m; v_rg := v_rg - v_g;
    v_card := r.price - v_dep;
    if v_m > 0 then
      insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata)
      values (p_uid, 'membership', 'ticket_purchase', -v_m, v_after,
              coalesce(r.rest_name, '티켓') || ' 패키지 「' || v_title || '」 ' || o.pax || '인 (멤버십 예치금)',
              jsonb_build_object('purchase_id', r.purchase_id, 'ticket_id', r.ticket_product_id, 'restaurant_id', r.rest_id, 'restaurant_name', r.rest_name,
                                 'party_size', o.pax, 'payment_method', case when p_order is null then 'deposit_only' else 'card+deposit' end,
                                 'portion', 'membership', 'server_confirmed', true, 'package_id', o.package_id, 'package_order', p_group, 'order_id', p_order));
    end if;
    if v_g > 0 then
      insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata)
      values (p_uid, 'general', 'ticket_purchase', -v_g, v_after,
              coalesce(r.rest_name, '티켓') || ' 패키지 「' || v_title || '」 ' || o.pax || '인 (일반 예치금)',
              jsonb_build_object('purchase_id', r.purchase_id, 'ticket_id', r.ticket_product_id, 'restaurant_id', r.rest_id, 'restaurant_name', r.rest_name,
                                 'party_size', o.pax, 'payment_method', case when p_order is null then 'deposit_only' else 'card+deposit' end,
                                 'portion', 'general', 'server_confirmed', true, 'package_id', o.package_id, 'package_order', p_group, 'order_id', p_order));
    end if;
    update public.tickets
       set status = 'active', price = r.price,
           extra_data = coalesce(extra_data, '{}'::jsonb) - 'seatHold'
                        || jsonb_build_object('pkg', o.package_id,
                                              'pkg_info', jsonb_build_object('gid', p_group, 'title', v_title, 'i', v_i, 'n', v_n),
                                              'server_confirmed', true, 'confirmed_at', now(), 'agencyFee', r.agency_per)
                        || case when p_order is null then jsonb_build_object('paidBy', 'deposit', 'depositUsed', v_dep)
                                else jsonb_build_object('paidBy', case when v_dep > 0 then 'card+deposit' else 'card' end,
                                                        'depositUsed', v_dep, 'cardPaid', v_card)
                                     || case when v_card > 0 then jsonb_build_object('order_id', p_order) else '{}'::jsonb end end
     where purchase_id = r.purchase_id;
    v_rows := v_rows || jsonb_build_object('purchase_id', r.purchase_id, 'ticket_product_id', r.ticket_product_id, 'rest_id', r.rest_id,
                                           'rest_name', r.rest_name, 'date', r.vdate, 'time', r.vtime, 'price', r.price, 'agency_per', r.agency_per,
                                           'dep', v_dep, 'mem', v_m, 'gen', v_g, 'card', v_card);
  end loop;
  perform set_config('taam.pkg_confirm', '', true);
  update public.ticket_package_orders
     set status = 'paid', items = v_rows, total = v_total, deposit_used = coalesce(p_dep_want, 0), card_paid = coalesce(p_card, 0),
         order_id = p_order, paid_at = now(), updated_at = now()   -- 예치금만이면 null — 결제창에 남은 옛 카드 주문이 이 묶음을 「이미 낸」 것으로 잡지 못하게
   where id = p_group;
  return jsonb_build_object('ok', true, 'group_id', p_group, 'total', v_total, 'deposit_used', coalesce(p_dep_want, 0), 'card_paid', coalesce(p_card, 0),
                            'balance_after', v_after, 'rows', v_rows, 'title', v_title);
end $$;
revoke all on function public._taam_pkg_confirm(text, uuid, bigint, bigint, text, bigint) from public, anon, authenticated;

create or replace function public.taam_package_confirm_deposit(p_group text, p_expect bigint)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  if p_expect is null or p_expect <= 0 then raise exception '결제 금액이 올바르지 않습니다' using errcode = '22023'; end if;
  return public._taam_pkg_confirm(p_group, auth.uid(), p_expect, p_expect, null, 0);
end $$;

-- 회원 — 내 패키지 홀드 반납(시도 묶음 또는 패키지 회차의 내 홀드 전부)
create or replace function public.taam_package_release(p_group text default null, p_package text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_n int := 0; v_pids text[] := '{}';
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  if p_group is not null then
    select purchase_ids into v_pids from public.ticket_package_orders where id = p_group and user_id = v_uid and status = 'hold';
    update public.ticket_package_orders set status = 'failed', fail_reason = 'released', updated_at = now()
     where id = p_group and user_id = v_uid and status = 'hold';
  end if;
  update public.tickets set status = 'cancelled'
   where user_id = v_uid and status = 'hold' and purchase_id like 'PAYH-%'
     and (purchase_id = any(coalesce(v_pids, '{}'))
          or (p_package is not null and coalesce(extra_data->>'pkg', '') = p_package));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'released', v_n);
end $$;
revoke all on function public.taam_package_start(text, int, text[], bigint), public.taam_package_confirm_deposit(text, bigint),
                       public.taam_package_release(text, text) from public, anon;
grant execute on function public.taam_package_start(text, int, text[], bigint), public.taam_package_confirm_deposit(text, bigint),
                          public.taam_package_release(text, text) to authenticated;
insert into _pk values ('F 회원 함수(홀드 등록 · 예치금 확정 · 반납)', '✅');

-- ── G. 서버(Edge toss-package-pay) — 카드 주문 · 카드 확정 · 실패 ──
create or replace function public.taam_package_order_prepare(p_group text, p_uid uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  o public.ticket_package_orders%rowtype; v_title text; r record; v_total bigint := 0; v_n int := 0;
  v_mem bigint; v_gen bigint; v_dep bigint; v_card bigint; v_oid text;
begin
  if not public._taam_pkg_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into o from public.ticket_package_orders where id = p_group for update;
  if not found or o.user_id is distinct from p_uid then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
  if o.status <> 'hold' then raise exception 'GROUP_CLOSED: 결제를 이어갈 수 없는 주문입니다 (상태 %)', o.status using errcode = 'P0002'; end if;
  -- 주문 만들기마다 좌석 시간을 다시 재므로 끝없이 붙들 수 없게 — 묶음은 20분까지 · 회원마다 시간당 30번(적대 리뷰)
  if o.created_at < now() - interval '20 minutes' then raise exception 'HOLD_GONE: 좌석 확보 시간이 지났습니다' using errcode = 'P0002'; end if;
  if to_regprocedure('public.taam_rate_hit(text, integer, interval)') is not null then   -- 함수가 없는 DB 에서 식을 통째로 못 읽지 않게 따로
    if not public.taam_rate_hit('pkg_prepare:' || p_uid::text, 30, interval '1 hour') then
      raise exception 'RATE_LIMITED: 잠시 뒤 다시 시도해 주세요' using errcode = '42501';
    end if;
  end if;
  select title into v_title from public.ticket_packages where id = o.package_id and status = 'active';
  if not found then raise exception 'PACKAGE_NOT_ACTIVE' using errcode = 'P0002'; end if;
  for r in select * from public._taam_pkg_rows(p_group) loop
    v_n := v_n + 1;
    if r.status <> 'hold' or r.user_id is distinct from p_uid then raise exception 'HOLD_GONE: 좌석 확보가 만료되었습니다' using errcode = 'P0002'; end if;
    if r.price is null or r.price <= 0 then raise exception 'PRICE_NOT_SET' using errcode = '22023'; end if;
    if public._taam_pkg_round_closed(r.ticket_product_id::text) then   -- 결제 사이 어드민이 손으로 잠갔다(앱 밖 판매) — 카드 확정이면 Edge 가 취소
      raise exception 'ROUND_CLOSED: 지금 판매하지 않는 일정이 있습니다' using errcode = '22023';
    end if;
    v_total := v_total + r.price;
  end loop;
  if v_n <> coalesce(array_length(o.purchase_ids, 1), 0) then raise exception 'HOLD_GONE' using errcode = 'P0002'; end if;
  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0) into v_mem, v_gen from public.profiles where id = p_uid;
  v_dep := least(coalesce(v_mem, 0) + coalesce(v_gen, 0), v_total);
  v_card := v_total - v_dep;
  if v_card <= 0 then return jsonb_build_object('ok', true, 'need_payment', false, 'total', v_total); end if;
  if v_card < 100 then   -- 토스 최소 금액 — 예치금을 그만큼 덜 쓴다
    v_card := least(100, v_total); v_dep := v_total - v_card;
  end if;
  v_oid := 'taampkg_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || (floor(random() * 100000))::int;
  -- 같은 묶음의 결제 안 된 옛 주문은 닫는다(카드창을 두 번 열어 두 번 결제되지 않게 — 늦게 돌아온 옛 승인은 확정에서 거절되고 Edge 가 취소한다)
  update public.payment_orders set status = 'failed', fail_reason = 'superseded'
   where purpose = 'package_topup' and status = 'pending' and user_id = p_uid and metadata->>'group_id' = p_group;
  insert into public.payment_orders(order_id, user_id, purpose, amount, currency, settle_krw, status, metadata)
  values (v_oid, p_uid, 'package_topup', v_card, 'KRW', v_card, 'pending',
          jsonb_build_object('group_id', p_group, 'package_id', o.package_id, 'title', v_title, 'pax', o.pax, 'total', v_total,
                             'deposit_used', v_dep, 'balance_at_order', coalesce(v_mem, 0) + coalesce(v_gen, 0),
                             'purchase_ids', to_jsonb(o.purchase_ids)));
  update public.ticket_package_orders set order_id = v_oid, expires_at = greatest(expires_at, now() + interval '15 minutes'), updated_at = now() where id = p_group;
  -- 카드창 왕복 동안 좌석을 붙든다 — 5분 만료(created_at 기준)를 지금부터 다시
  update public.tickets set created_at = now() where purchase_id = any(o.purchase_ids) and status = 'hold';
  return jsonb_build_object('ok', true, 'need_payment', true, 'order_id', v_oid, 'amount', v_card, 'total', v_total, 'deposit_used', v_dep,
                            'title', v_title);
end $$;

-- 토스 승인 뒤 주문을 paid 로 — 한 문장(metadata 를 덮지 않고 합친다 · pending 일 때만 · 확정 표시 pkg_claim). 못 잡으면 지금 상태를 돌려준다
create or replace function public.taam_package_order_claim(p_order text, p_payment_key text, p_method text, p_receipt text, p_approved_at timestamptz,
                                                           p_toss jsonb, p_paid_via text, p_billing_key_id text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_st text; v_n int;
begin
  if not public._taam_pkg_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.payment_orders
     set status = 'paid', payment_key = p_payment_key, method = left(p_method, 40), receipt_url = left(p_receipt, 400),
         approved_at = coalesce(p_approved_at, now()),
         metadata = coalesce(metadata, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('toss', p_toss, 'paid_via', p_paid_via,
                      'billing_key_id', p_billing_key_id, 'pkg_claim', 'toss-package-pay'))
   where order_id = p_order and purpose = 'package_topup' and status = 'pending';
  get diagnostics v_n = row_count;
  select status into v_st from public.payment_orders where order_id = p_order;
  return jsonb_build_object('claimed', v_n = 1, 'status', v_st);
end $$;

-- 확정이 분명히 거절된 카드 주문을 닫는다 — **Toss 승인 취소 전에**. 주문 줄을 잠그고(확정 함수와 같은 순서 — 먼저 주문) 묶음이
--   이 주문으로 이미 확정·취소됐으면 닫지 않는다(settled). 닫힌 주문은 확정 함수가 ORDER_NOT_PAID 로 거절하므로
--   「취소하는 사이 다른 호출이 확정」하는 경주가 없다(적대 리뷰 2차). 취소 결과는 Edge 가 fail_reason 에 이어 적는다.
create or replace function public.taam_package_order_close(p_order text, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare po public.payment_orders%rowtype; v_st text; v_oid text;
begin
  if not public._taam_pkg_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into po from public.payment_orders where order_id = p_order and purpose = 'package_topup' for update;
  if not found then return jsonb_build_object('closed', false, 'status', null); end if;
  select status, order_id into v_st, v_oid from public.ticket_package_orders where id = po.metadata->>'group_id';
  if v_st in ('paid', 'cancelled') and v_oid = p_order then
    return jsonb_build_object('closed', false, 'settled', v_st, 'status', po.status);
  end if;
  if po.status <> 'paid' then return jsonb_build_object('closed', false, 'status', po.status); end if;
  update public.payment_orders set status = 'canceled', fail_reason = left(coalesce(p_reason, 'closed'), 60) || '_canceling' where order_id = p_order;
  return jsonb_build_object('closed', true, 'status', 'canceled');
end $$;

create or replace function public.taam_package_confirm_card(p_order text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare po public.payment_orders%rowtype; v_gid text; v_st text;
begin
  if not public._taam_pkg_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into po from public.payment_orders where order_id = p_order for update;
  if not found or po.purpose <> 'package_topup' then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  if po.status <> 'paid' then raise exception 'ORDER_NOT_PAID' using errcode = 'P0002'; end if;
  v_gid := po.metadata->>'group_id';
  if not exists (select 1 from public.ticket_package_orders o where o.id = v_gid and o.order_id = p_order) then
    raise exception 'ORDER_SUPERSEDED: 이 결제는 지금 주문이 아닙니다' using errcode = 'P0002';
  end if;
  -- 이 결제로 이미 확정된 묶음(결제됨 · 그 뒤 취소됨)은 다시 불러도 「이미」 — 오류로 돌리면 Edge 가 카드를 전액 취소해 환불 규정을 비켜 간다(적대 리뷰)
  select status into v_st from public.ticket_package_orders where id = v_gid;
  if v_st in ('paid', 'cancelled') then
    return jsonb_build_object('ok', true, 'already', true, 'group_id', v_gid, 'status', v_st);
  end if;
  return public._taam_pkg_confirm(v_gid, po.user_id, (po.metadata->>'total')::bigint,
                                  (po.metadata->>'deposit_used')::bigint, p_order, coalesce(po.settle_krw, po.amount));
end $$;

create or replace function public.taam_package_fail(p_group text, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_pids text[]; v_n int := 0;
begin
  if not public._taam_pkg_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.ticket_package_orders set status = 'failed', fail_reason = left(coalesce(p_reason, 'failed'), 200), updated_at = now()
   where id = p_group and status = 'hold' returning purchase_ids into v_pids;
  if v_pids is not null then
    update public.tickets set status = 'cancelled' where purchase_id = any(v_pids) and status = 'hold';
    get diagnostics v_n = row_count;
  end if;
  return jsonb_build_object('ok', true, 'released', v_n);
end $$;
revoke all on function public.taam_package_order_prepare(text, uuid), public.taam_package_confirm_card(text), public.taam_package_fail(text, text),
                       public.taam_package_order_claim(text, text, text, text, timestamptz, jsonb, text, text), public.taam_package_order_close(text, text)
  from public, anon, authenticated;
insert into _pk values ('G 서버 함수(카드 주문 · 카드 확정 · 실패) — service_role 만', '✅');

-- ── H. 취소 — 통째로 · 회차마다 규정 · 예치금 먼저 ──
create or replace function public._taam_pkg_quote(p_group text, p_full boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
-- 줄마다 따로 센다(적대 리뷰 2026-10-29 — 패키지 단위 「예치금 먼저」가 환불을 다른 회차로 옮겨 매장별 판매·대행비·파트너 화면이 틀렸다):
--   그 줄의 환불액 = 그 줄의 지금 규정(결제 30분 안 전액 · 방문 D-31 이상 정가 − 대행비×인원 · 그 뒤 0 · 슈퍼어드민 전액) · 그 줄에 남은 돈(예치금 − 이미 돌려준 것 + 카드 몫) 이하
--   그 줄 안에서 예치금 먼저, 남으면 그 줄의 카드 몫. 패키지 합계는 줄의 합. 살아 있지 않은 줄(운영이 따로 처리한 줄)은 0.
--   방문일은 지금 회차 날짜(없으면 산 때의 날짜) · 어느 회차든 방문일이 지났거나 오늘이면(결제 30분 안의 오늘은 빼고) 회원은 못 취소 · 방문·노쇼 처리된 줄이 있어도.
declare
  o public.ticket_package_orders%rowtype; it jsonb; v_rows jsonb := '[]'::jsonb; v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_ref bigint; v_pol text; v_d date; v_days int; v_block text := null; v_st text; v_in30 boolean;
  v_paid bigint; v_back bigint; v_dep_rem bigint; v_card_rem bigint; v_dep_i bigint; v_card_i bigint;
  v_sum_dep bigint := 0; v_sum_card bigint := 0;
begin
  select * into o from public.ticket_package_orders where id = p_group;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
  v_in30 := o.paid_at is not null and o.paid_at > now() - interval '30 minutes';
  for it in select * from jsonb_array_elements(o.items) loop
    select lower(coalesce(t.status, '')) into v_st from public.tickets t where t.purchase_id = it->>'purchase_id';
    v_d := coalesce(public._taam_pkg_visit(it->>'ticket_product_id'), public._taam_pu_visit_date(it->>'date'));
    v_days := case when v_d is null then null else v_d - v_today end;
    if v_days is not null and (v_days < 0 or (v_days = 0 and not v_in30)) then v_block := coalesce(v_block, 'VISIT_STARTED'); end if;
    if v_st is not null and v_st not in ('active', 'cancelled', 'canceled') then v_block := coalesce(v_block, 'ROUND_DONE'); end if;
    select coalesce(sum(abs(amount)) filter (where change_type = 'ticket_purchase' and amount < 0), 0),
           coalesce(sum(amount) filter (where change_type in ('ticket_refund', 'ticket_pax_change') and amount > 0), 0)
      into v_paid, v_back
      from public.deposit_transactions where user_id = o.user_id and metadata->>'purchase_id' = it->>'purchase_id';
    v_dep_rem := greatest(0, v_paid - v_back);
    v_card_rem := greatest(0, coalesce((it->>'card')::bigint, 0));
    if v_st is distinct from 'active' then v_ref := 0; v_pol := 'not_active';
    elsif p_full then v_ref := v_dep_rem + v_card_rem; v_pol := 'super_admin';
    elsif v_in30 then v_ref := (it->>'price')::bigint; v_pol := 'within_30min';
    elsif v_days is not null and v_days >= 31 then
      v_ref := greatest(0, (it->>'price')::bigint - coalesce((it->>'agency_per')::bigint, 0) * o.pax); v_pol := 'agency_excluded';
    else v_ref := 0; v_pol := 'no_refund';
    end if;
    v_ref := least(v_ref, v_dep_rem + v_card_rem);
    v_dep_i := least(v_ref, v_dep_rem);
    v_card_i := v_ref - v_dep_i;
    v_sum_dep := v_sum_dep + v_dep_i; v_sum_card := v_sum_card + v_card_i;
    v_rows := v_rows || jsonb_build_object('purchase_id', it->>'purchase_id', 'ticket_product_id', it->>'ticket_product_id', 'rest_name', it->>'rest_name',
                                           'date', coalesce(to_char(v_d, 'YYYY.MM.DD'), it->>'date'), 'time', it->>'time',
                                           'price', (it->>'price')::bigint, 'refund', v_ref, 'dep_refund', v_dep_i, 'card_refund', v_card_i,
                                           'policy', v_pol, 'days', v_days, 'status', v_st);
  end loop;
  return jsonb_build_object('ok', true, 'group_id', o.id, 'status', o.status, 'pax', o.pax, 'total', o.total,
                            'deposit_used', o.deposit_used, 'card_paid', o.card_paid, 'refund', v_sum_dep + v_sum_card,
                            'deposit_refund', v_sum_dep, 'card_refund', least(v_sum_card, o.card_paid), 'within_30min', v_in30,
                            'cancellable', o.status = 'paid' and (p_full or v_block is null), 'block', v_block, 'rows', v_rows);
end $$;
revoke all on function public._taam_pkg_quote(text, boolean) from public, anon, authenticated;

create or replace function public.taam_package_cancel_quote(p_group text, p_full boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid; v_super boolean := coalesce(public.is_super_admin(auth.uid()), false);
begin
  select user_id into v_owner from public.ticket_package_orders where id = p_group;
  if v_owner is null then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
  if auth.uid() is null or (auth.uid() <> v_owner and not v_super) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return public._taam_pkg_quote(p_group, p_full and v_super);
end $$;

create or replace function public.taam_package_cancel(p_group text, p_expect_refund bigint, p_reason text default null, p_full boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_super boolean := coalesce(public.is_super_admin(auth.uid()), false);
  o public.ticket_package_orders%rowtype; q jsonb; rw jsonb;
  v_m_out bigint; v_g_out bigint; v_m bigint; v_g bigint; v_mem bigint; v_gen bigint; v_tm bigint := 0; v_tg bigint := 0; v_first text := null;
  v_title text; v_by text; v_alloc jsonb := '{}'::jsonb; v_take bigint;
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  select * into o from public.ticket_package_orders where id = p_group for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_uid <> o.user_id and not v_super then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if o.status <> 'paid' then raise exception 'GROUP_CLOSED: 이미 취소됐거나 결제되지 않은 패키지입니다' using errcode = 'P0002'; end if;
  if char_length(coalesce(p_reason, '')) > 200 or not public._taam_pkg_text_ok(p_reason) then raise exception 'BAD_INPUT' using errcode = '22023'; end if;
  perform 1 from public.tickets t where t.purchase_id = any(o.purchase_ids) order by t.purchase_id for update;
  q := public._taam_pkg_quote(p_group, p_full and v_super);
  if not (q->>'cancellable')::boolean then
    raise exception 'PACKAGE_CANCEL_CLOSED: 이미 방문이 시작된 패키지입니다 — TAAM 에 문의해 주세요 (%)', q->>'block' using errcode = '42501';
  end if;
  if p_expect_refund is not null and p_expect_refund <> (q->>'refund')::bigint then
    raise exception 'REFUND_CHANGED: 환불 금액이 바뀌었습니다 (화면 %원 · 현재 %원)', p_expect_refund, q->>'refund' using errcode = '22023';
  end if;
  select title into v_title from public.ticket_packages where id = o.package_id;
  v_by := case when v_uid = o.user_id then 'member' else 'super_admin' end;
  -- 줄마다 몫(견적이 줄마다 센 것 그대로) — 카드 환불 대기·패키지 환불 요약을 둘 줄은 카드 몫이 있는 첫 줄(그 줄에 주문 번호가 있다)
  for rw in select * from jsonb_array_elements(q->'rows') loop
    v_alloc := v_alloc || jsonb_build_object(rw->>'purchase_id', jsonb_build_object('dep', coalesce((rw->>'dep_refund')::bigint, 0), 'card', coalesce((rw->>'card_refund')::bigint, 0)));
  end loop;
  select x.v->>'purchase_id' into v_first from jsonb_array_elements(q->'rows') with ordinality x(v, i)
   where x.v->>'status' = 'active'
   order by (coalesce((x.v->>'card_refund')::bigint, 0) > 0) desc, x.i limit 1;

  perform set_config('taam.pkg_cancel', p_group, true);
  for rw in select * from jsonb_array_elements(q->'rows') loop
    if rw->>'status' <> 'active' then continue; end if;
    update public.tickets
       set status = 'cancelled',
           extra_data = coalesce(extra_data, '{}'::jsonb)
                        || jsonb_build_object('cancelled_at', now(), 'refunded_amount', (rw->>'refund')::bigint, 'cancel_reason', coalesce(nullif(p_reason, ''), '패키지 취소'),
                                              'cancelled_by_role', v_by, 'pkg_cancel', p_group, 'refund_policy', rw->>'policy',
                                              'deposit_refund', coalesce((rw->>'dep_refund')::bigint, 0),
                                              'pkg_card_refund', coalesce((rw->>'card_refund')::bigint, 0))
                        || case when rw->>'purchase_id' = v_first
                                then jsonb_build_object('pkg_refund', jsonb_build_object('refund', (q->>'refund')::bigint, 'deposit_refund', (q->>'deposit_refund')::bigint,
                                                                                       'card_refund', (q->>'card_refund')::bigint, 'rows', jsonb_array_length(q->'rows')))
                                     || case when (q->>'card_refund')::bigint > 0
                                             then jsonb_build_object('card_refund_pending', jsonb_build_object(
                                                    'amount', (q->>'card_refund')::bigint, 'order_id', o.order_id, 'pkg_group', p_group,
                                                    'reason', '패키지 「' || coalesce(v_title, '') || '」 취소', 'requested_at', now(), 'status', 'pending'))
                                             else '{}'::jsonb end
                                else '{}'::jsonb end
     where purchase_id = rw->>'purchase_id' and lower(coalesce(status, '')) = 'active';
  end loop;

  -- 예치금 환불 원장 — 줄마다 그 줄의 몫만 · 그 줄에서 나간 주머니 비율로
  if (q->>'deposit_refund')::bigint > 0 then
    select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0) into v_mem, v_gen from public.profiles where id = o.user_id for update;
    for rw in select * from jsonb_array_elements(q->'rows') loop
      v_take := coalesce((rw->>'dep_refund')::bigint, 0);
      if v_take <= 0 then continue; end if;
      select coalesce(sum(abs(amount)) filter (where change_type = 'ticket_purchase' and amount < 0 and deposit_type = 'membership'), 0),
             coalesce(sum(abs(amount)) filter (where change_type = 'ticket_purchase' and amount < 0 and deposit_type <> 'membership'), 0)
        into v_m_out, v_g_out
        from public.deposit_transactions where user_id = o.user_id and metadata->>'purchase_id' = rw->>'purchase_id';
      v_m := case when v_m_out + v_g_out > 0 then least(v_take, round(v_take::numeric * v_m_out / (v_m_out + v_g_out))::bigint) else v_take end;
      v_g := v_take - v_m;
      v_tm := v_tm + v_m; v_tg := v_tg + v_g;
      if v_m > 0 then
        insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata)
        values (o.user_id, 'membership', 'ticket_refund', v_m, v_mem + v_gen + v_tm + v_tg,
                coalesce(rw->>'rest_name', '티켓') || ' 패키지 「' || coalesce(v_title, '') || '」 취소 환불(멤버십 예치금)',
                jsonb_build_object('purchase_id', rw->>'purchase_id', 'ticket_id', rw->>'ticket_product_id', 'package_order', p_group, 'package_id', o.package_id,
                                   'refund_type', 'returned', 'cancel_refund', true, 'cancelled_by', v_by, 'policy', rw->>'policy'));
      end if;
      if v_g > 0 then
        insert into public.deposit_transactions(user_id, deposit_type, change_type, amount, balance_after, description, metadata)
        values (o.user_id, 'general', 'ticket_refund', v_g, v_mem + v_gen + v_tm + v_tg,
                coalesce(rw->>'rest_name', '티켓') || ' 패키지 「' || coalesce(v_title, '') || '」 취소 환불(일반 예치금)',
                jsonb_build_object('purchase_id', rw->>'purchase_id', 'ticket_id', rw->>'ticket_product_id', 'package_order', p_group, 'package_id', o.package_id,
                                   'refund_type', 'returned', 'cancel_refund', true, 'cancelled_by', v_by, 'policy', rw->>'policy'));
      end if;
    end loop;
    update public.profiles set membership_deposit_balance = v_mem + v_tm, general_deposit_balance = v_gen + v_tg where id = o.user_id;
  end if;
  perform set_config('taam.pkg_cancel', '', true);

  update public.ticket_package_orders
     set status = 'cancelled', cancelled_at = now(), updated_at = now(),
         cancel = jsonb_build_object('at', now(), 'by', v_uid, 'role', v_by, 'reason', p_reason, 'refund', q->'refund',
                                     'deposit_refund', v_tm + v_tg, 'card_refund', q->'card_refund', 'full', p_full and v_super, 'rows', q->'rows',
                                     'alloc', v_alloc),
         card_refund = case when (q->>'card_refund')::bigint > 0
                            then jsonb_build_object('amount', (q->>'card_refund')::bigint, 'order_id', o.order_id, 'status', 'pending',
                                                    'requested_at', now(), 'first_purchase_id', v_first)
                            else null end
   where id = p_group;
  return jsonb_build_object('ok', true, 'group_id', p_group, 'refund', q->'refund', 'deposit_refund', v_tm + v_tg, 'card_refund', q->'card_refund',
                            'first_purchase_id', v_first, 'title', v_title, 'rows', q->'rows');
end $$;
revoke all on function public.taam_package_cancel_quote(text, boolean), public.taam_package_cancel(text, bigint, text, boolean) from public, anon;
grant execute on function public.taam_package_cancel_quote(text, boolean), public.taam_package_cancel(text, bigint, text, boolean) to authenticated;
insert into _pk values ('H 취소(견적 · 통째로 취소 · 예치금 먼저 · 카드 몫은 환불 대기)', '✅');

-- ── I. 카드 환불 — 견적 · 완료 표시(슈퍼어드민·서버) ──
create or replace function public.taam_package_card_refund_quote(p_group text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o public.ticket_package_orders%rowtype; po public.payment_orders%rowtype;
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into o from public.ticket_package_orders where id = p_group;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
  if o.card_refund is null or o.card_refund->>'status' <> 'pending' then
    return jsonb_build_object('ok', false, 'error', case when o.card_refund->>'status' = 'done' then 'already_done' else 'no_pending' end);
  end if;
  select * into po from public.payment_orders where order_id = o.order_id;
  if not found or po.status <> 'paid' or coalesce(po.payment_key, '') = '' then return jsonb_build_object('ok', false, 'error', 'order_not_paid'); end if;
  return jsonb_build_object('ok', true, 'group_id', o.id, 'order_id', o.order_id, 'payment_key', po.payment_key, 'amount', (o.card_refund->>'amount')::bigint,
                            'card_paid', o.card_paid, 'paid_via', po.metadata->>'paid_via', 'user_id', o.user_id,
                            'first_purchase_id', o.card_refund->>'first_purchase_id');
end $$;

create or replace function public.taam_package_card_refund_mark(p_group text, p_amount bigint, p_tx text default null, p_via text default 'manual')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare o public.ticket_package_orders%rowtype; v_first text; v_amt bigint;
begin
  if not public._taam_pkg_super_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into o from public.ticket_package_orders where id = p_group for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
  if o.card_refund is null or o.card_refund->>'status' <> 'pending' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  v_first := o.card_refund->>'first_purchase_id';
  -- 적는 금액은 묶음 기록의 대기 금액 이하(화면이 보낸 값을 그대로 믿지 않는다)
  v_amt := least(greatest(coalesce(p_amount, (o.card_refund->>'amount')::bigint), 0), coalesce((o.card_refund->>'amount')::bigint, 0));
  update public.ticket_package_orders
     set card_refund = card_refund || jsonb_build_object('status', 'done', 'done_at', now(), 'done_by', auth.uid(), 'via', left(coalesce(p_via, 'manual'), 20),
                                                         'refunded_amount', v_amt, 'toss_tx', p_tx),
         updated_at = now()
   where id = p_group;
  if v_first is not null then
    update public.tickets
       set extra_data = jsonb_set(coalesce(extra_data, '{}'::jsonb), '{card_refund_pending}',
                                  coalesce(extra_data->'card_refund_pending', '{}'::jsonb)
                                  || jsonb_build_object('status', 'done', 'refunded_at', now(), 'refunded_amount', v_amt,
                                                        'via', left(coalesce(p_via, 'manual'), 20), 'toss_tx', p_tx))
     where purchase_id = v_first;
  end if;
  if o.order_id is not null and v_amt > 0 then
    update public.payment_orders
       set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('app_cancels',
             coalesce(metadata->'app_cancels', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
               'at', now(), 'amount', v_amt, 'via', left(coalesce(p_via, 'manual'), 20), 'package_order', p_group,
               'purchase_id', v_first, 'tx', p_tx, 'by', auth.uid(), 'policy', 'package')))   -- toss-card-refund 와 같은 모양(결제 내역이 대기 완료와 같은 건으로 맞춘다)
     where order_id = o.order_id;
  end if;
  return jsonb_build_object('ok', true, 'group_id', p_group, 'first_purchase_id', v_first, 'user_id', o.user_id, 'amount', v_amt);
end $$;
revoke all on function public.taam_package_card_refund_quote(text), public.taam_package_card_refund_mark(text, bigint, text, text) from public, anon;
grant execute on function public.taam_package_card_refund_quote(text), public.taam_package_card_refund_mark(text, bigint, text, text) to authenticated;
insert into _pk values ('I 카드 환불(견적 · 완료 표시)', '✅');

-- ── J. 취소표(재입고) 알림 — 연계 회차는 단일로 못 사므로 「자리 났다」 푸시를 보내지 않는다(적대 리뷰) ──
do $do$ begin
  if to_regclass('public.ticket_restock_events') is null then insert into _pk values ('J 재입고 알림', '⚠ 표 없음 — 건너뜀'); return; end if;
  execute $f$
    create or replace function public.taam_restock_skip_package() returns trigger language plpgsql security definer set search_path = public as $b$
    begin
      -- 줄을 아예 넣지 않는다 — skipped 로 남기면 쿨다운(60분)에 걸려 연계를 푼 뒤 첫 취소표 알림까지 막힌다
      if coalesce(new.status, 'pending') = 'pending' and exists (
           select 1 from public.ticket_package_rounds r join public.ticket_packages p on p.id = r.package_id and p.status = 'active'
            where r.ticket_product_id = new.ticket_product_id) then
        return null;
      end if;
      return new;
    end $b$;
  $f$;
  execute 'revoke all on function public.taam_restock_skip_package() from public, anon, authenticated';
  execute 'drop trigger if exists trg_taam_restock_skip_package on public.ticket_restock_events';
  execute 'create trigger trg_taam_restock_skip_package before insert on public.ticket_restock_events for each row execute function public.taam_restock_skip_package()';
  insert into _pk values ('J 연계 회차는 취소표 알림을 건너뛴다', '✅');
end $do$;

-- ── K. 결과를 모르는 카드 주문 정리 — 10분마다 Edge toss-package-pay 의 sweep(service_role) ──
--   카드 승인은 됐는데 좌석 확정 결과를 모르는 주문(Edge 가 중간에 끊김 · 회원이 앱을 다시 안 엶)이 그대로 남지 않게:
--   paid 인데 묶음이 이 주문으로 확정되지 않은 것 → 확정을 다시(안 되면 분명한 거절로 자동 취소) · 10분 넘은 pending → 토스에 주문 번호로 조회 ·
--   취소가 실패했던(_refund_failed) · 취소 도중 끊긴(_canceling) 주문 → 같은 멱등 키로 다시 취소. 볼 것이 없으면 Edge 를 부르지 않는다.
--   부르는 법은 taam_admin_push 와 같다(app_config.restock_push 의 Vault 시크릿 이름·URL · 함수 이름만 바꿔 쓴다 · 키 값은 Vault 에만).
-- 정리할 주문 목록(서버만) — confirm: paid 인데 묶음이 이 주문으로 확정 안 됨(3분 지남) · lookup: 10분 넘은 pending · cancel: 취소 실패·도중 끊김
create or replace function public.taam_package_reconcile_list(p_limit int default 15)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public._taam_pkg_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x order by ca), '[]'::jsonb) into v from (
    select po.created_at as ca,
           jsonb_build_object('order_id', po.order_id, 'user_id', po.user_id, 'amount', po.amount, 'status', po.status, 'payment_key', po.payment_key,
                              'fail_reason', po.fail_reason, 'created_at', po.created_at, 'approved_at', po.approved_at,
                              'metadata', jsonb_build_object('group_id', po.metadata->>'group_id', 'paid_via', po.metadata->>'paid_via',
                                                             'title', po.metadata->>'title', 'pax', po.metadata->'pax', 'total', po.metadata->'total',
                                                             'deposit_used', po.metadata->'deposit_used'),
                              'reconcile', case when po.status = 'paid' then 'confirm' when po.status = 'pending' then 'lookup' else 'cancel' end) as x
      from public.payment_orders po
      left join public.ticket_package_orders o on o.id = po.metadata->>'group_id'
     where po.purpose = 'package_topup' and po.created_at > now() - interval '3 days'
       and ((po.status = 'paid' and not (coalesce(o.status, '') in ('paid', 'cancelled') and o.order_id = po.order_id)
             and coalesce(po.approved_at, po.created_at) < now() - interval '3 minutes')
         or (po.status = 'pending' and po.created_at < now() - interval '10 minutes')
         or (po.status = 'canceled' and (po.fail_reason like '%refund_failed' or po.fail_reason like '%canceling')))
     order by po.created_at
     limit greatest(1, least(coalesce(p_limit, 15), 50))) s;
  return v;
end $$;
revoke all on function public.taam_package_reconcile_list(int) from public, anon, authenticated;

create or replace function public.taam_package_reconcile_kick()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  if jsonb_array_length(public.taam_package_reconcile_list(1)) = 0 then
    return jsonb_build_object('ok', true, 'skipped', 'nothing');
  end if;
  if to_regclass('public.app_config') is null then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name, '') = '' or coalesce(v_url, '') = '' then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  v_url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/toss-package-pay');
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return jsonb_build_object('ok', false, 'reason', 'no_pg_net'); end if;
  begin
    select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  exception when others then v_jwt := null; end;
  if coalesce(v_jwt, '') = '' then return jsonb_build_object('ok', false, 'reason', 'no_secret'); end if;
  select net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt),
                       body := jsonb_build_object('action', 'sweep'), timeout_milliseconds := 55000) into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req);
end $$;
revoke all on function public.taam_package_reconcile_kick() from public, anon, authenticated;
do $do$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('taam-package-reconcile'); exception when others then null; end;
    perform cron.schedule('taam-package-reconcile', '*/10 * * * *', $job$ select public.taam_package_reconcile_kick(); $job$);
    insert into _pk values ('K 결과 모르는 카드 주문 정리 — 10분 크론', '✅');
  else
    insert into _pk values ('K 결과 모르는 카드 주문 정리 — 10분 크론', '⚠ pg_cron 없음 — 함수만 설치(정리는 회원 재접속·슈퍼어드민 「카드 결제 확인」으로)');
  end if;
exception when others then insert into _pk values ('K 크론 등록', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── 확인 (하나로 · ❌ 가 없어야 정상) ──
select 항목, 결과 from _pk
union all select '함수 21개', case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in (
         'taam_package_save','taam_package_unlink','taam_package_list','taam_package_orders_admin','taam_guard_ticket_package','taam_guard_tp_package_delete',
         '_taam_pkg_rows','taam_package_start','_taam_pkg_confirm','taam_package_confirm_deposit','taam_package_release','taam_package_order_prepare',
         'taam_package_confirm_card','taam_package_fail','taam_package_cancel_quote','taam_package_cancel','taam_package_card_refund_mark',
         'taam_package_order_claim','taam_package_order_close','taam_package_reconcile_kick','taam_package_reconcile_list')) = 21
       and to_regprocedure('public.taam_package_card_refund_quote(text)') is not null then '✅' else '❌ 빠진 함수가 있다' end
union all select 'E 가드 트리거', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ticket_package' and not tgisinternal) then '✅' else '❌' end
union all select 'E 회차 삭제 가드', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_tp_package_delete' and not tgisinternal) then '✅' else '❌' end
union all select '회원·비로그인이 서버 함수를 못 부른다',
       case when has_function_privilege('authenticated', 'public.taam_package_order_prepare(text, uuid)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_package_confirm_card(text)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_package_order_claim(text, text, text, text, timestamptz, jsonb, text, text)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_package_order_close(text, text)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_package_reconcile_kick()', 'execute')
              or has_function_privilege('authenticated', 'public.taam_package_reconcile_list(int)', 'execute')
              or has_function_privilege('anon', 'public.taam_package_start(text, int, text[], bigint)', 'execute') then '❌' else '✅' end
union all select '필요한 옛 함수(taam_ticket_price_krw · _taam_pu_visit_date · taam_time_slot · is_super_admin)',
       case when to_regprocedure('public.taam_ticket_price_krw(text, integer)') is not null and to_regproc('public._taam_pu_visit_date') is not null
             and to_regproc('public.taam_time_slot') is not null and to_regproc('public.is_super_admin') is not null then '✅' else '❌ 없음' end
union all select '지금 패키지(정보)', (select count(*) filter (where status = 'active') || ' 연계 · ' || count(*) filter (where status = 'unlinked') || ' 해제' from public.ticket_packages);
