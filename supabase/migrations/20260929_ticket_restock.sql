-- ============================================================================
-- 20260929_ticket_restock.sql — 취소표(재입고) 알림: 매진 → 자리가 다시 나면 전원 푸시 (2026-09-29)
-- ============================================================================
-- 무엇을
--   매진(ticket_products.status='soldout')이던 회차에 한 자리라도 다시 생기면 — 회원 취소, 수동 추가 삭제,
--   정산 좌석 취소, 홀드 만료, 어드민의 매진→판매중 전환 등 **경로가 무엇이든** — 살 수 있는 회원 전원과
--   슈퍼어드민에게 알린다 (인앱 종 + 푸시).
--
-- 어디에 거나 — 한 지점
--   좌석이 풀리는 길은 전부 tickets 행을 지나고, 그러면 trg_sync_ticket_soldout 이 ticket_products.status 를
--   soldout → active 로 되돌린다. 어드민 토글·연장·재편집은 status 를 직접 쓴다. 그러니 **ticket_products.status 의
--   soldout → active 전이**가 유일한 길목이다.
--
-- 왜 「지연 제약 트리거」인가
--   한 트랜잭션 안에서 soldout → active → soldout 이 될 수 있다 (링크 초대가 만료 홀드를 접고 새 홀드를 넣을 때,
--   재연결이 옛 좌석을 접고 새로 만들 때). 즉시 트리거는 중간 상태를 보고 「자리가 났다」고 거짓말한다.
--   DEFERRABLE INITIALLY DEFERRED 는 **커밋 직전**에 돌아 최종 상태를 다시 읽는다.
--
-- 거짓 알림을 막는 검사 (taam_ticket_restock_check)
--   status 가 여전히 active · 판매 공개(draft/예약 오픈 전 제외) · 방문일이 지나지 않음 · 총 정원이 있고 잔여 > 0 ·
--   flex 회차면 그 잔여를 허용 인원 조합으로 채울 수 있음(taam_seat_fillable) · 같은 회차 60분 쿨다운.
--   결제 홀드(PAYH-, 5분)가 풀리며 생기는 잠깐의 빈자리도 이 검사를 지나면 알린다 — 실제로 살 수 있는 자리다.
--
-- 누구에게 (taam_ticket_restock_process)
--   탈퇴 아님 · 취소표 알림(notif_prefs.restock)을 끄지 않음 · 전체(all)를 끄지 않음 · 티켓 이용 등급(min_tier) 통과 ·
--   taam_ticket_visible(차단·전용 명단·대상 조건) 통과 · 이 회차를 이미 들고 있지 않음. 슈퍼어드민은 조건 없이 전원.
--   ⚠ 등급별 우선 공개(grade_open · M 오픈 시각)는 서버가 모른다 (CLAUDE.md) — 여기서도 보지 않는다.
--
-- 흐름
--   전이 → (커밋 시) ticket_restock_events 에 pending 한 줄 → taam_restock_kick() 이 Edge notify-restock 을 부른다
--   (app_config 'restock_push' 에 Vault 시크릿 이름과 URL 이 있을 때) → Edge 가 taam_ticket_restock_process() 로
--   알림 행을 만들고 회원 uid 마다 · 슈퍼어드민 role 로 한 번 send-push. 1분 크론이 같은 kick 을 불러 놓친 것을 줍는다.
-- ============================================================================

-- ── 1. 이벤트 표 ──
create table if not exists public.ticket_restock_events (
  id                bigserial primary key,
  ticket_product_id text not null,
  status            text not null default 'pending' check (status in ('pending','sent','skipped')),
  reason            text,
  seats_left        int,
  made              int not null default 0,
  push_sent         int not null default 0,
  created_at        timestamptz not null default now(),
  processed_at      timestamptz
);
create index if not exists idx_restock_status on public.ticket_restock_events (status, created_at);
create index if not exists idx_restock_ticket on public.ticket_restock_events (ticket_product_id, created_at desc);
alter table public.ticket_restock_events enable row level security;
drop policy if exists "restock events super read" on public.ticket_restock_events;
create policy "restock events super read" on public.ticket_restock_events
  for select to authenticated using (public._taam_uid_is_super());
grant select on public.ticket_restock_events to authenticated;
grant all on public.ticket_restock_events to service_role;

-- ── 2. 지금 이 회차에 「살 수 있는 자리」가 있나 ──
create or replace function public.taam_ticket_restock_check(p_ticket_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  tp public.ticket_products%rowtype;
  v_date date; v_sold int := 0; v_left int; v_slots jsonb; v_allowed int[]; v_solo_cap int; v_solo_used int;
  v_open timestamp;
begin
  select * into tp from public.ticket_products where id::text = p_ticket_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND'); end if;
  if coalesce(tp.status, '') <> 'active' then return jsonb_build_object('ok', false, 'reason', 'NOT_ACTIVE:' || coalesce(tp.status,'')); end if;
  if coalesce(tp.sale_state, 'open') = 'draft' then return jsonb_build_object('ok', false, 'reason', 'DRAFT'); end if;
  if coalesce(tp.sale_state, 'open') = 'scheduled' and coalesce(tp.sale_open_at, '') <> '' then
    begin v_open := tp.sale_open_at::timestamp; exception when others then v_open := null; end;
    if v_open is not null and v_open > (now() at time zone 'Asia/Seoul') then
      return jsonb_build_object('ok', false, 'reason', 'SCHEDULED');
    end if;
  end if;
  v_date := public.taam_visit_date(tp.date);
  if v_date is not null and v_date < (now() at time zone 'Asia/Seoul')::date then
    return jsonb_build_object('ok', false, 'reason', 'PAST');
  end if;
  if coalesce(tp.total_pax, 0) <= 0 then return jsonb_build_object('ok', false, 'reason', 'NO_CAPACITY'); end if;
  select coalesce(sum(party_size), 0) into v_sold
    from public.tickets where ticket_product_id = tp.id and coalesce(status, '') <> 'cancelled';
  v_left := tp.total_pax - v_sold;
  if v_left <= 0 then return jsonb_build_object('ok', false, 'reason', 'FULL'); end if;
  -- flex: 남은 자리를 허용 인원 조합으로 채울 수 있어야 「살 수 있는 자리」다
  v_slots := to_jsonb(tp.slots);
  if (v_slots->>'mode') = 'flex' and to_regprocedure('public.taam_seat_fillable(int,int[],int)') is not null then
    v_allowed  := array(select jsonb_array_elements_text(coalesce(v_slots->'allowed','[]'::jsonb))::int);
    v_solo_cap := coalesce((v_slots->>'solo')::int, 0);
    select count(*) into v_solo_used from public.tickets
     where ticket_product_id = tp.id and party_size = 1 and coalesce(status,'') <> 'cancelled';
    if not public.taam_seat_fillable(v_left, v_allowed, greatest(0, v_solo_cap - v_solo_used))
       and not (coalesce((v_slots->>'strict')::boolean, false) = false and v_left = 1) then
      return jsonb_build_object('ok', false, 'reason', 'UNFILLABLE', 'seats_left', v_left);
    end if;
  end if;
  return jsonb_build_object('ok', true, 'seats_left', v_left, 'rest', coalesce(tp.rest_name, ''),
                            'date', coalesce(tp.date, ''), 'time', coalesce(tp.time, ''), 'min_tier', coalesce(tp.min_tier, ''));
end $$;
revoke all on function public.taam_ticket_restock_check(text) from public;
grant execute on function public.taam_ticket_restock_check(text) to authenticated, service_role;

-- ── 3. Edge 를 깨운다 — 설정이 있을 때만, pending 이 있을 때만 ──
--   app_config 'restock_push' = {"vault_secret": "<Vault 시크릿 이름>", "url": "https://<ref>.supabase.co/functions/v1/notify-restock"}
--   시크릿 값은 Vault 에만 있다. 여기엔 이름만. cron.job 에도 키가 남지 않는다.
create or replace function public.taam_restock_kick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  if not exists (select 1 from public.ticket_restock_events where status = 'pending') then
    return jsonb_build_object('kicked', false, 'reason', 'nothing_pending');
  end if;
  begin
    select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  exception when others then v_cfg := null; end;
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name,'') = '' or coalesce(v_url,'') = '' then
    return jsonb_build_object('kicked', false, 'reason', 'no_config');
  end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    return jsonb_build_object('kicked', false, 'reason', 'no_pg_net');
  end if;
  begin
    select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  exception when others then v_jwt := null; end;
  if coalesce(v_jwt,'') = '' then return jsonb_build_object('kicked', false, 'reason', 'no_secret'); end if;
  select net.http_post(
           url     := v_url,
           headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt),
           body    := jsonb_build_object('source', 'kick', 'at', now()))
    into v_req;
  return jsonb_build_object('kicked', true, 'request_id', v_req);
exception when others then
  raise warning '[restock] kick 실패: % %', sqlstate, sqlerrm;
  return jsonb_build_object('kicked', false, 'reason', left(sqlerrm, 120));
end $$;
revoke all on function public.taam_restock_kick() from public;
grant execute on function public.taam_restock_kick() to service_role;

-- ── 4. 전이 트리거 (커밋 시점) ──
create or replace function public.taam_ticket_restock_on_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  begin
    v := public.taam_ticket_restock_check(new.id::text);
    if not coalesce((v->>'ok')::boolean, false) then return null; end if;
    if exists (select 1 from public.ticket_restock_events e
                where e.ticket_product_id = new.id::text and e.status in ('pending','sent')
                  and e.created_at > now() - interval '60 minutes') then
      return null;   -- 쿨다운: 같은 회차는 한 시간에 한 번
    end if;
    insert into public.ticket_restock_events (ticket_product_id, seats_left) values (new.id::text, (v->>'seats_left')::int);
    perform public.taam_restock_kick();
  exception when others then
    raise warning '[restock] 트리거 실패(판매 상태 갱신은 유지): % %', sqlstate, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists trg_ticket_restock on public.ticket_products;
create constraint trigger trg_ticket_restock
  after update of status on public.ticket_products
  deferrable initially deferred
  for each row
  when (old.status = 'soldout' and new.status = 'active')
  execute function public.taam_ticket_restock_on_status();

-- ── 5. 알림 만들기 — Edge(service_role)가 부른다. 슈퍼어드민도 손으로 부를 수 있다 ──
create or replace function public.taam_ticket_restock_process(p_limit int default 10)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  ev record; chk jsonb; v_rows jsonb := '[]'::jsonb; v_n int := 0;
  v_title text; v_body text; v_url text; v_tier text; v_members uuid[]; v_admins uuid[]; v_made int;
  v_role text := coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role', '');
begin
  if not (public._taam_uid_is_super() or v_role = 'service_role' or session_user = 'postgres') then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  for ev in select * from public.ticket_restock_events where status = 'pending' order by created_at limit p_limit for update skip locked loop
    v_n := v_n + 1;
    chk := public.taam_ticket_restock_check(ev.ticket_product_id);
    if not coalesce((chk->>'ok')::boolean, false) then
      update public.ticket_restock_events set status = 'skipped', reason = chk->>'reason', processed_at = now() where id = ev.id;
      continue;
    end if;
    v_tier  := coalesce(chk->>'min_tier', '');
    v_title := '🎫 취소표가 나왔습니다';
    v_body  := coalesce(nullif(chk->>'rest',''), '매장') || ' · ' || (chk->>'date')
             || case when coalesce(chk->>'time','') <> '' then ' ' || (chk->>'time') else '' end
             || ' · 잔여 ' || (chk->>'seats_left') || '석 — 지금 예약할 수 있어요';
    v_url   := '/?ticket=' || ev.ticket_product_id;

    -- 받을 회원: 살 수 있는 사람만
    select coalesce(array_agg(p.id), '{}') into v_members
      from public.profiles p
     where p.deleted_at is null
       and coalesce(p.role, '') not in ('superadmin', 'super_admin')
       and (p.notif_prefs -> 'restock') is distinct from 'false'::jsonb
       and (p.notif_prefs -> 'all') is distinct from 'false'::jsonb
       and ( public.taam_tier_is_open(v_tier)
             or (v_tier = '' and upper(coalesce(p.membership_tier, '')) <> 'A')
             or public.taam_tier_rank(public.taam_user_tier(p.id)) >= public.taam_tier_rank(v_tier) )
       and public.taam_ticket_visible(ev.ticket_product_id, p.id)
       and not exists (select 1 from public.tickets t
                        where t.user_id = p.id and t.ticket_product_id = ev.ticket_product_id
                          and coalesce(t.status, '') <> 'cancelled');
    select coalesce(array_agg(p.id), '{}') into v_admins
      from public.profiles p where p.deleted_at is null and coalesce(p.role, '') in ('superadmin', 'super_admin');

    with ins as (
      insert into public.notifications (user_id, type, title, body, url, payload)
      select u, 'ticket_restock', v_title, v_body, v_url,
             jsonb_build_object('kind', 'ticket_restock', 'ticket_id', ev.ticket_product_id, 'event_id', ev.id,
                                'rest', chk->>'rest', 'date', chk->>'date', 'time', chk->>'time',
                                'seats_left', (chk->>'seats_left')::int)
        from unnest(v_members || v_admins) as u
      returning id)
    select count(*) into v_made from ins;

    update public.ticket_restock_events set status = 'sent', made = v_made, processed_at = now(), reason = null where id = ev.id;
    v_rows := v_rows || jsonb_build_object('event_id', ev.id, 'ticket_id', ev.ticket_product_id,
                                           'title', v_title, 'body', v_body, 'url', v_url,
                                           'rest', chk->>'rest', 'date', chk->>'date', 'time', chk->>'time',
                                           'seats_left', (chk->>'seats_left')::int,
                                           'member_ids', to_jsonb(v_members), 'admin_ids', to_jsonb(v_admins));
  end loop;
  return jsonb_build_object('events', v_n, 'rows', v_rows);
end $$;
revoke all on function public.taam_ticket_restock_process(int) from public;
grant execute on function public.taam_ticket_restock_process(int) to authenticated, service_role;

-- ── 6. Edge 가 푸시 결과를 적는다 ──
create or replace function public.taam_ticket_restock_mark_pushed(p_event_id bigint, p_push_sent int)
returns void language sql security definer set search_path = public as $$
  update public.ticket_restock_events set push_sent = coalesce(p_push_sent, 0) where id = p_event_id;
$$;
revoke all on function public.taam_ticket_restock_mark_pushed(bigint, int) from public;
grant execute on function public.taam_ticket_restock_mark_pushed(bigint, int) to service_role;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① 이벤트 표' as what, case when to_regclass('public.ticket_restock_events') is not null then '✅' else '❌' end as result
union all
select '② 검사 함수', case when to_regprocedure('public.taam_ticket_restock_check(text)') is not null then '✅' else '❌' end
union all
select '③ 전이 트리거 (지연 제약)', case when exists (select 1 from pg_trigger where tgname = 'trg_ticket_restock' and tgdeferrable and tginitdeferred) then '✅' else '❌' end
union all
select '④ 처리 함수', case when to_regprocedure('public.taam_ticket_restock_process(integer)') is not null then '✅' else '❌' end
union all
select '⑤ kick 함수', case when to_regprocedure('public.taam_restock_kick()') is not null then '✅' else '❌' end
union all
select '⑥ 의존 함수 (taam_visit_date · taam_ticket_visible · taam_user_tier)',
       case when to_regprocedure('public.taam_visit_date(text)') is not null and to_regprocedure('public.taam_ticket_visible(text,uuid)') is not null
             and to_regprocedure('public.taam_user_tier(uuid)') is not null then '✅' else '❌ 없음 — sql/visit_reminder.sql · ticket_audience.sql · guard_ticket_tier.sql 먼저' end
union all
select '⑦ Edge 호출 설정 (app_config restock_push)',
       case when exists (select 1 from public.app_config where key = 'restock_push') then '✅' else '⚠ 아직 없음 — 아래 안내대로 넣으면 즉시 발송, 없으면 1분 크론만' end;
