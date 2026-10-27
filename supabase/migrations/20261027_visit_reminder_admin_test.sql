-- ═══════════════════════════════════════════════════════════════
-- 슈퍼어드민 전 일정 리마인드 — 테스트 발송 · 앞으로 받을 일정 · 실제 경로 한 번 (2026-10-27)
--   20261027_visit_reminder_admin.sql 바로 뒤(파일 이름 순서). 회원에게 새로 가는 것은 없다.
--   A 예시 푸시 1건(슈퍼어드민만 · 고정 예시 미토우 · [예약자] : 우댕)
--   B 앞으로 30일 슈퍼어드민이 받을 리마인드 — 며칠 전별 합계만(공개 로그 — 날짜·종류·이름·매장 없음: 수동 예약 날짜는 운영자 본인 일정이다)
--   C 오늘 몫 — 슈퍼어드민 몫만(_taam_visit_reminder_admin) 지금 만들고 줄마다 푸시한다(오늘 11:00 크론은 이 기능 전에 돌아 슈퍼어드민 몫이 없었다).
--     Edge(회원·손님 알림톡까지 도는 전체 실행)는 부르지 않는다 — 11시 전에 배포되면 회원·손님 리마인드를 앞당겨 보내게 된다(적대 리뷰).
--     만든 줄은 같은 일정·일수로 다시 안 가므로 11:00 크론과 겹치지 않는다. 응답은 다음 진단에서 request_id 로 읽는다.
-- ═══════════════════════════════════════════════════════════════
create temp table _vrat(seq serial, 구분 text, 내용 text);

-- ── A 예시 ──
do $do$
declare r record; v_i18n jsonb; v_res jsonb;
begin
  if to_regproc('public._taam_vr_add_who') is null then insert into _vrat(구분, 내용) values ('A 예시', '⚠ 함수가 없다 — 앞 파일 확인'); return; end if;
  v_i18n := public._taam_vr_add_who(public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 2, null, 1), '우댕');
  v_i18n := jsonb_build_object(
    'ko', jsonb_build_object('title', '[테스트] ' || (v_i18n->'ko'->>'title'), 'body', v_i18n->'ko'->>'body'),
    'en', jsonb_build_object('title', '[Test] ' || (v_i18n->'en'->>'title'), 'body', v_i18n->'en'->>'body'),
    'ja', jsonb_build_object('title', '[テスト] ' || (v_i18n->'ja'->>'title'), 'body', v_i18n->'ja'->>'body'));
  for r in select p.id from public.profiles p where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = '' loop
    insert into public.notifications(user_id, type, title, body, url, payload)
    values (r.id, 'visit_reminder', v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', '/',
            jsonb_build_object('kind', 'visit_reminder', 'test', true, 'admin', true, 'days', 1, 'fmt', 'v2', 'date', '2026-09-10', 'i18n', v_i18n));
    begin
      v_res := public._taam_member_push(r.id, v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', '/', 'visit-reminder-admin-test-' || extract(epoch from now())::bigint, 'remind1', v_i18n);
    exception when others then v_res := jsonb_build_object('ok', false, 'reason', left(sqlerrm, 120)); end;
    insert into _vrat(구분, 내용) values ('A 예시 푸시 · 슈퍼어드민 …' || right(r.id::text, 4),
      case when coalesce((v_res->>'ok')::boolean, false) then '요청함 request_id=' || (v_res->>'request_id') else '⚠ 못 보냄(' || coalesce(v_res->>'reason', '?') || ')' end);
  end loop;
  insert into _vrat(구분, 내용) values ('A 문구 (KO)', (v_i18n->'ko'->>'title') || E'\n' || (v_i18n->'ko'->>'body'));
end $do$;

-- ── B 앞으로 30일 — 슈퍼어드민이 받을 리마인드(며칠 전별 합계만) ──
with sa as (
  select p.id, coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np from public.profiles p
   where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = ''
), ent as (
  select public.taam_visit_date(t.reservation_date) as vd
    from public.tickets t left join public.profiles pu on pu.id = t.user_id
   where lower(coalesce(t.status, '')) in ('active', 'manual')
     and not (coalesce(to_jsonb(pu)->>'is_test', '') = 'true' and coalesce(t.purchase_id, '') !~ '^(KSK|LINK|MAN)-')
  union all
  select public.taam_visit_date(i.visit_date) from public.reservation_invites i left join public.profiles pi on pi.id = i.invitee_user_id
   where lower(coalesce(i.status, '')) = 'paid' and coalesce(to_jsonb(pi)->>'is_test', '') <> 'true'
     and not exists (select 1 from public.tickets t where lower(coalesce(t.status, '')) in ('active', 'manual')
                       and (t.extra_data->>'inviteId' = i.id::text or (t.extra_data->>'inviteId' is null and t.purchase_id like 'INV-' || left(i.id::text, 8) || '-%')))
  union all
  select m.ymd from public.daegwan_manual m
), f as (
  select v.d
    from ent e cross join (values (7), (3), (1)) v(d) cross join sa
   where e.vd is not null
     and coalesce(case when jsonb_typeof(sa.np -> ('remind' || v.d)) = 'boolean' then (sa.np ->> ('remind' || v.d))::boolean end, v.d in (1, 3)) is true
     and e.vd - v.d between (now() at time zone 'Asia/Seoul')::date and (now() at time zone 'Asia/Seoul')::date + 30
)
insert into _vrat(구분, 내용)
select 'B 앞으로 30일(슈퍼어드민 몫)', '하루 전 ' || count(*) filter (where d = 1) || '건 · 3일 전 ' || count(*) filter (where d = 3) || '건 · 7일 전 ' || count(*) filter (where d = 7)
       || '건 (본인이 회원으로 산 예약은 회원 리마인드로 따로 · 일정마다 한 건씩)'
  from f;

insert into _vrat(구분, 내용)
select 'B 설정', '슈퍼어드민 알림 설정 — 7일 전 ' || case when (np->>'remind7') = 'true' then '켬' else '끔(기본)' end
       || ' · 3일 전 ' || case when (np->>'remind3') = 'false' then '끔' else '켬' end
       || ' · 하루 전 ' || case when (np->>'remind1') = 'false' then '끔' else '켬' end
       || ' · 전체 ' || case when (np->>'all') = 'false' then '끔(푸시 안 감)' else '켬' end
  from (select coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np from public.profiles p
         where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = '' order by p.id limit 1) x;

-- ── C 오늘 몫(슈퍼어드민만) — 만들고 줄마다 푸시 ──
do $do$
declare v_adm jsonb; r jsonb; v_res jsonb; v_ok int := 0; v_fail int := 0; v_ids text := '';
begin
  if to_regproc('public._taam_visit_reminder_admin') is null then insert into _vrat(구분, 내용) values ('C 오늘 몫', '⚠ 함수가 없다 — 앞 파일 확인'); return; end if;
  v_adm := public._taam_visit_reminder_admin();
  for r in select * from jsonb_array_elements(coalesce(v_adm->'rows', '[]'::jsonb)) loop
    begin
      v_res := public._taam_member_push((r->>'user_id')::uuid, r->>'title', r->>'body', '/', 'visit-reminder-' || (r->>'ticket_id'), 'remind' || (r->>'days'), r->'i18n');
    exception when others then v_res := jsonb_build_object('ok', false, 'reason', left(sqlerrm, 120)); end;
    if coalesce((v_res->>'ok')::boolean, false) then v_ok := v_ok + 1; v_ids := v_ids || case when v_ids = '' then '' else ',' end || (v_res->>'request_id');
    else v_fail := v_fail + 1; end if;
  end loop;
  insert into _vrat(구분, 내용) values ('C 오늘 몫(슈퍼어드민만)',
    '만든 리마인드 ' || coalesce(v_adm->>'made', '0') || '건 · 푸시 요청 ' || v_ok || '건' || case when v_fail > 0 then ' · ⚠ 못 보냄 ' || v_fail else '' end
    || case when v_ids <> '' then ' · request_id=' || v_ids else '' end || case when coalesce((v_adm->>'skipped')::int, 0) > 0 then ' · 상한 넘침 ' || (v_adm->>'skipped') else '' end);
end $do$;

select 구분, 내용 from _vrat order by seq;
