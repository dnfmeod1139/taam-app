#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Supabase execute_sql 승인 창 줄이기 — 「정의·구조만 읽는 조회」는 묻지 않고 통과시킨다. (2026-11-20)

왜: 작업 에이전트가 운영 DB 의 함수 정의·트리거·정책·권한을 읽을 때마다 승인 창이 떴다(하루 수십 번).
    그 조회들은 회원 자료에도 닿지 않고 아무것도 바꾸지 않는다.

무엇을 통과시키나 (전부 만족할 때만 「allow」):
  · 문장 하나 · select / with 로 시작
  · 쓰기·실행 계열 낱말이 없다 (insert/update/delete/… · into · returning · for update …)
  · FROM/JOIN 대상이 전부 시스템 카탈로그(pg_proc · pg_trigger · pg_policies · information_schema.* …)
    또는 마이그레이션 기록(public._taam_migrations)
  · 부르는 함수가 전부 아래 허용 목록(정의 읽기 · 글자 다루기 · 집계) 안에 있다

그 밖(회원·예약·원장 같은 실제 표를 읽는 조회 · 앱 함수를 부르는 조회 · 쓰기)은 **아무 결정도 내지 않는다**
 → 종전처럼 승인 창이 뜬다. 이 스크립트는 「allow」만 하고 「deny」는 하지 않는다.
모르는 모양이면 언제나 묻는 쪽으로 떨어진다(예외 · 파싱 실패 포함).

입력: 훅 stdin JSON {"tool_name": "...", "tool_input": {"project_id": "...", "query": "..."}}
출력: 통과면 PreToolUse permissionDecision "allow" JSON, 아니면 아무것도 안 찍고 0 으로 끝난다.
"""
import json
import re
import sys

# FROM / JOIN 에 올 수 있는 관계 — 구조·정의만 담긴 것
REL_OK = {
    'pg_proc', 'pg_namespace', 'pg_trigger', 'pg_class', 'pg_policies', 'pg_policy', 'pg_attribute',
    'pg_attrdef', 'pg_type', 'pg_constraint', 'pg_index', 'pg_indexes', 'pg_depend', 'pg_description',
    'pg_default_acl', 'pg_extension', 'pg_views', 'pg_tables', 'pg_matviews', 'pg_sequences',
    'pg_event_trigger', 'pg_rewrite', 'pg_rules', 'pg_operator', 'pg_language', 'pg_enum', 'pg_am',
    'pg_publication', 'pg_publication_tables', 'pg_roles', 'pg_auth_members', 'pg_inherits',
    'pg_collation', 'pg_cast', 'pg_aggregate', 'pg_opclass', 'pg_tablespace', 'pg_database',
    'public._taam_migrations', '_taam_migrations',
}
REL_OK |= {'pg_catalog.' + r for r in list(REL_OK) if r.startswith('pg_')}
# information_schema 는 구조 뷰만(외부 서버 옵션·사용자 매핑 같은 뷰는 뺀다)
REL_OK |= {'information_schema.' + v for v in (
    'columns', 'tables', 'views', 'routines', 'parameters', 'triggers', 'table_constraints', 'key_column_usage',
    'constraint_column_usage', 'constraint_table_usage', 'referential_constraints', 'check_constraints',
    'table_privileges', 'role_table_grants', 'column_privileges', 'role_column_grants', 'routine_privileges',
    'role_routine_grants', 'usage_privileges', 'role_usage_grants', 'schemata', 'sequences', 'domains',
    'enabled_roles', 'applicable_roles', 'element_types', 'attributes', 'view_table_usage', 'view_column_usage',
    'view_routine_usage', 'triggered_update_columns', 'column_udt_usage', 'domain_constraints')}

# FROM 자리에 올 수 있는 집합 반환 함수
SRF_OK = {'aclexplode', 'unnest', 'generate_series', 'generate_subscripts', 'regexp_split_to_table',
          'jsonb_array_elements', 'jsonb_array_elements_text', 'json_array_elements', 'json_array_elements_text',
          'jsonb_each', 'jsonb_each_text', 'jsonb_object_keys', 'string_to_table', 'pg_get_keywords',
          'pg_options_to_table', 'regexp_matches'}

# 부를 수 있는 함수 — 정의 읽기 · 권한 확인 · 글자/숫자/배열/JSON 다루기 · 집계 · 형 이름
FN_OK = SRF_OK | {
    'pg_get_functiondef', 'pg_get_function_identity_arguments', 'pg_get_function_arguments',
    'pg_get_function_result', 'pg_get_triggerdef', 'pg_get_expr', 'pg_get_constraintdef', 'pg_get_indexdef',
    'pg_get_viewdef', 'pg_get_ruledef', 'pg_get_userbyid', 'pg_get_serial_sequence', 'pg_function_is_visible',
    'pg_table_is_visible', 'pg_type_is_visible', 'pg_typeof', 'pg_encoding_to_char', 'pg_relation_is_publishable',
    'obj_description', 'col_description', 'shobj_description', 'format_type', 'oidvectortypes',
    'to_regproc', 'to_regprocedure', 'to_regclass', 'to_regtype', 'to_regnamespace', 'to_regrole', 'to_regoper',
    'has_function_privilege', 'has_table_privilege', 'has_schema_privilege', 'has_column_privilege',
    'has_any_column_privilege', 'has_sequence_privilege', 'has_type_privilege', 'has_database_privilege',
    'pg_has_role', 'row_security_active',
    'md5', 'length', 'char_length', 'octet_length', 'left', 'right', 'substr', 'substring', 'position', 'strpos',
    'replace', 'regexp_replace', 'regexp_match', 'regexp_count', 'regexp_like', 'translate', 'overlay',
    'lower', 'upper', 'initcap', 'trim', 'btrim', 'ltrim', 'rtrim', 'lpad', 'rpad', 'repeat', 'reverse',
    'split_part', 'starts_with', 'format', 'concat', 'concat_ws', 'quote_ident', 'quote_literal', 'quote_nullable',
    'chr', 'ascii', 'to_hex', 'encode', 'decode', 'convert_from', 'convert_to',
    'coalesce', 'nullif', 'greatest', 'least', 'abs', 'round', 'ceil', 'floor', 'trunc', 'mod', 'sign', 'power', 'sqrt',
    'count', 'sum', 'min', 'max', 'avg', 'bool_and', 'bool_or', 'every', 'string_agg', 'array_agg', 'json_agg',
    'jsonb_agg', 'json_object_agg', 'jsonb_object_agg', 'row_number', 'rank', 'dense_rank', 'lag', 'lead',
    'first_value', 'last_value', 'ntile',
    'array_to_string', 'string_to_array', 'array_length', 'array_position', 'array_remove', 'array_cat',
    'array_append', 'array_upper', 'array_lower', 'cardinality', 'array_dims',
    'json_build_object', 'jsonb_build_object', 'json_build_array', 'jsonb_build_array', 'to_json', 'to_jsonb',
    'row_to_json', 'jsonb_typeof', 'json_typeof', 'jsonb_pretty', 'jsonb_array_length', 'json_array_length',
    'jsonb_strip_nulls', 'jsonb_extract_path', 'jsonb_extract_path_text', 'jsonb_set',
    'now', 'version', 'to_char', 'to_timestamp', 'date_trunc', 'age', 'extract', 'date_part',
    'clock_timestamp', 'statement_timestamp', 'timezone', 'make_interval',
    'cast', 'row', 'array', 'exists', 'any', 'all', 'some', 'in', 'not', 'and', 'or', 'on', 'when', 'then', 'else',
    'case', 'where', 'select', 'from', 'join', 'as', 'over', 'filter', 'by', 'having', 'union', 'except', 'intersect',
    'values', 'using', 'like', 'ilike', 'between', 'is', 'distinct', 'within', 'group', 'order', 'limit', 'offset',
    'partition', 'lateral', 'with', 'recursive', 'left', 'right', 'inner', 'outer', 'cross', 'full', 'natural',
    'numeric', 'decimal', 'varchar', 'char', 'character', 'bit', 'varbit', 'time', 'timestamp', 'timestamptz',
    'interval', 'float', 'text', 'int', 'integer', 'bigint', 'smallint', 'boolean', 'bool',
}

# 한 번이라도 나오면 묻는다(문자열·주석을 가린 뒤 낱말 단위)
WORD_BAD = re.compile(
    r'\b(insert|update|delete|merge|truncate|drop|alter|create|grant|revoke|copy|call|do|set|reset|lock|vacuum|'
    r'analyze|analyse|refresh|reindex|cluster|comment|security|notify|listen|unlisten|prepare|execute|deallocate|'
    r'declare|fetch|move|begin|start|commit|rollback|savepoint|abort|end\s+transaction|into|returning|checkpoint|'
    r'discard|load|import|explain|show|table)\b')
FOR_LOCK = re.compile(r'\bfor\s+(update|share|no\s+key|key\s+share)\b')

IDENT = r'[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)?'
CLAUSE_END = {'where', 'group', 'order', 'limit', 'offset', 'having', 'window', 'union', 'except', 'intersect',
              'fetch', 'for', 'returning', 'on', 'using'}
JOIN_WORDS = {'join', 'inner', 'left', 'right', 'full', 'outer', 'cross', 'natural', 'lateral'}


def mask(sql):
    """주석을 지우고 문자열 리터럴·따옴표 이름을 자리표시로 바꾼다. 못 읽는 모양이면 None."""
    out = []
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        two = sql[i:i + 2]
        if two == '--':
            j = sql.find('\n', i)
            i = n if j < 0 else j
            out.append(' ')
        elif two == '/*':
            j = sql.find('*/', i + 2)
            if j < 0:
                return None
            if '/*' in sql[i + 2:j]:
                return None   # 중첩 주석 — 읽지 않는다
            i = j + 2
            out.append(' ')
        elif c == "'":
            # E'…' (역슬래시 이스케이프)는 읽지 않는다
            if out and out[-1] in ('e', 'E') and (len(out) < 2 or not (out[-2].isalnum() or out[-2] == '_')):
                return None
            j = i + 1
            while True:
                k = sql.find("'", j)
                if k < 0:
                    return None
                if sql[k:k + 2] == "''":
                    j = k + 2
                    continue
                break
            i = k + 1
            out.append(" 'S' ")
        elif c == '"':
            k = sql.find('"', i + 1)
            if k < 0:
                return None
            i = k + 1
            out.append(' qident ')
        elif c == '$':
            return None       # 달러 인용 · 매개변수 — 읽지 않는다
        elif c == '\\':
            return None
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def tokens(s):
    """낱말 · 기호 토큰. 'S'(가린 문자열)는 한 토큰."""
    return re.findall(r"'S'|::|" + IDENT + r"|[0-9]+(?:\.[0-9]+)?|[(),.;*=<>!+\-/|%~&\[\]:]", s)


def rel_ok(name, cte=()):
    return name in REL_OK or name in cte


def top_cte_names(tok):
    """문장 맨 앞 WITH 의 이름들 — 문장 전체에서 그 이름은 표가 아니라 이 CTE 를 가리킨다."""
    names = set()
    if not tok or tok[0] != 'with':
        return names
    i, n = 1, len(tok)
    if i < n and tok[i] == 'recursive':
        i += 1
    while i < n:
        if not re.fullmatch(r'[a-z_][a-z0-9_]*', tok[i]):
            return set()
        name = tok[i]
        i += 1
        if i < n and tok[i] == '(':            # 칸 이름 목록
            d = 0
            while i < n:
                if tok[i] == '(':
                    d += 1
                elif tok[i] == ')':
                    d -= 1
                    if d == 0:
                        i += 1
                        break
                i += 1
        if i >= n or tok[i] != 'as':
            return set()
        i += 1
        if i < n and tok[i] == 'not':
            i += 1
        if i < n and tok[i] == 'materialized':
            i += 1
        if i >= n or tok[i] != '(':
            return set()
        d = 0
        while i < n:
            if tok[i] == '(':
                d += 1
            elif tok[i] == ')':
                d -= 1
                if d == 0:
                    i += 1
                    break
            i += 1
        names.add(name)
        if i < n and tok[i] == ',':
            i += 1
            continue
        break
    return names


def from_items_ok(tok, cte=()):
    """모든 FROM 절(깊이 무관)의 대상이 허용된 관계·함수·부분질의인지 본다."""
    n = len(tok)
    for idx, t in enumerate(tok):
        if t != 'from':
            continue
        i = idx + 1
        expect_item = True
        depth = 0
        while i < n:
            x = tok[i]
            if depth == 0 and expect_item:
                while x == 'lateral' or x == 'only':
                    i += 1
                    if i >= n:
                        return False
                    x = tok[i]
                if x == '(':
                    # 부분질의 — 안쪽 from 은 바깥 for 가 따로 본다. (여러 겹 괄호 뒤의) 첫 낱말이 select/with/values 여야 한다.
                    #   `((profiles p join tickets t on true))` 같은 괄호 묶음 조인은 안쪽 표를 못 보니 통과시키지 않는다.
                    j = i
                    while j < n and tok[j] == '(':
                        j += 1
                    if j >= n or tok[j] not in ('select', 'with', 'values'):
                        return False
                    depth = 1
                    i += 1
                    expect_item = False
                    continue
                if not re.fullmatch(IDENT, x):
                    return False
                if i + 1 < n and tok[i + 1] == '(':
                    if x not in SRF_OK:
                        return False
                    depth = 1
                    i += 2
                    expect_item = False
                    continue
                if not rel_ok(x, cte):
                    return False
                expect_item = False
                i += 1
                continue
            if x == '(':
                depth += 1
            elif x == ')':
                if depth == 0:
                    break            # 이 FROM 을 감싼 괄호가 닫혔다
                depth -= 1
            elif depth == 0:
                if x == ',':
                    expect_item = True
                elif x == 'join':
                    expect_item = True
                elif x in CLAUSE_END and x not in ('on', 'using'):
                    break
                elif x == ';':
                    break
            i += 1
        if expect_item:
            return False             # from 뒤에 대상이 없다
    return True


def decide(query):
    if not isinstance(query, str) or not query.strip() or len(query) > 20000:
        return False
    m = mask(query)
    if m is None:
        return False
    s = m.lower().strip()
    # 문장 하나 — 끝의 ; 하나만 허용
    s = re.sub(r';\s*$', '', s)
    if ';' in s:
        return False
    if not re.match(r'(select|with)\b', s):
        return False
    if WORD_BAD.search(s) or FOR_LOCK.search(s):
        return False
    tok = tokens(s)
    if 'from' not in tok:
        # from 없는 select — 함수 호출만 있는 문장이다. 허용 함수뿐인지만 본다
        pass
    # 함수 호출: 낱말 바로 뒤가 '(' 인 것은 전부 허용 목록에 있어야 한다
    for i in range(len(tok) - 1):
        if tok[i + 1] == '(' and re.fullmatch(IDENT, tok[i]):
            name = tok[i]
            if name.startswith('pg_catalog.'):
                name = name[len('pg_catalog.'):]
            if name not in FN_OK:
                return False
    # 스키마를 붙인 이름은 카탈로그·정보 스키마·별칭뿐이어야 한다 — 자료 스키마 이름이 보이면 묻는다
    if re.search(r'\b(auth|storage|vault|cron|net|realtime|pgsodium|graphql|graphql_public|supabase_functions|'
                 r'supabase_migrations|extensions|pgbouncer|pg_temp|pg_toast)\s*\.', s):
        return False
    for mm in re.finditer(r'\bpublic\s*\.\s*([a-z_][a-z0-9_]*)', s):
        if mm.group(1) != '_taam_migrations':
            return False
    if not from_items_ok(tok, top_cte_names(tok)):
        return False
    return True


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    try:
        if not str(data.get('tool_name', '')).endswith('execute_sql'):
            return 0
        q = (data.get('tool_input') or {}).get('query')
        if decide(q):
            print(json.dumps({
                'hookSpecificOutput': {
                    'hookEventName': 'PreToolUse',
                    'permissionDecision': 'allow',
                    'permissionDecisionReason': '정의·구조만 읽는 조회(시스템 카탈로그) — 자동 통과',
                }
            }, ensure_ascii=False))
    except Exception:
        return 0
    return 0


if __name__ == '__main__':
    sys.exit(main())
