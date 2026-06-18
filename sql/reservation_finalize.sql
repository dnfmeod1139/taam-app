-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 요청 — 정합성 finalize (2026-06-18)
-- ═══════════════════════════════════════════════════════════════
-- 라이브 진단 결과 반영:
--   · venue_partners 컬럼(notify_phone/notify_line_id/reservation_notes/intro 등) 모두 존재 — OK
--   · 어드민 RPC(get_requester_info/set_reservation_admin_memo/confirm_reservation/
--     mark_reservation_visit) 모두 존재 — OK
--   · create_reservation_request 가 6인자/7인자 2개 공존 (앱은 7인자=allergy 호출)
--   · ❗ is_venue_admin_of 가 venue_admins(0행)만 조회 → 일반 어드민이 예약 수락/거절 시
--        RLS·RPC 에서 FORBIDDEN. UI 는 admin_grants 로 매장을 뽑는데 권한 기준이 달라 불일치.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN (멱등).
-- ═══════════════════════════════════════════════════════════════

-- [1] 어드민 권한 판정 일원화 — admin_grants(예약 venue_id, 폴백 rest_id)도 인정.
--     UI(renderReservationAdmin)가 admin_grants 기준으로 매장을 뽑으므로,
--     RLS/RPC 권한도 동일 기준으로 맞춰 FORBIDDEN 해소. venue_admins(레거시)도 계속 인정.
create or replace function public.is_venue_admin_of(p_venue_id text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select
    exists (
      select 1 from public.admin_grants ag
      where ag.user_id = auth.uid()
        and (ag.venue_id = p_venue_id or ag.rest_id = p_venue_id)
    )
    or exists (
      select 1 from public.venue_admins va
      where va.admin_user_id = auth.uid() and va.venue_id = p_venue_id
    );
$$;

-- [2] 중복 RPC 정리 — 옛 6인자(allergy 없음) 버전 제거.
--     앱(submitReserveRequest)은 7인자(... , p_allergy) 버전만 호출하므로 안전.
drop function if exists public.create_reservation_request(text, date, time, integer, text, boolean);

-- [3] 검증
select 'create_reservation_request 잔존' as label, p.oid::regprocedure::text as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'create_reservation_request'
union all
select 'is_venue_admin_of 정의됨', count(*)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'is_venue_admin_of';

do $$ begin
  raise notice '✅ finalize 완료 — 어드민 권한 admin_grants 인정 + create_reservation_request 단일화';
end $$;
