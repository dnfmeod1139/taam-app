-- ═══════════════════════════════════════════════════════════════
-- TAAM — daegwan_capacity (티켓 캘린더: 매장×날짜 좌석 정원) (2026-06-19)
-- ═══════════════════════════════════════════════════════════════
-- 슈퍼어드민이 티켓 캘린더에서 매장×날짜의 "총 좌석 수"를 수동 저장.
-- 남은 좌석 = seats − (그날 초대 결제 인원 + 티켓 판매 인원). 앱이 자동 카운팅.
-- venue_id = 정적 큐레이션 id(text) / restaurants.id 등 매장 식별자.
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent).
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.daegwan_capacity (
  venue_id    text not null,
  ymd         date not null,
  seats       integer not null default 0,
  updated_by  uuid references auth.users(id),
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  primary key (venue_id, ymd)
);

comment on table public.daegwan_capacity is
  '티켓 캘린더 매장×날짜 좌석 정원(수동). 남은좌석 = seats - 그날 예약 인원(초대결제+티켓판매).';

create index if not exists idx_daegwan_cap_ymd on public.daegwan_capacity(ymd);

-- RLS: 슈퍼어드민만 읽기/쓰기 (운영 도구)
alter table public.daegwan_capacity enable row level security;

drop policy if exists "daegwan_cap_super_all" on public.daegwan_capacity;
create policy "daegwan_cap_super_all" on public.daegwan_capacity
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );

do $$ begin raise notice '✅ daegwan_capacity 생성 — 티켓 캘린더에서 매장×날짜 좌석 정원 저장 가능'; end $$;
