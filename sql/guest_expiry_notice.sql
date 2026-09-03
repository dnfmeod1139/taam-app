-- ═══════════════════════════════════════════════════════════════
-- TAAM — 게스트 만료가 다가오면 알린다 (2026-09-03)
-- ═══════════════════════════════════════════════════════════════
-- 규칙
--   슈퍼어드민 — 만료 5일 전부터 **매일** (5·4·3·2·1일 남음)
--                 연장할지 그냥 보낼지 판단할 시간을 준다.
--   게스트 본인 — **3일 전 · 1일 전** 두 번만.
--                 매일 보내면 재촉이 된다. 초대는 재촉하는 것이 아니다.
--
--   구매하면 기한이 다시 90일로 서므로(trg_taam_guest_touch_on_purchase)
--   알림도 저절로 멈춘다. 어드민이 [+90일] 을 눌러도 마찬가지다.
--   ⚠ 그래서 「멈춤」을 따로 만들지 않았다. 조건이 사라지면 안 나간다.
--
-- 하루에 한 번만
--   ⚠ 「보냈다」를 따로 적어 두지 않는다. **남은 일수를 열쇠로** 쓴다.
--     같은 사람·같은 일수로는 한 번만 들어간다. 하루가 지나면 일수가
--     달라져 다시 나간다. 작업이 하루 걸러 돌아도 그날 숫자로 나간다.
--     별도 발송대장을 두면 그 표와 실제 발송이 어긋나는 날이 온다.
--
-- 실행: Supabase SQL Editor. ⚠ guest_expiry_init.sql 다음.
-- ═══════════════════════════════════════════════════════════════

-- 남은 일수. 오늘 자정 기준으로 센다 — 시:분 때문에 「4.7일」이 되지 않게.
create or replace function public.taam_guest_days_left(p_at timestamptz)
returns int
language sql stable
as $$
  select case when p_at is null then null
              else (p_at at time zone 'Asia/Seoul')::date - (now() at time zone 'Asia/Seoul')::date
         end;
$$;

create or replace function public.taam_guest_expiry_notify()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_admin int := 0; v_self int := 0; v_ids jsonb;
begin
  -- ── ① 슈퍼어드민에게 — 5일 전부터 매일 ──────────────────────
  with due as (
    select p.id as guest_id,
           coalesce(nullif(btrim(p.display_name), ''), '게스트') as nm,
           public.taam_guest_days_left(p.guest_expires_at) as d
      from public.profiles p
     where upper(coalesce(p.membership_tier,'')) = 'A'
       and p.guest_expires_at is not null
  ), pick as (
    select * from due where d between 1 and 5
  ), admins as (
    -- 슈퍼어드민 판정은 한 곳에서만 한다 — 이메일 목록을 여기 또 적지 않는다.
    select id from public.profiles where is_super_admin(id)
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select a.id, 'guest_expiry_admin',
           '게스트 만료 ' || k.d || '일 전',
           k.nm || ' 님의 게스트 기한이 ' || k.d || '일 남았습니다. '
             || '연장하시려면 멤버십 · 게스트 → 게스트 기한에서 [+90일].',
           '/',
           jsonb_build_object('guest_id', k.guest_id, 'days', k.d, 'kind', 'guest_expiry')
      from pick k cross join admins a
     where not exists (
       select 1 from public.notifications n
        where n.user_id = a.id
          and n.type = 'guest_expiry_admin'
          and n.payload ->> 'guest_id' = k.guest_id::text
          and (n.payload ->> 'days')::int = k.d)
    returning 1
  )
  select count(*) into v_admin from ins;

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
           -- 「끝난다」로만 끝내지 않는다. 지금 할 수 있는 것을 같이 적는다.
           '예약하시면 기한이 다시 늘어납니다.',
           '/',
           jsonb_build_object('days', k.d, 'kind', 'guest_expiry')
      from pick k
     where not exists (
       select 1 from public.notifications n
        where n.user_id = k.guest_id
          and n.type = 'guest_expiry_self'
          and (n.payload ->> 'days')::int = k.d
          and n.created_at > now() - interval '30 day')
    returning 1
  )
  select count(*) into v_self from ins;

  -- 방금 넣은 것들 — Edge Function 이 이걸로 푸시를 쏜다
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_ids
    from (select n.id, n.user_id, n.title, n.body, n.url
            from public.notifications n
           where n.type in ('guest_expiry_admin','guest_expiry_self')
             and n.created_at > now() - interval '2 minute') x;

  return jsonb_build_object('admin', v_admin, 'self', v_self, 'rows', v_ids);
end;
$$;

comment on function public.taam_guest_expiry_notify() is
  '게스트 만료 알림 — 슈퍼어드민은 5일 전부터 매일, 본인은 3·1일 전. 남은 일수를 열쇠로 써서 하루 한 번만 들어간다.';

revoke all on function public.taam_guest_expiry_notify() from public;
-- 사람이 부를 일은 없다. Edge Function(service_role)만 부른다.


-- ── 매일 돌린다 ────────────────────────────────────────────────
--   ⚠ 이것만으로는 **인앱 알림(종 아이콘)** 까지다. 실제 푸시는
--     notify-guest-expiry Edge Function 이 쏜다 — 그쪽도 같이 걸어야 한다.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('taam_guest_expiry_notify')
      where exists (select 1 from cron.job where jobname = 'taam_guest_expiry_notify');
    perform cron.schedule(
      'taam_guest_expiry_notify',
      '0 1 * * *',                              -- UTC 01:00 = KST 10:00
      'select public.taam_guest_expiry_notify();'
    );
    raise notice '[guest] 만료 알림 예약 완료 — 매일 한국시간 오전 10시';
  else
    raise notice '[guest] pg_cron 이 없습니다 — 대시보드 Cron 이나 Edge Function 스케줄로 거세요';
  end if;
end $$;


-- 예약 상태를 읽는다.
--   ⚠ 확인 쿼리에서 cron.job 을 그냥 쓰면 안 된다. pg_cron 이 없는 DB 에서는
--     실행이 아니라 **파싱**에서 깨져 확인 쿼리 전체가 죽는다.
--     EXECUTE 로 미뤄야 있는 곳에서만 읽는다.
create or replace function public._taam_cron_desc(p_job text)
returns text language plpgsql stable as $$
declare v text;
begin
  if to_regclass('cron.job') is null then return '⚠ pg_cron 없음'; end if;
  execute 'select schedule from cron.job where jobname = $1' into v using p_job;
  return coalesce('✅ ' || v, '❌ 예약 안 됨');
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 알림 함수가 있나 ⭐' as "구분",
       case when count(*) = 1 then '✅' else '❌' end as "상태",
       '슈퍼어드민 5일 전부터 매일 · 본인 3·1일 전' as "메모"
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_guest_expiry_notify'
union all
select '② 매일 예약됐나 ⭐',
       public._taam_cron_desc('taam_guest_expiry_notify'),
       'UTC 01:00 = 한국시간 오전 10시'
union all
select '③ 5일 안에 만료될 게스트',
       (select count(*)::text from public.profiles
         where upper(coalesce(membership_tier,'')) = 'A'
           and public.taam_guest_days_left(guest_expires_at) between 1 and 5) || '명',
       '지금 알림 대상'
union all
select '④ 이미 나간 만료 알림',
       (select count(*)::text from public.notifications
         where type in ('guest_expiry_admin','guest_expiry_self')) || '건',
       '처음이면 0'
 order by 1;
