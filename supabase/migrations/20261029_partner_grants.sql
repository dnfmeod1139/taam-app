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
alter table public.admin_grants add column if not exists prev_status text;   -- 정지(suspended) 직전 상태 — 되살리기(Edge restore)가 그 상태로 돌린다
alter table public.admin_grants add column if not exists suspended_via text; -- 누가 정지했나: 'rpc'(슈퍼어드민 「정지」) · 'account'(Edge 계정 해지) — 계정 되살리기는 'account' 줄만 되살린다(2차 리뷰)
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
  -- 도장: 로그인 호출은 auth.uid() 로 고정 · 서버 호출(auth.uid() null — Edge partner-account · SQL Editor)만 보낸 값을 받는다(trg_taam_fee_from_deduct 의 by 와 같은 규칙)
  if new.status not in ('pending', 'approved', 'suspended') then new.status := 'pending'; end if;
  if tg_op = 'INSERT' then
    new.status_set_at := now(); new.status_set_by := coalesce(auth.uid(), new.status_set_by);
    if new.status = 'approved' then new.approved_at := coalesce(new.approved_at, now()); new.approved_by := coalesce(auth.uid(), new.approved_by);
    else new.approved_at := null; new.approved_by := null; end if;
    new.prev_status := null; new.suspended_via := case when new.status = 'suspended' then coalesce(new.suspended_via, 'rpc') else null end;
    if new.granted_by is null then new.granted_by := auth.uid(); end if;
  elsif new.status is distinct from old.status then
    new.status_set_at := now(); new.status_set_by := coalesce(auth.uid(), new.status_set_by);
    if new.status = 'approved' then
      new.approved_at := now(); new.approved_by := coalesce(auth.uid(), new.approved_by);
    elsif new.status = 'pending' then
      new.approved_at := null; new.approved_by := null;          -- 「대기로」 = 승인 철회 — approved_at 이 「지금 승인 상태(또는 승인 상태에서 정지)」만 뜻하게
    else
      new.approved_at := old.approved_at; new.approved_by := old.approved_by;
    end if;
    new.prev_status := case when new.status = 'suspended' then old.status else null end;
    new.suspended_via := case when new.status = 'suspended' then coalesce(new.suspended_via, 'rpc') else null end;
  else
    new.status_set_at := old.status_set_at; new.status_set_by := old.status_set_by;
    new.approved_at := old.approved_at; new.approved_by := old.approved_by;
    new.prev_status := old.prev_status; new.suspended_via := old.suspended_via;
  end if;
  return new;
end $$;
-- 운영 메모(note)는 슈퍼어드민 몫 — 파트너는 「ag select」(자기 줄) 로 표를 직접 읽을 수 있어 RPC 가 note 를 빼도 소용이 없었다(3차 리뷰 재현).
--   칸 단위 권한: authenticated 의 표 select 를 거두고 note 를 뺀 칸만 다시 준다(슈퍼어드민 목록은 security definer RPC 가 읽는다 · 앱 직접 읽기는 rest_id·venue_id·label·status 뿐).
--   표에 칸이 늘면 기본은 못 읽는다 — 그때 이 블록이 다시 돌아 note 밖의 칸을 준다.
do $do$
declare v_cols text;
begin
  select string_agg(format('%I', c.column_name), ', ' order by c.ordinal_position) into v_cols
    from information_schema.columns c where c.table_schema = 'public' and c.table_name = 'admin_grants' and c.column_name <> 'note';
  execute 'revoke select on public.admin_grants from public, authenticated, anon';
  execute format('grant select (%s) on public.admin_grants to authenticated', v_cols);
  insert into _pg(항목, 결과) values ('A admin_grants 칸 권한(note 제외)', '✅');
exception when others then insert into _pg(항목, 결과) values ('A admin_grants 칸 권한(note 제외)', '❌ ' || left(sqlerrm, 160));
end $do$;
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
revoke all on function public.taam_rest_admin_ok_for(uuid, text) from public, anon, authenticated;   -- 부르는 곳은 전부 security definer(소유자 권한) — 회원에게 열 이유가 없다
revoke all on function public.taam_rest_admin_ok(text) from public, anon;
grant execute on function public.taam_rest_admin_ok(text) to authenticated;   -- SECURITY INVOKER 트리거(taam_guard_ticket_insert)가 호출자 권한으로 부른다 · 안은 definer

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
    if v_old = p_status then
      -- 상태가 같으면 아무것도 안 바꾼다 — 도장·메모·알림이 반복되지 않게(4차 리뷰: 화면을 열 때마다 「승인되었습니다」가 쌓였다)
      return jsonb_build_object('ok', true, 'id', v_id, 'from', v_old, 'to', p_status, 'changed', false);
    end if;
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
  return jsonb_build_object('ok', true, 'id', v_id, 'from', v_old, 'to', p_status, 'changed', true);
end $$;
revoke all on function public.taam_partner_grant_set(uuid, text, text, text) from public, anon;
grant execute on function public.taam_partner_grant_set(uuid, text, text, text) to authenticated;

-- 파트너 본인 — 내 권한(앱이 역할·화면을 정한다)
create or replace function public.taam_partner_my_grants()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'rest_id', g.rest_id, 'venue_id', g.venue_id, 'label', coalesce(r.name, g.label), 'status', g.status, 'approved_at', g.approved_at))
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
  elsif exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'taam_guard_ticket_insert' and p.prosrc like '%TAAM_GUARD_TICKET_INSERT_V2%') then insert into _pg(항목, 결과) values ('C taam_guard_ticket_insert', '✅ 이미 새 판 → 다시 만든다');
  else insert into _pg(항목, 결과) values ('C taam_guard_ticket_insert', '⚠ 모르는 판(' || left(v_md5, 8) || ') — 교체한다(권한 판정은 이 파일이 바꾸는 것)');
  end if;
end $do$;
-- 연결 회차 검사 — INSERT 가드는 SECURITY INVOKER 라 RLS 가 숨긴(다른 매장의 승인 대기) 회차를 「없는 회차」로 봤다(2차 리뷰) → definer 도우미.
--   3차 리뷰: 도우미가 아무에게나 매장·상태를 돌려줘 숨은 승인 대기 회차의 존재를 묻는 오라클이 됐다 → **그 매장의 승인 어드민(또는 슈퍼어드민)만** 답을 받고,
--   없는 회차·다른 매장 회차는 같은 답('bad')이다. 승인 대기 회차를 막는 일은 아래 trg_taam_guard_ticket_round_open 이 한다.
drop function if exists public._taam_tp_rest_status(text);
create or replace function public._taam_tp_seat_check(p_tp text, p_rest text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_rest text; v_st text;
begin
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(p_rest)) then return null; end if;
  select tp.rest_id::text, lower(coalesce(tp.status, '')) into v_rest, v_st from public.ticket_products tp where tp.id::text = p_tp;
  if not found or v_rest is distinct from p_rest then return 'bad'; end if;
  return case when v_st = 'pending' then 'pending' else 'ok' end;
end $$;
revoke all on function public._taam_tp_seat_check(text, text) from public, anon;
grant execute on function public._taam_tp_seat_check(text, text) to authenticated;   -- INVOKER 가드가 호출자 권한으로 부른다 · 안에서 권한을 다시 본다
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
drop trigger if exists trg_taam_guard_ticket_insert on public.tickets;
create trigger trg_taam_guard_ticket_insert
  before insert on public.tickets
  for each row execute function public.taam_guard_ticket_insert();

-- 승인 대기 회차에는 좌석을 못 넣는다 — 로그인 호출 전부(회원 PAYH- 홀드 · 매장 어드민 MAN-/INVH- · 매장 어드민이 부른 서버 함수의 LINK- 홀드 …).
--   슈퍼어드민은 운영 좌석(MAN-·INVH-)만 막는다(승인 대기 회차에 좌석이 차면 매진 동기화가 공개 상태로 밀던 길) · 서버(auth.uid() null)는 그대로.
--   security definer 트리거 — 회원은 RLS 로 승인 대기 회차를 못 보므로 INVOKER 가드로는 못 센다(3차 리뷰: 회원이 숨은 회차 id 로 홀드를 넣어 승인 전 회차를 살 수 있었다).
create or replace function public.taam_guard_ticket_round_open()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_pay boolean;
begin
  if coalesce(new.ticket_product_id::text, '') = '' then return new; end if;
  if lower(coalesce(new.status, '')) in ('cancelled', 'canceled', 'expired') then return new; end if;
  -- UPDATE 는 회차를 옮기거나 죽은 행을 되살릴 때만 본다(그 밖의 갱신 — 출석·메모·취소 — 은 그대로)
  if TG_OP = 'UPDATE' and new.ticket_product_id::text is not distinct from old.ticket_product_id::text
     and lower(coalesce(old.status, '')) not in ('cancelled', 'canceled', 'expired') then return new; end if;
  -- 회원 결제 행(PAYH-·PAYC-)은 **누가 넣든** 막는다 — 서버(카드 확정 폴백 INSERT · auth.uid() null)로 숨은 회차를 사던 길(4차 리뷰)
  v_pay := coalesce(new.purchase_id, '') like 'PAY%';
  if not v_pay then
    if auth.uid() is null then return new; end if;   -- 서버의 운영 행(KSK- 정산 동기화 · LINK- 결제 확정)은 그대로
    if public.is_super_admin(auth.uid()) and not (coalesce(new.purchase_id, '') like 'MAN-%' or coalesce(new.purchase_id, '') like 'INVH-%') then return new; end if;
  end if;
  if exists (select 1 from public.ticket_products tp where tp.id::text = new.ticket_product_id::text and lower(coalesce(tp.status, '')) = 'pending') then
    raise exception 'TICKET_NOT_APPROVED: 승인 대기 회차에는 좌석을 넣을 수 없습니다' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists trg_taam_guard_ticket_round_open on public.tickets;
create trigger trg_taam_guard_ticket_round_open
  before insert or update of ticket_product_id, status on public.tickets
  for each row execute function public.taam_guard_ticket_round_open();

-- ── D. ticket_products — 파트너 정책 · 승인 대기 비공개 · 수정은 큐(ticket_product_edits) · 알림 ──
--   ⚠ 1차 판은 「승인된 회차의 내용을 고치면 status 를 pending 으로 되돌린다」였다 — 적대 리뷰(재현)가 넷을 짚었다:
--     ① 회원이 산 회차가 pending 이 되어 그 회원에게도 안 보인다 ② 파트너가 한 글자 고쳐 pending 으로 만든 뒤 DELETE → 회원 티켓이 고아
--     ③ 매진 동기화(tickets 트리거)가 보낸 중첩 UPDATE 를 회원 세션 것으로 보고 NOT_YOUR_RESTAURANT → **회원의 마지막 좌석 구매·취소·홀드 반납이 통째로 막혔다** ④ 앱이 'pending' 을 보내 내용이 같아도 거절.
--   → 승인된 회차의 status 는 파트너 수정으로 바뀌지 않는다. 바뀐 칸은 **되돌리고 별도 표 `ticket_product_edits`(회차마다 한 줄 · 바뀐 칸 → 새 값)에 적는다** — 슈퍼어드민이 「수정 승인」
--     (taam_ticket_edit_review)을 누르면 그때 반영된다. 2차 리뷰: 큐를 행의 칸(pending_edit)에 두면 회원·anon 이 select('*') 로 미승인 값을 그대로 내려받고 크기 상한도 없었다 → 별도 표(RLS 슈퍼어드민·그 매장 승인 어드민만) + 상한.
--   중첩 갱신(pg_trigger_depth() > 1 · tickets 트리거·서버 함수)은 **어느 세션이든** 승인 대기 회차의 status 를 지킨다(2차 리뷰 — 슈퍼어드민·서버 세션에서 좌석이 차면 soldout 으로 바뀌어 승인 없이 공개됐다).
alter table public.ticket_products add column if not exists approved_by uuid;
alter table public.ticket_products add column if not exists approved_at timestamptz;
alter table public.ticket_products add column if not exists review_note text;

-- 파트너 수정 큐 — 회차마다 한 줄. 회원·anon 은 못 읽는다(미승인 값이 회원 기기에 내려가지 않게). 쓰기는 트리거·RPC(security definer)만.
create table if not exists public.ticket_product_edits (
  ticket_id    text primary key,
  rest_id      text,
  edit         jsonb not null,
  requested_by uuid,
  requested_at timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.ticket_product_edits enable row level security;
revoke all on table public.ticket_product_edits from public, anon, authenticated;
grant select on table public.ticket_product_edits to authenticated;
drop policy if exists tpe_read on public.ticket_product_edits;
create policy tpe_read on public.ticket_product_edits for select to authenticated
  using (public._taam_uid_is_super() or public.taam_rest_admin_ok(rest_id));

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
-- 삭제는 **한 번도 승인된 적 없는** 자기 매장 대기 회차만(승인된 회차는 status 가 pending 으로 돌아오지 않으니 approved_at 으로 한 번 더 못 박는다)
create policy ticket_products_partner_delete on public.ticket_products
  for delete to authenticated
  using (public.taam_rest_admin_ok(rest_id::text) and coalesce(status, '') = 'pending' and approved_at is null);

-- 칸 셋: FREE(파트너가 승인 없이 바꿔도 되는 것 · 서버·트리거 몫) · REVERT(파트너는 못 바꾼다 — 예외 없이 되돌린다 · 슈퍼어드민 몫) · 그 밖 = 내용(큐). 칸이 늘면 기본은 큐.
create or replace function public._taam_tp_free_cols()
returns text[] language sql immutable as $$
  select array['status', 'updated_at', 'auto_soldout', 'approved_by', 'approved_at', 'review_note',
               'tile_photo', 'i18n_status_en', 'i18n_status_jp', 'i18n_status_ja', 'i18n_jp_approved',
               'repurchase_open', 'audience', 'uploaded_by', 'uploader_rest_id', 'rest_name', 'created_at', 'reg_date',
               'repurchase_open_at', 'guest_open', 'guest_open_reason', 'guest_price', 'guest_seat_qty', 'guest_opened_at', 'guest_opened_by']
$$;
create or replace function public._taam_tp_revert_cols()
returns text[] language sql immutable as $$
  -- ⚠ 판매 오픈(sale_state · sale_open_at)은 여기 없다 — 파트너 업로드 폼이 고르는 값이고(예약 오픈 · 비공개 보관), 되돌리면 승인 순간 바로 판매됐다(3차 리뷰) · 내용 칸이라 승인된 회차에선 큐로 간다
  --   게스트석(guest_*)·재구매 해제 시각은 슈퍼어드민 RPC(taam_guest_seat_open · taam_ticket_repurchase_open)가 적는 칸이다 — 파트너가 큐로 도장을 위조하던 길(4차 리뷰)
  select array['approved_by', 'approved_at', 'review_note', 'repurchase_open', 'audience', 'uploaded_by', 'uploader_rest_id', 'rest_name', 'created_at', 'reg_date',
               'repurchase_open_at', 'guest_open', 'guest_open_reason', 'guest_price', 'guest_seat_qty', 'guest_opened_at', 'guest_opened_by']
$$;
-- 값 정규화 — 앱은 빈 칸을 0/''/false/null 로 섞어 보낸다(meal_fee: x||0 · slots {s1:0,s2:0,s4:0} · type_class 'std'). 그 차이를 「내용 변경」으로 보지 않는다.
create or replace function public._taam_tp_norm(v jsonb)
returns jsonb language sql immutable as $$
  select case when v is null or jsonb_typeof(v) = 'null' then null
              when jsonb_typeof(v) = 'number' and v = '0'::jsonb then null
              when jsonb_typeof(v) = 'string' and btrim(v #>> '{}') in ('', 'std') then null
              when jsonb_typeof(v) = 'boolean' and v = 'false'::jsonb then null
              when jsonb_typeof(v) = 'array' and v = '[]'::jsonb then null
              -- 객체는 빈 값 키(null · 0 · '' · false)를 뺀 모양으로 견준다 — 앱의 slots 가 strict:false 를 넣었다 뺐다 해서 바뀐 것 없는 저장이 수정 신청이 됐다(4차 리뷰)
              when jsonb_typeof(v) = 'object' then (select case when count(*) = 0 then null else jsonb_object_agg(e.key, e.value) end
                                                      from jsonb_each(v) e where not (jsonb_typeof(e.value) = 'null' or e.value in ('0'::jsonb, '""'::jsonb, 'false'::jsonb)))
              else v end
$$;
-- 칸별 정규화 — 앱은 판매 오픈을 비워 두지 않고 'open' 을 보낸다(로더: sale_state || 'open') · 서버의 null 과 같다(아니면 매진 토글마다 「판매 상태 open」 수정 신청이 쌓인다)
create or replace function public._taam_tp_normk(p_k text, v jsonb)
returns jsonb language sql immutable as $$
  select case when p_k = 'sale_state' and jsonb_typeof(v) = 'string' and v #>> '{}' = 'open' then null else public._taam_tp_norm(v) end
$$;
-- 승인 대상 칸 중 바뀐 것만 { 칸: 새 값 }
create or replace function public._taam_tp_content_diff(p_old jsonb, p_new jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, p_new -> k), '{}'::jsonb)
    from (select distinct k from (select jsonb_object_keys(p_old) k union all select jsonb_object_keys(p_new)) z) keys
   where not (k = any (public._taam_tp_free_cols()))
     and public._taam_tp_normk(k, p_old -> k) is distinct from public._taam_tp_normk(k, p_new -> k)
$$;
-- 글자 검사 도우미 — v 안의 글자(jsonb 안쪽 포함) 중 **옛 값에 없던 것**이 HTML 태그 모양(<글자 · </ · <! · <?) 이거나 javascript: 면 true
create or replace function public._taam_text_bad(v jsonb, p_old jsonb)
returns boolean language sql immutable as $$
  select exists (
    select 1 from jsonb_path_query(v, 'strict $.** ? (@.type() == "string")') x
     where ((x #>> '{}') ~* '<\s*[a-z/!?]' or (x #>> '{}') ~* 'javascript\s*:')
       and (p_old is null or not exists (select 1 from jsonb_path_query(p_old, 'strict $.** ? (@.type() == "string")') y where (y #>> '{}') = (x #>> '{}'))))
$$;
revoke all on function public._taam_text_bad(jsonb, jsonb) from public, anon;
grant execute on function public._taam_text_bad(jsonb, jsonb) to authenticated;   -- INVOKER 트리거(taam_guard_text_input)가 호출자 권한으로 부른다 · 읽기만

-- 파트너 입력 검사 — 바뀐 칸만 본다(옛 행의 옛 모양 때문에 매진 토글이 막히지 않게).
--   id·date·time 은 형식(앱 피커가 만드는 모양) · 그 밖의 글자(jsonb 안쪽 포함)는 HTML 태그 모양(<글자 · </ · <! · <?)과 javascript: 금지.
--   승인 대기 카드·캘린더·회원 화면 여러 곳이 이 값을 innerHTML 로 그린다 — 파트너가 쓴 값이 슈퍼어드민 세션에서 돌던 길(4차 리뷰 재현).
create or replace function public._taam_tp_check_input(p_new jsonb, p_old jsonb)
returns void language plpgsql immutable as $$
declare k text; v jsonb; s text;
begin
  for k, v in select e.key, e.value from jsonb_each(p_new) e loop
    if p_old is not null and (p_old -> k) is not distinct from v then continue; end if;
    if v is null or jsonb_typeof(v) = 'null' then continue; end if;
    if k = 'id' and not (v #>> '{}' ~ '^[0-9A-Za-z_.:-]{1,64}$') then
      raise exception 'BAD_INPUT: 회차 id 모양이 아닙니다' using errcode = '22023';
    elsif k = 'date' and not (btrim(v #>> '{}') ~ '^(\d{4}\.)?\d{1,2}\.\d{1,2}$') then
      raise exception 'BAD_INPUT: 날짜 모양이 아닙니다(MM.DD 또는 YYYY.MM.DD)' using errcode = '22023';
    elsif k = 'time' and btrim(v #>> '{}') <> '' and not (btrim(v #>> '{}') ~ '^\d{1,2}:\d{2}$') then
      raise exception 'BAD_INPUT: 시각 모양이 아닙니다(HH:MM)' using errcode = '22023';
    end if;
    if public._taam_text_bad(v, case when p_old is null then null else p_old -> k end) then
      raise exception 'BAD_INPUT: % 칸에 HTML 태그 모양의 글자는 쓸 수 없습니다(꺾쇠 < 바로 뒤에 영문 — 예: <A코스> 대신 [A코스])', k using errcode = '22023';
    end if;
  end loop;
end $$;
revoke all on function public._taam_tp_check_input(jsonb, jsonb) from public, anon, authenticated;

-- 큐 크기 상한(글자 값 2,000자 · 전체 16KB) — notifications payload 상한(2026-10-25)과 같은 모양
create or replace function public._taam_tp_edit_ok(p jsonb)
returns boolean language sql immutable as $$
  select octet_length(p::text) <= 16384
     and not exists (select 1 from jsonb_each(p) e where jsonb_typeof(e.value) = 'string' and char_length(e.value #>> '{}') > 2000)
$$;
-- 큐에 적힌 수정을 슈퍼어드민에게 알린다(파트너마다 시간당 30건 · 같은 회차 10분 안 한 번 · 푸시는 taam_admin_push 가 있으면)
create or replace function public._taam_tp_edit_notify(p_id text, p_rest text, p_rest_name text, p_when text, p_by uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_rest text; v_n int;
begin
  begin
    if to_regprocedure('public.taam_rate_hit(text, integer, interval)') is not null
       and not public.taam_rate_hit('tp_approval_notify:' || coalesce(p_by::text, 'srv'), 30, interval '1 hour') then return; end if;
    if exists (select 1 from public.notifications n where n.type = 'ticket_upload_request' and n.payload->>'ticket_id' = p_id and n.payload->>'edit' = 'true'
                 and n.created_at > now() - interval '10 minutes') then return; end if;
    select name into v_rest from public.restaurants where id::text = p_rest;
    v_rest := coalesce(v_rest, p_rest_name, '매장');
    insert into public.notifications (user_id, type, title, body, url, payload)
    select p.id, 'ticket_upload_request', '티켓 수정 신청 — 승인 필요', v_rest || ' · ' || coalesce(p_when, ''), '/',
           jsonb_build_object('ticket_id', p_id, 'rest_id', p_rest, 'edit', true, 'via', 'enforce_ticket_approval')
      from public.profiles p where p.role in ('superadmin', 'super_admin');
    get diagnostics v_n = row_count;
    if v_n > 0 and to_regprocedure('public.taam_admin_push(text, text, text, text, text)') is not null then
      begin perform public.taam_admin_push('티켓 수정 신청 — 승인 필요', v_rest || ' · ' || coalesce(p_when, ''), '/', 'tpedit-' || p_id, 'admin'); exception when others then null; end;
    end if;
  exception when others then null;
  end;
end $$;
revoke all on function public._taam_tp_edit_notify(text, text, text, text, uuid) from public, anon, authenticated;

create or replace function public.enforce_ticket_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_diff jsonb; v_keep jsonb; v_old jsonb; v_merged jsonb; v_rest text;
begin
  -- ① 중첩 갱신(tickets 트리거의 매진 동기화 · 서버 함수) — **어느 세션이든** 승인 대기 회차의 status 는 지킨다(승인은 depth 1 의 직접 UPDATE 로만)
  if TG_OP = 'UPDATE' and pg_trigger_depth() > 1 and coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') <> 'pending' then
    NEW.status := 'pending';
  end if;
  -- 슈퍼어드민: 전부 허용 · 승인(pending→active/soldout) 때 도장
  if public.is_super_admin(auth.uid()) then
    if TG_OP = 'UPDATE' and coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') in ('active', 'soldout') then
      NEW.approved_by := auth.uid(); NEW.approved_at := now();
    end if;
    return NEW;
  end if;
  -- 서버(auth.uid() null — SQL Editor · service_role) · 중첩 갱신은 그대로
  if auth.uid() is null or pg_trigger_depth() > 1 then return NEW; end if;

  if TG_OP = 'INSERT' then
    -- 앱 저장은 PostgREST upsert(INSERT … ON CONFLICT DO UPDATE)라 있는 행에도 BEFORE INSERT 가 먼저 돈다 — 그때는 UPDATE 가지가 판정한다
    if exists (select 1 from public.ticket_products x where x.id::text = NEW.id::text) then return NEW; end if;
    if coalesce(NEW.status, '') <> 'pending' then
      raise exception 'ADMIN_MUST_UPLOAD_PENDING' using errcode = 'P0001';
    end if;
    if NEW.rest_id is null or not public.taam_rest_admin_ok(NEW.rest_id::text) then
      raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
    end if;
    NEW.approved_by := null; NEW.approved_at := null; NEW.review_note := null;
    NEW.repurchase_open := false;
    -- 게스트석(guest_*)·재구매 해제 시각·공개 대상은 슈퍼어드민 RPC 몫 — UPDATE 에선 되돌리고 INSERT 에선 기본값으로(있는 칸만 · 5차 리뷰: 업로드로 「게스트석 열림 · ₩1 · 슈퍼어드민이 열었음」을 넣던 길)
    NEW := jsonb_populate_record(NEW, (select coalesce(jsonb_object_agg(x.k, x.d), '{}'::jsonb)
             from (values ('guest_open', 'false'::jsonb), ('guest_open_reason', 'null'::jsonb), ('guest_price', 'null'::jsonb), ('guest_seat_qty', '0'::jsonb),
                          ('guest_opened_at', 'null'::jsonb), ('guest_opened_by', 'null'::jsonb), ('repurchase_open_at', 'null'::jsonb), ('audience', 'null'::jsonb)) x(k, d)
            where to_jsonb(NEW) ? x.k));
    perform public._taam_tp_check_input(to_jsonb(NEW), null);
    NEW.updated_at := now();   -- 파트너 쓰기의 시각은 서버가 적는다(게시 승인 직전 「그 사이 바뀌었나」 대조의 근거 · 4차 리뷰)
    return NEW;
  end if;

  -- UPDATE
  if NEW.rest_id::text is distinct from OLD.rest_id::text then
    raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
  end if;
  if not public.taam_rest_admin_ok(OLD.rest_id::text) then
    raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
  end if;
  if coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') = 'active' then
    raise exception 'ONLY_SUPERADMIN_APPROVES' using errcode = 'P0001';
  end if;
  -- 파트너가 못 만지는 칸(도장 · 검토 메모 · 재구매 해제 · 공개 대상 · 업로더 · 매장 이름 · 판매 오픈) — 예외 없이 OLD 로 되돌린다(있는 칸만)
  v_old := to_jsonb(OLD);
  select jsonb_object_agg(k, v_old -> k) into v_keep from unnest(public._taam_tp_revert_cols()) k where v_old ? k;
  if v_keep is not null then NEW := jsonb_populate_record(NEW, v_keep); end if;
  perform public._taam_tp_check_input(to_jsonb(NEW), v_old);
  NEW.updated_at := now();   -- 파트너가 옛 updated_at 을 보내 「그 사이 바뀌었나」 대조를 비켜 가던 길(4차 리뷰)

  if coalesce(OLD.status, '') = 'pending' then
    -- 승인 전 회차는 내용을 바로 고친다(어차피 승인 대상) · 상태는 못 바꾼다
    if coalesce(NEW.status, '') <> 'pending' then
      raise exception 'BAD_STATUS_CHANGE: 승인 대기 회차의 상태는 슈퍼어드민이 정합니다' using errcode = 'P0001';
    end if;
    return NEW;
  end if;

  -- 승인된(또는 그 밖의 어떤 status 든) 회차 — 옛 앱(2026.10.28-a 이전)은 수정 저장에 'pending' 을 보낸다: 「상태 변경 없음」으로 읽는다
  if coalesce(NEW.status, '') = 'pending' then NEW.status := OLD.status; end if;
  if coalesce(OLD.status, '') in ('active', 'soldout', 'deleteRequest') then
    if coalesce(NEW.status, '') not in ('active', 'soldout', 'deleteRequest') then
      raise exception 'BAD_STATUS_CHANGE: 파트너는 매진/판매중/삭제 신청만 바꿀 수 있습니다' using errcode = 'P0001';
    end if;
  elsif NEW.status is distinct from OLD.status then
    -- 슈퍼어드민이 숨겨 둔(hidden 등) 회차의 상태는 파트너가 못 바꾼다 — 모르는 상태 = 자유가 아니다(2차 리뷰)
    raise exception 'BAD_STATUS_CHANGE: 이 회차의 상태는 슈퍼어드민이 정합니다' using errcode = 'P0001';
  end if;
  -- 내용이 바뀌었으면 **되돌리고 큐에 적는다** — 승인(taam_ticket_edit_review)이 반영한다
  v_diff := public._taam_tp_content_diff(v_old, to_jsonb(NEW));
  if v_diff <> '{}'::jsonb then
    select jsonb_object_agg(k, v_old -> k) into v_keep from jsonb_object_keys(v_diff) k;
    -- 설명이 큐로 가면 그 저장이 같이 찍은 번역 상태(i18n_status_* = 'pending')도 되돌린다 — 옛 설명을 번역하게 두지 않는다 · 승인 때 다시 pending(3차 리뷰)
    if v_diff ? 'ticket_desc' then
      v_keep := v_keep || coalesce((select jsonb_object_agg(k, v_old -> k) from unnest(array['i18n_status_en', 'i18n_status_jp', 'i18n_status_ja']) k where v_old ? k), '{}'::jsonb);
    end if;
    NEW := jsonb_populate_record(NEW, v_keep);
    select coalesce(e.edit, '{}'::jsonb) || v_diff into v_merged from public.ticket_product_edits e where e.ticket_id = NEW.id::text;
    v_merged := coalesce(v_merged, v_diff);
    if not public._taam_tp_edit_ok(v_merged) then
      raise exception 'EDIT_TOO_LONG: 수정 내용이 너무 큽니다(글자 2,000자 · 전체 16KB)' using errcode = 'P0001';
    end if;
    insert into public.ticket_product_edits (ticket_id, rest_id, edit, requested_by, requested_at, updated_at)
    values (NEW.id::text, NEW.rest_id::text, v_merged, auth.uid(), now(), now())
    on conflict (ticket_id) do update set edit = excluded.edit, requested_by = excluded.requested_by, updated_at = now();
    perform public._taam_tp_edit_notify(NEW.id::text, NEW.rest_id::text, NEW.rest_name, coalesce(NEW.date, '') || ' ' || coalesce(NEW.time, ''), auth.uid());
  end if;
  return NEW;
end;
$$;
drop trigger if exists trg_enforce_ticket_approval on public.ticket_products;
create trigger trg_enforce_ticket_approval
  before insert or update on public.ticket_products
  for each row execute function public.enforce_ticket_approval();

-- 큐를 읽는 쪽 — 앱 로더(슈퍼어드민 · 그 매장 승인 어드민)
create or replace function public.taam_ticket_edits()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('ticket_id', e.ticket_id, 'rest_id', e.rest_id, 'edit', e.edit, 'requested_at', e.requested_at, 'requested_by', e.requested_by)), '[]'::jsonb)
    from public.ticket_product_edits e
   where public._taam_uid_is_super() or public.taam_rest_admin_ok(e.rest_id)
$$;
revoke all on function public.taam_ticket_edits() from public, anon;
grant execute on function public.taam_ticket_edits() to authenticated;

-- 파트너가 자기 신청을 거둔다(그 매장 승인 어드민 · 슈퍼어드민)
create or replace function public.taam_ticket_edit_cancel(p_id text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_rest text; v_n int;
begin
  select rest_id into v_rest from public.ticket_product_edits where ticket_id = p_id;
  if v_rest is null then return jsonb_build_object('ok', true, 'removed', 0); end if;
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(v_rest)) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  delete from public.ticket_product_edits where ticket_id = p_id; get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'removed', v_n);
end $$;
revoke all on function public.taam_ticket_edit_cancel(text) from public, anon;
grant execute on function public.taam_ticket_edit_cancel(text) to authenticated;

-- 슈퍼어드민 「수정 승인 / 반려」 — 큐에 적힌 칸을 행에 반영(또는 비움) · 그 매장 승인 어드민에게 알림
drop function if exists public.taam_ticket_edit_review(text, boolean, text);
create or replace function public.taam_ticket_edit_review(p_id text, p_approve boolean, p_note text default null, p_expect jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_row public.ticket_products; v_cols text; v_edit jsonb; v_apply jsonb; v_old jsonb; v_rest text; v_when text;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_row from public.ticket_products where id::text = p_id for update;
  if v_row.id is null then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select edit into v_edit from public.ticket_product_edits where ticket_id = p_id for update;
  if v_edit is null or v_edit = '{}'::jsonb then return jsonb_build_object('ok', true, 'applied', false, 'reason', 'nothing_pending'); end if;
  -- 화면이 본 큐와 지금 큐가 다르면 멈춘다 — 파트너가 그 사이 칸을 더하면 슈퍼어드민이 못 본 값이 승인 도장과 함께 나갔다(3차 리뷰 재현) · SQL Editor 는 p_expect 없이
  if p_expect is not null and p_expect is distinct from v_edit then
    raise exception 'STALE_EDIT: 수정 신청이 바뀌었습니다 — 다시 확인해 주세요' using errcode = 'P0001';
  end if;
  if p_approve then
    -- 큐의 칸만 바꾼다 — 모르는 칸(표에 없는 키)·되돌림 칸·id 는 버리고, 지금 값과 같은 칸은 건너뛴다(그 사이 슈퍼어드민이 같은 값으로 고친 것)
    v_old := to_jsonb(v_row);
    select coalesce(jsonb_object_agg(k, v_edit -> k), '{}'::jsonb) into v_apply
      from jsonb_object_keys(v_edit) k where public._taam_tp_normk(k, v_old -> k) is distinct from public._taam_tp_normk(k, v_edit -> k);
    -- 설명이 바뀌면 번역 상태를 pending 으로 — 옛 번역이 새 설명 옆에 남지 않게(3차 리뷰)
    if v_apply ? 'ticket_desc' then
      v_apply := v_apply || coalesce((select jsonb_object_agg(k, to_jsonb('pending'::text)) from unnest(array['i18n_status_en', 'i18n_status_jp', 'i18n_status_ja']) k where v_old ? k), '{}'::jsonb);
    end if;
    select string_agg(format('%I', c.column_name), ', ') into v_cols
      from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = 'ticket_products' and c.column_name <> 'id'
       and not (c.column_name = any (public._taam_tp_revert_cols())) and c.column_name <> 'status' and v_apply ? c.column_name;
    if v_cols is not null then
      execute format('update public.ticket_products set (%s) = (select %s from jsonb_populate_record(null::public.ticket_products, $1)) where id::text = $2', v_cols, v_cols)
        using (v_old || v_apply), p_id;
    end if;
    update public.ticket_products
       set review_note = nullif(btrim(coalesce(p_note, '')), ''), approved_by = coalesce(auth.uid(), approved_by), approved_at = now(), updated_at = now()
     where id::text = p_id;
  else
    update public.ticket_products set review_note = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now() where id::text = p_id;
  end if;
  delete from public.ticket_product_edits where ticket_id = p_id;
  begin
    select name into v_rest from public.restaurants where id::text = v_row.rest_id::text;
    v_rest := coalesce(v_rest, v_row.rest_name, '매장'); v_when := coalesce(v_row.date, '') || ' ' || coalesce(v_row.time, '');
    insert into public.notifications (user_id, type, title, body, url, payload)
    select g.user_id, case when p_approve then 'ticket_edit_approved' else 'ticket_edit_rejected' end,
           case when p_approve then '티켓 수정이 승인되었습니다' else '티켓 수정이 반려되었습니다' end,
           v_rest || ' · ' || v_when || coalesce(' — ' || nullif(btrim(coalesce(p_note, '')), ''), ''), '/',
           jsonb_build_object('ticket_id', p_id, 'rest_id', v_row.rest_id::text, 'approved', p_approve, 'fields', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(v_edit) k))
      from public.admin_grants g where g.status = 'approved' and (g.rest_id = v_row.rest_id::text or g.venue_id = v_row.rest_id::text);
  exception when others then null; end;
  return jsonb_build_object('ok', true, 'applied', p_approve, 'fields', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(v_edit) k),
                            'applied_fields', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(coalesce(v_apply, '{}'::jsonb)) k));
end $$;
revoke all on function public.taam_ticket_edit_review(text, boolean, text, jsonb) from public, anon;
grant execute on function public.taam_ticket_edit_review(text, boolean, text, jsonb) to authenticated;

-- 파트너의 「수정 신청」 저장 — 폼의 값 전체(p_row · 앱 저장 payload 와 같은 칸 이름)를 지금 승인된 값과 견주어 **큐를 그 차이로 바꾼다**(합치지 않는다).
--   종전 길(행 upsert → 트리거가 큐에 합침)은 칸을 더하기만 해서, 파트너가 값을 원래대로 되돌려도 큐에 옛 신청이 남아 그대로 승인됐다(3차 리뷰 재현).
--   차이가 없으면 큐를 지운다(= 신청 거두기) · 행은 건드리지 않는다(승인 전까지 회원에게는 종전 내용) · 앱은 폼을 큐 값으로 채워 연다.
drop function if exists public.taam_ticket_edit_submit(text, jsonb);
create or replace function public.taam_ticket_edit_submit(p_id text, p_row jsonb, p_expect jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_cur public.ticket_products; v_old jsonb; v_in jsonb; v_new jsonb; v_diff jsonb; v_n int; v_q jsonb;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_row is null or jsonb_typeof(p_row) <> 'object' then raise exception 'BAD_ARGS' using errcode = '22023'; end if;
  select * into v_cur from public.ticket_products where id::text = p_id for update;
  if v_cur.id is null then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(v_cur.rest_id::text)) then raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001'; end if;
  if p_row ? 'rest_id' and nullif(p_row->>'rest_id', '') is distinct from v_cur.rest_id::text then raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001'; end if;
  if coalesce(v_cur.status, '') = 'pending' then raise exception 'ROUND_PENDING: 승인 전 회차는 바로 고칩니다' using errcode = 'P0001'; end if;
  -- 폼이 열린 때 본 큐(없었으면 {})와 지금 큐가 다르면 멈춘다 — 신청 값을 못 읽고 열린 폼(IDB 폴백 · 큐 조회 실패)이 앞 신청을 지우던 길
  select e.edit into v_q from public.ticket_product_edits e where e.ticket_id = p_id for update;
  if p_expect is not null and coalesce(v_q, '{}'::jsonb) is distinct from p_expect then
    raise exception 'STALE_EDIT: 수정 신청이 그 사이 바뀌었습니다 — 다시 열어 주세요' using errcode = 'P0001';
  end if;
  v_old := to_jsonb(v_cur);
  -- 표에 있는 내용 칸만(도장·상태·매장·되돌림 칸·서버 칸은 버린다) · 값은 칸 타입으로 바꿔서 견준다(트리거와 같은 비교)
  select coalesce(jsonb_object_agg(k, p_row -> k), '{}'::jsonb) into v_in
    from jsonb_object_keys(p_row) k
   where v_old ? k and k not in ('id', 'status', 'rest_id') and not (k = any (public._taam_tp_free_cols()));
  v_new := to_jsonb(jsonb_populate_record(v_cur, v_in));
  perform public._taam_tp_check_input(v_new, v_old);
  v_diff := public._taam_tp_content_diff(v_old, v_new);
  if v_diff = '{}'::jsonb then
    delete from public.ticket_product_edits where ticket_id = p_id;
    get diagnostics v_n = row_count;
    return jsonb_build_object('ok', true, 'queued', false, 'cleared', v_n > 0);
  end if;
  if not public._taam_tp_edit_ok(v_diff) then
    raise exception 'EDIT_TOO_LONG: 수정 내용이 너무 큽니다(글자 2,000자 · 전체 16KB)' using errcode = 'P0001';
  end if;
  insert into public.ticket_product_edits (ticket_id, rest_id, edit, requested_by, requested_at, updated_at)
  values (p_id, v_cur.rest_id::text, v_diff, auth.uid(), now(), now())
  on conflict (ticket_id) do update set edit = excluded.edit, requested_by = excluded.requested_by, updated_at = now();
  perform public._taam_tp_edit_notify(p_id, v_cur.rest_id::text, v_cur.rest_name, coalesce(v_cur.date, '') || ' ' || coalesce(v_cur.time, ''), auth.uid());
  return jsonb_build_object('ok', true, 'queued', true, 'fields', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(v_diff) k));
end $$;
revoke all on function public.taam_ticket_edit_submit(text, jsonb, jsonb) from public, anon;
grant execute on function public.taam_ticket_edit_submit(text, jsonb, jsonb) to authenticated;

-- 업로드 신청 → 슈퍼어드민 알림(파트너마다 시간당 30건 · 푸시) · 승인 → 그 매장 승인 어드민 알림 (서버가 적는다 · 실패는 삼킨다)
--   ⚠ 앱의 taamNotifyAdmins 는 파트너 업로드 경로에서 빠졌다(2차 리뷰 — 두 번 가던 것) — 알림은 여기서만.
create or replace function public.taam_ticket_approval_notify()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_rest text; v_when text; v_partner boolean; v_n int;
begin
  begin
    v_partner := auth.uid() is not null and not public.is_super_admin(auth.uid()) and pg_trigger_depth() <= 1;
    select name into v_rest from public.restaurants where id::text = NEW.rest_id::text;
    v_rest := coalesce(v_rest, NEW.rest_name, '매장');
    v_when := coalesce(NEW.date, '') || ' ' || coalesce(NEW.time, '');
    if v_partner and TG_OP = 'INSERT' and coalesce(NEW.status, '') = 'pending' then
      if to_regprocedure('public.taam_rate_hit(text, integer, interval)') is not null
         and not public.taam_rate_hit('tp_approval_notify:' || auth.uid()::text, 30, interval '1 hour') then
        return NEW;   -- 알림만 건너뛴다 · 업로드 자체는 그대로
      end if;
      insert into public.notifications (user_id, type, title, body, url, payload)
      select p.id, 'ticket_upload_request', '티켓 업로드 신청', v_rest || ' · ' || v_when, '/',
             jsonb_build_object('ticket_id', NEW.id::text, 'rest_id', NEW.rest_id::text, 'edit', false, 'via', 'trg_taam_ticket_approval_notify')
        from public.profiles p where p.role in ('superadmin', 'super_admin');
      get diagnostics v_n = row_count;
      if v_n > 0 and to_regprocedure('public.taam_admin_push(text, text, text, text, text)') is not null then
        begin perform public.taam_admin_push('티켓 업로드 신청', v_rest || ' · ' || v_when, '/', 'tpup-' || NEW.id::text, 'admin'); exception when others then null; end;
      end if;
    elsif TG_OP = 'UPDATE' and coalesce(OLD.status, '') = 'pending' and coalesce(NEW.status, '') in ('active', 'soldout') then
      -- 정원이 이미 찬 회차는 BEFORE 재계산이 soldout 으로 바꾼다 — 그래도 승인이다(2차 리뷰)
      insert into public.notifications (user_id, type, title, body, url, payload)
      select g.user_id, 'ticket_approved', '티켓이 승인되었습니다', v_rest || ' · ' || v_when || ' — 회원에게 공개됐습니다', '/', jsonb_build_object('ticket_id', NEW.id::text, 'rest_id', NEW.rest_id::text)
        from public.admin_grants g where g.status = 'approved' and (g.rest_id = NEW.rest_id::text or g.venue_id = NEW.rest_id::text);
    end if;
  exception when others then null;
  end;
  return NEW;
end $$;
drop trigger if exists trg_taam_ticket_approval_notify on public.ticket_products;
create trigger trg_taam_ticket_approval_notify after insert or update on public.ticket_products   -- ⚠ UPDATE OF 로 걸면 BEFORE 가 바꾼 칸(SET 에 없는 것)을 못 본다
  for each row execute function public.taam_ticket_approval_notify();

-- 거절(pending 회차 삭제)은 슈퍼어드민의 DELETE 다 — 그 매장 어드민에게 알린다 · 큐도 같이 지운다
create or replace function public.taam_ticket_reject_notify()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_rest text;
begin
  begin
    delete from public.ticket_product_edits where ticket_id = OLD.id::text;
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
end $$;
drop trigger if exists trg_taam_guard_invite_rest on public.reservation_invites;
create trigger trg_taam_guard_invite_rest before insert or update on public.reservation_invites
  for each row execute function public.taam_guard_invite_rest();

-- 보낸 사람(host) 세션: INSERT 는 언제나 'sent'(paid_at 없음) · UPDATE 로 paid 를 만들 수 없다 · paid 줄의 받는 회원·금액·회차·매장은 못 바꾼다(취소·시각 변경은 그대로)
--   받는 회원 쪽 가드(trg_taam_guard_invite_row · 20261022)와 대칭 — 그 가드는 host 를 면제해 둬, 승인된 파트너가 초대 한 줄을 paid 로 넣어 아무 회원이든 「관계」로 만들 수 있었다.
create or replace function public.taam_guard_invite_host()
returns trigger
language plpgsql security definer set search_path = public
as $$
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
end $$;
drop trigger if exists trg_taam_guard_invite_host on public.reservation_invites;
create trigger trg_taam_guard_invite_host before insert or update on public.reservation_invites
  for each row execute function public.taam_guard_invite_host();

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
-- 초대가 실제로 결제됐나 — 서버만 쓰는 증거로: 그 초대의 INV- 좌석 행(확정 RPC 가 만든다) 또는 받는 회원의 원장 결제 줄(invite_id · INV-앞8 구매 id). status 'paid' 는 믿지 않는다.
create or replace function public._taam_invite_paid_evidence(p_inv uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tickets t where t.user_id = p_uid and t.extra_data->>'inviteId' = p_inv::text and lower(coalesce(t.status, '')) not in ('hold', 'expired'))
      or exists (select 1 from public.deposit_transactions d where d.user_id = p_uid and d.amount < 0 and d.change_type = 'ticket_purchase'
                   and (d.metadata->>'invite_id' = p_inv::text or coalesce(d.metadata->>'purchase_id', '') like 'INV-' || left(p_inv::text, 8) || '%'))
$$;
revoke all on function public._taam_invite_paid_evidence(uuid, uuid) from public, anon, authenticated;
-- 회원 행인가 — 운영 행(MAN-·KSK-·INVH- · memberUid 없는 LINK-)의 user_id 는 그 행을 넣은 어드민이다(3차 리뷰: 슈퍼어드민이 그 매장에 수동 좌석을 넣으면 파트너가 슈퍼어드민의 연락처를 받았다)
create or replace function public._taam_pt_member_row(p_pid text, p_ed jsonb)
returns boolean language sql immutable as $$
  select coalesce(p_pid, '') !~ '^(MAN|KSK|INVH)-' and not (coalesce(p_pid, '') like 'LINK-%' and coalesce(p_ed->>'memberUid', '') = '')
$$;
revoke all on function public._taam_pt_member_row(text, jsonb) from public, anon, authenticated;
-- 이 매장의 회원인가 — 회원 행(홀드·만료 제외) 또는 결제 증거가 있는 초대 · 어드민 계정(role admin/superadmin)은 아니다
create or replace function public._taam_pt_related(p_rest text, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = p_uid and coalesce(p.role, 'user') not in ('admin', 'superadmin', 'super_admin'))
     and (exists (select 1 from public.tickets t where t.user_id = p_uid and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold', 'expired')
                    and public._taam_pt_member_row(t.purchase_id, t.extra_data))
          or exists (select 1 from public.reservation_invites i where i.invitee_user_id = p_uid and i.restaurant_id::text = p_rest and public._taam_invite_paid_evidence(i.id, p_uid)))
$$;
revoke all on function public._taam_pt_related(text, uuid) from public, anon, authenticated;
-- 회원이 쓸 수 있는 칸의 숫자를 안전하게 읽는다(결제 내역 보고와 같은 도우미가 있으면 그것)
create or replace function public._taam_pt_num(p text)
returns numeric language sql immutable as $$ select case when p ~ '^\s*-?\d{1,13}(\.\d+)?\s*$' then round(p::numeric, 2) end $$;
revoke all on function public._taam_pt_num(text) from public, anon, authenticated;

-- 회원 모양(PAYH- 등) 행인데 주인이 어드민 계정(슈퍼어드민 시험 구매 등)인가 — 그 줄의 손님 칸은 그 어드민이 적은 자기 연락처다
create or replace function public._taam_pt_admin_owned(p_uid uuid, p_pid text, p_ed jsonb)
returns boolean language sql stable security definer set search_path = public as $$
  select public._taam_pt_member_row(p_pid, p_ed)
     and exists (select 1 from public.profiles a where a.id = p_uid and coalesce(a.role, 'user') in ('admin', 'superadmin', 'super_admin'))
$$;
revoke all on function public._taam_pt_admin_owned(uuid, text, jsonb) from public, anon, authenticated;

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
                when public._taam_pt_admin_owned(t.user_id, t.purchase_id, t.extra_data) then null
                when coalesce(t.purchase_id, '') like 'LINK-%' and coalesce(t.extra_data->>'memberUid', '') = '' then null else t.user_id end,
    'buyer', case when public._taam_pt_admin_owned(t.user_id, t.purchase_id, t.extra_data) then '(운영 계정)' else coalesce(nullif(btrim(p.display_name), ''), nullif(btrim(t.buyer_name), '')) end,
    'phone', case when public._taam_pt_admin_owned(t.user_id, t.purchase_id, t.extra_data) then null else coalesce(nullif(btrim(to_jsonb(p)->>'phone'), ''), nullif(btrim(t.buyer_phone), '')) end,
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
                               and coalesce(p.role, 'user') not in ('admin', 'superadmin', 'super_admin')   -- 어드민 계정의 시험 구매에 그 사람 연락처를 붙이지 않는다(4차 리뷰)
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
        left join public.profiles p on p.id = t.user_id and public._taam_pt_member_row(t.purchase_id, t.extra_data)   -- 운영 행은 어드민 프로필로 찾지 않는다
                                   and coalesce(p.role, 'user') not in ('admin', 'superadmin', 'super_admin')
       where t.restaurant_id::text = p_rest
         and lower(coalesce(t.status, '')) not in ('hold', 'expired')
         and (p_from is null or coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(tp.date)) >= p_from)
         and (p_to   is null or coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(tp.date)) <  p_to)
         and (coalesce(p_status, '') = '' or
              (p_status = 'cancelled' and lower(coalesce(t.status, '')) in ('cancelled', 'canceled')) or
              (p_status = 'active' and lower(coalesce(t.status, '')) in ('active', 'manual', 'used', 'pending_confirm')) or
              (p_status = 'noshow' and t.visit_status = 'no_show') or
              (p_status = 'visited' and (t.visit_status = 'attended' or lower(coalesce(t.status, '')) = 'used')))
         and (v_q = '' or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
              or (not public._taam_pt_admin_owned(t.user_id, t.purchase_id, t.extra_data) and lower(coalesce(t.buyer_name, '')) like '%' || v_q || '%')
              or lower(coalesce(t.purchase_id, '')) like '%' || v_q || '%' or lower(coalesce(to_jsonb(p)->>'email', '')) like '%' || v_q || '%'
              or (length(v_qd) >= 4 and (regexp_replace(coalesce(to_jsonb(p)->>'phone', ''), '\D', '', 'g') like '%' || v_qd || '%'
                                         or (not public._taam_pt_admin_owned(t.user_id, t.purchase_id, t.extra_data) and regexp_replace(coalesce(t.buyer_phone, ''), '\D', '', 'g') like '%' || v_qd || '%'))))
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
  -- 초대는 **결제된 것만** 관계로 친다 — 초대 줄은 바로 그 파트너가 어느 회원에게나 넣을 수 있는 줄이라, 보낸 것만으로 관계가 되면 명부 훑기가 된다(적대 리뷰 재현)
  v_related := public._taam_pt_related(p_rest, p_uid);
  if not v_related then raise exception 'NOT_RELATED: 이 매장에 예약한 회원이 아닙니다' using errcode = '42501'; end if;
  select p.id, nullif(btrim(p.display_name), '') as display_name, to_jsonb(p)->>'phone' as phone, to_jsonb(p)->>'email' as email,
         to_jsonb(p)->>'membership_tier' as tier, to_jsonb(p)->>'nationality' as nationality, to_jsonb(p)->>'country' as country,
         to_jsonb(p)->>'display_name_en' as display_name_en, to_jsonb(p)->>'currency' as currency, p.created_at
    into v_p from public.profiles p where p.id = p_uid;
  if v_p.id is null then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select coalesce(jsonb_agg(r order by (r->>'date') desc nulls last, (r->>'created_at') desc), '[]'::jsonb) into v_rows
    from (select public._taam_pt_row(t, p_rest) as r from public.tickets t
           where t.user_id = p_uid and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold', 'expired')
             and public._taam_pt_member_row(t.purchase_id, t.extra_data) order by t.created_at desc limit 300) z;
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
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb; v_q text := lower(btrim(coalesce(p_q, ''))); v_qd text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g'); v_lim boolean := false;
begin
  -- ⚠ volatile — 번호 조회 상한(taam_rate_hit)이 표에 적는다. stable 이면 PostgREST 가 READ ONLY 트랜잭션으로 돌려 10자리 조회가 전부 25006 으로 실패했다(3차 리뷰 재현)
  if not (public._taam_uid_is_super() or public.taam_rest_admin_ok(p_rest)) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(v_q) < 2 then return '[]'::jsonb; end if;
  -- ② 번호 정확 일치(관계 없는 회원)는 파트너마다 시간당 30번 — **조회마다 먼저 센다**(맞는 번호일 때만 세면 틀린 번호 훑기가 공짜였다 · 3차 리뷰)
  if length(v_qd) >= 10 then
    v_lim := to_regprocedure('public.taam_rate_hit(text, integer, interval)') is null
          or public.taam_rate_hit('partner_phone_lookup:' || coalesce(auth.uid()::text, 'x'), 30, interval '1 hour');
  end if;
  with rel as (
    -- ① 이 매장의 회원(회원 행 · 결제 증거가 있는 초대) — 부분 일치 · 전 칸
    select distinct t.user_id as id from public.tickets t
     where t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold', 'expired') and public._taam_pt_member_row(t.purchase_id, t.extra_data)
    union
    select i.invitee_user_id from public.reservation_invites i
     where i.restaurant_id::text = p_rest and i.invitee_user_id is not null and public._taam_invite_paid_evidence(i.id, i.invitee_user_id)
  )
  select coalesce(jsonb_agg(row_obj order by nm), '[]'::jsonb) into v
    from (
      select nullif(btrim(p.display_name), '') nm,
             case when rel.id is not null then
               jsonb_strip_nulls(jsonb_build_object('id', p.id, 'display_name', nullif(btrim(p.display_name), ''), 'phone', to_jsonb(p)->>'phone', 'email', to_jsonb(p)->>'email',
                 'membership_tier', to_jsonb(p)->>'membership_tier', 'nationality', to_jsonb(p)->>'nationality', 'currency', to_jsonb(p)->>'currency', 'related', true,
                 'last_visit', (select max(coalesce(public._taam_pu_visit_date(t.reservation_date), t.created_at::date)) from public.tickets t
                                 where t.user_id = p.id and t.restaurant_id::text = p_rest and lower(coalesce(t.status, '')) not in ('hold','expired','cancelled','canceled')
                                   and public._taam_pt_member_row(t.purchase_id, t.extra_data))))
             else
               -- ② 그 밖의 회원은 **전화번호를 끝까지 정확히** 쳤을 때만(10자리 이상 · 010 ↔ +8210 같은 끝 10자리) · 초대에 필요한 이름·번호·등급·통화만
               jsonb_strip_nulls(jsonb_build_object('id', p.id, 'display_name', nullif(btrim(p.display_name), ''), 'phone', to_jsonb(p)->>'phone',
                 'membership_tier', to_jsonb(p)->>'membership_tier', 'currency', to_jsonb(p)->>'currency', 'related', false))
             end as row_obj
        from public.profiles p left join rel on rel.id = p.id
       where coalesce(to_jsonb(p)->>'deleted_at', '') = ''
         and coalesce(p.role, 'user') not in ('admin', 'superadmin', 'super_admin')   -- 어드민 계정은 회원 검색에 안 나온다
         and (
              (rel.id is not null
               and (lower(coalesce(p.display_name, '')) like '%' || v_q || '%' or lower(coalesce(to_jsonb(p)->>'email', '')) like '%' || v_q || '%'
                    or (length(v_qd) >= 4 and regexp_replace(coalesce(to_jsonb(p)->>'phone', ''), '\D', '', 'g') like '%' || v_qd || '%')))
              or (length(v_qd) >= 10 and v_lim and right(regexp_replace(coalesce(to_jsonb(p)->>'phone', ''), '\D', '', 'g'), 10) = right(v_qd, 10))
             )
       limit 20) z;
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
     and public._taam_pt_related(p_rest, p.id);
  return v;
end $$;
revoke all on function public.taam_partner_names(text, uuid[]) from public, anon;
grant execute on function public.taam_partner_names(text, uuid[]) to authenticated;

-- ── J. admin_grants 를 status 없이 직접 읽는 라이브 본문 — 결제 링크 만들기(taam_link_invite_create) · 정산 좌석 셋(taam_kashikiri_link_ticket · taam_ksk_seat_set_pax · taam_ksk_seat_rows) · storage 정책 ──
--   옛 이름 함수 7개를 바꿔도 이들은 `exists (select 1 from public.admin_grants g where g.user_id = v_uid and (g.rest_id … or g.venue_id …))` 를 안에 품고 있어
--   승인 대기·정지 권한도 어드민으로 쳤다(적대 리뷰 재현). 본문에서 그 모양만 `select 1 where public.taam_rest_admin_ok_for(v_uid, …)` 로 바꿔 다시 만든다 —
--   모양을 못 찾으면(다른 판) ⚠ 로 적고 건드리지 않는다(배포는 멈추지 않는다 · 다음 묶음에서 손으로).
do $do$
declare r record; v_def text; v_new text; v_cnt int; v_log text := '';
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('taam_link_invite_create', 'taam_kashikiri_link_ticket', 'taam_ksk_seat_set_pax', 'taam_ksk_seat_rows') loop
    v_def := pg_get_functiondef(r.oid);
    if position('from public.admin_grants' in v_def) = 0 then v_log := v_log || r.proname || ' ✅(이미) · '; continue; end if;
    v_new := regexp_replace(v_def,
      'select\s+1\s+from\s+public\.admin_grants\s+g\s+where\s+g\.user_id\s*=\s*v_uid\s+and\s*\(\s*g\.rest_id::text\s*=\s*(v_tp\.rest_id::text|v_ev\.venue_id)\s+or\s+g\.venue_id::text\s*=\s*\1\s*\)',
      'select 1 where public.taam_rest_admin_ok_for(v_uid, \1)', 'g');
    if position('from public.admin_grants' in v_new) > 0 then v_log := v_log || r.proname || ' ⚠ 모르는 모양(그대로) · '; continue; end if;
    execute v_new;
    v_log := v_log || r.proname || ' ✅ 교체 · ';
  end loop;
  insert into _pg(항목, 결과) values ('J 라이브 함수의 직접 조회 → 승인 판정', coalesce(nullif(v_log, ''), '(대상 없음)'));
exception when others then insert into _pg(항목, 결과) values ('J 라이브 함수의 직접 조회 → 승인 판정', '⚠ ' || left(sqlerrm, 160) || ' · ' || v_log);
end $do$;
do $do$
begin
  if to_regclass('storage.objects') is not null and exists (select 1 from pg_policies where schemaname = 'storage' and policyname = 'restaurant_videos_partner_insert') then
    drop policy if exists restaurant_videos_partner_insert on storage.objects;
    execute 'create policy restaurant_videos_partner_insert on storage.objects for insert to authenticated with check ('
         || 'bucket_id = ''restaurant-videos'' and (public._taam_uid_is_super()'
         || ' or exists (select 1 from public.admin_grants g where g.user_id = auth.uid() and g.status = ''approved'')))';
    insert into _pg(항목, 결과) values ('J storage restaurant-videos 정책', '✅ 승인 권한만');
  else
    insert into _pg(항목, 결과) values ('J storage restaurant-videos 정책', '⚠ 정책 없음(건너뜀)');
  end if;
exception when others then insert into _pg(항목, 결과) values ('J storage restaurant-videos 정책', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── K. 파트너·회원이 쓰는 그 밖의 표 — 글자 검사 ──
--   5차 리뷰(재현): 승인된 파트너가 REST 로 수동 좌석(tickets MAN-)의 시각·구매 id·손님 이름, 초대(reservation_invites)의 매장 이름·시각에
--   HTML 을 넣으면 슈퍼어드민의 티켓 캘린더와 회원의 초대 결제 팝업에서 돌았다(회원 세션에서 예치금 결제까지 몰 수 있다).
--   로그인 호출(슈퍼어드민 제외)의 **새로 생긴 글자**만 본다 — 옛 내용 때문에 취소·출석 같은 갱신이 막히지 않게. 구매 id 는 영문·숫자·_.:- 만(onclick 탈출).
--   서버 함수(definer) 안의 쓰기도 auth.uid() 가 있으면 본다(매장 어드민이 부르는 수동 좌석 수정 RPC · 링크 만들기 등) · 서버(auth.uid() null)는 그대로.
create or replace function public.taam_guard_text_input()
returns trigger language plpgsql set search_path = public as $$
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
end $$;
do $do$
declare t text; n int := 0;
begin
  foreach t in array array['tickets', 'reservation_invites', 'daegwan_manual', 'restaurant_visit_notes', 'restaurants'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_taam_guard_text_input on public.%I', t);
      execute format('create trigger trg_taam_guard_text_input before insert or update on public.%I for each row execute function public.taam_guard_text_input()', t);
      n := n + 1;
    end if;
  end loop;
  insert into _pg(항목, 결과) values ('K 글자 검사 트리거', '✅ ' || n || '개 표');
exception when others then insert into _pg(항목, 결과) values ('K 글자 검사 트리거', '❌ ' || left(sqlerrm, 160));
end $do$;

-- ── I. 덤 — 조회 함수 권한 ──
-- uuid → 이메일 조회가 누구에게나 열려 있었다(기본 PUBLIC EXECUTE). 본인·슈퍼어드민·서버만. (profiles 역할 가드 트리거가 본인 id 로 부른다 — 그대로 된다)
create or replace function public._taam_auth_email(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null or auth.uid() = p_id or public._taam_uid_is_super()
              then (select lower(u.email::text) from auth.users u where u.id = p_id) end
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
 ('B 옛 이름 7개가 새 판정으로(옛 본문 잔존 0)', case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('is_ticket_admin_of','is_restaurant_admin_of','is_venue_admin_of','taam_is_rest_admin','taam_can_mark_visit','taam_can_manage_ticket_as','_taam_rest_note_ok')
       and p.prosrc like '%taam_rest_admin_ok%') = 7
     and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('is_ticket_admin_of','is_restaurant_admin_of','is_venue_admin_of','taam_is_rest_admin','taam_can_mark_visit','taam_can_manage_ticket_as','_taam_rest_note_ok')
       and p.prosrc not like '%taam_rest_admin_ok%') then '✅' else '❌' end),
 ('B taam_rest_admin_ok_for 는 회원이 못 부른다', case when has_function_privilege('authenticated', 'public.taam_rest_admin_ok_for(uuid, text)', 'execute') then '❌' else '✅' end),
 ('A prev_status 칸', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'admin_grants' and column_name = 'prev_status') then '✅' else '❌' end),
 ('D 수정 큐 표 · RPC 셋(review · cancel · edits)', case when to_regclass('public.ticket_product_edits') is not null and to_regproc('public.taam_ticket_edit_review') is not null
     and to_regproc('public.taam_ticket_edit_cancel') is not null and to_regproc('public.taam_ticket_edits') is not null then '✅' else '❌' end),
 ('D 수정 큐 표 — 회원·anon 권한 없음', case when has_table_privilege('anon', 'public.ticket_product_edits', 'select') then '❌' else '✅' end),
 ('D enforce_ticket_approval 중첩 통과(pg_trigger_depth)', case when exists (select 1 from pg_proc where proname = 'enforce_ticket_approval' and prosrc like '%pg_trigger_depth() > 1%') then '✅' else '❌' end),
 ('C 회차 검사 도우미 · 승인 대기 회차 좌석 가드 · E host 가드', case when to_regproc('public._taam_tp_seat_check') is not null and to_regproc('public._taam_tp_rest_status') is null
     and exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ticket_round_open') and exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_invite_host') then '✅' else '❌' end),
 ('D 수정 신청 저장 RPC(p_expect) · 승인 STALE 검사(4인자)', case when to_regprocedure('public.taam_ticket_edit_submit(text, jsonb, jsonb)') is not null and to_regprocedure('public.taam_ticket_edit_submit(text, jsonb)') is null
     and to_regprocedure('public.taam_ticket_edit_review(text, boolean, text, jsonb)') is not null and to_regprocedure('public.taam_ticket_edit_review(text, boolean, text)') is null then '✅' else '❌' end),
 ('K tickets·초대 글자 검사', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_text_input' and tgrelid = 'public.tickets'::regclass)
     and exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_text_input' and tgrelid = 'public.reservation_invites'::regclass) then '✅' else '❌' end),
 ('D 파트너 입력 검사(_taam_tp_check_input)', case when to_regproc('public._taam_tp_check_input') is not null and exists (select 1 from pg_proc where proname = 'enforce_ticket_approval' and prosrc like '%_taam_tp_check_input%') then '✅' else '❌' end),
 ('G 회원 검색은 volatile(상한을 적는다)', case when (select provolatile from pg_proc where oid = to_regprocedure('public.taam_partner_member_search(text, text)')) = 'v' then '✅' else '❌' end),
 ('A 파트너는 admin_grants.note 를 못 읽는다', case when has_column_privilege('authenticated', 'public.admin_grants', 'note', 'select') then '❌' else '✅' end),
 ('A suspended_via 칸', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'admin_grants' and column_name = 'suspended_via') then '✅' else '❌' end),
 ('J admin_grants 직접 조회가 남은 함수(정보)', coalesce((select string_agg(p.proname, ' · ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosrc like '%from public.admin_grants%' and p.proname not in ('taam_rest_admin_ok_for', 'taam_partner_grants_list', 'taam_partner_grant_set', 'taam_partner_my_grants',
       'taam_ticket_approval_notify', 'taam_ticket_reject_notify', 'taam_ticket_edit_review', 'taam_guard_admin_grant')), '없음')),
 ('C tickets INSERT 가드 새 판', case when exists (select 1 from pg_proc where proname = 'taam_guard_ticket_insert' and prosrc like '%TAAM_GUARD_TICKET_INSERT_V2%') then '✅' else '❌' end),
 ('D ticket_products 정책(읽기 · 파트너 3)', case when (select count(*) from pg_policies where tablename = 'ticket_products' and policyname in ('ticket_products_read','ticket_products_partner_insert','ticket_products_partner_update','ticket_products_partner_delete')) = 4 then '✅' else '❌' end),
 ('D 승인 트리거 둘', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_ticket_approval_notify') and exists (select 1 from pg_trigger where tgname = 'trg_enforce_ticket_approval') then '✅' else '❌' end),
 ('E 초대 매장 일치 트리거', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_invite_rest') then '✅' else '❌' end),
 ('F profiles 전 칸 읽기 정책 없음', case when not exists (select 1 from pg_policies where tablename = 'profiles' and policyname = 'profiles read by venue admin for requesters') then '✅' else '❌' end),
 ('G 파트너 RPC 다섯', case when to_regproc('public.taam_partner_reservations') is not null and to_regproc('public.taam_partner_member') is not null
     and to_regproc('public.taam_partner_member_search') is not null and to_regproc('public.taam_partner_my_grants') is not null
    and to_regproc('public.taam_partner_names') is not null then '✅' else '❌' end),
 ('H 슈퍼어드민 RPC 둘', case when to_regproc('public.taam_partner_grants_list') is not null and to_regproc('public.taam_partner_grant_set') is not null then '✅' else '❌' end),
 ('I _taam_auth_email 본인·슈퍼어드민만 · 소문자', case when exists (select 1 from pg_proc where proname = '_taam_auth_email' and prosrc like '%auth.uid() = p_id%' and prosrc like '%lower(u.email%') then '✅' else '❌' end),
 ('A 권한 상태 분포(정보)', (select coalesce(string_agg(status || ' ' || n, ' · '), '없음') from (select status, count(*) n from public.admin_grants group by status) z));
select 항목, 결과 from _pg order by seq;
