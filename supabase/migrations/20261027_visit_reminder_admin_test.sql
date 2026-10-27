-- ═══════════════════════════════════════════════════════════════
-- 슈퍼어드민 전 일정 리마인드 — 테스트 발송 · 앞으로 받을 일정 · 실제 경로 한 번 (2026-10-27)
--   20261027_visit_reminder_admin.sql 바로 뒤(파일 이름 순서). 회원에게 새로 가는 것은 없다.
--   A 예시 푸시 1건(슈퍼어드민만 · 고정 예시 미토우 · [예약자] : 우댕)
--   B 앞으로 30일 슈퍼어드민이 받을 리마인드 — 날짜(11:00 KST)·며칠 전·일정 종류별 건수만(공개 로그 — 이름·매장 없음)
--   C 실제 경로 — 매일 11:00 크론과 같이 Edge notify-visit-reminder 를 한 번 부른다(Vault 키). 오늘 몫(내일·3일 뒤 일정)의 슈퍼어드민 리마인드가
--     지금 나간다 — 오늘 11:00 크론은 이 기능 전에 돌아 슈퍼어드민 몫이 없었다. 회원 몫은 이미 보냈으므로(같은 티켓·일수 한 번) 다시 안 간다.
--     응답은 다음 진단에서 request_id 로 읽는다.
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

-- ── B 앞으로 30일 — 슈퍼어드민이 받을 리마인드(건수만) ──
with sa as (
  select p.id, coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np from public.profiles p
   where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = '' limit 1
), ent as (
  select case when t.purchase_id like 'MAN-%' then '수동 예약' when t.purchase_id like 'KSK-%' then '정산' when t.purchase_id like 'LINK-%' then '결제 링크'
              when t.purchase_id like 'INV-%' then '초대' else '회원 구매' end as kind,
         public.taam_visit_date(t.reservation_date) as vd
    from public.tickets t left join public.profiles pu on pu.id = t.user_id
   where lower(coalesce(t.status, '')) in ('active', 'manual')
     and not (coalesce(to_jsonb(pu)->>'is_test', '') = 'true' and coalesce(t.purchase_id, '') !~ '^(KSK|LINK|MAN)-')
  union all
  select '수동 기록', m.ymd from public.daegwan_manual m
), f as (
  select e.kind, v.d, e.vd - v.d as fire
    from ent e cross join (values (7), (3), (1)) v(d) cross join sa
   where e.vd is not null
     and coalesce(case when jsonb_typeof(sa.np -> ('remind' || v.d)) = 'boolean' then (sa.np ->> ('remind' || v.d))::boolean end, v.d in (1, 3)) is true
     and e.vd - v.d between (now() at time zone 'Asia/Seoul')::date and (now() at time zone 'Asia/Seoul')::date + 30
), g as (
  select fire, d, count(*) as n, string_agg(distinct kind, '·') as kinds from f group by fire, d
)
insert into _vrat(구분, 내용)
select 'B ' || to_char(fire, 'MM-DD') || '(' || (array['일','월','화','수','목','금','토'])[extract(dow from fire)::int + 1] || ') 11:00',
       case d when 1 then '하루 전' else d || '일 전' end || ' · ' || n || '건 (' || kinds || ')'
  from (select * from g order by fire, d desc limit 20) z order by fire, d desc;

insert into _vrat(구분, 내용)
select 'B 설정', '슈퍼어드민 알림 설정 — 7일 전 ' || case when (np->>'remind7') = 'true' then '켬' else '끔(기본)' end
       || ' · 3일 전 ' || case when (np->>'remind3') = 'false' then '끔' else '켬' end
       || ' · 하루 전 ' || case when (np->>'remind1') = 'false' then '끔' else '켬' end
       || ' · 전체 ' || case when (np->>'all') = 'false' then '끔(푸시 안 감)' else '켬' end
  from (select coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np from public.profiles p
         where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = '' limit 1) x;

-- ── C 실제 경로 ──
do $do$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  if coalesce((select prosrc like '%VR_ADMIN_20261027%' from pg_proc where oid = to_regproc('public.taam_visit_reminder_notify')), false) is not true then
    insert into _vrat(구분, 내용) values ('C Edge 호출', '⚠ 리마인드 함수가 새 판이 아니라 부르지 않음 — 앞 파일 ② 확인'); return;
  end if;
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name, '') = '' or coalesce(v_url, '') = '' then insert into _vrat(구분, 내용) values ('C Edge 호출', '⚠ app_config.restock_push 없음'); return; end if;
  v_url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/notify-visit-reminder');
  select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  if coalesce(v_jwt, '') = '' then insert into _vrat(구분, 내용) values ('C Edge 호출', '⚠ Vault 키 없음'); return; end if;
  select net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt), body := '{}'::jsonb) into v_req;
  insert into _vrat(구분, 내용) values ('C Edge 호출', '요청함 request_id=' || v_req || ' (응답·보낸 건수는 다음 진단에서)');
exception when others then
  insert into _vrat(구분, 내용) values ('C Edge 호출', '⚠ ' || left(sqlerrm, 120));
end $do$;

select 구분, 내용 from _vrat order by seq;
