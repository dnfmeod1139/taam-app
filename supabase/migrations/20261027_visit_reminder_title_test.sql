-- ═══════════════════════════════════════════════════════════════
-- 테스트 발송 — 새 제목(「미토우 방문 3일 전입니다」 · 「내일은 미토우 방문일입니다」)을 슈퍼어드민에게만 2건 (2026-10-27)
--   20261027_visit_reminder_title.sql 바로 뒤(파일 이름 순서). 회원에게는 아무것도 안 간다. 고정 예시(미토우 2026-09-10 18:30 5인)만 — 공개 로그에 실제 예약을 안 찍는다.
--   응답(net._http_response)은 다음 진단에서 request_id 로 읽는다.
-- ═══════════════════════════════════════════════════════════════
create temp table _vrt3(seq serial, 구분 text, 내용 text);
do $do$
declare r record; v_i18n jsonb; v_res jsonb; d int;
begin
  if to_regprocedure('public._taam_visit_remind_msg(jsonb,date,text,integer,jsonb,integer)') is null then
    insert into _vrt3(구분, 내용) values ('테스트', '⚠ 6 인자 문구 함수가 없다 — 앞 파일 확인'); return;
  end if;
  foreach d in array array[3, 1] loop
    v_i18n := public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 5, null, d);
    v_i18n := jsonb_build_object(
      'ko', jsonb_build_object('title', '[테스트] ' || (v_i18n->'ko'->>'title'), 'body', v_i18n->'ko'->>'body'),
      'en', jsonb_build_object('title', '[Test] ' || (v_i18n->'en'->>'title'), 'body', v_i18n->'en'->>'body'),
      'ja', jsonb_build_object('title', '[テスト] ' || (v_i18n->'ja'->>'title'), 'body', v_i18n->'ja'->>'body'));
    for r in select p.id from public.profiles p where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = '' loop
      insert into public.notifications(user_id, type, title, body, url, payload)
      values (r.id, 'visit_reminder', v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', '/', jsonb_build_object('kind', 'visit_reminder', 'test', true, 'days', d, 'fmt', 'v2', 'i18n', v_i18n));
      begin
        v_res := public._taam_member_push(r.id, v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', '/', 'visit-reminder-title-test-' || d || '-' || extract(epoch from now())::bigint, 'remind' || d, v_i18n);
      exception when others then v_res := jsonb_build_object('ok', false, 'reason', left(sqlerrm, 120)); end;
      insert into _vrt3(구분, 내용) values (d || '일 전 테스트 · 슈퍼어드민 …' || right(r.id::text, 4),
        case when coalesce((v_res->>'ok')::boolean, false) then '요청함 request_id=' || (v_res->>'request_id') else '⚠ 못 보냄(' || coalesce(v_res->>'reason', '?') || ')' end);
    end loop;
    insert into _vrt3(구분, 내용) values (d || '일 전 문구 (KO / EN / JA 제목)', (v_i18n->'ko'->>'title') || ' / ' || (v_i18n->'en'->>'title') || ' / ' || (v_i18n->'ja'->>'title'));
  end loop;
end $do$;
insert into _vrt3(구분, 내용)
select '리마인드 함수', case when prosrc like '%VR_TITLE_20261027%' then '새 판(제목에 매장·일수) ✅' else '⚠ 제목 판이 아니다 — 앞 파일 ② 확인' end
  from pg_proc where oid = to_regproc('public.taam_visit_reminder_notify');
select 구분, 내용 from _vrt3 order by seq;
