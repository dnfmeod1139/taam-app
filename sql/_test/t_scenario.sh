#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 공개 대상 — 실제로 쓸 시나리오로 검증 (2026-09-01)
# ═══════════════════════════════════════════════════════════════
# 앞의 t_aud.sh 는 함수 하나하나가 도는지를 본다. 이건 **운영자가 실제로 하는
# 일**을 그대로 따라가며, 화면에 뜰 숫자까지 맞는지 본다.
#
#   매장 A 에 「재방문 2회+ · 단골 5회+」 규칙을 건다
#   회원 넷: 0회 · 2회 · 5회 · (2회지만 이용 제한)
#   티켓에 「재방문 이상만」 공개 대상을 건다
#   → 대상은 2명이어야 한다 (2회·5회). 0회는 못 보고, 제한된 사람도 빠진다
#
# 그리고 사용자가 못 박은 규칙 — **취소·노쇼는 방문으로 안 센다.**
#
# 먼저:  bash sql/_test/reset.sh
# 실행:  bash sql/_test/t_scenario.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa      # 우리매장
RB=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb      # 남의매장
ADM=22222222-2222-2222-2222-222222222222     # 우리매장 어드민
OTH=33333333-3333-3333-3333-333333333333     # 남의매장 어드민
SUP=99999999-9999-9999-9999-999999999999
M0=c0000000-0000-4000-8000-00000000000a      # 방문 0회
M2=c0000000-0000-4000-8000-00000000000b      # 방문 2회
M5=c0000000-0000-4000-8000-00000000000c      # 방문 5회
MB=c0000000-0000-4000-8000-00000000000d      # 방문 2회 + 이용 제한

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
# 되나/막히나 만 본다 — 막히는 게 정상인 호출은 값이 아니라 예외로 판정해야 한다.
#   (종전엔 tail -1 이 set_config 결과(uid)를 집어 와 「값이 다르다」로 잘못 읽혔다)
rc(){ if $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" >/dev/null 2>&1;
      then echo OK; else echo FAIL; fi; }
asuper(){ $P -c "set role authenticated; select set_config('taam.uid','$SUP',false); $1" | tail -1; }
as(){ $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" | tail -1; }
FAIL=0

# ── 배우 세우기 ──────────────────────────────────────────────
$P -c "
insert into auth.users(id) values ('$M0'),('$M2'),('$M5'),('$MB') on conflict do nothing;
insert into public.profiles(id,role,display_name,membership_tier) values
 ('$M0','member','방문0','T'),('$M2','member','방문2','T'),
 ('$M5','member','방문5','T'),('$MB','member','제한된회원','T')
 on conflict (id) do update set membership_tier='T', role='member';
truncate public.member_bans;
delete from public.visit_tier_rules where restaurant_id <> '*';
delete from public.tickets where purchase_id like 'SC-%';
" >/dev/null

# 방문을 만든다. 지난 날짜 · 결제완료 · attended.
#   ⚠ postgres 로 넣는다 — 회원 세션이면 가드가 막는 것이 정상이고,
#     여기서 보고 싶은 건 「쌓인 방문이 어떻게 세어지나」다.
mkvisit(){ # uid, 몇 건, 상태
  for i in $(seq 1 $2); do
    $P -c "insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,
             reservation_date,visit_status)
           values('$1','$RA','SC-$1-$3-$i','active',100000,'2026-08-0$((i%9+1))','$3');" >/dev/null
  done
}
mkvisit $M2 2 attended
mkvisit $M5 5 attended
mkvisit $MB 2 attended

echo "── ① 방문 횟수가 제대로 세어지나 ──"
ok "방문 0회"  0 "$(as $ADM "select public.taam_visit_count('$M0','$RA');")"
ok "방문 2회"  2 "$(as $ADM "select public.taam_visit_count('$M2','$RA');")"
ok "방문 5회"  5 "$(as $ADM "select public.taam_visit_count('$M5','$RA');")"

echo "── ② 취소·노쇼는 방문이 아니다 (사용자 규칙) ──"
#   ⚠ 케이스마다 넣고 지운다. 한 회원에 쌓으면 앞 건이 다음 판정에 섞여,
#     실패 하나가 뒤따르는 둘까지 물들인다(처음에 그렇게 잘못 읽었다).
one(){ # 이름, status, visit_status, 매장
  $P -c "delete from public.tickets where purchase_id='SC-one';
         insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,
                reservation_date,visit_status)
         values('$M0','$4','SC-one','$2',100000,'2026-08-01','$3');" >/dev/null
  as $ADM "select public.taam_visit_count('$M0','$RA');"
}
ok "취소된 건은 안 센다"      0 "$(one cx  cancelled attended $RA)"
ok "노쇼는 안 센다"           0 "$(one ns  active    no_show  $RA)"
ok "남의 매장 방문도 안 센다" 0 "$(one oth active    attended $RB)"
ok "그 매장의 정상 방문은 센다" 1 "$(one ok  active    attended $RA)"
$P -c "delete from public.tickets where purchase_id='SC-one';" >/dev/null

echo "── ③ 매장 규칙: 재방문 2회+ · 단골 5회+ ──"
$P -c "insert into public.visit_tier_rules(restaurant_id,repeat_min,regular_min)
       values('$RA',2,5)
       on conflict (restaurant_id) do update set repeat_min=2, regular_min=5;" >/dev/null
ok "0회 → 첫방문"   first   "$(as $ADM "select public.taam_visit_tier('$M0','$RA');")"
ok "2회 → 재방문"   repeat  "$(as $ADM "select public.taam_visit_tier('$M2','$RA');")"
ok "5회 → 단골"     regular "$(as $ADM "select public.taam_visit_tier('$M5','$RA');")"

echo "── ④ 티켓에 「재방문 이상만」 을 건다 ──"
$P -c "
delete from public.ticket_products where id in ('SC_TK','SC_FIRST');
insert into public.ticket_products(id,rest_id,min_tier,audience) values
 ('SC_TK',   '$RA', null, '{\"mode\":\"conditions\",\"visit\":[\"repeat\",\"regular\"]}'::jsonb),
 ('SC_FIRST','$RA', null, '{\"mode\":\"conditions\",\"visit\":[\"first\"]}'::jsonb);
" >/dev/null
ok "0회 회원에게는 안 보인다" f "$(as $M0 "select public.taam_ticket_visible('SC_TK','$M0');")"
ok "2회 회원에게는 보인다"    t "$(as $M2 "select public.taam_ticket_visible('SC_TK','$M2');")"
ok "5회 회원에게도 보인다"    t "$(as $M5 "select public.taam_ticket_visible('SC_TK','$M5');")"
ok "첫방문 전용은 0회만"      t "$(as $M0 "select public.taam_ticket_visible('SC_FIRST','$M0');")"
ok "첫방문 전용은 5회에게 안 보인다" f "$(as $M5 "select public.taam_ticket_visible('SC_FIRST','$M5');")"

echo "── ⑤ 이용 제한은 조건보다 세다 ──"
ok "제한 걸기 전에는 보인다" t "$(as $MB "select public.taam_ticket_visible('SC_TK','$MB');")"
$P -c "insert into public.member_bans(user_id,reason) values('$MB','노쇼 3회');" >/dev/null
ok "제한된 회원은 조건에 맞아도 못 본다" f "$(as $MB "select public.taam_ticket_visible('SC_TK','$MB');")"

echo "── ⑥ 화면에 뜨는 「대상 인원수」 ──"
#   회원 넷 중 2회·5회 둘만. 제한된 회원은 빠지고 0회도 빠진다.
#   ⚠ 어드민·슈퍼어드민도 profiles 에 있다 — 어드민은 검수용으로 보이므로 같이 세어진다.
N=$(asuper "select public.taam_ticket_audience_count('SC_TK');")
echo "   대상 인원수 = $N (회원 중 대상 2명 + 검수 권한자)"
NM=$($P -c "select count(*) from public.profiles p
            where p.role='member' and public.taam_ticket_visible('SC_TK', p.id);" | tail -1)
ok "회원만 세면 정확히 2명" 2 "$NM"

echo "── ⑦ 파트너는 자기 매장만 ──"
ok "그 매장 어드민은 이 티켓을 관리한다"   t "$(as $ADM "select public.taam_can_manage_ticket_as('SC_TK','$ADM');")"
ok "남의 매장 어드민은 관리 못 한다"       f "$(as $OTH "select public.taam_can_manage_ticket_as('SC_TK','$OTH');")"
ok "남의 매장 어드민은 인원수도 못 본다"   FAIL "$(rc $OTH "select public.taam_ticket_audience_count('SC_TK');")"
ok "그 매장 어드민은 인원수를 본다"        OK   "$(rc $ADM "select public.taam_ticket_audience_count('SC_TK');")"

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
