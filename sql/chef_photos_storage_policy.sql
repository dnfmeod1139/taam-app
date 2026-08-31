-- ═══════════════════════════════════════════════════════════════
-- TAAM — chef-photos 버킷에 슈퍼어드민을 더한다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제였나
--   셰프 사진 정리 도구가 Storage 업로드에서 전부 막혔다.
--     400 Bad Request · new row violates row-level security policy
--
--   chef-photos 정책 셋(INSERT·UPDATE·DELETE)이 이렇게 돼 있다.
--
--     bucket_id = 'chef-photos'
--     AND exists (select 1 from profiles
--                  where id = auth.uid() and is_admin = true)
--
--   **profiles.is_admin** 이라는 별도 불리언 컬럼만 본다. role 은 안 본다.
--   슈퍼어드민 계정의 is_admin 이 false/null 이라 통째로 막혔다.
--
--   다른 버킷들은 전부 is_superadmin() / is_super_admin(auth.uid()) 을 쓴다.
--   chef-photos 만 옛 플래그에 묶여 있었다.
--
-- 무엇을 하나
--   **기존 조건을 지우지 않고 슈퍼어드민을 or 로 더한다.**
--   is_admin=true 로 지금 잘 쓰고 있는 사람이 있을 수 있다 — 그 길을 끊으면
--   멀쩡히 되던 셰프 사진 업로드가 죽는다. 더하기만 하면 아무것도 안 깨진다.
--
--   ⚠ 대안은 「그 계정의 is_admin 을 true 로 켠다」였다. 그렇게 안 한 이유:
--     is_admin 이 다른 어디에서 무엇을 여는지 전부 확인하지 못했다. 뜻이
--     불분명한 플래그를 켜는 것보다, 의도가 드러나는 정책을 고치는 쪽이 낫다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════

do $$
begin
  -- INSERT — 정리 도구가 막힌 자리
  if exists (select 1 from pg_policies
              where schemaname='storage' and tablename='objects'
                and policyname='chef_photos_admin_write') then
    execute $p$
      alter policy chef_photos_admin_write on storage.objects
        with check (
          bucket_id = 'chef-photos'
          and (
            exists (select 1 from public.profiles p
                     where p.id = auth.uid() and p.is_admin = true)
            or public._taam_uid_is_super()
          )
        )
    $p$;
    raise notice '[chef-photos] INSERT 정책에 슈퍼어드민 추가';
  else
    raise notice '[chef-photos] INSERT 정책(chef_photos_admin_write)이 없습니다 — 건너뜀';
  end if;

  -- UPDATE — 같은 사진을 덮어쓸 때
  if exists (select 1 from pg_policies
              where schemaname='storage' and tablename='objects'
                and policyname='chef_photos_admin_update') then
    execute $p$
      alter policy chef_photos_admin_update on storage.objects
        using (
          bucket_id = 'chef-photos'
          and (
            exists (select 1 from public.profiles p
                     where p.id = auth.uid() and p.is_admin = true)
            or public._taam_uid_is_super()
          )
        )
    $p$;
    raise notice '[chef-photos] UPDATE 정책에 슈퍼어드민 추가';
  end if;

  -- DELETE — 사진을 바꿀 때 옛 파일을 지운다
  if exists (select 1 from pg_policies
              where schemaname='storage' and tablename='objects'
                and policyname='chef_photos_admin_delete') then
    execute $p$
      alter policy chef_photos_admin_delete on storage.objects
        using (
          bucket_id = 'chef-photos'
          and (
            exists (select 1 from public.profiles p
                     where p.id = auth.uid() and p.is_admin = true)
            or public._taam_uid_is_super()
          )
        )
    $p$;
    raise notice '[chef-photos] DELETE 정책에 슈퍼어드민 추가';
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 세 정책에 _taam_uid_is_super 가 들어갔나
-- ═══════════════════════════════════════════════════════════════
select policyname                                   as "정책",
       cmd                                          as "동작",
       case when coalesce(qual,'') || coalesce(with_check,'') like '%_taam_uid_is_super%'
            then '✅ 슈퍼어드민 포함' else '❌ 아직' end as "결과"
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and policyname like 'chef_photos%'
order by cmd;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   or public._taam_uid_is_super() 만 빼고 다시 alter policy 하면 된다.
--   원래 조건:
--     bucket_id = 'chef-photos'
--     and exists (select 1 from public.profiles p
--                  where p.id = auth.uid() and p.is_admin = true)
