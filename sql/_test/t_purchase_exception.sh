#!/usr/bin/env bash
# 구매 규정 예외(슈퍼어드민 협의 구매) 회귀 — supabase/migrations/20261022_purchase_rule_exception.sql (2026-10-22)
# 로컬 Postgres: psql -h /tmp -U postgres (trust). 실행: bash sql/_test/t_purchase_exception.sh
#   A. 독립 픽스처 — 실제 중복 가드(20261014)를 올리고 그 위에 이 파일 · 회원/슈퍼어드민 세션 · 초대 확정 모양
#   B. 결제 링크 픽스처(t_pay_link.sh 를 PL_KEEP 으로 남김) 위에 이 파일 — 선검사 치환 · 결제 뒤 소유자 이전
#   C. 모르는 판의 가드 → 건너뜀(❌)
cd "$(dirname "$0")/../.."
PSQL="psql -h /tmp -U postgres -X -q"
MIG=supabase/migrations/20261022_purchase_rule_exception.sql
DBA=t_pexc_a; DBB=t_pexc_pl; DBC=t_pexc_c
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
cls(){ if echo "$1" | grep -q DUPLICATE_PURCHASE; then echo DUPLICATE_PURCHASE; elif echo "$1" | grep -q TIME_CONFLICT; then echo TIME_CONFLICT; elif echo "$1" | grep -q ERROR; then echo "ERROR:$(echo "$1" | grep ERROR | head -1 | sed 's/^.*ERROR: *//' | cut -c1-60)"; else echo OK; fi; }

M=11111111-1111-1111-1111-111111111111; N=22222222-2222-2222-2222-222222222222; A=99999999-9999-9999-9999-999999999999; SU=88888888-8888-8888-8888-888888888888

fixture(){   # $1 = db
  $PSQL -c "drop database if exists $1" >/dev/null 2>&1; $PSQL -c "create database $1" >/dev/null
  $PSQL -d $1 -At >/dev/null 2>&1 <<SQL
create schema if not exists auth;
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
             if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
             if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if; end \$\$;
alter default privileges in schema public grant execute on functions to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable security definer set search_path = public as \$\$
begin
  if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if;
  return session_user = 'postgres' or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then return false; end \$\$;
create table public.profiles(id uuid primary key, display_name text, role text, membership_tier text, deleted_at timestamptz);
create table public.ticket_products(id text primary key, rest_id text, rest_name text, date text, time text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, reservation_date text, visit_time text, party_size int default 2, price bigint default 0, status text default 'hold', purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
grant usage on schema public, auth to authenticated, anon; grant all on all tables in schema public to authenticated;
insert into public.profiles values ('$M','회원M','user','M',null),('$N','회원N','user','T',null),('$A','어드민','admin',null,null),('$SU','슈퍼','superadmin','M',null);
insert into public.ticket_products values
 ('tp-a','r1','스시 사이토','2027.06.01','20:30'), ('tp-b','r2','다른매장','2027.06.01','19:00'), ('tp-c','r3','점심매장','2027.06.01','12:00'),
 ('tp-i','r4','세번째','2027.06.01','18:00'), ('tp-old','r5','지난매장','2020.01.05','19:00'), ('tp-y','r6','연도없음','06.01','19:00');
SQL
  $PSQL -d $1 -At -f supabase/migrations/20261014_purchase_uniqueness.sql >/dev/null 2>&1
  # 라이브 _taam_ticket_is_ops 는 20261018 판(회원 소유 LINK- · PAY 는 언제나 회원 행)
  $PSQL -d $1 -At >/dev/null 2>&1 <<'SQL'
create or replace function public._taam_ticket_is_ops(p_purchase_id text, p_extra jsonb)
returns boolean language sql immutable as $$
  select case when coalesce(p_purchase_id, '') ~ '^PAY' then false
         else (coalesce(p_purchase_id, '') ~ '^(KSK|MAN|INVH)-'
               or (coalesce(p_purchase_id, '') ~ '^LINK-' and coalesce(nullif(p_extra ->> 'memberUid', ''), '') = '')
               or coalesce(p_extra ->> 'manualEntry', '') in ('true','1')
               or coalesce(p_extra ->> 'inviteHold',  '') in ('true','1')
               or coalesce(p_extra ->> 'kashikiri',   '') in ('true','1')
               or (coalesce(p_extra ->> 'linkInvite',  '') in ('true','1') and coalesce(nullif(p_extra ->> 'memberUid', ''), '') = ''))
         end
$$;
SQL
}

echo "══ A. 독립 픽스처 (실제 가드 20261014 판 위)"
fixture $DBA
P="$PSQL -d $DBA -At"
ok "픽스처의 가드 본문 md5 = 저장소 20261014 판" "7e6c53a6513c61de94377047dbd94b64" "$($P -c "select md5(prosrc) from pg_proc where oid=to_regprocedure('public.taam_guard_purchase_unique()')")"
SUS="set taam.uid='$SU'; set taam.super='1';"
ins(){ o=$($P -c "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time, status, purchase_id, extra_data) values ('$1', (select rest_id from ticket_products where id='$2'), '매장', nullif('$2',''), nullif('$3',''), nullif('$4',''), '${6:-hold}', '$5', '${7:-{\}}'::jsonb);" 2>&1); cls "$o"; }
upd(){ o=$($P -c "update public.tickets set $1 where purchase_id='$2';" 2>&1); cls "$o"; }
mem(){ o=$($P -c "set taam.uid='$1'; set taam.super='0'; set role authenticated; $2" 2>&1); echo "$o"; }
grant(){ $P -c "$SUS select public.taam_purchase_exception_grant('$1', '$2', $3, $4, ${5:-1}, null, ${6:-'협의 — 일행 추가'})::text" 2>&1; }

ok "가드가 걸리기 전 상태: M 첫 홀드 → OK · 확정 → OK · 같은 회차 두 번째 → DUPLICATE_PURCHASE" "OK|OK|DUPLICATE_PURCHASE" "$(ins $M tp-a 2027.06.01 20:30 PAYH-1)|$(upd "status='active', price=1100000" PAYH-1)|$(ins $M tp-a 2027.06.01 20:30 PAYH-2)"

out=$($P -f $MIG 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0 · 가드 교체 · 결제 링크 없음(해당 없음)" "|0|1|1" "$(echo "$out" | grep -E "^ERROR|psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체 (옛 md5 7e6c53a6')|$(echo "$out" | grep -c '결제 링크 함수 없음')"
ok "확인 표 ①④⑤⑥ ✅" "4" "$(echo "$out" | grep -cE '^(① 표 둘|④ RPC|⑤ anon|⑥ 가드 트리거).*\|✅$')"

echo "── 예외 없으면 종전 그대로"
ok "예외 없음: 같은 회차 두 번째 → DUPLICATE_PURCHASE · 같은 날 저녁 다른 매장 → TIME_CONFLICT · 점심 → OK" "DUPLICATE_PURCHASE|TIME_CONFLICT|OK" "$(ins $M tp-a 2027.06.01 20:30 PAYH-2)|$(ins $M tp-b 2027.06.01 19:00 PAYH-3)|$(ins $M tp-c 2027.06.01 12:00 PAYH-4)"
$P -c "update public.tickets set status='cancelled' where purchase_id='PAYH-4'" >/dev/null

echo "── 허용 RPC 의 규칙"
ok "회원 세션은 허용 못 함 → FORBIDDEN" "1" "$(mem $M "select public.taam_purchase_exception_grant('$M','tp-a',true,false,1,null,'셀프')" | grep -c FORBIDDEN)"
ok "사유 없음 → NOTE_REQUIRED · 항목 없음 → KIND_REQUIRED · 지난 회차 → BAD_EXPIRES · 없는 회차 → TICKET_NOT_FOUND · 추가 6건 → BAD_EXTRA" "1|1|1|1|1" "$(grant $M tp-a true false 1 "''" | grep -c NOTE_REQUIRED)|$(grant $M tp-a false false | grep -c KIND_REQUIRED)|$(grant $M tp-old true false | grep -c BAD_EXPIRES)|$(grant $M tp-zz true false | grep -c TICKET_NOT_FOUND)|$(grant $M tp-a true false 6 | grep -c BAD_EXTRA)"
ok "탈퇴 회원 → MEMBER_NOT_FOUND" "1" "$($P -c "update public.profiles set deleted_at=now() where id='$N'" >/dev/null; grant $N tp-a true false | grep -c MEMBER_NOT_FOUND; $P -c "update public.profiles set deleted_at=null where id='$N'" >/dev/null)"
G1=$(grant $M tp-a true false 1)
ok "슈퍼어드민: M · 스시 사이토 · 같은 회차 추가 1건 → ok · 기본 기한 = 방문일 끝(KST 2027-06-02 00:00)" "true|2027-06-01 15:00:00+00" "$(echo "$G1" | grep -oE '"ok": (true|false)' | grep -oE 'true|false')|$($P -c "select expires_at at time zone 'UTC' || '+00' from public.purchase_rule_exceptions where user_id='$M' and ticket_product_id='tp-a' and revoked_at is null")"

echo "── 같은 회차 추가 구매"
ok "M 같은 회차 두 번째 홀드 → OK (예외)" "OK" "$(ins $M tp-a 2027.06.01 20:30 PAYH-2)"
ok "  → extra_data.ruleException = 예외 id · 사용 기록 1줄(dup · PAYH-2)" "1|1" "$($P -c "select count(*) from public.tickets t join public.purchase_rule_exceptions e on e.id::text = t.extra_data->>'ruleException' where t.purchase_id='PAYH-2'")|$($P -c "select count(*) from public.purchase_rule_exception_uses where purchase_id='PAYH-2' and kind='dup'")"
ok "  → 두 번째 홀드 확정(hold → active · 열쇠 그대로) → OK" "OK" "$(upd "status='active', price=1100000" PAYH-2)"
ok "세 번째(추가 허용 1건 초과) → DUPLICATE_PURCHASE" "DUPLICATE_PURCHASE" "$(ins $M tp-a 2027.06.01 20:30 PAYH-5)"
ok "같은 회차 추가는 다른 회차의 같은 시간대를 열지 않는다 — 같은 날 저녁 다른 매장 → TIME_CONFLICT" "TIME_CONFLICT" "$(ins $M tp-b 2027.06.01 19:00 PAYH-6)"
ok "다른 회원 N 은 M 의 예외와 무관 — N 첫 OK · 두 번째 DUPLICATE_PURCHASE" "OK|DUPLICATE_PURCHASE" "$(ins $N tp-a 2027.06.01 20:30 PAYH-N1)|$(ins $N tp-a 2027.06.01 20:30 PAYH-N2)"
ok "M 이 하나를 취소하면 같은 회차 하나 더 → OK (살아 있는 행으로 센다)" "OK|OK" "$(upd "status='cancelled'" PAYH-2)|$(ins $M tp-a 2027.06.01 20:30 PAYH-7)"
ok "toss-confirm 폴백 모양(PAYC- · 날짜·시각 비움 · active) 도 같은 규칙 — 추가 1건이 이미 찼으니 DUPLICATE_PURCHASE" "DUPLICATE_PURCHASE" "$(ins $M tp-a '' '' PAYC-8 active)"

echo "── 같은 날 같은 시간대"
G2=$(grant $M tp-b false true 1)
ok "M · 다른매장 19:00 에 time 예외 → 같은 날 저녁 → OK · 사용 기록(time)" "OK|1" "$(ins $M tp-b 2027.06.01 19:00 PAYH-9)|$($P -c "select count(*) from public.purchase_rule_exception_uses where purchase_id='PAYH-9' and kind='time'")"
ok "time 예외는 그 회차만 — 세번째 매장 18:00 → TIME_CONFLICT · 그 회차 두 번째(dup 아님) → DUPLICATE_PURCHASE" "TIME_CONFLICT|DUPLICATE_PURCHASE" "$(ins $M tp-i 2027.06.01 18:00 PAYH-10)|$(ins $M tp-b 2027.06.01 19:00 PAYH-11)"
ok "dup 예외만 있는 회차(tp-i)는 다른 회차와 겹치면 여전히 TIME_CONFLICT" "TIME_CONFLICT" "$(grant $M tp-i true false >/dev/null; ins $M tp-i 2027.06.01 18:00 PAYH-12)"

echo "── 초대 확정 모양 (INVH- 어드민 홀드 → INV- 회원 소유 UPDATE)"
ok "N 에게 같은 회차 초대 홀드(INVH · 어드민 소유) → OK · 확정(소유자 N) → DUPLICATE_PURCHASE (예외 없음)" "OK|DUPLICATE_PURCHASE" "$(ins $A tp-a 2027.06.01 20:30 INVH-n1 hold '{"inviteHold":true}')|$(upd "user_id='$N', status='active', purchase_id='INV-n1', extra_data='{\"inviteHold\":false}'::jsonb" INVH-n1)"
grant $N tp-a true false >/dev/null
ok "  → N 에게 dup 예외 → 같은 확정 → OK · 사용 기록(INV-n1)" "OK|1" "$(upd "user_id='$N', status='active', purchase_id='INV-n1', extra_data='{\"inviteHold\":false}'::jsonb" INVH-n1)|$($P -c "select count(*) from public.purchase_rule_exception_uses where purchase_id='INV-n1'")"

echo "── 기한 · 해제 · 대체"
$P -c "update public.purchase_rule_exceptions set expires_at = now() - interval '1 minute' where user_id='$M' and ticket_product_id='tp-a' and revoked_at is null" >/dev/null
ok "기한 지난 예외 → 다시 막힘 (M 같은 회차 취소 뒤 재구매: 추가 1건 자리가 있어도)" "OK|DUPLICATE_PURCHASE" "$(upd "status='cancelled'" PAYH-7)|$(ins $M tp-a 2027.06.01 20:30 PAYH-13)"
G3=$(grant $M tp-a true false 2)
ok "다시 허용(추가 2) → OK(같은 저녁의 다른매장 19:00 은 그 회차 time 예외라 겹침으로 안 센다 — 예외는 양쪽) · 같은 회원·회차의 살아 있는 예외는 하나만(대체)" "OK|1" "$(ins $M tp-a 2027.06.01 20:30 PAYH-13)|$($P -c "select count(*) from public.purchase_rule_exceptions where user_id='$M' and ticket_product_id='tp-a' and revoked_at is null and expires_at > now()")"
G4=$(grant $M tp-a true false 2)
ok "  두 번째 허용 → replaced 1 · 옛 줄 「새 예외로 대체」" "1|1" "$(echo "$G4" | grep -oE '"replaced": [0-9]+' | grep -oE '[0-9]+$')|$($P -c "select count(*) from public.purchase_rule_exceptions where user_id='$M' and ticket_product_id='tp-a' and revoke_note='새 예외로 대체' and created_at > now() - interval '1 minute'")"
EID=$($P -c "select id from public.purchase_rule_exceptions where user_id='$M' and ticket_product_id='tp-a' and revoked_at is null and expires_at > now()")
ok "해제 → ok · 다시 해제 → already_revoked · 없는 id → not_found · 해제 뒤 → DUPLICATE_PURCHASE · 이미 산 것은 그대로(active)" "true|already_revoked|not_found|DUPLICATE_PURCHASE|active" "$($P -c "$SUS select (public.taam_purchase_exception_revoke('$EID','협의 취소')->>'ok')")|$($P -c "$SUS select (public.taam_purchase_exception_revoke('$EID')->>'error')")|$($P -c "$SUS select (public.taam_purchase_exception_revoke(gen_random_uuid())->>'error')")|$(ins $M tp-a 2027.06.01 20:30 PAYH-14)|$($P -c "select status from public.tickets where purchase_id='PAYH-1'")"
ok "회원 세션은 해제 못 함 → FORBIDDEN" "1" "$(mem $M "select public.taam_purchase_exception_revoke('$EID')" | grep -c FORBIDDEN)"

echo "── 회원이 보는 것 · 못 하는 것"
ok "M: 내 예외 = 살아 있는 것만(해제·기한 지남 빠짐) · 열쇠만(사유·만든 사람 없음)" "tp-b:false:true,tp-i:true:false|f" "$(mem $M "select string_agg((e->>'ticket_product_id')||':'||(e->>'allow_dup')||':'||(e->>'allow_time'), ',' order by e->>'ticket_product_id') from jsonb_array_elements(public.taam_my_purchase_exceptions()) e" | tail -1)|$(mem $M "select coalesce(bool_or(e ? 'note' or e ? 'created_by'), false) from jsonb_array_elements(public.taam_my_purchase_exceptions()) e" | tail -1)"
ok "N: 남의 예외는 안 보인다(자기 것만 1)" "1|tp-a" "$(mem $N "select jsonb_array_length(public.taam_my_purchase_exceptions())" | tail -1)|$(mem $N "select (public.taam_my_purchase_exceptions()->0)->>'ticket_product_id'" | tail -1)"
ok "회원은 표를 직접 못 읽는다(0행) · 못 쓴다(권한 거절) · 사용 기록도 0행" "0|1|0" "$(mem $M "select count(*) from public.purchase_rule_exceptions" | tail -1)|$(mem $M "insert into public.purchase_rule_exceptions(user_id,ticket_product_id,allow_dup,expires_at,note) values ('$M','tp-c',true,now()+interval '1 day','셀프')" | grep -c 'permission denied')|$(mem $M "select count(*) from public.purchase_rule_exception_uses" | tail -1)"
ok "회원은 목록·미리보기 RPC 를 못 부른다 → FORBIDDEN" "1|1" "$(mem $M "select public.taam_purchase_exception_list()" | grep -c FORBIDDEN)|$(mem $M "select public.taam_purchase_exception_preview('$M','tp-a')" | grep -c FORBIDDEN)"
ok "anon 은 내 예외 RPC 실행 권한 없음 · authenticated 는 판정 도우미 실행 권한 없음" "f|f" "$($P -c "select has_function_privilege('anon','public.taam_my_purchase_exceptions()','execute')")|$($P -c "select has_function_privilege('authenticated','public._taam_purchase_exc_find(uuid,text,text,integer)','execute')")"

echo "── 목록 · 미리보기"
L=$($P -c "$SUS select public.taam_purchase_exception_list('$M', true)::text")
ok "목록(M · 닫힌 것 포함): 상태 셋(active·expired·revoked) · 사용 기록에 구매 상태 · 회차 이름" "1|1|1|1|1" "$(echo "$L" | grep -c '"state": "active"')|$(echo "$L" | grep -c '"state": "expired"')|$(echo "$L" | grep -c '"state": "revoked"')|$($P -c "$SUS select count(*) from jsonb_array_elements(public.taam_purchase_exception_list('$M', true)) e, jsonb_array_elements(e->'uses') u where u->>'purchase_id'='PAYH-9' and u->>'status'='hold' and u->>'kind'='time'")|$(echo "$L" | grep -c '"rest": "다른매장"')"
ok "목록 기본은 살아 있는 것만" "2" "$($P -c "$SUS select jsonb_array_length(public.taam_purchase_exception_list('$M'))")"
PV=$($P -c "$SUS select public.taam_purchase_exception_preview('$M','tp-i')::text")
ok "미리보기(M · 세번째 18:00): 같은 회차 0 · 같은 시간대 = 사이토 둘·다른매장 하나(그 회차 time 예외라 excused) · 살아 있는 예외 1(dup)" "0|3|1|1" "$($P -c "$SUS select jsonb_array_length(public.taam_purchase_exception_preview('$M','tp-i')->'same_ticket')")|$($P -c "$SUS select jsonb_array_length(public.taam_purchase_exception_preview('$M','tp-i')->'same_slot')")|$($P -c "$SUS select jsonb_array_length(public.taam_purchase_exception_preview('$M','tp-i')->'active')")|$($P -c "$SUS select count(*) from jsonb_array_elements(public.taam_purchase_exception_preview('$M','tp-i')->'same_slot') r where (r->>'excused')::boolean")"

echo "── 그대로여야 하는 것"
ok "남의 user_id 로 넣는 회원 세션은 여전히 침묵(OK — 소유권 가드의 몫)" "OK" "$(cls "$(mem $N "insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,status,purchase_id) values ('$M','r1','매장','tp-a','2027.06.01','20:30','hold','PAYH-X1')")")"
$P -c "delete from public.tickets where purchase_id='PAYH-X1'" >/dev/null
ok "운영 행(MAN-)은 여전히 제외 → OK" "OK" "$(ins $M tp-a 2027.06.01 20:30 MAN-1 manual '{"manualEntry":true}')"
ok "extra_data 가 배열인 행도 통과(예외 표시만 못 붙인다)" "OK|array" "$(ins $N tp-c 2027.06.01 12:00 PAYH-N3 hold '[1]')|$($P -c "select jsonb_typeof(extra_data) from public.tickets where purchase_id='PAYH-N3'")"
out2=$($P -f $MIG 2>&1)
ok "두 번째 RUN: 오류 없음 · ❌ 0 · 「이미 새 판」" "|0|1" "$(echo "$out2" | grep -E "^ERROR|psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep -c '② 중복 가드 교체.*이미 새 판')"
ok "두 번째 RUN 뒤에도 예외·사용 기록은 그대로" "1" "$($P -c "select (count(*) > 3)::int from public.purchase_rule_exception_uses")"

echo "══ B. 결제 링크 픽스처 위"
PLO=$(PL_DB=$DBB PL_KEEP=1 bash sql/_test/t_pay_link.sh 2>&1 | tail -1)
ok "결제 링크 회귀(기반) 통과" "=== 전부 통과 ===" "$PLO"
Q="$PSQL -d $DBB -At"
SU2=a1000000-0000-4000-8000-000000000001; M3=a1000000-0000-4000-8000-000000000003
S2="set taam.uid='$SU2'; set taam.super='1';"
$Q -c "create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable security definer set search_path = public as \$\$ begin if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if; return session_user = 'postgres'; end \$\$;" >/dev/null 2>&1
ok "픽스처의 결제 링크 만들기 md5 = 라이브(350c0c48…)" "350c0c486abf2fe012a49025e23431c0" "$($Q -c "select md5(prosrc) from pg_proc where oid=to_regprocedure('public.taam_pay_link_create(text,jsonb)')")"
outb=$($Q -f $MIG 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0 · 가드 교체 · 선검사 교체" "|0|1|1" "$(echo "$outb" | grep -E "^ERROR|psql:.*ERROR" | head -1)|$(echo "$outb" | grep -c '❌')|$(echo "$outb" | grep -c '② 중복 가드 교체.*✅ 교체')|$(echo "$outb" | grep -c '③ 결제 링크 선검사.*✅ 교체')"
plc(){ $Q -c "$S2 select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','$1','name','$2','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','$3','user_id','$M3'))::text" 2>&1; }
ok "예외 없음: M3 같은 회차(tp1) 링크 → DUPLICATE_PURCHASE · 같은 날 저녁 다른 회차(tp2) → TIME_CONFLICT" "1|1" "$(plc tp1 Again 18:00 | grep -c DUPLICATE_PURCHASE)|$(plc tp2 Eve 19:30 | grep -c TIME_CONFLICT)"
$Q -c "$S2 select public.taam_purchase_exception_grant('$M3','tp1',true,false,1,now()+interval '2 days','일행 추가 협의')" >/dev/null 2>&1
R=$(plc tp1 Again 18:00); CB=$(echo "$R" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "dup 예외 → 같은 회차 링크 만들어짐 · 같은 날 저녁 다른 회차는 여전히 TIME_CONFLICT" "1|1" "$([ -n "$CB" ] && echo 1 || echo "$R" | head -2)|$(plc tp2 Eve 19:30 | grep -c TIME_CONFLICT)"
$Q -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pkX', payer_name='Again' where id='$CB'" >/dev/null 2>&1
ok "  결제 → 소유자 이전이 가드를 통과 · M3 소유 active · memberUidPending 없음 · ruleException · 사용 기록" "active|$M3||1|1" "$($Q -c "select status||'|'||user_id||'|'||coalesce(extra_data->>'memberUidPending','')||'|'||(extra_data ? 'ruleException')::int from public.tickets where extra_data->>'chargeId'='$CB'")|$($Q -c "select count(*) from public.purchase_rule_exception_uses u join public.tickets t on t.purchase_id = u.purchase_id where t.extra_data->>'chargeId'='$CB'")"
$Q -c "$S2 select public.taam_purchase_exception_grant('$M3','tp2',false,true,1,now()+interval '2 days','같은 저녁 두 매장 협의')" >/dev/null 2>&1
ok "time 예외 → 같은 날 저녁 다른 회차(tp2) 링크 만들어짐" "ticket" "$($Q -c "$S2 select j->>'purpose' from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp2','name','Eve','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','19:30','user_id','$M3')) j" 2>&1)"
outb2=$($Q -f $MIG 2>&1)
ok "두 번째 RUN: ❌ 0 · 가드·선검사 둘 다 「이미 새 판」" "0|2" "$(echo "$outb2" | grep -c '❌')|$(echo "$outb2" | grep -cE '(② 중복 가드 교체|③ 결제 링크 선검사).*이미 새 판')"
$PSQL -c "drop database if exists $DBB" >/dev/null 2>&1

echo "══ C. 모르는 판"
fixture $DBC
R3="$PSQL -d $DBC -At"
$R3 -c "do \$\$ declare d text := pg_get_functiondef('public.taam_guard_purchase_unique()'::regprocedure); begin execute replace(d, 'v_old_tp   text;', 'v_old_tp   text;  -- 대시보드에서 손댄 판'); end \$\$;" >/dev/null 2>&1
outc=$($R3 -f $MIG 2>&1)
ok "가드 본문이 알려진 두 판이 아니면 건너뛰고 ❌ · 가드는 그대로(예외 모름)" "1|0" "$(echo "$outc" | grep -c '② 중복 가드 교체.*❌ 라이브 본문이 알려진 판과 다르다')|$($R3 -c "select (prosrc like '%_taam_purchase_exc_find%')::int from pg_proc where oid=to_regprocedure('public.taam_guard_purchase_unique()')")"
$PSQL -c "drop database if exists $DBC" >/dev/null 2>&1
$PSQL -c "drop database if exists $DBA" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
