#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 게스트는 「3개월 구매 없으면」 만료 (2026-09-03)
# ═══════════════════════════════════════════════════════════════
#   종전엔 구매와 무관한 고정 90일이었다. 몇 번을 사든 가입 90일이면 끝났다.
#
#   ① 게스트가 사면 기한이 다시 90일이 되는가 ⭐
#   ② 쌓이지 않는가 — 「살 때마다 90씩」이 아니라 「마지막 구매로부터 90」
#   ③ 취소된 건은 안 미는가 ⭐ 사고 취소해서 기한만 늘리는 길
#   ④ 회원(M·T)의 기한은 안 건드리는가
#   ⑤ 만료된 게스트가 스스로 살아나지 않는가 (연장은 어드민만)
#
# 먼저: membership_settings.sql · guest_expiry_on_purchase.sql
# 실행: bash sql/_test/t_guestrenew.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
GA=d1000000-0000-4000-8000-0000000000a1   # 게스트
GB=d1000000-0000-4000-8000-0000000000a2   # 만료된 게스트
UM=d1000000-0000-4000-8000-0000000000a3   # M 회원
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
# 기한이 「오늘부터 며칠 뒤」인지 (반올림)
days(){ $P -c "select round(extract(epoch from (guest_expires_at - now()))/86400)::int
               from public.profiles where id='$1';" | tail -1; }
buy(){ # uid, purchase_id, status
  $P -c "set role authenticated; select set_config('taam.uid','$1',false);
         insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,
                party_size,reservation_date)
         values('$1','$RA','$2','${3:-active}',100000,1,'2027-06-06');" >/dev/null 2>&1; }

$P -c "
insert into auth.users(id) values ('$GA'),('$GB'),('$UM') on conflict do nothing;
insert into public.restaurants(id,name) values ('$RA','허용매장') on conflict (id) do nothing;
delete from public.tickets where user_id in ('$GA','$GB','$UM');
insert into public.profiles(id,role,display_name,membership_tier,guest_expires_at) values
 ('$GA','member','게스트에이','A', now() + interval '10 day'),
 ('$GB','member','게스트비','A',  now() - interval '5 day'),
 ('$UM','member','엠회원','M',    null)
 on conflict (id) do update set membership_tier=excluded.membership_tier,
   guest_expires_at=excluded.guest_expires_at, role='member';
" >/dev/null 2>&1

echo "── ① 사면 기한이 다시 선다 ── ⭐"
ok "산 적 없으면 10일 남음" 10 "$(days $GA)"
buy $GA GR-1
ok "사면 90일로 다시 ⭐" 90 "$(days $GA)"

echo "── ② 쌓이지 않는다 ── ⭐"
# ⚠ 「살 때마다 90일씩 더하기」가 아니다. 그러면 몇 번 사고 몇 년을 버틴다.
buy $GA GR-2
ok "두 번 사도 90일 ⭐" 90 "$(days $GA)"
buy $GA GR-3
ok "세 번 사도 90일"     90 "$(days $GA)"

echo "── ③ 취소된 건은 안 민다 ── ⭐"
$P -c "update public.profiles set guest_expires_at = now() + interval '3 day' where id='$GA';" >/dev/null 2>&1
buy $GA GR-4 cancelled
ok "취소 건은 기한을 안 민다 ⭐" 3 "$(days $GA)"
# 초대 홀드도 구매가 아니다
buy $GA INVH-9 active
ok "초대 홀드도 아니다"          3 "$(days $GA)"

echo "── ④ 회원은 안 건드린다 ── ⭐"
buy $UM GR-5
ok "M 회원 기한은 비어 있다" "" "$(days $UM)"

echo "── ⑤ 만료된 게스트 ── ⭐"
# 만료되면 로그인이 막혀 살 수가 없다 — 그래서 스스로는 못 돌아온다.
ok "만료 상태 그대로" -5 "$(days $GB)"
# 되살리는 길은 어드민의 [+90일] 하나뿐이다
$P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
       select public.taam_guest_extend('$GB');" >/dev/null 2>&1
ok "어드민 연장으로만 살아난다 ⭐" 90 "$(days $GB)"
# 게스트가 자기 기한을 못 민다
if $P -c "set role authenticated; select set_config('taam.uid','$GA',false);
          update public.profiles set guest_expires_at = now() + interval '999 day' where id='$GA';" 2>&1 | grep -q "UPDATE 1";
then echo "❌ 게스트가 자기 기한을 늘렸다"; FAIL=1; else echo "✅ 자기 기한은 못 민다 ⭐"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$GA',false);
          select public.taam_guest_extend('$GA');" >/dev/null 2>&1;
then echo "❌ 게스트가 스스로 연장했다"; FAIL=1; else echo "✅ 연장은 어드민만 ⭐"; fi

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
