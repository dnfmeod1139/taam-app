-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용 · 2026-10-30): 인증 설정 신호(자동 확인 · 이메일 변경 · 익명) · 초대 코드 중복 · 트리거 정의 — 건수만(공개 로그)
-- ═══════════════════════════════════════════════════════════════
select '① 이메일 계정 · 가입→확인 간격' as 항목,
       (select '2초 안 ' || count(*) filter (where email_confirmed_at - created_at < interval '2 seconds')
             || ' · 2초~1분 ' || count(*) filter (where email_confirmed_at - created_at between interval '2 seconds' and interval '1 minute')
             || ' · 1분 넘음 ' || count(*) filter (where email_confirmed_at - created_at > interval '1 minute')
             || ' · 확인 없음 ' || count(*) filter (where email_confirmed_at is null)
          from auth.users where nullif(email,'') is not null and coalesce(raw_app_meta_data->>'provider','') = 'email') as 결과
union all select '② 번호 계정 · 가입→확인 간격',
       (select '2초 안 ' || count(*) filter (where phone_confirmed_at - created_at < interval '2 seconds')
             || ' · 2초~1분 ' || count(*) filter (where phone_confirmed_at - created_at between interval '2 seconds' and interval '1 minute')
             || ' · 1분 넘음 ' || count(*) filter (where phone_confirmed_at - created_at > interval '1 minute')
             || ' · 확인 없음 ' || count(*) filter (where phone_confirmed_at is null)
          from auth.users where nullif(phone,'') is not null and coalesce(raw_app_meta_data->>'provider','') = 'phone')
union all select '③ auth.users 칸(이메일·번호 변경·익명)', (select string_agg(column_name, ', ' order by column_name) from information_schema.columns
         where table_schema = 'auth' and table_name = 'users' and (column_name like 'email_change%' or column_name like 'phone_change%' or column_name in ('is_anonymous','is_sso_user','confirmed_at')))
union all select '④ 익명 계정', coalesce((select count(*)::text from auth.users u where coalesce((to_jsonb(u)->>'is_anonymous')::boolean, false)), '0')
union all select '⑤ 이메일 변경 대기 · 확인 상태', (select '대기 ' || count(*) filter (where nullif(to_jsonb(u)->>'email_change','') is not null)
             || ' · confirm_status 값 ' || coalesce(string_agg(distinct to_jsonb(u)->>'email_change_confirm_status', ','), '-') from auth.users u)
union all select '⑥ 번호 변경 대기', (select count(*) filter (where nullif(to_jsonb(u)->>'phone_change','') is not null)::text from auth.users u)
union all select '⑦ 이메일 확인 시각 = 가입 시각인 비밀번호 가입 흔적', (select count(*)::text from auth.users where email_confirmed_at is not null and email_confirmed_at = created_at)
union all select '⑧ 초대 code 중복(대소문자·공백 무시)', (select count(*)::text from (select upper(btrim(code)) from public.invite_codes group by 1 having count(*) > 1) s)
union all select '⑨ invite_codes 고유 제약/인덱스', coalesce((select string_agg(indexname || ':' || indexdef, ' · ') from pg_indexes where schemaname = 'public' and tablename = 'invite_codes'), '없음')
union all select '⑩ trg_sync_profile_contact 정의', coalesce((select pg_get_triggerdef(t.oid) from pg_trigger t where t.tgname = 'trg_sync_profile_contact' and t.tgrelid = 'auth.users'::regclass), '없음')
union all select '⑪ trg_sync_profile_email 정의', coalesce((select pg_get_triggerdef(t.oid) from pg_trigger t where t.tgname = 'trg_sync_profile_email' and t.tgrelid = 'auth.users'::regclass), '없음')
union all select '⑫ on_auth_user_created 정의', coalesce((select pg_get_triggerdef(t.oid) from pg_trigger t where t.tgname = 'on_auth_user_created' and t.tgrelid = 'auth.users'::regclass), '없음')
union all select '⑬ profiles 의 auto_promote 트리거 정의', coalesce((select pg_get_triggerdef(t.oid) from pg_trigger t where t.tgname = 'trg_auto_promote_super_admin'), '없음')
union all select '⑭ 결제 링크 손님 번호 분류(청구 · 국내 정규식/엄격 정규식 다름)', (select count(*)::text from public.kashikiri_charges c
         where coalesce(c.link_invite, false) and length(regexp_replace(coalesce(c.payer_phone,''), '[^0-9]', '', 'g')) >= 9
           and (regexp_replace(coalesce(c.payer_phone,''), '[^0-9]', '', 'g') ~ '^(0?1[016789]|821[016789])')
            <> (regexp_replace(coalesce(c.payer_phone,''), '[^0-9]', '', 'g') ~ '^(0?1[016789][0-9]{7,8}|821[016789][0-9]{7,8})$'))
union all select '⑮ 결제 링크 손님 청구(링크 초대 · 비회원)', (select count(*)::text from public.kashikiri_charges c where coalesce(c.link_invite, false) and c.user_id is null)
union all select '⑯ notifications 를 쓰는 회원 정책(정보)', coalesce((select string_agg(policyname || ' ' || cmd, ' · ') from pg_policies where schemaname = 'public' and tablename = 'notifications' and cmd in ('INSERT','UPDATE','ALL')), '없음')
union all select '⑰ partner.taam.kr 계정 · 발급 경로', (select count(*)::text || '개 · 확인 시각=가입 시각 ' || count(*) filter (where email_confirmed_at = created_at) from auth.users where email like '%@partner.taam.kr');
