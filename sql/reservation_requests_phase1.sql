-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 요청 기능 (Phase 1) — DB 스키마 + RLS + 요청제한 RPC
-- 작성: 2026-06-10
-- ═══════════════════════════════════════════════════════════════
-- 스펙: TAAM_RESERVATION_REQUEST_SPEC.md
-- 결정값:
--   · ANNUAL_LIMIT = 사실상 무제한(상수 9999, 아래 RPC에서 조정)
--   · 예치금 = 객단가 플로어(min_spend_floor_per_person) × 인원
--   · 알림 = 인앱 레드닷 (Realtime)
--   · 신뢰등급 표기 = Phase 1 제외 (컬럼은 생성, UI 표기만 생략)
--
-- 설계 메모(코드베이스 반영):
--   · venues 는 정적 JSON(/venues/{id}.json) — DB 테이블 아님.
--     따라서 venue_id 는 text (예: '7th-door-seoul'). FK 아님.
--   · 파트너 조건은 venues 가 아니라 신규 venue_partners 테이블에 저장.
--   · venue_admins 는 예약 도메인 전용(티켓용 restaurant_admins 와 분리).
--   · is_super_admin(uuid) 함수는 기존 존재 가정.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 Run (idempotent).
-- ═══════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1) venue_partners — 파트너 매장 설정 (어드민이 1회 설정)
-- ─────────────────────────────────────────────────────────────
create table if not exists public.venue_partners (
  venue_id                   text primary key,                 -- /venues/{id}.json 의 venue_id
  is_partner                 boolean not null default true,    -- 파트너십 리스트 노출
  channel                    text not null default 'request_open'
                               check (channel in ('daegwan_priority','request_open')),
  min_alcohol_per_person     integer default 0,                -- 주류 최소금액(원/인)
  min_spend_floor_per_person integer default 0,                -- 객단가 플로어(원/인) — 예치금 산정 기준
  min_lead_time_months       integer default 0,                -- 최소 리드타임(개월)
  party_min                  integer default 1,
  party_max                  integer default 8,
  closed_weekdays            integer[] default '{}',           -- 0=일 ... 6=토
  updated_at                 timestamptz not null default now(),
  created_at                 timestamptz not null default now()
);
comment on table public.venue_partners is '예약 파트너 매장 설정. venue_id=정적 큐레이션 id(text).';


-- ─────────────────────────────────────────────────────────────
-- 2) venue_admins — 매장별 어드민 매핑 (다대다)
-- ─────────────────────────────────────────────────────────────
create table if not exists public.venue_admins (
  id            uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references auth.users(id) on delete cascade,
  venue_id      text not null,
  granted_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  unique (admin_user_id, venue_id)
);
create index if not exists idx_va_admin on public.venue_admins(admin_user_id);
create index if not exists idx_va_venue on public.venue_admins(venue_id);

-- 헬퍼: 로그인 유저가 이 매장의 어드민인가
create or replace function public.is_venue_admin_of(p_venue_id text)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.venue_admins va
    where va.admin_user_id = auth.uid() and va.venue_id = p_venue_id
  );
$$;


-- ─────────────────────────────────────────────────────────────
-- 3) reservation_requests — 예약 요청 본체
-- ─────────────────────────────────────────────────────────────
create table if not exists public.reservation_requests (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  venue_id            text not null,
  reserve_date        date not null,
  reserve_time        time,
  party_size          integer not null check (party_size > 0),
  member_memo         text,
  conditions_accepted boolean not null default false,
  status              text not null default 'pending'
                        check (status in ('pending','confirmed','declined')),
  handled_by          uuid references auth.users(id),
  handled_at          timestamptz,
  deposit_status      text,                                    -- 기존 예치금 서비스 상태 연결
  deposit_amount      integer,                                 -- 산정된 예치금(객단가플로어×인원) 스냅샷
  visit_status        text check (visit_status in ('attended','no_show')),
  created_at          timestamptz not null default now()
);
create index if not exists idx_rr_user    on public.reservation_requests(user_id, created_at desc);
create index if not exists idx_rr_venue   on public.reservation_requests(venue_id, status);
create index if not exists idx_rr_pending on public.reservation_requests(user_id) where status = 'pending';
comment on table public.reservation_requests is '회원 예약 요청. 어드민이 수락/거절. Phase 1.';


-- ─────────────────────────────────────────────────────────────
-- 4) favorites — 즐겨찾기
-- ─────────────────────────────────────────────────────────────
create table if not exists public.favorites (
  user_id    uuid not null references auth.users(id) on delete cascade,
  venue_id   text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, venue_id)
);


-- ─────────────────────────────────────────────────────────────
-- 5) profiles — 신뢰 루프 컬럼 (표기는 Phase 1 제외, 데이터는 누적)
-- ─────────────────────────────────────────────────────────────
alter table public.profiles add column if not exists taam_visit_count integer not null default 0;
alter table public.profiles add column if not exists no_show_count    integer not null default 0;
alter table public.profiles add column if not exists spend_tier       text;


-- ═════════════════════════════════════════════════════════════
-- 6) RLS 정책
-- ═════════════════════════════════════════════════════════════

-- ── venue_partners ──
alter table public.venue_partners enable row level security;

drop policy if exists "vp member read partners" on public.venue_partners;
create policy "vp member read partners" on public.venue_partners
  for select to authenticated
  using ( is_partner = true );                                 -- 회원: 파트너만 노출

drop policy if exists "vp admin manage" on public.venue_partners;
create policy "vp admin manage" on public.venue_partners
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) or public.is_venue_admin_of(venue_id) )
  with check ( public.is_super_admin(auth.uid()) or public.is_venue_admin_of(venue_id) );

-- ── venue_admins ──
alter table public.venue_admins enable row level security;

drop policy if exists "va select" on public.venue_admins;
create policy "va select" on public.venue_admins
  for select to authenticated
  using ( public.is_super_admin(auth.uid()) or admin_user_id = auth.uid() );

drop policy if exists "va write" on public.venue_admins;
create policy "va write" on public.venue_admins
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );

-- ── reservation_requests ──
alter table public.reservation_requests enable row level security;

-- 회원: 본인 것 read. (insert 는 아래 RPC 로만 — 직접 insert 막기 위해 insert 정책 없음)
drop policy if exists "rr member select own" on public.reservation_requests;
create policy "rr member select own" on public.reservation_requests
  for select to authenticated
  using ( user_id = auth.uid()
          or public.is_super_admin(auth.uid())
          or public.is_venue_admin_of(venue_id) );

-- 어드민: 본인 매핑 매장의 요청 update (수락/거절/방문기록)
drop policy if exists "rr admin update" on public.reservation_requests;
create policy "rr admin update" on public.reservation_requests
  for update to authenticated
  using      ( public.is_super_admin(auth.uid()) or public.is_venue_admin_of(venue_id) )
  with check ( public.is_super_admin(auth.uid()) or public.is_venue_admin_of(venue_id) );

-- 슈퍼어드민: 전체 insert/delete 여지 (운영용)
drop policy if exists "rr super all" on public.reservation_requests;
create policy "rr super all" on public.reservation_requests
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );

-- ── favorites ──
alter table public.favorites enable row level security;

drop policy if exists "fav own all" on public.favorites;
create policy "fav own all" on public.favorites
  for all to authenticated
  using      ( user_id = auth.uid() )
  with check ( user_id = auth.uid() );


-- ═════════════════════════════════════════════════════════════
-- 7) 요청 생성 RPC — 제한로직 + 1차 거름망(매장 조건) 서버 강제
-- ═════════════════════════════════════════════════════════════
-- 앱에서 직접 insert 대신 이 함수만 호출. 우회 불가.
create or replace function public.create_reservation_request(
  p_venue_id            text,
  p_reserve_date        date,
  p_reserve_time        time,
  p_party_size          integer,
  p_member_memo         text default null,
  p_conditions_accepted boolean default false
)
returns public.reservation_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  ANNUAL_LIMIT constant integer := 9999;   -- 우선 제한 없음(큰 값). 추후 조정.
  v_uid        uuid := auth.uid();
  v_partner    public.venue_partners%rowtype;
  v_pending    integer;
  v_annual     integer;
  v_dow        integer;
  v_deposit    integer;
  v_row        public.reservation_requests%rowtype;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  -- 조건 동의 필수
  if coalesce(p_conditions_accepted, false) = false then
    raise exception 'CONDITIONS_NOT_ACCEPTED' using errcode = 'P0001';
  end if;

  -- 파트너 매장 확인
  select * into v_partner from public.venue_partners where venue_id = p_venue_id;
  if not found or v_partner.is_partner = false then
    raise exception 'NOT_A_PARTNER_VENUE' using errcode = 'P0001';
  end if;

  -- 1차 거름망: 인원 범위
  if p_party_size < coalesce(v_partner.party_min,1)
     or p_party_size > coalesce(v_partner.party_max,9999) then
    raise exception 'PARTY_SIZE_OUT_OF_RANGE' using errcode = 'P0001';
  end if;

  -- 1차 거름망: 최소 리드타임 (개월)
  if p_reserve_date < (current_date + (coalesce(v_partner.min_lead_time_months,0) || ' months')::interval) then
    raise exception 'LEAD_TIME_TOO_SHORT' using errcode = 'P0001';
  end if;

  -- 1차 거름망: 휴무 요일 (0=일 ... 6=토)
  v_dow := extract(dow from p_reserve_date)::int;
  if v_dow = any (coalesce(v_partner.closed_weekdays, '{}')) then
    raise exception 'VENUE_CLOSED_THAT_DAY' using errcode = 'P0001';
  end if;

  -- 제한 1: 동시 진행 pending < 2
  select count(*) into v_pending
    from public.reservation_requests
    where user_id = v_uid and status = 'pending';
  if v_pending >= 2 then
    raise exception 'TOO_MANY_PENDING' using errcode = 'P0001';
  end if;

  -- 제한 2: 연간 총량 < ANNUAL_LIMIT
  select count(*) into v_annual
    from public.reservation_requests
    where user_id = v_uid and created_at >= date_trunc('year', now());
  if v_annual >= ANNUAL_LIMIT then
    raise exception 'ANNUAL_LIMIT_REACHED' using errcode = 'P0001';
  end if;

  -- 예치금 산정: 객단가 플로어 × 인원
  v_deposit := coalesce(v_partner.min_spend_floor_per_person,0) * p_party_size;

  insert into public.reservation_requests
    (user_id, venue_id, reserve_date, reserve_time, party_size,
     member_memo, conditions_accepted, status, deposit_amount)
  values
    (v_uid, p_venue_id, p_reserve_date, p_reserve_time, p_party_size,
     p_member_memo, true, 'pending', v_deposit)
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.create_reservation_request is
  '예약 요청 생성. 매장조건·동시진행2·연간한도 서버검증 후 insert. 예치금=객단가플로어×인원.';


-- ═════════════════════════════════════════════════════════════
-- 8) 회원용 남은 요청 카운트 조회 RPC (화면 표시용)
-- ═════════════════════════════════════════════════════════════
create or replace function public.my_reservation_quota()
returns table (pending_count integer, annual_count integer, annual_limit integer)
language sql stable security definer set search_path = public
as $$
  select
    (select count(*)::int from public.reservation_requests
       where user_id = auth.uid() and status = 'pending'),
    (select count(*)::int from public.reservation_requests
       where user_id = auth.uid() and created_at >= date_trunc('year', now())),
    9999;
$$;


-- ═════════════════════════════════════════════════════════════
-- 9) 방문/노쇼 기록 시 신뢰 루프 자동 갱신 (트리거)
-- ═════════════════════════════════════════════════════════════
create or replace function public.trg_reservation_visit_status()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  -- visit_status 가 새로 채워질 때만 카운트 갱신
  if new.visit_status is distinct from old.visit_status and new.visit_status is not null then
    if new.visit_status = 'attended' then
      update public.profiles set taam_visit_count = coalesce(taam_visit_count,0) + 1
        where id = new.user_id;
    elsif new.visit_status = 'no_show' then
      update public.profiles set no_show_count = coalesce(no_show_count,0) + 1
        where id = new.user_id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_rr_visit_status on public.reservation_requests;
create trigger trg_rr_visit_status
  after update of visit_status on public.reservation_requests
  for each row execute function public.trg_reservation_visit_status();


-- ═════════════════════════════════════════════════════════════
-- 10) Realtime 발행 (레드닷 알림용) — 이미 활성화돼 있으면 무해
-- ═════════════════════════════════════════════════════════════
-- 회원: 본인 요청 status UPDATE 감지 / 어드민: 매핑 매장 신규 pending 감지
alter publication supabase_realtime add table public.reservation_requests;


-- ═════════════════════════════════════════════════════════════
-- 11) (설정용 참고) 파트너 매장 등록 예시 — 실제 값으로 채워 실행
-- ═════════════════════════════════════════════════════════════
-- insert into public.venue_partners
--   (venue_id, channel, min_alcohol_per_person, min_spend_floor_per_person,
--    min_lead_time_months, party_min, party_max, closed_weekdays)
-- values
--   ('7th-door-seoul', 'request_open', 0, 300000, 1, 2, 6, '{1}')  -- 월요일 휴무 예시
-- on conflict (venue_id) do update set
--   channel = excluded.channel,
--   min_spend_floor_per_person = excluded.min_spend_floor_per_person,
--   updated_at = now();
--
-- 어드민 매핑 예시:
-- insert into public.venue_admins (admin_user_id, venue_id, granted_by)
-- values ('<어드민 uuid>', '7th-door-seoul', auth.uid())
-- on conflict (admin_user_id, venue_id) do nothing;
