-- ═══════════════════════════════════════════════════════════════
-- TAAM — 사진 캘린더 (첫 화면 개편) 저장소 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   첫 화면을 「사진 타일 캘린더」로 바꾼다. 날짜 칸 자체가 그 날 요리
--   사진이 되고, 사진 있는 칸 = 그 날 자리가 있다는 뜻이다.
--   화면이 필요로 하는 데이터는 셋뿐이다.
--     ① 월별 히어로 사진 · 지역        → month_covers (신규)
--     ② 날짜별 타일 사진               → ticket_products.tile_photo (컬럼 추가)
--     ③ 매장명·시간·정원·코스·잔여석   → 이미 있음 (건드리지 않는다)
--
--   그래서 새로 만드는 건 테이블 1개 + 컬럼 1개 + 사진 버킷 1개다.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 타일 사진 컬럼 ──────────────────────────────────────────
--   Storage 의 public URL 을 담는다. 원본이 아니라 이미 보정된 파일을 가리킨다
--   (평균 휘도 108 · 채도 ×0.88 · 대비 ×1.06 — 업로드 시 서버에서 1회 처리).
alter table public.ticket_products
  add column if not exists tile_photo text;

comment on column public.ticket_products.tile_photo is
  '사진 캘린더 타일 이미지 URL. 정사각 중앙 크롭 + 휘도 정규화된 파일만 넣는다. 요리 단품 클로즈업 전용 — 실내 전경·인물컷 금지.';


-- ── ② 월별 표지 ───────────────────────────────────────────────
create table if not exists public.month_covers (
  year        int  not null,
  month       int  not null check (month between 1 and 12),
  photo_url   text,                     -- 히어로 사진 (인물·요리 모두 가능)
  regions     text,                     -- 예: '도쿄 · 오사카 · 교토'
  photo_credit text,                    -- 예: 'Photography · 우종'
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null,
  primary key (year, month)
);

comment on table public.month_covers is
  '사진 캘린더의 월별 히어로. 슈퍼어드민이 매달 갈아 끼운다. 없으면 앱이 그 달 타일 중 한 장으로 대체한다.';

alter table public.month_covers enable row level security;

-- 읽기: 로그인한 회원 전원 (첫 화면이라 모두 본다)
drop policy if exists month_covers_read on public.month_covers;
create policy month_covers_read on public.month_covers
  for select to authenticated using (true);

-- 쓰기: 슈퍼어드민만
drop policy if exists month_covers_write on public.month_covers;
create policy month_covers_write on public.month_covers
  for all to authenticated
  using (is_super_admin(auth.uid()))
  with check (is_super_admin(auth.uid()));


-- ── ③ 사진 버킷 ───────────────────────────────────────────────
--   히어로·타일 사진을 담는다. index.html 에 base64 로 박으면 파일이 다시
--   비대해진다(예전에 25MB 까지 갔던 이유) — 반드시 Storage 를 쓴다.
insert into storage.buckets (id, name, public)
values ('taam-photos', 'taam-photos', true)
on conflict (id) do nothing;

-- 읽기: 공개 (앱이 <img> 로 바로 부른다)
drop policy if exists taam_photos_read on storage.objects;
create policy taam_photos_read on storage.objects
  for select to public
  using (bucket_id = 'taam-photos');

-- 업로드·교체·삭제: 슈퍼어드민만
drop policy if exists taam_photos_write on storage.objects;
create policy taam_photos_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'taam-photos' and is_super_admin(auth.uid()));

drop policy if exists taam_photos_update on storage.objects;
create policy taam_photos_update on storage.objects
  for update to authenticated
  using (bucket_id = 'taam-photos' and is_super_admin(auth.uid()));

drop policy if exists taam_photos_delete on storage.objects;
create policy taam_photos_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'taam-photos' and is_super_admin(auth.uid()));


-- ── 확인 ──────────────────────────────────────────────────────
select 'ticket_products.tile_photo' as 항목,
       (select count(*) from information_schema.columns
         where table_schema='public' and table_name='ticket_products'
           and column_name='tile_photo')::text as 상태
union all
select 'month_covers', (select count(*) from public.month_covers)::text || '개월 등록됨'
union all
select 'taam-photos 버킷', (select count(*) from storage.buckets where id='taam-photos')::text;

do $$ begin raise notice '✅ 사진 캘린더 저장소 준비 완료'; end $$;
