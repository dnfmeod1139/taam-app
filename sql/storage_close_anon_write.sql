-- ═══════════════════════════════════════════════════════════════
-- TAAM — 로그인 없이 쓰고 지울 수 있던 버킷 두 개를 닫는다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제였나
--   storage.objects 정책을 훑다가 나왔다.
--
--     anon_full_access_carousel   ALL  {anon, authenticated}  bucket_id='carousel-photos'
--     anon_full_access_videos     ALL  {anon, authenticated}  bucket_id='restaurant-videos'
--
--   ALL 은 INSERT·UPDATE·**DELETE** 전부고, 조건이 버킷 이름 하나뿐이다.
--   anon 키는 index.html 에 공개돼 있으므로 **로그인조차 필요 없다.**
--   홈 캐러셀 사진과 레스토랑 영상을 아무나 갈아치우거나 지울 수 있었다.
--
--   다른 버킷(chef-photos · restaurant-photos · taam-photos · splash-media ·
--   partner-logos)은 전부 어드민/슈퍼어드민 조건이 걸려 있다. 이 둘만 예외였다.
--
-- 왜 그냥 지우면 되나
--   두 버킷 모두 **제대로 된 정책이 이미 따로 있다.**
--     carousel_photos_insert/update/delete_superadmin · carousel_photos_select_authenticated
--     restaurant_videos_insert/update/delete_superadmin · Public read videos
--   정책은 OR 로 합쳐지므로, anon_full_access_* 가 그 위를 덮고 있었을 뿐이다.
--   지우면 원래 의도대로 돌아간다.
--
-- 영상 업로드는 왜 남기나
--   파트너 어드민이 「나의 레스토랑」에서 히어로 영상을 올린다
--   (index.html:34484). 여기를 슈퍼어드민 전용으로 좁히면 그게 깨진다.
--   그래서 authenticated 의 INSERT·UPDATE 는 **남기고**, DELETE 만 걷는다.
--   앱에는 영상을 지우는 코드가 아예 없다 — 교체는 새 파일명으로 올린다.
--   지우는 건 슈퍼어드민만 하면 된다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포 필요 없음.
-- ═══════════════════════════════════════════════════════════════

do $$
declare
  v_dropped text[] := '{}';
begin
  -- ── 로그인 없이 전부 되던 정책 두 개 ────────────────────────────
  if exists (select 1 from pg_policies where schemaname='storage' and tablename='objects'
              and policyname='anon_full_access_carousel') then
    execute 'drop policy anon_full_access_carousel on storage.objects';
    v_dropped := array_append(v_dropped, 'anon_full_access_carousel');
  end if;

  if exists (select 1 from pg_policies where schemaname='storage' and tablename='objects'
              and policyname='anon_full_access_videos') then
    execute 'drop policy anon_full_access_videos on storage.objects';
    v_dropped := array_append(v_dropped, 'anon_full_access_videos');
  end if;

  -- ── 로그인만 하면 영상을 지울 수 있던 정책들 ──────────────────
  --   업로드(INSERT)·교체(UPDATE)는 남긴다 — 파트너 어드민이 쓴다.
  --   삭제는 슈퍼어드민 정책(restaurant_videos_delete_superadmin)만 남는다.
  if exists (select 1 from pg_policies where schemaname='storage' and tablename='objects'
              and policyname='Authenticated delete videos') then
    execute 'drop policy "Authenticated delete videos" on storage.objects';
    v_dropped := array_append(v_dropped, 'Authenticated delete videos');
  end if;

  if exists (select 1 from pg_policies where schemaname='storage' and tablename='objects'
              and policyname='Authenticated can manage videos j552aw_3') then
    execute 'drop policy "Authenticated can manage videos j552aw_3" on storage.objects';
    v_dropped := array_append(v_dropped, 'Authenticated can manage videos j552aw_3');
  end if;

  if array_length(v_dropped, 1) is null then
    raise notice '[storage] 지울 정책이 없습니다 — 이미 정리됐습니다.';
  else
    raise notice '[storage] 지운 정책: %', array_to_string(v_dropped, ', ');
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 두 버킷에 이제 무엇이 남았나
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 「역할」에 anon 이 들어간 쓰기(INSERT/UPDATE/DELETE) 줄이 하나도
--     없어야 정상이다. SELECT 는 공개 읽기라 있어도 된다.
select cmd                                   as "동작",
       policyname                            as "정책",
       roles::text                           as "역할",
       case
         when cmd = 'SELECT' then '읽기 — 공개여도 됨'
         when roles::text like '%anon%' then '🔴 로그인 없이 쓰기 가능'
         when coalesce(qual,'') || coalesce(with_check,'') like '%is_super%'
           or coalesce(qual,'') || coalesce(with_check,'') like '%is_admin%' then '✅ 어드민 조건 있음'
         else '🟡 로그인만 하면 됨'
       end                                   as "판정"
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and (coalesce(qual,'') || coalesce(with_check,'')
        like any (array['%carousel-photos%', '%restaurant-videos%']))
order by
  case cmd when 'INSERT' then 1 when 'UPDATE' then 2 when 'DELETE' then 3 else 4 end,
  policyname;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   지운 것은 「누구나 전부 가능」이었으므로 되살릴 이유가 거의 없다.
--   그래도 필요하면:
--
--   create policy anon_full_access_carousel on storage.objects
--     for all to anon, authenticated
--     using (bucket_id = 'carousel-photos') with check (bucket_id = 'carousel-photos');
--
--   create policy anon_full_access_videos on storage.objects
--     for all to anon, authenticated
--     using (bucket_id = 'restaurant-videos') with check (bucket_id = 'restaurant-videos');
--
-- ═══════════════════════════════════════════════════════════════
-- 남은 것
-- ═══════════════════════════════════════════════════════════════
--   ⓐ restaurant-videos 는 여전히 「로그인한 회원이면 업로드 가능」이다.
--      파트너 어드민 업로드를 살리려고 남겼다. 남의 매장 영상을 덮어쓰진
--      못하지만(파일명이 매번 새로 생긴다), 용량을 채울 수는 있다.
--      파트너 어드민을 서버에서 식별하는 방법(admin_grants)을 조건에 넣으면
--      좁힐 수 있다 — 그때 restaurants.id 와 파일 경로를 묶는 설계가 필요하다.
--   ⓑ chef-photos · restaurant-photos 는 profiles.is_admin 이라는 옛 플래그를
--      본다. 그 플래그가 어디에서 무엇을 여는지 전수 확인이 아직 안 됐다.
