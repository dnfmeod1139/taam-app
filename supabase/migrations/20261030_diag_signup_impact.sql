-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용 · 2026-10-30): 초대 대조를 「인증된 번호·이메일 정확 일치」로 조이면 누가 걸리나 — 건수만(공개 로그)
-- ═══════════════════════════════════════════════════════════════
with u as (
  select au.id,
         lower(nullif(btrim(coalesce(au.email, '')), '')) as em,
         case when au.email_confirmed_at is not null then lower(nullif(btrim(coalesce(au.email, '')), '')) end as em_v,
         nullif(public._taam_phone_key(au.phone), '') as ph,
         case when au.phone_confirmed_at is not null then nullif(public._taam_phone_key(au.phone), '') end as ph_v,
         p.role, p.deleted_at, nullif(public._taam_phone_key(p.phone), '') as p_ph, lower(nullif(btrim(coalesce(p.email,'')),'')) as p_em
    from auth.users au left join public.profiles p on p.id = au.id
), m as (   -- 로그인 대조를 받는 회원(어드민·탈퇴 제외)
  select * from u where coalesce(role, 'user') not in ('admin','super_admin','superadmin','staff') and deleted_at is null
), old_match as (
  select m.id, exists (
    select 1 from public.invite_codes ic
     where (coalesce(m.em,'') <> '' and (lower(coalesce(ic.invitee_email,'')) = m.em or lower(coalesce(ic.used_by_email,'')) = m.em))
        or (length(coalesce(coalesce(m.ph, m.p_ph),'')) >= 4 and (
              regexp_replace(coalesce(ic.invitee_phone,''), '[^0-9]', '', 'g') like '%' || coalesce(m.ph, m.p_ph) || '%'
           or regexp_replace(coalesce(ic.used_by_phone,''), '[^0-9]', '', 'g') like '%' || coalesce(m.ph, m.p_ph) || '%'))) as ok
    from m
), new_match as (
  select m.id, exists (
    select 1 from public.invite_codes ic
     where ic.member_id = m.id::text
        or (m.em_v is not null and (lower(btrim(coalesce(ic.invitee_email,''))) = m.em_v or lower(btrim(coalesce(ic.used_by_email,''))) = m.em_v))
        or (length(coalesce(m.ph_v,'')) >= 8 and (public._taam_phone_key(ic.invitee_phone) = m.ph_v or public._taam_phone_key(ic.used_by_phone) = m.ph_v))) as ok
    from m
), inv as (
  select ic.*, public._taam_phone_key(ic.invitee_phone) as ip, lower(nullif(btrim(coalesce(ic.invitee_email,'')),'')) as ie,
         (select count(*) from u where (length(coalesce(public._taam_phone_key(ic.invitee_phone),'')) >= 8 and u.ph_v = public._taam_phone_key(ic.invitee_phone))
                                    or (nullif(btrim(coalesce(ic.invitee_email,'')),'') is not null and u.em_v = lower(btrim(ic.invitee_email)))) as bound_users
    from public.invite_codes ic
)
select '① 대조 대상 회원' as 항목, (select count(*)::text from m) as 결과
union all select '② 옛 대조 통과 → 새 대조 실패(로그인에서 튕길 회원)', (select count(*)::text from old_match o join new_match n using (id) where o.ok and not n.ok)
union all select '③ 옛 대조 실패 → 새 대조 통과', (select count(*)::text from old_match o join new_match n using (id) where not o.ok and n.ok)
union all select '④ 옛·새 모두 실패', (select count(*)::text from old_match o join new_match n using (id) where not o.ok and not n.ok)
union all select '⑤ 인증 안 된 번호/이메일을 가진 auth 계정', (select '번호 ' || count(*) filter (where ph is not null and ph_v is null) || ' · 이메일 ' || count(*) filter (where em is not null and em_v is null) from u)
union all select '⑥ profiles 번호가 인증 번호와 다른 회원', (select count(*)::text from m where p_ph is not null and coalesce(ph_v,'') <> p_ph)
union all select '⑦ profiles 이메일이 인증 이메일과 다른 회원', (select count(*)::text from m where p_em is not null and coalesce(em_v,'') <> p_em)
union all select '⑧ 초대장 member_id', (select '채움 ' || count(*) filter (where nullif(member_id,'') is not null) || ' · 그중 실제 계정 ' ||
                       count(*) filter (where exists (select 1 from auth.users au where au.id::text = inv.member_id)) || ' / 전체 ' || count(*) from inv)
union all select '⑨ 초대장 묶인 채널 = 인증 계정 수', (select '1명 ' || count(*) filter (where bound_users = 1) || ' · 0명 ' || count(*) filter (where bound_users = 0) || ' · 2명↑ ' || count(*) filter (where bound_users > 1) from inv)
union all select '⑩ 초대장 used_by 가 묶인 채널과 다름', (select '번호 ' || count(*) filter (where length(coalesce(ip,'')) >= 8 and nullif(public._taam_phone_key(used_by_phone),'') is not null and public._taam_phone_key(used_by_phone) <> ip)
                       || ' · 이메일 ' || count(*) filter (where ie is not null and nullif(lower(btrim(coalesce(used_by_email,''))),'') is not null and lower(btrim(used_by_email)) <> ie) from inv)
union all select '⑪ 초대장 member_id 가 묶인 채널의 계정과 다름', (select count(*)::text from inv where nullif(member_id,'') is not null and bound_users = 1
                       and not exists (select 1 from u where u.id::text = inv.member_id and ((length(coalesce(inv.ip,'')) >= 8 and u.ph_v = inv.ip) or (inv.ie is not null and u.em_v = inv.ie))))
union all select '⑫ profiles 정책', coalesce((select string_agg(policyname || ' ' || cmd || ' ' || array_to_string(roles, ',') || ' · ' || left(coalesce(qual, '') || ' | ' || coalesce(with_check, ''), 120), ' ‖ ' order by policyname) from pg_policies where schemaname = 'public' and tablename = 'profiles'), '없음')
union all select '⑬ profiles 글자 칸', (select string_agg(column_name, ', ' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and data_type in ('text','character varying'))
union all select '⑭ 회원 칸 쓰기 권한(phone · email · display_name)', 'phone=' || has_column_privilege('authenticated','public.profiles','phone','update')::text || ' email=' || has_column_privilege('authenticated','public.profiles','email','update')::text
                       || ' display_name=' || has_column_privilege('authenticated','public.profiles','display_name','update')::text
union all select '⑮ invite_codes used_by_name 에 꺾쇠·javascript', (select count(*)::text from public.invite_codes where coalesce(used_by_name,'') ~ '[<>]' or coalesce(used_by_name,'') ilike '%javascript:%' or coalesce(invitee_name,'') ~ '[<>]')
union all select '⑯ auth 메타데이터 display_name 에 꺾쇠', (select count(*)::text from auth.users where coalesce(raw_user_meta_data->>'display_name','') ~ '[<>]')
union all select '⑰ 게스트(pay_link) 초대장', (select '전체 ' || count(*) || ' · 미사용 ' || count(*) filter (where not coalesce(used,false)) from public.invite_codes where invited_by = 'pay_link')
union all select '⑱ 초대장 code 형식', (select string_agg(k || ' ' || n, ' · ') from (select length(code)::text || '자' || case when code ~ '^[A-Z0-9]+$' then '' else '·기호' end as k, count(*) n from public.invite_codes group by 1) s)
union all select '⑲ 같은 번호 키 auth 계정 2개↑', (select count(*)::text from (select ph_v from u where ph_v is not null group by 1 having count(*) > 1) s)
union all select '⑳ 같은 이메일 auth 계정 2개↑', (select count(*)::text from (select em_v from u where em_v is not null group by 1 having count(*) > 1) s);
