-- ═══════════════════════════════════════════════════════════════
-- TAAM — 레스토랑 전용 파트너 QR (개인화 제안·조건 페이지 + 열람 기록)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 실행해도 안전)
-- 작성일: 2026-07-19  /  v2: 2026-07-20 (가격 조건 + 파트너 로고)
-- 구조:
--   · partner_qr_codes  — 레스토랑별 고유 코드 + 협의 조건(식사/주류/기타)
--   · partner_qr_views  — QR 열람 기록
--   · partner_logos     — 전용 페이지 하단 「함께하는 파트너」 로고
--   · partner_qr_lookup(code) — 랜딩 페이지용 RPC (anon):
--       코드 검증 + 열람 기록 + 레스토랑/셰프/언어/조건/로고 반환
--   · Storage 버킷 'partner-logos' (public) — 로고 이미지 저장
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 코드 테이블 ──
create table if not exists public.partner_qr_codes (
  code            text primary key,
  restaurant_name text not null,
  chef_name       text,
  lang            text not null default 'ja',       -- 'ja' | 'en' | 'ko'
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);
-- v2: 협의 조건 컬럼 (자유 기재 — 예: '¥30,000 / 1인')
alter table public.partner_qr_codes add column if not exists meal_price     text;
alter table public.partner_qr_codes add column if not exists beverage_price text;
alter table public.partner_qr_codes add column if not exists extra_note     text;
comment on table public.partner_qr_codes is
  '레스토랑 전용 파트너 제안 QR. taam-app.vercel.app/partner/?c=<code> 로 개인화 페이지 오픈.';

-- ── 2) 열람 기록 ──
create table if not exists public.partner_qr_views (
  id         bigint generated always as identity primary key,
  code       text not null references public.partner_qr_codes(code) on delete cascade,
  viewed_at  timestamptz not null default now(),
  user_agent text
);
create index if not exists idx_partner_qr_views_code on public.partner_qr_views(code, viewed_at desc);

-- ── 3) 파트너 로고 ──
create table if not exists public.partner_logos (
  id         bigint generated always as identity primary key,
  image_url  text not null,
  name       text,
  sort_order int  not null default 0,
  created_at timestamptz not null default now()
);
comment on table public.partner_logos is '전용 페이지 하단 「함께하는 파트너」 로고 목록.';

-- ── 4) RLS ──
alter table public.partner_qr_codes enable row level security;
alter table public.partner_qr_views enable row level security;
alter table public.partner_logos    enable row level security;

drop policy if exists "superadmin manages partner qr codes" on public.partner_qr_codes;
create policy "superadmin manages partner qr codes"
on public.partner_qr_codes for all to authenticated
using ( public.is_super_admin(auth.uid()) ) with check ( public.is_super_admin(auth.uid()) );

drop policy if exists "superadmin reads partner qr views" on public.partner_qr_views;
create policy "superadmin reads partner qr views"
on public.partner_qr_views for select to authenticated
using ( public.is_super_admin(auth.uid()) );

drop policy if exists "superadmin manages partner logos" on public.partner_logos;
create policy "superadmin manages partner logos"
on public.partner_logos for all to authenticated
using ( public.is_super_admin(auth.uid()) ) with check ( public.is_super_admin(auth.uid()) );

-- 🆕 파트너 로고는 공개 노출용 → anon/authenticated 읽기 허용 (랜딩 페이지 직접 조회)
drop policy if exists "partner logos public read" on public.partner_logos;
create policy "partner logos public read"
on public.partner_logos for select to public
using ( true );

-- ── 5) Storage 버킷 (public) + 정책 ──
insert into storage.buckets (id, name, public)
values ('partner-logos', 'partner-logos', true)
on conflict (id) do update set public = true;

drop policy if exists "partner logos public read" on storage.objects;
create policy "partner logos public read"
on storage.objects for select to public
using ( bucket_id = 'partner-logos' );

drop policy if exists "partner logos superadmin write" on storage.objects;
create policy "partner logos superadmin write"
on storage.objects for insert to authenticated
with check ( bucket_id = 'partner-logos' and public.is_super_admin(auth.uid()) );

drop policy if exists "partner logos superadmin delete" on storage.objects;
create policy "partner logos superadmin delete"
on storage.objects for delete to authenticated
using ( bucket_id = 'partner-logos' and public.is_super_admin(auth.uid()) );

-- ── 6) 랜딩 페이지용 RPC — 코드 검증 + 열람 기록 + 조건/로고 반환 ──
create or replace function public.partner_qr_lookup(p_code text, p_ua text default null, p_log boolean default true)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.partner_qr_codes%rowtype;
begin
  -- 기본(GENERIC) QR — 이름·매장·금액 없이 로고만 (기본 전달 메시지용)
  if upper(trim(coalesce(p_code,''))) = 'GENERIC' then
    return json_build_object(
      'ok', true, 'generic', true,
      'restaurant_name','', 'chef_name','', 'lang','',
      'meal_price','', 'beverage_price','', 'extra_note','',
      'logos', coalesce(
        (select json_agg(image_url order by sort_order, id) from public.partner_logos),
        '[]'::json)
    );
  end if;

  select * into r
  from public.partner_qr_codes
  where code = upper(trim(p_code)) and active = true;

  if not found then
    return json_build_object('ok', false);
  end if;

  if coalesce(p_log, true) then
    insert into public.partner_qr_views(code, user_agent)
    values (r.code, left(coalesce(p_ua, ''), 400));
  end if;

  return json_build_object(
    'ok', true,
    'restaurant_name', r.restaurant_name,
    'chef_name',       coalesce(r.chef_name, ''),
    'lang',            r.lang,
    'meal_price',      coalesce(r.meal_price, ''),
    'beverage_price',  coalesce(r.beverage_price, ''),
    'extra_note',      coalesce(r.extra_note, ''),
    'logos', coalesce(
      (select json_agg(image_url order by sort_order, id) from public.partner_logos),
      '[]'::json)
  );
end;
$$;
comment on function public.partner_qr_lookup(text, text, boolean) is
  '파트너 QR 랜딩 검증용. 유효 코드면 레스토랑/셰프/언어/조건/로고 반환 + 열람 기록.';

revoke execute on function public.partner_qr_lookup(text, text, boolean) from public;
grant  execute on function public.partner_qr_lookup(text, text, boolean) to anon;
grant  execute on function public.partner_qr_lookup(text, text, boolean) to authenticated;

do $$ begin raise notice '✅ 파트너 전용 QR v2 — 조건 컬럼 + 로고 테이블/버킷 + RPC 설치 완료'; end $$;
