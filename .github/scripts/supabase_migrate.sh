#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# supabase_migrate.sh — supabase/migrations/2*.sql 중 안 돌린 파일을 순서대로 실행하고 public._taam_migrations 에 기록한다 (2026-10-19)
# ═══════════════════════════════════════════════════════════════
# 부르는 곳: .github/workflows/supabase.yml 의 ① SQL 잡. 로컬 검증: SUPABASE_DB_URL='postgresql:///t_wf?host=/tmp' GH_SHA=test bash .github/scripts/supabase_migrate.sh
# 상태는 stdout 의 마지막 줄 `state=ok|skipped|failed` (워크플로가 GITHUB_OUTPUT 으로 옮긴다).
# 규칙 (2026-10-18 적대 점검에서 고친 것):
#   · 기록이 0건인데 안 돌린 파일이 3개 이상이면 멈춘다 — sql/migrations_baseline_2026-10-18.sql 을 먼저 (기준선 가드)
#   · 파일 실행은 --single-transaction — 오류가 나면 통째로 되돌리고 기록하지 않는다(다음 푸시에 다시 시도)
#   · 확인 표에 ❌ 가 있으면 **실패로 끝내되 기록은 남긴다**(sha = check-failed:<커밋>) — 종전엔 기록을 안 남겨 같은 파일이 푸시마다 다시 돌고 뒤 파일·Edge 가 영영 막혔다
#   · 기록된 파일이 그 뒤 바뀌었으면(file_md5) 경고만 — 다시 돌리지 않는다. 바꿀 것이 있으면 새 파일로
#   · psql 은 배열로 인용(URI 에 특수문자) · -X(psqlrc 무시) · LC_ALL=C 정렬(edit.sql < edit2.sql)
set -euo pipefail
export LC_ALL=C
: "${GH_SHA:=local}"
if [ -z "${SUPABASE_DB_URL:-}" ]; then
  echo "::warning title=SQL 배포 건너뜀::SUPABASE_DB_URL 시크릿이 없다 — 마이그레이션은 Supabase SQL Editor 에서 직접 실행해야 한다"
  echo "state=skipped"; exit 0
fi
P=(psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -q)
"${P[@]}" -c "create table if not exists public._taam_migrations(
                name text primary key, applied_at timestamptz not null default now(), sha text);
              alter table public._taam_migrations add column if not exists file_md5 text;
              alter table public._taam_migrations enable row level security;
              revoke all on public._taam_migrations from anon, authenticated;"
declare -A REC=()
while IFS='|' read -r nm m; do [ -n "$nm" ] && REC["$nm"]="$m"; done < <("${P[@]}" -tA -F '|' -c "select name, coalesce(file_md5, '') from public._taam_migrations")
recorded=${#REC[@]}
files=$(ls supabase/migrations/2*.sql 2>/dev/null | sort || true)
pending=0; for f in $files; do n=$(basename "$f"); [ -n "${REC[$n]+x}" ] || pending=$((pending+1)); done
echo "기록 $recorded · 안 돌린 파일 $pending"
if [ "$recorded" = "0" ] && [ "$pending" -gt 2 ]; then
  echo "::error title=기준선 없음::_taam_migrations 가 비어 있는데 안 돌린 파일이 ${pending}개다 — 먼저 sql/migrations_baseline_2026-10-18.sql 을 SQL Editor 에서 실행해 이미 적용된 파일을 기록하라 (CLAUDE.md 「Supabase 도 main 이 곧 라이브다」)"
  echo "state=failed"; exit 1
fi
ran=0
for f in $files; do
  n=$(basename "$f"); md5=$(md5sum "$f" | cut -c1-32)
  if [ -n "${REC[$n]+x}" ]; then
    old=${REC[$n]}
    if [ -n "$old" ] && [ "$old" != "$md5" ]; then echo "::warning title=기록 뒤 수정됨::$n 은 기록된 뒤 내용이 바뀌었다 — 다시 돌리지 않는다. 바꿀 것이 있으면 새 파일로"; fi
    echo "· $n — 이미 적용"; continue
  fi
  echo "▶ $n 실행"
  if ! out=$(psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -f "$f" 2>&1); then
    echo "$out"
    echo "::error title=마이그레이션 실패::$n — 트랜잭션을 되돌렸다. 기록하지 않았으니 고쳐서 다시 푸시하면 다시 돈다"
    echo "state=failed"; exit 1
  fi
  echo "$out"
  if [[ $out == *'❌'* ]]; then
    "${P[@]}" -c "insert into public._taam_migrations(name, sha, file_md5) values ('$n', 'check-failed:$GH_SHA', '$md5')"
    echo "::error title=확인 표 ❌::$n 의 확인 표에 ❌ 가 있다 — SQL 은 적용됐고 기록도 남겼다(check-failed). 위 표를 보고 손으로 처리하라. 다음 푸시는 이 파일을 다시 돌리지 않는다"
    echo "state=failed"; exit 1
  fi
  "${P[@]}" -c "insert into public._taam_migrations(name, sha, file_md5) values ('$n', '$GH_SHA', '$md5')"
  ran=$((ran+1))
done
echo "✅ 새로 적용한 마이그레이션: $ran"
echo "state=ok"
