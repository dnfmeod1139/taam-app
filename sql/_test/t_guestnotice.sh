#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 게스트 만료 알림 — 누구에게 언제 (2026-09-03)
# ═══════════════════════════════════════════════════════════════
#   슈퍼어드민 — 5일 전부터 **매일** (5·4·3·2·1)
#   게스트 본인 — **3일 전 · 1일 전만**. 매일 보내면 재촉이 된다.
#
#   ① 5일 전부터 어드민에게 가는가 · 6일 전엔 안 가는가
#   ② 본인에게는 3·1일에만 가는가 ⭐
#   ③ 같은 날 두 번 돌려도 한 번만 가는가 ⭐
#   ④ 하루가 지나면 다시 가는가 (일수가 열쇠다)
#   ⑤ 구매하면 멈추는가 ⭐ 기한이 밀리므로 대상에서 빠진다
#   ⑥ 만료된 사람에게는 안 가는가
#
# 먼저: notifications.sql · guest_expiry_init.sql · guest_expiry_notice.sql
# 실행: bash sql/_test/t_guestnotice.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
G=e1000000-0000-4000-8000-00000000000

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
run(){ $P -c "select public.taam_guest_expiry_notify();" >/dev/null 2>&1; }
# 어드민에게 간 알림 수 (그 게스트 건)
adm(){ $P -c "select count(*) from public.notifications
              where type='guest_expiry_admin' and payload->>'guest_id'='$1';" | tail -1; }
# 본인에게 간 알림 수
self(){ $P -c "select count(*) from public.notifications
               where type='guest_expiry_self' and user_id='$1';" | tail -1; }
# 남은 일수를 원하는 값으로 세운다
setd(){ $P -c "update public.profiles
               set guest_expires_at = (now() at time zone 'Asia/Seoul')::date
                   + interval '$2 day' + interval '12 hour'
               where id='$1';" >/dev/null 2>&1; }

# ── 배우 ─────────────────────────────────────────────────────
$P -c "
insert into auth.users(id) values ('${G}1'),('${G}2'),('${G}3'),('${G}4') on conflict do nothing;
insert into public.restaurants(id,name) values ('$RA','매장') on conflict (id) do nothing;
delete from public.notifications where type like 'guest_expiry%';
delete from public.tickets where user_id in ('${G}1','${G}2','${G}3','${G}4');
insert into public.profiles(id,role,display_name,membership_tier) values
 ('${G}1','member','게스트하나','A'),('${G}2','member','게스트둘','A'),
 ('${G}3','member','게스트셋','A'),('${G}4','member','게스트넷','A')
 on conflict (id) do update set membership_tier='A', role='member';
-- ⚠ 기한을 전부 범위 밖(60일)으로 밀어 둔다. 앞 실행에서 남은 값이 있으면
--   지금 보려는 게스트 말고 **다른 게스트까지 같이 잡혀** 숫자가 어긋난다.
--   on conflict do update 는 guest_expires_at 을 안 건드리므로 여기서 민다.
update public.profiles set guest_expires_at = now() + interval '60 day'
 where id in ('${G}1','${G}2','${G}3','${G}4');
" >/dev/null 2>&1

echo "── ① 어드민 — 5일 전부터 ── ⭐"
setd ${G}1 6; run
ok "6일 전에는 안 간다 ⭐" 0 "$(adm ${G}1)"
setd ${G}1 5; run
ok "5일 전부터 간다 ⭐"    1 "$(adm ${G}1)"
setd ${G}1 4; run
ok "4일 전에도 간다"       2 "$(adm ${G}1)"
setd ${G}1 1; run
ok "1일 전까지 간다"       3 "$(adm ${G}1)"

echo "── ② 본인 — 3일·1일에만 ── ⭐"
setd ${G}2 5; run
ok "5일 전엔 본인에게 안 간다 ⭐" 0 "$(self ${G}2)"
setd ${G}2 4; run
ok "4일 전에도 안 간다"           0 "$(self ${G}2)"
setd ${G}2 3; run
ok "3일 전에 간다 ⭐"             1 "$(self ${G}2)"
setd ${G}2 2; run
ok "2일 전엔 안 간다 ⭐"          1 "$(self ${G}2)"
setd ${G}2 1; run
ok "1일 전에 간다 ⭐"             2 "$(self ${G}2)"

echo "── ③ 같은 날 두 번 돌려도 ── ⭐"
setd ${G}3 5; run; run; run
ok "어드민에게 한 번만 ⭐" 1 "$(adm ${G}3)"
setd ${G}3 3; run; run
ok "본인에게도 한 번만 ⭐" 1 "$(self ${G}3)"

echo "── ④ 날이 바뀌면 다시 ──"
# 일수가 열쇠라 4일이 되면 새로 나간다.
#   ⚠ 이 게스트는 ③ 에서 이미 5일·3일로 두 번 받았다 (남은 일수가 열쇠이므로
#     일수가 바뀔 때마다 새로 나간다). 그래서 여기서는 세 번째다.
setd ${G}3 4; run
ok "다음 날 다시 간다 ⭐" 3 "$(adm ${G}3)"

echo "── ⑤ 구매하면 멈춘다 ── ⭐"
setd ${G}4 2; run
ok "먼저 한 번 갔다" 1 "$(adm ${G}4)"
# 티켓을 사면 기한이 90일로 밀린다 → 대상에서 빠진다
$P -c "set role authenticated; select set_config('taam.uid','${G}4',false);
       insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,
              party_size,reservation_date)
       values('${G}4','$RA','GN-1','active',100000,1,'2027-06-06');" >/dev/null 2>&1
ok "기한이 90일로 밀렸다 ⭐" 90 \
   "$($P -c "select public.taam_guest_days_left(guest_expires_at) from public.profiles where id='${G}4';" | tail -1)"
run
ok "더는 안 간다 ⭐" 1 "$(adm ${G}4)"

echo "── ⑥ 만료된 사람 ──"
$P -c "update public.profiles set guest_expires_at = now() - interval '2 day' where id='${G}4';" >/dev/null 2>&1
B=$(adm ${G}4); run
ok "이미 만료면 안 간다 ⭐" "$B" "$(adm ${G}4)"

echo "── ⑦ 회원에게는 안 간다 ──"
$P -c "update public.profiles set membership_tier='M' where id='${G}1';" >/dev/null 2>&1
B=$(adm ${G}1); run
ok "M 회원은 대상이 아니다" "$B" "$(adm ${G}1)"

# ── 뒷정리 ──────────────────────────────────────────────────
#   ⚠ 남겨 두면 다른 테스트의 「전역 목록」 검사에 끼어든다. 테스트가
#     남긴 것이 다른 테스트를 깨뜨리면 원인을 엉뚱한 데서 찾게 된다.
$P -c "delete from public.notifications where user_id in ('${G}1','${G}2','${G}3','${G}4');
       delete from public.tickets where user_id in ('${G}1','${G}2','${G}3','${G}4');
       delete from public.profiles where id in ('${G}1','${G}2','${G}3','${G}4');" >/dev/null 2>&1

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
