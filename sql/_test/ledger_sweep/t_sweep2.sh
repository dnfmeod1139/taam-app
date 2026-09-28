#!/bin/bash
# 2차 공격 시드 (2026-09-28 저녁) — 가족별 기대가 다르다 (같은 접두사 B1 이 착시/도난 양쪽에 있음)
#   r2b   : 전부 착시 → ❌ 금지 (⚠ 허용)
#   r2x/r2j0 : B1·B1b·B2·B3·C1·D1·D2·E1 = 진짜 이동 → D ❌ 또는 (E2 ❌ + 상쇄) · BEN*/A1/F1/X1 = 착시(또는 판정 불가 쌍둥이) → ❌ 금지
#   r2z   : judge1 자기 공격 Z* = 진짜 이동 → 전부 D ❌
#   r2p   : 라이브 모양 — Super Admin(및 그 변형 B·C) = D ❌ · 유수봉·구자호·김우·이형주·홍길동·김우종 = ❌ 금지
#   r3    : 3차(병합본 이음새) — R2·R3 와 대조 R1c·R2c·R3c = D ❌ · R1 = ❌ 또는 판정 불가(정상 금지) · BN1·BN2·BN3·BN1c = ❌ 금지
# 실행: bash sql/_test/ledger_sweep/t_sweep2.sh [sweep.sql]
cd "$(dirname "$0")/../../.."
SQL="${1:-sql/diag_ledger_sweep_v4_2026-09-28.sql}"; S=sql/_test/ledger_sweep/seeds2
fam() {
  local fam="$1"; local db="rg2_$1"; shift
  psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $db" >/dev/null 2>&1
  psql -h /tmp -U postgres -d postgres -q -c "create database $db" >/dev/null 2>&1
  local P="psql -h /tmp -U postgres -d $db -q"
  $P -f sql/_test/fx_ledger.sql >/dev/null 2>&1; $P -f sql/_test/fx_ledger_close.sql >/dev/null 2>&1; $P -f sql/ledger_server_side.sql >/dev/null 2>&1
  $P -c "alter table public.profiles add column if not exists phone text, add column if not exists email text; create table if not exists public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_name text, reservation_date text, party_size int, price bigint, status text, purchase_id text, created_at timestamptz default now()); alter table public.profiles disable trigger all; alter table public.deposit_transactions disable trigger all;" >/dev/null 2>&1
  for f in "$@"; do $P -f "$f" >/dev/null 2>&1; done
  psql -h /tmp -U postgres -d $db -q -At -F'|' -f "$SQL" 2>&1 | awk -F'|' -v fam="$fam" '
    $1 ~ /^D·/ { d[$2]=$8 }  $1 ~ /^E2/ { k=($8 ~ /❌/)?"❌":"ⓘ"; e[$2]=e[$2] k $5 " " }  $1 ~ /^G·/ { g[$2]=$8 }
    $1 ~ /ERROR/ { print fam " ERROR " $0 }
    END { for (w in g) printf "%-5s %-30s D:%-30s E2:%-26s G:%s\n", fam, w, (w in d)?substr(d[w],1,30):"-", (w in e)?substr(e[w],1,26):"-", substr(g[w],1,34);
          for (w in d) if (!(w in g)) printf "%-5s %-30s D:%-30s E2:%-26s G:-\n", fam, w, substr(d[w],1,30), (w in e)?substr(e[w],1,26):"-" }' | sort
  psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $db" >/dev/null 2>&1
}
OUT=$( fam r2b $S/r2_benign.sql; fam r2x $S/r2_rules.sql $S/r2_rules_extra.sql; fam r2j0 $S/r2_j0_repro.sql; fam r2z $S/r2_j1_selfattack.sql; fam r2p $S/r2_prod.sql; fam r3 $S/r3_seams.sql $S/r3_controls.sql )
echo "$OUT"
echo "$OUT" | awk '
  { fam=$1; name=$2; line=$0; bad=0; benign=0;
    if (fam=="r2b") benign=1;
    if (fam=="r2x" || fam=="r2j0") { if (name ~ /^(B1|B1b|B1c|B2|B3|C1|D1|D2|E1)$/) bad=1; else benign=1 }
    if (fam=="r2z") bad=1;
    if (fam=="r2p") { if (name ~ /^(Super|B|C)$/ || line ~ /Super Admin/) bad=1; else benign=1 }
    if (fam=="r3")  { if (name ~ /^(R[0-9]c?)$/) bad=1; else benign=1 }
    if (bad && line !~ /D:(❌|⚠ 판정 불가)/ && !(line ~ /E2:.*❌/ && line ~ /상쇄/)) { print "❌ 놓침: " line; f=1 }
    if (benign && line ~ /❌/) { print "❌ 오탐: " line; f=1 } }
  END { if (!f) print "✅ 2차 회귀 통과"; exit f }'
