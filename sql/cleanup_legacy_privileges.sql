-- ═══════════════════════════════════════════════════════════════
-- TAAM — 옛 흔적 정리: 중복 트리거 · is_admin 플래그 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- ① profiles 에 같은 일을 하는 트리거가 둘이었다
--
--     trg_sync_deposit_balance       BEFORE INSERT OR UPDATE OF (멤버십·일반)
--       → sync_deposit_balance_total()
--     trg_taam_sync_deposit_balance  BEFORE INSERT OR UPDATE (모든 컬럼)
--       → taam_sync_deposit_balance()
--
--   두 함수의 본문을 떠서 비교했다. **한 글자도 다르지 않다.**
--     new.deposit_balance := coalesce(멤버십,0) + coalesce(일반,0);
--
--   ⚠ 어느 쪽을 남길지가 중요하다. BEFORE 트리거는 **이름 알파벳 순**으로 돈다.
--
--     trg_sync_deposit_balance        ← 합계 계산
--     trg_taam_guard_deposit_balance  ← 가드들
--     trg_taam_guard_membership_tier
--     trg_taam_guard_profile_currency
--     trg_taam_guard_profile_role
--     trg_taam_sync_deposit_balance   ← 합계 다시 계산
--
--   가드가 값을 되돌리는 경우(등급·role 가드는 실제로 되돌린다) 합계를
--   맞춰 주는 건 **마지막에 도는 쪽**이다. 그래서 taam_ 쪽을 남기고
--   앞의 것을 지운다. 반대로 지우면 되돌린 뒤의 합계가 어긋날 수 있다.
--
-- ② profiles.is_admin — 앱이 안 쓰는 옛 플래그
--   index.html 전체에 이 값을 읽거나 쓰는 코드가 한 줄도 없다.
--   참조하는 건 스토리지 정책 여섯 개뿐이었고, 그 탓에 슈퍼어드민이
--   사진을 못 올리는 상태였다(오늘 or 조건으로 임시 조치).
--   켜져 있던 계정은 사장님 서브 계정 하나이고, 권한이 필요 없다고 확인받았다.
--   → 정책을 「슈퍼어드민만」으로 정리하고 플래그를 내린다. 뜻이 분명해진다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포 필요 없음.
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
-- ① 중복 트리거 정리
-- ═══════════════════════════════════════════════════════════════
do $$
begin
  -- 남길 쪽이 실제로 있는지 먼저 본다. 없으면 아무것도 지우지 않는다.
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.profiles'::regclass
                    and tgname = 'trg_taam_sync_deposit_balance') then
    raise notice '[cleanup] trg_taam_sync_deposit_balance 가 없습니다 — 아무것도 지우지 않습니다';
    return;
  end if;

  if exists (select 1 from pg_trigger
              where tgrelid = 'public.profiles'::regclass
                and tgname = 'trg_sync_deposit_balance') then
    drop trigger trg_sync_deposit_balance on public.profiles;
    raise notice '[cleanup] 중복 트리거 제거: trg_sync_deposit_balance';
  else
    raise notice '[cleanup] trg_sync_deposit_balance 없음 — 이미 정리됨';
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ② 사진 버킷 정책을 「슈퍼어드민만」으로
-- ═══════════════════════════════════════════════════════════════
--   오늘은 is_admin 조건을 남겨 둔 채 슈퍼어드민을 or 로 더했다.
--   그 플래그를 쓰는 계정이 없어졌으므로 이제 조건을 지운다.
do $$
declare
  v_pol text;
  v_cmd text;
  v_bkt text;
  v_n   int := 0;
begin
  for v_pol, v_cmd in
    select policyname, cmd from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname in ('chef_photos_admin_write','chef_photos_admin_update','chef_photos_admin_delete',
                          'rest_photos_admin_write','rest_photos_admin_update','rest_photos_admin_delete')
  loop
    v_bkt := case when v_pol like 'chef%' then 'chef-photos' else 'restaurant-photos' end;
    if v_cmd = 'INSERT' then
      execute format(
        'alter policy %I on storage.objects with check (bucket_id = %L and public._taam_uid_is_super())',
        v_pol, v_bkt);
    else
      execute format(
        'alter policy %I on storage.objects using (bucket_id = %L and public._taam_uid_is_super())',
        v_pol, v_bkt);
    end if;
    v_n := v_n + 1;
  end loop;
  raise notice '[cleanup] 사진 정책 % 개를 슈퍼어드민 전용으로 정리', v_n;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ③ is_admin 플래그 내리기
-- ═══════════════════════════════════════════════════════════════
--   컬럼 자체는 지우지 않는다 — 어딘가 남은 참조가 있으면 그때 터진다.
--   값만 내려서 아무 효력이 없게 만든다.
update public.profiles set is_admin = false where is_admin is true;


-- ═══════════════════════════════════════════════════════════════
-- 확인
-- ═══════════════════════════════════════════════════════════════
select '① profiles 트리거' as "구분",
       tgname             as "이름",
       case when tgname = 'trg_sync_deposit_balance' then '❌ 아직 남음' else '✅' end as "상태"
  from pg_trigger
 where tgrelid = 'public.profiles'::regclass and not tgisinternal
union all
select '② 사진 정책',
       cmd || ' · ' || policyname,
       case when coalesce(qual,'') || coalesce(with_check,'') like '%is_admin%'
            then '❌ is_admin 아직 있음' else '✅ 슈퍼어드민만' end
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
   and (policyname like 'chef_photos_admin%' or policyname like 'rest_photos_admin%')
union all
select '③ is_admin=true 인원',
       count(*)::text,
       case when count(*) = 0 then '✅ 없음' else '❌ 남아 있음' end
  from public.profiles where is_admin is true
order by 1, 2;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   ① 중복 트리거 (지운 것과 같은 정의)
--      create trigger trg_sync_deposit_balance
--        before insert or update of membership_deposit_balance, general_deposit_balance
--        on public.profiles for each row
--        execute function sync_deposit_balance_total();
--
--   ② 정책에 is_admin 을 되살리려면 sql/chef_photos_storage_policy.sql 과
--      sql/restaurant_photos_storage_policy.sql 을 다시 돌린다 (or 조건이 붙는다).
--
--   ③ update public.profiles set is_admin = true where id = '<그 계정>';
