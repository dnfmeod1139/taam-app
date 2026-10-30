-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용 · 2026-10-30): 가입·초대·프로필 동기화 함수의 라이브 본문 — 저장소 판과 md5 가 달라 그대로 읽는다.
-- 공개 로그라 이메일은 <e:md5앞6> · 8자리 이상 숫자는 <n> 으로 가린다(함수 본문에 비밀 값은 없다).
-- ═══════════════════════════════════════════════════════════════
with f as (
  select p.oid, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as fn,
         p.prosecdef as definer, p.provolatile as vol,
         regexp_replace(
           regexp_replace(p.prosrc, '([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})', '<e>', 'g'),
           '[0-9]{8,}', '<n>', 'g') as src,
         array(select (regexp_matches(p.prosrc, '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})', 'g'))[1]) as emails
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('taam_guard_signup','sync_profile_email_from_auth','sync_profile_contact_from_auth','handle_new_user',
                       'auto_promote_super_admin','consume_invite_by_self','user_has_invite_match','taam_guest_attach_on_profile',
                       'taam_guest_invite_on_paid','taam_guard_profile_role_ins','taam_guard_profile_role','is_superadmin','is_super_admin',
                       '_taam_uid_is_super','taam_guest_attach_on_invite_used')
), l as (
  select fn, 0 as n,
         '■ ' || case when definer then 'definer' else 'invoker' end || ' · ' || vol::text || ' · md5 ' || left(md5((select prosrc from pg_proc where oid = f.oid)), 12)
         || ' · 이메일 ' || coalesce((select string_agg(left(md5(lower(e)), 6), ',') from unnest(emails) e), '없음')
         || ' · 실행 권한 anon=' || has_function_privilege('anon', f.oid, 'execute')::text || ' authenticated=' || has_function_privilege('authenticated', f.oid, 'execute')::text as line
    from f
  union all
  select fn, t.n, t.line from f, regexp_split_to_table(src, E'\n') with ordinality as t(line, n)
)
select fn as 함수, n as 줄, line as 본문 from l
union all
select '(메타데이터를 읽는 함수)', 0, coalesce((select string_agg(p.proname || ' ' || left(md5(p.prosrc), 12), ' · ' order by p.proname)
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosrc ilike '%raw_user_meta_data%'), '없음')
union all
select '(invite_codes 를 읽는 함수 md5)', 0, coalesce((select string_agg(p.proname || ' ' || left(md5(p.prosrc), 12) || ' anon=' || has_function_privilege('anon', p.oid, 'execute')::text
         || ' auth=' || has_function_privilege('authenticated', p.oid, 'execute')::text, ' · ' order by p.proname)
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosrc ilike '%invite_codes%'), '없음')
union all
select '(auth 훅 설정)', 0, coalesce((select string_agg(k || '=' || v, ' · ') from (select name k, left(setting, 60) v from pg_settings where name ilike '%hook%') s), '없음')
order by 1, 2;
