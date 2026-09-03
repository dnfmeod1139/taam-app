#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 일반 회원(A 등급) — 서버가 정말 막는지 (2026-09-02)
# ═══════════════════════════════════════════════════════════════
# 앱에서 버튼을 숨기는 건 방어가 아니다. 여기서 보는 건
# **앱을 거치지 않고 tickets 에 직접 INSERT 해도 막히는가** 이다.
#
#   ① A 등급은 「일반공개(min_tier=A)」 티켓만 사나
#   ② min_tier 가 비어 있는 티켓을 A 가 못 사나  ← 이게 핵심
#   ③ 그런데 기존 회원(T·M·등급없음)은 종전 그대로인가  ← 라이브 안 깨지나
#   ④ 슈퍼어드민·초대·수동입력은 여전히 예외인가
#
# 먼저:  bash sql/_test/reset.sh + 픽스처 + sql/general_member_tier.sql
# 실행:  bash sql/_test/t_tier.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
MEM=11111111-1111-1111-1111-111111111111
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
UA=b0000000-0000-4000-8000-0000000000a1   # A 등급 (일반 회원)
UT=b0000000-0000-4000-8000-0000000000a2   # T 등급
UM=b0000000-0000-4000-8000-0000000000a3   # M 등급
UN=b0000000-0000-4000-8000-0000000000a4   # 등급 없음 (옛 회원)

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
# 산다/못 산다 — tickets 에 직접 INSERT 해 본다 (앱을 거치지 않는다)
buy(){ # uid, ticket_product_id, purchase_id
  if $P -c "set role authenticated; select set_config('taam.uid','$1',false);
            insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,
                   party_size,reservation_date,ticket_product_id)
            values('$1','$RA','$3','active',100000,2,'2027-01-01','$2');" >/dev/null 2>&1;
  then echo 산다; else echo 막힘; fi; }
FAIL=0

# ── 배우 ─────────────────────────────────────────────────────
$P -c "
insert into auth.users(id) values ('$UA'),('$UT'),('$UM'),('$UN') on conflict do nothing;
insert into public.profiles(id,role,display_name,membership_tier,membership_expires_at) values
 ('$UA','member','일반회원','A',null),
 ('$UT','member','T회원','T',null),
 ('$UM','member','M회원','M', now() + interval '365 day'),
 ('$UN','member','옛회원',null,null)
 on conflict (id) do update set membership_tier=excluded.membership_tier,
   membership_expires_at=excluded.membership_expires_at, role='member';
-- ⚠ 앞 실행이 남긴 것 위에서 돌면 재구매 가드에 걸려 「막힘」이 무더기로 난다.
--   이 배우들의 티켓은 통째로 지운다 (INV-·MAN- 예외 건까지).
delete from public.tickets where user_id in ('$UA','$UT','$UM','$UN','$SUP');
delete from public.ticket_products where id in ('TP_OPEN','TP_BLANK','TP_T','TP_M');
insert into public.ticket_products(id, rest_id, min_tier) values
 ('TP_OPEN','$RA','A'),      -- 일반공개
 ('TP_BLANK','$RA',null),    -- 제한 안 걸린 티켓 (기본 = 유료 전용)
 ('TP_T','$RA','T'),
 ('TP_M','$RA','M');
" >/dev/null 2>&1

echo "── ① 게스트(A)는 게스트석만 산다 ──"
# ⚠ 2026-09: min_tier='A' **만으로는 못 산다.** 게스트석으로 열려야 한다 —
#   이유·수량·매장 허락까지 갖춰야 한다(sql/guest_seat.sql). 그전에는
#   min_tier='A' 하나로 열렸는데, 그러면 이유 없는 자리가 그냥 할인이 된다.
ok "안 연 자리는 못 산다 ⭐"       막힘 "$(buy $UA TP_OPEN  TR-A0)"
$P -c "update public.restaurants set guest_seat_allowed=true where id='$RA';
       set role authenticated; select set_config('taam.uid','$SUP',false);
       select public.taam_guest_seat_open('TP_OPEN','셰프의 요청으로',300000,3);" >/dev/null 2>&1
ok "게스트석으로 열면 산다"        산다 "$(buy $UA TP_OPEN  TR-A1)"
ok "제한 없는 티켓은 못 산다 ⭐"   막힘 "$(buy $UA TP_BLANK TR-A2)"
ok "T 전용은 못 산다"              막힘 "$(buy $UA TP_T     TR-A3)"
ok "M 전용은 못 산다"              막힘 "$(buy $UA TP_M     TR-A4)"

echo "── ② 기존 회원은 종전 그대로 (라이브가 안 깨진다) ──"
ok "T 회원 — 제한 없는 티켓"  산다 "$(buy $UT TP_BLANK TR-T1)"
ok "T 회원 — 일반공개"        산다 "$(buy $UT TP_OPEN  TR-T2)"
ok "T 회원 — T 전용"          산다 "$(buy $UT TP_T     TR-T3)"
ok "T 회원 — M 전용은 막힘"   막힘 "$(buy $UT TP_M     TR-T4)"
ok "M 회원 — M 전용"          산다 "$(buy $UM TP_M     TR-M1)"
ok "M 회원 — 제한 없는 티켓"  산다 "$(buy $UM TP_BLANK TR-M2)"
# ⚠ 등급이 아예 없는 옛 회원. 여기가 막히면 멀쩡한 회원이 아무것도 못 산다.
ok "등급 없는 옛 회원 — 제한 없는 티켓" 산다 "$(buy $UN TP_BLANK TR-N1)"
# ⚠ 게스트가 아닌 사람에게 min_tier=A 는 여전히 「개방」이다 — 하한이 아니다
ok "등급 없는 옛 회원 — 일반공개 ⭐"     산다 "$(buy $UN TP_OPEN  TR-N2)"
ok "등급 없는 옛 회원 — T 전용은 막힘"  막힘 "$(buy $UN TP_T     TR-N3)"

echo "── ③ 예외 ──"
ok "슈퍼어드민은 뭐든 산다" 산다 "$(buy $SUP TP_M TR-S1)"
# 초대·수동입력은 purchase_id 로 갈린다
if $P -c "set role authenticated; select set_config('taam.uid','$UA',false);
          insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,party_size,
                 reservation_date,ticket_product_id)
          values('$UA','$RA','INV-abc','active',100000,2,'2027-01-01','TP_M');" >/dev/null 2>&1;
then echo "✅ 초대(INV-)는 A 등급도 통과"; else echo "❌ 초대(INV-)가 막혔다"; FAIL=1; fi
if $P -c "set role authenticated; select set_config('taam.uid','$UA',false);
          insert into public.tickets(user_id,restaurant_id,purchase_id,status,price,party_size,
                 reservation_date,ticket_product_id)
          values('$UA','$RA','MAN-abc','active',100000,2,'2027-01-01','TP_M');" >/dev/null 2>&1;
then echo "✅ 수동입력(MAN-)은 통과"; else echo "❌ 수동입력이 막혔다"; FAIL=1; fi

echo "── ④ 일반공개 판정 ──"
ok "min_tier=A 는 일반공개"      t "$($P -c "select public.taam_tier_is_open('A');" | tail -1)"
ok "소문자 a 도 일반공개"        t "$($P -c "select public.taam_tier_is_open('a');" | tail -1)"
ok "빈 값은 일반공개가 아니다 ⭐" f "$($P -c "select public.taam_tier_is_open('');" | tail -1)"
ok "null 도 일반공개가 아니다"   f "$($P -c "select public.taam_tier_is_open(null);" | tail -1)"
ok "T 는 일반공개가 아니다"      f "$($P -c "select public.taam_tier_is_open('T');" | tail -1)"

echo "── ⑤ M 만료는 T 로 내려앉는다 (종전 규칙 유지) ──"
$P -c "update public.profiles set membership_expires_at = now() - interval '1 day' where id='$UM';" >/dev/null
ok "만료된 M 은 T 로 본다"     T    "$($P -c "select public.taam_user_tier('$UM');" | tail -1)"
ok "만료된 M 은 M 전용을 못 산다" 막힘 "$(buy $UM TP_M TR-M3)"
ok "만료돼도 A 로 떨어지진 않는다" 산다 "$(buy $UM TP_BLANK TR-M4)"

echo "── ⑥ 초대코드가 A 를 받는다 ──"
if $P -c "insert into public.invite_codes(code, invitee_tier) values ('TESTA','A')
          on conflict (code) do update set invitee_tier='A';" >/dev/null 2>&1;
then echo "✅ A 초대코드 발급"; else echo "❌ A 초대코드가 막혔다"; FAIL=1; fi
if $P -c "insert into public.invite_codes(code, invitee_tier) values ('TESTX','X');" >/dev/null 2>&1;
then echo "❌ 이상한 등급이 들어갔다"; FAIL=1; else echo "✅ 이상한 등급은 거절"; fi

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
