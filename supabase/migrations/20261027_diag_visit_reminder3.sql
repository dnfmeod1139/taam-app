-- ═══════════════════════════════════════════════════════════════
-- 진단 3 — 새 「예약 안내」 배포 뒤 확인 (2026-10-27) · 회원에게는 아무것도 안 간다
--   P 첫 테스트 푸시(request_id 120 · 새 send-push 배포 전에 나감)의 send-push 응답
--   Q 두 번째 테스트 — 새 send-push 를 지나게, 슈퍼어드민에게만 · [유의사항]·[안내말씀] 칸이 어떻게 보이는지 예시 글로
--   R 실제 경로 — 매일 11:00 크론이 부르는 것과 같이 Edge notify-visit-reminder 를 한 번 부른다(Vault 키 · 응답은 다음 진단에서).
--     오늘 보낼 리마인드는 없다(가장 가까운 방문 11-12 · 오늘 크론은 이미 돌았다 — 같은 티켓·일수는 한 번만) → made 0 · 응답 ver 로 새 판인지 본다
--   S 회원 설정(remind7/3/1 · 전체) — 운영 계정(admin·superadmin) 빼고 · 탈퇴 빼고. 진단 1·테스트 파일은 role='user' 로만 세어 0명이었다
-- 이름·전화·이메일은 찍지 않는다(공개 저장소 · Actions 로그 공개).
-- ═══════════════════════════════════════════════════════════════

create temp table _vr3(seq serial, 구분 text, 내용 text);

-- ── P 첫 테스트 푸시 응답 ──
do $do$
declare h record; j jsonb;
begin
  begin
    select * into h from net._http_response where id = 120;
    if not found then
      insert into _vr3(구분, 내용) values ('P 첫 테스트 푸시(120)', '⚠ 응답 줄이 없다');
    else
      begin j := h.content::jsonb; exception when others then j := null; end;
      insert into _vr3(구분, 내용) values ('P 첫 테스트 푸시(120)',
        'HTTP ' || coalesce(h.status_code::text, '-')
        || case when j is not null then ' · 시도 ' || coalesce(j->'summary'->>'attempted', '-') || ' · 성공 ' || coalesce(j->'summary'->>'ok', '-') || ' · 실패 ' || coalesce(j->'summary'->>'failed', '-')
                else ' · ' || left(coalesce(h.content, h.error_msg, ''), 160) end);
    end if;
  exception when others then insert into _vr3(구분, 내용) values ('P 첫 테스트 푸시(120)', '⚠ 못 읽음: ' || left(sqlerrm, 120)); end;
end $do$;

-- ── Q 두 번째 테스트 (새 send-push · 매장 문구 칸 예시) ──
do $do$
declare r record; v_i18n jsonb; v_res jsonb;
begin
  v_i18n := public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 5,
    jsonb_build_object('notice', '(예시) 매장이 적은 유의사항이 여기에 나갑니다.', 'message', '(예시) 매장이 적은 안내말씀이 여기에 나갑니다.',
                       'notice_en', '(Sample) Notes written by the restaurant appear here.', 'message_en', '(Sample) A message from the restaurant appears here.'));
  v_i18n := jsonb_build_object(
    'ko', jsonb_build_object('title', '[테스트 2] ' || (v_i18n->'ko'->>'title'), 'body', v_i18n->'ko'->>'body'),
    'en', jsonb_build_object('title', '[Test 2] ' || (v_i18n->'en'->>'title'), 'body', v_i18n->'en'->>'body'),
    'ja', jsonb_build_object('title', '[テスト 2] ' || (v_i18n->'ja'->>'title'), 'body', v_i18n->'ja'->>'body'));
  for r in select p.id from public.profiles p where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = '' loop
    insert into public.notifications(user_id, type, title, body, url, payload)
    values (r.id, 'visit_reminder', v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', '/', jsonb_build_object('kind', 'visit_reminder', 'test', true, 'days', 1, 'fmt', 'v2', 'i18n', v_i18n));
    begin
      v_res := public._taam_member_push(r.id, v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', '/', 'visit-reminder-test2-' || extract(epoch from now())::bigint, 'remind1', v_i18n);
    exception when others then v_res := jsonb_build_object('ok', false, 'reason', left(sqlerrm, 120)); end;
    insert into _vr3(구분, 내용) values ('Q 두 번째 테스트 · 슈퍼어드민 …' || right(r.id::text, 4),
      case when coalesce((v_res->>'ok')::boolean, false) then '요청함 request_id=' || (v_res->>'request_id') else '⚠ 못 보냄(' || coalesce(v_res->>'reason', '?') || ')' end);
  end loop;
  insert into _vr3(구분, 내용) values ('Q 문구 (KO)', (v_i18n->'ko'->>'title') || E'\n' || (v_i18n->'ko'->>'body'));
end $do$;

-- ── R 실제 경로: Edge notify-visit-reminder 한 번 ──
do $do$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name, '') = '' or coalesce(v_url, '') = '' then insert into _vr3(구분, 내용) values ('R Edge 호출', '⚠ app_config.restock_push 없음'); return; end if;
  v_url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/notify-visit-reminder');
  select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  if coalesce(v_jwt, '') = '' then insert into _vr3(구분, 내용) values ('R Edge 호출', '⚠ Vault 키 없음'); return; end if;
  select net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt), body := '{}'::jsonb) into v_req;
  insert into _vr3(구분, 내용) values ('R Edge 호출', '요청함 request_id=' || v_req || ' (응답 ver 는 다음 진단에서)');
exception when others then
  insert into _vr3(구분, 내용) values ('R Edge 호출', '⚠ ' || left(sqlerrm, 120));
end $do$;

-- ── S 회원 설정 (운영 계정·탈퇴 제외) ──
insert into _vr3(구분, 내용)
select 'S 회원 설정 (회원 ' || count(*) || '명 · role 별 ' || (select string_agg(coalesce(role, '없음') || ' ' || n, ' · ') from (select p2.role, count(*) n from public.profiles p2 group by p2.role order by 2 desc) z) || ')',
       '7일 전 켬 ' || count(*) filter (where (case when jsonb_typeof(np->'remind7') = 'boolean' then (np->>'remind7')::boolean end) is true)
       || ' · 3일 전 끔 ' || count(*) filter (where (case when jsonb_typeof(np->'remind3') = 'boolean' then (np->>'remind3')::boolean end) is false)
       || ' · 하루 전 끔 ' || count(*) filter (where (case when jsonb_typeof(np->'remind1') = 'boolean' then (np->>'remind1')::boolean end) is false)
       || ' · 알림 전체 끔 ' || count(*) filter (where (case when jsonb_typeof(np->'all') = 'boolean' then (np->>'all')::boolean end) is false)
       || ' · 나머지는 기본(3일 전·하루 전만)'
  from (select coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np from public.profiles p
         where coalesce(p.role, '') not in ('admin', 'superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = '') x;

select 구분, 내용 from _vr3 order by seq;
