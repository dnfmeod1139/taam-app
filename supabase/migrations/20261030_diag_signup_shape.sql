-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용 · 2026-10-30): 가입 문지기 · 초대장 · 표시 이름 경로의 라이브 모양 — 건수·이름·md5 만(공개 로그 · 이메일·번호·이름·코드 없음)
-- ═══════════════════════════════════════════════════════════════
select '① 문지기 모드' as 항목, coalesce((select value->>'mode' from public.app_config where key = 'signup_guard'), '(없음)') as 결과
union all select '② auth.users 트리거', coalesce((select string_agg(t.tgname || '→' || p.proname, ' · ' order by t.tgname) from pg_trigger t join pg_proc p on p.oid = t.tgfoid where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal), '없음')
union all select '③ profiles 트리거', coalesce((select string_agg(t.tgname || '→' || p.proname, ' · ' order by t.tgname) from pg_trigger t join pg_proc p on p.oid = t.tgfoid where t.tgrelid = 'public.profiles'::regclass and not t.tgisinternal), '없음')
union all select '④ invite_codes 트리거', coalesce((select string_agg(t.tgname || '→' || p.proname, ' · ' order by t.tgname) from pg_trigger t join pg_proc p on p.oid = t.tgfoid where t.tgrelid = 'public.invite_codes'::regclass and not t.tgisinternal), '없음')
union all select '⑤ invite_codes 정책', coalesce((select string_agg(policyname || ' ' || cmd || ' ' || array_to_string(roles, ',') || ' · ' || left(coalesce(qual, '') || ' | ' || coalesce(with_check, ''), 160), ' ‖ ' order by policyname) from pg_policies where schemaname = 'public' and tablename = 'invite_codes'), '없음')
union all select '⑥ invite_codes 칸', (select string_agg(column_name || ':' || data_type, ', ' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'invite_codes')
union all select '⑦ 함수 md5(앞 12)', (select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ') ' || left(md5(p.prosrc), 12) || ' ' || length(p.prosrc), ' · ' order by p.proname)
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
          and p.proname in ('taam_guard_signup','taam_invited_tier','sync_profile_email_from_auth','handle_new_user','taam_guard_membership_tier','taam_guard_invite_code_row',
                            'taam_guest_attach_tickets','taam_invite_consume','taam_consume_my_invite','taam_invite_code_check','auto_promote_super_admin','_taam_text_bad','taam_guard_text_input'))
union all select '⑧ invite_codes 를 읽는 함수(이름)', (select string_agg(distinct p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosrc ilike '%invite_codes%')
union all select '⑨ 초대장 묶임(전체 · 미사용)', (select '번호만 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is not null and nullif(btrim(coalesce(invitee_email,'')),'') is null)
         || ' · 이메일만 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is null and nullif(btrim(coalesce(invitee_email,'')),'') is not null)
         || ' · 둘 다 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is not null and nullif(btrim(coalesce(invitee_email,'')),'') is not null)
         || ' · 둘 다 없음 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is null and nullif(btrim(coalesce(invitee_email,'')),'') is null)
         || ' / 미사용 ' || count(*) filter (where not coalesce(used, false)) || ' / 전체 ' || count(*) from public.invite_codes)
union all select '⑩ 미사용 초대장 묶임', (select '번호만 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is not null and nullif(btrim(coalesce(invitee_email,'')),'') is null)
         || ' · 이메일만 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is null and nullif(btrim(coalesce(invitee_email,'')),'') is not null)
         || ' · 둘 다 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is not null and nullif(btrim(coalesce(invitee_email,'')),'') is not null)
         || ' · 둘 다 없음 ' || count(*) filter (where nullif(btrim(coalesce(invitee_phone,'')),'') is null and nullif(btrim(coalesce(invitee_email,'')),'') is null)
         from public.invite_codes where not coalesce(used, false))
union all select '⑪ 문지기 판정(최근 90일)', coalesce((select string_agg(k || ' ' || n, ' · ' order by n desc) from (select verdict || ':' || reason || ':' || coalesce(nullif(provider,''),'?') as k, count(*) n from public.signup_guard_log where at > now() - interval '90 days' group by 1) s), '없음')
union all select '⑫ 계정 제공자 · 채널(전체)', coalesce((select string_agg(k || ' ' || n, ' · ' order by n desc) from (select coalesce(raw_app_meta_data->>'provider','?') || case when phone is not null and phone <> '' then '+번호' else '' end || case when email is not null and email <> '' then '+이메일' else '' end as k, count(*) n from auth.users group by 1) s), '없음')
union all select '⑬ 메타데이터 번호가 계정 번호와 다른 계정', (select count(*)::text from auth.users where nullif(raw_user_meta_data->>'phone','') is not null and public._taam_phone_key(raw_user_meta_data->>'phone') <> public._taam_phone_key(coalesce(phone,'')))
union all select '⑭ 메타데이터 키(이름만 · 건수)', coalesce((select string_agg(k || ' ' || n, ' · ' order by n desc) from (select jsonb_object_keys(raw_user_meta_data) k, count(*) n from auth.users group by 1) s), '없음')
union all select '⑮ 이름에 꺾쇠·javascript 가 든 profiles', (select count(*)::text from public.profiles where coalesce(display_name,'') ~ '[<>]' or coalesce(display_name,'') ilike '%javascript:%')
union all select '⑯ 초대장 used_by 칸 채움', (select 'used ' || count(*) filter (where coalesce(used,false)) || ' · used_by_uid 칸 있음=' || (exists (select 1 from information_schema.columns where table_schema='public' and table_name='invite_codes' and column_name='used_by_uid'))::text from public.invite_codes)
union all select '⑰ 로그인 회원이 invite_codes 를 읽는가(정보)', case when has_table_privilege('authenticated','public.invite_codes','select') then 'select 권한 있음' else '없음' end;
