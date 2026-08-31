-- ═══════════════════════════════════════════════════════════════
-- TAAM — restaurant-photos 버킷도 슈퍼어드민을 모른다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 하나
--   chef-photos 를 고치면서 정책을 훑다가 같은 모양을 하나 더 봤다.
--
--     rest_photos_admin_write / _update / _delete
--       bucket_id = 'restaurant-photos'
--       AND exists (select 1 from profiles
--                    where id = auth.uid() and is_admin = true)
--
--   chef-photos 와 똑같이 **profiles.is_admin 만** 본다.
--
--   그런데 is_admin 은 앱 어디에서도 쓰이지 않는다 — index.html 전체를
--   훑어도 이 플래그를 읽거나 쓰는 코드가 한 줄도 없다. 옛 흔적이다.
--   슈퍼어드민 계정의 is_admin 이 false/null 이라 chef-photos 가 막혔던
--   것처럼, **레스토랑 사진 업로드도 지금 막혀 있을 가능성이 높다.**
--   (index.html:79988 의 「📷 버튼 → restaurant-photos 업로드」 경로)
--
-- 무엇을 하나
--   chef-photos 와 같은 방식. 기존 is_admin 조건을 **지우지 않고**
--   슈퍼어드민을 or 로 더한다. 지금 is_admin=true 로 쓰고 있는 계정이
--   있다면 그 길은 그대로 남는다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포 필요 없음.
-- ═══════════════════════════════════════════════════════════════

do $$
declare
  v_done text[] := '{}';
  v_pol  text;
  v_cmd  text;
begin
  for v_pol, v_cmd in
    select policyname, cmd from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname in ('rest_photos_admin_write',
                          'rest_photos_admin_update',
                          'rest_photos_admin_delete')
  loop
    if v_cmd = 'INSERT' then
      execute format($p$
        alter policy %I on storage.objects
          with check (
            bucket_id = 'restaurant-photos'
            and (exists (select 1 from public.profiles p
                          where p.id = auth.uid() and p.is_admin = true)
                 or public._taam_uid_is_super())
          )$p$, v_pol);
    else
      execute format($p$
        alter policy %I on storage.objects
          using (
            bucket_id = 'restaurant-photos'
            and (exists (select 1 from public.profiles p
                          where p.id = auth.uid() and p.is_admin = true)
                 or public._taam_uid_is_super())
          )$p$, v_pol);
    end if;
    v_done := array_append(v_done, v_pol || '(' || v_cmd || ')');
  end loop;

  if array_length(v_done, 1) is null then
    raise notice '[restaurant-photos] 대상 정책이 없습니다 — 건너뜀';
  else
    raise notice '[restaurant-photos] 슈퍼어드민 추가: %', array_to_string(v_done, ', ');
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 사진 버킷 두 개가 이제 같은 모양인가
-- ═══════════════════════════════════════════════════════════════
select cmd                                   as "동작",
       policyname                            as "정책",
       case when coalesce(qual,'') || coalesce(with_check,'') like '%_taam_uid_is_super%'
            then '✅ 슈퍼어드민 포함'
            when cmd = 'SELECT' then '읽기 — 공개'
            else '❌ 아직 is_admin 만' end   as "결과"
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and (policyname like 'chef_photos%' or policyname like 'rest_photos%')
order by policyname, cmd;


-- ═══════════════════════════════════════════════════════════════
-- 남은 것 — is_admin 은 결국 어떻게 할 것인가
-- ═══════════════════════════════════════════════════════════════
--   앱은 이 플래그를 전혀 안 쓴다. 지금 이 값이 true 인 사람이 있는지 본다.
--
--     select id, display_name, role, is_admin from public.profiles
--      where is_admin is true;
--
--   0명이면 조건에서 빼도 아무 일이 안 난다. 그때 정책을
--   「슈퍼어드민만」으로 정리하면 뜻이 분명해진다.
--   지금은 확인 전이라 지우지 않고 더하기만 했다.
