#!/bin/bash
# Supabase 자동 배포 스크립트 회귀 — 2026-10-19. 먼저: 로컬 pg. 실행: bash sql/_test/t_workflow_scripts.sh
#   .github/scripts/supabase_migrate.sh(기준선 가드 · 실패 롤백 · ❌ 기록 · md5 경고 · 재실행) 와 supabase_pick.sh(구간 · _shared · config 구역)
cd "$(dirname "$0")/../.."
ROOT=$(pwd); DB=t_wf; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"; URL="postgresql:///$DB?host=/tmp&user=postgres"
FAIL=0; ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
# 임시 저장소 사본 — 마이그레이션 폴더만 (가짜 ❌ 파일을 더하기 위해)
W=$(mktemp -d); mkdir -p "$W/supabase/migrations"; cp supabase/migrations/2*.sql "$W/supabase/migrations/"; cd "$W"
MIG="bash $ROOT/.github/scripts/supabase_migrate.sh"
# ⓪ 시크릿 없음
out=$(env -u SUPABASE_DB_URL $MIG 2>&1; echo "rc=$?"); ok "시크릿 없음 → state=skipped · rc 0" "state=skipped|rc=0" "$(echo "$out" | grep -E '^state=|^rc=' | tr '\n' '|' | sed 's/|$//')"
# ① 기록 0 · 안 돌린 파일 35 → 기준선 가드
out=$(SUPABASE_DB_URL="$URL" GH_SHA=t1 $MIG 2>&1; echo "rc=$?"); ok "기록 0건 → 기준선 가드 ::error · state=failed · rc 1" "1|state=failed|rc=1" "$(echo "$out" | grep -c '::error title=기준선 없음')|$(echo "$out" | grep -E '^state=|^rc=' | tr '\n' '|' | sed 's/|$//')"
# ② 기준선 — 20261019_test_accounts.sql 만 빼고 전부 기록 → 그 파일이 돈다 · profiles 가 없어 실패 → 롤백 · 기록 없음
$P -c "insert into public._taam_migrations(name, sha) select regexp_replace(f, '^.*/', ''), 'baseline' from unnest(string_to_array('$(ls supabase/migrations/2*.sql | grep -v '20261019_test_accounts.sql$' | tr '\n' ',' | sed 's/,$//')', ',')) f" >/dev/null
out=$(SUPABASE_DB_URL="$URL" GH_SHA=t2 $MIG 2>&1; echo "rc=$?")
ok "안 돌린 파일 1개 실행 → 실패(표 없음) → 롤백 · 기록 없음 · state=failed" "1|0|state=failed|rc=1" "$(echo "$out" | grep -c '::error title=마이그레이션 실패')|$($P -c "select count(*) from public._taam_migrations where name='20261019_test_accounts.sql'")|$(echo "$out" | grep -E '^state=|^rc=' | tr '\n' '|' | sed 's/|$//')"
# ③ 표를 만들어 주면 성공 · md5 기록 · 두 번째는 「이미 적용」
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select null::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select true \$\$;
create table public.profiles(id uuid primary key default gen_random_uuid(), display_name text, phone text, email text, role text, deleted_at timestamptz, fee_exempt boolean not null default false, fee_exempt_note text, created_at timestamptz default now());
insert into public.profiles(display_name) values ('김우'), ('테스트1'), ('김우종은'), ('홍길동');
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if; if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
SQL
out=$(SUPABASE_DB_URL="$URL" GH_SHA=t3 $MIG 2>&1; echo "rc=$?")
ok "성공 → 기록(sha=커밋 · md5 32자) · ran 1 · state=ok" "t3|32|1|state=ok|rc=0" "$($P -c "select sha||'|'||length(file_md5) from public._taam_migrations where name='20261019_test_accounts.sql'")|$(echo "$out" | grep -c '✅ 새로 적용한 마이그레이션: 1')|$(echo "$out" | grep -E '^state=|^rc=' | tr '\n' '|' | sed 's/|$//')"
ok "시드가 실제로 돌았다(김우·테스트1 숨김 · 김우종은은 1명이라 숨김)" "3" "$($P -c "select count(*) from public.profiles where is_test")"
out=$(SUPABASE_DB_URL="$URL" GH_SHA=t4 $MIG 2>&1; echo "rc=$?"); ok "두 번째: 전부 「이미 적용」 · ran 0 · state=ok" "$(ls supabase/migrations/2*.sql | wc -l | tr -d ' ')|1|state=ok|rc=0" "$(echo "$out" | grep -c '이미 적용')|$(echo "$out" | grep -c '✅ 새로 적용한 마이그레이션: 0')|$(echo "$out" | grep -E '^state=|^rc=' | tr '\n' '|' | sed 's/|$//')"
# ④ 기록된 파일을 고치면 경고만 · 다시 안 돈다
echo "-- touched" >> supabase/migrations/20261019_test_accounts.sql
out=$(SUPABASE_DB_URL="$URL" GH_SHA=t5 $MIG 2>&1; echo "rc=$?"); ok "기록 뒤 수정 → ::warning 기록 뒤 수정됨 · 다시 안 돈다 · state=ok" "1|0|state=ok" "$(echo "$out" | grep -c '::warning title=기록 뒤 수정됨::20261019_test_accounts.sql')|$(echo "$out" | grep -c '▶ 20261019_test_accounts')|$(echo "$out" | grep -E '^state=' )"
# ⑤ 확인 표에 ❌ 가 있는 파일 → 적용·기록(check-failed) · 실패로 끝남 · 뒤 파일은 이번엔 안 돌고 다음엔 돈다
printf "select '❌ 일부러 틀린 확인' as 결과;\n" > supabase/migrations/20261098_zz_bad.sql
printf "select '✅ 뒤 파일' as 결과;\n" > supabase/migrations/20261099_zz_after.sql
out=$(SUPABASE_DB_URL="$URL" GH_SHA=t6 $MIG 2>&1; echo "rc=$?")
ok "❌ 파일: ::error 확인 표 ❌ · 기록 sha=check-failed:t6 · 뒤 파일은 이번에 안 돈다 · state=failed" "1|check-failed:t6|0|state=failed|rc=1" "$(echo "$out" | grep -c '::error title=확인 표 ❌')|$($P -c "select sha from public._taam_migrations where name='20261098_zz_bad.sql'")|$($P -c "select count(*) from public._taam_migrations where name='20261099_zz_after.sql'")|$(echo "$out" | grep -E '^state=|^rc=' | tr '\n' '|' | sed 's/|$//')"
out=$(SUPABASE_DB_URL="$URL" GH_SHA=t7 $MIG 2>&1; echo "rc=$?")
ok "다음 실행: ❌ 파일은 건너뛰고(wedge 없음) 뒤 파일이 돈다 · state=ok" "1|t7|state=ok|rc=0" "$(echo "$out" | grep -c '· 20261098_zz_bad.sql — 이미 적용')|$($P -c "select sha from public._taam_migrations where name='20261099_zz_after.sql'")|$(echo "$out" | grep -E '^state=|^rc=' | tr '\n' '|' | sed 's/|$//')"
# ⑥ 정렬 — LC_ALL=C 라 edit.sql 이 edit2.sql 보다 먼저
ok "정렬: manual_entry_edit.sql 이 edit2.sql 보다 먼저(LC_ALL=C)" "20261014_manual_entry_edit.sql|20261014_manual_entry_edit2.sql" "$(LC_ALL=C ls supabase/migrations/2*.sql | sort | grep manual_entry | xargs -n1 basename | tr '\n' '|' | sed 's/|$//')"
cd "$ROOT"; rm -rf "$W"
# ── pick ──
PICK="bash .github/scripts/supabase_pick.sh"
ok "pick: all → 23개(_shared 제외)" "23" "$(WANT=all $PICK | tail -1 | sed 's/^list=//' | wc -w | tr -d ' ')"
ok "pick: 이름 목록" "list=send-push taam-chat" "$(WANT='send-push,taam-chat' $PICK | tail -1)"
ok "pick: push 1d46027..7a78966 → notify-visit-reminder 만" "list=notify-visit-reminder " "$(EV=push BEFORE=1d46027 SHA=7a78966 $PICK | tail -1)"
ok "pick: push e85f6a5..63fc876(함수 변경 없음) → 없음" "list=" "$(EV=push BEFORE=e85f6a5 SHA=63fc876 $PICK | tail -1)"
ok "pick: before 가 0000(강제 푸시) → HEAD~1 로 폴백(오류 없음)" "0" "$(EV=push BEFORE=0000000000000000000000000000000000000000 SHA=HEAD $PICK >/dev/null 2>&1; echo $?)"
# 문서만 바뀐 함수 폴더는 배포 대상이 아니다 · index.ts 가 바뀌면 대상 — ⚠ 작업 트리를 건드리지 않게 **임시 워크트리**에서 커밋한다
WT=$(mktemp -d); git worktree add -q --detach "$WT" HEAD
( cd "$WT" && echo "x" >> supabase/functions/notify-purchase/SETUP.md && printf "\n// t\n" >> supabase/functions/toss-order/index.ts && git add -A && git -c user.email=t@t -c user.name=t commit -q -m tmp-pick-test )
ok "pick: SETUP.md 만 바뀐 notify-purchase 는 제외 · index.ts 가 바뀐 toss-order 만" "list=toss-order " "$(cd "$WT" && EV=push BEFORE=HEAD~1 SHA=HEAD bash "$ROOT/.github/scripts/supabase_pick.sh" | tail -1)"
git worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"
# config.toml — 구역 안의 주석·빈 줄만 바뀌면 대상이 아니다 · 값이 바뀐 구역만(2026-10-19 · 설명을 끼워 넣다 옆 구역 함수가 잡히던 것)
WT=$(mktemp -d); git worktree add -q --detach "$WT" HEAD
( cd "$WT" && python3 - <<'PY'
import re
p='supabase/config.toml'; s=open(p,encoding='utf-8').read()
s=s.replace('[functions.line-webhook]\nverify_jwt = false', '[functions.line-webhook]\n# 설명 한 줄\n\nverify_jwt = false', 1)
s=s.replace('[functions.verify-invite]\nverify_jwt = false', '[functions.verify-invite]\nverify_jwt = true', 1)
open(p,'w',encoding='utf-8').write(s)
PY
git add -A && git -c user.email=t@t -c user.name=t commit -q -m tmp-pick-cfg )
ok "pick: config 주석만 바뀐 line-webhook 은 제외 · 값이 바뀐 verify-invite 만" "list=verify-invite " "$(cd "$WT" && EV=push BEFORE=HEAD~1 SHA=HEAD bash "$ROOT/.github/scripts/supabase_pick.sh" | tail -1)"
git worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
