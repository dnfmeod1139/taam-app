-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 회원 접근 제어 (화이트/블랙리스트) (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 목적:
--   ① 화이트리스트(allow): 명단에 있는 회원만 그 티켓을 볼 수 있고 구매 가능
--   ② 블랙리스트(block):   명단에 있는 회원은 그 티켓을 못 봄 + 못 삼
--   두 모드는 한 티켓에 동시 적용 가능 (allow 명단 + 그 안에서도 block 으로 일부 제외).
--
-- 정책:
--   · 슈퍼어드민: 모든 티켓 + 모든 명단 관리 가능
--   · 레스토랑 어드민: 본인 매장의 티켓만 명단 관리 가능
--   · 일반 회원:
--     - allow 명단이 비어있고 본인이 block 에 없으면 → 티켓 SELECT 허용 (기본 공개)
--     - allow 명단이 있고 본인이 allow 에 있으면 → SELECT 허용
--     - allow 명단이 있지만 본인이 없으면 → SELECT 차단 (티켓 자체가 안 보임)
--     - block 에 본인이 있으면 → SELECT 차단
--
-- 실행: Supabase SQL Editor 1회.
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 테이블 ──
create table if not exists public.ticket_access_lists (
  id uuid primary key default gen_random_uuid(),
  ticket_id text not null,                    -- tickets.id (ticketDB 의 id, text)
  user_id uuid not null references auth.users(id) on delete cascade,
  access_type text not null check (access_type in ('allow','block')),
  added_by uuid references auth.users(id),    -- 누가 추가했는지 (감사 추적)
  added_at timestamptz not null default now(),
  unique (ticket_id, user_id, access_type)
);

comment on table public.ticket_access_lists is
  '티켓별 회원 접근 제어. access_type=allow 는 화이트리스트(이 회원만 구매), block 은 블랙리스트(이 회원 차단).';
comment on column public.ticket_access_lists.access_type is 'allow | block';
comment on column public.ticket_access_lists.added_by is '명단에 추가한 슈퍼어드민/레스토랑 어드민 user_id';

-- 빠른 조회 인덱스
create index if not exists idx_tal_ticket_type   on public.ticket_access_lists(ticket_id, access_type);
create index if not exists idx_tal_user_type     on public.ticket_access_lists(user_id, access_type);

-- ── 2) RLS 활성화 ──
alter table public.ticket_access_lists enable row level security;

-- ── 3) 헬퍼 함수: 본인이 티켓의 소유 레스토랑 어드민인지 ──
-- ticketDB 의 t.uploaderRestId 또는 t.uploadedBy 와 매칭.
-- 실제 tickets 테이블 스키마에 따라 조정 필요할 수 있음.
-- 우선 간단 버전: profiles.role='admin' 이면 본인 매장 티켓만 관리 (앱 측 추가 검증).
create or replace function public.can_manage_ticket_access(p_ticket_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    -- 슈퍼어드민은 무조건
    public.is_super_admin(auth.uid())
    or
    -- 일반 어드민/파트너는 본인 매장 ticket 만 — 앱 측에서 ticket.uploaderRestId 검증 후 호출.
    -- 여기서는 admin/partner role 보유자에게 일단 허용 (앱 가드 신뢰).
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('admin','partner')
    );
$$;

comment on function public.can_manage_ticket_access(text) is
  '티켓 명단 관리 권한: 슈퍼어드민 OR admin/partner. 매장 매칭은 앱 측 가드.';

-- ── 4) ticket_access_lists 정책 ──

-- SELECT: 슈퍼어드민/관리자/파트너 → 전체, 일반 회원 → 본인 항목만
drop policy if exists "tal select" on public.ticket_access_lists;
create policy "tal select"
on public.ticket_access_lists for select to authenticated
using (
  public.can_manage_ticket_access(ticket_id)
  or user_id = auth.uid()
);

-- INSERT/DELETE: 슈퍼어드민 OR admin/partner 만
drop policy if exists "tal insert" on public.ticket_access_lists;
create policy "tal insert"
on public.ticket_access_lists for insert to authenticated
with check ( public.can_manage_ticket_access(ticket_id) );

drop policy if exists "tal delete" on public.ticket_access_lists;
create policy "tal delete"
on public.ticket_access_lists for delete to authenticated
using ( public.can_manage_ticket_access(ticket_id) );

-- ── 5) 회원의 티켓 SELECT 가드 ──
-- ticketDB 가 Supabase tickets 테이블에 있다면 그 SELECT RLS 에 화이트/블랙 체크 추가.
-- 현 단계에서는 클라이언트 가드 (renderTicketGenres 필터) 로 1차 차단.
-- 향후 tickets RLS 강화 시 아래 함수 활용:
create or replace function public.user_can_see_ticket(p_ticket_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    -- 슈퍼/어드민/파트너는 항상 보임
    public.can_manage_ticket_access(p_ticket_id)
    or
    -- 블랙리스트에 본인이 있으면 차단
    not exists (
      select 1 from public.ticket_access_lists
      where ticket_id = p_ticket_id
        and access_type = 'block'
        and user_id = auth.uid()
    )
    and
    -- allow 가 비어있으면 공개, 있으면 본인이 그 안에 있어야 함
    (
      not exists (
        select 1 from public.ticket_access_lists
        where ticket_id = p_ticket_id and access_type = 'allow'
      )
      or exists (
        select 1 from public.ticket_access_lists
        where ticket_id = p_ticket_id
          and access_type = 'allow'
          and user_id = auth.uid()
      )
    );
$$;

comment on function public.user_can_see_ticket(text) is
  '회원이 티켓을 볼 수 있는지 판단. allow 명단 / block 명단 / 어드민 권한 종합 평가.';

revoke execute on function public.user_can_see_ticket(text) from anon;
grant  execute on function public.user_can_see_ticket(text) to authenticated;

-- ── 검증 쿼리 (실행 후) ──
-- 1) 정책/함수 존재 확인:
--    select policyname, cmd from pg_policies where tablename='ticket_access_lists';
--    select proname from pg_proc where proname in ('can_manage_ticket_access','user_can_see_ticket');
--
-- 2) 슈퍼어드민으로 샘플 데이터:
--    insert into ticket_access_lists (ticket_id, user_id, access_type, added_by)
--    values ('<ticket_id>', '<user_id>', 'allow', auth.uid());
--
-- 3) 회원이 볼 수 있는지 확인:
--    select public.user_can_see_ticket('<ticket_id>');

do $$ begin raise notice '✅ ticket_access_lists 테이블 + 정책 + 헬퍼 함수 설치 완료'; end $$;
