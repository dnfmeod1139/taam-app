#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 대관 분할 청구 — 서버가 정말 막는지 (2026-09-01)
# ═══════════════════════════════════════════════════════════════
# 여기서 보고 싶은 것은 「앱이 안 보내면 안 일어난다」가 아니라
# **앱을 거치지 않고 찔러도 안 일어난다** 이다.
#
#   ① 합계가 1원이라도 어긋나면 분할이 통째로 거절되나
#   ② 이미 낸 사람이 있으면 다시 못 나누나 (낸 사람 몫을 조용히 지우지 않는다)
#   ③ 회원이 자기 청구 금액을 못 고치나
#   ④ 남의 청구를 못 읽나
#   ⑤ 링크 토큰을 아는 사람은 **그 한 건만** 보나
#   ⑥ 승인 금액이 청구와 다르면 확정이 거절되나
#   ⑦ 게스트 시트에 **금액이 안 나가나** ← 셰프 원칙
#   ⑧ 만료된 링크로 결제를 못 시작하나
#
# 먼저:  bash sql/_test/reset.sh && psql … -f sql/kashikiri.sql
# 실행:  bash sql/_test/t_kashikiri.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
MEM=11111111-1111-1111-1111-111111111111
OTH=33333333-3333-3333-3333-333333333333
RA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
has(){ if echo "$3" | grep -q "$2"; then echo "✅ $1"; else echo "❌ $1  ($2 없음)"; FAIL=1; fi; }
hasnt(){ if echo "$3" | grep -q "$2"; then echo "❌ $1  ($2 가 새어나옴)"; FAIL=1; else echo "✅ $1"; fi; }
rc(){ if $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" >/dev/null 2>&1;
      then echo OK; else echo FAIL; fi; }
as(){ $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" | tail -1; }
sudo_(){ $P -c "$1" | tail -1; }
FAIL=0

# ── 배우 세우기 ──────────────────────────────────────────────
$P -c "
truncate public.kashikiri_charges, public.kashikiri_guests,
         public.kashikiri_teams, public.kashikiri_events cascade;
insert into public.kashikiri_events(id, venue_id, venue_name, event_date, event_time,
        total_pax, escort, fx_rate, fx_note, venue_paid_jpy, status, created_by)
 values ('e1111111-1111-4111-8111-111111111111','$RA','鮨 めい乃','2027-01-01','18:00',
         9, true, 9.35, '1/1 매매기준율 + 2%', 960000, 'settling','$SUP');
insert into public.kashikiri_teams(id, event_id, seq, host_user_id, host_label, pax,
        total_jpy, total_krw, drink_note, allergy_note)
 values ('a1111111-1111-4111-8111-111111111111','e1111111-1111-4111-8111-111111111111',
         1,'$MEM','K様',4, 450000, 4207500, 'シャンパーニュ中心','甲殻類（1名）');
insert into public.kashikiri_guests(team_id, seq, display_name, user_id, is_host,
        visit_count, drink_note, allergy_note, memo)
 values ('a1111111-1111-4111-8111-111111111111',1,'K様','$MEM',true,3,
         'シャンパーニュから日本酒へ',null,'のどぐろをよろこばれた'),
        ('a1111111-1111-4111-8111-111111111111',2,'P様',null,false,0,
         null,'甲殻類（えび・かに）',null);
" >/dev/null 2>&1

echo "── ① 합계가 어긋나면 통째로 거절 ──"
BAD='[{"label":"K様","amount_krw":1000000},{"label":"동행1","amount_krw":1000000},
      {"label":"동행2","amount_krw":1000000},{"label":"동행3","amount_krw":1000000}]'
ok "합계 400만 ≠ 확정 4,207,500 → 거절" FAIL \
   "$(rc $SUP "select public.taam_kashikiri_split('a1111111-1111-4111-8111-111111111111','$BAD'::jsonb);")"
ok "0원 청구는 거절" FAIL \
   "$(rc $SUP "select public.taam_kashikiri_split('a1111111-1111-4111-8111-111111111111','[{\"label\":\"a\",\"amount_krw\":0},{\"label\":\"b\",\"amount_krw\":4207500}]'::jsonb);")"

GOOD='[{"label":"K様","user_id":"'$MEM'","amount_krw":1051875},
       {"label":"동행 1","amount_krw":1051875},
       {"label":"동행 2","amount_krw":1051875},
       {"label":"동행 3","amount_krw":1051875}]'
ok "딱 맞으면 통과" OK \
   "$(rc $SUP "select public.taam_kashikiri_split('a1111111-1111-4111-8111-111111111111','$GOOD'::jsonb);")"
ok "청구가 4건 생겼다" 4 "$(sudo_ "select count(*) from public.kashikiri_charges;")"
ok "회원 1 · 링크 3" 3 "$(sudo_ "select count(*) from public.kashikiri_charges where user_id is null;")"
ok "만료일이 방문일+3일" 2027-01-04 \
   "$(sudo_ "select to_char(min(expires_at),'YYYY-MM-DD') from public.kashikiri_charges;")"

echo "── ② 슈퍼어드민만 나눈다 ──"
ok "회원은 못 나눈다"   FAIL "$(rc $MEM "select public.taam_kashikiri_split('a1111111-1111-4111-8111-111111111111','$GOOD'::jsonb);")"
ok "남의 어드민도 못 나눈다" FAIL "$(rc $OTH "select public.taam_kashikiri_split('a1111111-1111-4111-8111-111111111111','$GOOD'::jsonb);")"

echo "── ③ 링크로 한 건만 읽는다 ──"
TOK=$(sudo_ "select token from public.kashikiri_charges where user_id is null order by label limit 1;")
J=$($P -c "select public.taam_kashikiri_charge_public('$TOK');" | tail -1)
has  "매장 이름이 나온다"      "めい乃"   "$J"
has  "자기 몫 금액이 나온다"   "1051875"  "$J"
has  "적용 환율이 나온다"      "9.35"     "$J"
hasnt "팀 확정액(4207500)은 안 나온다" "4207500" "$J"
hasnt "매장 지급액(960000)은 안 나온다" "960000"  "$J"
hasnt "남의 토큰은 안 나온다"   "token"    "$J"
ok "없는 토큰은 빈 결과" "" "$($P -c "select public.taam_kashikiri_charge_public('00000000000000000000000000000000');" | tail -1)"
ok "짧은 토큰은 빈 결과" "" "$($P -c "select public.taam_kashikiri_charge_public('abc');" | tail -1)"

echo "── ④ 회원이 금액을 못 고친다 ──"
# ⚠ 여기서 「예외가 났나」로 판정하면 안 된다. RLS 가 행을 걸러내면 UPDATE 는
#   0행을 고치고 **성공으로 끝난다.** 막혔는지는 값이 그대로인지로 본다.
$P -c "set role authenticated; select set_config('taam.uid','$MEM',false);
       update public.kashikiri_charges set amount_krw = 1 where user_id='$MEM';" >/dev/null 2>&1
ok "회원이 고쳐도 금액은 그대로" 1051875 \
   "$(sudo_ "select amount_krw from public.kashikiri_charges where user_id='$MEM';")"
ok "회원은 남의 청구도 못 고친다" 3 \
   "$(sudo_ "select count(*) from public.kashikiri_charges where amount_krw = 1051875 and user_id is null;")"
ok "회원은 자기 청구를 읽는다" OK \
   "$(rc $MEM "select amount_krw from public.kashikiri_charges where user_id='$MEM';")"
N=$(as $MEM "select count(*) from public.kashikiri_charges;")
ok "회원에게는 자기 것 1건만 보인다" 1 "$N"
N2=$(as $OTH "select count(*) from public.kashikiri_charges;")
ok "남에게는 한 건도 안 보인다" 0 "$N2"

echo "── ⑤ 결제 시작 — 금액은 서버가 준다 ──"
S=$($P -c "select public.taam_kashikiri_order_start('$TOK','박지연');" | tail -1)
has "주문번호가 KSK- 로 시작"  "KSK-"    "$S"
has "금액을 서버가 돌려준다"    "1051875" "$S"
O=$(sudo_ "select order_id from public.kashikiri_charges where token='$TOK';")
S2=$($P -c "select public.taam_kashikiri_order_start('$TOK');" | tail -1)
O2=$(sudo_ "select order_id from public.kashikiri_charges where token='$TOK';")
ok "다시 불러도 주문번호가 같다 (멱등)" "$O" "$O2"
ok "이름이 남는다" "박지연" "$(sudo_ "select payer_name from public.kashikiri_charges where token='$TOK';")"

echo "── ⑥ 승인 금액이 다르면 확정 거절 ──"
ok "금액이 다르면 거절" FAIL \
   "$(rc $SUP "select public.taam_kashikiri_mark_paid('$O','pk_x',999,'카드',null);")"
ok "금액이 맞으면 확정" OK \
   "$($P -c "select public.taam_kashikiri_mark_paid('$O','pk_ok',1051875,'카드','http://r');" >/dev/null 2>&1 && echo OK || echo FAIL)"
ok "상태가 paid" paid "$(sudo_ "select status from public.kashikiri_charges where token='$TOK';")"
ok "두 번 확정해도 멱등" OK \
   "$($P -c "select public.taam_kashikiri_mark_paid('$O','pk_ok',1051875,'카드','http://r');" >/dev/null 2>&1 && echo OK || echo FAIL)"
ok "회원은 mark_paid 를 못 부른다" FAIL \
   "$(rc $MEM "select public.taam_kashikiri_mark_paid('$O','pk_z',1051875,null,null);")"

echo "── ⑦ 낸 사람이 있으면 다시 못 나눈다 ──"
ok "결제된 건이 있으면 재분할 거절" FAIL \
   "$(rc $SUP "select public.taam_kashikiri_split('a1111111-1111-4111-8111-111111111111','$GOOD'::jsonb);")"
ok "낸 사람 몫이 그대로 남아 있다" 1 \
   "$(sudo_ "select count(*) from public.kashikiri_charges where status='paid';")"

echo "── ⑧ 이미 낸 링크로는 결제가 다시 시작되지 않는다 ──"
has "already_paid 로 돌려준다" "already_paid" \
    "$($P -c "select public.taam_kashikiri_order_start('$TOK');" | tail -1)"

echo "── ⑨ 만료된 링크 ──"
TOK2=$(sudo_ "select token from public.kashikiri_charges where status='pending' limit 1;")
$P -c "update public.kashikiri_charges set expires_at = now() - interval '1 day' where token='$TOK2';" >/dev/null
has "만료된 링크는 blocked 로 돌려준다" "expired" \
    "$($P -c "select public.taam_kashikiri_order_start('$TOK2');" | tail -1)"
ok "만료로 상태가 바뀐다" expired "$(sudo_ "select status from public.kashikiri_charges where token='$TOK2';")"

echo "── ⑩ 게스트 시트 — 셰프에게 돈이 안 나간다 ⭐ ──"
ST=$(as $SUP "select public.taam_kashikiri_sheet_link('e1111111-1111-4111-8111-111111111111', 3);")
G=$($P -c "select public.taam_kashikiri_sheet_public('$ST');" | tail -1)
has  "매장 이름이 나온다"        "めい乃"        "$G"
has  "인솔 여부가 나온다"        "escort"        "$G"
has  "인원별 이름이 나온다"      "P様"           "$G"
has  "알레르기가 나온다"         "甲殻類"        "$G"
has  "방문 횟수가 나온다"        "visit_count"   "$G"
hasnt "팀 확정액(4207500) 없음"   "4207500"       "$G"
hasnt "1인 청구액(1051875) 없음"  "1051875"       "$G"
hasnt "매장 지급액(960000) 없음"  "960000"        "$G"
hasnt "환율(9.35) 없음"           "9.35"          "$G"
hasnt "전화번호 컬럼 자체가 없음" "phone"         "$G"
ok "게스트 시트 링크는 슈퍼어드민만 발급" FAIL \
   "$(rc $MEM "select public.taam_kashikiri_sheet_link('e1111111-1111-4111-8111-111111111111',3);")"

echo "── ⑪ 시트 토큰을 다시 발급하면 옛 링크가 죽는다 ──"
ST2=$(as $SUP "select public.taam_kashikiri_sheet_link('e1111111-1111-4111-8111-111111111111', 3);")
ok "새 토큰은 다르다" different "$([ "$ST" != "$ST2" ] && echo different || echo same)"
ok "옛 토큰은 빈 결과" "" "$($P -c "select public.taam_kashikiri_sheet_public('$ST');" | tail -1)"

echo "── ⑫ 만료된 시트 ──"
$P -c "update public.kashikiri_events set sheet_expires = now() - interval '1 day';" >/dev/null
has "만료 표시로 돌려준다" "expired" "$($P -c "select public.taam_kashikiri_sheet_public('$ST2');" | tail -1)"

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
