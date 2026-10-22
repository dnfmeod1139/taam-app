-- ═══════════════════════════════════════════════════════════════
-- 구매 규정 예외 — 슈퍼어드민이 협의한 회원에게만 「같은 회차 추가 구매」·「같은 날 같은 시간대」를 허용한다 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다. 마지막 표에 ❌ 가 없어야 정상.
-- 왜: 중복 가드(trg_taam_guard_ticket_unique · 20261014)는 「어떤 일이 있어도」 한 회원 = 한 회차 1건 · 같은 날 같은 시간대 1건이라
--     슈퍼어드민과 협의한 추가 구매(같은 회차를 일행용으로 한 번 더 · 같은 저녁에 두 매장)도 막는다 — 2026-10-22 스시 사이토 2027.06.01 20:30 「중복 구매 불가」.
--     슈퍼어드민 세션·service_role 도 같은 규칙이라 우회할 길이 없었다(앱 구매 · 초대 확정 · 결제 링크 모두).
-- 무엇:
--   1. 표 purchase_rule_exceptions — 회원 · 회차 · 허용 항목(dup 같은 회차 추가 · time 같은 날 같은 시간대) · 추가 허용 건수(dup) · 기한 · 사유(필수) · 만든 사람 · 해제.
--      한 줄 = 그 회원의 그 회차에만. 다른 회원·다른 회차는 그대로 막힌다. 기한이 지나거나 해제하면 다시 막힌다(이미 산 것은 그대로 — 취소는 따로).
--      쓰기는 RPC(슈퍼어드민)만 · 읽기는 슈퍼어드민(RLS) · 회원은 taam_my_purchase_exceptions() 로 자기 것의 열쇠만(사유는 안 보인다).
--   2. 표 purchase_rule_exception_uses — 예외로 통과한 구매(구매 id · 종류) 기록. 티켓 행 extra_data.ruleException 에도 예외 id 를 적는다(표시용).
--   3. 가드 taam_guard_purchase_unique 교체(md5 가드 — 저장소 20261014 판 7e6c53a6… 또는 라이브 주석 축약 판 efee83c2… 일 때만 · 로직은 둘이 같다):
--      ① 같은 회차가 있으면 → 살아 있는 같은 회차 행 수 ≤ 예외의 추가 허용 건수일 때만 통과 · 통과하면 ② 에서 같은 회차 행은 겹침으로 안 센다(같은 회차는 당연히 같은 시각)
--      ② 같은 날 같은 시간대가 있으면 → time 예외일 때만 통과. time 예외는 **양쪽으로** 본다 — 예외를 받은 회차는 이 회원에게 겹침 판정에서 빠진다
--         (예: 사이토 20:30 이 있는 회원에게 다른 매장 19:00 을 허락했으면, 그 뒤 사이토를 한 번 더 살 때도 19:00 은 겹침으로 안 센다).
--         그 밖의 줄(남의 user_id 침묵 · UPDATE 열쇠 그대로 통과 · 회원 단위 잠금 · 문구)은 종전 그대로.
--   4. 결제 링크 만들기(taam_pay_link_create)의 회원 선검사 두 줄도 같은 예외를 본다(md5 가드 350c0c48… · 문자열 치환 · 각각 정확히 1곳).
--      초대 확정(taam_invite_confirm_hold)·결제 링크 결제 뒤 소유자 이전은 가드를 지나므로 따로 고칠 것이 없다.
--   5. RPC: taam_purchase_exception_grant / _revoke / _list / _preview(슈퍼어드민·SQL Editor·서버) · taam_my_purchase_exceptions(로그인 회원 · 자기 것).
-- ⚠ 재구매 제한(같은 매장 N일 · trg_taam_repurchase_guard)은 이 예외와 무관하다 — 같은 날은 원래 예외 · 다른 날은 회차별 「재구매 해제」.
-- 회귀: bash sql/_test/t_purchase_exception.sh
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 표 ──
create table if not exists public.purchase_rule_exceptions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null,
  ticket_product_id text not null,
  allow_dup         boolean not null default false,
  allow_time        boolean not null default false,
  extra             int not null default 1,
  expires_at        timestamptz not null,
  note              text not null,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  revoked_at        timestamptz,
  revoked_by        uuid,
  revoke_note       text,
  constraint pre_kind_chk  check (allow_dup or allow_time),
  constraint pre_extra_chk check (extra between 1 and 5),
  constraint pre_note_chk  check (length(btrim(note)) > 0)
);
create index if not exists purchase_rule_exceptions_user_tp on public.purchase_rule_exceptions (user_id, ticket_product_id);
alter table public.purchase_rule_exceptions enable row level security;
drop policy if exists pre_super_read on public.purchase_rule_exceptions;
create policy pre_super_read on public.purchase_rule_exceptions for select using (coalesce(public._taam_uid_is_super(), false));
revoke insert, update, delete, truncate on public.purchase_rule_exceptions from anon, authenticated;
comment on table public.purchase_rule_exceptions is
  '구매 규정 예외 — 슈퍼어드민이 협의한 회원·회차에만 같은 회차 추가 구매(dup)·같은 날 같은 시간대(time)를 허용. 쓰기는 RPC 만. 2026-10-22';

create table if not exists public.purchase_rule_exception_uses (
  id                bigserial primary key,
  exception_id      uuid not null references public.purchase_rule_exceptions(id) on delete cascade,
  user_id           uuid not null,
  ticket_product_id text,
  purchase_id       text,
  kind              text not null,
  created_at        timestamptz not null default now(),
  constraint preu_kind_chk check (kind in ('dup', 'time')),
  constraint preu_once unique (exception_id, purchase_id, kind)
);
alter table public.purchase_rule_exception_uses enable row level security;
drop policy if exists preu_super_read on public.purchase_rule_exception_uses;
create policy preu_super_read on public.purchase_rule_exception_uses for select using (coalesce(public._taam_uid_is_super(), false));
revoke insert, update, delete, truncate on public.purchase_rule_exception_uses from anon, authenticated;

-- ── 2) 판정 도우미 ──
-- 이 회원·회차에 지금 쓸 수 있는 예외 id (없으면 null). dup 은 「이미 살아 있는 같은 회차 행 수(p_others) ≤ 추가 허용 건수」일 때만.
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
revoke all on function public._taam_purchase_exc_find(uuid, text, text, int) from public, anon, authenticated;

-- 예외로 통과한 구매를 적는다 — 기록이 실패해도 구매는 막지 않는다
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
revoke all on function public._taam_purchase_exc_use(uuid, uuid, text, text, text) from public, anon, authenticated;

-- 같은 날 같은 시간대에 **다른 회차**의 살아 있는 행이 있나 (가드와 같은 식 — 결제 링크 선검사가 쓴다)
create or replace function public._taam_pu_clash_other(p_uid uuid, p_tp text, p_date date, p_slot text)
returns boolean
language sql stable security definer set search_path = public
as $$
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
$$;
revoke all on function public._taam_pu_clash_other(uuid, text, date, text) from public, anon, authenticated;

-- ── 3) 가드 교체 (md5 가드) ──
drop table if exists _pre_chk; create temp table _pre_chk(k text, v text);
do $do$
declare v_live text;
begin
  select md5(p.prosrc) into v_live from pg_proc p where p.oid = to_regprocedure('public.taam_guard_purchase_unique()');
  if v_live is null then
    insert into _pre_chk values ('② 중복 가드 교체', '❌ 라이브에 가드 함수가 없다 — 20261014_purchase_uniqueness.sql 먼저');
  elsif exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_guard_purchase_unique()') and p.prosrc like '%_taam_purchase_exc_find%') then
    insert into _pre_chk values ('② 중복 가드 교체', '✅ 이미 새 판');
  elsif v_live not in ('7e6c53a6513c61de94377047dbd94b64', 'efee83c2c4defcbab67ba22d809b4382') then
    insert into _pre_chk values ('② 중복 가드 교체', '❌ 라이브 본문이 알려진 판과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  else
    execute $fn$
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
$fn$;
    insert into _pre_chk values ('② 중복 가드 교체', '✅ 교체 (옛 md5 ' || v_live || ')');
  end if;
end $do$;

-- ── 4) 결제 링크 선검사 — 같은 예외를 본다 (md5 가드 · 문자열 치환) ──
do $do$
declare v_oid oid := to_regprocedure('public.taam_pay_link_create(text,jsonb)'); v_live text; v_def text; v_new text;
        o1 text := 'raise exception ''DUPLICATE_PURCHASE'' using errcode = ''23505'';';
        n1 text := 'if public._taam_purchase_exc_find(v_user, p->>''ticket_id'', ''dup'', (select count(*)::int from public.tickets k2 where k2.user_id = v_user and k2.ticket_product_id::text = p->>''ticket_id'' and coalesce(k2.status,'''') not in (''cancelled'',''canceled'',''expired'') and not public._taam_ticket_is_ops(k2.purchase_id, k2.extra_data))) is null then raise exception ''DUPLICATE_PURCHASE'' using errcode = ''23505''; end if;   -- 2026-10-22 구매 규정 예외';
        o2 text := 'raise exception ''TIME_CONFLICT'' using errcode = ''23505'';';
        n2 text := 'if public._taam_purchase_exc_find(v_user, p->>''ticket_id'', ''time'', 0) is null and (public._taam_pu_clash_other(v_user, p->>''ticket_id'', v_vdate, v_vslot) or (public._taam_purchase_exc_find(v_user, p->>''ticket_id'', ''dup'', 0) is null and exists (select 1 from public.tickets k3 where k3.user_id = v_user and k3.ticket_product_id::text = p->>''ticket_id'' and coalesce(k3.status,'''') not in (''cancelled'',''canceled'',''expired'') and not public._taam_ticket_is_ops(k3.purchase_id, k3.extra_data)))) then raise exception ''TIME_CONFLICT'' using errcode = ''23505''; end if;   -- 2026-10-22 구매 규정 예외';
begin
  if v_oid is null then
    insert into _pre_chk values ('③ 결제 링크 선검사', '✅ 결제 링크 함수 없음 — 건너뜀(해당 없음)');
    return;
  end if;
  select md5(p.prosrc) into v_live from pg_proc p where p.oid = v_oid;
  if exists (select 1 from pg_proc p where p.oid = v_oid and p.prosrc like '%_taam_purchase_exc_find%') then
    insert into _pre_chk values ('③ 결제 링크 선검사', '✅ 이미 새 판');
  elsif v_live <> '350c0c486abf2fe012a49025e23431c0' then
    insert into _pre_chk values ('③ 결제 링크 선검사', '❌ 라이브 본문이 저장소 판(20261019_pay_link_override_parts)과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  else
    v_def := pg_get_functiondef(v_oid);
    if (length(v_def) - length(replace(v_def, o1, ''))) / length(o1) <> 1 or (length(v_def) - length(replace(v_def, o2, ''))) / length(o2) <> 1 then
      insert into _pre_chk values ('③ 결제 링크 선검사', '❌ 치환할 줄이 정확히 한 곳이 아니다 — 건너뜀');
    else
      v_new := replace(replace(v_def, o1, n1), o2, n2);
      execute v_new;
      insert into _pre_chk values ('③ 결제 링크 선검사', '✅ 교체 (옛 md5 ' || v_live || ')');
    end if;
  end if;
end $do$;

-- ── 5) RPC ──
-- 슈퍼어드민: 허용
create or replace function public.taam_purchase_exception_grant(
  p_user uuid, p_ticket text, p_dup boolean, p_time boolean,
  p_extra int default 1, p_expires_at timestamptz default null, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_tp text := nullif(btrim(coalesce(p_ticket, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_name text; v_row record; v_vd date; v_exp timestamptz; v_id uuid; v_old int := 0;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN: 슈퍼어드민만 허용할 수 있습니다' using errcode = '42501'; end if;
  if p_user is null then raise exception 'MEMBER_REQUIRED' using errcode = '22023'; end if;
  select display_name into v_name from public.profiles where id = p_user and deleted_at is null;
  if not found then raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_tp is null then raise exception 'TICKET_REQUIRED' using errcode = '22023'; end if;
  select tp.id::text as id, tp.rest_name, tp.date, tp.time into v_row from public.ticket_products tp where tp.id::text = v_tp;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  if not coalesce(p_dup, false) and not coalesce(p_time, false) then raise exception 'KIND_REQUIRED: 허용 항목을 하나 이상 고르세요' using errcode = '22023'; end if;
  if coalesce(p_extra, 1) < 1 or coalesce(p_extra, 1) > 5 then raise exception 'BAD_EXTRA: 추가 허용은 1~5건' using errcode = '22023'; end if;
  if v_note is null then raise exception 'NOTE_REQUIRED: 사유(협의 내용)를 적어 주세요' using errcode = '22023'; end if;
  v_vd := public._taam_pu_visit_date(v_row.date);
  -- 기본 기한 = 방문일 끝(KST) · 날짜를 못 읽으면 14일
  v_exp := coalesce(p_expires_at, case when v_vd is not null then ((v_vd + 1)::timestamp at time zone 'Asia/Seoul') else now() + interval '14 days' end);
  if v_exp <= now() then raise exception 'BAD_EXPIRES: 기한이 이미 지났습니다(지난 회차)' using errcode = '22023'; end if;
  if v_exp > now() + interval '400 days' then raise exception 'BAD_EXPIRES: 기한이 너무 깁니다' using errcode = '22023'; end if;
  -- 같은 회원·회차의 살아 있는 예외는 새 것으로 대체(한 줄만 살아 있게)
  update public.purchase_rule_exceptions
     set revoked_at = now(), revoked_by = auth.uid(), revoke_note = '새 예외로 대체'
   where user_id = p_user and ticket_product_id = v_tp and revoked_at is null and expires_at > now();
  get diagnostics v_old = row_count;
  insert into public.purchase_rule_exceptions (user_id, ticket_product_id, allow_dup, allow_time, extra, expires_at, note, created_by)
  values (p_user, v_tp, coalesce(p_dup, false), coalesce(p_time, false), coalesce(p_extra, 1), v_exp, v_note, auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'expires_at', v_exp, 'replaced', v_old,
                            'member_name', v_name, 'allow_dup', coalesce(p_dup, false), 'allow_time', coalesce(p_time, false), 'extra', coalesce(p_extra, 1),
                            'ticket', jsonb_build_object('id', v_row.id, 'rest', v_row.rest_name, 'date', v_row.date, 'time', v_row.time));
end $$;
revoke all on function public.taam_purchase_exception_grant(uuid, text, boolean, boolean, int, timestamptz, text) from public, anon;
grant execute on function public.taam_purchase_exception_grant(uuid, text, boolean, boolean, int, timestamptz, text) to authenticated;

-- 슈퍼어드민: 해제 (이미 산 티켓은 그대로 — 취소는 따로)
create or replace function public.taam_purchase_exception_revoke(p_id uuid, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.purchase_rule_exceptions
     set revoked_at = now(), revoked_by = auth.uid(), revoke_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), '해제')
   where id = p_id and revoked_at is null;
  if found then return jsonb_build_object('ok', true, 'id', p_id); end if;
  if exists (select 1 from public.purchase_rule_exceptions where id = p_id) then
    return jsonb_build_object('ok', false, 'error', 'already_revoked', 'id', p_id);
  end if;
  return jsonb_build_object('ok', false, 'error', 'not_found', 'id', p_id);
end $$;
revoke all on function public.taam_purchase_exception_revoke(uuid, text) from public, anon;
grant execute on function public.taam_purchase_exception_revoke(uuid, text) to authenticated;

-- 슈퍼어드민: 목록 (기본 살아 있는 것만)
create or replace function public.taam_purchase_exception_list(p_user uuid default null, p_include_closed boolean default false, p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) into v
    from (
      select e.created_at,
             jsonb_build_object(
               'id', e.id, 'user_id', e.user_id, 'member_name', p.display_name, 'member_tier', p.membership_tier,
               'ticket_product_id', e.ticket_product_id, 'rest', tp.rest_name, 'date', tp.date, 'time', tp.time,
               'allow_dup', e.allow_dup, 'allow_time', e.allow_time, 'extra', e.extra,
               'expires_at', e.expires_at, 'note', e.note, 'created_at', e.created_at, 'created_by_name', cb.display_name,
               'revoked_at', e.revoked_at, 'revoke_note', e.revoke_note,
               'state', case when e.revoked_at is not null then 'revoked' when e.expires_at <= now() then 'expired' else 'active' end,
               'uses', coalesce((select jsonb_agg(jsonb_build_object('purchase_id', u.purchase_id, 'kind', u.kind, 'at', u.created_at,
                                                                     'status', (select k.status from public.tickets k where k.purchase_id = u.purchase_id order by k.created_at desc limit 1))
                                                  order by u.created_at)
                                   from public.purchase_rule_exception_uses u where u.exception_id = e.id), '[]'::jsonb)
             ) as j
        from public.purchase_rule_exceptions e
        left join public.profiles p  on p.id = e.user_id
        left join public.profiles cb on cb.id = e.created_by
        left join public.ticket_products tp on tp.id::text = e.ticket_product_id
       where (p_user is null or e.user_id = p_user)
         and (coalesce(p_include_closed, false) or (e.revoked_at is null and e.expires_at > now()))
       order by e.created_at desc
       limit least(greatest(coalesce(p_limit, 100), 1), 500)
    ) x;
  return v;
end $$;
revoke all on function public.taam_purchase_exception_list(uuid, boolean, int) from public, anon;
grant execute on function public.taam_purchase_exception_list(uuid, boolean, int) to authenticated;

-- 슈퍼어드민: 미리보기 — 이 회원이 이 회차를 지금 사면 무엇에 걸리나 (가드와 같은 식)
create or replace function public.taam_purchase_exception_preview(p_user uuid, p_ticket text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_tp text := nullif(btrim(coalesce(p_ticket, '')), ''); v_date date; v_time text; v_slot text; v_dup jsonb; v_clash jsonb; v_exc jsonb;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select public._taam_pu_visit_date(tp.date), nullif(btrim(coalesce(tp.time, '')), '') into v_date, v_time
    from public.ticket_products tp where tp.id::text = v_tp;
  v_slot := public.taam_time_slot(v_time);
  select coalesce(jsonb_agg(jsonb_build_object('purchase_id', k.purchase_id, 'status', k.status, 'pax', k.party_size, 'rest', k.restaurant_name,
                                               'date', coalesce(k.reservation_date, tp.date), 'time', coalesce(nullif(k.visit_time, ''), tp.time)) order by k.created_at), '[]'::jsonb)
    into v_dup
    from public.tickets k left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
   where k.user_id = p_user and k.ticket_product_id::text = v_tp
     and coalesce(k.status, '') not in ('cancelled','canceled','expired')
     and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data);
  select coalesce(jsonb_agg(jsonb_build_object('purchase_id', k.purchase_id, 'status', k.status, 'pax', k.party_size, 'rest', k.restaurant_name,
                                               'date', coalesce(k.reservation_date, tp.date), 'time', coalesce(nullif(k.visit_time, ''), tp.time),
                                               'excused', public._taam_purchase_exc_find(p_user, k.ticket_product_id::text, 'time', 0) is not null) order by k.created_at), '[]'::jsonb)
    into v_clash
    from public.tickets k left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
   where v_date is not null and k.user_id = p_user
     and coalesce(k.status, '') not in ('cancelled','canceled','expired')
     and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
     and k.ticket_product_id::text is distinct from v_tp
     and coalesce(public._taam_pu_visit_date(k.reservation_date), public._taam_pu_visit_date(tp.date)) = v_date
     and ( v_slot is null
           or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) is null
           or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) = v_slot );
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'allow_dup', e.allow_dup, 'allow_time', e.allow_time, 'extra', e.extra, 'expires_at', e.expires_at)), '[]'::jsonb)
    into v_exc
    from public.purchase_rule_exceptions e
   where e.user_id = p_user and e.ticket_product_id = v_tp and e.revoked_at is null and e.expires_at > now();
  return jsonb_build_object('ok', true, 'visit_date', v_date, 'slot', v_slot, 'same_ticket', v_dup, 'same_slot', v_clash, 'active', v_exc);
end $$;
revoke all on function public.taam_purchase_exception_preview(uuid, text) from public, anon;
grant execute on function public.taam_purchase_exception_preview(uuid, text) to authenticated;

-- 회원: 자기 예외의 열쇠만(사유·만든 사람은 안 준다) — 앱의 사전 차단이 서버와 같게 판단하려고
create or replace function public.taam_my_purchase_exceptions()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('ticket_product_id', e.ticket_product_id, 'allow_dup', e.allow_dup, 'allow_time', e.allow_time,
                                               'extra', e.extra, 'expires_at', e.expires_at) order by e.created_at desc), '[]'::jsonb)
    from public.purchase_rule_exceptions e
   where auth.uid() is not null and e.user_id = auth.uid() and e.revoked_at is null and e.expires_at > now()
$$;
revoke all on function public.taam_my_purchase_exceptions() from public, anon;
grant execute on function public.taam_my_purchase_exceptions() to authenticated;

-- ── 확인 — 한 표 ──
insert into _pre_chk
select '① 표 둘 · RLS 켜짐', case when to_regclass('public.purchase_rule_exceptions') is not null and to_regclass('public.purchase_rule_exception_uses') is not null
                                    and (select relrowsecurity from pg_class where oid = 'public.purchase_rule_exceptions'::regclass)
                                    and (select relrowsecurity from pg_class where oid = 'public.purchase_rule_exception_uses'::regclass) then '✅' else '❌' end
union all select '④ RPC 다섯 · 도우미 셋', case when to_regprocedure('public.taam_purchase_exception_grant(uuid,text,boolean,boolean,integer,timestamp with time zone,text)') is not null
                                          and to_regprocedure('public.taam_purchase_exception_revoke(uuid,text)') is not null
                                          and to_regprocedure('public.taam_purchase_exception_list(uuid,boolean,integer)') is not null
                                          and to_regprocedure('public.taam_purchase_exception_preview(uuid,text)') is not null
                                          and to_regprocedure('public.taam_my_purchase_exceptions()') is not null
                                          and to_regprocedure('public._taam_purchase_exc_find(uuid,text,text,integer)') is not null
                                          and to_regprocedure('public._taam_purchase_exc_use(uuid,uuid,text,text,text)') is not null
                                          and to_regprocedure('public._taam_pu_clash_other(uuid,text,date,text)') is not null then '✅' else '❌' end
union all select '⑤ anon 은 못 부른다(목록·내 예외·허용)', case when not has_function_privilege('anon', 'public.taam_my_purchase_exceptions()', 'execute')
                                                and not has_function_privilege('anon', 'public.taam_purchase_exception_list(uuid,boolean,integer)', 'execute')
                                                and not has_function_privilege('anon', 'public.taam_purchase_exception_grant(uuid,text,boolean,boolean,integer,timestamp with time zone,text)', 'execute')
                                                and not has_function_privilege('authenticated', 'public._taam_purchase_exc_find(uuid,text,text,integer)', 'execute') then '✅' else '❌' end
union all select '⑥ 가드 트리거가 새 함수에 붙어 있다', case when exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                                                           where g.tgname = 'trg_taam_guard_ticket_unique' and not g.tgisinternal and p.proname = 'taam_guard_purchase_unique'
                                                             and p.prosrc like '%_taam_purchase_exc_find%') then '✅' else '❌' end
union all select '⑦ 살아 있는 예외 (정보)', (select count(*) from public.purchase_rule_exceptions where revoked_at is null and expires_at > now())::text || '건';
select k as 항목, v as 결과 from _pre_chk order by 1;
