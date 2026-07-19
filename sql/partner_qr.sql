-- ═══════════════════════════════════════════════════════════════
-- TAAM — 레스토랑 전용 파트너 QR (개인화 제안 페이지 + 열람 기록)
-- Supabase SQL Editor 에서 1회 실행 (idempotent)
-- 작성일: 2026-07-19
-- 구조:
--   · partner_qr_codes  — 레스토랑별 고유 코드 (슈퍼어드민이 발급)
--   · partner_qr_views  — QR 열람 기록 (누가 언제 열었는지)
--   · partner_qr_lookup(code) — 랜딩 페이지용 RPC (anon 호출 가능):
--       코드 검증 + 열람 기록 + 레스토랑/셰프/언어 반환
-- 접근 제어:
--   · 테이블 직접 접근은 슈퍼어드민(is_super_admin)만 (RLS)
--   · 외부(북릿 QR 스캔)는 RPC 를 통해서만 — 유효 코드 1건의
--     이름/언어만 노출되고 목록 조회는 불가능
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 코드 테이블 ──
create table if not exists public.partner_qr_codes (
  code            text primary key,                 -- 예: 'X7K2MQ4A'
  restaurant_name text not null,
  chef_name       text,
  lang            text not null default 'ja',       -- 'ja' | 'en'
  active          boolean not null default true,    -- false = 링크 비활성화
  created_at      timestamptz not null default now()
);
comment on table public.partner_qr_codes is
  '레스토랑 전용 파트너 제안 QR 코드. taam-app.vercel.app/partner/?c=<code> 로 개인화 페이지 오픈.';

-- ── 2) 열람 기록 테이블 ──
create table if not exists public.partner_qr_views (
  id         bigint generated always as identity primary key,
  code       text not null references public.partner_qr_codes(code) on delete cascade,
  viewed_at  timestamptz not null default now(),
  user_agent text
);
create index if not exists idx_partner_qr_views_code on public.partner_qr_views(code, viewed_at desc);
comment on table public.partner_qr_views is '파트너 QR 열람 기록 — 셰프가 언제 열어봤는지 팔로업용.';

-- ── 3) RLS — 슈퍼어드민만 직접 접근 ──
alter table public.partner_qr_codes enable row level security;
alter table public.partner_qr_views enable row level security;

drop policy if exists "superadmin manages partner qr codes" on public.partner_qr_codes;
create policy "superadmin manages partner qr codes"
on public.partner_qr_codes
for all
to authenticated
using ( public.is_super_admin(auth.uid()) )
with check ( public.is_super_admin(auth.uid()) );

drop policy if exists "superadmin reads partner qr views" on public.partner_qr_views;
create policy "superadmin reads partner qr views"
on public.partner_qr_views
for select
to authenticated
using ( public.is_super_admin(auth.uid()) );

-- ── 4) 랜딩 페이지용 RPC — 코드 검증 + 열람 기록 ──
-- p_log=false 면 기록 없이 조회만 (슈퍼어드민 미리보기용)
create or replace function public.partner_qr_lookup(p_code text, p_ua text default null, p_log boolean default true)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.partner_qr_codes%rowtype;
begin
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
    'chef_name', coalesce(r.chef_name, ''),
    'lang', r.lang
  );
end;
$$;
comment on function public.partner_qr_lookup(text, text, boolean) is
  '파트너 QR 랜딩 페이지 검증용. 유효 코드면 레스토랑/셰프/언어 반환 + 열람 기록.';

revoke execute on function public.partner_qr_lookup(text, text, boolean) from public;
grant execute on function public.partner_qr_lookup(text, text, boolean) to anon;
grant execute on function public.partner_qr_lookup(text, text, boolean) to authenticated;

do $$ begin raise notice '✅ 파트너 전용 QR 테이블 + RPC 설치 완료'; end $$;
