-- ═══════════════════════════════════════════════════════════════
-- TAAM — daegwan_manual (티켓 캘린더: 수기 예약) (2026-06-19)
-- ═══════════════════════════════════════════════════════════════
-- 앱 초대/티켓으로 처리 못 하는 예약을 슈퍼어드민이 캘린더에 직접 기재.
-- 이름·인원·메모만. pax 는 초대/티켓과 동일하게 점유 인원 카운팅에 합산됨.
-- venue_id = 매장 식별자(text), ymd = 날짜.
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent).
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.daegwan_manual (
  id          uuid primary key default gen_random_uuid(),
  venue_id    text not null,
  ymd         date not null,
  name        text,
  pax         integer not null default 1,
  memo        text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);

comment on table public.daegwan_manual is
  '티켓 캘린더 수기 예약(앱 초대 불가 상황). pax 가 점유 인원 카운팅에 합산.';

create index if not exists idx_daegwan_manual_vd on public.daegwan_manual(venue_id, ymd);

-- RLS: 슈퍼어드민만 (운영 도구)
alter table public.daegwan_manual enable row level security;

drop policy if exists "daegwan_manual_super_all" on public.daegwan_manual;
create policy "daegwan_manual_super_all" on public.daegwan_manual
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );

do $$ begin raise notice '✅ daegwan_manual 생성 — 티켓 캘린더에서 수기 예약 추가 가능'; end $$;
