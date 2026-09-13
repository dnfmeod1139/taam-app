#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 파트너 증서 — id 만으로는 못 연다 (2026-09-13)
# ═══════════════════════════════════════════════════════════════
#   partner_agreement_get(p_id) 가 anon 에게 열려 있고 id 가 순번이라
#   ?cert=1,2,3… 으로 셰프 전원의 서명·협의 금액을 긁어갈 수 있었다.
#
#   ① 승인하면 토큰이 같이 온다 ⭐
#   ② id 만으로는 항상 거부 ⭐ (옛 링크·열거)
#   ③ 틀린 토큰은 거부 ⭐  ④ 맞는 토큰은 통과
#   ⑤ 기존 행에도 토큰이 채워진다 (백필)
# 실행: bash sql/_test/t_partner_cert.sh
# ═══════════════════════════════════════════════════════════════
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
j(){ python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('$1',''))"; }

$P -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>/tmp/_pc.err || { echo "❌ 픽스처"; head -3 /tmp/_pc.err; exit 1; }
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('taam.uid', true), '')::uuid $$;
create table public.profiles(id uuid primary key, role text);
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable as $$ select false $$;
-- 라이브 모양 그대로 (partner_qr.sql 의 표)
create table public.partner_agreements (
  id bigint generated always as identity primary key, code text, restaurant_name text, chef_name text,
  signer_name text not null, agreed_at timestamptz not null default now(), user_agent text,
  signature_data text, agreed_meal text, agreed_min text);
do $$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
         if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end $$;
grant usage on schema public, auth to anon, authenticated;
-- 이미 있던 계약 두 건 (백필 대상)
insert into public.partner_agreements(code,restaurant_name,chef_name,signer_name,signature_data,agreed_meal,agreed_min)
 values ('QHFF','스시 사사다','佐々田','사사다','data:image/png;base64,AAAA','¥38,000','¥5,000'),
        ('ABCD','카하라','かはら','카하라','data:image/png;base64,BBBB','¥42,000','¥8,000');
SQL
$P -v ON_ERROR_STOP=1 -f sql/partner_cert_token.sql >/dev/null 2>/tmp/_pc.err || { echo "❌ SQL 적용"; head -5 /tmp/_pc.err; exit 1; }

as_anon(){ $P -c "set role anon; $1" 2>&1 | tail -1; }

echo "── ⑤ 백필 ──"
ok "기존 행에 토큰이 채워졌다" 0 "$($P -c "select count(*) from public.partner_agreements where cert_token is null;" | tail -1)"
ok "토큰 길이 32" 32 "$($P -c "select min(length(cert_token)) from public.partner_agreements;" | tail -1)"

echo "── ① 승인 ── ⭐"
R=$(as_anon "select public.partner_agree('QHFF','슌지','春二','슌지',null,'data:image/png;base64,CCCC','¥6,000','¥30,000');")
ID=$(echo "$R" | j id); TOK=$(echo "$R" | j token)
ok "ok:true" "True" "$(echo "$R" | j ok)"
ok "토큰이 같이 온다 ⭐" 32 "${#TOK}"

echo "── ② id 만으로 ── ⭐"
ok "1인자 조회는 거부" "False" "$(as_anon "select public.partner_agreement_get($ID);" | j ok)"
ok "옛 행(1번)도 id 만으로는 거부 ⭐" "False" "$(as_anon "select public.partner_agreement_get(1);" | j ok)"

echo "── ③ 틀린 토큰 ── ⭐"
ok "틀린 토큰 거부" "False" "$(as_anon "select public.partner_agreement_get($ID, 'deadbeefdeadbeefdeadbeefdeadbeef');" | j ok)"
ok "빈 토큰 거부" "False" "$(as_anon "select public.partner_agreement_get($ID, '');" | j ok)"
# ⚠ anon 은 표를 못 읽으니 남의 토큰은 관리자로 먼저 꺼내 온다 (테스트 편의 — 실제 공격자는 이 값을 모른다)
OTHER=$($P -c "select cert_token from public.partner_agreements where id=1;" | tail -1)
ok "남의 토큰으로 내 id 거부" "False" "$(as_anon "select public.partner_agreement_get($ID, '$OTHER');" | j ok)"

echo "── ④ 맞는 토큰 ──"
R2=$(as_anon "select public.partner_agreement_get($ID, '$TOK');")
ok "통과" "True" "$(echo "$R2" | j ok)"
ok "서명이 온다" "data:image/png;base64,CCCC" "$(echo "$R2" | j signature_data)"
ok "협의 금액이 온다" "¥30,000" "$(echo "$R2" | j agreed_meal)"

echo; [ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
exit $FAIL
