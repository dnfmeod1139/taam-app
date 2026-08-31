#!/bin/bash
P="psql -h /tmp -U postgres -d postgres -q -t -A"
MEM=11111111-1111-1111-1111-111111111111
ADM=22222222-2222-2222-2222-222222222222
OTH=33333333-3333-3333-3333-333333333333
SUP=99999999-9999-9999-9999-999999999999
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
RB=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

vis(){ $P -c "set role authenticated; select set_config('taam.uid','$2',false); select public.taam_ticket_visible('$1','$3');" | tail -1; }
chk(){ got=$(vis "$1" "$2" "$3"); if [ "$got" = "$4" ]; then echo "✅ $5"; else echo "❌ $5  (기대 $4, 실제 $got)"; fi; }

$P -c "
truncate public.ticket_products, public.ticket_access_lists, public.member_bans cascade;
delete from public.visit_tier_rules where restaurant_id <> '*';
update public.profiles set membership_tier='T' where id='$MEM';
insert into public.ticket_products(id,rest_id,min_tier,audience) values
 ('TP_ALL',   '$RA', null, null),
 ('TP_M',     '$RA', 'M',  null),
 ('TP_COND',  '$RA', null, '{\"mode\":\"conditions\",\"tiers\":[\"T\"],\"visit\":[\"repeat\",\"regular\"]}'::jsonb),
 ('TP_FIRST', '$RA', null, '{\"mode\":\"conditions\",\"visit\":[\"first\"]}'::jsonb),
 ('TP_OTHER', '$RB', null, null);
" >/dev/null

echo "── 기본 ──"
chk TP_ALL $MEM $MEM t "조건 없으면 회원에게 보인다"
chk TP_M   $MEM $MEM f "T 회원에게 M 전용은 안 보인다"
$P -c "update public.profiles set membership_tier='M' where id='$MEM';" >/dev/null
chk TP_M   $MEM $MEM t "M 으로 올리면 보인다"
$P -c "update public.profiles set membership_tier='T' where id='$MEM';" >/dev/null

echo "── 방문 조건 ──"
n=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_visit_count('$MEM','$RA');" | tail -1)
t=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_visit_tier('$MEM','$RA');" | tail -1)
echo "   현재 방문 $n 회 → 등급 $t"
chk TP_COND  $MEM $MEM t "재방문+ 조건에 맞으면 보인다"
chk TP_FIRST $MEM $MEM f "첫방문 전용은 안 보인다"
$P -c "insert into public.visit_tier_rules(restaurant_id,repeat_min,regular_min) values('$RA',5,9);" >/dev/null
t2=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_visit_tier('$MEM','$RA');" | tail -1)
echo "   이 매장 기준을 재방문 5회+ 로 올림 → 등급 $t2"
chk TP_COND  $MEM $MEM f "매장 기준을 올리니 재방문+ 에서 빠진다"
chk TP_FIRST $MEM $MEM t "대신 첫방문 전용이 보인다"
$P -c "delete from public.visit_tier_rules where restaurant_id='$RA';" >/dev/null

echo "── 이용 제한 ──"
$P -c "insert into public.member_bans(user_id,reason) values('$MEM','노쇼 3회');" >/dev/null
chk TP_ALL $MEM $MEM f "제한된 회원은 조건 없는 티켓도 못 본다"
$P -c "update public.member_bans set until = (now() - interval '1 day')::date where user_id='$MEM';" >/dev/null
chk TP_ALL $MEM $MEM t "기한이 지난 제한은 자동 해제된다"
$P -c "delete from public.member_bans;" >/dev/null

echo "── 명단 ──"
$P -c "insert into public.ticket_access_lists(ticket_id,user_id,access_type) values('TP_ALL','$MEM','block');" >/dev/null
chk TP_ALL $MEM $MEM f "티켓 차단 명단에 있으면 안 보인다"
$P -c "delete from public.ticket_access_lists;" >/dev/null
$P -c "insert into public.ticket_access_lists(ticket_id,user_id,access_type) values('TP_ALL','$SUP','allow');" >/dev/null
chk TP_ALL $MEM $MEM f "전용 명단이 있으면 명단 밖은 안 보인다"
$P -c "insert into public.ticket_access_lists(ticket_id,user_id,access_type) values('TP_ALL','$MEM','allow');" >/dev/null
chk TP_ALL $MEM $MEM t "명단에 넣으면 보인다"
$P -c "delete from public.ticket_access_lists;" >/dev/null

echo "── 관리 권한 (구멍 확인) ──"
chk TP_M $ADM $ADM t "그 매장 어드민은 M 전용도 본다 (검수)"
r=$($P -c "set role authenticated; select set_config('taam.uid','$OTH',false); select public.can_manage_ticket_access('TP_ALL');" | tail -1)
[ "$r" = "f" ] && echo "✅ 남의 매장 어드민은 명단 관리 못 한다" || echo "❌ 남의 매장 어드민이 여전히 관리 가능 ($r)"
r2=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.can_manage_ticket_access('TP_OTHER');" | tail -1)
[ "$r2" = "f" ] && echo "✅ 자기 매장 밖 티켓은 관리 못 한다" || echo "❌ 자기 매장 밖도 관리 가능 ($r2)"

echo "── 인원수 ──"
c=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_ticket_audience_count('TP_ALL');" | tail -1)
echo "   TP_ALL 을 볼 수 있는 회원 수 = $c (슈퍼어드민 제외, 어드민 3명 포함)"
cf=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_ticket_audience_count('TP_M');" | tail -1)
echo "   TP_M (M 전용) = $cf"
[ "$c" -gt "$cf" ] && echo "✅ 조건이 좁아지면 인원이 준다" || echo "❌ 인원이 안 줄었다 ($c → $cf)"
e=$($P -c "set role authenticated; select set_config('taam.uid','$OTH',false); select public.taam_ticket_audience_count('TP_ALL');" 2>&1 | grep -ci error)
[ "$e" -ge 1 ] && echo "✅ 남의 매장 티켓 인원수는 못 본다" || echo "❌ 남의 매장 인원수가 조회됨"
