-- ═══════════════════════════════════════════════════════════════
-- TAAM — 2차 검증에서 남은 low 묶음 · SQL 로 닫히는 것 (2026-09-14 저녁)
-- ═══════════════════════════════════════════════════════════════
-- 근거: docs/AUDIT_2026-09-14_unaudited5.md 6절 (#14 · #32 · #53 · #55)
-- 앱·Edge 를 안 바꿔도 안전하다. 각 절은 독립 DO/CREATE 라 하나가 실패해도 나머지는 적용된다.
--
--   ① 게스트 만료 알림(슈퍼어드민) 중복 열쇠에 기간 — 같은 게스트의 두 번째 만료 주기에 알림이 영영 안 가던 것
--   ② 대관 링크 결제 시작(order_start) — 이름 60자 제한 · 토큰당 10분 30회
--   ③ 오류 신고(taam_report_error) — extra 4KB 상한 · 익명은 세션(sid)별 20건/시간, 전체 300건/시간
--      (종전엔 익명 전체가 60건 한 묶음이라 한 사람이 채우면 진짜 부팅 오류 신고가 전부 버려졌다)
--   ④ 파트너 QR 조회 — 전체 600/시간 · 코드당 120/시간을 넘으면 **열람 기록만 건너뛰고** 데이터는 준다
--      (거부하면 플러딩 뒤에 진짜 셰프가 「무효 코드」를 본다)
--
-- taam_rate_hit 는 audit_hardening_2026-09-13.sql 이 만든다. 없으면 제한 없이 통과한다.
-- 실행: Supabase SQL Editor 에 통째로. 여러 번 돌려도 안전. 마지막 표에 ❌ 가 없어야 정상.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 게스트 만료 알림 — 슈퍼어드민 열쇠에 기간
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guest_expiry_notify()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_admin int := 0; v_self int := 0; v_ids jsonb;
        v_rows_a jsonb := '[]'::jsonb; v_rows_s jsonb := '[]'::jsonb;
        v_days int := 90; v_win interval;
begin
  -- 중복 판정 창: 게스트 기간(guest_days)보다 짧게 — 기본 90일이면 30일. 35일 미만이면 그 절반.
  begin
    select coalesce((v#>>'{}')::int, 90) into v_days from public.membership_settings where k = 'guest_days';
  exception when others then v_days := 90; end;
  v_win := (greatest(7, least(30, coalesce(v_days, 90) / 2)) || ' day')::interval;

  -- ── ① 슈퍼어드민에게 — 5일 전부터 매일 ──────────────────────
  with due as (
    select p.id as guest_id,
           coalesce(nullif(btrim(p.display_name), ''), '게스트') as nm,
           public.taam_guest_days_left(p.guest_expires_at) as d,
           (p.guest_expires_at at time zone 'Asia/Seoul')::date as expires_on
      from public.profiles p
     where upper(coalesce(p.membership_tier,'')) = 'A'
       and p.guest_expires_at is not null
  ), pick as (
    select * from due where d between 1 and 5
  ), admins as (
    select id from public.profiles where is_super_admin(id)
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select a.id, 'guest_expiry_admin',
           '게스트 만료 ' || k.d || '일 전',
           k.nm || ' 님의 게스트 기한이 ' || k.d || '일 남았습니다. '
             || '연장하시려면 멤버십 · 게스트 → 게스트 기한에서 [+90일].',
           '/',
           jsonb_build_object('guest_id', k.guest_id, 'days', k.d, 'kind', 'guest_expiry',
                              'expires_on', k.expires_on)
      from pick k cross join admins a
     where not exists (
       select 1 from public.notifications n
        where n.user_id = a.id
          and n.type = 'guest_expiry_admin'
          and n.payload ->> 'guest_id' = k.guest_id::text
          and (n.payload ->> 'days')::int = k.d
          -- 🔧 2026-09-14 기간을 건다 — 종전엔 (guest_id, days) 만 봐서 연장 뒤 다음 주기엔 영영 안 갔다
          and n.created_at > now() - v_win)
    returning id, user_id, title, body, url
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'user_id', i.user_id,
           'title', i.title, 'body', i.body, 'url', i.url)), '[]'::jsonb)
    into v_admin, v_rows_a
    from ins i;

  -- ── ② 게스트 본인에게 — 3일 전·1일 전만 ─────────────────────
  with pick as (
    select p.id as guest_id, public.taam_guest_days_left(p.guest_expires_at) as d
      from public.profiles p
     where upper(coalesce(p.membership_tier,'')) = 'A'
       and p.guest_expires_at is not null
       and public.taam_guest_days_left(p.guest_expires_at) in (1, 3)
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select k.guest_id, 'guest_expiry_self',
           case when k.d = 1 then '내일 초대가 종료됩니다'
                             else '초대 종료 ' || k.d || '일 전입니다' end,
           '예약하시면 기한이 다시 늘어납니다.',
           '/',
           jsonb_build_object('days', k.d, 'kind', 'guest_expiry')
      from pick k
     where not exists (
       select 1 from public.notifications n
        where n.user_id = k.guest_id
          and n.type = 'guest_expiry_self'
          and (n.payload ->> 'days')::int = k.d
          and n.created_at > now() - v_win)
    returning id, user_id, title, body, url
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'user_id', i.user_id,
           'title', i.title, 'body', i.body, 'url', i.url)), '[]'::jsonb)
    into v_self, v_rows_s
    from ins i;

  v_ids := v_rows_a || v_rows_s;
  return jsonb_build_object('admin', v_admin, 'self', v_self, 'rows', v_ids);
end;
$$;
revoke all on function public.taam_guest_expiry_notify() from public, anon, authenticated;
grant execute on function public.taam_guest_expiry_notify() to service_role;


-- ═══════════════════════════════════════════════════════════════
-- ② 대관 링크 결제 시작 — 이름 길이 · 속도 제한
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_kashikiri_order_start(
  p_token text,
  p_name  text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare c public.kashikiri_charges%rowtype; v_order text; e_row public.kashikiri_events%rowtype;
begin
  if p_token is null or length(p_token) < 16 then
    raise exception '없는 링크입니다' using errcode = 'P0002';
  end if;
  -- 🆕 2026-09-14 토큰당 10분 30회 (anon 이 부른다). 제한기가 없으면 통과.
  if to_regprocedure('public.taam_rate_hit(text,integer,interval)') is not null then
    if not public.taam_rate_hit('ksk_start:' || left(p_token, 16), 30, interval '10 minutes') then
      raise exception '요청이 너무 잦습니다. 잠시 후 다시 시도해주세요' using errcode = 'P0001';
    end if;
  end if;

  select * into c from public.kashikiri_charges where token = p_token;
  if not found then raise exception '없는 링크입니다' using errcode = 'P0002'; end if;
  if c.status = 'paid' then
    return jsonb_build_object('already_paid', true, 'order_id', c.order_id);
  end if;
  if c.status in ('cancelled','expired') then
    return jsonb_build_object('blocked', c.status);
  end if;
  if c.expires_at is not null and now() > c.expires_at then
    update public.kashikiri_charges set status = 'expired' where id = c.id;
    return jsonb_build_object('blocked', 'expired');
  end if;

  select * into e_row from public.kashikiri_events where id = c.event_id;
  v_order := coalesce(c.order_id, 'KSK-' || replace(c.id::text, '-', ''));

  update public.kashikiri_charges
     set order_id   = v_order,
         -- 🆕 2026-09-14 60자 제한 (anon 입력이 길이 제한 없이 들어왔다)
         payer_name = coalesce(nullif(left(btrim(p_name), 60), ''), payer_name)
   where id = c.id;

  return jsonb_build_object(
    'order_id',   v_order,
    'currency',   coalesce(c.pay_currency, 'KRW'),
    'amount',     coalesce(c.pay_amount, c.amount_krw),
    'amount_krw', c.amount_krw,
    'order_name', '[TAAM] ' || to_char(e_row.event_date, 'MM/DD')
                  || ' ' || coalesce(e_row.venue_name, 'TAAM')
  );
end;
$$;
revoke all on function public.taam_kashikiri_order_start(text, text) from public;
grant execute on function public.taam_kashikiri_order_start(text, text) to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- ③ 오류 신고 — extra 상한 · 익명 세션별 버킷
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_report_error(
  p_kind     text,
  p_message  text,
  p_stack    text  default null,
  p_url      text  default null,
  p_build    text  default null,
  p_platform text  default null,
  p_extra    jsonb default '{}'::jsonb
)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_role  text;
  v_n     int;
  v_sid   text;
  v_extra jsonb;
begin
  v_extra := case when jsonb_typeof(p_extra) = 'object' then p_extra else '{}'::jsonb end;
  -- 🆕 2026-09-14 4KB 를 넘는 extra 는 통째로 표지로 바꾼다 (잘라서 캐스트하면 예외로 신고 전체가 버려진다)
  if pg_column_size(v_extra) > 4000 then
    v_extra := jsonb_build_object('_truncated', true, '_size', pg_column_size(v_extra));
  end if;

  if v_uid is not null then
    select count(*) into v_n from public.app_errors
     where user_id = v_uid and created_at > now() - interval '1 hour';
    if v_n >= 60 then return; end if;
  else
    -- 🆕 익명은 앱이 준 세션 id(sid)별로 20건, 전체로는 300건. 한 사람이 남의 신고까지 막지 못한다.
    v_sid := left(coalesce(v_extra ->> 'sid', ''), 40);
    if v_sid <> '' then
      select count(*) into v_n from public.app_errors
       where user_id is null and extra ->> 'sid' = v_sid and created_at > now() - interval '1 hour';
      if v_n >= 20 then return; end if;
    end if;
    select count(*) into v_n from public.app_errors
     where user_id is null and created_at > now() - interval '1 hour';
    if v_n >= 300 then return; end if;
  end if;

  if v_uid is not null then
    select p.role into v_role from public.profiles p where p.id = v_uid;
  end if;

  insert into public.app_errors (user_id, role, build, platform, kind, message, stack, url, extra)
  values (
    v_uid, v_role,
    left(p_build, 40), left(p_platform, 20),
    left(coalesce(nullif(btrim(p_kind), ''), 'js'), 40),
    left(coalesce(p_message, ''), 500),
    left(p_stack, 2000),
    left(p_url, 300),
    v_extra
  );
exception when others then
  return;
end;
$$;
revoke all on function public.taam_report_error(text,text,text,text,text,text,jsonb) from public;
grant execute on function public.taam_report_error(text,text,text,text,text,text,jsonb) to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- ④ 파트너 QR 조회 — 열람 기록에 속도 제한
-- ═══════════════════════════════════════════════════════════════
create or replace function public.partner_qr_lookup(p_code text, p_ua text default null, p_log boolean default true)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.partner_qr_codes%rowtype;
  v_log boolean := coalesce(p_log, true);
begin
  if upper(trim(coalesce(p_code,''))) = 'GENERIC' then
    return json_build_object(
      'ok', true, 'generic', true,
      'restaurant_name','', 'chef_name','', 'lang','',
      'meal_price','', 'beverage_price','', 'extra_note','',
      'logos', coalesce(
        (select json_agg(image_url order by sort_order, id) from public.partner_logos),
        '[]'::json)
    );
  end if;

  -- 🆕 2026-09-14 코드 열거 방지 — 너무 짧으면 조회조차 안 한다
  if length(trim(coalesce(p_code,''))) < 4 then
    return json_build_object('ok', false);
  end if;

  select * into r
  from public.partner_qr_codes
  where code = upper(trim(p_code)) and active = true;

  if not found then
    return json_build_object('ok', false);
  end if;

  -- 🆕 2026-09-14 열람 기록만 제한한다 — 넘치면 기록을 건너뛰고 데이터는 준다
  if v_log and to_regprocedure('public.taam_rate_hit(text,integer,interval)') is not null then
    if not public.taam_rate_hit('pqr_all', 600, interval '1 hour')
       or not public.taam_rate_hit('pqr:' || r.code, 120, interval '1 hour') then
      v_log := false;
    end if;
  end if;
  if v_log then
    insert into public.partner_qr_views(code, user_agent)
    values (r.code, left(coalesce(p_ua, ''), 400));
  end if;

  return json_build_object(
    'ok', true,
    'restaurant_name', r.restaurant_name,
    'chef_name',       coalesce(r.chef_name, ''),
    'lang',            r.lang,
    'meal_price',      coalesce(r.meal_price, ''),
    'beverage_price',  coalesce(r.beverage_price, ''),
    'extra_note',      coalesce(r.extra_note, ''),
    'logos', coalesce(
      (select json_agg(image_url order by sort_order, id) from public.partner_logos),
      '[]'::json)
  );
end;
$$;
revoke execute on function public.partner_qr_lookup(text, text, boolean) from public;
grant  execute on function public.partner_qr_lookup(text, text, boolean) to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 게스트 만료 열쇠에 기간' as "구분",
       case when p.prosrc like '%now() - v_win%' then '✅' else '❌ 옛 판' end as "상태", '' as "메모"
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_guest_expiry_notify'
union all
select '② order_start 이름 60자·속도 제한',
       case when p.prosrc like '%ksk_start:%' and p.prosrc like '%left(btrim(p_name), 60)%' then '✅' else '❌' end, ''
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_kashikiri_order_start'
union all
select '③ 오류 신고 extra 상한·익명 버킷',
       case when p.prosrc like '%_truncated%' and p.prosrc like '%''sid''%' then '✅' else '❌' end, ''
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_report_error'
union all
select '④ QR 조회 열람 기록 속도 제한',
       case when p.prosrc like '%pqr_all%' then '✅' else '❌' end, ''
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'partner_qr_lookup'
union all
select '⑤ 제한기(taam_rate_hit) 존재',
       case when to_regprocedure('public.taam_rate_hit(text,integer,interval)') is not null then '✅' else '⚠ 없음 — 제한 없이 통과' end, ''
order by 1;
