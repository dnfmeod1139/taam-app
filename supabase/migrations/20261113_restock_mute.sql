-- ============================================================================
-- 20261113_restock_mute.sql — 취소표 알림을 슈퍼어드민이 고른다(좌석을 풀 때마다 켬/끔) (2026-11-13)
-- ============================================================================
-- 왜
--   「다른 사람이 못 잡게 수동 추가(MAN-)로 자리를 잡아 뒀다가, 특정 회원에게 초대를 보내려고 그 홀드를 풀면
--   전원에게 「🎫 취소표가 나왔습니다」가 나간다 — 회원이 들어와 보면 곧 다시 매진(초대 홀드)이라 헷갈린다.」
--   매진이던 회차가 풀리는 길(soldout → active)은 전부 취소표 알림을 만든다(20260929_ticket_restock.sql).
--   슈퍼어드민이 좌석을 풀 때 「이번엔 알리지 않는다」를 고를 수 있게 한다.
--
-- 어떻게 — 라이브 함수 본문은 건드리지 않는다(덧대기)
--   ① 앱이 좌석을 풀기 직전에 taam_restock_mute(회차들, 분) 를 부른다 → ticket_restock_mutes 에 짧은 「끔」 줄(기본 5분 · 최대 30분)
--   ② 좌석을 푼다(× · 초대 회수 · 반환·환불 · 인원 줄임 · 판매 재개 · 결제 링크 끊기·환불 …) — 커밋 때 지연 트리거가 이벤트를 넣으려 하면
--      BEFORE INSERT 트리거 trg_taam_restock_mute 가 그 줄을 skipped · reason 'MUTED' 로 바꾼다(푸시·알림함 없음 · 기록은 남는다)
--   ③ 앱이 바로 taam_restock_unmute(token) 으로 끈 줄을 닫는다 → 실제로 막은 건수(hits)를 돌려준다(「취소표 알림 안 보냄」 안내)
--   · skipped 줄은 60분 쿨다운에 들지 않는다(쿨다운은 pending·sent 만 센다) — 알림을 끈 뒤 진짜 취소가 나면 그건 알린다.
--   · 앱이 ③ 을 못 부르면(끊김) 「끔」은 정한 시간이 지나면 저절로 풀린다. 그 사이 같은 회차가 다시 매진됐다 풀리면 그것도 조용히 지나간다(몇 분).
--   · 회원·매장 어드민은 부를 수 없다(슈퍼어드민·SQL Editor·서버만 · _taam_fee_caller_ok) — 그들이 푸는 좌석은 종전대로 알린다.
--   · 연계(패키지) 회차를 건너뛰는 trg_taam_restock_skip_package 와 함께 돈다(이름 순으로 이쪽이 먼저 — 둘 다 알림을 막는 쪽이라 순서는 상관없다).
-- ============================================================================

-- ── A. 「끔」 표 ──
create table if not exists public.ticket_restock_mutes (
  id                bigserial primary key,
  token             uuid not null,
  ticket_product_id text not null,
  until             timestamptz not null,
  note              text,
  set_by            uuid,
  set_at            timestamptz not null default now(),
  cleared_at        timestamptz,
  hits              int not null default 0,
  last_hit_at       timestamptz
);
create index if not exists idx_restock_mutes_live  on public.ticket_restock_mutes (ticket_product_id, until) where cleared_at is null;
create index if not exists idx_restock_mutes_token on public.ticket_restock_mutes (token);
alter table public.ticket_restock_mutes enable row level security;
drop policy if exists "restock mutes super read" on public.ticket_restock_mutes;
create policy "restock mutes super read" on public.ticket_restock_mutes
  for select to authenticated using (public._taam_uid_is_super());
revoke all on public.ticket_restock_mutes from public, anon, authenticated;
grant select on public.ticket_restock_mutes to authenticated;
grant all on public.ticket_restock_mutes to service_role;
revoke all on sequence public.ticket_restock_mutes_id_seq from public, anon, authenticated;

-- ── B. 끄기 · 닫기 — 슈퍼어드민 · SQL Editor · 서버만 ──
create or replace function public.taam_restock_mute(p_ticket_ids text[], p_minutes int default 5, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_tok uuid := gen_random_uuid(); v_ids text[]; v_min int; v_until timestamptz; v_uid uuid;
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_ids
    from unnest(coalesce(p_ticket_ids, '{}'::text[])) as x
   where x ~ '^[0-9A-Za-z_.:-]{1,64}$';
  if cardinality(v_ids) = 0 then raise exception 'BAD_TICKET_IDS' using errcode = '22023'; end if;
  if cardinality(v_ids) > 20 then raise exception 'TOO_MANY_TICKETS' using errcode = '22023'; end if;
  v_min   := least(30, greatest(1, coalesce(p_minutes, 5)));
  v_until := now() + make_interval(mins => v_min);
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  insert into public.ticket_restock_mutes (token, ticket_product_id, until, note, set_by)
  select v_tok, x, v_until, left(nullif(btrim(coalesce(p_note, '')), ''), 200), v_uid from unnest(v_ids) as x;
  return jsonb_build_object('ok', true, 'token', v_tok, 'until', v_until, 'minutes', v_min, 'ticket_ids', to_jsonb(v_ids));
end $$;

create or replace function public.taam_restock_unmute(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_n int := 0; v_hits int := 0; v_ids text[];
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_token is null then raise exception 'BAD_TOKEN' using errcode = '22023'; end if;
  update public.ticket_restock_mutes set cleared_at = now() where token = p_token and cleared_at is null;
  get diagnostics v_n = row_count;
  select coalesce(sum(hits), 0), coalesce(array_agg(ticket_product_id) filter (where hits > 0), '{}')
    into v_hits, v_ids from public.ticket_restock_mutes where token = p_token;
  return jsonb_build_object('ok', true, 'cleared', v_n, 'hits', v_hits, 'muted_ids', to_jsonb(v_ids));
end $$;

revoke all on function public.taam_restock_mute(text[], int, text), public.taam_restock_unmute(uuid) from public, anon;
grant execute on function public.taam_restock_mute(text[], int, text), public.taam_restock_unmute(uuid) to authenticated, service_role;

-- ── C. 이벤트가 들어오려 할 때 — 「끔」이 살아 있으면 skipped · MUTED ──
create or replace function public.taam_restock_mute_check()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.status, 'pending') = 'pending' then
    update public.ticket_restock_mutes set hits = hits + 1, last_hit_at = now()
     where ticket_product_id = new.ticket_product_id and cleared_at is null and until > now();
    if found then
      new.status := 'skipped'; new.reason := 'MUTED'; new.processed_at := now();
    end if;
  end if;
  return new;
exception when others then
  raise warning '[restock] 알림 끔 검사 실패(종전대로 알림): % %', sqlstate, sqlerrm;
  return new;
end $$;
revoke all on function public.taam_restock_mute_check() from public, anon, authenticated;

do $do$ begin
  if to_regclass('public.ticket_restock_events') is null then return; end if;
  execute 'drop trigger if exists trg_taam_restock_mute on public.ticket_restock_events';
  execute 'create trigger trg_taam_restock_mute before insert on public.ticket_restock_events for each row execute function public.taam_restock_mute_check()';
end $do$;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① 끔 표 ticket_restock_mutes (RLS 켬)' as what,
       case when exists (select 1 from pg_class where oid = to_regclass('public.ticket_restock_mutes') and relrowsecurity) then '✅' else '❌' end as result
union all
select '② 끄기·닫기 RPC',
       case when to_regprocedure('public.taam_restock_mute(text[],integer,text)') is not null
             and to_regprocedure('public.taam_restock_unmute(uuid)') is not null then '✅' else '❌' end
union all
select '③ 이벤트 표 BEFORE INSERT 트리거',
       case when to_regclass('public.ticket_restock_events') is null then '❌ 취소표 이벤트 표가 없다 — 20260929_ticket_restock.sql 먼저'
            when exists (select 1 from pg_trigger where tgname = 'trg_taam_restock_mute' and tgrelid = 'public.ticket_restock_events'::regclass and not tgisinternal)
            then '✅' else '❌' end
union all
select '④ 비로그인(anon)은 끄기 못 부름',
       case when not has_function_privilege('anon', 'public.taam_restock_mute(text[],integer,text)', 'execute') then '✅' else '❌' end
union all
select '⑤ 의존 함수 (_taam_fee_caller_ok · _taam_uid_is_super)',
       case when to_regprocedure('public._taam_fee_caller_ok()') is not null and to_regprocedure('public._taam_uid_is_super()') is not null then '✅' else '❌' end
union all
select '⑥ 지금 살아 있는 「끔」(정보)', (select count(*)::text from public.ticket_restock_mutes where cleared_at is null and until > now());
