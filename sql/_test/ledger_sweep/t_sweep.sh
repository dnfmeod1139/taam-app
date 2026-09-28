#!/bin/bash
# ═════════════════════════════════════════════════
# 원장 전수 대사 SQL 회귀 — 2026-09-28
#   공격 에이전트가 만든 시드(진짜 이동 · 착시 패턴 · 라이브 유수봉 · 슈퍼 테스트)를
#   가족별 새 DB 에 넣고 스윕을 돌려 회원별 D / E2 / G 를 한 줄씩 찍는다.
#   기대: 이름이 C*/X*/BY-*/S1/M1/T1/C1b/C3x 인 회원은 D 에 ❌ 또는 판정 불가,
#         FF-*/OK-*/B*/S2/S3/S4/유수봉 은 ❌ 가 한 줄도 없어야 한다.
# 먼저: 로컬 pg (psql -h /tmp -U postgres). 실행: bash sql/_test/ledger_sweep/t_sweep.sh [sweep.sql]
# ═════════════════════════════════════════════════
cd "$(dirname "$0")/../../.."
SQL="${1:-sql/diag_ledger_sweep_v4_2026-09-28.sql}"; SEEDS=sql/_test/ledger_sweep/seeds; FAIL=0
fam() {
  local fam="$1"; local db="rg_$1"; shift
  psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $db" >/dev/null 2>&1
  psql -h /tmp -U postgres -d postgres -q -c "create database $db" >/dev/null 2>&1
  local P="psql -h /tmp -U postgres -d $db -q"
  $P -f sql/_test/fx_ledger.sql >/dev/null 2>&1; $P -f sql/_test/fx_ledger_close.sql >/dev/null 2>&1; $P -f sql/ledger_server_side.sql >/dev/null 2>&1
  $P -c "alter table public.profiles add column if not exists phone text, add column if not exists email text; create table if not exists public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_name text, reservation_date text, party_size int, price bigint, status text, purchase_id text, created_at timestamptz default now()); alter table public.profiles disable trigger all; alter table public.deposit_transactions disable trigger all;" >/dev/null 2>&1
  for f in "$@"; do $P -f "$f" >/dev/null 2>&1; done
  psql -h /tmp -U postgres -d $db -q -At -F'|' -f "$SQL" 2>&1 | awk -F'|' -v fam="$fam" '
    $1 ~ /^D·/ { d[$2]=$8 }  $1 ~ /^E2/ { k=($8 ~ /❌/)?"❌":"ⓘ"; e[$2]=e[$2] k $5 " " }  $1 ~ /^G·/ { g[$2]=$8 }
    $1 ~ /ERROR/ { print fam " ERROR " $0 }
    END { for (w in g) printf "%-7s %-26s D:%-30s E2:%-28s G:%s\n", fam, w, (w in d)?substr(d[w],1,30):"-", (w in e)?substr(e[w],1,28):"-", substr(g[w],1,34);
          for (w in d) if (!(w in g)) printf "%-7s %-26s D:%-30s E2:%-28s G:-\n", fam, w, substr(d[w],1,30), (w in e)?substr(e[w],1,28):"-" }' | sort
  psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $db" >/dev/null 2>&1
}
OUT=$( fam cases $SEEDS/c*.sql $SEEDS/controls.sql; fam ff $SEEDS/ff_seed_*.sql; fam judgeb $SEEDS/judge_benign.sql; fam judgex $SEEDS/judge_bypass.sql $SEEDS/judge_extra.sql; fam live $SEEDS/live_yoo.sql; fam mine $SEEDS/mine_s1_s4.sql )
echo "$OUT"
# 판정: 진짜 이동 회원은 D 에 ❌ 또는 판정 불가 · 착시 회원은 ❌ 없음
echo "$OUT" | awk '
  { name=$2; line=$0; bad=(name ~ /^(C[0-9]|X[0-9]|BY-|S1|M1|T1|C3x|C1b)/); benign=(name ~ /^(FF-|OK-|B[0-9]|S2|S3|S4|유수봉)/);
    # 상쇄 쌍(C6 형)은 돈이 안 샜으므로 D 에 안 오르고 E2 ❌ 두 줄 + G 「상쇄」가 정답이다
    if (bad && line !~ /D:(❌|⚠ 판정 불가)/ && !(line ~ /E2:.*❌/ && line ~ /상쇄/)) { print "❌ 놓침: " line; f=1 }
    if (benign && line ~ /❌/) { print "❌ 오탐: " line; f=1 } }
  END { if (!f) print "✅ 회귀 통과 — 놓침·오탐 없음"; exit f }'
