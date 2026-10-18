-- ═══════════════════════════════════════════════════════════════
-- 비회원 손님 방문 리마인드 — 카카오 알림톡 대상 뽑기 · 발송 기록 (2026-10-19)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 방문 리마인드(7·3·1일 전)는 앱 푸시로만 나간다. 결제 링크로 결제한 비회원 손님(LINK-)과 캘린더 「수동 추가」 손님(MAN-)은
--     앱 계정이 없어 아무것도 못 받았다. 두 부류 모두 손님 번호(tickets.buyer_phone)가 있고, 수동 추가 손님에겐 예약 확인 알림톡을
--     이미 보내는 길(Edge notify-guest-booking · 솔라피 · 카카오 채널)이 살아 있다 — 그 위에 「방문 3일 전 · 1일 전」을 얹는다.
-- 무엇: Edge notify-visit-reminder(매일 11:00 KST 크론)가 회원 푸시를 쏜 뒤 ① taam_guest_reminder_targets() 로 오늘 보낼 손님을 받고
--     ② 알림톡을 보내고 ③ taam_guest_reminder_mark() 로 결과를 적는다. 열쇠는 (ticket_id, 남은 일수) — 같은 티켓·같은 일수로 한 번만.
--     대상: status active|manual · 손님 번호 9자리 이상 · (비회원 LINK- = memberUid 없음) 또는 MAN- · 방문 3일 전 또는 1일 전.
--     회원 소유 LINK-(memberUid)는 회원 푸시 쪽(20261019_member_link_rows.sql)이 맡는다 — 두 번 안 간다. KSK- 는 결제자 번호가 티켓에 없어 뺀다.
-- 지키는 것: 두 함수는 서버(service_role·SQL Editor·크론)·슈퍼어드민만 부른다(회원·anon FORBIDDEN) · 발송 자체는 Edge 가 한다(DB 는 대상·기록만) ·
--     해외 번호(한국 010 아님)는 Edge 가 skip 으로 기록한다(알림톡은 국내 번호만) · 티켓·원장은 건드리지 않는다.
-- 템플릿: Edge 시크릿 KAKAO_TEMPLATE_GUEST_REMIND (카카오 비즈니스 채널에 등록·승인된 템플릿 id · 변수 #{name} #{shop} #{date} #{party} #{dday}).
-- 회귀: bash sql/_test/t_guest_reminder.sh
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.guest_remind_log (
  ticket_id  uuid not null,
  d          int  not null,
  phone_key  text,
  result     text,
  sent_at    timestamptz not null default now(),
  primary key (ticket_id, d)
);
comment on table public.guest_remind_log is '비회원 손님 방문 리마인드(알림톡) 발송 기록 — (티켓, 남은 일수) 열쇠로 하루 한 번. 2026-10-19';
alter table public.guest_remind_log enable row level security;
revoke all on public.guest_remind_log from anon, authenticated;
drop policy if exists grl_super_read on public.guest_remind_log;
create policy grl_super_read on public.guest_remind_log for select to authenticated using (public.is_super_admin(auth.uid()));
grant select on public.guest_remind_log to authenticated;

-- 호출자 — 서버(service_role · SQL Editor/postgres) 또는 슈퍼어드민. anon(auth.uid() null 이지만 role anon)은 아니다.
create or replace function public._taam_guest_caller_ok()
returns boolean language plpgsql stable as $$
declare v_role text := '';
begin
  if auth.uid() is not null then return coalesce(public.is_super_admin(auth.uid()), false); end if;
  begin v_role := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', ''); exception when others then v_role := ''; end;
  return v_role = 'service_role' or session_user = 'postgres';
end $$;

create or replace function public.taam_guest_reminder_targets()
returns setof jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public._taam_guest_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
  select jsonb_build_object(
           'ticket_id',   t.id,
           'name',        coalesce(nullif(btrim(t.buyer_name), ''), '고객'),
           'phone',       regexp_replace(coalesce(t.buyer_phone, ''), '[^0-9+]', '', 'g'),
           'rest',        coalesce(nullif(btrim(t.restaurant_name), ''), '예약하신 매장'),
           'date',        t.reservation_date,
           'vtime',       coalesce(nullif(btrim(t.visit_time), ''), ''),
           'pax',         coalesce(t.party_size, 1),
           'd',           dd.d,
           'purchase_id', t.purchase_id)
    from public.tickets t
    cross join lateral (select public.taam_visit_days_left(t.reservation_date) as d) dd
   where lower(coalesce(t.status, '')) in ('active', 'manual')
     and length(regexp_replace(coalesce(t.buyer_phone, ''), '[^0-9]', '', 'g')) >= 9
     and ( (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
        or  coalesce(t.purchase_id, '') like 'MAN-%' )
     and dd.d in (1, 3)
     and not exists (select 1 from public.guest_remind_log g where g.ticket_id = t.id and g.d = dd.d)
   order by dd.d, t.reservation_date, t.created_at;
end $$;
revoke all on function public.taam_guest_reminder_targets() from public, anon, authenticated;
grant execute on function public.taam_guest_reminder_targets() to authenticated, service_role;   -- authenticated 는 함수 안에서 슈퍼어드민만 통과

create or replace function public.taam_guest_reminder_mark(p_ticket uuid, p_d int, p_result text, p_phone_key text default null)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not public._taam_guest_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_ticket is null or p_d is null then return; end if;
  insert into public.guest_remind_log (ticket_id, d, phone_key, result)
  values (p_ticket, p_d, p_phone_key, left(coalesce(p_result, ''), 200))
  on conflict (ticket_id, d) do update set result = excluded.result, phone_key = coalesce(excluded.phone_key, public.guest_remind_log.phone_key), sent_at = now();
end $$;
revoke all on function public.taam_guest_reminder_mark(uuid, int, text, text) from public, anon, authenticated;
grant execute on function public.taam_guest_reminder_mark(uuid, int, text, text) to authenticated, service_role;

-- ── 확인 — 한 표 ──
select '① 표 guest_remind_log · RLS · 슈퍼어드민 읽기 정책' as 항목,
       case when to_regclass('public.guest_remind_log') is not null and exists (select 1 from pg_policies where tablename = 'guest_remind_log' and policyname = 'grl_super_read') then '✅' else '❌' end as 결과
union all select '② 함수 둘 (targets · mark) · 호출자 검사', case when to_regproc('public.taam_guest_reminder_targets') is not null and to_regprocedure('public.taam_guest_reminder_mark(uuid,integer,text,text)') is not null and to_regproc('public._taam_guest_caller_ok') is not null then '✅' else '❌' end
union all select '③ 의존 — taam_visit_days_left(sql/visit_reminder.sql) · is_super_admin', case when to_regproc('public.taam_visit_days_left') is not null and to_regprocedure('public.is_super_admin(uuid)') is not null then '✅' else '❌ sql/visit_reminder.sql 먼저' end
union all select '④ anon 은 못 부른다', case when has_function_privilege('anon', 'public.taam_guest_reminder_targets()', 'execute') then '❌' else '✅' end
union all select '⑤ 오늘 기준 대상 수 (정보 · 3일 전·1일 전 손님)', (select count(*) from public.tickets t where lower(coalesce(t.status,'')) in ('active','manual') and length(regexp_replace(coalesce(t.buyer_phone,''),'[^0-9]','','g')) >= 9
          and ((coalesce(t.purchase_id,'') like 'LINK-%' and nullif(t.extra_data->>'memberUid','') is null) or coalesce(t.purchase_id,'') like 'MAN-%') and public.taam_visit_days_left(t.reservation_date) in (1,3))::text;
