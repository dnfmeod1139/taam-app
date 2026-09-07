-- ═══════════════════════════════════════════════════════════════
-- TAAM — 방문일이 다가오면 알린다 (2026-09-07)
-- ═══════════════════════════════════════════════════════════════
-- 왜 만드나
--   앱에는 「예약 리마인더 7일 전 / 3일 전 / 1일 전」 설정이 이미 있고
--   send-push 도 remind7·remind3·remind1 을 받을 준비가 되어 있었다.
--   그런데 **보내는 쪽이 없었다.** 구매 시점에 발송시각을 계산해 두고,
--   회원이 앱을 열면 그때 놓친 것을 토스트로 잠깐 보여주는 게 전부였다.
--   앱을 안 열면 영영 오지 않았다.
--
--   서버에서 매일 한 번 훑는 방식으로 바꾼다. 그러면 종전 코드의
--   구멍 세 개가 저절로 사라진다.
--     ① 초대로 받은 티켓은 일정이 빈 배열로 저장돼 리마인드가 없었다
--     ② 구매 뒤에 설정을 켜도 일정이 이미 확정돼 있어 소용없었다
--     ③ 방문일이 바뀌어도 일정이 따라가지 않았다
--   서버는 매일 「지금의 방문일」을 보므로 셋 다 해당 없다.
--
-- 규칙
--   방문 7일 전 · 3일 전 · 1일 전. 회원이 켜 둔 것만 나간다.
--   설정을 안 만진 회원은 기본값으로 **3일 전·1일 전만** 받는다.
--   7일 전은 기본 꺼짐 — 한 예약에 세 번은 많다.
--
-- 하루에 한 번만
--   ⚠ 「보냈다」를 따로 적지 않는다. **티켓 id + 남은 일수를 열쇠로** 쓴다.
--     guest_expiry_notice.sql 과 같은 방식이다. 발송대장을 따로 두면
--     그 표와 실제 발송이 어긋나는 날이 온다.
--
-- 실행: Supabase SQL Editor 에서 RUN.
--   ⚠ 예약(Cron)은 이 파일에 걸지 않는다. 아래 「예약」 절 참고.
-- ═══════════════════════════════════════════════════════════════


-- ── 방문일 읽기 ────────────────────────────────────────────────
--   ⚠ tickets.reservation_date 는 date 가 아니라 **text** 이고 형식이 섞여 있다.
--     _tkFullDate 가 만든 '2027.4.17' (0을 안 채운다), 다른 경로에서 온
--     '2027-04-17', 손으로 넣은 '2027/4/7' 이 한 테이블에 같이 있다.
--     그래서 to_date 를 바로 부르면 어떤 행에서 예외가 나 함수 전체가 죽는다.
--     숫자만 남기고 구분자를 통일한 뒤, 못 읽는 값은 조용히 건너뛴다.
create or replace function public.taam_visit_date(p_raw text)
returns date
language plpgsql immutable
as $$
declare s text; d date;
begin
  s := btrim(coalesce(p_raw, ''));
  if s = '' then return null; end if;
  s := btrim(regexp_replace(s, '[^0-9]+', '-', 'g'), '-');
  begin
    d := to_date(s, 'YYYY-MM-DD');
  exception when others then
    return null;          -- 읽을 수 없는 값에는 알림을 걸지 않는다
  end;
  -- 형식이 깨진 값이 엉뚱한 미래로 튀는 것을 막는다
  if d < date '2020-01-01' or d > date '2100-01-01' then return null; end if;
  return d;
end $$;

comment on function public.taam_visit_date(text) is
  'tickets.reservation_date(text, 형식 제각각)를 date 로. 못 읽으면 null.';


-- ── 남은 일수 ──────────────────────────────────────────────────
--   한국시간 자정 기준으로 센다 — 시:분 때문에 「2.7일」이 되지 않게.
create or replace function public.taam_visit_days_left(p_raw text)
returns int
language sql stable
as $$
  select case
    when public.taam_visit_date(p_raw) is null then null
    else public.taam_visit_date(p_raw) - (now() at time zone 'Asia/Seoul')::date
  end;
$$;


-- ── 알림 만들기 ────────────────────────────────────────────────
create or replace function public.taam_visit_reminder_notify()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
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
  ), pick as (
    select * from due where d in (1, 3, 7)
  ), want as (
    -- 회원이 켜 둔 것만. 설정을 안 만졌으면 3일·1일만 보낸다(7일은 기본 꺼짐).
    select k.*
      from pick k
      join public.profiles p on p.id = k.user_id
     where coalesce(
             (p.notif_prefs ->> ('remind' || k.d::text))::boolean,
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
$$;

comment on function public.taam_visit_reminder_notify() is
  '방문 리마인드 — 7·3·1일 전, 회원이 켠 것만. 티켓id+남은일수를 열쇠로 하루 한 번.';

revoke all on function public.taam_visit_reminder_notify() from public;
-- 사람이 부를 일은 없다. Edge Function(service_role)만 부른다.


-- ── 예약 ───────────────────────────────────────────────────────
--   ⚠ 여기서 pg_cron 으로 이 함수를 돌리면 **푸시를 놓친다.**
--     notify-visit-reminder 는 「방금 들어온 알림」을 보고 푸시를 쏘는데,
--     SQL 예약이 먼저 넣어 버리면 그 함수가 볼 것이 없어진다.
--     guest_expiry_notice.sql 에서 같은 이유로 이미 한 번 겪었다.
--
--   예약은 한 곳에만 — 대시보드 Cron 에서 notify-visit-reminder 를 매일 부른다.
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule('taam_visit_reminder_notify')
      where exists (select 1 from cron.job where jobname = 'taam_visit_reminder_notify');
    raise notice '[visit] SQL 예약은 두지 않는다 — 대시보드 Cron 에서 notify-visit-reminder 를 매일 거세요';
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 알림 함수가 있나 ⭐' as "구분",
       case when count(*) = 1 then '✅' else '❌' end as "상태",
       '방문 7·3·1일 전 · 회원 설정 존중' as "메모"
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_visit_reminder_notify'
union all
select '② 날짜 파서가 형식을 다 읽나 ⭐',
       case when public.taam_visit_date('2027.4.17')  = date '2027-04-17'
             and public.taam_visit_date('2027-04-17') = date '2027-04-17'
             and public.taam_visit_date('2027/4/7')   = date '2027-04-07'
             and public.taam_visit_date('')           is null
             and public.taam_visit_date('없음')        is null
            then '✅' else '❌ 형식을 놓친다' end,
       '2027.4.17 · 2027-04-17 · 2027/4/7 · 빈값 · 쓰레기값'
union all
select '③ 지금 7일 안에 방문할 예약',
       (select count(*)::text from public.tickets
         where lower(coalesce(status,'')) = 'active'
           and public.taam_visit_days_left(reservation_date) between 1 and 7) || '건',
       '오늘 돌리면 알림이 갈 후보'
union all
select '④ 읽지 못한 방문일',
       (select count(*)::text from public.tickets
         where lower(coalesce(status,'')) = 'active'
           and coalesce(btrim(reservation_date),'') <> ''
           and public.taam_visit_date(reservation_date) is null) || '건',
       '0 이 아니면 형식이 더 있다 — 알려주세요'
union all
select '⑤ 이미 나간 방문 리마인드',
       (select count(*)::text from public.notifications where type = 'visit_reminder') || '건',
       '처음이면 0'
 order by 1;
