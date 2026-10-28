-- ═══════════════════════════════════════════════════════════════
-- 파트너(매장 어드민) 권한 정리 — 승인 상태 · 권한 판정 하나로 · 매장 범위 자료 RPC (2026-10-29)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다. 마지막 표에 ❌ 가 없어야 정상.
-- 왜(운영 결정 2026-10-28 · 4 렌즈 조사 + 라이브 진단 20261029_diag_admin_surface.sql):
--   · 「매장 어드민은 슈퍼어드민이 허락·승인한 레스토랑에 한해 그 매장 예약 자료와 예약한 회원 정보(예치금 제외 · 다른 매장 구매 제외)를
--     보고 검색한다 · 모든 어드민 계정은 슈퍼어드민 승인이 있어야 티켓 업로드·수정 등을 할 수 있다」.
--   · 지금은 admin_grants 한 줄 = 곧 권한이고(승인 상태 없음), 「이 사람이 X 매장 어드민인가」를 네 가지로 다르게 판정했다 —
--     admin_grants(is_ticket_admin_of) · admin_grants 또는 옛 restaurant_admins(is_restaurant_admin_of) · 옛 restaurant_admins 만(taam_can_mark_visit ·
--     taam_can_manage_ticket_as) · profiles.role='admin' 글자(taam_guard_ticket_insert · send-push · taam-format). 파트너 계정(partner-account)은 role 'user' 라
--     글자 판정에 전부 걸려 수동 좌석(MAN-)·초대 홀드(INVH-)·방문 기록이 **안 됐고**, 반대로 role 'admin' 글자를 가진 계정은 매장 제한 없이 어느 회차에든 넣을 수 있었다.
--   · 라이브(2026-10-29): admin_grants 1줄(role member) · restaurant_admins 1줄 · partner_accounts 0 · venue_admins 0 — 파트너 운영은 사실상 아직 시작 전이다.
-- 무엇:
--   A. admin_grants 에 status(pending|approved|suspended) · approved_by/at · status_set_by/at · note. 지금 있는 줄은 approved 로(종전엔 줄 = 승인) ·
--      옛 restaurant_admins 줄은 admin_grants 로 옮겨 적는다(approved). 상태 칸은 트리거가 찍는다.
--   B. 판정 하나: taam_rest_admin_ok(매장) = 「로그인 회원이 그 매장의 **approved** 권한을 가졌다」. 옛 이름 전부(is_ticket_admin_of · is_restaurant_admin_of ·
--      is_venue_admin_of · taam_is_rest_admin · taam_can_mark_visit · taam_can_manage_ticket_as · _taam_rest_note_ok)를 같은 서명으로 이것에 얹는다 —
--      정책·RPC·트리거를 한 줄도 안 고치고 전부 승인 상태를 보게 된다. 옛 표(restaurant_admins · venue_admins)는 더 읽지 않는다.
--   C. tickets INSERT 가드: role 글자 대신 승인 권한 + 매장 일치 — 매장 어드민은 **자기 매장** 회차의 INVH- 홀드와 MAN- 수동 좌석만.
--   D. ticket_products: 파트너 정책을 (profiles.admin_rest_id — 아무도 안 쓰는 칸) 대신 승인 권한으로 · 승인 대기(pending) 회차는 슈퍼어드민과 그 매장 어드민만 읽는다
--      (종전엔 전원 공개 — 가격·좌석이 승인 전에 새어 나갔다) · 승인된 회차를 파트너가 고치면 **다시 승인 대기**로(매진 토글·삭제 신청은 그대로) ·
--      승인 때 approved_by/at · 업로드 신청·승인·거절을 서버 알림으로(종전엔 앱이 보낼 때만).
--   E. reservation_invites: 연결 회차는 반드시 그 초대의 매장 것(다른 매장 회차에 아무 값으로 초대하던 길).
--   F. profiles: 「매장 어드민이 요청 회원의 profiles 전 칸을 읽는」 정책 삭제(예치금 잔액·이메일이 통째로 보였다) · get_requester_info 의 구매·취소 건수를 그 매장 것으로.
--   G. 파트너 RPC(승인 권한 필요 · security definer):
--      taam_partner_my_grants() · taam_partner_reservations(매장, from, to, 검색, 상태) · taam_partner_member(매장, 회원) · taam_partner_member_search(매장, 검색).
--      회원 정보는 이름·전화·이메일·등급·국적·언어(운영 결정) + **이 매장** 방문/노쇼/취소 + **이 매장** 구매·환불·취소 내역뿐 — 예치금 잔액·다른 매장은 어디에도 없다.
--   H. 슈퍼어드민 RPC: taam_partner_grants_list() · taam_partner_grant_set(회원, 매장, 상태, 메모).
--   I. 덤(조사에서 나온 구멍): _taam_auth_email 이 누구나 부를 수 있는 uuid→이메일 조회였다 → 본인·슈퍼어드민·서버만 · 속성 조회 함수들 anon 회수.
-- 회귀: bash sql/_test/t_partner_grants.sh
-- ═══════════════════════════════════════════════════════════════
create temp table _pg(seq serial, 항목 text, 결과 text);

-- ── A. admin_grants 승인 상태 ──
alter table public.admin_grants add column if not exists status text not null default 'pending';
alter table public.admin_grants add column if not exists approved_by uuid;
alter table public.admin_grants add column if not exists approved_at timestamptz;
alter table public.admin_grants add column if not exists status_set_by uuid;
alter table public.admin_grants add column if not exists status_set_at timestamptz;
alter table public.admin_grants add column if not exists note text;
alter table public.admin_grants drop constraint if exists admin_grants_status_chk;
alter table public.admin_grants add constraint admin_grants_status_chk check (status in ('pending', 'approved', 'suspended'));
create index if not exists idx_ag_user_status on public.admin_grants(user_id, status);

-- 지금 있는 줄 = 종전 규칙(줄 = 승인)으로 준 것 — approved 로 (한 번만: approved_at 이 비어 있고 status 가 기본값 pending 인 옛 줄)
do $do$
declare n int;
begin
  update public.admin_grants
     set status = 'approved', approved_at = coalesce(approved_at, created_at), approved_by = coalesce(approved_by, granted_by),
         status_set_at = coalesce(status_set_at, created_at), note = coalesce(note, '2026-10-29 승인 상태 도입 전 권한 — 자동 승인')
   where status = 'pending' and approved_at is null and status_set_at is null and created_at < timestamptz '2026-10-29 00:00:00+09';
  get diagnostics n = row_count;
  insert into _pg(항목, 결과) values ('A 옛 권한 approved 로', '✅ ' || n || '줄');
  -- 옛 restaurant_admins 줄 → admin_grants (없는 것만 · approved)
  if to_regclass('public.restaurant_admins') is not null then
    insert into public.admin_grants (user_id, rest_id, label, granted_by, created_at, status, approved_by, approved_at, status_set_at, note)
    select ra.user_id, ra.restaurant_id::text, ra.restaurant_name, ra.added_by, ra.added_at, 'approved', ra.added_by, ra.added_at, ra.added_at, 'restaurant_admins 에서 옮김 2026-10-29'
      from public.restaurant_admins ra
     where ra.restaurant_id is not null
       and not exists (select 1 from public.admin_grants g where g.user_id = ra.user_id and g.rest_id = ra.restaurant_id::text);
    get diagnostics n = row_count;
    insert into _pg(항목, 결과) values ('A restaurant_admins → admin_grants', '✅ ' || n || '줄 옮김');
  end if;
  if to_regclass('public.venue_admins') is not null then
    insert into public.admin_grants (user_id, venue_id, granted_by, created_at, status, approved_by, approved_at, status_set_at, note)
    select va.admin_user_id, va.venue_id::text, va.granted_by, coalesce(to_jsonb(va)->>'created_at', now()::text)::timestamptz, 'approved', va.granted_by, now(), now(), 'venue_admins 에서 옮김 2026-10-29'
      from public.venue_admins va
     where va.venue_id is not null
       and not exists (select 1 from public.admin_grants g where g.user_id = va.admin_user_id and g.venue_id = va.venue_id::text);
    get diagnostics n = row_count;
    insert into _pg(항목, 결과) values ('A venue_admins → admin_grants', '✅ ' || n || '줄 옮김');
  end if;
exception when others then insert into _pg(항목, 결과) values ('A 옮김', '❌ ' || left(sqlerrm, 160));
end $do$;

-- 상태 칸은 트리거가 찍는다(앱이 보내도 무시) · RLS 는 종전대로 슈퍼어드민만 쓴다
create or replace function public.taam_guard_admin_grant()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.status not in ('pending', 'approved', 'suspended') then new.status := 'pending'; end if;
  if tg_op = 'INSERT' then
    new.status_set_at := now(); new.status_set_by := auth.uid();
    if new.status = 'approved' then new.approved_at := coalesce(new.approved_at, now()); new.approved_by := coalesce(new.approved_by, auth.uid()); end if;
    if new.granted_by is null then new.granted_by := auth.uid(); end if;
  elsif new.status is distinct from old.status then
    new.status_set_at := now(); new.status_set_by := auth.uid();
    if new.status = 'approved' then new.approved_at := now(); new.approved_by := auth.uid(); end if;
  else
    new.status_set_at := old.status_set_at; new.status_set_by := old.status_set_by;
    new.approved_at := old.approved_at; new.approved_by := old.approved_by;
  end if;
  return new;
end $$;
drop trigger if exists trg_taam_guard_admin_grant on public.admin_grants;
create trigger trg_taam_guard_admin_grant before insert or update on public.admin_grants
  for each row execute function public.taam_guard_admin_grant();

-- ── B. 판정 하나 ──
create or replace function public.taam_rest_admin_ok_for(p_uid uuid, p_rest text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_uid is not null and coalesce(p_rest, '') <> '' and exists (
    select 1 from public.admin_grants g
     where g.user_id = p_uid and g.status = 'approved'
       and (g.rest_id = p_rest or g.venue_id = p_rest))
$$;
create or replace function public.taam_rest_admin_ok(p_rest text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.taam_rest_admin_ok_for(auth.uid(), p_rest)
$$;
revoke all on function public.taam_rest_admin_ok_for(uuid, text) from public, anon;
revoke all on function public.taam_rest_admin_ok(text) from public, anon;
grant execute on function public.taam_rest_admin_ok(text) to authenticated;
grant execute on function public.taam_rest_admin_ok_for(uuid, text) to authenticated;   -- 정책식 안에서 호출자 권한으로 돈다

-- 옛 이름들 — 같은 서명 · 전부 승인 권한으로 (라이브 본문 md5 를 기록만 하고 교체한다 — 권한 판정은 이 파일이 의도적으로 바꾸는 것)
do $do$
declare r record; v text := '';
begin
  for r in select p.proname, md5(p.prosrc) m from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('is_ticket_admin_of','is_restaurant_admin_of','is_venue_admin_of','taam_is_rest_admin','taam_can_mark_visit','taam_can_manage_ticket_as','_taam_rest_note_ok') loop
    v := v || r.proname || ' ' || left(r.m, 8) || ' · ';
  end loop;
  insert into _pg(항목, 결과) values ('B 교체 전 md5(기록)', coalesce(nullif(v, ''), '없음'));
end $do$;
-- ⚠ CREATE OR REPLACE 는 인자 이름을 못 바꾼다("cannot change name of input parameter") — 라이브 함수의 인자 이름을 모르니
--   pg_get_function_identity_arguments 로 지금 이름을 읽어 그대로 쓰고, 본문은 $1·$2 로 쓴다. 없는 함수는 기본 이름으로 만든다.
--   DROP 은 안 한다 — 정책식이 의존하면 DROP 이 막히고, 연쇄 삭제는 정책을 날린다.
do $do$
declare
  f record; v_args text; v_names text[]; v_sig text;
begin
  for f in select * from (values
      ('is_ticket_admin_of',        array['p_rest_id'],               array['text'],         'select public.taam_rest_admin_ok($1)'),
      ('is_restaurant_admin_of',    array['p_restaurant_id'],         array['text'],         'select public.taam_rest_admin_ok($1)'),
      ('is_venue_admin_of',         array['p_venue_id'],              array['text'],         'select public.taam_rest_admin_ok($1)'),
      ('taam_is_rest_admin',        array['p_rest_id'],               array['text'],         'select public.taam_rest_admin_ok($1)'),
      ('taam_can_mark_visit',       array['p_restaurant_id'],         array['text'],         'select public._taam_uid_is_super() or public.taam_rest_admin_ok($1)'),
      ('taam_can_manage_ticket_as', array['p_ticket_id', 'p_user'],   array['text', 'uuid'],
         'select exists (select 1 from public.profiles p where p.id = $2 and p.role in (''super_admin'', ''superadmin''))'
         || ' or exists (select 1 from public.ticket_products tp where tp.id::text = $1 and public.taam_rest_admin_ok_for($2, coalesce(tp.rest_id::text, tp.uploader_rest_id::text)))'),
      ('_taam_rest_note_ok',        array['p_rest_id'],               array['text'],
         'select coalesce(public._taam_fee_caller_ok(), false) or public.taam_rest_admin_ok($1)')
    ) as t(fn, defnames, types, body) loop
    -- 지금 라이브 서명(같은 인자 타입)이 있으면 그 이름을 쓴다
    select pg_get_function_identity_arguments(p.oid) into v_args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f.fn
       and p.proargtypes::text = (select string_agg(t::regtype::oid::text, ' ' order by ord) from unnest(f.types) with ordinality as u(t, ord))
     limit 1;
    if v_args is not null then
      -- "p_a text, p_b uuid" → 이름만. 이름이 없는(타입만 적힌) 인자는 기본 이름.
      select array_agg(case when array_length(w, 1) >= 2 then w[1] else f.defnames[ord] end order by ord) into v_names
        from (select regexp_split_to_array(btrim(x), '\s+') w, ord from regexp_split_to_table(v_args, ',') with ordinality as a(x, ord)) z;
    else
      v_names := f.defnames;
    end if;
    select string_agg(format('%I %s', v_names[i], f.types[i]), ', ' order by i) into v_sig from generate_subscripts(f.types, 1) i;
    execute format('create or replace function public.%I(%s) returns boolean language sql stable security definer set search_path = public as %L', f.fn, v_sig, f.body);
  end loop;
end $do$;

-- ── H. 슈퍼어드민 — 권한 목록 · 상태 바꾸기 ──
create or replace function public.taam_partner_grants_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'id', g.id, 'user_id', g.user_id, 'rest_id', g.rest_id, 'venue_id', g.venue_id, 'label', g.label,
           'rest_name', coalesce(r.name, g.label), 'status', g.status, 'created_at', g.created_at, 'approved_at', g.approved_at,
           'status_set_at', g.status_set_at, 'note', g.note,
           'display_name', nullif(btrim(p.display_name), ''), 'email', to_jsonb(p)->>'email', 'role', p.role,
           'login_id', pa.login_id, 'last_login_at', pa.last_login_at, 'disabled', pa.disabled,
           'approved_by_name', (select nullif(btrim(q.display_name), '') from public.profiles q where q.id = g.approved_by)
         )) order by (g.status = 'pending') desc, g.created_at desc), '[]'::jsonb) into v
    from public.admin_grants g
    left join public.profiles p on p.id = g.user_id
    left join public.restaurants r on r.id::text = coalesce(g.rest_id, g.venue_id)
    left join lateral (select pa.login_id, pa.last_login_at, pa.disabled from public.partner_accounts pa where pa.user_id = g.user_id order by pa.issued_at desc limit 1) pa on true;
  return v;
end $$;
revoke all on function public.taam_partner_grants_list() from public, anon;
grant execute on function public.taam_partner_grants_list() to authenticated;

create or replace function public.taam_partner_grant_set(p_user uuid, p_rest text, p_status text, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid; v_old text; v_lbl text;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_status not in ('pending', 'approved', 'suspended') then raise exception 'BAD_STATUS' using errcode = '22023'; end if;
  if p_user is null or coalesce(p_rest, '') = '' then raise exception 'BAD_ARGS' using errcode = '22023'; end if;
  select g.id, g.status into v_id, v_old from public.admin_grants g where g.user_id = p_user and (g.rest_id = p_rest or g.venue_id = p_rest) order by g.created_at limit 1;
  if v_id is null then
    select name into v_lbl from public.restaurants where id::text = p_rest;
    insert into public.admin_grants (user_id, rest_id, label, granted_by, status, note) values (p_user, p_rest, v_lbl, auth.uid(), p_status, nullif(btrim(coalesce(p_note, '')), ''))
    returning id into v_id;
    v_old := null;
  else
    update public.admin_grants set status = p_status, note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note) where id = v_id;
  end if;
  -- 매장 어드민 본인에게 알림(앱 알림함 · 승인/정지) — 푸시는 앱이 따로 안 보낸다
  begin
    insert into public.notifications (user_id, type, title, body, url, payload)
    values (p_user, 'partner_grant',
            case p_status when 'approved' then '매장 권한이 승인되었습니다' when 'suspended' then '매장 권한이 정지되었습니다' else '매장 권한이 승인 대기로 바뀌었습니다' end,
            coalesce((select name from public.restaurants where id::text = p_rest), p_rest) || case p_status when 'approved' then ' — 이제 예약 자료를 보고 티켓을 올릴 수 있습니다' when 'suspended' then ' — 문의는 TAAM 으로' else '' end,
            '/', jsonb_build_object('rest_id', p_rest, 'status', p_status, 'via', 'taam_partner_grant_set'));
  exception when others then null; end;
  return jsonb_build_object('ok', true, 'id', v_id, 'from', v_old, 'to', p_status);
end $$;
revoke all on function public.taam_partner_grant_set(uuid, text, text, text) from public, anon;
grant execute on function public.taam_partner_grant_set(uuid, text, text, text) to authenticated;

-- 파트너 본인 — 내 권한(앱이 역할·화면을 정한다)
create or replace function public.taam_partner_my_grants()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'rest_id', coalesce(g.rest_id, g.venue_id), 'label', coalesce(r.name, g.label), 'status', g.status, 'approved_at', g.approved_at, 'note', g.note))
           order by (g.status = 'approved') desc, g.created_at), '[]'::jsonb)
    from public.admin_grants g left join public.restaurants r on r.id::text = coalesce(g.rest_id, g.venue_id)
   where g.user_id = auth.uid() and auth.uid() is not null
$$;
revoke all on function public.taam_partner_my_grants() from public, anon;
grant execute on function public.taam_partner_my_grants() to authenticated;

-- ── C. tickets INSERT 가드 — role 글자 대신 승인 권한 + 매장 일치 ──
do $do$
declare v_md5 text;
begin
  select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'taam_guard_ticket_insert';
  if v_md5 is null then insert into _pg(항목, 결과) values ('C taam_guard_ticket_insert', '❌ 함수 없음');
  elsif v_md5 = '7567d32fd00eaa36dcc7aaa7ffa0d541' then insert into _pg(항목, 결과) values ('C taam_guard_ticket_insert', '✅ 저장소 원본과 같음 → 교체');
  elsif v_md5 = md5('TAAM_GUARD_TICKET_INSERT_V2') then insert into _pg(항목, 결과) values ('C taam_guard_ticket_insert', '✅ 이미 새 판');
  else insert into _pg(항목, 결과) values ('C taam_guard_ticket_insert', '⚠ 모르는 판(' || left(v_md5, 8) || ') — 교체한다(권한 판정은 이 파일이 바꾸는 것)');
  end if;
end $do$;
create or replace function public.taam_guard_ticket_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_adm boolean := false; v_tp_rest text;
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

  -- 이 행의 매장에 승인된 어드민인가 · 연결 회차가 있으면 그 회차도 같은 매장이어야 한다(다른 매장 회차에 좌석을 잡던 길)
  v_adm := public.taam_rest_admin_ok(new.restaurant_id::text);
  if v_adm and coalesce(new.ticket_product_id::text, '') <> '' then
    select tp.rest_id::text into v_tp_rest from public.ticket_products tp where tp.id::text = new.ticket_product_id::text;
    if v_tp_rest is not null and v_tp_rest <> new.restaurant_id::text then
      raise exception 'TICKET_REST_MISMATCH: 다른 매장의 회차입니다' using errcode = '42501';
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
drop trigger if exists trg_taam_guard_ticket_insert on public.tickets;
create trigger trg_taam_guard_ticket_insert
  before insert on public.tickets
  for each row execute function public.taam_guard_ticket_insert();

-- ── D. ticket_products — 파트너 정책 · 승인 대기 비공개 · 재승인 · 알림 ──
alter table public.ticket_products add column if not exists approved_by uuid;
alter table public.ticket_products add column if not exists approved_at timestamptz;
alter table public.ticket_products add column if not exists review_note text;

drop policy if exists ticket_products_partner_insert on public.ticket_products;
drop policy if exists ticket_products_partner_update on public.ticket_products;
drop policy if exists ticket_products_partner_delete on public.ticket_products;
drop policy if exists ticket_products_read on public.ticket_products;
-- 읽기 정책은 anon(로그인 전 · /pay) 도 평가한다 — 정책식 안의 함수는 anon 이 실행할 수 있어야 한다(아니면 select 전체가 permission denied).
--   security definer 한 함수 하나로 묶어 anon·authenticated 에 execute 를 준다(안의 is_super_admin·taam_rest_admin_ok_for 는 소유자 권한으로 돈다).
create or replace function public.taam_tp_visible(p_status text, p_rest text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_status, '') <> 'pending'
      or (auth.uid() is not null and (public.is_super_admin(auth.uid()) or public.taam_rest_admin_ok_for(auth.uid(), p_rest)))
$$;
revoke all on function public.taam_tp_visible(text, text) from public;
grant execute on function public.taam_tp_visible(text, text) to anon, authenticated;
create policy ticket_products_read on public.ticket_products
  for select to public
  using (public.taam_tp_visible(status, rest_id::text));
create policy ticket_products_partner_insert on public.ticket_products
  for insert to authenticated
  with check (public.taam_rest_admin_ok(rest_id::text));
create policy ticket_products_partner_update on public.ticket_products
  for update to authenticated
  using (public.taam_rest_admin_ok(rest_id::text))
  with check (public.taam_rest_admin_ok(rest_id::text));
create policy ticket_products_partner_delete on public.ticket_products
  for delete to authenticated
  using (public.taam_rest_admin_ok(rest_id::text) and coalesce(status, '') = 'pending');

create or replace function public.enforce_ticket_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_changed boolean;
begin
  -- 슈퍼어드민: 전부 허용 · 승인(pending→active)·거절 때 도장
  if public.is_super_admin(auth.uid()) then
    if TG_OP = 'UPDATE' and coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') = 'active' then
      NEW.approved_by := auth.uid(); NEW.approved_at := now();
    end if;
    return NEW;
  end if;
  -- 서버(auth.uid() null — SQL Editor · service_role)는 그대로
  if auth.uid() is null then return NEW; end if;

  if TG_OP = 'INSERT' then
    -- 앱 저장은 PostgREST upsert(INSERT … ON CONFLICT DO UPDATE)라 있는 행에도 BEFORE INSERT 가 먼저 돈다 — 그때는 UPDATE 가지가 판정한다
    --   (종전엔 파트너의 매진 토글·재저장이 여기서 ADMIN_MUST_UPLOAD_PENDING 으로 조용히 실패했다)
    if exists (select 1 from public.ticket_products x where x.id::text = NEW.id::text) then return NEW; end if;
    if coalesce(NEW.status, '') <> 'pending' then
      raise exception 'ADMIN_MUST_UPLOAD_PENDING' using errcode = 'P0001';
    end if;
    if NEW.rest_id is null or not public.taam_rest_admin_ok(NEW.rest_id::text) then
      raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
    end if;
    NEW.approved_by := null; NEW.approved_at := null;

  elsif TG_OP = 'UPDATE' then
    if NEW.rest_id::text is distinct from OLD.rest_id::text then
      raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
    end if;
    if not public.taam_rest_admin_ok(OLD.rest_id::text) then
      raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
    end if;
    if coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') = 'active' then
      raise exception 'ONLY_SUPERADMIN_APPROVES' using errcode = 'P0001';
    end if;
    -- 도장은 파트너가 못 찍는다
    NEW.approved_by := OLD.approved_by; NEW.approved_at := OLD.approved_at;
    -- 승인된(active/soldout/deleteRequest) 회차의 내용을 고치면 다시 승인 대기 — 상태만 바꾸는 것(매진 토글 · 삭제 신청 · 되돌림)은 그대로
    if coalesce(OLD.status, '') in ('active', 'soldout', 'deleteRequest') then
      v_changed := (to_jsonb(NEW) - 'status' - 'updated_at' - 'auto_soldout' - 'approved_by' - 'approved_at' - 'review_note' - 'tile_photo' - 'repurchase_open' - 'sale_open_at' - 'i18n_status_en' - 'i18n_status_ja' - 'ticket_desc_en' - 'ticket_desc_ja')
                 is distinct from
                 (to_jsonb(OLD) - 'status' - 'updated_at' - 'auto_soldout' - 'approved_by' - 'approved_at' - 'review_note' - 'tile_photo' - 'repurchase_open' - 'sale_open_at' - 'i18n_status_en' - 'i18n_status_ja' - 'ticket_desc_en' - 'ticket_desc_ja');
      if v_changed then
        NEW.status := 'pending'; NEW.approved_by := null; NEW.approved_at := null;
      elsif coalesce(NEW.status, '') not in ('active', 'soldout', 'deleteRequest') then
        raise exception 'BAD_STATUS_CHANGE: 파트너는 매진/판매중/삭제 신청만 바꿀 수 있습니다' using errcode = 'P0001';
      end if;
    elsif coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') not in ('pending') then
      raise exception 'BAD_STATUS_CHANGE: 승인 대기 회차의 상태는 슈퍼어드민이 정합니다' using errcode = 'P0001';
    end if;
  end if;
  return NEW;
end;
$$;
drop trigger if exists trg_enforce_ticket_approval on public.ticket_products;
create trigger trg_enforce_ticket_approval
  before insert or update on public.ticket_products
  for each row execute function public.enforce_ticket_approval();

-- 업로드 신청·재승인 → 슈퍼어드민 알림 · 승인·거절 → 그 매장 승인 어드민 알림 (서버가 적는다 · 실패는 삼킨다)
create or replace function public.taam_ticket_approval_notify()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_rest text; v_when text; v_title text; v_body text;
begin
  begin
    select name into v_rest from public.restaurants where id::text = NEW.rest_id::text;
    v_rest := coalesce(v_rest, NEW.rest_name, '매장');
    v_when := coalesce(NEW.date, '') || ' ' || coalesce(NEW.time, '');
    if (TG_OP = 'INSERT' and coalesce(NEW.status, '') = 'pending' and auth.uid() is not null and not public.is_super_admin(auth.uid()))
       or (TG_OP = 'UPDATE' and coalesce(OLD.status, '') <> 'pending' and coalesce(NEW.status, '') = 'pending' and auth.uid() is not null and not public.is_super_admin(auth.uid())) then
      v_title := case when TG_OP = 'INSERT' then '티켓 업로드 신청' else '티켓 수정 — 다시 승인 필요' end;
      insert into public.notifications (user_id, type, title, body, url, payload)
      select p.id, 'ticket_upload_request', v_title, v_rest || ' · ' || v_when, '/', jsonb_build_object('ticket_id', NEW.id::text, 'rest_id', NEW.rest_id::text, 'via', 'trg_taam_ticket_approval_notify')
        from public.profiles p where p.role in ('superadmin', 'super_admin');
    elsif TG_OP = 'UPDATE' and coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') = 'active' then
      insert into public.notifications (user_id, type, title, body, url, payload)
      select g.user_id, 'ticket_approved', '티켓이 승인되었습니다', v_rest || ' · ' || v_when || ' — 회원에게 공개됐습니다', '/', jsonb_build_object('ticket_id', NEW.id::text, 'rest_id', NEW.rest_id::text)
        from public.admin_grants g where g.status = 'approved' and (g.rest_id = NEW.rest_id::text or g.venue_id = NEW.rest_id::text);
    end if;
  exception when others then null;
  end;
  return NEW;
end $$;
drop trigger if exists trg_taam_ticket_approval_notify on public.ticket_products;
create trigger trg_taam_ticket_approval_notify after insert or update on public.ticket_products   -- ⚠ UPDATE OF status 로 걸면 BEFORE 가 pending 으로 바꾼 것(SET 에 status 없음)을 못 본다
  for each row execute function public.taam_ticket_approval_notify();

-- 거절(pending 회차 삭제)은 슈퍼어드민의 DELETE 다 — 그 매장 어드민에게 알린다
create or replace function public.taam_ticket_reject_notify()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_rest text;
begin
  begin
    if coalesce(OLD.status, '') = 'pending' and auth.uid() is not null and public.is_super_admin(auth.uid()) then
      select name into v_rest from public.restaurants where id::text = OLD.rest_id::text;
      insert into public.notifications (user_id, type, title, body, url, payload)
      select g.user_id, 'ticket_rejected', '티켓 업로드가 반려되었습니다', coalesce(v_rest, OLD.rest_name, '매장') || ' · ' || coalesce(OLD.date, '') || ' ' || coalesce(OLD.time, '') || coalesce(' — ' || nullif(OLD.review_note, ''), ''), '/',
             jsonb_build_object('ticket_id', OLD.id::text, 'rest_id', OLD.rest_id::text)
        from public.admin_grants g where g.status = 'approved' and (g.rest_id = OLD.rest_id::text or g.venue_id = OLD.rest_id::text);
    end if;
  exception when others then null;
  end;
  return OLD;
end $$;
drop trigger if exists trg_taam_ticket_reject_notify on public.ticket_products;
create trigger trg_taam_ticket_reject_notify after delete on public.ticket_products
  for each row execute function public.taam_ticket_reject_notify();

-- ── E. reservation_invites — 연결 회차는 그 초대의 매장 것 ──
create or replace function public.taam_guard_invite_rest()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_tp_rest text;
begin
  if auth.uid() is null or public.is_super_admin(auth.uid()) then return NEW; end if;
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
  end if;
  if TG_OP = 'UPDATE' and NEW.restaurant_id::text is distinct from OLD.restaurant_id::text
     and not public.taam_rest_admin_ok(NEW.restaurant_id::text) then
    raise exception 'NOT_YOUR_RESTAURANT' using errcode = '42501';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_taam_guard_invite_rest on public.reservation_invites;
create trigger trg_taam_guard_invite_rest before insert or update on public.reservation_invites
  for each row execute function public.taam_guard_invite_rest();

-- ── F. profiles — 매장 어드민의 전 칸 읽기 삭제 · 요청자 집계는 그 매장만 ──
drop policy if exists "profiles read by venue admin for requesters" on public.profiles;
do $do$
begin
  if to_regprocedure('public.get_requester_info(uuid,text)') is not null then
    execute $f$
    create or replace function public.get_requester_info(p_user_id uuid, p_venue_id text)
    returns table (display_name text, phone text, nationality text, membership_tier text, purchase_count integer, cancel_count integer, venue_visits integer, last_visit date)
    language plpgsql stable security definer set search_path = public
    as $b$
    declare v_ticket_buy integer := 0; v_ticket_cancel integer := 0; v_resv_conf integer := 0; v_resv_noshow integer := 0; v_related boolean := false;
    begin
      if not (public.is_super_admin(auth.uid()) or public.taam_rest_admin_ok(p_venue_id)) then raise exception 'FORBIDDEN' using errcode = 'P0001'; end if;
      if not public.is_super_admin(auth.uid()) then
        v_related := exists (select 1 from public.reservation_requests rr where rr.user_id = p_user_id and rr.venue_id = p_venue_id)
                  or exists (select 1 from public.tickets t where t.user_id = p_user_id and t.restaurant_id::text = p_venue_id);
        if not v_related then raise exception 'FORBIDDEN' using errcode = 'P0001'; end if;
      end if;
      -- 2026-10-29: 건수는 **그 매장** 것만 (종전엔 전 매장 합계가 새어 나갔다)
      select count(*) filter (where coalesce(status,'') not in ('cancelled','canceled','hold','expired')), count(*) filter (where status in ('cancelled','canceled'))
        into v_ticket_buy, v_ticket_cancel from public.tickets where user_id = p_user_id and restaurant_id::text = p_venue_id;
      select count(*) filter (where status = 'confirmed'), count(*) filter (where visit_status = 'no_show')
        into v_resv_conf, v_resv_noshow from public.reservation_requests where user_id = p_user_id and venue_id = p_venue_id;
      return query
      select p.display_name, p.phone, p.nationality, p.membership_tier, (v_ticket_buy + v_resv_conf)::int, (v_ticket_cancel + v_resv_noshow)::int,
             (select count(*)::int from public.reservation_requests rr where rr.user_id = p_user_id and rr.venue_id = p_venue_id and rr.visit_status = 'attended'),
             (select max(rr.reserve_date) from public.reservation_requests rr where rr.user_id = p_user_id and rr.venue_id = p_venue_id and rr.visit_status = 'attended')
        from public.profiles p where p.id = p_user_id;
    end $b$ $f$;
    insert into _pg(항목, 결과) values ('F get_requester_info 매장 범위로', '✅');
  else
    insert into _pg(항목, 결과) values ('F get_requester_info', '✅ 함수 없음(예약 요청 1단계 미설치) — 건너뜀');
  end if;
exception when others then insert into _pg(항목, 결과) values ('F get_requester_info', '❌ ' || left(sqlerrm, 160));
end $do$;

-- ── G. 파트너 RPC ──
-- 회원이 쓸 수 있는 칸의 숫자를 안전하게 읽는다(결제 내역 보고와 같은 도우미가 있으면 그것)
create or replace function public._taam_pt_num(p text)
returns numeric language sql immutable as $$ select case when p ~ '^\s*-?\d{1,13}(\.\d+)?\s*$' then round(p::numeric, 2) end $$;
revoke all on function public._taam_pt_num(text) from public, anon, authenticated;

-- 이 매장 예약 한 줄 (tickets 행) — 예치금·다른 매장 것은 없다
create or replace function public._taam_pt_row(t public.tickets, p_rest text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', t.id, 'pid', t.purchase_id, 'status', lower(coalesce(t.status, '')), 'visit_status', t.visit_status,
    'kind', case when coalesce(t.purchase_id, '') like 'MAN-%' then 'manual' when coalesce(t.purchase_id, '') like 'INV%' then 'invite'
                 when coalesce(t.purchase_id, '') like 'LINK-%' then 'link' when coalesce(t.purchase_id, '') like 'KSK-%' then 'settle' else 'app' end,
    'date', coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(tp.date)),
    'date_raw', coalesce(t.reservation_date, tp.date), 'time', coalesce(nullif(t.visit_time, ''), tp.time), 'pax', t.party_size, 'price', t.price,
    'tp_id', t.ticket_product_id, 'tp_label', tp.ticket_type,
    'uid', case when coalesce(t.purchase_id, '') ~ '^(MAN|KSK|INVH)-' then null   -- 운영 행의 user_id 는 어드민이다
                when coalesce(t.purchase_id, '') like 'LINK-%' and coalesce(t.extra_data->>'memberUid', '') = '' then null else t.user_id end,
    'buyer', coalesce(nullif(btrim(p.display_name), ''), nullif(btrim(t.buyer_name), '')),
    'phone', coalesce(nullif(btrim(to_jsonb(p)->>'phone'), ''), nullif(btrim(t.buyer_phone), '')),
    'tier', to_jsonb(p)->>'membership_tier',
    'created_at', t.created_at, 'cancelled_at', coalesce(t.cancelled_at, public._taam_sr_ts(t.extra_data->>'server_cancelled_at'), public._taam_sr_ts(t.extra_data->>'cancelled_at')),
    'cancel_reason', left(t.extra_data->>'cancel_reason', 120), 'cancelled_by', left(t.extra_data->>'cancelled_by_role', 20),
    'used_at', t.used_at, 'visit_marked_at', t.visit_marked_at,
    'memo', left(t.extra_data->>'admin_memo', 300), 'ttype', left(t.extra_data->>'ttype', 40),
    -- 돌려준 돈: 이 구매의 예치금 환불(원장 · 서버만 쓰는 표) + 카드 환불 완료 + 결제 링크 환불 — 예치금 잔액이 아니라 이 결제에 붙은 금액
    'refund_dep', (select sum(d.amount) from public.deposit_transactions d where d.user_id = t.user_id and d.amount > 0
                     and d.metadata->>'purchase_id' = t.purchase_id and d.change_type in ('ticket_refund', 'ticket_pax_change') and not (d.metadata ? 'fix')),
    'refund_card', case when t.extra_data->'card_refund_pending'->>'status' = 'done' then public._taam_pt_num(coalesce(t.extra_data->'card_refund_pending'->>'refunded_amount', t.extra_data->'card_refund_pending'->>'amount')) end,
    'card_refund_pending', case when t.extra_data->'card_refund_pending'->>'status' = 'pending' then public._taam_pt_num(t.extra_data->'card_refund_pending'->>'amount') end,
    'refund_link', (select c.refund_krw from public.kashikiri_charges c where c.id::text = t.extra_data->>'chargeId' limit 1),
    'pay_kind', case when coalesce(t.purchase_id, '') like 'LINK-%' or coalesce(t.purchase_id, '') like 'KSK-%' then 'card_link'
                     when public._taam_pt_num(t.extra_data->>'cardPaid') > 0 then 'card_mixed'
                     when coalesce(t.purchase_id, '') like 'MAN-%' then 'offline' else 'deposit' end
  ))
    from (select 1) z
    left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
    left join public.profiles p on p.id = t.user_id and coalesce(t.purchase_id, '') !~ '^(MAN|KSK|INVH)-' and not (coalesce(t.purchase_id, '') like 'LINK-%' and coalesce(t.extra_data->>'memberUid', '') = '')
   limit 1
$$;
revoke all on function public._taam_pt_row(public.tickets, text) from public, anon, authenticated;

create or replace function public.taam_partner_reservations(p_rest text, p_from date default null, p_to date default null, p_q text default null, p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_q text := lower(btrim(coalesce(p_q, ''))); v_qd text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(p_rest)) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_from is not null and p_to is not null and p_to <= p_from then raise exception 'BAD_RANGE' using errcode = '22023'; end if;
  select coalesce(jsonb_agg(r order by (r->>'date') desc nulls last, (r->>'time') desc nulls last, (r->>'created_at') desc), '[]'::jsonb) into v
    from (
      select public._taam_pt_row(t, p_rest) as r
        from public.tickets t
        left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
        left join public.profiles p on p.id = t.user_id
       where t.restaurant_id::text = p_rest
         and lower(coalesce(t.status, '')) not in ('hold', 'expired')
         and (p_from is null or coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(tp.date)) >= p_from)
         and (p_to   is null or coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(tp.date)) <  p_to)
         and (coalesce(p_status, '') = '' or
              (p_status = 'cancelled' and lower(coalesce(t.status, '')) in ('cancelled', 'canceled')) or
              (p_status = 'active' and lower(coalesce(t.status, '')) in ('active', 'manual', 'used', 'pending_confirm')) or
              (p_status = 'noshow' and t.visit_status = 'no_show') or
              (p_status = 'visited' and (t.visit_status = 'attended' or lower(coalesce(t.status, '')) = 'used')))
         and (v_q = '' or lower(coalesce(p.display_name, '')) like '%' || v_q || '%' or lower(coalesce(t.buyer_name, '')) like '%' || v_q || '%'
              or lower(coalesce(t.purchase_id, '')) like '%' || v_q || '%' or lower(coalesce(to_jsonb(p)->>'email', '')) like '%' || v_q || '%'
              or (length(v_qd) >= 4 and (regexp_replace(coalesce(to_jsonb(p)->>'phone', ''), '\D', '', 'g') like '%' || v_qd || '%'
                                         or regexp_replace(coalesce(t.buyer_phone, ''), '\D', '', 'g') like '%' || v_qd || '%')))
       order by t.created_at desc
       limit 1500) z;
  return jsonb_build_object('ok', true, 'rest_id', p_rest, 'rows', v, 'generated_at', now());
end $$;
revoke all on function public.taam_partner_reservations(text, date, date, text, text) from public, anon;
grant execute on function public.taam_partner_reservations(text, date, date, text, text) to authenticated;

-- 한 회원 — 이름·연락처·등급·국적·언어 + 이 매장 통계 + 이 매장 내역. 예치금 잔액 · 다른 매장은 없다
create or replace function public.taam_partner_member(p_rest text, p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_p record; v_rows jsonb; v_inv jsonb; v_related boolean;
begin
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(p_rest)) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- 이 매장에 예약(좌석 행 · 초대)이 있는 회원만
  v_related := exists (select 1 from public.tickets t where t.user_id = p_uid and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold', 'expired'))
            or exists (select 1 from public.reservation_invites i where i.invitee_user_id = p_uid and i.restaurant_id::text = p_rest);
  if not v_related then raise exception 'NOT_RELATED: 이 매장에 예약한 회원이 아닙니다' using errcode = '42501'; end if;
  select p.id, nullif(btrim(p.display_name), '') as display_name, to_jsonb(p)->>'phone' as phone, to_jsonb(p)->>'email' as email,
         to_jsonb(p)->>'membership_tier' as tier, to_jsonb(p)->>'nationality' as nationality, to_jsonb(p)->>'country' as country,
         to_jsonb(p)->>'display_name_en' as display_name_en, to_jsonb(p)->>'currency' as currency, p.created_at
    into v_p from public.profiles p where p.id = p_uid;
  if v_p.id is null then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select coalesce(jsonb_agg(r order by (r->>'date') desc nulls last, (r->>'created_at') desc), '[]'::jsonb) into v_rows
    from (select public._taam_pt_row(t, p_rest) as r from public.tickets t
           where t.user_id = p_uid and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold', 'expired') order by t.created_at desc limit 300) z;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', i.id, 'status', i.status, 'date', public._taam_pu_visit_date(i.visit_date), 'time', i.visit_time, 'pax', i.pax,
                   'total', i.total_amount, 'created_at', i.created_at, 'paid_at', i.paid_at, 'cancelled_at', i.cancelled_at)) order by i.created_at desc), '[]'::jsonb) into v_inv
    from public.reservation_invites i where i.invitee_user_id = p_uid and i.restaurant_id::text = p_rest;
  return jsonb_build_object('ok', true, 'rest_id', p_rest,
    'member', jsonb_strip_nulls(jsonb_build_object('id', v_p.id, 'name', v_p.display_name, 'name_en', v_p.display_name_en, 'phone', v_p.phone, 'email', v_p.email,
                'tier', v_p.tier, 'nationality', v_p.nationality, 'country', v_p.country, 'currency', v_p.currency, 'joined_at', v_p.created_at)),
    'stats', jsonb_build_object(
      'visits', (select count(*) from public.tickets t where t.user_id = p_uid and t.restaurant_id::text = p_rest and (t.visit_status = 'attended' or lower(coalesce(t.status, '')) = 'used')),
      'no_shows', (select count(*) from public.tickets t where t.user_id = p_uid and t.restaurant_id::text = p_rest and t.visit_status = 'no_show'),
      'cancels', (select count(*) from public.tickets t where t.user_id = p_uid and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) in ('cancelled', 'canceled')),
      'upcoming', (select count(*) from public.tickets t left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
                    where t.user_id = p_uid and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) in ('active', 'manual', 'pending_confirm')
                      and coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(tp.date)) >= (now() at time zone 'Asia/Seoul')::date)),
    'rows', v_rows, 'invites', v_inv);
end $$;
revoke all on function public.taam_partner_member(text, uuid) from public, anon;
grant execute on function public.taam_partner_member(text, uuid) to authenticated;

-- 회원 찾기 — 이 매장에 예약·초대가 있는 회원만(전체 회원 명부를 이름·번호로 훑던 길을 닫는다)
create or replace function public.taam_partner_member_search(p_rest text, p_q text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_q text := lower(btrim(coalesce(p_q, ''))); v_qd text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(p_rest)) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(v_q) < 2 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', p.id, 'display_name', nullif(btrim(p.display_name), ''), 'phone', to_jsonb(p)->>'phone', 'email', to_jsonb(p)->>'email',
                   'membership_tier', to_jsonb(p)->>'membership_tier', 'nationality', to_jsonb(p)->>'nationality',
                   'last_visit', (select max(coalesce(public._taam_pu_visit_date(t.reservation_date), t.created_at::date)) from public.tickets t where t.user_id = p.id and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold','expired','cancelled','canceled'))))
                 order by p.display_name), '[]'::jsonb) into v
    from public.profiles p
   where coalesce(to_jsonb(p)->>'deleted_at', '') = ''
     and (
          -- ① 이 매장에 예약·초대가 있는 회원은 부분 일치로
          ((exists (select 1 from public.tickets t where t.user_id = p.id and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold', 'expired'))
            or exists (select 1 from public.reservation_invites i where i.invitee_user_id = p.id and i.restaurant_id::text = p_rest))
           and (lower(coalesce(p.display_name, '')) like '%' || v_q || '%' or lower(coalesce(to_jsonb(p)->>'email', '')) like '%' || v_q || '%'
                or (length(v_qd) >= 4 and regexp_replace(coalesce(to_jsonb(p)->>'phone', ''), '\D', '', 'g') like '%' || v_qd || '%')))
          -- ② 그 밖의 회원은 **전화번호를 끝까지 정확히** 쳤을 때만(10자리 이상 · 010 ↔ +8210 같은 끝 10자리) — 단골을 초대할 길은 두되 명부 훑기는 막는다
          or (length(v_qd) >= 10 and right(regexp_replace(coalesce(to_jsonb(p)->>'phone', ''), '\D', '', 'g'), 10) = right(v_qd, 10))
         )
   limit 20;
  return v;
end $$;
revoke all on function public.taam_partner_member_search(text, text) from public, anon;
grant execute on function public.taam_partner_member_search(text, text) to authenticated;

-- 이름 채우기 — 화면이 가진 uid 들의 이름·연락처·등급·통화만(이 매장에 예약·초대가 있는 회원만 · 잔액 없음).
--   오늘 화면·예약 탭·캘린더·보낸 초대 목록이 profiles 를 직접 읽던 자리(파트너는 이제 자기 행만 읽힌다)가 이걸 쓴다.
create or replace function public.taam_partner_names(p_rest text, p_uids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(p_rest)) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_uids is null or coalesce(array_length(p_uids, 1), 0) = 0 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', p.id, 'display_name', nullif(btrim(p.display_name), ''), 'phone', to_jsonb(p)->>'phone', 'email', to_jsonb(p)->>'email',
                   'membership_tier', to_jsonb(p)->>'membership_tier', 'currency', to_jsonb(p)->>'currency', 'nationality', to_jsonb(p)->>'nationality'))), '[]'::jsonb) into v
    from public.profiles p
   where p.id = any (p_uids[1:500])
     and (exists (select 1 from public.tickets t where t.user_id = p.id and t.restaurant_id::text = p_rest)
          or exists (select 1 from public.reservation_invites i where i.invitee_user_id = p.id and i.restaurant_id::text = p_rest));
  return v;
end $$;
revoke all on function public.taam_partner_names(text, uuid[]) from public, anon;
grant execute on function public.taam_partner_names(text, uuid[]) to authenticated;

-- ── I. 덤 — 조회 함수 권한 ──
-- uuid → 이메일 조회가 누구에게나 열려 있었다(기본 PUBLIC EXECUTE). 본인·슈퍼어드민·서버만. (profiles 역할 가드 트리거가 본인 id 로 부른다 — 그대로 된다)
create or replace function public._taam_auth_email(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null or auth.uid() = p_id or public._taam_uid_is_super()
              then (select u.email::text from auth.users u where u.id = p_id) end
$$;
do $do$
declare r record; v text := '';
begin
  for r in select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('taam_user_tier', 'taam_invited_tier', 'taam_is_banned', 'taam_can_manage_ticket_as', 'get_requester_info', 'confirm_reservation', 'decline_reservation', 'mark_reservation_visit', 'set_reservation_admin_memo') loop
    execute format('revoke all on function public.%I(%s) from public, anon', r.proname, r.args);
    execute format('grant execute on function public.%I(%s) to authenticated', r.proname, r.args);
    v := v || r.proname || ' · ';
  end loop;
  insert into _pg(항목, 결과) values ('I anon 회수', '✅ ' || coalesce(nullif(v, ''), '(없음)'));
exception when others then insert into _pg(항목, 결과) values ('I anon 회수', '⚠ ' || left(sqlerrm, 120));
end $do$;

-- ── 확인 (하나로 · ❌ 가 없어야 정상 · 사람·매장 이름 없음) ──
insert into _pg(항목, 결과) values
 ('B 판정 함수 taam_rest_admin_ok', case when to_regprocedure('public.taam_rest_admin_ok(text)') is not null then '✅' else '❌' end),
 ('B 옛 이름 7개가 새 판정으로', case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('is_ticket_admin_of','is_restaurant_admin_of','is_venue_admin_of','taam_is_rest_admin','taam_can_mark_visit','taam_can_manage_ticket_as','_taam_rest_note_ok')
       and p.prosrc like '%taam_rest_admin_ok%') = 7 then '✅' else '❌' end),
 ('C tickets INSERT 가드 새 판', case when exists (select 1 from pg_proc where proname = 'taam_guard_ticket_insert' and prosrc like '%TAAM_GUARD_TICKET_INSERT_V2%') then '✅' else '❌' end),
 ('D ticket_products 정책(읽기 · 파트너 3)', case when (select count(*) from pg_policies where tablename = 'ticket_products' and policyname in ('ticket_products_read','ticket_products_partner_insert','ticket_products_partner_update','ticket_products_partner_delete')) = 4 then '✅' else '❌' end),
 ('D 승인 트리거 둘', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_ticket_approval_notify') and exists (select 1 from pg_trigger where tgname = 'trg_enforce_ticket_approval') then '✅' else '❌' end),
 ('E 초대 매장 일치 트리거', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_invite_rest') then '✅' else '❌' end),
 ('F profiles 전 칸 읽기 정책 없음', case when not exists (select 1 from pg_policies where tablename = 'profiles' and policyname = 'profiles read by venue admin for requesters') then '✅' else '❌' end),
 ('G 파트너 RPC 다섯', case when to_regproc('public.taam_partner_reservations') is not null and to_regproc('public.taam_partner_member') is not null
     and to_regproc('public.taam_partner_member_search') is not null and to_regproc('public.taam_partner_my_grants') is not null
    and to_regproc('public.taam_partner_names') is not null then '✅' else '❌' end),
 ('H 슈퍼어드민 RPC 둘', case when to_regproc('public.taam_partner_grants_list') is not null and to_regproc('public.taam_partner_grant_set') is not null then '✅' else '❌' end),
 ('I _taam_auth_email 본인·슈퍼어드민만', case when exists (select 1 from pg_proc where proname = '_taam_auth_email' and prosrc like '%auth.uid() = p_id%') then '✅' else '❌' end),
 ('A 권한 상태 분포(정보)', (select coalesce(string_agg(status || ' ' || n, ' · '), '없음') from (select status, count(*) n from public.admin_grants group by status) z));
select 항목, 결과 from _pg order by seq;
