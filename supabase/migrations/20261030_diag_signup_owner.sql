-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용 · 2026-10-30): 강화판 주인 판정(_taam_invite_owner_ok)을 라이브 자료에 그대로 대어 본다 — 건수만(공개 로그)
--   (함수는 아직 없으니 같은 식을 풀어 쓴다 · 초대장은 전부 사용됨)
-- ═══════════════════════════════════════════════════════════════
with m as (
  select au.id, au.phone, au.email, au.phone_confirmed_at, au.email_confirmed_at
    from auth.users au join public.profiles p on p.id = au.id
   where coalesce(p.role, 'user') not in ('admin','super_admin','superadmin','staff') and p.deleted_at is null
     and not exists (select 1 from public.admin_grants g where g.user_id = au.id)
), own as (
  select m.id,
         exists (select 1 from public.invite_codes ic
                  where (nullif(btrim(coalesce(ic.member_id,'')),'') is not null and btrim(ic.member_id) = m.id::text)
                     or ((nullif(btrim(coalesce(ic.member_id,'')),'') is null or not exists (select 1 from auth.users x where x.id::text = btrim(ic.member_id)))
                         and coalesce(ic.used, false)
                         and (   (m.phone_confirmed_at is not null and length(public._taam_phone_key(m.phone)) >= 8
                                  and (public._taam_phone_key(ic.invitee_phone) = public._taam_phone_key(m.phone) or public._taam_phone_key(ic.used_by_phone) = public._taam_phone_key(m.phone)))
                              or (m.email_confirmed_at is not null and nullif(lower(btrim(coalesce(m.email,''))),'') is not null
                                  and (lower(btrim(coalesce(ic.invitee_email,''))) = lower(btrim(m.email)) or lower(btrim(coalesce(ic.used_by_email,''))) = lower(btrim(m.email))))))) as ok
    from m
)
select '① 대조 대상 회원(파트너·어드민·탈퇴 제외)' as 항목, (select count(*)::text from m) as 결과
union all select '② 강화판 주인 판정으로 로그인 대조 실패할 회원', (select count(*)::text from own where not ok)
union all select '③ member_id 가 실제 계정을 가리키지만 묶인 채널의 계정과 다른 초대장', (select count(*)::text from public.invite_codes ic
         where exists (select 1 from auth.users x where x.id::text = btrim(coalesce(ic.member_id,'')))
           and exists (select 1 from auth.users y where y.id::text <> btrim(ic.member_id)
                        and ((y.phone_confirmed_at is not null and length(public._taam_phone_key(y.phone)) >= 8 and public._taam_phone_key(ic.invitee_phone) = public._taam_phone_key(y.phone))
                          or (y.email_confirmed_at is not null and nullif(lower(btrim(coalesce(ic.invitee_email,''))),'') is not null and lower(btrim(y.email)) = lower(btrim(ic.invitee_email))))))
union all select '④ member_id 가 없는 계정을 가리키는 초대장 · 그 묶인 채널이 지금 비어 있음', (select count(*)::text || ' · 비어 있음 ' || count(*) filter (where not exists (select 1 from auth.users y
           where (length(public._taam_phone_key(ic.invitee_phone)) >= 8 and public._taam_phone_key(y.phone) = public._taam_phone_key(ic.invitee_phone))
              or (nullif(lower(btrim(coalesce(ic.invitee_email,''))),'') is not null and lower(btrim(y.email)) = lower(btrim(ic.invitee_email)))))
         from public.invite_codes ic where nullif(btrim(coalesce(ic.member_id,'')),'') is not null and not exists (select 1 from auth.users x where x.id::text = btrim(ic.member_id)))
union all select '⑤ 묶인 채널의 계정이 없는 사용된 초대장(member_id 없음)', (select count(*)::text from public.invite_codes ic
         where coalesce(ic.used,false) and nullif(btrim(coalesce(ic.member_id,'')),'') is null
           and not exists (select 1 from auth.users y
                            where (length(public._taam_phone_key(ic.invitee_phone)) >= 8 and public._taam_phone_key(y.phone) = public._taam_phone_key(ic.invitee_phone))
                               or (nullif(lower(btrim(coalesce(ic.invitee_email,''))),'') is not null and lower(btrim(y.email)) = lower(btrim(ic.invitee_email)))));
