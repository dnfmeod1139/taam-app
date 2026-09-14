#!/bin/bash
# 가입 문지기 (sql/signup_guard.sql) 재보기. 먼저: 로컬 pg. 실행: bash sql/_test/t_signup_guard.sh
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
$P -v ON_ERROR_STOP=1 -f sql/_test/fx_signup_guard.sql >/dev/null 2>/tmp/_sg.err || { echo "❌ 픽스처"; head -3 /tmp/_sg.err; exit 1; }
$P -v ON_ERROR_STOP=1 -f sql/signup_guard.sql >/tmp/_sg.out 2>/tmp/_sg.err || { echo "❌ 적용 실패"; grep -i error /tmp/_sg.err | head -5; exit 1; }
ok "확인 표 ❌ 없음" 0 "$(grep -c '❌' /tmp/_sg.out)"
ok "확인 표 ✅ 5줄" 5 "$(grep -c '✅' /tmp/_sg.out)"
# 두 번 돌려도 된다 (멱등)
$P -v ON_ERROR_STOP=1 -f sql/signup_guard.sql >/dev/null 2>&1 || { echo "❌ 2회 실행 실패"; FAIL=1; }

# ins <email> <phone> <meta json> <app json> → 마지막 로그의 verdict:reason 또는 ERR
ins(){ local o; o=$($P -c "insert into auth.users(email,phone,raw_user_meta_data,raw_app_meta_data) values ($1,$2,'$3'::jsonb,'$4'::jsonb);" 2>&1); if echo "$o" | grep -q "ERROR"; then echo "ERR:$(echo "$o" | grep -o 'SIGNUP_NOT_INVITED: [a-z_]*' | head -1)"; else $P -c "select verdict||':'||reason from public.signup_guard_log order by id desc limit 1;" | tail -1; fi; }
last_enf(){ $P -c "select enforced from public.signup_guard_log order by id desc limit 1;" | tail -1; }

echo "── log 모드 (1단계): 판정만 적고 막지 않는다"
ok "코드 없이 + 초대장에 없음 → reject 기록, 가입은 됨" "reject:no_invite" "$(ins "'nobody@x.com'" "null" '{}' '{}')"
ok "  … 실제로 안 막았다" "f" "$(last_enf)"
ok "  … auth.users 에 들어갔다" 1 "$($P -c "select count(*) from auth.users where email='nobody@x.com';" | tail -1)"
ok "  … profiles 동기화도 그대로" 1 "$($P -c "select count(*) from public.profiles where email='nobody@x.com';" | tail -1)"
ok "슈퍼어드민 화이트리스트" "allow:super_whitelist" "$(ins "'DNFMEOD@playtaam.com'" "null" '{}' '{}')"
ok "파트너 도메인" "allow:partner_domain" "$(ins "'r-001@partner.taam.kr'" "null" '{}' '{}')"
ok "코드 OK + 번호 일치 (전화 가입)" "allow:invite_code" "$(ins "null" "'+821011112222'" '{"invite_code":"live01","display_name":"홍길동"}' '{}')"
ok "코드 OK + 번호 불일치" "reject:phone_mismatch" "$(ins "null" "'+821099990000'" '{"invite_code":"LIVE01"}' '{}')"
ok "코드 OK + 이메일 일치" "allow:invite_code" "$(ins "'Kim@X.com'" "null" '{"invite_code":"MAIL01"}' '{}')"
ok "코드 OK + 이메일 불일치" "reject:email_mismatch" "$(ins "'other@x.com'" "null" '{"invite_code":"MAIL01"}' '{}')"
ok "초대장에 이메일 적힌 코드로 전화 가입 (이메일 없음) → 통과" "allow:invite_code" "$(ins "null" "'+821055556666'" '{"invite_code":"MAIL01"}' '{}')"
ok "번호·이메일 없는 열린 코드" "allow:invite_code" "$(ins "'any@x.com'" "null" '{"invite_code":"OPEN01"}' '{}')"
ok "없는 코드" "reject:code_not_found" "$(ins "'a@x.com'" "null" '{"invite_code":"ZZZZ99"}' '{}')"
ok "사용된 코드" "reject:code_used" "$(ins "'b@x.com'" "null" '{"invite_code":"USED01"}' '{}')"
ok "만료된 코드 (text 컬럼)" "reject:code_expired" "$(ins "'c@x.com'" "null" '{"invite_code":"EXP001"}' '{}')"
ok "만료일이 깨진 문자열 → 만료 없음으로 통과 (가입을 막지 않는다)" "allow:invite_code" "$(ins "'d@x.com'" "null" '{"invite_code":"BAD001"}' '{}')"
ok "코드 없이 소셜 — 초대장 이메일 일치" "allow:invitee_match" "$(ins "'kim@x.com'" "null" '{}' '{"provider":"google"}')"
ok "  … provider 기록" "google" "$($P -c "select provider from public.signup_guard_log order by id desc limit 1;" | tail -1)"
ok "코드 없이 전화 — 초대장 번호 일치" "allow:invitee_match" "$(ins "null" "'+821011112222'" '{}' '{"provider":"phone"}')"
ok "코드 없이 소셜 — 초대장에 없음" "reject:no_invite" "$(ins "'stranger@gmail.com'" "null" '{}' '{"provider":"apple"}')"

echo "── enforce 모드 (2단계): 거부면 INSERT 자체가 실패한다"
$P -c "update public.app_config set value = jsonb_build_object('mode','enforce') where key='signup_guard';" >/dev/null
N0=$($P -c "select count(*) from auth.users;" | tail -1)
ok "초대 없는 가입 → 예외 ⭐" "ERR:SIGNUP_NOT_INVITED: no_invite" "$(ins "'intruder@x.com'" "null" '{}' '{}')"
ok "  … auth.users 안 늘었다" "$N0" "$($P -c "select count(*) from auth.users;" | tail -1)"
ok "  … profiles 도 안 생겼다" 0 "$($P -c "select count(*) from public.profiles where email='intruder@x.com';" | tail -1)"
ok "  … 로그 행은 같은 트랜잭션이라 롤백된다 (Postgres 로그의 warning 으로만 남음)" 0 "$($P -c "select count(*) from public.signup_guard_log where email='intruder@x.com';" | tail -1)"
ok "번호 불일치 → 예외" "ERR:SIGNUP_NOT_INVITED: phone_mismatch" "$(ins "null" "'+821099990000'" '{"invite_code":"LIVE01"}' '{}')"
ok "정상 초대 가입은 된다" "allow:invite_code" "$(ins "'e@x.com'" "null" '{"invite_code":"OPEN01"}' '{}')"
ok "슈퍼어드민은 된다" "allow:super_whitelist" "$(ins "'dnfmeod@playtaam.com'" "null" '{}' '{}')"
ok "파트너는 된다" "allow:partner_domain" "$(ins "'r-002@partner.taam.kr'" "null" '{}' '{}')"

echo "── 안전장치: 판정 코드가 깨져도 가입을 막지 않는다"
$P -c "alter table public.invite_codes rename column invitee_phone to invitee_phone_x;" >/dev/null
ok "컬럼이 없어도 error 로 통과" "error" "$(ins "'f@x.com'" "null" '{"invite_code":"OPEN01"}' '{}' | cut -d: -f1)"
ok "  … 가입은 됐다" 1 "$($P -c "select count(*) from auth.users where email='f@x.com';" | tail -1)"
$P -c "alter table public.invite_codes rename column invitee_phone_x to invitee_phone;" >/dev/null

echo "── 권한"
ok "회원은 로그를 못 쓴다" "f" "$($P -c "select has_table_privilege('authenticated','public.signup_guard_log','insert');" | tail -1)"
ok "anon 은 로그를 못 읽는다" "f" "$($P -c "select has_table_privilege('anon','public.signup_guard_log','select');" | tail -1)"
ok "모드 함수는 회원이 못 부른다" "f" "$($P -c "select has_function_privilege('authenticated','public.taam_signup_guard_mode()','execute');" | tail -1)"

[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
