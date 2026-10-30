-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 + Edge 한 번 부름 · 2026-10-30): 패키지 결제 정리 크론이 실제로 도는지
--   크론 등록 · 정리 대상 수 · Vault 설정 · Edge toss-package-pay 의 sweep 을 서버 토큰(Vault service_role_key)으로 한 번 직접 부른다
--   (kick 은 대상이 없으면 Edge 를 안 부르므로 여기서 직접). 응답(HTTP 200 + {"ok":true,…})은 pg_net 이 비동기라 다음 진단이 읽는다.
--   대상이 0 이면 sweep 은 아무것도 바꾸지 않는다. 공개 로그 — 건수·상태만 찍는다(이름·금액 없음).
-- ═══════════════════════════════════════════════════════════════
create temp table if not exists _d(항목 text, 결과 text);
truncate _d;
do $do$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name, '') = '' or coalesce(v_url, '') = '' then insert into _d values ('sweep 직접 호출', '❌ app_config.restock_push 없음'); return; end if;
  begin select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1; exception when others then v_jwt := null; end;
  if coalesce(v_jwt, '') = '' then insert into _d values ('sweep 직접 호출', '❌ Vault 시크릿 없음'); return; end if;
  select net.http_post(url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/toss-package-pay'),
                       headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt),
                       body := jsonb_build_object('action', 'sweep'), timeout_milliseconds := 55000) into v_req;
  insert into _d values ('sweep 직접 호출', '✅ request ' || v_req || ' — 응답은 다음 진단(net._http_response)');
exception when others then insert into _d values ('sweep 직접 호출', '⚠ ' || left(sqlerrm, 160));
end $do$;

select 항목, 결과 from _d
union all select '크론 taam-package-reconcile(정보)',
       coalesce((select schedule || ' · ' || case when active then '켜짐' else '꺼짐' end from cron.job where jobname = 'taam-package-reconcile'), '⚠ 없음')
union all select '정리 대상 주문 수(정보)', jsonb_array_length(public.taam_package_reconcile_list(50))::text
union all select 'kick 결과(정보)', public.taam_package_reconcile_kick()::text
union all select '패키지 수(정보)', (select count(*) filter (where status = 'active') || ' 연계 · ' || count(*) filter (where status = 'unlinked') || ' 해제' from public.ticket_packages);
