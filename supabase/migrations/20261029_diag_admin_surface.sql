-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 파트너(매장 어드민) 권한 정리 전, 라이브의 정책·권한·권한 표 모양 (2026-10-29)
--   공개 저장소라 Actions 로그도 공개다 — 정책 이름·조건식·건수만 찍는다. 사람 이름·매장 이름·uid 는 찍지 않는다.
--   A 주요 표의 RLS 정책 전부(이름 · 명령 · 역할 · USING/WITH CHECK 조건식)
--   B 권한 함수들의 라이브 본문 md5 (저장소 판과 같은지 대조용)
--   C admin_grants · restaurant_admins · venue_admins · partner_accounts 의 모양과 건수(사람·매장별이 아니라 합계)
--   D authenticated 가 실행할 수 있는 security definer 함수 목록(이름만)
--   E profiles 칸 목록
-- 아무것도 쓰지 않는다.
-- ═══════════════════════════════════════════════════════════════
create temp table _das(seq serial, 구분 text, 내용 text);

-- ── A 정책 ──
insert into _das(구분, 내용)
select 'A ' || tablename || ' · ' || policyname,
       cmd || ' · roles ' || array_to_string(roles, ',') || ' · USING ' || coalesce(left(qual, 400), '-')
       || case when with_check is not null then ' · CHECK ' || left(with_check, 300) else '' end
  from pg_policies
 where schemaname = 'public'
   and tablename in ('tickets','ticket_products','profiles','restaurants','reservation_invites','deposit_transactions','payment_orders',
                     'kashikiri_events','kashikiri_teams','kashikiri_charges','kashikiri_charge_admin','daegwan_manual','notifications',
                     'membership_fees','admin_grants','restaurant_admins','venue_admins','partner_accounts','venue_partners',
                     'reservation_requests','restaurant_visit_notes','billing_keys','app_config','invite_codes','push_subscriptions','active_sessions')
 order by tablename, policyname;

insert into _das(구분, 내용)
select 'A RLS 꺼진 표', coalesce(string_agg(c.relname, ' · ' order by c.relname), '없음')
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
   and c.relname in ('tickets','ticket_products','profiles','restaurants','reservation_invites','deposit_transactions','payment_orders',
                     'kashikiri_events','kashikiri_teams','kashikiri_charges','kashikiri_charge_admin','daegwan_manual','notifications',
                     'membership_fees','admin_grants','restaurant_admins','venue_admins','partner_accounts','venue_partners',
                     'reservation_requests','restaurant_visit_notes','billing_keys','app_config','invite_codes','push_subscriptions','active_sessions');

-- 표 권한(authenticated 에게 select/insert/update/delete 가 열려 있나 — RLS 와 별개로 grant 가 있어야 한다)
insert into _das(구분, 내용)
select 'A 표 권한 ' || table_name,
       'authenticated: ' || coalesce(string_agg(privilege_type, ',' order by privilege_type) filter (where grantee = 'authenticated'), '-')
       || ' · anon: ' || coalesce(string_agg(privilege_type, ',' order by privilege_type) filter (where grantee = 'anon'), '-')
  from information_schema.role_table_grants
 where table_schema = 'public'
   and table_name in ('tickets','ticket_products','profiles','restaurants','reservation_invites','deposit_transactions','payment_orders',
                      'kashikiri_charges','notifications','admin_grants','restaurant_admins','partner_accounts','reservation_requests','toss_payment_cache')
 group by table_name order by table_name;

-- ── B 권한 함수 md5 ──
insert into _das(구분, 내용)
select 'B 함수 ' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
       'md5 ' || md5(p.prosrc) || ' · definer ' || p.prosecdef || ' · authenticated 실행 ' || has_function_privilege('authenticated', p.oid, 'execute')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('is_restaurant_admin_of','is_ticket_admin_of','is_venue_admin_of','taam_is_rest_admin','_taam_uid_role','is_super_admin','_taam_uid_is_super',
                     'enforce_ticket_approval','taam_guard_ticket_insert','taam_guard_ticket_row','taam_partner_accounts','_taam_rest_note_ok','_taam_fee_caller_ok')
 order by p.proname;

-- ── C 권한 표 모양 ──
insert into _das(구분, 내용)
select 'C admin_grants 칸', string_agg(column_name || ':' || data_type, ' · ' order by ordinal_position)
  from information_schema.columns where table_schema = 'public' and table_name = 'admin_grants';
insert into _das(구분, 내용)
select 'C partner_accounts 칸', coalesce(string_agg(column_name || ':' || data_type, ' · ' order by ordinal_position), '표 없음')
  from information_schema.columns where table_schema = 'public' and table_name = 'partner_accounts';
do $do$
declare v text;
begin
  select 'admin_grants ' || (select count(*) from public.admin_grants) || '줄(rest ' || (select count(*) from public.admin_grants where rest_id is not null)
         || ' · venue ' || (select count(*) from public.admin_grants where venue_id is not null) || ' · 사람 ' || (select count(distinct user_id) from public.admin_grants) || ')'
         || ' · restaurant_admins ' || coalesce((select count(*)::text from public.restaurant_admins), '표 없음')
         || ' · venue_admins ' || coalesce((select count(*)::text from public.venue_admins), '표 없음')
         || ' · partner_accounts ' || coalesce((select count(*)::text from public.partner_accounts), '표 없음')
         || ' · restaurant_admins 에만 있는 (사람,매장) ' || coalesce((select count(*)::text from public.restaurant_admins ra
                where not exists (select 1 from public.admin_grants g where g.user_id = ra.user_id and g.rest_id = ra.restaurant_id::text)), '-')
    into v;
  insert into _das(구분, 내용) values ('C 건수', v);
  select string_agg(r || ' ' || n, ' · ') into v from (
    select coalesce(p.role, '(null)') r, count(*) n from public.admin_grants g join public.profiles p on p.id = g.user_id group by 1) z;
  insert into _das(구분, 내용) values ('C 권한 가진 사람의 profiles.role 분포', coalesce(v, '-'));
exception when others then insert into _das(구분, 내용) values ('C', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── D authenticated 가 실행 가능한 security definer 함수(이름만) ──
insert into _das(구분, 내용)
select 'D definer · authenticated 실행 가능', string_agg(p.proname, ' · ' order by p.proname)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute');

-- ── E profiles 칸 ──
insert into _das(구분, 내용)
select 'E profiles 칸', string_agg(column_name, ' · ' order by ordinal_position)
  from information_schema.columns where table_schema = 'public' and table_name = 'profiles';
insert into _das(구분, 내용)
select 'E tickets 칸', string_agg(column_name, ' · ' order by ordinal_position)
  from information_schema.columns where table_schema = 'public' and table_name = 'tickets';

select 구분, 내용 from _das order by seq;
