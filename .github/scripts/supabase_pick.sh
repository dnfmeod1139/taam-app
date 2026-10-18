#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# supabase_pick.sh — 이번에 배포할 Edge Function 목록을 정한다 (2026-10-19)
# ═══════════════════════════════════════════════════════════════
# 입력(환경): WANT(functions 칸 · 'all' | '이름,이름' | 빈값) · EV(push|workflow_dispatch) · BEFORE(push 의 before SHA) · SHA(HEAD)
# 출력: stdout 마지막 줄 `list=<이름 공백 구분>` (빈 목록이면 `list=`)
# 규칙 (2026-10-18 적대 점검에서 고친 것):
#   · push 는 이번 푸시에 들어온 커밋 **전부**(before..sha)를 본다 — HEAD~1 만 보면 한 번에 여러 커밋이 올라올 때 앞 커밋의 함수 변경을 놓쳤다. before 를 모르면(첫 푸시·강제 푸시·수동 실행) HEAD~1
#   · _shared/ 가 바뀌면 전부가 아니라 **그걸 import 하는 함수만**
#   · config.toml 이 바뀌면 전부가 아니라 **구역([functions.X]) 내용이 달라진 함수만** — 머리말 주석만 고치면 아무것도 안 올라간다
#   · 함수 폴더에서는 .ts 가 바뀐 것만 — README·SETUP.md·sql 문서 수정은 배포가 아니다
#   · 종전 「전부 재배포」는 대시보드에서만 손본 함수를 저장소 옛 판으로 덮었다. 전부 올리려면 functions 칸에 all 을 적는다(대조 뒤에)
set -euo pipefail
export LC_ALL=C
: "${WANT:=}"; : "${EV:=workflow_dispatch}"; : "${BEFORE:=}"; : "${SHA:=HEAD}"
all=$(ls -d supabase/functions/*/ | xargs -n1 basename | grep -v '^_' | tr '\n' ' ')
sect(){ awk -v fn="$2" '/^\[functions\./{on=($0=="[functions." fn "]")} on' <<<"$1"; }
if [ "$WANT" = "all" ]; then
  list="$all"
elif [ -n "$WANT" ]; then
  list=$(echo "$WANT" | tr ',' ' ')
else
  from="HEAD~1"; to="HEAD"
  if [ "$EV" = "push" ] && [ -n "$BEFORE" ] && [ "$BEFORE" != "0000000000000000000000000000000000000000" ] && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then from="$BEFORE"; to="$SHA"; fi
  echo "비교 구간: $from..$to"
  changed=$(git diff --name-only "$from" "$to" -- supabase/functions supabase/config.toml || true)
  # 함수 폴더 안의 .ts 만 — README/SETUP.md/sql 같은 문서를 고쳤다고 그 함수를 다시 올리면 대시보드 판을 덮는다(적대 점검)
  list=$(echo "$changed" | sed -n 's#^supabase/functions/\([^_][^/]*\)/.*\.ts$#\1#p' | sort -u | tr '\n' ' ')
  if echo "$changed" | grep -q '^supabase/functions/_shared/'; then
    imp=$(grep -l "_shared/" supabase/functions/*/index.ts 2>/dev/null | sed 's#supabase/functions/\([^/]*\)/index.ts#\1#' | tr '\n' ' ')
    echo "_shared 변경 — import 하는 함수: ${imp:-(없음)}"; list="$list $imp"
  fi
  if echo "$changed" | grep -q '^supabase/config.toml$'; then
    oldcfg=$(git show "$from:supabase/config.toml" 2>/dev/null || true); newcfg=$(cat supabase/config.toml)
    cfg=""; for fn in $all; do [ "$(sect "$oldcfg" "$fn")" != "$(sect "$newcfg" "$fn")" ] && cfg="$cfg $fn"; done
    echo "config.toml 변경 — 구역이 달라진 함수: ${cfg:-(없음 · 머리말만 바뀜)}"; list="$list $cfg"
  fi
  list=$(echo $list | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' || true)
fi
echo "배포 대상: ${list:-(없음)}"
echo "list=$list"
