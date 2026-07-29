-- ═══════════════════════════════════════════════════════════════
-- TAAM — 시작화면(스플래시) 동영상 저장용 Storage 버킷
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 실행 안전)
-- 사진은 기존대로 app_config 에 base64 로 저장하지만, 동영상은 용량이 커서
-- Storage 버킷에 올리고 URL 만 app_config 에 저장한다.
-- ═══════════════════════════════════════════════════════════════

-- 공개 읽기 버킷 (스플래시는 로그인 전에도 보여야 하므로 public)
insert into storage.buckets (id, name, public)
values ('splash-media', 'splash-media', true)
on conflict (id) do update set public = true;

-- 누구나 읽기 (익명 포함 — 로그인 전 스플래시 재생용)
drop policy if exists "splash media public read" on storage.objects;
create policy "splash media public read"
on storage.objects for select to public
using ( bucket_id = 'splash-media' );

-- 슈퍼어드민만 업로드
drop policy if exists "splash media superadmin write" on storage.objects;
create policy "splash media superadmin write"
on storage.objects for insert to authenticated
with check ( bucket_id = 'splash-media' and public.is_superadmin() );

-- 슈퍼어드민만 삭제
drop policy if exists "splash media superadmin delete" on storage.objects;
create policy "splash media superadmin delete"
on storage.objects for delete to authenticated
using ( bucket_id = 'splash-media' and public.is_superadmin() );

do $$ begin raise notice '✅ splash-media 버킷 + 정책 설치 완료'; end $$;
