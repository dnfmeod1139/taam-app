-- ═══════════════════════════════════════════════════════════════
-- 테스트 발송 — 새 「예약 안내」 문구를 슈퍼어드민에게만 1건 (2026-10-27)
--   20261027_visit_reminder_format.sql 바로 뒤에 돈다(파일 이름 순서). 회원에게는 아무것도 안 간다.
--   문구는 실제 리마인드와 같은 함수(_taam_visit_remind_msg)로 — 가장 가까운 다가오는 회원 예약의 매장·날짜·시각·인원·매장 문구를 빌린다
--   (이름·전화·이메일은 쓰지 않는다). 없으면 요청 예시(미토우 2026-09-10 18:30 5인).
--   푸시 결과(net._http_response)는 다음 진단 파일에서 request_id 로 읽는다.
-- ═══════════════════════════════════════════════════════════════

create temp table _vrt(seq serial, 구분 text, 내용 text);

do $do$
declare
  r record; s record; v_i18n jsonb; v_res jsonb; v_title text; v_body text;
begin
  if to_regproc('public._taam_visit_remind_msg') is null then
    insert into _vrt(구분, 내용) values ('테스트', '⚠ 문구 함수가 없다 — 앞 파일이 안 돌았다'); return;
  end if;
  -- 가장 가까운 다가오는 회원 예약 (리마인드와 같은 거름)
  select coalesce(nullif(btrim(t.restaurant_name), ''), '예약하신 매장') as rest_nm,
         coalesce(nullif(btrim(t.visit_time), ''), '') as vtime,
         public.taam_visit_date(t.reservation_date) as vd,
         greatest(coalesce(t.party_size, 1), 1) as pax,
         coalesce(nullif(btrim(t.restaurant_id::text), ''),
                  (select tp.rest_id::text from public.ticket_products tp where tp.id::text = t.ticket_product_id::text limit 1)) as rest_id
    into s
    from public.tickets t
   where t.user_id is not null and lower(coalesce(t.status, '')) = 'active'
     and coalesce(t.purchase_id, '') not like 'KSK-%' and coalesce(t.purchase_id, '') not like 'MAN-%'
     and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
     and public.taam_visit_days_left(t.reservation_date) >= 1
   order by public.taam_visit_days_left(t.reservation_date), t.visit_time
   limit 1;
  if s.vd is not null then
    select public._taam_visit_remind_msg(
             jsonb_build_object('ko', s.rest_nm, 'en', nullif(btrim(to_jsonb(x)->>'name_en'), ''), 'ja', nullif(btrim(to_jsonb(x)->>'name_jp'), '')),
             s.vd, s.vtime, s.pax, (select to_jsonb(n) from public.restaurant_visit_notes n where n.restaurant_id = s.rest_id))
      into v_i18n
      from (select 1) one left join public.restaurants x on x.id::text = s.rest_id;
  else
    v_i18n := public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 5, null);
  end if;
  -- 제목에만 [테스트] — 본문은 실제와 같다
  v_i18n := jsonb_build_object(
    'ko', jsonb_build_object('title', '[테스트] ' || (v_i18n->'ko'->>'title'), 'body', v_i18n->'ko'->>'body'),
    'en', jsonb_build_object('title', '[Test] ' || (v_i18n->'en'->>'title'), 'body', v_i18n->'en'->>'body'),
    'ja', jsonb_build_object('title', '[テスト] ' || (v_i18n->'ja'->>'title'), 'body', v_i18n->'ja'->>'body'));
  v_title := v_i18n->'ko'->>'title'; v_body := v_i18n->'ko'->>'body';
  for r in
    select p.id from public.profiles p
     where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = ''
  loop
    insert into public.notifications(user_id, type, title, body, url, payload)
    values (r.id, 'visit_reminder', v_title, v_body, '/', jsonb_build_object('kind', 'visit_reminder', 'test', true, 'days', 1, 'fmt', 'v2', 'i18n', v_i18n));
    begin
      v_res := public._taam_member_push(r.id, v_title, v_body, '/', 'visit-reminder-test-' || extract(epoch from now())::bigint, 'remind1', v_i18n);
    exception when others then v_res := jsonb_build_object('ok', false, 'reason', left(sqlerrm, 120)); end;
    insert into _vrt(구분, 내용) values ('테스트 발송 · 슈퍼어드민 …' || right(r.id::text, 4),
      '알림함 1줄 · 푸시 ' || case when coalesce((v_res->>'ok')::boolean, false) then '요청함 request_id=' || (v_res->>'request_id') else '⚠ 못 보냄(' || coalesce(v_res->>'reason', '?') || ')' end);
  end loop;
  insert into _vrt(구분, 내용) values ('문구 (KO)', v_title || E'\n' || v_body);
  insert into _vrt(구분, 내용) values ('문구 (EN)', (v_i18n->'en'->>'title') || E'\n' || (v_i18n->'en'->>'body'));
  insert into _vrt(구분, 내용) values ('문구 (JA)', (v_i18n->'ja'->>'title') || E'\n' || (v_i18n->'ja'->>'body'));
end $do$;

insert into _vrt(구분, 내용)
select '리마인드 함수', case when prosrc like '%VR_FMT_20261027%' then '새 판(예약 안내) ✅' else '⚠ 옛 판 그대로 — 앞 파일 ④ 확인' end || ' · md5 ' || md5(prosrc)
  from pg_proc where oid = to_regproc('public.taam_visit_reminder_notify');

select 구분, 내용 from _vrt order by seq;
