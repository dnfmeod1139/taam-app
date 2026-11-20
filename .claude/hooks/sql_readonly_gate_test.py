#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sql_readonly_gate.py 회귀 — 실행: python3 .claude/hooks/sql_readonly_gate_test.py"""
import json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, 'sql_readonly_gate.py')

def run(query, tool='mcp__Supabase__execute_sql'):
    p = subprocess.run([sys.executable, GATE], input=json.dumps({'tool_name': tool, 'tool_input': {'project_id': 'x', 'query': query}}),
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    if not p.stdout.strip():
        return False
    d = json.loads(p.stdout)
    return d['hookSpecificOutput']['permissionDecision'] == 'allow' and d['hookSpecificOutput']['hookEventName'] == 'PreToolUse'

ALLOW = [
 # 이 세션에서 실제로 떴던 모양
 "select pg_get_functiondef(p.oid) as def from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('taam_purchase_confirm_deposit')",
 "select p.proname, md5(p.prosrc), pg_get_function_identity_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'taam_%' order by 1;",
 "select tgname, pg_get_triggerdef(t.oid) from pg_trigger t where tgrelid = 'public.tickets'::regclass and not tgisinternal order by tgname",
 "select policyname, cmd, qual, with_check from pg_policies where schemaname='public' and tablename='ticket_access_lists'",
 "select string_agg(column_name||':'||data_type, ', ' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='restaurants'",
 "select name, left(sha, 12) from public._taam_migrations where name like '20261120%'",
 "select has_table_privilege('anon','public.profiles','select'), has_function_privilege('authenticated', 'public.taam_restock_kick()', 'execute')",
 "select p.proname, a.grantee::regrole::text, a.privilege_type from pg_proc p, lateral aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and p.prosecdef",
 "with f as (select p.oid, p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace) select f.proname, md5(pg_get_functiondef(f.oid)) from f order by 1",
 "select 'a' as k, (select count(*) from pg_trigger where tgrelid = 'public.tickets'::regclass)::text as v union all select 'b', to_regprocedure('public.taam_x(text)')::text",
 "select c.relname, c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r'",
 "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.ticket_products'::regclass -- 제약\n",
 "select proname from pg_proc where prosrc like '%update public.profiles%'",
 "select \"proname\" as \"이름\" from pg_proc limit 3",
 # 2026-11-20 넓힘: public 표·뷰 읽기도 통과
 "select count(*) from public.profiles",
 "select * from profiles limit 1",
 "select id, name_jp from public.restaurants",
 "select count(*) from tickets where status = 'hold'",
 "select p.proname, (select count(*) from deposit_transactions) from pg_proc p",
 "select * from pg_proc p, profiles x",
 "select * from pg_proc p join tickets t on true",
 "with profiles as (select 1) select * from (select * from profiles) a, tickets",
 "select * from (with profiles as (select 1) select * from profiles) a, profiles",
 "select left(p.prosrc, 1800) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname = 'taam_guard_repurchase'",
 "select status, count(*) from public.payment_orders where purpose = 'ticket_topup' group by 1",
]
ASK = [
 # 실제 표를 읽는 조회 — 계속 묻는다
 "select * from ((profiles p join tickets t on true))",
 "select * from pg_proc where exists (select 1 from auth.users)",
 "select * from storage.objects",
 "select * from net._http_response",
 "select * from public.pg_x",
 "select * from tickets t join auth.users u on u.id = t.user_id",
 "select taam_ticket_sold_slots('x') from tickets",
 "select * from auth.users",
 "select decrypted_secret from vault.decrypted_secrets",
 "select command from cron.job",
 "table profiles",
 "select (table profiles)",
 # 쓰기 · 여러 문장
 "update public.profiles set role = 'superadmin'",
 "select 1; delete from tickets",
 "with d as (delete from tickets returning *) select count(*) from d",
 "select * into x from pg_proc",
 "select * from pg_proc for update",
 "insert into public._taam_migrations(name) values ('x')",
 "create table x (a int)",
 "do $$ begin perform 1; end $$",
 "explain analyze select * from pg_proc",
 # 앱 함수 · 위험 함수 호출
 "select public.taam_member_until_sync(null, true)",
 "select taam_apply_deposit_delta('u', 1, 1)",
 "select taam_ticket_visible('x', 'y')",
 "select pg_sleep(10)",
 "select set_config('x','y',false)",
 "select current_setting('app.settings.jwt_secret')",
 "select pg_read_file('/etc/passwd')",
 "select query_to_xml('select * from profiles', true, false, '')",
 "select dblink('x','select 1')",
 "select nextval('x')",
 "select pg_terminate_backend(1)",
 "select lo_import('/etc/passwd')",
 # 읽지 않는 모양
 "select $$x$$",
 "select E'a\\'b' from pg_proc",
 "select 1 /* a /* b */ c */",
 "select * from pg_authid",
 "select * from pg_shadow",
 "select * from pg_stat_activity",
 "select * from pg_settings",
 "select * from information_schema.user_mapping_options",
 "select * from pg_catalog.pg_authid",
 "",
 "select 'unterminated",
]
bad = 0
for q in ALLOW:
    if not run(q): bad += 1; print('❌ 통과해야 하는데 묻는다:', q[:110])
for q in ASK:
    if run(q): bad += 1; print('❌ 물어야 하는데 통과:', q[:110])
if run(ALLOW[0], tool='Bash'): bad += 1; print('❌ 다른 도구에 반응')
if not run(ALLOW[0], tool='mcp__claude_ai_Supabase__execute_sql'): bad += 1; print('❌ 접두어가 다른 execute_sql 을 못 알아본다')
# 깨진 입력
p = subprocess.run([sys.executable, GATE], input='not json', capture_output=True, text=True)
if p.returncode != 0 or p.stdout.strip(): bad += 1; print('❌ 깨진 입력 처리')
print('통과 %d · 묻기 %d 건 확인 — ' % (len(ALLOW), len(ASK)) + ('전부 통과' if not bad else '실패 %d건' % bad))
sys.exit(1 if bad else 0)
