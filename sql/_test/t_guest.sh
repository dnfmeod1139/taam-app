#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 게스트 90일 초대 — 서버가 정말 지키는지 (2026-09-02)
# ═══════════════════════════════════════════════════════════════
#   ① 만료 판정을 서버가 하는가 (앱 시계를 안 믿는다)
#   ② [+90일] 이 기한을 **줄이지 않는가**  ← 남은 기한 뒤에 붙어야 한다
#   ③ 만료된 사람에게 누르면 되살아나는가
#   ④ 휴면이 **삭제가 아닌가**  ← 결제 이력·등급이 남아 있어야 한다
#   ⑤ 회원은 남의 상태를 못 보는가 / 정원·설정을 못 바꾸는가
#   ⑥ 설정값이 없는 열쇠를 만들지 않는가
#
# 먼저:  psql -f sql/membership_apply.sql && psql -f sql/membership_settings.sql
# 실행:  bash sql/_test/t_guest.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
G1=d0000000-0000-4000-8000-0000000000c1   # 살아 있는 게스트
G2=d0000000-0000-4000-8000-0000000000c2   # 만료된 게스트
GM=d0000000-0000-4000-8000-0000000000c3   # M 회원 (게스트가 아니다)
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0

$P -c "grant usage on schema public to anon, authenticated;" >/dev/null 2>&1
$P -c "
insert into auth.users(id) values ('$G1'),('$G2'),('$GM') on conflict do nothing;
insert into public.profiles(id,role,display_name,membership_tier) values
 ('$G1','member','게스트살아','A'),('$G2','member','게스트만료','A'),('$GM','member','엠회원','M')
 on conflict (id) do update set membership_tier=excluded.membership_tier, role='member';
-- ⚠ 티켓을 **먼저** 넣는다. 2026-09-03 부터 게스트가 티켓을 사면
--   서버가 기한을 90일로 다시 잡는다(trg_taam_guest_touch_on_purchase).
--   기한을 먼저 세우면 이 삽입이 그걸 덮어써서, 「만료된 게스트」를
--   만들려다 멀쩡한 게스트가 된다.
delete from public.tickets where user_id='$G2';
insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,party_size,reservation_date)
 values('$G2','$RA','MAN-guest','active',100000,2,'2027-05-05');
update public.profiles set guest_expires_at = now() + interval '40 day',
       guest_status='active', guest_extended_cnt=0 where id='$G1';
update public.profiles set guest_expires_at = now() - interval '3 day',
       guest_status='active', guest_extended_cnt=0 where id='$G2';
update public.profiles set guest_expires_at = null, guest_status=null where id='$GM';
" >/dev/null 2>&1

echo "── ① 만료 판정은 서버가 ──"
ok "살아 있는 게스트 — 안 만료" false \
   "$($P -c "set role authenticated; select set_config('taam.uid','$G1',false);
             select (public.taam_guest_state())->>'expired';" | tail -1)"
ok "남은 날짜를 센다 (40일)" 40 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$G1',false);
             select (public.taam_guest_state())->>'days_left';" | tail -1)"
ok "만료된 게스트 — 만료 ⭐" true \
   "$($P -c "set role authenticated; select set_config('taam.uid','$G2',false);
             select (public.taam_guest_state())->>'expired';" | tail -1)"
ok "만료면 남은 날은 0" 0 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$G2',false);
             select (public.taam_guest_state())->>'days_left';" | tail -1)"
ok "M 회원은 게스트가 아니다" false \
   "$($P -c "set role authenticated; select set_config('taam.uid','$GM',false);
             select (public.taam_guest_state())->>'is_guest';" | tail -1)"

echo "── ② D-7 경고 ──"
$P -c "update public.profiles set guest_expires_at = now() + interval '5 day' where id='$G1';" >/dev/null
ok "5일 남으면 경고" true \
   "$($P -c "set role authenticated; select set_config('taam.uid','$G1',false);
             select (public.taam_guest_state())->>'warn';" | tail -1)"
$P -c "update public.profiles set guest_expires_at = now() + interval '40 day' where id='$G1';" >/dev/null
ok "40일 남으면 경고 없음" false \
   "$($P -c "set role authenticated; select set_config('taam.uid','$G1',false);
             select (public.taam_guest_state())->>'warn';" | tail -1)"

echo "── ③ [+90일] ── ⭐ 기한이 줄면 안 된다"
B=$($P -c "select guest_expires_at from public.profiles where id='$G1';" | tail -1)
$P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
       select public.taam_guest_extend('$G1');" >/dev/null 2>&1
ok "남은 기한 뒤에 붙는다 (40+90=130일) ⭐" 130 \
   "$($P -c "select ceil(extract(epoch from (guest_expires_at - now()))/86400)::int
             from public.profiles where id='$G1';" | tail -1)"
ok "연장 횟수가 센다" 1 \
   "$($P -c "select guest_extended_cnt from public.profiles where id='$G1';" | tail -1)"

echo "── ④ 만료된 사람을 되살린다 ──"
$P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
       select public.taam_guest_extend('$G2');" >/dev/null 2>&1
ok "지금부터 90일로 되살아난다 ⭐" 90 \
   "$($P -c "select ceil(extract(epoch from (guest_expires_at - now()))/86400)::int
             from public.profiles where id='$G2';" | tail -1)"
ok "휴면이 풀린다" active \
   "$($P -c "select guest_status from public.profiles where id='$G2';" | tail -1)"

echo "── ⑤ 휴면은 삭제가 아니다 ── ⭐"
$P -c "update public.profiles set guest_expires_at = now() - interval '1 day' where id='$G2';" >/dev/null
ok "쓸어담으면 휴면이 된다" dormant \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select public.taam_guest_sweep();
             select guest_status from public.profiles where id='$G2';" | tail -1)"
ok "등급은 그대로 남는다 ⭐" A \
   "$($P -c "select membership_tier from public.profiles where id='$G2';" | tail -1)"
ok "결제 이력도 그대로 ⭐" 1 \
   "$($P -c "select count(*) from public.tickets where user_id='$G2';" | tail -1)"
ok "이름도 안 지운다" 게스트만료 \
   "$($P -c "select display_name from public.profiles where id='$G2';" | tail -1)"

echo "── ⑥ 권한 ──"
if $P -c "set role authenticated; select set_config('taam.uid','$G1',false);
          select public.taam_guest_state('$G2');" >/dev/null 2>&1;
then echo "❌ 남의 게스트 상태를 봤다"; FAIL=1; else echo "✅ 남의 상태는 못 본다 ⭐"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$G1',false);
          select public.taam_guest_extend('$G1');" >/dev/null 2>&1;
then echo "❌ 자기 기한을 스스로 늘렸다"; FAIL=1; else echo "✅ 자기 기한을 못 늘린다 ⭐"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$G1',false);
          select public.taam_guest_list('all',10);" >/dev/null 2>&1;
then echo "❌ 회원이 게스트 명단을 봤다"; FAIL=1; else echo "✅ 명단은 슈퍼어드민만"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$G1',false);
          select public.taam_mship_settings_set('annual_fee','1'::jsonb);" >/dev/null 2>&1;
then echo "❌ 회원이 연회비를 바꿨다"; FAIL=1; else echo "✅ 연회비를 못 바꾼다 ⭐"; fi

echo "── ⑦ 설정값 ──"
ok "누구나 읽는다 (화면에 적힌다)" 10125000 \
   "$($P -c "set role anon; select (public.taam_mship_settings())->>'deposit_amount';" | tail -1)"
ok "슈퍼어드민은 바꾼다" 1300000 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select (public.taam_mship_settings_set('annual_fee_card','1300000'::jsonb))->>'v';" | tail -1)"
# 연회비는 결제 수단으로 갈린다 — 하나로 합쳐 두면 한쪽이 반드시 틀린다
ok "이체 연회비" 1125000 \
   "$($P -c "set role anon; select (public.taam_mship_settings())->>'annual_fee_cash';" | tail -1)"
ok "카드 연회비는 더 크다 ⭐" t \
   "$($P -c "set role anon; select ((public.taam_mship_settings())->>'annual_fee_card')::int
                                 > ((public.taam_mship_settings())->>'annual_fee_cash')::int;" | tail -1)"
ok "예치금은 결제 수단과 무관 (하나뿐)" 1 \
   "$($P -c "select count(*) from public.membership_settings where k like 'deposit%';" | tail -1)"
if $P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
          select public.taam_mship_settings_set('annual_feee','1'::jsonb);" >/dev/null 2>&1;
then echo "❌ 오타로 새 설정이 생겼다 (화면은 옛 값을 계속 읽는다)"; FAIL=1;
else echo "✅ 없는 열쇠는 안 만든다 ⭐"; fi
$P -c "select public.taam_mship_settings_set('annual_fee_card','1270000'::jsonb);" >/dev/null 2>&1

echo "── ⑧ 어드민 목록 ──"
ok "만료 임박순으로 나온다" 게스트만료 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select (public.taam_guest_list('all',50))->0->>'display_name';" | tail -1)"
ok "구매 여부를 같이 준다" true \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select (public.taam_guest_list('all',50))->0->>'has_purchased';" | tail -1)"
ok "휴면만 걸러진다" 1 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select jsonb_array_length(public.taam_guest_list('dormant',50));" | tail -1)"
ok "M 회원은 목록에 없다" 0 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select count(*) from jsonb_array_elements(public.taam_guest_list('all',200)) e
              where e->>'display_name' = '엠회원';" | tail -1)"

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
