#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 파트너 계정 — 서버가 정말 지키는지 (2026-09-03)
# ═══════════════════════════════════════════════════════════════
#   ① 슈퍼어드민만 목록을 보는가       ← 어느 매장에 뭘 발급했는지가 샌다
#   ② 남의 행을 못 읽는가              ← RLS
#   ③ 본인 행은 읽는가
#   ④ last_login 은 **본인 것만** 찍히는가 ← 남의 행을 못 찍어야 한다
#   ⑤ 건넴 표시·메모가 슈퍼어드민만인가
#   ⑥ 권한은 admin_grants 가 주는가    ← 경로를 둘로 늘리지 않았나
#
# 먼저: admin_grants.sql · partner_accounts.sql
# 실행: bash sql/_test/t_partner.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
PA=c1000000-0000-4000-8000-000000000p01   # 파트너 계정 A
PB=c1000000-0000-4000-8000-000000000p02   # 파트너 계정 B
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
# ⚠ uuid 에 'p' 는 못 쓴다. 짐작으로 만들면 여기서 깨진다.
PA=c1000000-0000-4000-8000-00000000ee01
PB=c1000000-0000-4000-8000-00000000ee02

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
SA="set role authenticated; select set_config('taam.uid','$SUP',false);"
AS(){ echo "set role authenticated; select set_config('taam.uid','$1',false);"; }

# ── 배우 ─────────────────────────────────────────────────────
$P -c "
insert into auth.users(id) values ('$PA'),('$PB') on conflict do nothing;
insert into public.profiles(id,role,display_name) values
 ('$PA','user','스시아라이'),('$PB','user','타카미츠')
 on conflict (id) do update set role='user';
insert into public.restaurants(id,name) values ('$RA','허용매장') on conflict (id) do nothing;
delete from public.partner_accounts where login_id in ('t-alpha','t-beta');
delete from public.admin_grants where user_id in ('$PA','$PB');
insert into public.partner_accounts(login_id,user_id,rest_id,label,issued_by) values
 ('t-alpha','$PA','$RA','허용매장','$SUP'),
 ('t-beta','$PB','$RA','허용매장','$SUP');
insert into public.admin_grants(user_id,rest_id,label,granted_by)
 values ('$PA','$RA','허용매장','$SUP');
" >/dev/null 2>&1

echo "── ① 목록은 슈퍼어드민만 ── ⭐"
ok "슈퍼어드민은 본다" 2 \
   "$($P -c "$SA select jsonb_array_length(public.taam_partner_accounts());" | tail -1)"
if $P -c "$(AS $PA) select public.taam_partner_accounts();" >/dev/null 2>&1;
then echo "❌ 파트너가 전체 목록을 봤다"; FAIL=1; else echo "✅ 파트너는 목록을 못 본다 ⭐"; fi

echo "── ② 권한이 붙었는지 같이 준다 ── ⭐"
# ⚠ 「로그인은 되는데 어드민이 아니다」가 가장 헷갈리는 고장이다.
ok "권한 있는 계정" true \
   "$($P -c "$SA select e->>'has_grant' from jsonb_array_elements(public.taam_partner_accounts()) e where e->>'login_id'='t-alpha';" | tail -1)"
ok "권한 없는 계정 ⭐" false \
   "$($P -c "$SA select e->>'has_grant' from jsonb_array_elements(public.taam_partner_accounts()) e where e->>'login_id'='t-beta';" | tail -1)"
# 매장명은 restaurants 에서 최신으로 — label 은 발급 시점 값이라 낡는다
$P -c "update public.restaurants set name='이름바뀐매장' where id='$RA';" >/dev/null 2>&1
ok "매장명은 최신을 준다 ⭐" 이름바뀐매장 \
   "$($P -c "$SA select e->>'label' from jsonb_array_elements(public.taam_partner_accounts()) e where e->>'login_id'='t-alpha';" | tail -1)"
$P -c "update public.restaurants set name='허용매장' where id='$RA';" >/dev/null 2>&1

echo "── ③ RLS — 남의 행은 못 읽는다 ── ⭐"
ok "본인 행은 읽는다" t-alpha \
   "$($P -c "$(AS $PA) select login_id from public.partner_accounts;" | tail -1)"
ok "한 줄만 보인다 ⭐" 1 \
   "$($P -c "$(AS $PA) select count(*) from public.partner_accounts;" | tail -1)"
# ⚠ 익명은 0행이 아니라 **거부**여야 한다. grant 자체를 안 줬다 —
#   RLS 만 믿으면 정책 하나 실수에 통째로 열린다.
if $P -c "set role anon; select count(*) from public.partner_accounts;" >/dev/null 2>&1;
then echo "❌ 익명이 장부를 읽었다"; FAIL=1; else echo "✅ 익명은 아예 거부된다 ⭐"; fi

echo "── ④ last_login 은 본인 것만 ── ⭐"
$P -c "$(AS $PA) select public.taam_partner_touch();" >/dev/null 2>&1
ok "내 행에 찍힌다" 1 \
   "$($P -c "select count(*) from public.partner_accounts where login_id='t-alpha' and last_login_at is not null;" | tail -1)"
# ⚠ login_id 를 인자로 받지 않는다 — 받으면 남의 행을 찍을 수 있다
ok "남의 행은 안 찍힌다 ⭐" 0 \
   "$($P -c "select count(*) from public.partner_accounts where login_id='t-beta' and last_login_at is not null;" | tail -1)"

echo "── ⑤ 건넴 표시·메모 ──"
ok "슈퍼어드민이 표시한다" true \
   "$($P -c "$SA select (public.taam_partner_mark_handed('t-alpha', true))->>'handed';" | tail -1)"
ok "표시가 남는다" 1 \
   "$($P -c "select count(*) from public.partner_accounts where login_id='t-alpha' and handed_at is not null;" | tail -1)"
ok "되돌린다" 0 \
   "$($P -c "$SA select public.taam_partner_mark_handed('t-alpha', false);
             select count(*) from public.partner_accounts where login_id='t-alpha' and handed_at is not null;" | tail -1)"
if $P -c "$(AS $PA) select public.taam_partner_mark_handed('t-beta', true);" >/dev/null 2>&1;
then echo "❌ 파트너가 남의 건넴표시를 바꿨다"; FAIL=1; else echo "✅ 표시는 슈퍼어드민만 ⭐"; fi
if $P -c "$(AS $PA) select public.taam_partner_memo('t-beta','아무거나');" >/dev/null 2>&1;
then echo "❌ 파트너가 메모를 바꿨다"; FAIL=1; else echo "✅ 메모도 슈퍼어드민만"; fi
ok "없는 아이디는 막힌다" 막힘 \
   "$(if $P -c "$SA select public.taam_partner_mark_handed('없는아이디', true);" >/dev/null 2>&1; then echo 통과; else echo 막힘; fi)"

echo "── ⑥ 파트너가 자기 권한을 못 만든다 ── ⭐"
# 로그인만으로 어드민이 되면 안 된다. admin_grants 를 스스로 못 넣어야 한다.
if $P -c "$(AS $PB) insert into public.admin_grants(user_id,rest_id) values ('$PB','$RA');" >/dev/null 2>&1;
then echo "❌ 스스로 어드민이 됐다"; FAIL=1; else echo "✅ 스스로 권한을 못 만든다 ⭐"; fi
# 장부를 직접 고쳐 남의 매장을 가리키게 하는 것도 막혀야 한다
if $P -c "$(AS $PA) update public.partner_accounts set rest_id='$RA', disabled=false where login_id='t-alpha';" 2>&1 | grep -q "UPDATE 1";
then echo "❌ 파트너가 자기 장부를 고쳤다"; FAIL=1; else echo "✅ 장부는 못 고친다 ⭐"; fi

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
