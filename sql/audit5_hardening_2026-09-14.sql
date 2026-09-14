-- ═══════════════════════════════════════════════════════════════
-- TAAM — 미감사 영역 5개 점검 후 SQL 로 닫히는 것 (2026-09-14)
-- ═══════════════════════════════════════════════════════════════
-- 근거: docs/AUDIT_2026-09-14_unaudited5.md
-- 앱·Edge 를 안 바꿔도 안전하다. 각 절은 독립된 DO 블록이라 하나가 실패해도
-- 나머지는 적용된다 (실패는 NOTICE 로 남고 마지막 확인 표에 ❌ 로 보인다).
--
--   ① 서버 전용 RPC 실행 권한 회수 — 알림 2개 · 대관 링크 결제 확정 2개
--      (anon/authenticated 에 남아 있으면 전 회원 방문 일정이 읽히고, 토큰만으로 청구가 'paid' 가 된다)
--   ② taam_kill_sessions(uuid) — 서버가 회원 세션을 실제로 폐기하는 함수 (partner-account 가 쓸 것)
--   ③ 탈퇴(taam_delete_my_account) — auth 계정 정지 + 세션·refresh token·active_sessions 폐기
--      (종전엔 프로필만 마스킹해 비밀번호 로그인·다른 기기 세션이 그대로 살았다)
--   ④ profiles.guest_expires_at 가드 — 회원이 자기 만료일을 못 고친다
--   ⑤ profiles.is_admin 가드 + 값 내리기 + 그 플래그를 보는 Storage 정책을 슈퍼어드민 전용으로
--   ⑥ 게스트 기한 연장은 **확정(active)** 된 구매만 — 홀드 INSERT 로 +90일 밀리던 것
--   ⑦ taam_invited_tier — 회원이 써넣은 phone/email 이 아니라 **auth.users 의 인증된 값**으로 초대를 찾는다
--      (남의 M 초대 번호를 알면 자기 계정에 M 이 붙던 길)
--   ⑧ restaurant-videos — 「로그인만 하면 업로드·덮어쓰기」를 파트너 어드민 업로드 · 슈퍼어드민 덮어쓰기로
--   ⑨ 버킷별 파일 크기·MIME 제한 (지금까지 클라이언트 검사뿐)
--
-- 실행: Supabase SQL Editor 에 통째로. 여러 번 돌려도 안전.
-- 결과: 마지막 표에 ❌ 가 한 줄도 없어야 정상. ⚠ 는 사람이 판단.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 서버 전용 RPC — 실행 권한 회수
-- ═══════════════════════════════════════════════════════════════
do $$
declare sig text;
begin
  foreach sig in array array[
    'public.taam_visit_reminder_notify()',
    'public.taam_guest_expiry_notify()',
    'public.taam_kashikiri_mark_paid(text,text,bigint,text,text)',
    'public.taam_kashikiri_mark_paid_v2(text,text,numeric,text,text,text)'
  ] loop
    if to_regprocedure(sig) is not null then
      execute 'revoke all on function ' || sig || ' from public, anon, authenticated';
      execute 'grant execute on function ' || sig || ' to service_role';
      raise notice '[①] % — service_role 만', sig;
    else
      raise notice '[①] % — 없음(건너뜀)', sig;
    end if;
  end loop;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ② taam_kill_sessions — 회원의 모든 세션·refresh token 을 서버에서 지운다
-- ═══════════════════════════════════════════════════════════════
--   GoTrue 어드민 API 에는 「user_id 로 로그아웃」이 없다(partner-account 가 uuid 를
--   JWT 자리에 넣어 부르던 것이 그래서 아무 일도 안 했다). DB 에서 지운다.
--   refresh_tokens 는 sessions 에 cascade 지만, 옛 행(session_id null)이 있을 수 있어 둘 다 지운다.
create or replace function public.taam_kill_sessions(p_uid uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n1 int := 0; n2 int := 0;
begin
  if p_uid is null then return 0; end if;
  begin
    delete from auth.refresh_tokens where user_id = p_uid::text;
    get diagnostics n1 = row_count;
  exception when others then
    raise notice '[kill_sessions] refresh_tokens 삭제 실패: %', sqlerrm;
  end;
  begin
    delete from auth.sessions where user_id = p_uid;
    get diagnostics n2 = row_count;
  exception when others then
    raise notice '[kill_sessions] sessions 삭제 실패: %', sqlerrm;
  end;
  begin
    delete from public.active_sessions where user_id = p_uid;
  exception when others then null;
  end;
  return n1 + n2;
end;
$$;
revoke all on function public.taam_kill_sessions(uuid) from public, anon, authenticated;
grant execute on function public.taam_kill_sessions(uuid) to service_role;
comment on function public.taam_kill_sessions(uuid) is
  '회원의 auth.sessions·refresh_tokens·active_sessions 를 지운다. service_role 전용 (Edge Function). access token 은 만료(기본 1h)까지 남는다.';


-- ═══════════════════════════════════════════════════════════════
-- ③ 탈퇴 — 프로필 마스킹에 더해 계정을 실제로 잠근다
-- ═══════════════════════════════════════════════════════════════
--   banned_until = infinity 면 GoTrue 가 모든 로그인·토큰 갱신을 거부한다.
--   번호·이메일은 그대로 둔다 — 「탈퇴한 번호로 재가입 불가」는 의도된 정책이다 (CLAUDE.md).
create or replace function public.taam_delete_my_account()
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ban boolean := false;
  v_kill int := 0;
begin
  if v_uid is null then
    return json_build_object('ok', false, 'error', 'not authenticated');
  end if;

  if exists (select 1 from public.profiles where id = v_uid and deleted_at is not null) then
    return json_build_object('ok', true, 'already', true);
  end if;

  update public.profiles
     set deleted_at   = now(),
         display_name = '탈퇴회원',
         phone        = null,
         email        = null,
         display_name_en = null
   where id = v_uid;

  begin
    update public.billing_keys set deleted_at = now()
     where user_id = v_uid and deleted_at is null;
  exception when others then null;
  end;

  begin
    delete from public.push_subscriptions where user_id = v_uid;
  exception when others then null;
  end;

  -- 🆕 2026-09-14 계정 잠금 + 세션 폐기
  begin
    update auth.users set banned_until = 'infinity'::timestamptz where id = v_uid;
    v_ban := true;
  exception when others then
    raise notice '[delete_my_account] banned_until 실패: %', sqlerrm;
  end;
  begin
    v_kill := public.taam_kill_sessions(v_uid);
  exception when others then null;
  end;

  return json_build_object('ok', true, 'banned', v_ban, 'sessions_killed', v_kill);
end;
$$;
revoke execute on function public.taam_delete_my_account() from public;
grant  execute on function public.taam_delete_my_account() to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- ④ guest_expires_at — 회원은 못 바꾼다 (값을 되돌린다)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_guest_expires()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.guest_expires_at is distinct from old.guest_expires_at then
    if auth.uid() is not null and not public._taam_uid_is_super() then
      new.guest_expires_at := old.guest_expires_at;
    end if;
  end if;
  return new;
end;
$$;
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles' and column_name='guest_expires_at') then
    drop trigger if exists trg_taam_guard_guest_expires on public.profiles;
    create trigger trg_taam_guard_guest_expires
      before update of guest_expires_at on public.profiles
      for each row execute function public.taam_guard_guest_expires();
    raise notice '[④] guest_expires_at 가드 설치';
  else
    raise notice '[④] profiles.guest_expires_at 컬럼 없음 — 건너뜀';
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑤ is_admin — 회원이 못 켠다 · 값 내림 · Storage 정책에서 제거
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_is_admin()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.is_admin is distinct from old.is_admin then
    if auth.uid() is not null and not public._taam_uid_is_super() then
      new.is_admin := old.is_admin;
    end if;
  end if;
  return new;
end;
$$;
do $$
declare r record; v_bkt text; v_n int := 0;
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles' and column_name='is_admin') then
    drop trigger if exists trg_taam_guard_is_admin on public.profiles;
    create trigger trg_taam_guard_is_admin
      before update of is_admin on public.profiles
      for each row execute function public.taam_guard_is_admin();
    update public.profiles set is_admin = false where is_admin is true;
    raise notice '[⑤] is_admin 가드 설치 + 값 내림';
  end if;

  -- 옛 사진 정책이 is_admin 을 보면 슈퍼어드민 전용으로 바꾼다 (버킷은 정책 본문에서 읽는다)
  for r in
    select policyname, cmd, coalesce(qual,'') as q, coalesce(with_check,'') as wc
      from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and (coalesce(qual,'') || coalesce(with_check,'')) like '%is_admin%'
  loop
    v_bkt := substring(r.q || r.wc from 'bucket_id = ''([^'']+)''');
    if v_bkt is null then
      raise notice '[⑤] 정책 % 의 버킷을 못 읽음 — 손으로 확인', r.policyname; continue;
    end if;
    if r.cmd = 'INSERT' then
      execute format('alter policy %I on storage.objects with check (bucket_id = %L and public._taam_uid_is_super())', r.policyname, v_bkt);
    elsif r.cmd = 'UPDATE' or r.cmd = 'ALL' then
      execute format('alter policy %I on storage.objects using (bucket_id = %L and public._taam_uid_is_super()) with check (bucket_id = %L and public._taam_uid_is_super())', r.policyname, v_bkt, v_bkt);
    else
      execute format('alter policy %I on storage.objects using (bucket_id = %L and public._taam_uid_is_super())', r.policyname, v_bkt);
    end if;
    v_n := v_n + 1;
  end loop;
  raise notice '[⑤] is_admin 을 보던 Storage 정책 % 개 정리', v_n;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑥ 게스트 기한 연장은 확정된 구매만
-- ═══════════════════════════════════════════════════════════════
--   종전: tickets AFTER INSERT 마다(홀드 포함) +90일. 회원은 status='hold' 행을 직접 넣을 수
--   있으므로(가드가 허용) 결제 없이 무한 연장이 됐다. 확정은 서버가 hold→active UPDATE 로
--   하므로 INSERT 만 봐서는 실제 구매를 놓친다 — INSERT·status UPDATE 둘 다 보고 active 만 센다.
create or replace function public.taam_guest_touch_on_purchase()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_days int; v_tier text;
begin
  if coalesce(new.status, '') <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and coalesce(old.status, '') = 'active' then return new; end if;   -- 이미 셌다
  if coalesce(new.purchase_id, '') like 'INVH-%' or coalesce(new.purchase_id, '') like 'PAYH-%' then return new; end if;

  select upper(coalesce(membership_tier,'')) into v_tier
    from public.profiles where id = new.user_id;
  if v_tier is distinct from 'A' then return new; end if;   -- 게스트만

  begin
    select coalesce((v#>>'{}')::int, 90) into v_days
      from public.membership_settings where k = 'guest_days';
  exception when others then v_days := 90; end;

  update public.profiles
     set guest_expires_at = now() + (coalesce(v_days, 90) || ' day')::interval
   where id = new.user_id;
  return new;
end;
$$;
do $$
begin
  if to_regclass('public.tickets') is not null then
    drop trigger if exists trg_taam_guest_touch_on_purchase on public.tickets;
    create trigger trg_taam_guest_touch_on_purchase
      after insert or update of status on public.tickets
      for each row execute function public.taam_guest_touch_on_purchase();
    raise notice '[⑥] 게스트 기한 연장 — active 만';
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑦ taam_invited_tier — 인증된 연락처로만 초대를 찾는다
-- ═══════════════════════════════════════════════════════════════
--   시그니처는 그대로(가드가 그대로 부른다). p_email/p_phone 은 이제 **무시**하고
--   auth.users 의 email/phone(OTP·소셜로 인증된 값)과 초대코드의 member_id 만 본다.
create or replace function public.taam_invited_tier(p_user_id uuid, p_email text, p_phone text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := '';
  v_pkey  text := '';
  v_tier  text;
begin
  if p_user_id is null then return null; end if;
  begin
    select lower(btrim(coalesce(u.email, ''))),
           public._taam_phone_key(coalesce(nullif(u.phone,''), u.raw_user_meta_data->>'phone'))
      into v_email, v_pkey
      from auth.users u where u.id = p_user_id;
  exception when others then
    v_email := ''; v_pkey := '';
  end;

  select upper(btrim(ic.invitee_tier))
    into v_tier
    from public.invite_codes ic
   where upper(btrim(coalesce(ic.invitee_tier,''))) in ('M','T','A')
     and (
          ic.member_id::text = p_user_id::text
       or (v_email <> '' and lower(btrim(coalesce(ic.used_by_email,''))) = v_email)
       or (v_email <> '' and lower(btrim(coalesce(ic.invitee_email,''))) = v_email)
       or (length(coalesce(v_pkey,'')) >= 8 and public._taam_phone_key(ic.used_by_phone) = v_pkey)
       or (length(coalesce(v_pkey,'')) >= 8 and public._taam_phone_key(ic.invitee_phone) = v_pkey)
     )
   order by ic.used_at desc nulls last
   limit 1;
  return v_tier;
end;
$$;
comment on function public.taam_invited_tier(uuid, text, text) is
  '이 회원의 초대코드가 지정한 등급. 2026-09-14 부터 인자의 email/phone 은 무시하고 auth.users 의 인증된 값만 쓴다.';


-- ═══════════════════════════════════════════════════════════════
-- ⑧ restaurant-videos — 파트너 어드민 업로드 · 슈퍼어드민 덮어쓰기
-- ═══════════════════════════════════════════════════════════════
do $$
declare r record; v_n int := 0;
begin
  if to_regclass('storage.objects') is null then raise notice '[⑧] storage 없음'; return; end if;
  -- 「bucket_id 만 보는」 authenticated INSERT/UPDATE/ALL 정책을 걷는다 (슈퍼어드민 조건이 있는 것은 둔다)
  for r in
    select policyname, cmd from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and (coalesce(qual,'') || coalesce(with_check,'')) like '%restaurant-videos%'
       and cmd in ('INSERT','UPDATE','ALL')
       and ('authenticated' = any(roles) or 'public' = any(roles) or 'anon' = any(roles))
       and (coalesce(qual,'') || coalesce(with_check,'')) not like '%_taam_uid_is_super%'
       and (coalesce(qual,'') || coalesce(with_check,'')) not like '%is_super_admin%'
       and (coalesce(qual,'') || coalesce(with_check,'')) not like '%is_superadmin%'
       and (coalesce(qual,'') || coalesce(with_check,'')) not like '%admin_grants%'
  loop
    execute format('drop policy %I on storage.objects', r.policyname);
    v_n := v_n + 1;
    raise notice '[⑧] 넓은 정책 제거: % (%)', r.policyname, r.cmd;
  end loop;

  -- 파트너 판정: admin_grants (파트너 계정 발급이 넣는 표) + 레거시 restaurant_admins (있으면)
  drop policy if exists restaurant_videos_partner_insert on storage.objects;
  execute 'create policy restaurant_videos_partner_insert on storage.objects for insert to authenticated with check ('
       || 'bucket_id = ''restaurant-videos'' and (public._taam_uid_is_super()'
       || ' or exists (select 1 from public.admin_grants g where g.user_id = auth.uid())'
       || case when to_regclass('public.restaurant_admins') is not null
               then ' or exists (select 1 from public.restaurant_admins ra where ra.user_id = auth.uid())' else '' end
       || '))';
  drop policy if exists restaurant_videos_super_update on storage.objects;
  create policy restaurant_videos_super_update on storage.objects
    for update to authenticated
    using (bucket_id = 'restaurant-videos' and public._taam_uid_is_super())
    with check (bucket_id = 'restaurant-videos' and public._taam_uid_is_super());
  raise notice '[⑧] restaurant-videos: 넓은 정책 % 개 제거 · 파트너 INSERT · 슈퍼어드민 UPDATE', v_n;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ⑨ 버킷 크기·MIME 제한
-- ═══════════════════════════════════════════════════════════════
do $$
begin
  if to_regclass('storage.buckets') is null then return; end if;
  update storage.buckets
     set file_size_limit = 10 * 1024 * 1024,
         allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif']
   where id in ('taam-photos','chef-photos','restaurant-photos','partner-logos','carousel-photos');
  update storage.buckets
     set file_size_limit = 30 * 1024 * 1024,
         allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime']
   where id = 'splash-media';
  update storage.buckets
     set file_size_limit = 50 * 1024 * 1024,
         allowed_mime_types = array['video/mp4','video/webm','video/quicktime']
   where id = 'restaurant-videos';
  raise notice '[⑨] 버킷 제한 적용';
exception when others then
  raise notice '[⑨] 버킷 제한 실패: %', sqlerrm;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 알림·대관 RPC 가 anon/authenticated 에 닫혔나 ⭐' as "구분",
       case when bool_and(not has_function_privilege('anon', p.oid, 'execute')
                     and not has_function_privilege('authenticated', p.oid, 'execute'))
            then '✅' else '❌ 열린 것 있음' end as "상태",
       string_agg(p.proname, ' · ') as "메모"
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('taam_visit_reminder_notify','taam_guest_expiry_notify','taam_kashikiri_mark_paid','taam_kashikiri_mark_paid_v2')
union all
select '② taam_kill_sessions (service_role 만)',
       case when to_regprocedure('public.taam_kill_sessions(uuid)') is not null
             and not has_function_privilege('authenticated', 'public.taam_kill_sessions(uuid)', 'execute')
            then '✅' else '❌' end, ''
union all
select '③ 탈퇴가 계정을 잠그나',
       case when p.prosrc like '%banned_until%' and p.prosrc like '%taam_kill_sessions%' then '✅' else '❌ 옛 판' end,
       'auth.users.banned_until + 세션 폐기'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_delete_my_account'
union all
select '④ guest_expires_at 가드',
       case when exists (select 1 from pg_trigger where tgname='trg_taam_guard_guest_expires' and not tgisinternal) then '✅' else '❌' end, ''
union all
select '⑤ is_admin 가드 · 남은 is_admin 정책',
       case when exists (select 1 from pg_trigger where tgname='trg_taam_guard_is_admin' and not tgisinternal)
             and not exists (select 1 from pg_policies where schemaname='storage'
                              and (coalesce(qual,'')||coalesce(with_check,'')) like '%is_admin%')
            then '✅' else '❌' end,
       coalesce((select string_agg(policyname, ' · ') from pg_policies where schemaname='storage'
                  and (coalesce(qual,'')||coalesce(with_check,'')) like '%is_admin%'), '남은 정책 없음')
union all
select '⑥ 게스트 연장은 active 만',
       case when p.prosrc like '%<> ''active''%' and p.prosrc like '%PAYH-%' then '✅' else '❌ 옛 판' end,
       'trigger: insert or update of status'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_guest_touch_on_purchase'
union all
select '⑦ 초대 등급을 auth.users 로 찾나 ⭐',
       case when p.prosrc like '%from auth.users u%' then '✅' else '❌ 옛 판 — 회원이 써넣은 번호로 찾는다' end, ''
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_invited_tier'
union all
select '⑧ restaurant-videos 정책',
       case when exists (select 1 from pg_policies where policyname='restaurant_videos_partner_insert')
             and exists (select 1 from pg_policies where policyname='restaurant_videos_super_update')
            then '✅' else '❌' end,
       coalesce((select string_agg(policyname || '[' || cmd || ']', ' · ') from pg_policies
                  where schemaname='storage' and (coalesce(qual,'')||coalesce(with_check,'')) like '%restaurant-videos%'), '')
union all
select '⑨ 버킷 제한',
       case when count(*) filter (where file_size_limit is null or allowed_mime_types is null) = 0 then '✅'
            else '⚠ 제한 없는 버킷: ' || string_agg(id, ', ') filter (where file_size_limit is null or allowed_mime_types is null) end,
       string_agg(id || '=' || coalesce((file_size_limit/1048576)::text,'∞') || 'MB', ' · ')
  from storage.buckets
order by 1;
