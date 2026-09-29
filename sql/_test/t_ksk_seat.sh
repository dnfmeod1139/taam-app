#!/bin/bash
# 정산 결제 → 티켓 좌석 연동 회귀 — 2026-09-29. 먼저: 로컬 pg. 실행: bash sql/_test/t_ksk_seat.sh
#   픽스처는 t_link_invite.sh 의 것을 그대로 빌린다 (같은 표·같은 정원 트리거 흉내).
cd "$(dirname "$0")/../.."
DB=t_kskseat; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
sed -n "/^\$P <<'SQL'/,/^SQL$/p" sql/_test/t_link_invite.sh | sed '1d;$d' | $P >/dev/null 2>&1
$P -f supabase/migrations/20260929_link_invite.sql 2>&1 | grep -E "❌|ERROR"
$P -f supabase/migrations/20260929_kashikiri_seat_sync.sql 2>&1 | grep -E "❌|ERROR"
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
SU=a1000000-0000-4000-8000-000000000001
S="select set_config('taam.uid','$SU',false); select set_config('taam.super','1',false);"
EV=e1000000-0000-4000-8000-000000000001; TA=f1000000-0000-4000-8000-00000000000a
C1=c1000000-0000-4000-8000-000000000001; C2=c1000000-0000-4000-8000-000000000002; C3=c1000000-0000-4000-8000-000000000003
$P <<SQL >/dev/null
insert into public.kashikiri_events(id, venue_id, venue_name, event_date, event_time, total_pax, escort, status, created_by)
  values ('$EV','b1000000-0000-4000-8000-000000000001','마츠카와','2027-05-01','18:00',4,false,'open','$SU');
insert into public.kashikiri_teams(id, event_id, seq, host_label, pax) values ('$TA','$EV',1,'K様',2);
insert into public.kashikiri_charges(id, event_id, team_id, label, amount_krw, status, payer_name, pay_currency, pay_amount, approved_at)
  values ('$C1','$EV','$TA','K様',1800000,'paid','Kim',    'KRW',1800000, now()),
         ('$C2','$EV',null, 'Trina',2321555,'pending','Trina Chin','USD',1679.85, null),
         ('$C3','$EV',null, 'Third',900000,'pending',null,'KRW',900000, null);
SQL
LIVE="select coalesce(sum(party_size),0)||'|'||count(*) from public.tickets where purchase_id like 'KSK-%' and coalesce(status,'')<>'cancelled'"

echo "── ① 연결 RPC: paid 청구(조 2명) → KSK- 행"
r=$($P -c "$S select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "made 1 · seats 2 · short 없음" "1|1|1" "$(echo "$r" | grep -c '"made" : 1')|$(echo "$r" | grep -c '"seats" : 2')|$(echo "$r" | grep -c '"short" : \[\]')"
ok "행: active · 2명 · 매장·날짜·시간·이름" "active|2|마츠카와|2027.05.01|18:00|Kim" "$($P -c "select status||'|'||party_size||'|'||restaurant_name||'|'||reservation_date||'|'||visit_time||'|'||buyer_name from public.tickets where purchase_id like 'KSK-%'")"
ok "회차 ticket_product_id 기록" "tp1" "$($P -c "select ticket_product_id from public.kashikiri_events where id='$EV'")"

echo "── ② 결제 트리거: 조 없는 청구 pending→paid → 1명 행"
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id='$C2'" >/dev/null
ok "살아 있는 좌석 3석 · 2행" "3|2" "$($P -c "$LIVE")"
ok "Trina 행 이름·통화" "Trina Chin|USD" "$($P -c "select buyer_name||'|'||(extra_data->>'currency') from public.tickets where extra_data->>'chargeId'='$C2' and status='active'")"

echo "── ③ 조 인원 변경 2→3 → 행 party_size 따라감"
$P -c "update public.kashikiri_teams set pax=3 where id='$TA'" >/dev/null
ok "K様 행 3명 · 총 4석" "3|4|2" "$($P -c "select party_size from public.tickets where extra_data->>'chargeId'='$C1' and status='active'")|$($P -c "$LIVE")"

echo "── ④ 정원 초과: 셋째 청구 paid → 예외 없이 short 로 보고, 행 없음"
r=$($P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id='$C3'" 2>&1); ok "update 가 깨지지 않음" "" "$(echo "$r" | grep -i error)"
ok "셋째 행 없음 · 여전히 4석" "0|4|2" "$($P -c "select count(*) from public.tickets where extra_data->>'chargeId'='$C3'")|$($P -c "$LIVE")"
r=$($P -c "$S select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "다시 연결해도 short 에 Third 1명" "1" "$(echo "$r" | grep -c '"label": "Third"')"

echo "── ⑤ 환불: 청구 refunded → 행 cancelled (좌석 복구)"
$P -c "update public.kashikiri_charges set status='refunded' where id='$C1'" >/dev/null
ok "K様 행 cancelled · 같은 패스에서 기다리던 Third 가 들어감 → 2석 2행" "cancelled|2|2|1" "$($P -c "select status from public.tickets where extra_data->>'chargeId'='$C1'")|$($P -c "$LIVE")|$($P -c "select count(*) from public.tickets where extra_data->>'chargeId'='$C3' and status='active'")"
r=$($P -c "$S select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "다시 연결은 멱등 (made 0 · short 없음)" "1|1" "$(echo "$r" | grep -c '"made" : 0')|$(echo "$r" | grep -c '"short" : \[\]')"

echo "── ⑥ 연결 해제 → 전부 cancelled · 재연결 → 다시 생성"
r=$($P -c "$S select (public.taam_kashikiri_link_ticket('$EV',null))::text" 2>&1)
ok "해제: cancelled 2 · 0석" "1|0|0" "$(echo "$r" | grep -c '"cancelled" : 2')|$($P -c "$LIVE")"
r=$($P -c "$S select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "재연결: made 2 · 2석" "1|2|2" "$(echo "$r" | grep -c '"made" : 2')|$($P -c "$LIVE")"

echo "── ⑦ 옛 빌드 경로: 회차 행을 직접 update 해도 트리거가 따라간다"
$P -c "update public.kashikiri_events set ticket_product_id=null where id='$EV'" >/dev/null
ok "직접 해제 → 0석" "0|0" "$($P -c "$LIVE")"
$P -c "update public.kashikiri_events set ticket_product_id='tp1' where id='$EV'" >/dev/null
ok "직접 연결 → 2석" "2|2" "$($P -c "$LIVE")"

echo "── ⑧ 권한: 매장 권한 없는 어드민은 막힌다"
r=$($P -c "select set_config('taam.uid','a1000000-0000-4000-8000-000000000009',false); select set_config('taam.super','',false); select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "42501" "1" "$(echo "$r" | grep -c '어드민만')"

echo "── ⑨ 링크 초대 청구는 KSK- 를 만들지 않는다"
$P -c "$S select public.taam_link_invite_create('tp1','Joy','+1 415 555 0100',1,'USD',1380,'2027.05.01','18:00')" >/dev/null 2>&1
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where link_invite" >/dev/null
ok "LINK 행 active 1 · KSK 행은 그대로 2" "1|2" "$($P -c "select count(*) from public.tickets where purchase_id like 'LINK-%' and status='active'")|$($P -c "select count(*) from public.tickets where purchase_id like 'KSK-%' and status='active'")"

[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
