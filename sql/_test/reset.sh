#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 로컬 검증판을 처음부터 다시 세운다 (2026-09-01)
# ═══════════════════════════════════════════════════════════════
# 왜 필요한가
#   테스트가 데이터를 바꾼다(방문 기록·등급·규칙). 그대로 다시 돌리면 앞 실행의
#   결과 위에서 판정하게 되고, 그러면 **통과도 실패도 못 믿는다.**
#   실제로 T1 의 visit_status 가 이미 'attended' 로 남아 있어서, 「회원이 직접
#   못 바꾼다」가 「같은 값으로 바꾸기」가 되어 가드가 안 걸린 적이 있다.
#
# 무엇을 세우나 — **저장소의 진짜 SQL 을 그대로 적용한다.**
#   ① fx_visit.sql            표·auth.uid() 흉내 (실측 타입)
#   ② sql/ticket_visit_record.sql   ← 라이브에 올린 그 파일
#   ③ fx_aud.sql              공개 대상이 기대는 표
#   ④ sql/ticket_audience.sql       ← 라이브에 올린 그 파일
#   ⑤ t_visit.sql             배우·티켓 데이터
#
# 쓰는 법:  bash sql/_test/reset.sh
# ═══════════════════════════════════════════════════════════════
set -e
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -v ON_ERROR_STOP=1"

$P -c "drop schema if exists public cascade; drop schema if exists auth cascade;" >/dev/null
$P -c "create schema public;" >/dev/null

step(){ printf '  %-34s' "$1"; if $P -f "$2" >/dev/null 2>/tmp/_rst.err; then echo "✅"; \
        else echo "❌"; head -3 /tmp/_rst.err; exit 1; fi; }

echo "── 로컬 검증판 재구축 ──"
step "① 표·auth 흉내"          sql/_test/fx_visit.sql
step "② 방문 기록 (실제 SQL)"   sql/ticket_visit_record.sql
step "③ 공개 대상 표"           sql/_test/fx_aud.sql
step "④ 공개 대상 (실제 SQL)"   sql/ticket_audience.sql
step "⑤ 배우·티켓 데이터"       sql/_test/t_visit.sql
echo "   준비 완료."
