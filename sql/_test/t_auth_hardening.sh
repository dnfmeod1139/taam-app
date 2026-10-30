#!/bin/bash
# 가입·초대·프로필 연락처 강화 (supabase/migrations/20261030_auth_hardening.sql) 재보기. 먼저: 로컬 pg. 실행: bash sql/_test/t_auth_hardening.sh
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d ${TAAM_TEST_DB:-postgres} -q -t -A -X"
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
T=$(mktemp -d)
$P -v ON_ERROR_STOP=1 -f sql/_test/fx_auth_hardening.sql >/dev/null 2>$T/err || { echo "❌ 픽스처"; head -3 $T/err; exit 1; }
# 옛 라이브: 문지기(sql/signup_guard.sql) · 게스트 붙이기(20261019) · 등급(audit5)
$P -v ON_ERROR_STOP=1 -f sql/signup_guard.sql >/dev/null 2>$T/err || { echo "❌ 옛 문지기"; head -3 $T/err; exit 1; }
{ sed -n '/^create or replace function public._taam_guest_invite_code/,/^  for each row execute function public.taam_guest_invite_on_paid();/p' supabase/migrations/20261019_guest_invite.sql
  sed -n '/^create or replace function public.taam_guest_attach_tickets/,/^  for each row execute function public.taam_guest_attach_on_profile();/p' supabase/migrations/20261019_guest_invite.sql; } > $T/guest.sql
$P -v ON_ERROR_STOP=1 -f $T/guest.sql >/dev/null 2>$T/err || { echo "❌ 게스트 붙이기"; head -3 $T/err; exit 1; }
sed -n '/^create or replace function public.taam_invited_tier/,/^\$\$;/p' sql/audit5_hardening_2026-09-14.sql > $T/tier.sql
$P -v ON_ERROR_STOP=1 -f $T/tier.sql >/dev/null 2>$T/err || { echo "❌ 등급"; head -3 $T/err; exit 1; }
SUPER=00000000-0000-0000-0000-00000000000a
A=00000000-0000-0000-0000-0000000000a1   # 이메일 가입 회원(공격자)
B=00000000-0000-0000-0000-0000000000b1   # 번호 가입 회원
$P -v ON_ERROR_STOP=1 >/dev/null <<SQL
insert into auth.users(id,email,phone,email_confirmed_at,phone_confirmed_at,last_sign_in_at) values
 ('$SUPER','dnfmeod@playtaam.com',null,now(),null,now()),
 ('$A','att@x.com',null,now(),null,now()),
 ('$B',null,'821077778888',null,now(),now());
update public.profiles set role='super_admin' where id='$SUPER';
insert into public.invite_codes(code,invitee_name,invitee_phone,invitee_email,invitee_tier,invited_by,used,used_at,used_by_email,used_by_phone,member_id,country) values
 ('AAAA0001','에이',null,'att@x.com','T','admin',true,now(),'att@x.com',null,'$A','EN'),
 ('BBBB0001','비','010-7777-8888',null,'M','admin',true,now(),null,'010-7777-8888',null,'KR'),
 ('PHON0001','홍길동','010-1111-2222',null,'M','admin',false,null,null,null,null,'KR'),
 ('MAIL0001','Kim',null,'kim@x.com','T','admin',false,null,null,null,null,'EN'),
 ('OPEN0001','',null,null,'T','admin',false,null,null,null,null,'KR'),
 ('USED0001','',null,'old@x.com','T','admin',true,now(),'old@x.com',null,null,'EN'),
 ('EXPD0001','','010-3333-4444',null,'T','admin',false,null,null,null,null,'KR'),
 ('GST00001','손님','010-5555-1234',null,'A','pay_link',false,null,null,null,null,'KR'),
 ('GSTEN002','Guest','+1 415 555 0100',null,'A','pay_link',false,null,null,null,null,'EN'),
 ('GSTEN003','Guest3','+44 20 7946 0000',null,'A','pay_link',false,null,null,null,null,'EN'),
 ('GSTEN004','Guest4','+81 90 1234 5678',null,'A','pay_link',false,null,null,null,null,'EN'),
 ('GSTKR005','손님5','010-6666-7777',null,'A','pay_link',false,null,null,null,null,'KR');
update public.invite_codes set expires_at = now() - interval '1 day' where code='EXPD0001';
update public.app_config set value = jsonb_build_object('mode','enforce') where key='signup_guard';
delete from public.signup_guard_log;
insert into public.kashikiri_charges(id,link_invite,status,user_id,payer_phone,payload) values
 ('11111111-1111-1111-1111-111111111111',true,'paid',null,'010-5555-1234','{"guest_invite_code":"GST00001"}');
insert into public.kashikiri_charges(id,link_invite,status,user_id,payer_phone,payload) values
 ('22222222-2222-2222-2222-222222222222',true,'paid',null,'+1 415 555 0100','{"guest_invite_code":"GSTEN002"}'),
 ('33333333-3333-3333-3333-333333333333',true,'paid',null,'+44 20 7946 0000','{"guest_invite_code":"GSTEN003"}');
insert into public.tickets(purchase_id,user_id,status,extra_data) values ('LINK-1',null,'active','{"chargeId":"11111111-1111-1111-1111-111111111111"}'),
 ('LINK-2',null,'active','{"chargeId":"22222222-2222-2222-2222-222222222222"}'),
 ('LINK-3',null,'active','{"chargeId":"33333333-3333-3333-3333-333333333333"}');
SQL

# ins <email> <phone> <meta json> <app json> → 마지막 판정 verdict:reason · 거절이면 ERR:사유
ins(){ local o; o=$($P -c "insert into auth.users(email,phone,raw_user_meta_data,raw_app_meta_data) values ($1,$2,'$3'::jsonb,'$4'::jsonb);" 2>&1); if echo "$o" | grep -q "ERROR"; then echo "ERR:$(echo "$o" | grep -oE 'SIGNUP_NOT_INVITED: [a-z_]*|SIGNUP_GUARD_ERROR' | head -1)"; else $P -c "select verdict||':'||reason from public.signup_guard_log order by id desc limit 1;" | tail -1; fi; }
as_user(){ $P -c "set role authenticated; set request.jwt.claims = '{\"sub\":\"$1\",\"role\":\"authenticated\"}'; $2" 2>&1 | grep -v '^CONTEXT\|^WARNING\|^LINE\|^ *\^' | tail -1; }
as_svc(){ $P -c "set role service_role; set request.jwt.claims = '{\"role\":\"service_role\"}'; $1" 2>&1 | grep -v '^CONTEXT\|^WARNING\|^LINE\|^ *\^' | tail -1; }
as_anon(){ $P -c "set role anon; set request.jwt.claims = '{\"role\":\"anon\"}'; $1" 2>&1 | tail -1; }
q(){ $P -c "$1" | tail -1; }

echo "── 고치기 전(옛 라이브) — 구멍이 실제로 있다"
ok "옛: 번호에 묶인 코드를 이메일 OTP 로 → 통과" "allow:invite_code" "$(ins "'evil1@x.com'" "null" '{"invite_code":"PHON0001"}' '{"provider":"email"}')"
ok "옛: 이메일 가입 + 메타데이터 번호 = 초대 번호 → 통과" "allow:invite_code" "$(ins "'evil2@x.com'" "null" '{"invite_code":"PHON0001","phone":"010-1111-2222"}' '{"provider":"email"}')"
ok "옛: 코드 없이 이미 쓴 초대장 이메일과 일치 → 통과(두 번째 계정)" "allow:invitee_match" "$(ins "'old@x.com'" "null" '{}' '{"provider":"google"}')"
ok "옛: 묶임 없는 코드 → 아무 채널로 통과" "allow:invite_code" "$(ins "'evil3@x.com'" "null" '{"invite_code":"OPEN0001"}' '{"provider":"email"}')"
ok "옛: 파트너 도메인은 누구나" "allow:partner_domain" "$(ins "'p-evil@partner.taam.kr'" "null" '{}' '{"provider":"email"}')"
ok "옛: 메타데이터 이름의 태그가 그대로 auth 에" "allow:invite_code" "$(ins "'evil4@x.com'" "null" '{"invite_code":"OPEN0001","display_name":"<img src=x onerror=alert(1)>"}' '{"provider":"email"}')"
ok "  … raw_user_meta_data.display_name 에 태그 그대로" "1" "$(q "select count(*) from auth.users where raw_user_meta_data->>'display_name' like '<img%';")"
$P -c "delete from auth.users where email like 'evil%' or email in ('old@x.com','p-evil@partner.taam.kr'); delete from public.profiles where id not in (select id from auth.users);" >/dev/null
ok "옛: 회원이 남의 초대장까지 전부 읽는다" "12" "$(as_user $A "select count(*) from public.invite_codes;")"
ok "옛: 회원이 자기 profiles 번호를 아무 값으로" "1234" "$(as_user $A "update public.profiles set phone='1234' where id='$A'; select phone from public.profiles where id='$A';")"
ok "옛: 그 번호로 자기 소진 → 게스트 초대장까지 소진(부분 일치)" "t" "$(as_user $A "select consume_invite_by_self() >= 1;")"
ok "옛: 결제된 손님 좌석이 공격자에게 붙었다 ⭐" "$A" "$(q "select user_id from public.tickets where purchase_id='LINK-1';")"
# 되돌려 놓고 새 판을 올린다
$P -v ON_ERROR_STOP=1 >/dev/null <<SQL
update public.tickets set user_id=null, extra_data=jsonb_build_object('chargeId', extra_data->>'chargeId') where purchase_id like 'LINK-%';
update public.kashikiri_charges set user_id=null, payload=jsonb_build_object('guest_invite_code', payload->>'guest_invite_code');
update public.invite_codes set used=false, used_at=null, used_by_email=null, used_by_phone=null, used_by_name=null, member_id=null
 where code in ('PHON0001','MAIL0001','OPEN0001','EXPD0001','GST00001','GSTEN002','GSTEN003','GSTEN004','GSTKR005');
update public.profiles set phone=null where id='$A';
SQL

echo "── 새 판 적용"
$P -v ON_ERROR_STOP=1 -f supabase/migrations/20261030_auth_hardening.sql >$T/out 2>$T/err || { echo "❌ 적용 실패"; grep -i error $T/err | head -5; exit 1; }
ok "확인 표 ❌ 없음" 0 "$(grep -c '❌' $T/out)"
$P -v ON_ERROR_STOP=1 -f supabase/migrations/20261030_auth_hardening.sql >$T/out2 2>$T/err || { echo "❌ 2회 실행 실패"; FAIL=1; }
ok "두 번 돌려도 ❌ 없음" 0 "$(grep -c '❌' $T/out2)"
ok "  … 지금 회원 로그인 대조(정보) 줄이 있다" 1 "$(grep -c '⑧ 지금 회원' $T/out)"

echo "── ① 문지기"
ok "번호 코드 + 이메일 OTP → 거절(채널 불일치) ⭐" "ERR:SIGNUP_NOT_INVITED: channel_mismatch" "$(ins "'evil1@x.com'" "null" '{"invite_code":"PHON0001"}' '{"provider":"email"}')"
ok "메타데이터 번호는 안 본다 ⭐" "ERR:SIGNUP_NOT_INVITED: channel_mismatch" "$(ins "'evil2@x.com'" "null" '{"invite_code":"PHON0001","phone":"010-1111-2222"}' '{"provider":"email"}')"
ok "번호 코드 + 다른 번호 → 거절" "ERR:SIGNUP_NOT_INVITED: phone_mismatch" "$(ins "null" "'821099990000'" '{"invite_code":"PHON0001"}' '{"provider":"phone"}')"
ok "이메일 코드 + 번호 OTP → 거절" "ERR:SIGNUP_NOT_INVITED: channel_mismatch" "$(ins "null" "'821066665555'" '{"invite_code":"MAIL0001"}' '{"provider":"phone"}')"
ok "이메일 코드 + 다른 이메일 → 거절" "ERR:SIGNUP_NOT_INVITED: email_mismatch" "$(ins "'other@x.com'" "null" '{"invite_code":"MAIL0001"}' '{"provider":"email"}')"
ok "묶임 없는 코드 → 거절 ⭐" "ERR:SIGNUP_NOT_INVITED: invite_unbound" "$(ins "'evil3@x.com'" "null" '{"invite_code":"OPEN0001"}' '{"provider":"email"}')"
ok "사용된 코드" "ERR:SIGNUP_NOT_INVITED: code_used" "$(ins "'x1@x.com'" "null" '{"invite_code":"USED0001"}' '{"provider":"email"}')"
ok "만료된 코드" "ERR:SIGNUP_NOT_INVITED: code_expired" "$(ins "null" "'821033334444'" '{"invite_code":"EXPD0001"}' '{"provider":"phone"}')"
ok "없는 코드" "ERR:SIGNUP_NOT_INVITED: code_not_found" "$(ins "'x2@x.com'" "null" '{"invite_code":"ZZZZ9999"}' '{"provider":"email"}')"
ok "코드 없이 이미 쓴 초대장과 일치 → 거절 ⭐" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "'old@x.com'" "null" '{}' '{"provider":"google"}')"
ok "소셜 · 안 쓴 초대장 이메일 · 제공자 미확인 → 거절" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "'kim@x.com'" "null" '{"email_verified":false}' '{"provider":"kakao"}')"
ok "파트너 도메인 · 발급 예약 없음 → 거절 ⭐" "ERR:SIGNUP_NOT_INVITED: partner_not_registered" "$(ins "'p-evil@partner.taam.kr'" "null" '{}' '{"provider":"email"}')"
$P -c "insert into public.partner_signup_allow(email, created_at) values ('p-old@partner.taam.kr', now() - interval '11 minutes');" >/dev/null
ok "파트너 도메인 · 10분 넘은 예약 → 거절" "ERR:SIGNUP_NOT_INVITED: partner_not_registered" "$(ins "'p-old@partner.taam.kr'" "null" '{}' '{"provider":"email"}')"
N0=$($P -c "select count(*) from auth.users;" | tail -1)
ok "  … 거절은 계정을 안 만든다" "$N0" "$($P -c "select count(*) from auth.users;" | tail -1)"
ok "정상 · 번호 코드 + 같은 번호" "allow:invite_code" "$(ins "null" "'821011112222'" '{"invite_code":"phon0001","display_name":"홍<b>길동</b>","phone":"010-0000-0000"}' '{"provider":"phone"}')"
ok "  … 메타데이터 이름의 꺾쇠를 지웠다" "홍b길동/b" "$(q "select raw_user_meta_data->>'display_name' from auth.users where phone='821011112222';")"
ok "  … 메타데이터 번호 키는 버렸다" "f" "$(q "select raw_user_meta_data ? 'phone' from auth.users where phone='821011112222';")"
ok "  … profiles 표시 이름 — 라이브 순서에선 handle_new_user 가 먼저 줄을 만들어 비어 있다" "" "$(q "select coalesce(p.display_name,'') from public.profiles p join auth.users u on u.id=p.id where u.phone='821011112222';")"
ok "정상 · 이메일 코드 + 같은 이메일(대소문자)" "allow:invite_code" "$(ins "'KIM@x.com'" "null" '{"invite_code":"MAIL0001","display_name":"javascript:alert(1)"}' '{"provider":"email"}')"
ok "  … javascript: 를 지웠다(메타데이터)" "alert(1)" "$(q "select raw_user_meta_data->>'display_name' from auth.users where email='KIM@x.com';")"
$P -c "delete from auth.users where email='KIM@x.com'; delete from public.profiles where email='KIM@x.com'; alter table auth.users disable trigger on_auth_user_created;" >/dev/null
ok "동기화 함수가 줄을 만들 때도 정리(트리거 순서가 바뀌어도)" "allow:invite_code" "$(ins "'KIM@x.com'" "null" '{"invite_code":"MAIL0001","display_name":"<svg/onload=1>김"}' '{"provider":"email"}')"
ok "  … profiles.display_name 정리" "svg/onload=1김" "$(q "select display_name from public.profiles where email='KIM@x.com';")"
$P -c "alter table auth.users enable trigger on_auth_user_created;" >/dev/null
$P -c "delete from auth.users where email='KIM@x.com'; delete from public.profiles where email='KIM@x.com';" >/dev/null
ok "소셜 · 안 쓴 초대장 이메일 · 제공자 확인 → 통과" "allow:invitee_match" "$(ins "'kim@x.com'" "null" '{"email_verified":true}' '{"provider":"google"}')"
$P -c "delete from auth.users where email='kim@x.com'; delete from public.profiles where email='kim@x.com';" >/dev/null
$P -c "insert into public.partner_signup_allow(email) values ('r-001@partner.taam.kr');" >/dev/null
ok "파트너 도메인 · 발급 예약 있음 → 통과" "allow:partner_domain" "$(ins "'r-001@partner.taam.kr'" "null" '{}' '{"provider":"email"}')"
ok "  … 예약은 한 번 쓰면 지워진다" 0 "$(q "select count(*) from public.partner_signup_allow where email='r-001@partner.taam.kr';")"
ok "슈퍼어드민 화이트리스트" "allow:super_whitelist" "$(ins "'DNFMEOD@playtaam.com'" "null" '{}' '{"provider":"email"}')"
$P -c "delete from auth.users where email='DNFMEOD@playtaam.com'; delete from public.profiles where id not in (select id from auth.users);" >/dev/null
$P -c "alter table public.invite_codes rename column invitee_phone to invitee_phone_x;" >/dev/null
ok "enforce · 판정 오류 → 거절 ⭐" "ERR:SIGNUP_GUARD_ERROR" "$(ins "'z@x.com'" "null" '{"invite_code":"MAIL0001"}' '{"provider":"email"}')"
$P -c "update public.app_config set value = jsonb_build_object('mode','log') where key='signup_guard';" >/dev/null
ok "log · 판정 오류 → 기록만" "error" "$(ins "'z2@x.com'" "null" '{"invite_code":"MAIL0001"}' '{"provider":"email"}' | cut -d: -f1)"
$P -c "update public.app_config set value = jsonb_build_object('mode','enforce') where key='signup_guard'; alter table public.invite_codes rename column invitee_phone_x to invitee_phone; delete from auth.users where email='z2@x.com'; delete from public.profiles where email='z2@x.com';" >/dev/null

echo "── ② 초대 소진"
ok "회원(공격자)이 자기 profiles 번호를 남의 것으로 → 되돌림 ⭐" "" "$(as_user $A "update public.profiles set phone='010-5555-1234' where id='$A'; select coalesce(phone,'') from public.profiles where id='$A';")"
ok "  … 같은 UPDATE 의 다른 칸은 그대로" "새이름" "$(as_user $A "update public.profiles set phone='1234', display_name='새이름' where id='$A'; select display_name from public.profiles where id='$A';")"
ok "자기 소진 · 공격자 → 게스트 초대장 안 건드림 ⭐" "0" "$(as_user $A "select consume_invite_by_self();")"
ok "  … 게스트 초대장 그대로 미사용" "f" "$(q "select used from public.invite_codes where code='GST00001';")"
ok "  … 손님 좌석 그대로" "" "$(q "select coalesce(user_id::text,'') from public.tickets where purchase_id='LINK-1';")"
ok "Edge(service_role) 소진 · 손님 계정 없음 → 거절 ⭐" "INVITE_OWNER_UNVERIFIED" "$(as_svc "update public.invite_codes set used=true, used_by_email='att@x.com', used_by_phone='010-5555-1234' where code='GST00001' and used=false;" | grep -oE 'INVITE_OWNER_UNVERIFIED' | head -1)"
G=00000000-0000-0000-0000-0000000000c1
$P -c "insert into public.partner_signup_allow(email) values ('dummy@partner.taam.kr'); delete from public.partner_signup_allow;" >/dev/null
ok "손님이 자기 번호로 가입" "allow:invite_code" "$(ins "null" "'821055551234'" '{"invite_code":"GST00001"}' '{"provider":"phone"}')"
$P -c "update auth.users set phone_confirmed_at = now(), last_sign_in_at = now() where phone='821055551234';" >/dev/null
GID=$(q "select id from auth.users where phone='821055551234';")
ok "Edge 소진 · 본문의 다른 번호·이메일 → 주인은 손님 · 기록은 인증 값" "t" "$(as_svc "update public.invite_codes set used=true, used_by_email='att@x.com', used_by_phone='010-0000-0000', used_by_name='<x>손님' where code='GST00001' and used=false; select used from public.invite_codes where code='GST00001';")"
ok "  … member_id = 손님" "$GID" "$(q "select member_id from public.invite_codes where code='GST00001';")"
ok "  … used_by_phone = 손님 인증 번호" "821055551234" "$(q "select used_by_phone from public.invite_codes where code='GST00001';")"
ok "  … used_by_email = (손님은 이메일 없음)" "" "$(q "select coalesce(used_by_email,'') from public.invite_codes where code='GST00001';")"
ok "  … used_by_name 정리" "x손님" "$(q "select used_by_name from public.invite_codes where code='GST00001';")"
ok "  … 손님 좌석은 손님에게" "$GID" "$(q "select user_id from public.tickets where purchase_id='LINK-1';")"
ok "쓴 초대장 · Edge 가 주인을 바꿔도 되돌림" "$GID" "$(as_svc "update public.invite_codes set member_id='$A', used_by_email='att@x.com' where code='GST00001'; select member_id from public.invite_codes where code='GST00001';")"
ok "쓴 초대장 · Edge 가 되살려도 되돌림" "t" "$(as_svc "update public.invite_codes set used=false where code='GST00001'; select used from public.invite_codes where code='GST00001';")"
ok "안 쓴 초대장에 주인을 미리 적기 → 되돌림" "" "$(as_svc "update public.invite_codes set member_id='$A' where code='MAIL0001'; select coalesce(member_id,'') from public.invite_codes where code='MAIL0001';")"
$P -c "insert into public.invite_codes(code,invitee_phone,invitee_tier,invited_by) values ('BBBB0002','010-7777-8888','T','admin');" >/dev/null
ok "회원 자기 소진 · 묶임 일치 → 됨" "1" "$(as_user $B "select consume_invite_by_self();")"
ok "  … member_id = 그 회원" "$B" "$(q "select member_id from public.invite_codes where code='BBBB0002';")"
ok "슈퍼어드민 강제 소진(묶임 계정 없음) → 됨 · 적힌 그대로" "t" "$(as_user $SUPER "update public.invite_codes set used=true where code='EXPD0001'; select used from public.invite_codes where code='EXPD0001';")"
ok "SQL Editor(로그인 없음 · 서버 아님) → 믿음" "$SUPER" "$(q "update public.invite_codes set member_id='$SUPER' where code='USED0001'; select member_id from public.invite_codes where code='USED0001';")"
ok "초대장 만들기 · 묶임 없음 → 거절" "INVITE_UNBOUND" "$(as_user $SUPER "insert into public.invite_codes(code,invitee_name) values ('NEW00001','누구');" | grep -oE 'INVITE_UNBOUND' | head -1)"
ok "초대장 만들기 · 짧은 번호 → 거절" "INVITE_UNBOUND" "$(as_user $SUPER "insert into public.invite_codes(code,invitee_phone) values ('NEW00002','010-12');" | grep -oE 'INVITE_UNBOUND' | head -1)"
ok "초대장 만들기 · 이름 꺾쇠 정리" "누구b" "$(as_user $SUPER "insert into public.invite_codes(code,invitee_name,invitee_phone) values ('NEW00003','누구<b>','010-2222-3333'); select invitee_name from public.invite_codes where code='NEW00003';")"
ok "서버가 만드는 새 초대장에 사용 기록을 미리 못 적는다" "f" "$(as_svc "insert into public.invite_codes(code,invitee_phone,used,member_id) values ('NEW00004','010-4444-5555',true,'$A'); select used from public.invite_codes where code='NEW00004';")"

echo "── ③ 읽기 · ⑥ 대조"
ok "회원은 자기 초대장만 ⭐" "1" "$(as_user $A "select count(*) from public.invite_codes;")"
ok "  … 그 한 줄이 자기 것" "AAAA0001" "$(as_user $A "select string_agg(code, ',') from public.invite_codes;")"
ok "번호 가입 회원도 자기 것만" "BBBB0001,BBBB0002" "$(as_user $B "select string_agg(code, ',' order by code) from public.invite_codes;")"
ok "슈퍼어드민은 전부" "$(q "select count(*) from public.invite_codes;")" "$(as_user $SUPER "select count(*) from public.invite_codes;")"
ok "anon 은 못 읽는다" "t" "$(as_anon "select count(*) from public.invite_codes;" | grep -c 'permission denied' | sed 's/1/t/')"
ok "내 초대장 RPC" "AAAA0001:T" "$(as_user $A "select (taam_my_invite()->>'code') || ':' || (taam_my_invite()->>'invitee_tier');")"
ok "로그인 대조 · 본인" "t" "$(as_user $A "select user_has_invite_match();")"
C=00000000-0000-0000-0000-0000000000d1
$P -c "update public.app_config set value = jsonb_build_object('mode','log') where key='signup_guard'; insert into auth.users(id,email,email_confirmed_at) values ('$C','none@x.com',now()); update public.app_config set value = jsonb_build_object('mode','enforce') where key='signup_guard';" >/dev/null
$P -c "update public.profiles set phone='010-7777' where id='$C';" >/dev/null
ok "로그인 대조 · 초대 없는 회원(profiles 번호 일부가 남과 겹침) → false ⭐" "f" "$(as_user $C "select user_has_invite_match();")"
ok "로그인 대조 · anon 실행 없음" "permission denied" "$(as_anon "select user_has_invite_match();" | grep -o 'permission denied' | head -1)"
ok "등급 · 메타데이터 번호 무시" "" "$(q "update auth.users set raw_user_meta_data = '{\"phone\":\"010-1111-2222\"}' where id='$C'; select coalesce(public.taam_invited_tier('$C', null, null), '');")"
ok "등급 · 본인 초대장(주인 줄 먼저)" "T" "$(q "select public.taam_invited_tier('$B', null, null);")"

echo "── ④ 연락처 · ⑤ 이름"
ok "회원 · 자기 인증 번호로 profiles 번호 → 됨" "010-7777-8888" "$(as_user $B "update public.profiles set phone='010-7777-8888' where id='$B'; select phone from public.profiles where id='$B';")"
ok "회원 · profiles 이메일을 남의 것으로 → 되돌림" "" "$(as_user $B "update public.profiles set email='kim@x.com' where id='$B'; select coalesce(email,'') from public.profiles where id='$B';")"
ok "회원 · 번호 비우기는 된다" "" "$(as_user $B "update public.profiles set phone=null where id='$B'; select coalesce(phone,'') from public.profiles where id='$B';")"
ok "슈퍼어드민은 회원 번호를 바꾼다" "010-9999-0000" "$(as_user $SUPER "update public.profiles set phone='010-9999-0000' where id='$B'; select phone from public.profiles where id='$B';")"
ok "회원 세션 · 이름 태그 → 거절(K)" "BAD_INPUT" "$(as_user $A "update public.profiles set display_name='<img src=x>' where id='$A';" | grep -o 'BAD_INPUT' | head -1)"
ok "서버 세션 · 이름 태그 → 정리" "img src=x" "$(as_svc "update public.profiles set display_name='<img src=x>' where id='$A'; select display_name from public.profiles where id='$A';")"
ok "서버 세션 · 영문 이름도" "b" "$(as_svc "update public.profiles set display_name_en='<b>' where id='$A'; select display_name_en from public.profiles where id='$A';")"
ok "정상 이름은 그대로" "Kim Min-su (김민수)" "$(as_svc "update public.profiles set display_name='Kim Min-su (김민수)' where id='$A'; select display_name from public.profiles where id='$A';")"

echo "── 해외 결제 링크 손님(코드로만 묶임)"
ok "국내 결제 링크 손님 초대장은 번호에 묶인 채 — 이메일 가입 거절" "ERR:SIGNUP_NOT_INVITED: channel_mismatch" "$(ins "'kr-guest@x.com'" "null" '{"invite_code":"GSTKR005"}' '{"provider":"email"}')"
ok "해외 손님 · 이메일 가입 + 코드 → 통과" "allow:invite_code_only" "$(ins "'us-guest@x.com'" "null" '{"invite_code":"GSTEN002"}' '{"provider":"email"}')"
UG=$(q "select id from auth.users where email='us-guest@x.com';")
ok "  … 확인 전 · Edge 소진 → 거절(인증 계정 없음)" "INVITE_OWNER_UNVERIFIED" "$(as_svc "update public.invite_codes set used=true, used_by_email='us-guest@x.com' where code='GSTEN002' and used=false;" | grep -oE 'INVITE_OWNER_UNVERIFIED' | head -1)"
$P -c "update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where id='$UG';" >/dev/null
ok "  … 확인 뒤 · 자기 초대장이 보인다(가입 코드)" "GSTEN002" "$(as_user $UG "select string_agg(code, ',') from public.invite_codes;")"
ok "  … 로그인 대조 통과" "t" "$(as_user $UG "select user_has_invite_match();")"
ok "  … 다른 회원은 그 초대장을 못 본다" "0" "$(as_user $A "select count(*) from public.invite_codes where code='GSTEN002';")"
ok "  … Edge 소진 → 주인은 그 가입 계정" "$UG" "$(as_svc "update public.invite_codes set used=true, used_by_email='att@x.com' where code='GSTEN002' and used=false; select member_id from public.invite_codes where code='GSTEN002';")"
ok "  … 기록 이메일은 그 계정의 인증 값" "us-guest@x.com" "$(q "select used_by_email from public.invite_codes where code='GSTEN002';")"
ok "  … 손님 좌석이 그 계정에" "$UG" "$(q "select user_id from public.tickets where purchase_id='LINK-2';")"
ok "공격자 자기 소진 · 남의 해외 손님 초대장 안 건드림" "0" "$(as_user $A "select consume_invite_by_self();")"
ok "해외 손님 3 · 가입" "allow:invite_code_only" "$(ins "'uk-guest@x.com'" "null" '{"invite_code":"GSTEN003"}' '{"provider":"email"}')"
U3=$(q "select id from auth.users where email='uk-guest@x.com';")
$P -c "update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where id='$U3';" >/dev/null
ok "  … Edge 가 실패해도 자기 소진 RPC 가 처리" "1" "$(as_user $U3 "select consume_invite_by_self();")"
ok "  … 좌석이 그 계정에" "$U3" "$(q "select user_id from public.tickets where purchase_id='LINK-3';")"
ok "해외 손님 4 · 두 계정이 같은 코드로 가입(둘 다 인증)" "allow:invite_code_only" "$(ins "'jp-a@x.com'" "null" '{"invite_code":"GSTEN004"}' '{"provider":"email"}'; ins "'jp-b@x.com'" "null" '{"invite_code":"GSTEN004"}' '{"provider":"email"}' >/dev/null)"
$P -c "update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where email in ('jp-a@x.com','jp-b@x.com');" >/dev/null
ok "  … Edge 소진 → 주인을 못 정해 거절" "INVITE_OWNER_UNVERIFIED" "$(as_svc "update public.invite_codes set used=true where code='GSTEN004' and used=false;" | grep -oE 'INVITE_OWNER_UNVERIFIED' | head -1)"
ok "등급 · 남의 등급은 못 묻는다" "" "$(as_user $A "select coalesce(public.taam_invited_tier('$B', null, null), '');")"
ok "등급 · 슈퍼어드민은 묻는다" "T" "$(as_user $SUPER "select public.taam_invited_tier('$B', null, null);")"

echo "── Confirm email 꺼짐 대비 · 메타데이터 · 번호 인증 붙이기 · 국내 판정"
ok "이메일 가입 · 코드 없음 · 안 쓴 초대장 이메일과 일치 → 거절(비밀번호 가입 길)" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "'kim@x.com'" "null" '{}' '{"provider":"email"}')"
ok "번호 가입 · 코드 없음 · 안 쓴 초대장 번호와 일치 → 거절" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "null" "'821066667777'" '{}' '{"provider":"phone"}')"
ok "회원이 로그인 이메일을 남의 초대 이메일로 → 막힘 ⭐" "EMAIL_CHANGE_BLOCKED" "$($P -c "update auth.users set email='kim@x.com' where id='$A';" 2>&1 | grep -oE 'EMAIL_CHANGE_BLOCKED' | head -1)"
ok "번호 회원이 이메일을 새로 붙이기 → 막힘" "EMAIL_CHANGE_BLOCKED" "$($P -c "update auth.users set email='kim@x.com' where id='$B';" 2>&1 | grep -oE 'EMAIL_CHANGE_BLOCKED' | head -1)"
ok "SQL Editor 는 GUC 로 바꾼다" "new-a@x.com" "$(q "begin; set local taam.allow_email_change = '1'; update auth.users set email='new-a@x.com' where id='$A'; commit; select email from auth.users where id='$A';")"
$P -c "begin; set local taam.allow_email_change = '1'; update auth.users set email='att@x.com' where id='$A'; commit;" >/dev/null
ok "같은 이메일(대소문자만)은 막지 않는다" "ATT@x.com" "$(q "update auth.users set email='ATT@x.com' where id='$A'; select email from auth.users where id='$A';")"
$P -c "begin; set local taam.allow_email_change = '1'; update auth.users set email='att@x.com' where id='$A'; commit;" >/dev/null
ok "로그인 시각 갱신 같은 평범한 갱신은 그대로" "t" "$(q "update auth.users set created_at = created_at where id='$A'; select true;")"
ok "메타데이터 갱신 · 번호 키 버림 ⭐" "f" "$(q "update auth.users set raw_user_meta_data = raw_user_meta_data || '{\"phone\":\"<svg onload=1>\",\"display_name\":\"<i>이</i>\"}' where id='$A'; select raw_user_meta_data ? 'phone' from auth.users where id='$A';")"
ok "  … 이름 정리" "i이/i" "$(q "select raw_user_meta_data->>'display_name' from auth.users where id='$A';")"
ok "  … profiles 번호로 안 넘어감" "" "$(q "select coalesce(phone,'') from public.profiles where id='$A';")"
ok "국내 판정 · 010" "t" "$(q "select public._taam_kr_mobile('010-1234-5678');")"
ok "국내 판정 · +82 10" "t" "$(q "select public._taam_kr_mobile('+82 10-1234-5678');")"
ok "국내 판정 · +1 617 은 아님 ⭐" "f" "$(q "select public._taam_kr_mobile('+1 617 555 1234');")"
ok "국내 판정 · +1 212 은 아님" "f" "$(q "select public._taam_kr_mobile('+1 212 555 1234');")"
ok "결제 링크 손님 초대장 · 판정 줄 교체" "t" "$(q "select prosrc like '%_taam_kr_mobile%' from pg_proc where proname='taam_guest_invite_on_paid';")"
$P -v ON_ERROR_STOP=1 >/dev/null <<SQL2
insert into public.kashikiri_charges(id,link_invite,status,user_id,payer_phone,payer_name) values
 ('44444444-4444-4444-4444-444444444444',true,'pending',null,'+1 617 555 1234','Bob'),
 ('55555555-5555-5555-5555-555555555555',true,'pending',null,'010-8888-1111','철수');
update public.kashikiri_charges set status='paid' where id in ('44444444-4444-4444-4444-444444444444','55555555-5555-5555-5555-555555555555');
insert into public.tickets(purchase_id,user_id,status,extra_data) values ('LINK-5',null,'active','{"chargeId":"55555555-5555-5555-5555-555555555555"}');
SQL2
ok "  … +1 617 손님 초대장은 해외(코드로만)" "EN:true" "$(q "select c.country || ':' || public._taam_invite_code_only(c.invited_by, c.country, c.invitee_phone, c.invitee_email)::text from public.invite_codes c where c.invitee_phone='+1 617 555 1234';")"
ok "  … 010 손님 초대장은 국내(번호 묶임)" "KR:false" "$(q "select c.country || ':' || public._taam_invite_code_only(c.invited_by, c.country, c.invitee_phone, c.invitee_email)::text from public.invite_codes c where c.invitee_phone='010-8888-1111';")"
KC=$(q "select code from public.invite_codes where invitee_phone='010-8888-1111';")
ok "국내 손님 · 번호 가입(확인 전)" "allow:invite_code" "$(ins "null" "'821088881111'" "{\"invite_code\":\"$KC\"}" '{"provider":"phone"}')"
ok "  … 확인 전엔 좌석이 안 붙는다" "" "$(q "select coalesce(user_id::text,'') from public.tickets where purchase_id='LINK-5';")"
KU=$(q "select id from auth.users where phone='821088881111';")
$P -c "update auth.users set phone_confirmed_at = now(), last_sign_in_at = now() where id='$KU';" >/dev/null
ok "  … 번호가 인증되는 순간 좌석이 붙는다(소진 전에도) ⭐" "$KU" "$(q "select user_id from public.tickets where purchase_id='LINK-5';")"
ok "해외 손님 · 이미 쓴 코드로 또 가입 → 거절" "ERR:SIGNUP_NOT_INVITED: code_used" "$(ins "'us-guest2@x.com'" "null" '{"invite_code":"GSTEN002"}' '{"provider":"email"}')"
NC=$(q "select code from public.invite_codes where invitee_phone='+1 617 555 1234';")
ins "'bob-a@x.com'" "null" "{\"invite_code\":\"$NC\"}" '{"provider":"email"}' >/dev/null
ok "해외 손님 · 첫 계정 인증 뒤 두 번째 가입 → 거절(code_claimed)" "ERR:SIGNUP_NOT_INVITED: code_claimed" "$($P -c "update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where email='bob-a@x.com';" >/dev/null; ins "'bob-b@x.com'" "null" "{\"invite_code\":\"$NC\"}" '{"provider":"email"}')"
BA=$(q "select id from auth.users where email='bob-a@x.com';")
ok "  … 등급 · 소진 전에도 코드 주인은 게스트 등급(A)" "A" "$(as_user $BA "select public.taam_invited_tier('$BA', null, null);")"
ok "두 계정 모두 인증된 해외 코드(GSTEN004) · 아무도 못 본다" "0:0" "$(as_user $(q "select id from auth.users where email='jp-a@x.com';") "select count(*) from public.invite_codes where code='GSTEN004';"):$(as_user $(q "select id from auth.users where email='jp-b@x.com';") "select count(*) from public.invite_codes where code='GSTEN004';")"
ok "Edge 소진과 함께 묶인 번호를 바꿔 주인 갈아 끼우기 → 거절(옛 번호의 주인 없음)" "INVITE_OWNER_UNVERIFIED" "$(as_svc "update public.invite_codes set invitee_phone='+1 617 999 0000', used=true where code='GSTKR005';" | grep -oE 'INVITE_OWNER_UNVERIFIED' | head -1)"
ok "  … 번호만 바꾸기 → 되돌림" "010-6666-7777" "$(as_svc "update public.invite_codes set invitee_phone='+1 617 999 0000' where code='GSTKR005'; select invitee_phone from public.invite_codes where code='GSTKR005';")"
ok "  … 그 바꾸기로 소진도 안 됨(주인 없음)" "f" "$(q "select used from public.invite_codes where code='GSTKR005';")"
ok "번호에 묶인 초대장은 가입 로그로 주인이 되지 않는다" "" "$(q "select coalesce(public._taam_code_owner('PHON0001')::text, '');")"
ok "서버 세션 · profiles 번호 태그 → 번호 글자만" "1" "$(as_svc "update public.profiles set phone='<svg onload=1>' where id='$A'; select phone from public.profiles where id='$A';")"
ok "서버 세션 · profiles 이메일 이상 → 비움" "" "$(as_svc "update public.profiles set email='x@a.b<img src=x>' where id='$A'; select coalesce(email,'') from public.profiles where id='$A';")"
ok "서버 세션 · 다른 글자 칸 태그 → 꺾쇠 제거" "b onmouseover=1KR" "$(as_svc "update public.profiles set membership_tier='<b onmouseover=1>KR' where id='$A'; select membership_tier from public.profiles where id='$A';")"

echo "── 2차 리뷰 반영"
$P -v ON_ERROR_STOP=1 >/dev/null <<SQL3
insert into public.invite_codes(code,invitee_name,invitee_phone,invitee_email,invitee_tier,invited_by,country) values
 ('VICT0001','피해자',null,'victim@x.com','M','admin','EN'),
 ('EXPE0001','만료',null,'exp@x.com','T','admin','EN'),
 ('ADMF0001','해외번호 어드민 초대','+1 415 555 2222',null,'T','admin','EN'),
 ('NOVE0001','소셜',null,'social@x.com','T','admin','EN');
update public.invite_codes set expires_at = now() - interval '1 day' where code='EXPE0001';
insert into public.kashikiri_charges(id,link_invite,status,user_id,payer_phone,payer_name) values
 ('66666666-6666-6666-6666-666666666666',true,'pending',null,'+1 202 555 7777','Eve'),
 ('77777777-7777-7777-7777-777777777777',true,'pending',null,'+1 303 555 8888','Typo'),
 ('88888888-8888-8888-8888-888888888888',true,'pending',null,'+1 404 555 9999','LogFail');
update public.kashikiri_charges set status='paid' where id in ('66666666-6666-6666-6666-666666666666','77777777-7777-7777-7777-777777777777','88888888-8888-8888-8888-888888888888');
SQL3
EC=$(q "select code from public.invite_codes where invitee_phone='+1 202 555 7777';")
ok "남의 안 쓴 이메일 초대장 주소 + 내 손님 코드로 가입 → 거절(channel_reserved) ⭐" "ERR:SIGNUP_NOT_INVITED: channel_reserved" "$(ins "'victim@x.com'" "null" "{\"invite_code\":\"$EC\"}" '{"provider":"email"}')"
ok "손님 코드로 내 이메일 가입은 된다" "allow:invite_code_only" "$(ins "'eve@x.com'" "null" "{\"invite_code\":\"$EC\"}" '{"provider":"email"}')"
EV=$(q "select id from auth.users where email='eve@x.com';")
$P -c "update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where id='$EV';" >/dev/null
$P -c "insert into public.invite_codes(code,invitee_name,invitee_email,invitee_tier,invited_by,country) values ('LATE0001','나중','eve@x.com','M','admin','EN');" >/dev/null 2>&1
ok "나중에 같은 이메일로 M 초대장이 생겨도 · 손님 코드로 들어온 계정은 그 초대장을 못 본다 ⭐" "$EC" "$(as_user $EV "select string_agg(code, ',') from public.invite_codes;")"
ok "  … 자기 소진으로 그 M 초대장을 못 가져간다" "1" "$(as_user $EV "select consume_invite_by_self();")"
ok "  … M 초대장은 그대로 미사용" "f" "$(q "select used from public.invite_codes where code='LATE0001';")"
ok "  … 등급은 손님(A) — M 이 아님" "A" "$(as_user $EV "select public.taam_invited_tier('$EV', null, null);")"
ok "  … 회원 세션 정의자 함수로 소진 → INVITE_NOT_YOURS ⭐" "INVITE_NOT_YOURS" "$($P -c "set role authenticated; set request.jwt.claims = '{\"sub\":\"$EV\",\"role\":\"authenticated\"}'; select public._t_mark_used('LATE0001');" 2>&1 | grep -oE 'INVITE_NOT_YOURS' | head -1)"
TC=$(q "select code from public.invite_codes where invitee_phone='+1 303 555 8888';")
ok "해외 손님 · 오타 이메일로 OTP 만 요청(로그인 안 함)" "allow:invite_code_only" "$(ins "'typo@gmial.com'" "null" "{\"invite_code\":\"$TC\"}" '{"provider":"email"}')"
$P -c "update auth.users set email_confirmed_at = now() where email='typo@gmial.com';" >/dev/null
ok "  … 바른 이메일로 다시 가입 → 통과(오타 계정은 주인이 아니다) ⭐" "allow:invite_code_only" "$(ins "'typo@gmail.com'" "null" "{\"invite_code\":\"$TC\"}" '{"provider":"email"}')"
$P -c "update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where email='typo@gmail.com';" >/dev/null
ok "  … 주인은 로그인한 계정" "$(q "select id from auth.users where email='typo@gmail.com';")" "$(q "select public._taam_code_owner('$TC');")"
ok "  … 슈퍼어드민 강제 소진 → 좌석은 그 계정에" "$(q "select id from auth.users where email='typo@gmail.com';")" "$(as_user $SUPER "update public.invite_codes set used=true where code='$TC'; select member_id from public.invite_codes where code='$TC';")"
ok "이메일 가입 · 코드 없음 · 메타데이터에 email_verified:true 를 적어도 → 거절" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "'social@x.com'" "null" '{"email_verified":true}' '{"provider":"email"}')"
ok "소셜 · 제공자 확인 · 이미 쓴 초대장 이메일 → 거절" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "'old@x.com'" "null" '{"email_verified":true}' '{"provider":"google"}')"
ok "소셜 · 제공자 확인 · 만료된 초대장 이메일 → 거절" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "'exp@x.com'" "null" '{"email_verified":true}' '{"provider":"google"}')"
ok "소셜 · 제공자 확인 · 안 쓴 초대장 → 통과" "allow:invitee_match" "$(ins "'social@x.com'" "null" '{"email_verified":true}' '{"provider":"apple"}')"
SO=$(q "select id from auth.users where email='social@x.com';")
$P -c "update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where id='$SO';" >/dev/null
ok "  … 소셜 계정은 코드 없이도 그 초대장의 주인" "1" "$(as_user $SO "select consume_invite_by_self();")"
ok "어드민이 해외 번호로 만든 초대장은 코드 전용 아님 → 이메일 가입 거절" "ERR:SIGNUP_NOT_INVITED: channel_mismatch" "$(ins "'adm-f@x.com'" "null" '{"invite_code":"ADMF0001"}' '{"provider":"email"}')"
ok "안 쓴 초대장에 used_by_email 을 미리 적기 → 되돌림" "" "$(as_svc "update public.invite_codes set used_by_email='att@x.com', used_by_phone='010-1' where code='VICT0001'; select coalesce(used_by_email,'') || coalesce(used_by_phone,'') from public.invite_codes where code='VICT0001';")"
ok "번호 회원 · profiles 번호를 다른 번호로 → 되돌림" "010-9999-0000" "$(as_user $B "update public.profiles set phone='010-1111-0000' where id='$B'; select phone from public.profiles where id='$B';")"
ok "  … 자기 인증 번호로는 된다" "010-7777-8888" "$(as_user $B "update public.profiles set phone='010-7777-8888' where id='$B'; select phone from public.profiles where id='$B';")"
$P -v ON_ERROR_STOP=1 >/dev/null <<SQL4
insert into public.kashikiri_charges(id,link_invite,status,user_id,payer_phone,payload) values ('99999999-9999-9999-9999-999999999999',true,'paid',null,'010-9999-1212','{"guest_invite_code":"NONE0001"}');
insert into public.tickets(purchase_id,user_id,status,extra_data) values ('LINK-9',null,'active','{"chargeId":"99999999-9999-9999-9999-999999999999"}');
SQL4
$P -c "update public.app_config set value = jsonb_build_object('mode','log') where key='signup_guard'; insert into auth.users(phone) values ('821099991212'); update public.app_config set value = jsonb_build_object('mode','enforce') where key='signup_guard';" >/dev/null
ok "번호 확인 전 다른 갱신 → 좌석 안 붙음" "" "$(q "update auth.users set created_at = created_at where phone='821099991212'; select coalesce(user_id::text,'') from public.tickets where purchase_id='LINK-9';")"
ok "  … 번호 확인 → 붙음" "$(q "select id from auth.users where phone='821099991212';")" "$(q "update auth.users set phone_confirmed_at = now() where phone='821099991212'; select user_id from public.tickets where purchase_id='LINK-9';")"
P2=$(q "select id from auth.users where phone='821099991212';")
ok "번호만 있는 계정 · 초대 없음 → 등급 없음(이메일 없는 초대장들과 엮이지 않음)" "" "$(q "select coalesce(public.taam_invited_tier('$P2', null, null), '');")"
ok "이메일 정리 · 작은따옴표 이메일은 그대로" "o'neil@x.com" "$(as_svc "update public.profiles set email='o''neil@x.com' where id='$P2'; select email from public.profiles where id='$P2';")"
ok "이메일 정리 · 앞뒤 공백은 다듬는다" "sp@x.com" "$(as_svc "update public.profiles set email=' sp@x.com ' where id='$P2'; select email from public.profiles where id='$P2';")"
ok "글자 칸 정리 · 겹친 javascript: 도 지운다" "ax" "$(as_svc "update public.profiles set membership_tier='<a>javajavascript:script:x' where id='$P2'; select membership_tier from public.profiles where id='$P2';")"
$P -c "update public.app_config set value = jsonb_build_object('mode','log') where key='signup_guard';" >/dev/null
ins "'nocode@x.com'" "null" '{}' '{"provider":"email"}' >/dev/null
ok "거절된 코드 없는 가입도 기록에 이메일이 남는다" "nocode@x.com:reject" "$(q "select email || ':' || verdict from public.signup_guard_log order by id desc limit 1;")"
$P -c "update public.app_config set value = jsonb_build_object('mode','enforce') where key='signup_guard'; delete from auth.users where email='nocode@x.com';" >/dev/null
$P -c "insert into public.signup_guard_log(user_id, invite_code, verdict, reason, mode) values ('$EV', 'GSTEN004', 'reject', 'x', 'log');" >/dev/null
ok "주인 판정은 allow 기록만(거절 기록은 주인 근거가 아니다)" "" "$(q "select coalesce(public._taam_code_owner('GSTEN004')::text, '');")"
LC=$(q "select code from public.invite_codes where invitee_phone='+1 404 555 9999';")
$P -c "alter table public.signup_guard_log rename column reason to reason_x;" >/dev/null
ok "해외 손님 가입 · 기록을 못 남기면 거절 ⭐" "ERR:SIGNUP_GUARD_ERROR" "$(ins "'lf@x.com'" "null" "{\"invite_code\":\"$LC\"}" '{"provider":"email"}')"
$P -c "alter table public.signup_guard_log rename column reason_x to reason;" >/dev/null
ok "anon 정의자 호출로 소진 · 주인 없음 → 거절(서버처럼 다룸)" "INVITE_OWNER_UNVERIFIED" "$($P -c "set role anon; set request.jwt.claims = '{\"role\":\"anon\"}'; select public._t_mark_used('VICT0001');" 2>&1 | grep -oE 'INVITE_OWNER_UNVERIFIED' | head -1)"
ok "로그인했지만 sub 없는 호출도 서버처럼(믿지 않음)" "INVITE_OWNER_UNVERIFIED" "$($P -c "set role authenticated; set request.jwt.claims = '{\"role\":\"authenticated\"}'; select public._t_mark_used('VICT0001');" 2>&1 | grep -oE 'INVITE_OWNER_UNVERIFIED' | head -1)"
ok "주인 판정 함수 · 회원 실행 없음" "f" "$(q "select has_function_privilege('authenticated','public._taam_code_owner(text)','execute');")"
ok "이메일 존재 조회 · 회원·anon 실행 없음" "f:f:f:f" "$(q "select has_function_privilege('authenticated','public.email_exists_in_auth(text)','execute')::text || ':' || has_function_privilege('anon','public.email_exists_in_auth(text)','execute')::text || ':' || has_function_privilege('authenticated','public.email_exists_in_auth_other(text,uuid)','execute')::text || ':' || has_function_privilege('anon','public.email_exists_in_auth_other(text,uuid)','execute')::text" | sed 's/false/f/g;s/true/t/g')"
ok "문지기 모드 함수 · 회원 실행 없음" "f" "$(q "select has_function_privilege('authenticated','public.taam_signup_guard_mode()','execute');")"

echo "── 3차 리뷰 반영"
$P -v ON_ERROR_STOP=1 >/dev/null <<SQL5
insert into public.invite_codes(code,invitee_name,invitee_email,invitee_tier,invited_by,country,used,used_at) values
 ('GHST0001','유령','ghost@x.com','M','admin','EN',true,now());
insert into public.invite_codes(code,invitee_name,invitee_email,invitee_tier,invited_by,country) values ('REIS0001','재발급','re@x.com','T','admin','EN');
insert into public.kashikiri_charges(id,link_invite,status,user_id,payer_phone,payer_name) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',true,'pending',null,'+1 505 555 1111','G');
update public.kashikiri_charges set status='paid' where id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
SQL5
GC=$(q "select code from public.invite_codes where invitee_phone='+1 505 555 1111';")
ok "쓴 초대장(주인 없음)의 빈 이메일 + 손님 코드 → 거절(channel_reserved) ⭐" "ERR:SIGNUP_NOT_INVITED: channel_reserved" "$(ins "'ghost@x.com'" "null" "{\"invite_code\":\"$GC\"}" '{"provider":"email"}')"
ok "다시 발급 · 첫 시도(OTP 요청만)" "allow:invite_code" "$(ins "'re@x.com'" "null" '{"invite_code":"REIS0001"}' '{"provider":"email"}')"
RU=$(q "select id from auth.users where email='re@x.com';")
$P -c "update auth.users set email_confirmed_at = now() where id='$RU'; delete from public.invite_codes where code='REIS0001'; insert into public.invite_codes(code,invitee_name,invitee_email,invitee_tier,invited_by,country) values ('REIS0002','재발급','re@x.com','M','admin','EN');" >/dev/null
$P -c "update auth.users set last_sign_in_at = now() where id='$RU';" >/dev/null
ok "  … 새 코드(가입 줄 없음)도 그 사람 것 ⭐" "REIS0002" "$(as_user $RU "select string_agg(code, ',') from public.invite_codes;")"
ok "  … 로그인 대조 통과" "t" "$(as_user $RU "select user_has_invite_match();")"
ok "  … 등급 M" "M" "$(as_user $RU "select public.taam_invited_tier('$RU', null, null);")"
ok "  … 자기 소진" "1" "$(as_user $RU "select consume_invite_by_self();")"

echo "── 권한"
ok "발급 예약 표 · 회원·anon 못 읽고 못 씀(기본 권한 회수)" "f:f:f" "$(q "select has_table_privilege('authenticated','public.partner_signup_allow','select')::text || ':' || has_table_privilege('authenticated','public.partner_signup_allow','insert')::text || ':' || has_table_privilege('anon','public.partner_signup_allow','insert')::text" | sed 's/false/f/g;s/true/t/g')"
ok "내 초대장 RPC · anon 없음" "f" "$(q "select has_function_privilege('anon','public.taam_my_invite()','execute');")"
ok "자기 소진 · anon 없음" "f" "$(q "select has_function_privilege('anon','public.consume_invite_by_self()','execute');")"

rm -rf $T
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
