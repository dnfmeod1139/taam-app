-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 좌석 홀드 48시간 자동 만료 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent)
-- · 판매 티켓 연결 초대(ticket_product_id 有)가 발송 후 48시간 미결제면:
--     ① reservation_invites.status = 'expired'
--     ② INVH- 좌석 홀드 행 cancelled → 본 티켓 잔여석 자동 복구
--     ③ 발송자(호스트)에게 인앱 알림
-- · pg_cron 으로 30분마다 스윕. 클라이언트(결제 직전) 이중 가드는 앱에 이미 반영.
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 만료 스윕 함수 ──
create or replace function public.taam_expire_invite_holds()
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_exp int := 0;
  v_rel int := 0;
begin
  -- ① 48시간 지난 미결제 '연결' 초대 → expired (+ 호스트 알림)
  with exp as (
    update public.reservation_invites
       set status = 'expired'
     where status = 'sent'
       and ticket_product_id is not null
       and created_at < now() - interval '48 hours'
    returning id, host_user_id, restaurant_name, visit_date, visit_time, pax
  ),
  noti as (
    insert into public.notifications (user_id, type, title, body, message, kind)
    select host_user_id,
           'invite_cancelled',
           '⏰ 초대 자동 만료 (48시간)',
           coalesce(restaurant_name,'') || ' · ' || coalesce(visit_date,'') || ' ' || coalesce(visit_time,'')
             || ' · ' || pax || '인 — 미결제로 만료, 좌석 자동 복구됨',
           coalesce(restaurant_name,'') || ' · ' || coalesce(visit_date,'') || ' ' || coalesce(visit_time,'')
             || ' · ' || pax || '인 — 미결제로 만료, 좌석 자동 복구됨',
           'invite_cancelled'
      from exp
    returning 1
  )
  select count(*) into v_exp from exp;

  -- ② 48시간 지난 살아있는 홀드 행 → cancelled (좌석 복구)
  --    (결제/취소된 초대의 홀드는 이미 cancelled 라 자연 제외)
  update public.tickets
     set status = 'cancelled'
   where purchase_id like 'INVH-%'
     and coalesce(status,'') <> 'cancelled'
     and created_at < now() - interval '48 hours';
  get diagnostics v_rel = row_count;

  return json_build_object('expired_invites', v_exp, 'released_holds', v_rel);
end;
$$;
revoke execute on function public.taam_expire_invite_holds() from public;
grant  execute on function public.taam_expire_invite_holds() to authenticated;

-- ── 2) pg_cron 스케줄 — 30분마다 스윕 ──
create extension if not exists pg_cron;

do $$
begin
  begin
    perform cron.unschedule('taam-expire-invite-holds');
  exception when others then
    null;   -- 처음 실행이라 잡이 없으면 무시
  end;
  perform cron.schedule('taam-expire-invite-holds', '*/30 * * * *',
    $job$ select public.taam_expire_invite_holds(); $job$);
end;
$$;

-- ── 3) 즉시 1회 실행 (기존에 쌓인 48시간 초과 홀드 정리) ──
select public.taam_expire_invite_holds();

do $$ begin raise notice '✅ 초대 홀드 48시간 자동 만료 설치 완료 (30분마다 스윕)'; end $$;
