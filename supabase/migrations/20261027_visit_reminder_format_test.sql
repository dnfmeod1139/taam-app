-- ═══════════════════════════════════════════════════════════════
-- 테스트 발송 — 새 「예약 안내」 문구를 슈퍼어드민에게만 1건 + 며칠 전에 보내는지 점검 (2026-10-27)
--   20261027_visit_reminder_format.sql 바로 뒤에 돈다(파일 이름 순서). 회원에게는 아무것도 안 간다.
--   문구는 실제 리마인드와 같은 함수(_taam_visit_remind_msg) · 요청 예시(미토우 2026-09-10 18:30 5인) 그대로.
--   ⚠ 저장소가 공개라 Actions 로그도 공개다 — 실제 예약(매장·날짜·인원)을 빌려 찍지 않는다(적대 리뷰). 아래 점검은 날짜별 건수만.
--   푸시 결과(net._http_response)는 다음 진단 파일에서 request_id 로 읽는다.
-- ═══════════════════════════════════════════════════════════════

create temp table _vrt(seq serial, 구분 text, 내용 text);

do $do$
declare
  r record; v_i18n jsonb; v_res jsonb; v_title text; v_body text;
begin
  if to_regproc('public._taam_visit_remind_msg') is null then
    insert into _vrt(구분, 내용) values ('테스트', '⚠ 문구 함수가 없다 — 앞 파일이 안 돌았다'); return;
  end if;
  v_i18n := public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 5, null);
  -- 제목에만 [테스트] — 본문은 실제와 같은 모양
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

-- ── 며칠 전에 보내나 (읽기만 · 이름·전화 없음) ──
--   보내는 날 = 함수 본문의 d in (…) · 회원 설정(remind7/3/1 · 기본 3·1 켜짐 · 7 꺼짐 · all=false 는 send-push 가 전부 막음)
--   다가오는 발송 = 살아 있는 회원 예약마다 방문일 − 7/3/1 (KST 11:00 크론) — 설정으로 걸러 「보냄」과 「꺼져서 안 감」을 가른다
insert into _vrt(구분, 내용)
select '보내는 날(함수)',
       case when prosrc like '%d in (1, 3, 7)%' then '방문 7일 전 · 3일 전 · 하루 전 (매일 11:00 KST 크론이 그날 해당하는 예약을 보낸다)'
            else '⚠ 함수 본문에서 d in (1, 3, 7) 을 못 찾음 — 직접 확인' end
  from pg_proc where oid = to_regproc('public.taam_visit_reminder_notify');

insert into _vrt(구분, 내용)
select '회원 설정(일반 회원 ' || count(*) || '명)',
       '7일 전 켬 ' || count(*) filter (where (case when jsonb_typeof(np->'remind7') = 'boolean' then (np->>'remind7')::boolean end) is true)
       || ' · 3일 전 끔 ' || count(*) filter (where (case when jsonb_typeof(np->'remind3') = 'boolean' then (np->>'remind3')::boolean end) is false)
       || ' · 하루 전 끔 ' || count(*) filter (where (case when jsonb_typeof(np->'remind1') = 'boolean' then (np->>'remind1')::boolean end) is false)
       || ' · 알림 전체 끔 ' || count(*) filter (where (case when jsonb_typeof(np->'all') = 'boolean' then (np->>'all')::boolean end) is false)
       || ' (나머지는 기본: 3일 전·하루 전만)'
  from (select coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np from public.profiles p
         where coalesce(p.role, 'user') = 'user' and coalesce(to_jsonb(p)->>'deleted_at', '') = '') x;

with tk as (
  select t.id, public.taam_visit_date(t.reservation_date) as vd, coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np
    from public.tickets t join public.profiles p on p.id = t.user_id
   where t.user_id is not null and lower(coalesce(t.status, '')) = 'active'
     and coalesce(t.purchase_id, '') not like 'KSK-%' and coalesce(t.purchase_id, '') not like 'MAN-%'
     and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
     and not coalesce((t.extra_data ? 'kashikiri') or ((t.extra_data ? 'linkInvite') and nullif(t.extra_data->>'memberUid', '') is null) or (t.extra_data ? 'manualEntry'), false)
), f as (
  select tk.*, v.d, tk.vd - v.d as fire,
         coalesce(case when jsonb_typeof(tk.np->('remind' || v.d)) = 'boolean' then (tk.np->>('remind' || v.d))::boolean end, v.d in (1, 3)) is true
           and coalesce(case when jsonb_typeof(tk.np->'all') = 'boolean' then (tk.np->>'all')::boolean end, true) is true as will
    from tk cross join (values (7), (3), (1)) v(d)
   where tk.vd is not null
), g as (
  select fire, d, count(*) as n, count(*) filter (where will) as sent
    from f where fire >= (now() at time zone 'Asia/Seoul')::date
   group by fire, d
)
insert into _vrt(구분, 내용)
select '다가오는 발송 ' || to_char(fire, 'MM-DD') || '(' || (array['일','월','화','수','목','금','토'])[extract(dow from fire)::int + 1] || ') 11:00',
       d || '일 전 · 예약 ' || n || '건 · 보냄 ' || sent || '건' || case when n > sent then ' · 설정 꺼져서 안 감 ' || (n - sent) || '건' else '' end
  from (select * from g order by fire, d desc limit 15) z
 order by fire, d desc;

insert into _vrt(구분, 내용)
select '다가오는 발송 요약',
       '살아 있는 회원 예약 ' || count(distinct t.id) || '건 · 가장 가까운 방문 ' || coalesce(to_char(min(public.taam_visit_date(t.reservation_date)) filter (where public.taam_visit_date(t.reservation_date) >= (now() at time zone 'Asia/Seoul')::date), 'YYYY-MM-DD'), '-')
  from public.tickets t
 where t.user_id is not null and lower(coalesce(t.status, '')) = 'active'
   and coalesce(t.purchase_id, '') not like 'KSK-%' and coalesce(t.purchase_id, '') not like 'MAN-%'
   and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null);

select 구분, 내용 from _vrt order by seq;
