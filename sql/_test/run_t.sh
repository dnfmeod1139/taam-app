#!/bin/bash
P="psql -h /tmp -U postgres -d postgres -q -t -A"
t(){ # 이름, uid, SQL, 기대(OK|FAIL)
  out=$($P -c "set role authenticated; select set_config('taam.uid','$2',false); $3" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then got=OK; else got=FAIL; fi
  if [ "$got" = "$4" ]; then echo "✅ $1"; else
    echo "❌ $1  (기대 $4, 실제 $got)"; echo "   $(echo "$out"|grep -i error|head -1)"; fi
}
MEM=11111111-1111-1111-1111-111111111111
ADM=22222222-2222-2222-2222-222222222222
OTH=33333333-3333-3333-3333-333333333333
SUP=99999999-9999-9999-9999-999999999999
T1=d0000001-0000-4000-8000-000000000001   # 지난 날짜 active
T2=d0000002-0000-4000-8000-000000000002   # 미래 날짜
T3=d0000003-0000-4000-8000-000000000003   # 취소됨
T4=d0000004-0000-4000-8000-000000000004   # 날짜가 '수동입력'

echo "── 가드 ──"
t "회원이 자기 visit_status 를 직접 못 바꾼다" $MEM \
  "update public.tickets set visit_status='attended' where id='$T1';" FAIL
t "회원의 정상 취소는 여전히 통과" $MEM \
  "update public.tickets set status='cancelled' where id='$T1';" OK
$P -c "update public.tickets set status='active' where id='$T1';" >/dev/null

echo "── 기록 권한 ──"
t "그 매장 어드민은 방문을 남긴다" $ADM \
  "select public.taam_set_ticket_visit('$T1','attended');" OK
t "다른 매장 어드민은 못 남긴다" $OTH \
  "select public.taam_set_ticket_visit('$T1','attended');" FAIL
t "회원 자신도 못 남긴다" $MEM \
  "select public.taam_set_ticket_visit('$T1','attended');" FAIL
t "슈퍼어드민은 남긴다" $SUP \
  "select public.taam_set_ticket_visit('$T1','attended');" OK

echo "── 거부 조건 ──"
t "미래 방문일은 거부" $ADM \
  "select public.taam_set_ticket_visit('$T2','attended');" FAIL
t "취소된 건은 거부" $ADM \
  "select public.taam_set_ticket_visit('$T3','attended');" FAIL
t "날짜 형식이 아니면 막지 않는다(수동입력)" $ADM \
  "select public.taam_set_ticket_visit('$T4','attended');" OK
t "이상한 상태값은 거부" $ADM \
  "select public.taam_set_ticket_visit('$T1','왔다감');" FAIL
t "기록 취소(null)는 가능" $ADM \
  "select public.taam_set_ticket_visit('$T1',null);" OK

echo "── 방문 횟수 ──"
$P -c "select public.taam_set_ticket_visit('$T1','attended');" >/dev/null 2>&1
$P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_set_ticket_visit('$T1','attended');" >/dev/null 2>&1
n=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_visit_count('$MEM','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');" | tail -1)
echo "   티켓 attended 2건(T1·T4) + 예약요청 1건 → 기대 3, 실제 $n"
[ "$n" = "3" ] && echo "✅ 티켓 + 예약요청을 합산" || echo "❌ 합산 결과가 다름"
t "회원은 자기 횟수를 본다" $MEM \
  "select public.taam_visit_count('$MEM','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');" OK
t "다른 매장 어드민은 남의 횟수를 못 본다" $OTH \
  "select public.taam_visit_count('$MEM','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');" FAIL
t "노쇼는 세지 않는다(기록만)" $ADM \
  "select public.taam_set_ticket_visit('$T4','no_show');" OK
n2=$($P -c "set role authenticated; select set_config('taam.uid','$ADM',false); select public.taam_visit_count('$MEM','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');" | tail -1)
echo "   T4 를 노쇼로 바꾼 뒤 → 기대 2, 실제 $n2"
[ "$n2" = "2" ] && echo "✅ 노쇼는 방문에서 빠진다" || echo "❌ 노쇼가 여전히 세어짐"
