-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기) + 테스트 발송(슈퍼어드민에게만) — 방문 리마인드 「며칠 전」 알림 (2026-10-27)
-- 왜: 「지금 앱에서 며칠 전 리마인드 예약 알림이 어떻게 돌아가는지 체크하고 테스트 한번 보내봐」.
-- 무엇:
--   A 예약 작업(크론) — 이름·일정·켜짐·키를 Vault 로 읽는지(명령 글자는 찍지 않는다)
--   B 그 작업의 최근 실행 기록(cron.job_run_details)
--   C 최근 HTTP 응답(net._http_response · 보통 6시간만 남는다) — 리마인드 함수 응답(made·push_sent·guest)과 그 시간대의 오류
--   D 최근 14일 리마인드 알림(notifications type visit_reminder) — 날짜(KST)별 건수 · 1/3/7일 전 · 받은 회원 수 · 만든 시각
--   E 지금 대상 — 남은 일수별 회원 예약 수 · 내일 11시에 나갈 몫(설정 반영)
--   F 회원 설정(notif_prefs) — 다가오는 예약이 있는 회원 중 끈 사람 수
--   G 푸시 구독 — 최근 받은 회원 중 기기 구독이 있는 회원 수
--   H 비회원 알림톡(guest_remind_log) — 결과별 건수
--   I 함수 판(md5 · memberUid)
--   J 테스트 — 슈퍼어드민마다 알림함 1줄 + 푸시 1건(실제 리마인드와 같은 문구·category remind1 → 본인 「하루 전」 설정을 따른다)
-- 이름·전화·이메일은 찍지 않는다(건수·시각·매장 이름만). 회원에게는 아무것도 보내지 않는다.
-- 푸시 결과(HTTP 응답)는 이 파일이 끝나야(커밋) 나가므로 다음 진단 파일에서 request_id 로 읽는다.
-- ═══════════════════════════════════════════════════════════════

create temp table _vr(seq serial, 구분 text, 내용 text);

-- ── A · B 예약 작업 ──
do $do$
declare r record; n int := 0;
begin
  begin
    for r in
      select j.jobid, j.jobname, j.schedule, j.active,
             (j.command ilike '%vault%')                                   as uses_vault,
             (j.command ~ 'eyJ[A-Za-z0-9_-]{20,}')                          as literal_jwt,
             coalesce(substring(j.command from '/functions/v1/([a-z0-9_-]+)'), '(SQL 직접)') as target
        from cron.job j
       where j.command ilike '%visit-reminder%' or j.command ilike '%visit_reminder%' or j.jobname ilike '%remind%'
       order by j.jobid
    loop
      n := n + 1;
      insert into _vr(구분, 내용) values ('A 예약 작업 #' || r.jobid,
        coalesce(r.jobname, '-') || ' · 일정 ' || r.schedule || ' (UTC) · ' || case when r.active then '켜짐' else '⚠ 꺼짐' end
        || ' · 대상 ' || r.target || ' · 키 ' || case when r.uses_vault then 'Vault' when r.literal_jwt then '⚠ 명령에 키 글자 그대로' else '헤더 없음?' end);
      insert into _vr(구분, 내용)
      select 'B 실행 기록 #' || r.jobid,
             to_char(d.start_time at time zone 'Asia/Seoul', 'MM-DD HH24:MI') || ' KST · ' || d.status || coalesce(' · ' || left(d.return_message, 60), '')
        from (select * from cron.job_run_details x where x.jobid = r.jobid order by x.start_time desc limit 8) d;
    end loop;
    if n = 0 then insert into _vr(구분, 내용) values ('A 예약 작업', '⚠ 리마인드를 부르는 예약 작업이 없다 — 대시보드 Cron 확인 필요'); end if;
  exception when others then
    insert into _vr(구분, 내용) values ('A 예약 작업', '⚠ cron 표를 못 읽음: ' || left(sqlerrm, 120));
  end;
end $do$;

-- ── C 최근 HTTP 응답 ──
do $do$
begin
  begin
    insert into _vr(구분, 내용)
    select 'C 리마인드 응답', to_char(h.created at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') || ' KST · HTTP ' || coalesce(h.status_code::text, '-')
           || ' · ' || left(coalesce(h.content, h.error_msg, ''), 220)
      from net._http_response h
     where h.content ilike '%push_sent%'
     order by h.created desc limit 10;
    insert into _vr(구분, 내용)
    select 'C 11시 무렵 오류 응답', to_char(h.created at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') || ' KST · HTTP ' || coalesce(h.status_code::text, '-')
           || ' · ' || left(coalesce(h.content, h.error_msg, ''), 160)
      from net._http_response h
     where (coalesce(h.status_code, 0) not between 200 and 299 or h.timed_out)
       and extract(hour from (h.created at time zone 'Asia/Seoul')) = 11
       and extract(minute from (h.created at time zone 'Asia/Seoul')) < 15
     order by h.created desc limit 10;
    insert into _vr(구분, 내용)
    select 'C 응답 표 범위', coalesce(to_char(min(h.created) at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), '-') || ' ~ '
           || coalesce(to_char(max(h.created) at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), '-') || ' KST · ' || count(*) || '줄 (pg_net 은 보통 6시간만 남긴다)'
      from net._http_response h;
  exception when others then
    insert into _vr(구분, 내용) values ('C 응답', '⚠ net._http_response 를 못 읽음: ' || left(sqlerrm, 120));
  end;
end $do$;

-- ── D 최근 14일 리마인드 알림 ──
insert into _vr(구분, 내용)
select 'D ' || k.day || ' (KST)',
       '알림 ' || k.n || '건 · 1일 전 ' || k.d1 || ' · 3일 전 ' || k.d3 || ' · 7일 전 ' || k.d7 || ' · 회원 ' || k.users || '명 · 만든 시각 ' || k.t0 || '~' || k.t1
  from (
    select to_char(n.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD') as day,
           count(*) as n,
           count(*) filter (where (n.payload->>'days') = '1') as d1,
           count(*) filter (where (n.payload->>'days') = '3') as d3,
           count(*) filter (where (n.payload->>'days') = '7') as d7,
           count(distinct n.user_id) as users,
           to_char(min(n.created_at) at time zone 'Asia/Seoul', 'HH24:MI') as t0,
           to_char(max(n.created_at) at time zone 'Asia/Seoul', 'HH24:MI') as t1
      from public.notifications n
     where n.type = 'visit_reminder' and coalesce(n.payload->>'test', '') <> 'true'
       and n.created_at > now() - interval '14 days'
     group by 1
  ) k
 order by k.day desc;
insert into _vr(구분, 내용)
select 'D 합계(전체 기간)', '리마인드 알림 ' || count(*) || '건 · 첫 ' || coalesce(to_char(min(created_at) at time zone 'Asia/Seoul', 'YYYY-MM-DD'), '-')
       || ' · 마지막 ' || coalesce(to_char(max(created_at) at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'), '-')
  from public.notifications where type = 'visit_reminder' and coalesce(payload->>'test', '') <> 'true';

-- ── E 지금 대상 (함수와 같은 거름: 확정 active · 회원 · 운영 행 제외 · 회원 소유 LINK- 포함) ──
create temp table _vr_t as
select t.id, t.user_id, public.taam_visit_days_left(t.reservation_date) as d,
       coalesce(nullif(btrim(t.restaurant_name), ''), '예약하신 매장') as rest, coalesce(nullif(btrim(t.visit_time), ''), '') as vtime,
       p.notif_prefs as prefs
  from public.tickets t
  join public.profiles p on p.id = t.user_id
 where t.user_id is not null
   and lower(coalesce(t.status, '')) = 'active'
   and coalesce(t.purchase_id, '') not like 'KSK-%'
   and coalesce(t.purchase_id, '') not like 'MAN-%'
   and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
   and not coalesce((t.extra_data ? 'kashikiri') or ((t.extra_data ? 'linkInvite') and nullif(t.extra_data->>'memberUid', '') is null) or (t.extra_data ? 'manualEntry'), false);

create or replace function pg_temp.vr_want(p jsonb, d int) returns boolean language sql immutable as $f$
  select coalesce(case when jsonb_typeof(p -> ('remind' || d::text)) = 'boolean' then (p ->> ('remind' || d::text))::boolean else null end, d in (1, 3))
$f$;

insert into _vr(구분, 내용)
select 'E 남은 일수별 예약', string_agg(x.d || '일 ' || x.n || '건', ' · ' order by x.d)
  from (select d, count(*) n from _vr_t where d between 0 and 10 group by d) x;
insert into _vr(구분, 내용)
select 'E 오늘(11시 실행) 대상', '1일 전 ' || count(*) filter (where d = 1) || '건(설정상 보냄 ' || count(*) filter (where d = 1 and pg_temp.vr_want(prefs, 1)) || ') · '
       || '3일 전 ' || count(*) filter (where d = 3) || '건(보냄 ' || count(*) filter (where d = 3 and pg_temp.vr_want(prefs, 3)) || ') · '
       || '7일 전 ' || count(*) filter (where d = 7) || '건(보냄 ' || count(*) filter (where d = 7 and pg_temp.vr_want(prefs, 7)) || ')'
       || ' · 그중 알림 이미 있음 ' || count(*) filter (where d in (1, 3, 7) and exists (
            select 1 from public.notifications n where n.user_id = _vr_t.user_id and n.type = 'visit_reminder'
               and n.payload->>'ticket_id' = _vr_t.id::text and n.payload->>'days' = _vr_t.d::text))
  from _vr_t;
insert into _vr(구분, 내용)
select 'E 내일 11시 예정', '1일 전 ' || count(*) filter (where d = 2 and pg_temp.vr_want(prefs, 1)) || '건 · 3일 전 ' || count(*) filter (where d = 4 and pg_temp.vr_want(prefs, 3))
       || '건 · 7일 전 ' || count(*) filter (where d = 8 and pg_temp.vr_want(prefs, 7)) || '건 (회원 설정 반영)'
  from _vr_t;

-- ── F 회원 설정 (다가오는 예약이 있는 회원) ──
insert into _vr(구분, 내용)
select 'F 알림 설정', '다가오는 예약이 있는 회원 ' || count(*) || '명 · 전체 끔 ' || count(*) filter (where (prefs->>'all') = 'false')
       || ' · 하루 전 끔 ' || count(*) filter (where (prefs->>'remind1') = 'false') || ' · 3일 전 끔 ' || count(*) filter (where (prefs->>'remind3') = 'false')
       || ' · 7일 전 켬 ' || count(*) filter (where (prefs->>'remind7') = 'true')
  from (select distinct on (user_id) user_id, prefs from _vr_t where d between 1 and 60) u;

-- ── G 푸시 구독 ──
do $do$
begin
  begin
    insert into _vr(구분, 내용)
    select 'G 푸시 구독', '최근 14일 리마인드 받은 회원 ' || count(*) || '명 중 기기 구독 있음 ' || count(*) filter (where exists (select 1 from public.push_subscriptions s where s.user_id = r.user_id))
           || ' · 다가오는 예약 회원 중 구독 있음 ' || (select count(distinct t.user_id) from _vr_t t where t.d between 1 and 60 and exists (select 1 from public.push_subscriptions s where s.user_id = t.user_id))
           || '/' || (select count(distinct t.user_id) from _vr_t t where t.d between 1 and 60)
      from (select distinct user_id from public.notifications where type = 'visit_reminder' and created_at > now() - interval '14 days') r;
  exception when others then
    insert into _vr(구분, 내용) values ('G 푸시 구독', '⚠ push_subscriptions 를 못 읽음: ' || left(sqlerrm, 120));
  end;
end $do$;

-- ── H 비회원 알림톡 ──
do $do$
begin
  begin
    insert into _vr(구분, 내용)
    select 'H 비회원 알림톡(14일)', coalesce(string_agg(x.k || ' ' || x.n || '건', ' · '), '기록 없음')
      from (select split_part(coalesce(result, '-'), '(', 1) || coalesce('(' || nullif(substring(result from '\((.*)\)'), '') || ')', '') as k, count(*) n
              from public.guest_remind_log where sent_at > now() - interval '14 days' group by 1 order by 2 desc) x;
    insert into _vr(구분, 내용)
    select 'H 지금 알림톡 대상', count(*)::text || '건 (3일 전·1일 전 · 아직 안 보낸 것)' from public.taam_guest_reminder_targets();
  exception when others then
    insert into _vr(구분, 내용) values ('H 비회원 알림톡', '⚠ 못 읽음: ' || left(sqlerrm, 120));
  end;
end $do$;

-- ── I 함수 판 ──
insert into _vr(구분, 내용)
select 'I 리마인드 함수', coalesce((select 'md5 ' || md5(prosrc) || case when prosrc like '%memberUid%' then ' · 회원 소유 LINK- 포함 판' else ' · ⚠ 옛 판(LINK- 통째 제외)' end
                                    from pg_proc where oid = to_regproc('public.taam_visit_reminder_notify')), '⚠ 함수 없음');

-- ── J 테스트 발송 — 슈퍼어드민에게만 ──
do $do$
declare r record; v_rest text; v_time text; v_title text; v_body text; v_i18n jsonb; v_res jsonb; v_body_rest text;
begin
  -- 문구는 실제 리마인드와 같은 모양 — 가장 가까운 다가오는 예약의 매장·시각을 빌린다(없으면 예시)
  select rest, vtime into v_rest, v_time from _vr_t where d >= 1 order by d, rest limit 1;
  v_rest := coalesce(v_rest, '스시 사이토'); v_time := coalesce(nullif(v_time, ''), '18:00');
  v_body_rest := v_rest || case when v_time <> '' then ' · ' || v_time else '' end;
  v_title := '[테스트] 내일 방문 예정입니다';
  v_body  := v_body_rest || ' 예약이 내일입니다.';
  v_i18n := jsonb_build_object(
    'ko', jsonb_build_object('title', v_title, 'body', v_body),
    'en', jsonb_build_object('title', '[Test] Your reservation is tomorrow', 'body', v_body_rest || ' — see you tomorrow.'),
    'ja', jsonb_build_object('title', '[テスト] 明日ご来店の予定です', 'body', v_body_rest || ' — 明日のご予約です。'));
  for r in
    select p.id, coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as prefs
      from public.profiles p
     where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = ''
  loop
    insert into public.notifications(user_id, type, title, body, url, payload)
    values (r.id, 'visit_reminder', v_title, v_body, '/', jsonb_build_object('kind', 'visit_reminder', 'test', true, 'days', 1, 'rest', v_rest, 'time', v_time));
    begin
      v_res := public._taam_member_push(r.id, v_title, v_body, '/', 'visit-reminder-test-' || extract(epoch from now())::bigint, 'remind1', v_i18n);
    exception when others then v_res := jsonb_build_object('ok', false, 'reason', left(sqlerrm, 120)); end;
    insert into _vr(구분, 내용) values ('J 테스트 발송 · 슈퍼어드민 …' || right(r.id::text, 4),
      '알림함 1줄 · 푸시 ' || case when coalesce((v_res->>'ok')::boolean, false) then '요청함 request_id=' || (v_res->>'request_id') else '⚠ 못 보냄(' || coalesce(v_res->>'reason', '?') || ')' end
      || ' · 기기 구독 ' || (select count(*) from public.push_subscriptions s where s.user_id = r.id) || '개'
      || ' · 설정 전체 ' || coalesce(r.prefs->>'all', '기본') || ' · 하루 전 ' || coalesce(r.prefs->>'remind1', '기본(켜짐)')
      || ' · 문구 「' || v_title || ' / ' || v_body || '」');
  end loop;
end $do$;

select 구분, 내용 from _vr order by seq;
