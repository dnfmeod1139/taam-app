-- ═══════════════════════════════════════════════════════════════
-- 회원이 결제 링크로 산 티켓(LINK- + memberUid)은 회원의 예약이다 — 방문 리마인드 · 멤버십 시작일에 센다 (2026-10-19)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 2026-10-18 결제 링크 재구성으로 티켓 링크에 회원을 골라 보내면 결제 뒤 그 회원의 티켓이 된다(user_id 이전 · extra_data.memberUid).
--     그런데 방문 리마인드(taam_visit_reminder_notify · sql/visit_reminder.sql)와 멤버십 시작일(taam_member_start · 20261015 판)은
--     LINK- 접두어를 통째로 빼서 — 「링크 결제 = 비회원 손님」이던 시절 규칙 — 그 회원은 리마인드를 못 받고 첫 구매로도 안 세였다.
-- 무엇: 두 함수에서 LINK- 제외를 「memberUid 가 없을 때만」으로 좁힌다. 비회원 LINK- · KSK- · MAN- 는 종전 그대로(비회원은 알림톡으로 따로 — 20261019_guest_reminder.sql).
-- ⚠ 라이브 함수 둘을 바꾼다. 라이브 본문의 md5 가 저장소 원본과 **같을 때만** 바꾸고, 다르면 건너뛰고 확인 표에 ❌ 로 알린다
--    (대시보드에서 손본 판을 모르고 덮어쓰지 않기 위해). ❌ 가 나오면 `select pg_get_functiondef('public.<함수>'::regproc)` 결과를 보내 달라.
--    예치금 결제 티켓(PAYH-/PAYC-/INV-)은 종전부터 들어 있었다 — 이 파일은 LINK- 만 다룬다.
-- 회귀: bash sql/_test/t_member_link_rows.sh
-- ═══════════════════════════════════════════════════════════════

drop table if exists _mlr;
create temp table _mlr(name text primary key, status text);   -- 세션 임시표 (psql -f 의 자동 커밋에서도 남게 on commit drop 은 쓰지 않는다)

do $do$
declare v_live text;
begin
  select md5(p.prosrc) into v_live from pg_proc p where p.oid = to_regproc('public.taam_visit_reminder_notify');
  if v_live is null then
    insert into _mlr values ('taam_visit_reminder_notify', '❌ 라이브에 함수가 없다 — sql/visit_reminder.sql 먼저');
  elsif v_live <> '07b7ff71b72383ee5cf0adc998e0659a' then
    insert into _mlr values ('taam_visit_reminder_notify', '❌ 라이브 본문이 저장소 원본(sql/visit_reminder.sql)과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  else
    execute $fn$
create or replace function public.taam_visit_reminder_notify()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $b$
declare v_cnt int := 0; v_rows jsonb;
begin
  with due as (
    select t.id            as ticket_id,
           t.user_id,
           coalesce(nullif(btrim(t.restaurant_name), ''), '예약하신 매장') as rest_nm,
           coalesce(nullif(btrim(t.visit_time), ''), '')                   as vtime,
           public.taam_visit_days_left(t.reservation_date)                 as d
      from public.tickets t
     where t.user_id is not null
       -- 확정된 예약만. 'hold'(좌석 잡아둔 미결제)·'cancelled'·'expired' 는 제외한다.
       and lower(coalesce(t.status,'')) = 'active'
       -- 🆕 2026-09-29 어드민이 잡은 좌석은 회원의 예약이 아니다 — 정산 결제(KSK-)·링크 초대(LINK-)·수동(MAN-) 행의
       --   user_id 는 회차 작성자·어드민이라, 두면 어드민이 「내일 방문 예정입니다」를 남의 자리로 받는다.
       and coalesce(t.purchase_id, '') not like 'KSK-%'
       -- 🆕 2026-10-19 결제 링크로 회원이 산 LINK- 행(extra_data.memberUid = 그 회원)은 회원의 예약이다 — 리마인드가 간다. 비회원 LINK- 는 종전대로 뺀다(알림톡이 따로 간다)
       and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
       and coalesce(t.purchase_id, '') not like 'MAN-%'
       and not coalesce((t.extra_data ? 'kashikiri') or ((t.extra_data ? 'linkInvite') and nullif(t.extra_data->>'memberUid', '') is null) or (t.extra_data ? 'manualEntry'), false)
  ), pick as (
    select * from due where d in (1, 3, 7)
  ), want as (
    -- 회원이 켜 둔 것만. 설정을 안 만졌으면 3일·1일만 보낸다(7일은 기본 꺼짐).
    select k.*
      from pick k
      join public.profiles p on p.id = k.user_id
     -- 🆕 2026-09-29 boolean 이 아닌 값이 하나라도 있으면 ::boolean 캐스트가 함수 전체를 죽여 그날 아무도 못 받았다.
     --   boolean 일 때만 읽고, 아니면 기본값(3일·1일 켜짐)으로 본다.
     where coalesce(
             case when jsonb_typeof(p.notif_prefs -> ('remind' || k.d::text)) = 'boolean'
                  then (p.notif_prefs ->> ('remind' || k.d::text))::boolean else null end,
             k.d in (1, 3)
           ) is true
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select w.user_id,
           'visit_reminder',
           case when w.d = 1 then '내일 방문 예정입니다'
                when w.d = 3 then '3일 뒤 방문 예정입니다'
                else '방문 ' || w.d || '일 전입니다' end,
           w.rest_nm
             || case when w.vtime <> '' then ' · ' || w.vtime else '' end
             || case when w.d = 1 then ' 예약이 내일입니다.'
                     else ' 예약이 ' || w.d || '일 남았습니다.' end,
           '/',
           -- rest·time 도 실어 둔다 — Edge Function 이 이걸로 EN·JA 문구를 만든다.
           --   (send-push 는 payload.i18n 을 받으면 기기 언어로 골라 보낸다)
           jsonb_build_object('ticket_id', w.ticket_id, 'days', w.d,
                              'kind', 'visit_reminder',
                              'rest', w.rest_nm, 'time', w.vtime)
      from want w
     -- 같은 티켓·같은 일수로는 한 번만. 하루가 지나면 일수가 달라져 다시 나간다.
     where not exists (
       select 1 from public.notifications n
        where n.user_id = w.user_id
          and n.type = 'visit_reminder'
          and n.payload ->> 'ticket_id' = w.ticket_id::text
          and (n.payload ->> 'days')::int = w.d)
    -- ⚠ 이번 실행이 **실제로 넣은 행만** 돌려받는다.
    --   예전에는 여기서 1 만 돌려받고, 푸시 대상은 따로
    --   「created_at > now() - 2분」으로 다시 긁었다. 그러면 이번 실행이
    --   만든 것인지 구분하지 못해, 2분 안에 두 번 부르면 앞 실행이 만든
    --   알림을 다시 집어 **같은 회원에게 푸시가 두 번** 나갔다.
    --   (made:0 인데 push_sent:1 로 실제로 관측됨)
    returning id, user_id, title, body, url, payload
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id',        i.id,
           'user_id',   i.user_id,
           'title',     i.title,
           'body',      i.body,
           'url',       i.url,
           'days',      (i.payload ->> 'days')::int,
           'ticket_id', i.payload ->> 'ticket_id',
           'rest',      i.payload ->> 'rest',
           'vtime',     i.payload ->> 'time'
         )), '[]'::jsonb)
    into v_cnt, v_rows
    from ins i;

  return jsonb_build_object('made', v_cnt, 'rows', v_rows);
end;
$b$
    $fn$;
    insert into _mlr values ('taam_visit_reminder_notify', '✅ 교체');
  end if;

  select md5(p.prosrc) into v_live from pg_proc p where p.oid = to_regprocedure('public.taam_member_start(uuid)');
  if v_live is null then
    insert into _mlr values ('taam_member_start', '❌ 라이브에 함수가 없다 — 20261013_member_start.sql · 20261015_membership_joined.sql 먼저');
  elsif v_live <> '9af9efe7613b6ccb3bfc136671728b05' then
    insert into _mlr values ('taam_member_start', '❌ 라이브 본문이 저장소 원본(20261015_membership_joined.sql 판)과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  else
    execute $fn$
create or replace function public.taam_member_start(p_uid uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $b$
declare
  u uuid := coalesce(p_uid, auth.uid());
  v_signup timestamptz; v_mj date; v_tk timestamptz; v_led timestamptz; v_inv timestamptz;
  v_buy timestamptz; v_start timestamptz; v_kind text; v_app date;
begin
  if u is null then return null; end if;
  -- 🔒 2026-10-16 비로그인(auth.uid() null)은 거절 — 종전엔 `u <> null` 이 NULL 이라 검사가 통째로 비켜 가 anon 키로 아무 uid 의 날짜를 읽을 수 있었다(적대 리뷰)
  if auth.uid() is null or (u <> auth.uid() and not public._taam_uid_is_super()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select p.created_at, p.membership_joined_at into v_signup, v_mj from public.profiles p where p.id = u;
  if not found then return null; end if;
  select min(t.created_at) into v_tk
    from public.tickets t
   where t.user_id = u
     and coalesce(t.status, '') not in ('cancelled', 'hold', 'expired')
     and coalesce(t.purchase_id, '') not like 'PAYH-%'
     and coalesce(t.purchase_id, '') not like 'INVH-%'
     and coalesce(t.purchase_id, '') not like 'KSK-%'
     -- 🆕 2026-10-19 결제 링크로 회원이 산 LINK- 행(memberUid)은 그 회원의 첫 구매로 센다. 비회원 LINK- 는 종전대로 뺀다
     and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
     and coalesce(t.purchase_id, '') not like 'MAN-%';
  if to_regclass('public.deposit_transactions') is not null then
    select min(d.created_at) into v_led
      from public.deposit_transactions d
     where d.user_id = u and d.change_type = 'ticket_purchase';
  end if;
  if to_regclass('public.reservation_invites') is not null then
    select min(i.created_at) into v_inv
      from public.reservation_invites i
     where i.invitee_user_id = u and i.status = 'paid';
  end if;
  v_buy   := least(v_tk, v_led);           -- least 는 null 을 건너뛴다
  v_start := least(v_buy, v_inv);
  v_kind  := case when v_start is null then null
                  when v_inv is not null and v_inv <= coalesce(v_buy, v_inv) then 'invite'
                  else 'purchase' end;
  v_app   := case when v_signup is null then null else (v_signup at time zone 'Asia/Seoul')::date end;
  return jsonb_build_object(
    'uid',                  u,
    'signup_at',            v_signup,
    'app_signup_date',      v_app,                                   -- ① 앱 가입일 (KST 날짜)
    'membership_joined_at', v_mj,                                    -- ② 실제 멤버십 가입일 (슈퍼어드민이 적은 것 · 없으면 null)
    'joined_at',            coalesce(v_mj, v_app),                   -- 회원에게 보여 줄 「가입일」 = ② 있으면 ②, 없으면 ①
    'joined_kind',          case when v_mj is not null then 'manual' else 'app' end,
    'first_purchase_at',    v_buy,
    'first_invite_at',      v_inv,
    'start_at',             v_start,                                 -- ③ 멤버십 시작일
    'start_kind',           v_kind,
    'started',              (v_start is not null),
    'year_end_at',          case when v_start is null then null else v_start + interval '1 year' end
  );
end $b$
    $fn$;
    insert into _mlr values ('taam_member_start', '✅ 교체');
  end if;
end $do$;

-- ── 확인 — 한 표 ──
select '① ' || name || ' 교체' as 항목, status as 결과 from _mlr
union all select '② 리마인드 함수가 memberUid 를 본다', case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_visit_reminder_notify') and prosrc like '%memberUid%') then '✅' else '❌' end
union all select '③ 시작일 함수가 memberUid 를 본다', case when exists (select 1 from pg_proc where oid = to_regprocedure('public.taam_member_start(uuid)') and prosrc like '%memberUid%') then '✅' else '❌' end
order by 1;
