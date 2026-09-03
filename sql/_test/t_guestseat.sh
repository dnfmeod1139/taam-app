#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 게스트 초대석 — 서버가 정말 지키는지 (2026-09-02)
# ═══════════════════════════════════════════════════════════════
#   ① 게스트는 **게스트석만** 사는가
#   ② 이유 없이는 못 여는가        ← 이유가 서사다. 빠지면 그냥 할인이다
#   ③ 매장이 안 허락하면 못 여는가 ← 핵심 관계 매장이 실수로 열리면 안 된다
#   ④ 정한 수량을 못 넘는가        ← 한 석짜리가 두 장 나가면 안 된다
#   ⑤ 게스트 구매가 **확정 대기**로 들어가는가
#   ⑤-2 **게스트가로** 받는가       ← 앱이 회원가를 보내도 서버가 덮어쓴다
#   ⑥ 회원은 종전 그대로인가       ← 라이브가 안 깨지나
#   ⑦ 매장을 끄면 열린 자리도 닫히는가
#
# 먼저: general_member_tier.sql · guest_seat.sql · guest_seat_price.sql
# 실행: bash sql/_test/t_guestseat.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
G1=a1000000-0000-4000-8000-000000000f01   # 게스트
G2=a1000000-0000-4000-8000-000000000f02   # 게스트 2
UM=a1000000-0000-4000-8000-000000000f03   # M 회원
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa   # 허용 매장
RB=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb   # 잠긴 매장

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
SA="set role authenticated; select set_config('taam.uid','$SUP',false);"
# 게스트가 산다 — 앱을 거치지 않고 tickets 에 직접 INSERT 한다
buy(){ # uid, product, purchase_id
  if $P -c "set role authenticated; select set_config('taam.uid','$1',false);
            insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,
                   party_size,reservation_date,ticket_product_id)
            values('$1','$RA','$3','active',300000,2,'2027-06-06','$2');" >/dev/null 2>&1;
  then echo 산다; else echo 막힘; fi; }
# 앱이 **틀린 금액**을 보냈을 때를 보기 위한 변형 — 금액·인원을 골라 넣는다
buyp(){ # uid, product, purchase_id, price, pax
  if $P -c "set role authenticated; select set_config('taam.uid','$1',false);
            insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,
                   party_size,reservation_date,ticket_product_id)
            values('$1','$RA','$3','active',$4,$5,'2027-06-06','$2');" >/dev/null 2>&1;
  then echo 산다; else echo 막힘; fi; }

# ── 배우 ─────────────────────────────────────────────────────
$P -c "
insert into auth.users(id) values ('$G1'),('$G2'),('$UM') on conflict do nothing;
insert into public.profiles(id,role,display_name,membership_tier) values
 ('$G1','member','게스트하나','A'),('$G2','member','게스트둘','A'),('$UM','member','엠회원','M')
 on conflict (id) do update set membership_tier=excluded.membership_tier, role='member';
insert into public.restaurants(id,name) values ('$RA','허용매장'),('$RB','잠긴매장')
 on conflict (id) do nothing;
delete from public.tickets where ticket_product_id in ('GP_OPEN','GP_SHUT','GP_MEM','GP_LOCKED','GP_PRICE');
delete from public.ticket_products where id in ('GP_OPEN','GP_SHUT','GP_MEM','GP_LOCKED','GP_PRICE');
insert into public.ticket_products(id, rest_id, min_tier) values
 ('GP_OPEN','$RA','A'),     -- 게스트석으로 열 것
 ('GP_SHUT','$RA','A'),     -- 안 여는 것
 ('GP_MEM','$RA',null),     -- 회원 전용
 ('GP_PRICE','$RA','A'),    -- 금액을 보는 것 (⑤-2)
 ('GP_LOCKED','$RB','A');   -- 잠긴 매장
update public.restaurants set guest_seat_allowed=true  where id='$RA';
update public.restaurants set guest_seat_allowed=false where id='$RB';
" >/dev/null 2>&1

echo "── ① 안 연 자리는 못 산다 ──"
ok "게스트석이 아니면 막힌다 ⭐" 막힘 "$(buy $G1 GP_SHUT GS-1)"
ok "회원 전용도 막힌다"          막힘 "$(buy $G1 GP_MEM  GS-2)"

echo "── ② 이유 없이는 못 연다 ── ⭐"
if $P -c "$SA select public.taam_guest_seat_open('GP_OPEN','',300000,2);" >/dev/null 2>&1;
then echo "❌ 이유 없이 열렸다 (그냥 할인이 된다)"; FAIL=1; else echo "✅ 이유 없이는 못 연다 ⭐"; fi
if $P -c "$SA select public.taam_guest_seat_open('GP_OPEN','셰프의 요청으로',300000,0);" >/dev/null 2>&1;
then echo "❌ 0석으로 열렸다"; FAIL=1; else echo "✅ 수량 없이는 못 연다"; fi
if $P -c "$SA select public.taam_guest_seat_open('GP_OPEN','셰프의 요청으로',0,2);" >/dev/null 2>&1;
then echo "❌ 가격 없이 열렸다"; FAIL=1; else echo "✅ 가격 없이는 못 연다"; fi

echo "── ③ 매장이 허락해야 ── ⭐"
if $P -c "$SA select public.taam_guest_seat_open('GP_LOCKED','셰프의 요청으로',300000,2);" >/dev/null 2>&1;
then echo "❌ 잠긴 매장에서 열렸다"; FAIL=1; else echo "✅ 잠긴 매장은 못 연다 ⭐"; fi

echo "── ④ 제대로 열기 ──"
ok "열린다" true \
   "$($P -c "$SA select (public.taam_guest_seat_open('GP_OPEN','셰프의 요청으로',300000,2))->>'open';" | tail -1)"
ok "이유가 남는다" "셰프의 요청으로" \
   "$($P -c "select guest_open_reason from public.ticket_products where id='GP_OPEN';" | tail -1)"
ok "두 석" 2 \
   "$($P -c "set role anon; select (public.taam_guest_seat_state('GP_OPEN'))->>'left';" | tail -1)"

echo "── ⑤ 게스트가 산다 — 확정 대기로 ── ⭐"
ok "산다" 산다 "$(buy $G1 GP_OPEN GS-10)"
ok "확정 대기로 들어간다 ⭐" pending_confirm \
   "$($P -c "select status from public.tickets where purchase_id='GS-10';" | tail -1)"
# ⚠ 앱이 'active' 로 보냈는데 서버가 내렸다 — 앱이 보낸 status 를 안 믿는다
ok "남은 자리가 준다" 1 \
   "$($P -c "set role anon; select (public.taam_guest_seat_state('GP_OPEN'))->>'left';" | tail -1)"

echo "── ⑤-2 금액은 서버가 정한다 ── ⭐"
# ⚠ guest_price 는 **1인당**, tickets.price 는 **총액**이다. 그래서 곱한다.
#   앱이 회원가를 보내도(옛 버전·앱을 거치지 않은 호출) 서버가 게스트가로 덮어쓴다.
$P -c "$SA select public.taam_guest_seat_open('GP_PRICE','개점 10주년을 기념해',300000,4);" >/dev/null 2>&1
ok "게스트가가 남는다" 300000 \
   "$($P -c "select guest_price from public.ticket_products where id='GP_PRICE';" | tail -1)"
# 앱이 회원가(250,000×2=500,000)를 보냈다 — 서버가 600,000 으로 고쳐야 한다
ok "산다" 산다 "$(buyp $G1 GP_PRICE GS-40 500000 2)"
ok "게스트가×인원으로 덮어쓴다 ⭐" 600000 \
   "$($P -c "select price from public.tickets where purchase_id='GS-40';" | tail -1)"
ok "앱이 틀렸다는 흔적을 남긴다 ⭐" true \
   "$($P -c "select extra_data->>'guest_price_fixed' from public.tickets where purchase_id='GS-40';" | tail -1)"
ok "앱이 보낸 금액을 적어 둔다" 500000 \
   "$($P -c "select extra_data->>'guest_price_app' from public.tickets where purchase_id='GS-40';" | tail -1)"
ok "1인당 금액도 적어 둔다" 300000 \
   "$($P -c "select extra_data->>'guest_price_per' from public.tickets where purchase_id='GS-40';" | tail -1)"
# 앱이 맞게 보냈으면 흔적을 안 남긴다 — 어드민 큐에 헛경고가 뜨면 안 된다
ok "맞게 보내면 그대로" 산다 "$(buyp $G2 GP_PRICE GS-41 900000 3)"
ok "맞으면 금액이 그대로다" 900000 \
   "$($P -c "select price from public.tickets where purchase_id='GS-41';" | tail -1)"
ok "맞으면 흔적을 안 남긴다 ⭐" "" \
   "$($P -c "select coalesce(extra_data->>'guest_price_fixed','') from public.tickets where purchase_id='GS-41';" | tail -1)"
# 어드민이 확정 전에 볼 수 있어야 한다
ok "큐가 어긋난 건을 표시한다 ⭐" true \
   "$($P -c "$SA select e->>'price_fixed' from jsonb_array_elements(public.taam_guest_seat_queue(200)) e
             where e->>'purchase_id'='GS-40';" | tail -1)"
ok "큐가 앱 금액도 준다" 500000 \
   "$($P -c "$SA select e->>'price_app' from jsonb_array_elements(public.taam_guest_seat_queue(200)) e
             where e->>'purchase_id'='GS-40';" | tail -1)"
ok "맞은 건은 표시가 안 뜬다" false \
   "$($P -c "$SA select e->>'price_fixed' from jsonb_array_elements(public.taam_guest_seat_queue(200)) e
             where e->>'purchase_id'='GS-41';" | tail -1)"
# ⚠ 회원 금액은 손대지 않는다. 회원가는 게스트가와 무관하다.
ok "회원 금액은 안 건드린다 ⭐" 산다 "$(buyp $UM GP_PRICE GS-42 500000 2)"
ok "회원은 보낸 금액 그대로" 500000 \
   "$($P -c "select price from public.tickets where purchase_id='GS-42';" | tail -1)"

echo "── ⑥ 수량을 못 넘는다 ── ⭐"
ok "두 번째도 산다" 산다 "$(buy $G2 GP_OPEN GS-11)"
ok "세 번째는 막힌다 ⭐" 막힘 "$(buy $G1 GP_OPEN GS-12)"
ok "남은 자리 0" 0 \
   "$($P -c "set role anon; select (public.taam_guest_seat_state('GP_OPEN'))->>'left';" | tail -1)"

echo "── ⑦ 회원은 종전 그대로 ── ⭐ 라이브가 안 깨지나"
ok "M 회원 — 회원 전용을 산다" 산다 "$(buy $UM GP_MEM GS-20)"
ok "M 회원 — 게스트석도 산다"  산다 "$(buy $UM GP_OPEN GS-21)"
ok "M 회원은 바로 active ⭐" active \
   "$($P -c "select status from public.tickets where purchase_id='GS-21';" | tail -1)"
# 회원이 산 자리는 게스트석 수량과 무관하다
ok "회원 구매는 게스트석 수량을 안 먹는다 ⭐" 2 \
   "$($P -c "set role anon; select (public.taam_guest_seat_state('GP_OPEN'))->>'sold';" | tail -1)"

echo "── ⑧ 확정 큐 ──"
# ⚠ 개수로 세면 다른 테스트가 남긴 대기 건까지 딸려 온다 (t_tier 가 하나 남긴다).
#   이 테스트가 만든 두 건이 큐에 있는지로 본다.
ok "이 회차 대기 두 건" 2 \
   "$($P -c "$SA select count(*) from jsonb_array_elements(public.taam_guest_seat_queue(200)) e
             where e->>'purchase_id' in ('GS-10','GS-11');" | tail -1)"
ok "이유를 같이 준다" "셰프의 요청으로" \
   "$($P -c "$SA select e->>'guest_open_reason'
             from jsonb_array_elements(public.taam_guest_seat_queue(200)) e
             where e->>'purchase_id' = 'GS-10';" | tail -1)"
TID=$($P -c "select id from public.tickets where purchase_id='GS-10';" | tail -1)
ok "확정하면 active" active \
   "$($P -c "$SA select public.taam_guest_seat_confirm('$TID');
             select status from public.tickets where id='$TID';" | tail -1)"
if $P -c "$SA select public.taam_guest_seat_confirm('$TID');" >/dev/null 2>&1;
then echo "❌ 이미 확정된 것을 또 확정했다"; FAIL=1; else echo "✅ 두 번 확정은 막힌다"; fi

TID2=$($P -c "select id from public.tickets where purchase_id='GS-11';" | tail -1)
ok "거절하면 취소" cancelled \
   "$($P -c "$SA select public.taam_guest_seat_reject('$TID2','자리가 안 나왔습니다');
             select status from public.tickets where id='$TID2';" | tail -1)"
# ⚠ 환불은 여기서 하지 않는다 — 카드 취소는 토스에서 따로 해야 하고,
#   여기서 「환불했다」고 기록하면 실제로 안 빠진 돈을 빠진 것으로 세게 된다.
#   그래서 상태만 내리고 **환불이 남았다고 알린다**.
GS12=$($P -c "$SA select set_config('taam.uid','$SUP',false);
  insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,party_size,
         reservation_date,ticket_product_id)
  values('$G1','$RA','GS-99','pending_confirm',300000,2,'2027-06-06','GP_OPEN')
  returning id;" | tail -1)
ok "환불이 남았다고 알린다 ⭐" true \
   "$($P -c "$SA select (public.taam_guest_seat_reject('$GS12','x'))->>'refund_needed';" | tail -1)"
# 확정된 건은 거절할 수 없다 (이미 자리를 드렸다)
if $P -c "$SA select public.taam_guest_seat_reject('$TID','x');" >/dev/null 2>&1;
then echo "❌ 확정된 건을 거절했다"; FAIL=1; else echo "✅ 확정된 건은 거절 못 한다 ⭐"; fi
ok "거절 사유가 남는다" "자리가 안 나왔습니다" \
   "$($P -c "select extra_data->>'guest_reject_memo' from public.tickets where id='$TID2';" | tail -1)"
ok "거절하면 자리가 돌아온다 ⭐" 1 \
   "$($P -c "set role anon; select (public.taam_guest_seat_state('GP_OPEN'))->>'left';" | tail -1)"

echo "── ⑨ 매장을 끄면 열린 자리도 닫힌다 ── ⭐"
$P -c "$SA select public.taam_guest_seat_allow('$RA', false);" >/dev/null 2>&1
ok "게스트석이 닫힌다 ⭐" f \
   "$($P -c "select guest_open from public.ticket_products where id='GP_OPEN';" | tail -1)"
ok "이유는 안 지운다 (다시 열 때 쓴다)" "셰프의 요청으로" \
   "$($P -c "select guest_open_reason from public.ticket_products where id='GP_OPEN';" | tail -1)"
ok "닫히면 못 산다" 막힘 "$(buy $G1 GP_OPEN GS-30)"
$P -c "$SA select public.taam_guest_seat_allow('$RA', true);" >/dev/null 2>&1

echo "── ⑩ 권한 ──"
if $P -c "set role authenticated; select set_config('taam.uid','$G1',false);
          select public.taam_guest_seat_open('GP_SHUT','내가 연다',1,1);" >/dev/null 2>&1;
then echo "❌ 게스트가 자리를 열었다"; FAIL=1; else echo "✅ 여는 건 슈퍼어드민만 ⭐"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$G1',false);
          select public.taam_guest_seat_queue(10);" >/dev/null 2>&1;
then echo "❌ 게스트가 확정 큐를 봤다"; FAIL=1; else echo "✅ 큐도 슈퍼어드민만"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$G1',false);
          update public.tickets set status='active' where purchase_id='GS-10';" 2>&1 | grep -q "UPDATE 1";
then echo "❌ 게스트가 스스로 확정했다"; FAIL=1; else echo "✅ 스스로 확정 못 한다 ⭐"; fi

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
