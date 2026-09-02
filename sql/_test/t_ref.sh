#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 추천권 — 서버가 정말 지키는지 (2026-09-02)
# ═══════════════════════════════════════════════════════════════
#   ① 연 2매를 **서버가** 세는가  ← 앱에서 세면 RPC 를 두 번 부르면 그만이다
#   ② 게스트는 발급 못 하는가
#   ③ 남의 추천권을 못 보는가
#   ④ 초대장이 추천인의 **성만** 주는가
#   ⑤ 신청에 코드가 붙으면 「썼다」로 넘어가는가
#   ⑥ 코드가 틀려도 **신청은 살아남는가** ← 오타로 신청이 사라지면 안 된다
#   ⑦ 만료·재사용이 막히는가
#
# 먼저: membership_apply.sql · membership_settings.sql · membership_referral.sql
# 실행: bash sql/_test/t_ref.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
M1=f0000000-0000-4000-8000-0000000000e1   # M 회원 (추천인)
M2=f0000000-0000-4000-8000-0000000000e2   # 다른 M 회원
G1=f0000000-0000-4000-8000-0000000000e3   # 게스트

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
AS(){ echo "set role authenticated; select set_config('taam.uid','$1',false);"; }

$P -c "grant usage on schema public to anon, authenticated;" >/dev/null 2>&1
$P -c "
insert into auth.users(id) values ('$M1'),('$M2'),('$G1') on conflict do nothing;
insert into public.profiles(id,role,display_name,membership_tier) values
 ('$M1','member','김추천','M'),('$M2','member','박다른','M'),('$G1','member','최게스트','A')
 on conflict (id) do update set membership_tier=excluded.membership_tier,
   display_name=excluded.display_name, role='member';
delete from public.membership_referrals where owner_id in ('$M1','$M2','$G1');
delete from public.membership_applications where phone in ('01044445555','01066667777','01088889999');
" >/dev/null 2>&1
$P -c "$(AS $SUP)
select public.taam_mship_settings_set('referral_per_year','2'::jsonb);
select public.taam_mship_settings_set('referral_days','14'::jsonb);
" >/dev/null 2>&1

echo "── ① 발급 ──"
C1=$($P -c "$(AS $M1) select (public.taam_ref_issue())->>'code';" | tail -1)
ok "코드 모양 TAAM-연도-4자" t \
   "$($P -c "select '$C1' ~ '^TAAM-[0-9]{4}-[0-9A-Z]{4}\$';" | tail -1)"
ok "14일 유효" 14 \
   "$($P -c "select ceil(extract(epoch from (expires_at-now()))/86400)::int
             from public.membership_referrals where code='$C1';" | tail -1)"
ok "남은 매수 1" 1 \
   "$($P -c "$(AS $M1) select (public.taam_ref_mine())->>'left';" | tail -1)"
C2=$($P -c "$(AS $M1) select (public.taam_ref_issue())->>'code';" | tail -1)
ok "두 장째도 발급" t "$($P -c "select '$C2' <> '$C1' and '$C2' <> '';" | tail -1)"

echo "── ② 연 2매를 서버가 센다 ── ⭐"
if $P -c "$(AS $M1) select public.taam_ref_issue();" >/dev/null 2>&1;
then echo "❌ 세 장째가 발급됐다"; FAIL=1; else echo "✅ 세 장째는 막힌다 ⭐"; fi
# 발급하고 버리기를 반복해 무한이 되면 안 된다 — 만료·미사용도 한 장으로 센다
$P -c "update public.membership_referrals set expires_at = now() - interval '1 day' where code='$C1';" >/dev/null
if $P -c "$(AS $M1) select public.taam_ref_issue();" >/dev/null 2>&1;
then echo "❌ 만료시키니 한 장이 더 나왔다 (버리고 다시 받기가 된다)"; FAIL=1;
else echo "✅ 만료돼도 한 장으로 센다 ⭐"; fi

echo "── ③ 게스트는 못 쓴다 ──"
if $P -c "$(AS $G1) select public.taam_ref_issue();" >/dev/null 2>&1;
then echo "❌ 게스트가 추천권을 발급했다"; FAIL=1; else echo "✅ 게스트는 발급 못 한다 ⭐"; fi

echo "── ④ 남의 추천권 ──"
ok "내 것은 두 장 보인다" 2 \
   "$($P -c "$(AS $M1) select jsonb_array_length((public.taam_ref_mine())->'items');" | tail -1)"
ok "남의 것은 안 보인다 ⭐" 0 \
   "$($P -c "$(AS $M2) select jsonb_array_length((public.taam_ref_mine())->'items');" | tail -1)"
ok "표를 직접 봐도 안 보인다 ⭐" 0 \
   "$($P -c "$(AS $M2) select count(*) from public.membership_referrals where owner_id='$M1';" | tail -1)"
if $P -c "set role anon; select count(*) from public.membership_referrals;" >/dev/null 2>&1;
then echo "❌ anon 이 추천권 표를 읽었다"; FAIL=1; else echo "✅ anon 은 표에 손도 못 댄다"; fi

echo "── ⑤ 초대장 ──"
ok "추천인의 성만 준다 ⭐" 김 \
   "$($P -c "set role anon; select (public.taam_ref_public('$C2'))->>'surname';" | tail -1)"
if $P -c "set role anon; select (public.taam_ref_public('$C2'))::text;" 2>/dev/null | grep -q "김추천";
then echo "❌ 초대장이 추천인 전체 이름을 줬다"; FAIL=1; else echo "✅ 전체 이름은 안 준다 ⭐"; fi
ok "열면 열었다고 남는다" opened \
   "$($P -c "select status from public.membership_referrals where code='$C2';" | tail -1)"
ok "소문자로 열어도 된다" 김 \
   "$($P -c "set role anon; select (public.taam_ref_public(lower('$C2')))->>'surname';" | tail -1)"
ok "없는 코드" false \
   "$($P -c "set role anon; select (public.taam_ref_public('TAAM-2026-ZZZZ'))->>'found';" | tail -1)"
ok "만료된 코드는 막힌다" expired \
   "$($P -c "set role anon; select (public.taam_ref_public('$C1'))->>'blocked';" | tail -1)"

echo "── ⑥ 신청에 코드가 붙으면 ──"
$P -c "$(AS $M1) select set_config('taam.uid','$M1',false);" >/dev/null 2>&1
A1=$($P -c "set role anon;
  select (public.taam_mship_apply('추천받은사람','010-4444-5555','{}'::jsonb,'ko','$C2','web'))->>'id';" | tail -1)
ok "신청이 만들어진다" t "$($P -c "select '$A1' <> '';" | tail -1)"
ok "추천권이 「썼다」로 ⭐" applied \
   "$($P -c "select status from public.membership_referrals where code='$C2';" | tail -1)"
ok "어느 신청인지 남는다" "$A1" \
   "$($P -c "select application_id from public.membership_referrals where code='$C2';" | tail -1)"
ok "신청에도 코드가 적힌다" "$C2" \
   "$($P -c "select referral_code from public.membership_applications where id='$A1';" | tail -1)"
ok "쓴 코드는 다시 못 연다" applied \
   "$($P -c "set role anon; select (public.taam_ref_public('$C2'))->>'blocked';" | tail -1)"

echo "── ⑦ 코드가 틀려도 신청은 산다 ── ⭐"
A2=$($P -c "set role anon;
  select (public.taam_mship_apply('오타낸사람','010-6666-7777','{}'::jsonb,'ko','TAAM-2026-XXXX','web'))->>'id';" | tail -1)
ok "오타여도 신청은 들어간다 ⭐" t "$($P -c "select '$A2' <> '';" | tail -1)"
ok "코드는 그대로 적어 둔다 (어드민이 본다)" TAAM-2026-XXXX \
   "$($P -c "select referral_code from public.membership_applications where id='$A2';" | tail -1)"

echo "── ⑧ 추천 없이도 신청된다 ──"
A3=$($P -c "set role anon;
  select (public.taam_mship_apply('그냥신청','010-8888-9999','{}'::jsonb))->>'id';" | tail -1)
ok "코드 없이 신청" t "$($P -c "select '$A3' <> '';" | tail -1)"
ok "코드 칸은 비어 있다" "" \
   "$($P -c "select coalesce(referral_code,'') from public.membership_applications where id='$A3';" | tail -1)"

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
