-- ============================================================================
-- 20261116_round_move_sync.sql — 회차 날짜·시간을 바꾸면 팔린 예약·초대·정산 좌석이 같이 옮겨 간다 (2026-11-15 운영 결정 「같이 옮긴다」)
-- ============================================================================
-- 왜
--   회차(ticket_products.date/time)를 고쳐도 이미 팔린 티켓(tickets.reservation_date/visit_time)·초대(reservation_invites.visit_date/
--   visit_time)·정산 회차(kashikiri_events.event_date/time)는 옛 날짜에 남았다. 리마인드·환불 D-31·캘린더·판매 현황·방문 기록이
--   모두 행의 날짜를 읽으므로 회원은 옛 날짜로 안내받고, 환불 규정도 옛 날짜로 셌다(2026-11-15 재구매 제한 점검에서 드러남).
--
-- 어떻게 (라이브 함수 본문 대조 · 2026-11-15 — 함수마다 md5 는 아래)
--   ① AFTER UPDATE OF date, time 트리거 trg_taam_tp_round_move — 날짜나 시간이 실제로 바뀌면(형식만 다른 저장은 아님)
--      그 회차의 살아 있는 예약을 같은 트랜잭션에서 옮기고 ticket_round_moves 에 한 줄 남긴다. 어느 경로든(앱 RPC · 파트너 수정 승인
--      taam_ticket_edit_review · SQL Editor) 이 트리거 하나가 본다.
--      · 옮기지 않는 것: 취소·만료·환불 행(그 날짜로 환불을 셌다 — 기록) · 방문 처리된 행 · 옛 날짜가 이미 지난 회차 ·
--        새 날짜가 오늘 이전인 이동(연도 실수 — NEW_DATE_PAST 로 기록만) · 회차 날짜와 다르게 적힌 행(date_diverged — 지금 0건).
--      · 시간: 그 행의 시간이 회차의 옛 시간(또는 비어 있음)일 때만 새 시간으로 — 따로 바꾼 시간(초대 시간 변경 · 수동 좌석 20:30)은 지킨다.
--      · 정산 좌석(KSK-)은 정산 회차(kashikiri_events)를 옮기고 _taam_ksk_seat_sync 를 직접 부른다(좌석 날짜의 주인은 정산 회차).
--      · 행마다 따로(서브트랜잭션) — 한 행이 실패하거나 잠겨 있으면(NOWAIT) 그 행만 옛 날짜에 남기고 errors 에 적는다(재동기화로 맞춘다).
--      · 같이 맞추는 것: 구매 규정 예외의 기본 기한(옛 방문일 끝 → 새 방문일 끝) · 결제 링크 청구의 부제(YYYY.MM.DD HH:MM) ·
--        비회원 알림톡 리마인드 기록(새 날짜로 다시 나가게) · (선택) 같은 매장·같은 날의 캘린더 수동 기록.
--      · 옮긴 뒤 겹침(그 회원의 같은 날 같은 시간대 다른 예약)·재구매 제한 창은 막지 않고 기록한다 — 매장이 옮긴 예약이다.
--   ② 앱이 직접 보낸 저장(current_user = authenticated)이 「옮길 예약이 있는 회차」의 날짜·시간을 바꾸면 거절한다
--      (ROUND_RESCHEDULE_REQUIRED). 날짜 이동은 taam_round_reschedule RPC(슈퍼어드민 · 화면이 본 옛 값과 다르면 STALE_ROUND)로만 —
--      낡은 화면의 매진 토글·연장 저장이 옛 날짜를 다시 써서 예약을 통째로 되돌리는 길을 막는다(검토 C1).
--   ③ 중복·시간대 가드(taam_guard_purchase_unique · 라이브 md5 ed27df3b…)에 「회차 이동 중인 그 회차의 행」 통과 한 덩어리를 넣는다
--      (GUC taam.round_move = 회차 id · 같은 회원·같은 회차·같은 상태일 때만 · 회원 잠금은 기다리지 않고 잡아 보고 못 잡으면 busy).
--      이걸 안 넣으면 같은 회차에 두 장을 가진 회원(라이브 5쌍)의 두 번째 행이 TIME_CONFLICT 로 옛 날짜에 갈라진다.
--   ④ 새로 넣는 좌석 행·초대는 회차 날짜로 맞춘다(BEFORE INSERT 고정 — 시간은 비어 있을 때만 · 회차 행을 잠그고 읽는다) — 낡은 화면이 옛 날짜로 넣는 길.
--   ⑤ 리마인드 중복 방지에 날짜를 넣는다 — 종전엔 (티켓·일수)만 봐서 옮긴 예약의 3일 전·하루 전이 새 날짜로 다시 안 갔다.
--      taam_visit_reminder_notify(52d0603a…) · _taam_vr_seat_status(b42fdace…) — md5 가 다르면 건드리지 않고 ❌.
--   ⑥ RPC — taam_round_move_preview(옮길 것 · 남길 것 · 겹침 · 환불 규정이 바뀌는 예약 · 수동 기록 후보) · taam_round_reschedule ·
--      taam_round_move_notify(회원 알림함 + 푸시 세 벌 · 한 번만) · taam_round_move_resync(남은 행 다시) · taam_round_moves(기록).
--      전부 슈퍼어드민 · SQL Editor · 서버(_taam_fee_caller_ok).
--
-- 2차(배포 전 적대 리뷰 반영 · 2026-11-16) — 이 파일은 아직 라이브에 올라가지 않아 그 자리에서 고쳤다
--   RM-1 끝나지 않은 이동(NEW_DATE_PAST · NEW_DATE_UNREADABLE · busy · error)의 옛 날짜도 따라온다 — 연도 실수를 고치는 이동이
--        처음 날짜에 남은 예약을 데려온다(트리거 · 미리보기 · 앱 저장 잠금이 같은 집합 · _taam_round_follow_spec)
--   RM-2 다시 맞추기는 예전 시간 전부가 아니라 「그 행을 남긴 기록의 (옛 날짜, 옛 시간)」·풀리지 않은 행 오류만 시간을 따른다 — 따로 바꾼 시간을 지킨다
--   RM-3 새 좌석·초대의 날짜 고정이 회차 행을 FOR NO KEY UPDATE 로 읽는다(이동 중이면 기다렸다 새 날짜로) · 가드 덩어리는 회원 잠금을
--        기다리지 않는다(try-lock → busy · 교착 대신 다시 맞추기)
--   RM-4 다시 맞추기가 앞으로 올 정산 회차(+ 동기화가 실패했던 정산 회차)의 좌석을 다시 맞추고, 실제로 바뀐 좌석이 있으면 기록한다
--   RM-5 부제·비회원 알림톡 기록은 이번에 실제로 옮긴 좌석 기준(다시 맞추기도) · 결제된 초대의 좌석이 같이 안 옮겨졌으면 초대로 알린다
--   RM-6 정산 좌석은 정산 회차의 판정을 따른다(정산 회차가 옮겨 갈 때만 「옮길 예약」 — 지난 회차의 날짜를 고칠 수 있다)
--   미리보기에 last_move_id(앱이 잃은 응답을 다시 확인하는 기준)
--
-- 3차(2차 판 검증 반영 · 2026-11-16) — 역시 라이브 전이라 그 자리에서
--   NEW-1 오류가 남은 기록이 영원히 「끝나지 않음」이었다 — 그 (옛 날짜, 옛 시간) 짝이 뒤 이동마다 끼어 따로 바꾼 시간을 회차 시간으로 덮고
--        회원에게 틀린 시간 알림이 갔다. → 기록은 남은 행이 있을 때만 open(행 오류 = 그 행이 살아 있고 뒤 기록이 안 옮김 · NEW_DATE_* = 그 옛 날짜에
--        옮길 수 있는 행이 남음) · 회차의 지금 옛 날짜와 같은 날짜의 짝은 트리거·미리보기·앱 저장 잠금에서 뺀다(_taam_round_spec_skip_od)
--   NEW-2 다시 맞추기도 짝은 open 기록에서만(날짜는 기록 전부) — 끝난 기록의 짝이 따로 바꾼 시간을 덮었다
--   NEW-3 같은 회원에게 같은 새 날짜·시간을 가장 최근에 알렸으면 다시 보내지 않는다(skipped · already_notified)
--   NEW-5 캘린더 수동 기록도 따라올 날짜 전부에서(연도 실수를 고치는 이동) · 미리보기 후보마다 ymd · movable
--   NEW-6 좌석 날짜 고정이 날짜·시간을 바꿨으면 같은 날 같은 시간대 겹침을 고정한 값으로 다시 본다(TIME_CONFLICT · 예외 존중)
--   덤: 연도 실수로 지난 날에 가 있는 회차의 「시간만」 바꾸기가 처음 날짜의 앞날 예약을 지난 날로 끌어왔다 → NEW_DATE_PAST 로 기록만
--
-- 4차(3차 판 재검증 반영 · 2026-11-16) — 역시 라이브 전이라 그 자리에서
--   RC3-1 고친 연도 실수 기록이 다시 open 이 됐다 — 그 날짜에 회차가 돌아온 뒤 다음 이동이 행 하나(busy · 잠긴 초대 · 두 번째 연도 실수)를
--        남기면 처음 기록의 (옛 날짜, 옛 시간) 짝이 살아나 다시 맞추기·연도 고침이 따로 바꾼 시간을 회차 시간으로 덮고 틀린 시간을 알렸다
--        → NEW_DATE_* 기록은 그 옛 날짜에서 출발한 뒤 기록이 생기면 닫는다(남은 행은 그 뒤 기록이 따라간다)
--   RC3-2 연도 실수 날에 바꾼 시간이 연도를 처음 날짜로 고칠 때 따라가지 않았다 — 처음 날짜의 예약은 이미 목표 날짜라 짝 규칙(옮겨 가는 행만)에
--        안 걸려 옛 시간에 남고(미리보기는 「따로 바꾼 시간」), 옮길 것이 없어 앱은 시트도 알림도 없었다
--        → 끝나지 않은 NEW_DATE_* 기록의 짝(rpairs)은 목표 날짜에 있는 행도 따른다 · 회차가 그 날짜에 있는 동안(그 날짜에서 출발하는 이동 ·
--          다시 맞추기)은 그 날짜의 짝을 뺀다(_taam_round_spec_skip_od — 다시 맞추기도) · 행 오류는 그 행이 시간을 따라가던 중이었으면
--          그때 시간(ft)을 적어 다시 맞추기·다음 이동이 그 시간으로 알아본다(짝으로 따라가던 행은 기록의 옛 시간과 다르다)
--
-- 되돌리기: drop trigger trg_taam_tp_round_move on public.ticket_products; drop trigger trg_taam_tp_round_lock on public.ticket_products;
--   (가드 덩어리는 GUC 가 없으면 아무 일도 안 한다 — 그대로 둬도 된다)
-- ============================================================================

-- ── 0. 도우미 ─────────────────────────────────────────────────────────────
create or replace function public._taam_hhmm(p text)
returns text language sql immutable set search_path = public as $$
  select case when btrim(coalesce(p, '')) ~ '^\d{1,2}:\d{1,2}(:\d{1,2}(\.\d+)?)?$'
               and split_part(btrim(p), ':', 1)::int between 0 and 23
               and split_part(btrim(p), ':', 2)::int between 0 and 59
              then lpad(split_part(btrim(p), ':', 1), 2, '0') || ':' || lpad(split_part(btrim(p), ':', 2), 2, '0') end
$$;

-- 날짜(+시간)를 세 언어로 — 알림 문구용
create or replace function public._taam_rm_dt(p_d date, p_t text, p_lang text)
returns text language sql stable set search_path = public as $$
  select case when p_d is null then '' else
    case lower(coalesce(p_lang, 'ko'))
      when 'en' then to_char(p_d, 'Dy, Mon FMDD, YYYY')
      when 'ja' then to_char(p_d, 'YYYY') || '年' || extract(month from p_d)::int || '月' || extract(day from p_d)::int || '日('
                     || (array['日','月','火','水','木','金','土'])[extract(dow from p_d)::int + 1] || ')'
      else to_char(p_d, 'YYYY') || '년 ' || extract(month from p_d)::int || '월 ' || extract(day from p_d)::int || '일('
                     || (array['일','월','화','수','목','금','토'])[extract(dow from p_d)::int + 1] || ')'
    end end || coalesce(' ' || nullif(btrim(coalesce(p_t, '')), ''), '')
$$;

-- ── 1. 이동 기록 ──────────────────────────────────────────────────────────
create table if not exists public.ticket_round_moves (
  id          bigserial primary key,
  round_id    text not null,
  rest_name   text,
  old_date    text, old_time text, new_date text, new_time text,
  moved_by    uuid,
  via         text not null default 'trigger',      -- trigger(승인·SQL Editor) | reschedule(앱 RPC) | resync
  at          timestamptz not null default now(),
  moved       jsonb not null default '[]'::jsonb,   -- [{kind, id, pid, uid, owner, st, pax, from:{d,t}, to:{d,t}, time_kept}]
  kept        jsonb not null default '[]'::jsonb,   -- [{kind, id, pid, uid, owner, st, reason}]
  conflicts   jsonb not null default '[]'::jsonb,   -- [{kind: time|repurchase, id, pid, uid, other:{...}}]
  errors      jsonb not null default '[]'::jsonb,   -- [{kind, id, pid, code, sqlstate, msg}]
  side        jsonb not null default '{}'::jsonb,   -- exceptions · subtitles · guest_log · ksk · manual
  note        text,
  notified_at timestamptz,
  notify_result jsonb
);
create index if not exists ticket_round_moves_round on public.ticket_round_moves (round_id, id);
alter table public.ticket_round_moves enable row level security;
drop policy if exists trm_super_read on public.ticket_round_moves;
create policy trm_super_read on public.ticket_round_moves for select to authenticated using (public.is_superadmin());
revoke insert, update, delete on public.ticket_round_moves from anon, authenticated;
revoke all on public.ticket_round_moves from anon;


-- ── 1-2. 끝나지 않은 이동 — 다음 이동·미리보기·다시 맞추기가 따라갈 옛 날짜와 (날짜, 시간) 짝 (2차 검토 RM-1 · RM-2 · 3차 NEW-1 · NEW-2) ─────────
--   오류가 남은 기록(NEW_DATE_PAST · NEW_DATE_UNREADABLE · busy · error)의 옛 날짜에는 옮기지 못한 행이 남아 있을 수 있다.
--   종전엔 다음 이동이 회차의 「지금」 옛 날짜 하나만 따라가서, 연도 실수(NEW_DATE_PAST)를 고친 뒤에도 예약 전부가 처음 날짜에 남았다.
--   3차(NEW-1): 기록이 「끝나지 않음(open)」인 것은 오류가 있어서가 아니라 **남은 행이 있을 때만**이다 — 종전엔 오류가 한 줄이라도 있으면
--     영원히 open 이라, 그 기록의 (옛 날짜, 옛 시간) 짝이 몇 번이고 뒤 이동에 끼어 따로 바꾼 시간을 회차 시간으로 덮었다(회원에게 틀린 시간 알림).
--     · 행 오류(busy · error — ticket/invite/event) — 그 행이 아직 살아 있고 뒤 기록이 그 행을 옮기지 않았을 때만 open
--     · 기록 오류(NEW_DATE_PAST · NEW_DATE_UNREADABLE) — 그 옛 날짜에 아직 옮길 수 있는 행(살아 있고 방문 처리 안 된 · 지난 날 아님)이 남아 있고
--       **그 날짜에서 출발한 뒤 기록(다시 맞추기 아님)이 아직 없을 때만** open (4차 RC3-1)
--       (「뒤 기록이 아무거나 있으면 닫는다」는 쓰지 않았다 — 뒤 기록이 다른 날짜에서 또 NEW_DATE_PAST 면 처음 날짜의 예약이 영영 남는다.
--        그 날짜에서 출발한 뒤 기록은 그 날짜의 행을 전부 봤다 — 남긴 행은 그 기록의 행 오류·짝이(그 기록도 NEW_DATE_* 면 그 기록이) 따라간다.
--        종전엔 연도 실수를 고쳐 그 날짜로 돌아온 뒤에도, 다음 이동이 행 하나를 남기면 처음 기록이 다시 open 이 되어 그 옛 시간 짝이
--        따로 바꾼 시간을 회차 시간으로 덮었다)
--     · 정산 좌석 동기화(ksk_sync)·부제·기록 지움 같은 곁가지 오류는 행을 옛 날짜에 남기지 않으므로 open 이 아니다(ksk 목록은 따로)
--   p_all = true(다시 맞추기)면 기록 전부의 옛 날짜를 준다 — 짝(pairs)은 언제나 open 기록에서만(3차 NEW-2: 다시 맞추기가 끝난 기록의
--     짝으로 따로 바꾼 시간을 덮었다). 회차의 지금 옛 날짜와 같은 날짜의 짝은 부르는 쪽이 뺀다(_taam_round_spec_skip_od).
--   err = 아직 풀리지 않은 행 오류(뒤 기록이 그 행을 옮기지 않았고 아직 살아 있다) → 그 기록의 옛 시간(hh:mm).
--   시간은 이 짝·오류로만 따라간다 — 예전 시간 전부를 따라가면 따로 바꾼 시간(⏰ 시간 변경)이 회차 시간으로 되돌아갔다(검토 RM-2).
--   ksk = 정산 좌석 동기화가 실패했던 정산 회차(다시 맞추기가 다시 부른다 · 검토 RM-4)

-- 그 행이 아직 살아 있나(취소·만료·환불 아님 · 초대는 보냄/결제됨 · 정산 회차는 이 회차에 있음)
create or replace function public._taam_round_row_live(p_round text, p_kind text, p_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select case p_kind
    when 'ticket' then exists (select 1 from public.tickets t where t.id::text = p_id and t.ticket_product_id::text = p_round
                                  and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'failed', 'refunded'))
    when 'invite' then exists (select 1 from public.reservation_invites i where i.id::text = p_id and i.ticket_product_id::text = p_round
                                  and lower(coalesce(i.status, '')) in ('sent', 'paid'))
    when 'event'  then exists (select 1 from public.kashikiri_events e where e.id::text = p_id and e.ticket_product_id = p_round)
    else false end
$$;
revoke all on function public._taam_round_row_live(text, text, text) from public, anon, authenticated;

-- 그 날짜에 이 회차의 「옮길 수 있는」 행이 남아 있나 — 살아 있고 방문 처리 안 된 좌석 행(정산 좌석은 정산 회차가 대신)·보냄/결제 초대·정산 회차.
--   지난 날짜는 언제나 false(지난 회차의 행은 옮기지 않는다 — past_round)
create or replace function public._taam_round_live_on(p_round text, p_date date)
returns boolean language sql stable security definer set search_path = public as $$
  select p_date is not null and p_date >= (now() at time zone 'Asia/Seoul')::date and (
         exists (select 1 from public.tickets t
                  where t.ticket_product_id::text = p_round
                    and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'failed', 'refunded', 'used', 'completed')
                    and t.visit_status is null
                    and coalesce(t.purchase_id, '') not like 'KSK-%'
                    and public._taam_pu_visit_date(t.reservation_date) = p_date)
      or exists (select 1 from public.reservation_invites i
                  where i.ticket_product_id::text = p_round and lower(coalesce(i.status, '')) in ('sent', 'paid')
                    and public._taam_pu_visit_date(i.visit_date) = p_date)
      or exists (select 1 from public.kashikiri_events e where e.ticket_product_id = p_round and e.event_date = p_date))
$$;
revoke all on function public._taam_round_live_on(text, date) from public, anon, authenticated;

create or replace function public._taam_round_follow_spec(p_round text, p_all boolean default false)
returns jsonb language sql stable security definer set search_path = public as $$
  with m as (
    select m.id, m.via, public._taam_pu_visit_date(m.old_date) as od, public._taam_hhmm(m.old_time) as ot,
           coalesce(m.errors, '[]'::jsonb) as errs,
           exists (select 1 from jsonb_array_elements(coalesce(m.errors, '[]'::jsonb)) x
                    where x->>'code' in ('NEW_DATE_PAST', 'NEW_DATE_UNREADABLE')) as rec_err
      from public.ticket_round_moves m
     where m.round_id = p_round),
  x as (   -- 풀리지 않은 행 오류 — 뒤 기록이 그 행을 옮기지 않았고 그 행이 아직 살아 있다
    --   시간 = 그 행이 시간을 따라가던 중이었으면 그 행의 그때 시간(ft · 4차 RC3-2 — 짝으로 따라가던 행은 기록의 옛 시간과 다르다),
    --          아니면 기록의 옛 시간(따로 바꾼 시간은 이 값과 달라 따라가지 않는다)
    select m.id as mid, coalesce(public._taam_hhmm(x->>'ft'), m.ot) as ot, x->>'id' as rid
      from m cross join lateral jsonb_array_elements(m.errs) x
     where m.via <> 'resync'
       and x->>'kind' in ('ticket', 'invite', 'event') and nullif(x->>'id', '') is not null
       and not exists (select 1 from public.ticket_round_moves m2 cross join lateral jsonb_array_elements(m2.moved) y
                        where m2.round_id = p_round and m2.id > m.id and y->>'id' = x->>'id')
       and public._taam_round_row_live(p_round, x->>'kind', x->>'id')),
  o as (
    select m.*, (exists (select 1 from x where x.mid = m.id)
                 or (m.rec_err and public._taam_round_live_on(p_round, m.od)
                     -- 4차 RC3-1: 그 옛 날짜에서 출발한 뒤 기록(다시 맞추기 아님)이 있으면 닫힌다 — 그 날짜에 남은 행은 그 뒤 기록이
                     --   자기 오류·짝으로 따라간다(뒤 기록도 NEW_DATE_* 면 그 기록이 같은 날짜로 open — 처음 날짜의 예약은 그대로 따라온다)
                     and not exists (select 1 from public.ticket_round_moves m3
                                      where m3.round_id = p_round and m3.id > m.id and m3.via <> 'resync'
                                        and public._taam_pu_visit_date(m3.old_date) = m.od))) as open
      from m)
  select jsonb_build_object(
    'dates', coalesce((select jsonb_agg(distinct to_char(o.od, 'YYYY-MM-DD')) from o where o.od is not null and (p_all or o.open)), '[]'::jsonb),
    'pairs', coalesce((select jsonb_agg(distinct jsonb_build_array(to_char(o.od, 'YYYY-MM-DD'), o.ot)) from o
                        where o.od is not null and o.ot is not null and o.open), '[]'::jsonb),
    -- 4차 RC3-2: NEW_DATE_* 기록의 짝 — 이미 목표 날짜에 있는 행도 따른다(연도 실수 날에 바꾼 시간이 처음 날짜로 되돌아올 때 같이 간다)
    'rpairs', coalesce((select jsonb_agg(distinct jsonb_build_array(to_char(o.od, 'YYYY-MM-DD'), o.ot)) from o
                        where o.od is not null and o.ot is not null and o.open and o.rec_err), '[]'::jsonb),
    'err',   coalesce((select jsonb_object_agg(z.rid, z.ot) from (select distinct on (x.rid) x.rid, x.ot from x order by x.rid, x.mid desc) z), '{}'::jsonb),
    'open',  coalesce((select jsonb_agg(o.id order by o.id) from o where o.open), '[]'::jsonb),
    'ksk',   coalesce((select jsonb_agg(distinct x->>'id') from m cross join lateral jsonb_array_elements(m.errs) x
                        where x->>'kind' = 'ksk_sync' and nullif(x->>'id', '') is not null), '[]'::jsonb))
$$;
revoke all on function public._taam_round_follow_spec(text, boolean) from public, anon, authenticated;

-- 회차의 지금 옛 날짜(p_od)와 같은 날짜의 짝은 뺀다(3차 NEW-1) — 회차 날짜에 있는 행의 시간이 회차 시간과 다르면 그건 따로 바꾼 시간이다.
--   그 날짜에 정말 못 옮긴 행은 행 오류(err)가 id 로 따라간다. 트리거 · 미리보기 · 앱 저장 잠금이 같이 쓴다
create or replace function public._taam_round_spec_skip_od(p_spec jsonb, p_od date)
returns jsonb language sql immutable as $$
  select case when p_spec is null or p_od is null then p_spec else
    jsonb_set(jsonb_set(p_spec, '{pairs}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(p_spec->'pairs', '[]'::jsonb)) x
                                                      where x->>0 is distinct from to_char(p_od, 'YYYY-MM-DD')), '[]'::jsonb)),
              '{rpairs}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(p_spec->'rpairs', '[]'::jsonb)) x
                                     where x->>0 is distinct from to_char(p_od, 'YYYY-MM-DD')), '[]'::jsonb)) end
$$;
revoke all on function public._taam_round_spec_skip_od(jsonb, date) from public, anon, authenticated;

-- 따라올 날짜 = 회차의 옛 날짜 + 끝나지 않은 기록의 옛 날짜(날짜만)
create or replace function public._taam_round_follow_dates(p_od date, p_spec jsonb)
returns date[] language sql immutable as $$
  select array[p_od] || coalesce(array(select d::date from jsonb_array_elements_text(coalesce(p_spec->'dates', '[]'::jsonb)) d
                                        where d::date is distinct from p_od), '{}'::date[])
$$;
revoke all on function public._taam_round_follow_dates(date, jsonb) from public, anon, authenticated;

-- 시간이 따라오나 — 이 행이 풀리지 않은 오류로 남은 행이고 그 기록의 옛 시간 그대로이거나,
--   (그 기록의 옛 날짜, 옛 시간) 그대로 남아 있을 때만(이미 목표 날짜에 있는 행은 짝으로는 안 따라간다 — 따로 바꾼 시간)
--   4차 RC3-2: 단 끝나지 않은 NEW_DATE_* 기록의 짝(rpairs)은 목표 날짜에 있는 행도 따른다 — 연도 실수 날에 시간을 바꾼 뒤 연도를
--     처음 날짜로 고치면, 처음 날짜에 남은 예약은 이미 목표 날짜라 짝으로는 안 따라가 옛 시간에 남았다. 회차가 그 날짜에 있을 때(그 날짜에서
--     출발하는 이동 · 그 날짜로 다시 맞추기)는 부르는 쪽이 _taam_round_spec_skip_od 로 뺀다 — 거기서 따로 바꾼 시간을 지킨다
create or replace function public._taam_rm_tf_spec(p_spec jsonb, p_id text, p_rd date, p_rt text, p_nd date)
returns boolean language sql immutable as $$
  select coalesce(
    (coalesce(p_spec->'err', '{}'::jsonb) ? p_id and (p_spec->'err'->>p_id) is not distinct from p_rt)
    or (p_rd is not null and p_rt is not null and p_rd is distinct from p_nd
        and coalesce(p_spec->'pairs', '[]'::jsonb) @> jsonb_build_array(jsonb_build_array(to_char(p_rd, 'YYYY-MM-DD'), p_rt)))
    or (p_rd is not null and p_rt is not null
        and coalesce(p_spec->'rpairs', '[]'::jsonb) @> jsonb_build_array(jsonb_build_array(to_char(p_rd, 'YYYY-MM-DD'), p_rt))), false)
$$;
revoke all on function public._taam_rm_tf_spec(jsonb, text, date, text, date) from public, anon, authenticated;

-- ── 2. 계획 — 무엇이 옮겨 가고 무엇이 남는가 (트리거 · 미리보기 · 재동기화가 같이 쓴다) ─────────────
--   p_nd/p_nt = 목표 날짜·시간(p_nt null 이면 시간은 안 바꾼다)
--   p_fd = 「따라와도 되는」 옛 날짜들 · p_ft = 따라와도 되는 옛 시간들(트리거는 회차의 옛 시간 하나 · 다시 맞추기는 빈 배열) — 빈 값은 언제나 따라온다
--   p_spec = _taam_round_follow_spec — 끝나지 않은 이동이 남긴 행의 시간(짝 · 행 오류)
drop function if exists public._taam_round_move_plan(text, date, text, date[], text[]);
create or replace function public._taam_round_move_plan(p_round text, p_nd date, p_nt text, p_fd date[], p_ft text[], p_spec jsonb default null)
returns table(kind text, ref_id text, purchase_id text, user_id uuid, owner text, st text, pax int,
              action text, reason text, from_d text, from_t text, to_d text, to_t text, time_kept boolean, extra jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_nds   text := to_char(p_nd, 'YYYY.MM.DD');
  r record; v_rd date; v_rt text; v_dfollow boolean; v_tfollow boolean; v_own text; v_st text; v_pid text;
  v_evact jsonb := '{}'::jsonb; v_ea jsonb;
begin
  -- 정산 회차
  for r in select e.id, e.event_date, e.event_time from public.kashikiri_events e where e.ticket_product_id = p_round loop
    kind := 'event'; ref_id := r.id::text; purchase_id := null; user_id := null; owner := 'event'; st := null; pax := null;
    from_d := to_char(r.event_date, 'YYYY.MM.DD'); from_t := to_char(r.event_time, 'HH24:MI');
    v_dfollow := coalesce(p_nd is not null and r.event_date is distinct from p_nd and r.event_date = any(coalesce(p_fd, '{}'::date[])), false);
    v_tfollow := coalesce(p_nt is not null and r.event_time is not null and from_t is distinct from p_nt
                          and (from_t = any(coalesce(p_ft, '{}'::text[])) or public._taam_rm_tf_spec(p_spec, r.id::text, r.event_date, from_t, p_nd)), false);
    to_d := case when v_dfollow then v_nds else from_d end;
    to_t := case when v_tfollow then p_nt else from_t end;
    time_kept := coalesce(p_nt is not null and r.event_time is not null and not v_tfollow and from_t is distinct from p_nt, false);
    extra := jsonb_build_object('time_null', r.event_time is null);
    if r.event_date < v_today then action := 'keep'; reason := 'past_round';
    elsif v_dfollow or v_tfollow then action := 'move'; reason := null;
    elsif p_nd is not null and r.event_date is distinct from p_nd then action := 'keep'; reason := 'date_diverged';
    else action := 'same'; reason := null; end if;
    v_evact := v_evact || jsonb_build_object(r.id::text, jsonb_build_object('a', action, 'r', reason));
    return next;
  end loop;

  -- 좌석 행
  for r in select t.* from public.tickets t where t.ticket_product_id::text = p_round loop
    v_st := lower(coalesce(r.status, '')); v_pid := coalesce(r.purchase_id, '');
    if v_st in ('cancelled', 'canceled', 'expired', 'failed', 'refunded') then continue; end if;   -- 기록 — 목록에도 안 싣는다
    v_own := case when v_pid like 'KSK-%' then 'ksk'
                  when v_pid like 'MAN-%' then 'manual'
                  when v_pid like 'INVH-%' then 'invite_hold'
                  when v_pid like 'LINK-%' and nullif(r.extra_data->>'memberUid', '') is null then 'guest_link'
                  when v_pid ~ '^PAY' or v_pid ~ '^[0-9]' or v_pid like 'INV-%' or v_pid like 'LINK-%' then 'member'
                  when public._taam_ticket_is_ops(r.purchase_id, r.extra_data) then 'ops'
                  else 'member' end;
    kind := 'ticket'; ref_id := r.id::text; purchase_id := r.purchase_id; user_id := r.user_id; owner := v_own; st := v_st;
    pax := r.party_size; extra := jsonb_build_object('buyer', coalesce(r.buyer_name, ''), 'price', coalesce(r.price, 0),
                                                     'charge_id', r.extra_data->>'chargeId', 'invite_id', r.extra_data->>'inviteId');
    from_d := r.reservation_date; from_t := r.visit_time;
    v_rd := public._taam_pu_visit_date(r.reservation_date); v_rt := public._taam_hhmm(r.visit_time);
    v_dfollow := coalesce(p_nd is not null
                 and (btrim(coalesce(r.reservation_date, '')) = '' or (v_rd is distinct from p_nd and v_rd = any(coalesce(p_fd, '{}'::date[])))), false);
    v_tfollow := coalesce(p_nt is not null
                 and (btrim(coalesce(r.visit_time, '')) = ''
                      or (v_rt is distinct from p_nt and (v_rt = any(coalesce(p_ft, '{}'::text[]))
                                                          or public._taam_rm_tf_spec(p_spec, r.id::text, v_rd, v_rt, p_nd)))), false);
    to_d := case when v_dfollow then v_nds else r.reservation_date end;
    to_t := case when v_tfollow then p_nt else r.visit_time end;
    time_kept := coalesce(p_nt is not null and not v_tfollow and v_rt is distinct from p_nt, false);
    if v_own = 'ksk' then
      -- 정산 좌석은 정산 회차를 따른다 — 정산 회차가 옮겨 갈 때만 「같이 옮김」(검토 RM-6: 지난 회차·남긴 회차의 정산 좌석이 언제나
      --   옮길 예약으로 세어져 날짜를 어느 쪽으로도 못 고쳤다)
      v_ea := v_evact -> (r.extra_data->>'eventId');
      if v_ea is null then action := 'same'; reason := null;
      elsif v_ea->>'a' = 'move' then action := 'event'; reason := 'ksk_via_event';
      elsif v_ea->>'a' = 'keep' then action := 'keep'; reason := v_ea->>'r';
      else action := 'same'; reason := null; end if;
    elsif r.visit_status is not null or v_st in ('used', 'completed') then action := 'keep'; reason := 'visited';
    elsif coalesce(v_rd, p_nd) < v_today then action := 'keep'; reason := 'past_round';
    elsif v_dfollow or v_tfollow then action := 'move'; reason := null;
    elsif p_nd is not null and v_rd is distinct from p_nd then action := 'keep'; reason := 'date_diverged';
    elsif time_kept then action := 'keep'; reason := 'time_individual';   -- 따로 바꾼 시간(초대 시간 변경 · 수동 좌석) — 지킨다
    else action := 'same'; reason := null; end if;
    return next;
  end loop;

  -- 초대(보냄 · 결제됨)
  for r in select i.* from public.reservation_invites i
            where i.ticket_product_id::text = p_round and lower(coalesce(i.status, '')) in ('sent', 'paid') loop
    kind := 'invite'; ref_id := r.id::text; purchase_id := null; user_id := r.invitee_user_id; owner := 'invite'; st := lower(r.status);
    pax := r.pax; extra := jsonb_build_object('host', r.host_user_id);
    from_d := r.visit_date; from_t := r.visit_time;
    v_rd := public._taam_pu_visit_date(r.visit_date); v_rt := public._taam_hhmm(r.visit_time);
    v_dfollow := coalesce(p_nd is not null
                 and (btrim(coalesce(r.visit_date, '')) = '' or (v_rd is distinct from p_nd and v_rd = any(coalesce(p_fd, '{}'::date[])))), false);
    v_tfollow := coalesce(p_nt is not null
                 and (btrim(coalesce(r.visit_time, '')) = ''
                      or (v_rt is distinct from p_nt and (v_rt = any(coalesce(p_ft, '{}'::text[]))
                                                          or public._taam_rm_tf_spec(p_spec, r.id::text, v_rd, v_rt, p_nd)))), false);
    to_d := case when v_dfollow then v_nds else r.visit_date end;
    to_t := case when v_tfollow then p_nt else r.visit_time end;
    time_kept := coalesce(p_nt is not null and not v_tfollow and v_rt is distinct from p_nt, false);
    if exists (select 1 from public.tickets k where k.extra_data->>'inviteId' = r.id::text
                and (k.visit_status is not null or lower(coalesce(k.status, '')) in ('used', 'completed'))) then
      action := 'keep'; reason := 'visited';
    elsif coalesce(v_rd, p_nd) < v_today then action := 'keep'; reason := 'past_round';
    elsif v_dfollow or v_tfollow then action := 'move'; reason := null;
    elsif p_nd is not null and v_rd is distinct from p_nd then action := 'keep'; reason := 'date_diverged';
    elsif time_kept then action := 'keep'; reason := 'time_individual';
    else action := 'same'; reason := null; end if;
    return next;
  end loop;
end $$;
revoke all on function public._taam_round_move_plan(text, date, text, date[], text[], jsonb) from public, anon, authenticated;


-- 옮긴 뒤 그 회원의 다른 예약과 겹치나(같은 날 같은 시간대) — 가드 ②와 같은 식 · 이 회차의 시간대 예외도 본다(검토 F3)
create or replace function public._taam_rm_clash(p_uid uuid, p_round text, p_date date, p_time text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when p_uid is null or p_date is null
                or public._taam_purchase_exc_find(p_uid, p_round, 'time', 0) is not null then null else (
    select jsonb_build_object('pid', k.purchase_id, 'rest', k.restaurant_name,
                              'date', coalesce(k.reservation_date, tp.date), 'time', coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time))
      from public.tickets k
      left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
     where k.user_id = p_uid
       and coalesce(k.status, '') not in ('cancelled','canceled','expired')
       and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
       and k.ticket_product_id::text is distinct from p_round
       and public._taam_purchase_exc_find(p_uid, k.ticket_product_id::text, 'time', 0) is null
       and coalesce(public._taam_pu_visit_date(k.reservation_date), public._taam_pu_visit_date(tp.date)) = p_date
       and ( public.taam_time_slot(p_time) is null
             or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) is null
             or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) = public.taam_time_slot(p_time) )
     order by k.created_at limit 1) end
$$;
revoke all on function public._taam_rm_clash(uuid, text, date, text) from public, anon, authenticated;

-- 옮긴 뒤 같은 매장 재구매 제한 창 안에 다른 예약이 있나 — 재구매 가드 v2 와 같은 식(INSERT 에만 걸려 이동은 안 본다 · 기록만)
create or replace function public._taam_rm_repurchase(p_uid uuid, p_round text, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rest text; v_days int; v jsonb;
begin
  if p_uid is null or p_date is null then return null; end if;
  if public.taam_repurchase_released(p_round) then return null; end if;
  select tp.rest_id::text into v_rest from public.ticket_products tp where tp.id::text = p_round;
  if v_rest is null then return null; end if;
  select r.repurchase_day into v_days from public.restaurants r where r.id::text = v_rest;
  if coalesce(v_days, 0) = 0 then return null; end if;
  select jsonb_build_object('pid', k.purchase_id, 'date', to_char(d.vd, 'YYYY.MM.DD'), 'days', v_days)
    into v
    from public.tickets k
    left join public.ticket_products tp2 on tp2.id::text = k.ticket_product_id::text
    cross join lateral (select coalesce(public._taam_pu_visit_date(tp2.date), public._taam_pu_visit_date(k.reservation_date)) as vd) d
   where k.user_id = p_uid
     and k.ticket_product_id::text is distinct from p_round
     and coalesce(nullif(tp2.rest_id::text, ''), k.restaurant_id::text) = v_rest
     and coalesce(k.status, '') not in ('cancelled','canceled','expired')
     and coalesce(k.purchase_id, '') not like 'MAN-%' and coalesce(k.purchase_id, '') not like 'INVH-%' and coalesce(k.purchase_id, '') not like 'KSK-%'
     and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
     and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
     and d.vd is not null and abs(d.vd - p_date) > 0 and abs(d.vd - p_date) < v_days
   order by abs(d.vd - p_date) limit 1;
  return v;
end $$;
revoke all on function public._taam_rm_repurchase(uuid, text, date) from public, anon, authenticated;

-- ── 3. 적용 — 트리거·재동기화가 부른다. 기록 id 를 돌려준다 ─────────────────────
drop function if exists public._taam_round_move_apply(text, date, text, date, text, date[], text[], text, text);
create or replace function public._taam_round_move_apply(p_round text, p_od date, p_ot text, p_nd date, p_nt text,
                                                         p_fd date[], p_ft text[], p_via text, p_note text default null,
                                                         p_spec jsonb default null)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_tp    record;
  v_moved jsonb := '[]'::jsonb; v_kept jsonb := '[]'::jsonb; v_conf jsonb := '[]'::jsonb; v_err jsonb := '[]'::jsonb;
  v_side  jsonb := '{}'::jsonb; v_ksk jsonb := '[]'::jsonb; v_sub jsonb := '[]'::jsonb; v_exc int := 0; v_glog jsonb := '[]'::jsonb; v_man jsonb := '[]'::jsonb;
  r record; v_id bigint; v_res json; v_c jsonb; v_d date; v_t text; v_dch boolean; v_tch boolean;
  v_mark jsonb; v_ed date; v_et time; v_sd date; v_st text; v_ns text; v_cm jsonb; v_fdx date; v_ftx text;
  v_moved_ids uuid[] := '{}'; v_glog_ids uuid[] := '{}'; v_event_ids uuid[] := '{}';
  v_cmap jsonb := '{}'::jsonb;   -- 결제 링크·정산 청구 → 그 좌석이 옮겨 간 (옛 날짜·시간 → 새 날짜·시간) — 부제를 맞춘다
  v_live boolean; v_kbefore jsonb; v_kseats jsonb; v_kdid boolean;
begin
  select tp.id, tp.rest_id::text as rest_id, tp.rest_name, tp.date, tp.time into v_tp from public.ticket_products tp where tp.id::text = p_round;
  v_dch := p_nd is not null and p_od is distinct from p_nd;
  v_tch := p_nt is not null and p_ot is distinct from p_nt;
  -- 끝나지 않은 이동이 남긴 행이 있으면(짝 · 행 오류) 시간도 목표 시간으로 맞춘다 — 회차 시간이 그대로인 이동에서도
  v_live := p_spec is not null and (jsonb_array_length(coalesce(p_spec->'pairs', '[]'::jsonb)) > 0 or coalesce(p_spec->'err', '{}'::jsonb) <> '{}'::jsonb);

  -- 새 날짜가 오늘 이전 — 연도 실수 등(검토 C8). 옛 날짜(또는 끝나지 않은 이동이 남긴 날짜)가 오늘 이후였으면 아무것도 옮기지 않고 기록만
  --   (3차) 날짜가 그대로인 시간만 바꾸기도 — 연도 실수로 지난 날에 가 있는 회차의 시간을 고치면 처음 날짜의 예약이 지난 날로 끌려왔다
  if p_via <> 'resync' and p_nd < v_today
     and (p_od is null or p_od >= v_today or exists (select 1 from unnest(coalesce(p_fd, '{}'::date[])) d where d >= v_today)) then
    insert into public.ticket_round_moves(round_id, rest_name, old_date, old_time, new_date, new_time, moved_by, via, errors, note)
    values (p_round, v_tp.rest_name, to_char(p_od, 'YYYY.MM.DD'), p_ot, to_char(p_nd, 'YYYY.MM.DD'), p_nt, auth.uid(), p_via,
            jsonb_build_array(jsonb_build_object('code', 'NEW_DATE_PAST', 'msg', '회차 날짜가 오늘 이전이라 예약을 옮기지 않았습니다 — 날짜(연도)를 고치면 그때 같이 옮겨 갑니다')), p_note)
    returning id into v_id;
    perform set_config('taam.round_move_last', v_id::text, true);
    return v_id;
  end if;

  perform set_config('taam.round_move', p_round, true);
  v_mark := jsonb_build_object('at', now(), 'by', auth.uid(), 'via', p_via);

  for r in select * from public._taam_round_move_plan(p_round, p_nd, case when v_tch or p_via = 'resync' or v_live then p_nt end, p_fd, p_ft, p_spec) loop
    if r.action = 'keep' then
      v_kept := v_kept || jsonb_build_object('kind', r.kind, 'id', r.ref_id, 'pid', r.purchase_id, 'uid', r.user_id, 'owner', r.owner,
                                             'st', r.st, 'reason', r.reason, 'd', r.from_d, 't', r.from_t);
      continue;
    end if;
    if r.action <> 'move' then continue; end if;
    begin
      if r.kind = 'ticket' then
        perform 1 from public.tickets k where k.id = r.ref_id::uuid for update nowait;
        update public.tickets k
           set reservation_date = r.to_d,
               visit_time = r.to_t,
               extra_data = case when k.extra_data is null or jsonb_typeof(k.extra_data) = 'object' then
                              (coalesce(k.extra_data, '{}'::jsonb)
                                || jsonb_build_object('round_move', v_mark || jsonb_build_object('from', jsonb_build_object('d', r.from_d, 't', r.from_t),
                                                                                                 'to',   jsonb_build_object('d', r.to_d,   't', r.to_t))))
                              || case when r.to_t is distinct from r.from_t
                                           and jsonb_typeof(k.extra_data->'time_change') = 'object'
                                           and coalesce(k.extra_data->'time_change'->>'status', '') = 'pending'
                                      then jsonb_build_object('time_change', (k.extra_data->'time_change')
                                             || jsonb_build_object('status', 'superseded', 'superseded_by', 'round_move', 'superseded_at', now()))
                                      else '{}'::jsonb end
                            else k.extra_data end
         where k.id = r.ref_id::uuid;
        v_moved_ids := v_moved_ids || r.ref_id::uuid;
        if public._taam_pu_visit_date(r.to_d) is distinct from public._taam_pu_visit_date(r.from_d) then v_glog_ids := v_glog_ids || r.ref_id::uuid; end if;
        if r.owner in ('member', 'guest_link') and nullif(r.extra->>'charge_id', '') is not null then
          v_cmap := v_cmap || jsonb_build_object(r.extra->>'charge_id', jsonb_build_object('fd', r.from_d, 'ft', r.from_t, 'td', r.to_d, 'tt', r.to_t));
        end if;
      elsif r.kind = 'invite' then
        perform 1 from public.reservation_invites i where i.id = r.ref_id::uuid for update nowait;
        update public.reservation_invites i set visit_date = r.to_d, visit_time = r.to_t where i.id = r.ref_id::uuid;
      elsif r.kind = 'event' then
        v_ed := public._taam_pu_visit_date(r.to_d); v_et := nullif(r.to_t, '')::time;
        perform set_config('taam.ksk_sync_skip', '1', true);
        update public.kashikiri_events e set event_date = v_ed, event_time = v_et, updated_at = now() where e.id = r.ref_id::uuid;
        perform set_config('taam.ksk_sync_skip', '', true);
        v_event_ids := v_event_ids || r.ref_id::uuid;
      end if;
      v_moved := v_moved || jsonb_build_object('kind', r.kind, 'id', r.ref_id, 'pid', r.purchase_id, 'uid', r.user_id, 'owner', r.owner,
                                               'st', r.st, 'pax', r.pax, 'time_kept', r.time_kept,
                                               'from', jsonb_build_object('d', r.from_d, 't', r.from_t),
                                               'to',   jsonb_build_object('d', r.to_d,   't', r.to_t),
                                               'buyer', r.extra->>'buyer', 'host', r.extra->>'host', 'inv', r.extra->>'invite_id');
    exception
      when lock_not_available then
        perform set_config('taam.ksk_sync_skip', '', true);
        v_err := v_err || (jsonb_build_object('kind', r.kind, 'id', r.ref_id, 'pid', r.purchase_id, 'code', 'busy',
                                              'msg', '결제·취소가 진행 중이라 지금 옮기지 못했습니다 — 「다시 맞추기」')
                           || case when public._taam_hhmm(r.from_t) is not null and public._taam_hhmm(r.to_t) is distinct from public._taam_hhmm(r.from_t)
                                   then jsonb_build_object('ft', public._taam_hhmm(r.from_t)) else '{}'::jsonb end);   -- 시간을 따라가던 행(4차 RC3-2)
      when others then
        perform set_config('taam.ksk_sync_skip', '', true);
        v_err := v_err || (jsonb_build_object('kind', r.kind, 'id', r.ref_id, 'pid', r.purchase_id, 'code', 'error',
                                              'sqlstate', sqlstate, 'msg', left(sqlerrm, 200))
                           || case when public._taam_hhmm(r.from_t) is not null and public._taam_hhmm(r.to_t) is distinct from public._taam_hhmm(r.from_t)
                                   then jsonb_build_object('ft', public._taam_hhmm(r.from_t)) else '{}'::jsonb end);
    end;
  end loop;
  perform set_config('taam.round_move', '', true);

  -- 정산 좌석 — 정산 회차가 주인이다. 옮긴 회차 + (시간만 바뀌고 event_time 이 비어 회차 시간을 쓰는) 회차를 직접 맞춘다(검토 F9)
  --   다시 맞추기는 이 회차의 앞으로 올 정산 회차 전부 + 동기화가 실패했던 정산 회차를 다시 맞춘다(검토 RM-4 — 정산 회차는 옮겨졌는데
  --   좌석 동기화가 실패하면, 다음 「다시 맞추기」에서 정산 회차가 이미 같은 날이라 아무도 좌석을 안 맞추고 「이미 모두 옮겨져 있습니다」라고 했다)
  for r in select e.id, e.event_date from public.kashikiri_events e
            where e.ticket_product_id = p_round
              and (e.id = any(v_event_ids)
                   or (v_tch and e.event_time is null and e.event_date >= v_today)
                   or (p_via = 'resync' and (e.event_date >= v_today or coalesce(p_spec->'ksk', '[]'::jsonb) ? e.id::text))) loop
    begin
      select coalesce(jsonb_object_agg(t.id::text, jsonb_build_object('d', t.reservation_date, 't', t.visit_time)), '{}'::jsonb) into v_kbefore
        from public.tickets t where t.purchase_id like 'KSK-%' and t.extra_data->>'eventId' = r.id::text and coalesce(t.status, '') <> 'cancelled';
      v_res := public._taam_ksk_seat_sync(r.id);
      select coalesce(jsonb_agg(jsonb_build_object('id', t.id::text, 'pid', t.purchase_id, 'charge_id', t.extra_data->>'chargeId',
                                                   'from', v_kbefore->(t.id::text), 'to', jsonb_build_object('d', t.reservation_date, 't', t.visit_time))), '[]'::jsonb)
        into v_kseats
        from public.tickets t
       where t.purchase_id like 'KSK-%' and t.extra_data->>'eventId' = r.id::text and coalesce(t.status, '') <> 'cancelled'
         and v_kbefore ? t.id::text
         and ((v_kbefore->(t.id::text)->>'d') is distinct from t.reservation_date or (v_kbefore->(t.id::text)->>'t') is distinct from t.visit_time);
      v_kdid := jsonb_array_length(v_kseats) > 0
             or coalesce((v_res::jsonb->>'made')::int, 0) + coalesce((v_res::jsonb->>'cancelled')::int, 0) + coalesce((v_res::jsonb->>'resized')::int, 0) > 0
             or jsonb_array_length(coalesce(v_res::jsonb->'short', '[]'::jsonb)) > 0
             or coalesce(v_res::jsonb->>'ok', 'true') <> 'true';
      if p_via <> 'resync' or v_kdid then
        v_ksk := v_ksk || jsonb_build_object('event_id', r.id, 'sync', v_res::jsonb, 'seats', v_kseats);
      end if;
      for v_cm in select x from jsonb_array_elements(v_kseats) x loop
        if nullif(v_cm->>'charge_id', '') is not null then
          v_cmap := v_cmap || jsonb_build_object(v_cm->>'charge_id', jsonb_build_object('fd', v_cm->'from'->>'d', 'ft', v_cm->'from'->>'t',
                                                                                         'td', v_cm->'to'->>'d',   'tt', v_cm->'to'->>'t'));
        end if;
      end loop;
    exception when others then
      v_err := v_err || jsonb_build_object('kind', 'ksk_sync', 'id', r.id::text, 'code', 'error', 'sqlstate', sqlstate, 'msg', left(sqlerrm, 200));
    end;
  end loop;

  -- 결제 링크 청구의 부제 'YYYY.MM.DD HH:MM' — 이번에 실제로 옮긴 좌석의 청구만, 그 좌석이 옮겨 간 대로(검토 F8 · RM-5 — 다시 맞추기로 옮긴 좌석도)
  for r in select c.id, c.subtitle from public.kashikiri_charges c
            where v_cmap ? c.id::text and coalesce(c.subtitle, '') ~ '^\d{4}\.\d{2}\.\d{2}( \d{2}:\d{2})?$' loop
    v_cm := v_cmap->(r.id::text);
    v_sd := public._taam_pu_visit_date(split_part(r.subtitle, ' ', 1)); v_st := nullif(split_part(r.subtitle, ' ', 2), '');
    v_fdx := public._taam_pu_visit_date(v_cm->>'fd');
    v_ftx := coalesce(public._taam_hhmm(v_cm->>'ft'), p_ot);
    v_ns := to_char(case when v_fdx is not null and v_sd = v_fdx and public._taam_pu_visit_date(v_cm->>'td') is not null
                         then public._taam_pu_visit_date(v_cm->>'td') else v_sd end, 'YYYY.MM.DD')
            || coalesce(' ' || case when v_st is not null and v_st = v_ftx and public._taam_hhmm(v_cm->>'tt') is not null
                                    then public._taam_hhmm(v_cm->>'tt') else v_st end, '');
    if v_ns is distinct from r.subtitle then
      begin
        update public.kashikiri_charges set subtitle = v_ns where id = r.id;
        v_sub := v_sub || jsonb_build_object('charge_id', r.id, 'from', r.subtitle, 'to', v_ns);
      exception when others then
        v_err := v_err || jsonb_build_object('kind', 'charge', 'id', r.id::text, 'code', 'error', 'sqlstate', sqlstate, 'msg', left(sqlerrm, 200));
      end;
    end if;
  end loop;

  -- 비회원 알림톡 리마인드 기록 — 날짜가 실제로 바뀐 좌석만 지운다(새 날짜로 3일 전·하루 전이 다시 나가게 · 옛 기록은 side 에 남긴다 · 다시 맞추기도)
  if coalesce(array_length(v_glog_ids, 1), 0) > 0 then
    begin
      with del as (delete from public.guest_remind_log g where g.ticket_id = any(v_glog_ids) returning g.*)
      select coalesce(jsonb_agg(to_jsonb(del)), '[]'::jsonb) into v_glog from del;
    exception when others then
      v_err := v_err || jsonb_build_object('kind', 'guest_log', 'code', 'error', 'sqlstate', sqlstate, 'msg', left(sqlerrm, 200));
    end;
  end if;

  if v_dch and p_via <> 'resync' then
    -- 구매 규정 예외 — 기본 기한(옛 방문일 끝 = 다음 날 0시 KST)만 새 방문일 끝으로(끝나지 않은 이동이 남긴 옛 날짜의 기한도)
    begin
      update public.purchase_rule_exceptions x
         set expires_at = ((p_nd + 1)::timestamp at time zone 'Asia/Seoul')
       where x.ticket_product_id = p_round and x.revoked_at is null
         and x.expires_at in (select ((d + 1)::timestamp at time zone 'Asia/Seoul') from unnest(coalesce(p_fd, array[p_od])) d where d is not null);
      get diagnostics v_exc = row_count;
    exception when others then
      v_err := v_err || jsonb_build_object('kind', 'exception', 'code', 'error', 'sqlstate', sqlstate, 'msg', left(sqlerrm, 200));
    end;
    -- 캘린더 수동 기록 — 앱이 고른 경우만(taam.round_move_manual = '1') · 같은 매장 · 따라올 날짜(회차의 옛 날짜 + 끝나지 않은 이동이 남긴 날짜 —
    --   3차 NEW-5: 연도 실수를 고치는 이동은 처음 날짜의 기록을 옮겨야 한다) · 그 날 이 매장의 다른 회차가 없는 날짜만(미리보기 movable 과 같다)
    if coalesce(current_setting('taam.round_move_manual', true), '') = '1' and v_tp.rest_id is not null then
      begin
        with up as (update public.daegwan_manual m set ymd = p_nd
                     where m.venue_id = v_tp.rest_id
                       and m.ymd = any(coalesce(p_fd, array[p_od])) and m.ymd is distinct from p_nd
                       and not exists (select 1 from public.ticket_products o where o.rest_id::text = v_tp.rest_id and o.id::text <> p_round
                                        and public._taam_pu_visit_date(o.date) = m.ymd)
                     returning m.id, m.name, m.pax)
        select coalesce(jsonb_agg(to_jsonb(up)), '[]'::jsonb) into v_man from up;
      exception when others then
        v_err := v_err || jsonb_build_object('kind', 'manual', 'code', 'error', 'sqlstate', sqlstate, 'msg', left(sqlerrm, 200));
      end;
    end if;
  end if;

  -- 옮긴 회원 예약의 겹침 · 재구매 제한 창 — 막지 않고 기록
  for r in select e from jsonb_array_elements(v_moved) e where e->>'kind' = 'ticket' and e->>'owner' = 'member' loop
    v_d := public._taam_pu_visit_date(r.e->'to'->>'d');
    v_t := coalesce(nullif(btrim(coalesce(r.e->'to'->>'t', '')), ''), v_tp.time);
    v_c := public._taam_rm_clash((r.e->>'uid')::uuid, p_round, v_d, v_t);
    if v_c is not null then
      v_conf := v_conf || jsonb_build_object('kind', 'time', 'id', r.e->>'id', 'pid', r.e->>'pid', 'uid', r.e->>'uid', 'other', v_c);
    end if;
    if v_d is distinct from public._taam_pu_visit_date(r.e->'from'->>'d') then
      v_c := public._taam_rm_repurchase((r.e->>'uid')::uuid, p_round, v_d);
      if v_c is not null then
        v_conf := v_conf || jsonb_build_object('kind', 'repurchase', 'id', r.e->>'id', 'pid', r.e->>'pid', 'uid', r.e->>'uid', 'other', v_c);
      end if;
    end if;
  end loop;

  v_side := jsonb_build_object('exceptions', v_exc, 'subtitles', v_sub, 'guest_log', v_glog, 'ksk', v_ksk, 'manual', v_man);
  if p_via = 'resync' and jsonb_array_length(v_moved) = 0 and jsonb_array_length(v_err) = 0 and jsonb_array_length(v_ksk) = 0 then
    perform set_config('taam.round_move_last', '', true);
    return null;   -- 다시 맞추기에서 옮긴 것이 없으면 기록하지 않는다(남긴 행 목록만 반복되지 않게)
  end if;
  if jsonb_array_length(v_moved) = 0 and jsonb_array_length(v_kept) = 0 and jsonb_array_length(v_err) = 0
     and jsonb_array_length(v_ksk) = 0 and jsonb_array_length(v_sub) = 0 and v_exc = 0 and jsonb_array_length(v_man) = 0 then
    perform set_config('taam.round_move_last', '', true);
    return null;   -- 옮길 것도 남길 것도 없는 회차 — 기록하지 않는다
  end if;
  insert into public.ticket_round_moves(round_id, rest_name, old_date, old_time, new_date, new_time, moved_by, via,
                                        moved, kept, conflicts, errors, side, note)
  values (p_round, v_tp.rest_name, to_char(p_od, 'YYYY.MM.DD'), p_ot, to_char(p_nd, 'YYYY.MM.DD'), p_nt, auth.uid(), p_via,
          v_moved, v_kept, v_conf, v_err, v_side, p_note)
  returning id into v_id;
  perform set_config('taam.round_move_last', v_id::text, true);
  return v_id;
end $$;
revoke all on function public._taam_round_move_apply(text, date, text, date, text, date[], text[], text, text, jsonb) from public, anon, authenticated;

-- ── 4. 트리거 함수 ───────────────────────────────────────────────────────
-- ① AFTER UPDATE OF date, time — 실제로 바뀌었을 때만(WHEN 은 글자 비교 · 여기서 날짜·시각으로 다시 본다)
--   따라올 날짜 = 회차의 옛 날짜 + 끝나지 않은 이동이 남긴 날짜(검토 RM-1 — 연도 실수를 고치는 이동이 처음 날짜의 예약을 데려온다)
create or replace function public.taam_tp_round_move()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_od date; v_nd date; v_ot text; v_nt text; v_spec jsonb;
begin
  v_od := public._taam_pu_visit_date(old.date); v_nd := public._taam_pu_visit_date(new.date);
  v_ot := public._taam_hhmm(old.time);          v_nt := public._taam_hhmm(new.time);
  if v_nd is null and btrim(coalesce(new.date, '')) <> '' and v_od is not null then
    insert into public.ticket_round_moves(round_id, rest_name, old_date, old_time, new_date, new_time, moved_by, via, errors)
    values (new.id::text, new.rest_name, old.date, old.time, new.date, new.time, auth.uid(),
            coalesce(nullif(current_setting('taam.round_move_via', true), ''), 'trigger'),
            jsonb_build_array(jsonb_build_object('code', 'NEW_DATE_UNREADABLE', 'msg', '새 날짜를 읽을 수 없어 예약을 옮기지 않았습니다 — 날짜를 고치면 그때 같이 옮겨 갑니다')));
    return null;
  end if;
  if v_od is not distinct from v_nd and (v_nt is null or v_ot is not distinct from v_nt) then return null; end if;   -- 형식만 다른 저장
  -- 옛 날짜가 지난 회차는 옮기지 않는다(기록 · 방문 처리 안 된 행의 환불을 다시 열지 않게 — 결정 D3) — 계획이 past_round 로 남긴다
  v_spec := public._taam_round_spec_skip_od(public._taam_round_follow_spec(new.id::text, false), v_od);   -- 회차 날짜의 짝은 뺀다(3차 NEW-1)
  perform public._taam_round_move_apply(new.id::text, v_od, v_ot, coalesce(v_nd, v_od), v_nt,
                                        public._taam_round_follow_dates(v_od, v_spec), array[v_ot],
                                        coalesce(nullif(current_setting('taam.round_move_via', true), ''), 'trigger'),
                                        nullif(current_setting('taam.round_move_note', true), ''), v_spec);
  return null;
end $$;
revoke all on function public.taam_tp_round_move() from public, anon, authenticated;

-- ② 앱이 직접 보낸 저장의 날짜·시간 변경 — 옮길 예약이 있으면 거절(RPC 로만). 정의자 함수(RPC·승인)·SQL Editor 는 그대로
create or replace function public._taam_round_has_movable(p_round text, p_od date, p_ot text, p_nd date, p_nt text)
returns int language plpgsql stable security definer set search_path = public as $$
declare v int; v_spec jsonb;
begin
  if not coalesce(public.is_superadmin(), false) then return 0; end if;   -- 파트너(승인 대기 회차 — 좌석 없음)·회원은 세지 않는다
  v_spec := public._taam_round_spec_skip_od(public._taam_round_follow_spec(p_round, false), p_od);   -- 트리거와 같은 짝(3차 NEW-1)
  -- 'event' = 정산 회차가 옮겨 갈 때의 정산 좌석뿐(계획이 정산 회차의 판정을 따른다 — 검토 RM-6)
  select count(*) into v from public._taam_round_move_plan(p_round, p_nd, p_nt, public._taam_round_follow_dates(p_od, v_spec), array[p_ot], v_spec) p
   where p.action in ('move', 'event') ;
  return v;
end $$;
revoke all on function public._taam_round_has_movable(text, date, text, date, text) from public, anon;
grant execute on function public._taam_round_has_movable(text, date, text, date, text) to authenticated;

create or replace function public.taam_guard_tp_round_lock()
returns trigger language plpgsql set search_path = public as $$
declare v_od date; v_nd date; v_ot text; v_nt text; v_n int;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  v_od := public._taam_pu_visit_date(old.date); v_nd := public._taam_pu_visit_date(new.date);
  v_ot := public._taam_hhmm(old.time);          v_nt := public._taam_hhmm(new.time);
  if v_od is not distinct from v_nd and (v_nt is null or v_ot is not distinct from v_nt) then return new; end if;
  v_n := public._taam_round_has_movable(new.id::text, v_od, v_ot, coalesce(v_nd, v_od), v_nt);
  if coalesce(v_n, 0) > 0 then
    raise exception 'ROUND_RESCHEDULE_REQUIRED: 이 회차에는 예약 %건이 있어 날짜·시간을 이 저장으로 바꿀 수 없습니다 — 화면을 새로고침한 뒤 수정 화면에서 다시 바꿔 주세요(예약을 같이 옮깁니다). 저장된 날짜 %, 보낸 날짜 %',
      v_n, coalesce(old.date, '-') || coalesce(' ' || old.time, ''), coalesce(new.date, '-') || coalesce(' ' || new.time, '')
      using errcode = 'P0001';
  end if;
  return new;
end $$;

-- ④ 새 좌석 행·초대의 날짜는 회차 날짜로(시간은 비어 있을 때만 · 회원 홀드 PAYH- 는 회차 시간) — 정산 좌석(KSK-)은 정산 회차가 주인이라 뺀다
--   회차 행을 FOR NO KEY UPDATE 로 읽는다(검토 RM-3) — 날짜를 바꾸는 중인 트랜잭션(수정 승인 · SQL Editor)이 끝날 때까지 기다렸다
--   **바뀐 날짜**로 고정한다. 종전엔 잠그지 않고 읽어 옛 날짜로 고정됐고, 그 행은 이동 기록 어디에도 없었다(앞서 끝난 INSERT 는 반대로
--   이동이 회차 행을 잠그려다 기다리므로 이동 계획이 본다).
--   잠금 순서: 이 잠금은 같은 INSERT 의 AFTER 트리거(touch_ticket_product_on_seat_change — 회차 행 UPDATE)가 어차피 잡는 잠금이다.
--   그래서 트리거 이름을 중복·시간대 가드(trg_taam_guard_ticket_unique — 회원 잠금 tkuniq_)보다 **뒤**로 둔다(zdate) — 앞에 두면
--   「정원 잠금 → 회차 행 → 회원 잠금」이 되어, 회원 잠금을 먼저 잡고 회차 행을 기다리는 그 회원의 다른 갱신(시간 변경 등)과 엇갈린다.
--   지금 순서: 정원 잠금(tkcap_) → 회원 잠금(tkuniq_) → 회차 행 — 종전 INSERT 와 같다. 회차 이동 쪽은 회원 잠금을 기다리지 않는다(가드 덩어리의 try-lock).
create or replace function public.taam_guard_ticket_date_pin()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_d date; v_t text; v_traw text; v_od0 date; v_ot0 text; v_c jsonb;
begin
  if nullif(btrim(coalesce(new.ticket_product_id::text, '')), '') is null then return new; end if;
  if coalesce(new.purchase_id, '') like 'KSK-%' then return new; end if;
  select public._taam_pu_visit_date(tp.date), public._taam_hhmm(tp.time), tp.time into v_d, v_t, v_traw
    from public.ticket_products tp where tp.id::text = new.ticket_product_id::text for no key update;
  if v_d is null then return new; end if;
  v_od0 := public._taam_pu_visit_date(new.reservation_date); v_ot0 := public._taam_hhmm(new.visit_time);   -- 앞 가드(중복·시간대)가 본 값
  if v_od0 is distinct from v_d or new.reservation_date is distinct from to_char(v_d, 'YYYY.MM.DD') then
    new.reservation_date := to_char(v_d, 'YYYY.MM.DD');
  end if;
  if btrim(coalesce(new.visit_time, '')) = '' and v_t is not null then new.visit_time := v_t;
  -- 회원 홀드의 시간은 회차 시간(결제 사실 칸 가드 payfacts_ins 와 같은 규칙 — 그 가드는 잠그기 전에 읽어 이동 중이면 옛 시간을 적는다)
  elsif coalesce(new.purchase_id, '') like 'PAYH-%' and btrim(coalesce(v_traw, '')) <> '' then new.visit_time := v_traw;
  end if;
  -- 3차 NEW-6 — 날짜·시간을 바꿔 고정했으면 같은 날 같은 시간대 겹침을 **고정한 값으로** 다시 본다.
  --   중복·시간대 가드(trg_taam_guard_ticket_unique)는 이 트리거보다 먼저 돌아 낡은 화면이 보낸 옛 날짜(또는 이동 중 잠그지 않고 읽은 옛 회차 날짜)로
  --   검사했다 — 새 날짜에서 같은 회원의 다른 예약과 겹쳐도 기록 없이 들어갔다. 가드와 같은 거름(빈 회원 · 취소 · 운영 행 · 남의 user_id 는
  --   소유권 가드 몫)과 같은 식(_taam_rm_clash — 같은 회차 행 제외 · 구매 규정 예외(시간대) 존중). 회원 잠금(tkuniq_)은 가드가 이미 잡았다.
  if (v_od0 is distinct from v_d or v_ot0 is distinct from public._taam_hhmm(new.visit_time))
     and new.user_id is not null
     and coalesce(new.status, '') not in ('cancelled', 'canceled', 'expired')
     and not public._taam_ticket_is_ops(new.purchase_id, new.extra_data)
     and not (auth.uid() is not null and new.user_id is distinct from auth.uid() and not public._taam_uid_is_super()) then
    v_c := public._taam_rm_clash(new.user_id, new.ticket_product_id::text, v_d, coalesce(nullif(btrim(coalesce(new.visit_time, '')), ''), v_traw));
    if v_c is not null then
      raise exception 'TIME_CONFLICT: 같은 날 같은 시간대에 이미 예약이 있습니다 (% · % %)',
        coalesce(v_c->>'rest', '다른 매장'), coalesce(v_c->>'date', v_d::text), coalesce(v_c->>'time', '')
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_ticket_date_pin() from public, anon, authenticated;

create or replace function public.taam_guard_invite_date_pin()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_d date; v_t text;
begin
  if nullif(btrim(coalesce(new.ticket_product_id::text, '')), '') is null then return new; end if;
  select public._taam_pu_visit_date(tp.date), public._taam_hhmm(tp.time) into v_d, v_t
    from public.ticket_products tp where tp.id::text = new.ticket_product_id::text for no key update;
  if v_d is null then return new; end if;
  new.visit_date := to_char(v_d, 'YYYY.MM.DD');
  if btrim(coalesce(new.visit_time, '')) = '' and v_t is not null then new.visit_time := v_t; end if;
  return new;
end $$;
revoke all on function public.taam_guard_invite_date_pin() from public, anon, authenticated;

-- ── 5. RPC ───────────────────────────────────────────────────────────────
-- 미리보기 — 바꾸기 전에 무엇이 옮겨 가는지(읽기만)
create or replace function public.taam_round_move_preview(p_round text, p_date text, p_time text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_tp record; v_od date; v_ot text; v_nd date; v_nt text; v_rows jsonb := '[]'::jsonb; r record; v_c jsonb; v_rp jsonb;
  v_conf jsonb := '[]'::jsonb; v_gain int := 0; v_loss int := 0; v_warn jsonb := '[]'::jsonb; v_man jsonb; v_names jsonb;
  v_exc int; v_pkg text; v_dch boolean; v_tch boolean; v_spec jsonb; v_fd date[]; v_live boolean; v_past int := 0; v_rd date;
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select tp.id, tp.rest_id::text as rest_id, tp.rest_name, tp.date, tp.time, tp.status, tp.deadline_date, tp.sale_open_at, tp.m_open_date
    into v_tp from public.ticket_products tp where tp.id::text = p_round;
  if not found then return jsonb_build_object('ok', false, 'error', 'ROUND_NOT_FOUND'); end if;
  v_od := public._taam_pu_visit_date(v_tp.date); v_ot := public._taam_hhmm(v_tp.time);
  v_nd := public._taam_pu_visit_date(p_date);    v_nt := public._taam_hhmm(p_time);
  if v_nd is null or btrim(coalesce(p_date, '')) !~ '^\d{4}\.\d{1,2}\.\d{1,2}$' then
    return jsonb_build_object('ok', false, 'error', 'BAD_DATE', 'cur', jsonb_build_object('date', v_tp.date, 'time', v_tp.time));
  end if;
  v_dch := v_od is distinct from v_nd; v_tch := v_nt is not null and v_ot is distinct from v_nt;
  -- 트리거와 같은 따라올 날짜(회차의 옛 날짜 + 끝나지 않은 이동이 남긴 날짜 — 검토 RM-1)
  v_spec := public._taam_round_spec_skip_od(public._taam_round_follow_spec(p_round, false), v_od);   -- 트리거와 같은 짝(3차 NEW-1)
  v_fd := public._taam_round_follow_dates(v_od, v_spec);
  v_live := jsonb_array_length(coalesce(v_spec->'pairs', '[]'::jsonb)) > 0 or coalesce(v_spec->'err', '{}'::jsonb) <> '{}'::jsonb;
  for r in select p.*, pr.display_name as name, pr.phone as phone
             from public._taam_round_move_plan(p_round, v_nd, case when v_tch or v_live then coalesce(v_nt, v_ot) end, v_fd, array[v_ot], v_spec) p
             left join public.profiles pr on pr.id = p.user_id
            where p.action <> 'same' loop
    v_rows := v_rows || jsonb_build_object('kind', r.kind, 'id', r.ref_id, 'pid', r.purchase_id, 'uid', r.user_id, 'owner', r.owner,
                                           'st', r.st, 'pax', r.pax, 'action', r.action, 'reason', r.reason, 'time_kept', r.time_kept,
                                           'from', jsonb_build_object('d', r.from_d, 't', r.from_t), 'to', jsonb_build_object('d', r.to_d, 't', r.to_t),
                                           'name', coalesce(nullif(r.name, ''), nullif(r.extra->>'buyer', ''), ''),
                                           'buyer', r.extra->>'buyer', 'price', (r.extra->>'price'));
    if r.action = 'keep' and r.reason = 'past_round' then v_past := v_past + 1; end if;
    if r.action = 'move' and r.kind = 'ticket' and r.owner = 'member' then
      v_c := public._taam_rm_clash(r.user_id, p_round, public._taam_pu_visit_date(r.to_d), coalesce(nullif(btrim(coalesce(r.to_t, '')), ''), v_nt, v_ot));
      if v_c is not null then
        v_conf := v_conf || jsonb_build_object('kind', 'time', 'id', r.ref_id, 'pid', r.purchase_id, 'name', coalesce(r.name, ''), 'other', v_c);
      end if;
      v_rd := coalesce(public._taam_pu_visit_date(r.from_d), v_od);   -- 그 행의 지금 날짜(끝나지 않은 이동이 남긴 행은 회차와 다르다)
      if public._taam_pu_visit_date(r.to_d) is distinct from v_rd then
        v_rp := public._taam_rm_repurchase(r.user_id, p_round, v_nd);
        if v_rp is not null then
          v_conf := v_conf || jsonb_build_object('kind', 'repurchase', 'id', r.ref_id, 'pid', r.purchase_id, 'name', coalesce(r.name, ''), 'other', v_rp);
        end if;
        -- 환불 규정(방문 D-31 이상이면 대행비 빼고 환불 · 그 뒤 0)이 바뀌는 예약
        if coalesce((r.extra->>'price')::int, 0) > 0 and v_rd is not null then
          if (v_rd - v_today) < 31 and (v_nd - v_today) >= 31 then v_gain := v_gain + 1; end if;
          if (v_rd - v_today) >= 31 and (v_nd - v_today) < 31 then v_loss := v_loss + 1; end if;
        end if;
      end if;
    end if;
  end loop;
  -- 날짜가 그대로인 시간만 바꾸기도 — 연도 실수로 지난 날에 가 있는 회차는 앞날의 예약을 옮기지 않는다(3차 · 적용과 같은 조건)
  if v_nd < v_today and (v_dch or exists (select 1 from unnest(v_fd) d where d >= v_today)) then v_warn := v_warn || to_jsonb('new_date_past'::text); end if;
  -- 옛 날짜가 지나 남기는 행이 있을 때만(끝나지 않은 이동이 남긴 앞날의 행은 옮겨 간다 — 검토 RM-1)
  if v_past > 0 then v_warn := v_warn || to_jsonb('old_date_past'::text); end if;
  if v_dch and public._taam_pu_visit_date(v_tp.deadline_date) is not null and public._taam_pu_visit_date(v_tp.deadline_date) > v_nd then
    v_warn := v_warn || to_jsonb('deadline_after_visit'::text);
  end if;
  if v_dch and public._taam_pu_visit_date(v_tp.m_open_date) is not null and public._taam_pu_visit_date(v_tp.m_open_date) > v_nd then
    v_warn := v_warn || to_jsonb('open_after_visit'::text);
  end if;
  if v_dch and public._taam_pu_visit_date(left(coalesce(v_tp.sale_open_at, ''), 10)) is not null
     and public._taam_pu_visit_date(left(v_tp.sale_open_at, 10)) > v_nd then
    v_warn := v_warn || to_jsonb('sale_open_after_visit'::text);
  end if;
  select pr.package_id into v_pkg from public.ticket_package_rounds pr where pr.ticket_product_id = p_round limit 1;
  if v_pkg is not null then v_warn := v_warn || to_jsonb('package'::text); end if;
  select count(*) into v_exc from public.purchase_rule_exceptions x
   where x.ticket_product_id = p_round and x.revoked_at is null and v_dch
     and x.expires_at in (select ((d + 1)::timestamp at time zone 'Asia/Seoul') from unnest(v_fd) d where d is not null);
  -- 캘린더 수동 기록 후보 — 같은 매장 · 따라올 날짜(회차의 옛 날짜 + 끝나지 않은 이동이 남긴 날짜 — 3차 NEW-5) · 날짜마다
  --   그날 이 매장의 다른 회차가 없을 때만 옮길 수 있다(movable · 적용과 같은 조건)
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'pax', m.pax, 'ttype', m.ttype,
                                               'ymd', to_char(m.ymd, 'YYYY.MM.DD'),
                                               'movable', not exists (select 1 from public.ticket_products o where o.rest_id::text = v_tp.rest_id and o.id::text <> p_round
                                                                       and public._taam_pu_visit_date(o.date) = m.ymd))
                            order by m.ymd, m.created_at), '[]'::jsonb)
    into v_man from public.daegwan_manual m
   where v_dch and m.venue_id = v_tp.rest_id and m.ymd = any(v_fd) and m.ymd is distinct from v_nd;
  return jsonb_build_object('ok', true, 'round', p_round, 'rest', v_tp.rest_name,
    'cur', jsonb_build_object('date', v_tp.date, 'time', v_tp.time),
    'new', jsonb_build_object('date', to_char(v_nd, 'YYYY.MM.DD'), 'time', coalesce(v_nt, v_tp.time)),
    'date_changed', v_dch, 'time_changed', v_tch,
    'rows', v_rows, 'conflicts', v_conf, 'refund', jsonb_build_object('gain', v_gain, 'loss', v_loss),
    'warnings', v_warn, 'exceptions', v_exc, 'manual', v_man,
    -- 응답을 잃은 「옮기기」를 앱이 다시 확인할 때 쓰는 기준 — 이 미리보기 뒤에 생긴 기록만 이번 이동이다(검토 앱 RM-4)
    'last_move_id', coalesce((select max(m.id) from public.ticket_round_moves m where m.round_id = p_round), 0),
    -- 서버 시각 — 앱이 기기 시계 차이를 맞춰 「이 수정 화면을 연 뒤의 이동 기록」만 고른다(3차 NEW-7)
    'now', now(),
    'manual_movable', exists (select 1 from jsonb_array_elements(v_man) x where (x->>'movable')::boolean));
end $$;
revoke all on function public.taam_round_move_preview(text, text, text) from public, anon;
grant execute on function public.taam_round_move_preview(text, text, text) to authenticated;

-- 날짜·시간 바꾸기 — 앱의 유일한 길. 잠금 순서: 정원 잠금(tkcap_) → 그 회차의 좌석 행 → 회차 행 (검토 C3 — 결제 확정이 티켓 → 회차 순이라 엇갈리지 않는다)
create or replace function public.taam_round_reschedule(p_round text, p_date text, p_time text,
                                                        p_expect_date text, p_expect_time text, p_opts jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_tp record; v_nd date; v_nt text; v_id bigint; v_log jsonb;
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  v_nd := public._taam_pu_visit_date(p_date); v_nt := public._taam_hhmm(p_time);
  if v_nd is null or btrim(coalesce(p_date, '')) !~ '^\d{4}\.\d{1,2}\.\d{1,2}$' then
    return jsonb_build_object('ok', false, 'error', 'BAD_DATE');
  end if;
  if btrim(coalesce(p_time, '')) <> '' and v_nt is null then return jsonb_build_object('ok', false, 'error', 'BAD_TIME'); end if;
  if v_nd < v_today then return jsonb_build_object('ok', false, 'error', 'NEW_DATE_PAST'); end if;
  perform pg_advisory_xact_lock(hashtext('tkcap_' || p_round));
  -- 초대 줄은 잠그지 않는다 — 초대 확정(초대 줄 → 좌석 행 → 정원 잠금)과 엇갈려 교착이 날 수 있다. 트리거가 NOWAIT 로 보고 잠겨 있으면 「다시 맞추기」 대상으로 남긴다
  perform 1 from public.tickets k where k.ticket_product_id::text = p_round
     and lower(coalesce(k.status, '')) not in ('cancelled', 'canceled', 'expired', 'failed', 'refunded') for update;
  select tp.id, tp.date, tp.time, tp.rest_name into v_tp from public.ticket_products tp where tp.id::text = p_round for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'ROUND_NOT_FOUND'); end if;
  if public._taam_pu_visit_date(v_tp.date) is distinct from public._taam_pu_visit_date(p_expect_date)
     or public._taam_hhmm(v_tp.time) is distinct from public._taam_hhmm(p_expect_time) then
    return jsonb_build_object('ok', false, 'error', 'STALE_ROUND', 'cur', jsonb_build_object('date', v_tp.date, 'time', v_tp.time));
  end if;
  if public._taam_pu_visit_date(v_tp.date) is not distinct from v_nd and (v_nt is null or public._taam_hhmm(v_tp.time) is not distinct from v_nt) then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;
  perform set_config('taam.round_move_via', 'reschedule', true);
  perform set_config('taam.round_move_note', left(coalesce(p_opts->>'note', ''), 300), true);
  perform set_config('taam.round_move_manual', case when coalesce(p_opts->>'move_manual', '') = 'true' then '1' else '' end, true);
  perform set_config('taam.round_move_last', '', true);
  update public.ticket_products tp
     set date = to_char(v_nd, 'YYYY.MM.DD'), time = coalesce(v_nt, public._taam_hhmm(tp.time), tp.time), updated_at = now()
   where tp.id::text = p_round;
  perform set_config('taam.round_move_via', '', true);
  perform set_config('taam.round_move_note', '', true);
  perform set_config('taam.round_move_manual', '', true);
  v_id := nullif(current_setting('taam.round_move_last', true), '')::bigint;
  if v_id is not null then select to_jsonb(m) into v_log from public.ticket_round_moves m where m.id = v_id; end if;
  return jsonb_build_object('ok', true, 'changed', true, 'move_id', v_id, 'move', v_log,
                            'round', jsonb_build_object('date', to_char(v_nd, 'YYYY.MM.DD'), 'time', coalesce(v_nt, v_tp.time)));
end $$;
revoke all on function public.taam_round_reschedule(text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.taam_round_reschedule(text, text, text, text, text, jsonb) to authenticated;

-- 다시 맞추기 — 기록된 옛 날짜에 남아 있는 행(잠김·오류·이동 중 들어온 행)을 지금 회차 날짜로
--   시간은 그 행을 남긴 기록의 옛 시간 그대로일 때만(행 오류 · (옛 날짜, 옛 시간) 짝) 지금 회차 시간으로 — 예전 시간 전부를 따라가면
--   따로 바꾼 시간이 되돌아갔다(검토 RM-2). 정산 좌석은 이 회차의 앞으로 올 정산 회차 전부를 다시 맞춘다(검토 RM-4)
create or replace function public.taam_round_move_resync(p_round text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_tp record; v_fd date[]; v_id bigint; v_log jsonb; v_nd date; v_nt text; v_spec jsonb;
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('tkcap_' || p_round));
  perform 1 from public.tickets k where k.ticket_product_id::text = p_round
     and lower(coalesce(k.status, '')) not in ('cancelled', 'canceled', 'expired', 'failed', 'refunded') for update;
  select tp.id, tp.date, tp.time into v_tp from public.ticket_products tp where tp.id::text = p_round for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'ROUND_NOT_FOUND'); end if;
  v_nd := public._taam_pu_visit_date(v_tp.date); v_nt := public._taam_hhmm(v_tp.time);
  if v_nd is null then return jsonb_build_object('ok', false, 'error', 'ROUND_DATE_UNREADABLE'); end if;
  if v_nd < (now() at time zone 'Asia/Seoul')::date then return jsonb_build_object('ok', false, 'error', 'ROUND_PAST'); end if;
  if not exists (select 1 from public.ticket_round_moves m where m.round_id = p_round) then
    return jsonb_build_object('ok', true, 'move_id', null, 'nothing', true);
  end if;
  -- 날짜는 기록 전부 · 짝은 끝나지 않은(open) 기록만(3차 NEW-2) · 회차 날짜의 짝은 뺀다(4차 RC3-2 — 회차가 그 날짜에 있는 동안
  --   거기서 따로 바꾼 시간을 NEW_DATE_* 짝(rpairs)이 덮지 않게 · 그 날짜에 정말 못 옮긴 행은 행 오류가 id·그때 시간으로 따라간다)
  v_spec := public._taam_round_spec_skip_od(public._taam_round_follow_spec(p_round, true), v_nd);
  v_fd := coalesce(array(select d::date from jsonb_array_elements_text(v_spec->'dates') d), '{}'::date[]);
  v_id := public._taam_round_move_apply(p_round, null, null, v_nd, v_nt, v_fd, '{}'::text[], 'resync', null, v_spec);
  if v_id is not null then select to_jsonb(m) into v_log from public.ticket_round_moves m where m.id = v_id; end if;
  return jsonb_build_object('ok', true, 'move_id', v_id, 'move', v_log);
end $$;
revoke all on function public.taam_round_move_resync(text) from public, anon;
grant execute on function public.taam_round_move_resync(text) to authenticated;

-- 기록 읽기
create or replace function public.taam_round_moves(p_round text, p_after_id bigint default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(m) order by m.id) from public.ticket_round_moves m
                    where m.round_id = p_round and m.id > coalesce(p_after_id, 0)), '[]'::jsonb);
end $$;
revoke all on function public.taam_round_moves(text, bigint) from public, anon;
grant execute on function public.taam_round_moves(text, bigint) to authenticated;

-- 회원 알림 — 옮긴 회원 예약의 주인 · 옮긴 「보냄」 초대의 받는 회원 (한 이동에 한 번 · 회원마다 한 줄)
create or replace function public.taam_round_move_notify(p_move_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_m public.ticket_round_moves%rowtype; r record; v_sent jsonb := '[]'::jsonb; v_manual jsonb := '[]'::jsonb; v_skip jsonb := '[]'::jsonb;
  v_i18n jsonb; v_lang text; v_rest text; v_from text; v_to text; v_url text; v_push jsonb; v_rest_id text; v_seen uuid[] := '{}';
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_m from public.ticket_round_moves where id = p_move_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'MOVE_NOT_FOUND'); end if;
  if v_m.notified_at is not null then return jsonb_build_object('ok', true, 'already', true, 'result', v_m.notify_result); end if;
  select tp.rest_id::text into v_rest_id from public.ticket_products tp where tp.id::text = v_m.round_id;
  for r in
    select e, e->>'kind' as kind, e->>'owner' as owner, e->>'st' as st, nullif(e->>'uid', '')::uuid as uid, e->>'id' as id, e->>'pid' as pid
      from jsonb_array_elements(v_m.moved) e
     where e->>'kind' in ('ticket', 'invite')
     order by case when e->>'kind' = 'ticket' then 0 else 1 end
  loop
    if r.kind = 'ticket' and r.owner in ('manual', 'guest_link') then
      v_manual := v_manual || jsonb_build_object('id', r.id, 'pid', r.pid, 'owner', r.owner, 'buyer', r.e->>'buyer',
                                                 'phone', (select k.buyer_phone from public.tickets k where k.id::text = r.id));
      continue;
    end if;
    if r.kind = 'ticket' and (r.owner <> 'member' or r.st not in ('active', 'pending_confirm')) then
      v_skip := v_skip || jsonb_build_object('id', r.id, 'pid', r.pid, 'why', r.owner || '/' || r.st); continue;
    end if;
    -- 결제된 초대는 좌석 행(INV-)으로 알린다 — 단 그 좌석이 이 이동에서 같이 옮겨지지 않았으면(잠겨 남음 · 다시 맞추기로 따로) 초대로 알린다(검토 RM-5)
    if r.kind = 'invite' and r.st = 'paid'
       and exists (select 1 from jsonb_array_elements(v_m.moved) s
                    where s->>'kind' = 'ticket' and (s->>'inv' = r.id or (coalesce(s->>'pid', '') like 'INV-' || left(r.id, 8) || '%' and s->>'uid' = r.uid::text))) then continue; end if;
    if r.kind = 'invite' and r.st not in ('sent', 'paid') then continue; end if;
    if r.uid is null or r.uid = any(v_seen) then continue; end if;
    -- 3차 NEW-3 — 같은 회차의 다른 기록에서 이 회원에게 **가장 최근에** 알린 새 날짜·시간이 이번과 같으면 다시 보내지 않는다
    --   (결제된 초대가 이동 때 잠겨 좌석(INV-)만 옮겨 알린 뒤, 다시 맞추기가 초대를 옮기면 같은 회원에게 같은 알림이 두 번 갔다 · 반대 순서도)
    --   가장 최근 것만 본다 — D2 → D3 → D2 로 되돌린 이동은 D3 을 알린 뒤라 다시 알려야 한다
    if (select public._taam_pu_visit_date(mv->'to'->>'d') is not distinct from public._taam_pu_visit_date(r.e->'to'->>'d')
               and public._taam_hhmm(mv->'to'->>'t') is not distinct from public._taam_hhmm(r.e->'to'->>'t')
          from public.ticket_round_moves m2
         cross join lateral jsonb_array_elements(coalesce(m2.notify_result->'sent', '[]'::jsonb)) s
         cross join lateral jsonb_array_elements(coalesce(m2.moved, '[]'::jsonb)) mv
         where m2.round_id = v_m.round_id and m2.id <> v_m.id and m2.notified_at is not null
           and s->>'uid' = r.uid::text and mv->>'id' = s->>'id'
         order by m2.notified_at desc, m2.id desc limit 1) is true then
      v_skip := v_skip || jsonb_build_object('id', r.id, 'pid', r.pid, 'uid', r.uid, 'why', 'already_notified');
      continue;
    end if;
    v_seen := v_seen || r.uid;
    v_i18n := '{}'::jsonb;
    foreach v_lang in array array['ko', 'en', 'ja'] loop
      v_rest := coalesce(public._taam_rest_name_l10n(v_m.round_id, v_lang), v_m.rest_name, '');
      v_from := public._taam_rm_dt(public._taam_pu_visit_date(r.e->'from'->>'d'), public._taam_hhmm(r.e->'from'->>'t'), v_lang);
      v_to   := public._taam_rm_dt(public._taam_pu_visit_date(r.e->'to'->>'d'),   public._taam_hhmm(r.e->'to'->>'t'),   v_lang);
      v_i18n := v_i18n || jsonb_build_object(v_lang, case v_lang
        when 'en' then jsonb_build_object('title', 'Your reservation has been rescheduled',
                         'body', v_rest || E'\n' || v_from || ' → ' || v_to || E'\n' || 'Your booking stays confirmed on the new date.')
        when 'ja' then jsonb_build_object('title', 'ご予約の日程が変更されました',
                         'body', v_rest || E'\n' || v_from || ' → ' || v_to || E'\n' || 'ご予約は新しい日程でそのまま有効です。')
        else jsonb_build_object('title', '예약 일정이 변경되었습니다',
                         'body', v_rest || E'\n' || v_from || ' → ' || v_to || E'\n' || '예약은 새 일정으로 그대로 유지됩니다.') end);
    end loop;
    v_url := case when r.kind = 'invite' and r.st = 'sent' then '/?ri_pay=' || r.id else '/?open_ticket_hist=1' end;
    begin
      insert into public.notifications (user_id, type, kind, title, body, message, url, payload)
      values (r.uid, 'ticket_date_changed', 'ticket_date_changed', v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', v_i18n->'ko'->>'body', v_url,
              jsonb_build_object('move_id', v_m.id, 'round_id', v_m.round_id, 'rest_id', v_rest_id,
                                 case when r.kind = 'invite' then 'invite_id' else 'ticket_id' end, r.id,
                                 'from', r.e->'from', 'to', r.e->'to', 'i18n', v_i18n));
      v_push := public._taam_member_push(r.uid, v_i18n->'ko'->>'title', v_i18n->'ko'->>'body', v_url,
                                         'taam-rmove-' || v_m.id || '-' || left(r.uid::text, 8), 'ticket_time_changed', v_i18n);
      v_sent := v_sent || jsonb_build_object('uid', r.uid, 'kind', r.kind, 'id', r.id, 'to', r.e->'to', 'push', v_push);
    exception when others then
      v_skip := v_skip || jsonb_build_object('id', r.id, 'pid', r.pid, 'why', 'error', 'msg', left(sqlerrm, 160));
    end;
  end loop;
  update public.ticket_round_moves set notified_at = now(),
         notify_result = jsonb_build_object('sent', v_sent, 'manual_contact', v_manual, 'skipped', v_skip)
   where id = p_move_id;
  return jsonb_build_object('ok', true, 'sent', v_sent, 'manual_contact', v_manual, 'skipped', v_skip);
end $$;
revoke all on function public.taam_round_move_notify(bigint) from public, anon;
grant execute on function public.taam_round_move_notify(bigint) to authenticated;

-- ── 6. 중복·시간대 가드에 「회차 이동」 통과 덩어리 (md5 가드) · 트리거는 가드가 준비됐을 때만 ─────────────
--   이동이 회원 잠금(tkuniq_)을 **기다리지 않는다**(검토 RM-3) — 그 회원의 다른 구매가 잠금을 쥐고 회차 행을 기다리면 교착이었다.
--   잡지 못하면 lock_not_available 로 올려 적용이 그 행을 「결제·취소 진행 중(busy)」으로 남긴다(다시 맞추기 대상).
do $mig$
declare v_src text; v_def text; v_anchor text; v_block text; v_n int; v_old_lock text; v_new_lock text;
begin
  v_old_lock := E'     and coalesce(old.status, \'\') = coalesce(new.status, \'\') then\n'
             || E'    perform pg_advisory_xact_lock(hashtext(\'tkuniq_\' || new.user_id::text));\n';
  v_new_lock := E'     and coalesce(old.status, \'\') = coalesce(new.status, \'\') then\n'
             || E'    if not pg_try_advisory_xact_lock(hashtext(\'tkuniq_\' || new.user_id::text)) then   -- 그 회원의 다른 구매가 진행 중 — 기다리지 않고 busy\n'
             || E'      raise exception \'ROUND_MOVE_MEMBER_BUSY\' using errcode = \'55P03\';\n'
             || E'    end if;\n';
  select p.prosrc into v_src from pg_proc p where p.oid = to_regprocedure('public.taam_guard_purchase_unique()');
  if v_src is null then raise warning '[round move] taam_guard_purchase_unique() 가 없습니다 — 트리거를 만들지 않음'; return; end if;
  -- 1차 판(기다리는 잠금)이 이미 들어간 DB — 그 줄만 바꾼다(라이브에는 1차 판이 올라간 적이 없다)
  if v_src like '%ROUND_MOVE_20261116%' and v_src not like '%ROUND_MOVE_MEMBER_BUSY%' then
    v_def := pg_get_functiondef('public.taam_guard_purchase_unique()'::regprocedure);
    v_n := (length(v_def) - length(replace(v_def, v_old_lock, ''))) / length(v_old_lock);
    if v_n <> 1 then raise warning '[round move] 1차 판 가드 덩어리를 정확히 한 곳 찾지 못했습니다(%) — 손대지 않음', v_n; return; end if;
    execute replace(v_def, v_old_lock, v_new_lock);
    raise notice '[round move] 가드 덩어리의 회원 잠금을 기다리지 않게 바꿨습니다';
  end if;
  if v_src not like '%ROUND_MOVE_20261116%' then
    if md5(v_src) <> 'ed27df3b771cb0aa866e3ce50227b0f4' then
      raise warning '[round move] 중복 가드 본문이 저장소 판과 다릅니다(md5 %) — 손대지 않고 트리거도 만들지 않음', md5(v_src);
      return;
    end if;
    v_anchor := E'  v_tp := nullif(btrim(coalesce(new.ticket_product_id::text, \'\')), \'\');\n';
    v_block := E'\n  -- ROUND_MOVE_20261116 회차 날짜·시간 이동(taam_tp_round_move)이 옮기는 그 회차의 행 — 새 구매가 아니다(겹침은 이동 기록에 남긴다)\n'
            || E'  if tg_op = \'UPDATE\' and v_tp is not null\n'
            || E'     and coalesce(current_setting(\'taam.round_move\', true), \'\') = v_tp\n'
            || E'     and old.user_id is not distinct from new.user_id\n'
            || E'     and old.ticket_product_id::text is not distinct from new.ticket_product_id::text\n'
            || v_new_lock
            || E'    return new;\n'
            || E'  end if;\n';
    v_def := pg_get_functiondef('public.taam_guard_purchase_unique()'::regprocedure);
    v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_n <> 1 then raise warning '[round move] 가드에서 넣을 자리를 정확히 한 곳 찾지 못했습니다(%) — 손대지 않음', v_n; return; end if;
    execute replace(v_def, v_anchor, v_anchor || v_block);
    raise notice '[round move] 중복 가드에 이동 통과 덩어리를 넣었습니다';
  end if;

  drop trigger if exists trg_taam_tp_round_move on public.ticket_products;
  create trigger trg_taam_tp_round_move after update of date, time on public.ticket_products
    for each row when (old.date is distinct from new.date or old.time is distinct from new.time)
    execute function public.taam_tp_round_move();
  drop trigger if exists trg_taam_tp_round_lock on public.ticket_products;
  create trigger trg_taam_tp_round_lock before update of date, time on public.ticket_products
    for each row when (old.date is distinct from new.date or old.time is distinct from new.time)
    execute function public.taam_guard_tp_round_lock();
  -- 이름이 중복·시간대 가드(trg_taam_guard_ticket_unique)보다 뒤여야 한다 — 회차 행 잠금을 회원 잠금 뒤에(위 ④ 머리말)
  drop trigger if exists trg_taam_guard_ticket_date_pin on public.tickets;
  drop trigger if exists trg_taam_guard_ticket_zdate_pin on public.tickets;
  create trigger trg_taam_guard_ticket_zdate_pin before insert on public.tickets
    for each row execute function public.taam_guard_ticket_date_pin();
  drop trigger if exists trg_taam_guard_invite_date_pin on public.reservation_invites;
  create trigger trg_taam_guard_invite_date_pin before insert on public.reservation_invites
    for each row execute function public.taam_guard_invite_date_pin();
end $mig$;

-- ── 7. 리마인드 중복 방지에 날짜 (md5 가드) ──────────────────────────────────
do $mig$
declare v_src text; v_def text; v_old text; v_new text; v_n int;
begin
  -- 7-1 회원 리마인드 — (티켓 · 일수) + 방문일. 날짜가 없는 옛 줄은 종전처럼 막는다
  select p.prosrc into v_src from pg_proc p where p.oid = to_regprocedure('public.taam_visit_reminder_notify()');
  if v_src is null then raise warning '[round move] taam_visit_reminder_notify 없음 — 건너뜀';
  elsif v_src like '%VR_DATEKEY_20261116%' then raise notice '[round move] 리마인드 이미 새 판';
  elsif md5(v_src) <> '52d0603ae3c0bd4482784b5799ca82c7' then raise warning '[round move] 리마인드 본문이 다릅니다(md5 %) — 건드리지 않음', md5(v_src);
  else
    v_old := E'          and n.payload ->> \'days\' = m.d::text)';
    v_new := E'          and n.payload ->> \'days\' = m.d::text\n'
          || E'          -- VR_DATEKEY_20261116 방문일까지 같아야 「이미 보냄」 — 회차 날짜를 옮긴 예약은 새 날짜로 다시 나간다(날짜 없는 옛 줄은 종전처럼)\n'
          || E'          and coalesce(n.payload ->> \'date\', to_char(m.vd, \'YYYY-MM-DD\')) = to_char(m.vd, \'YYYY-MM-DD\'))';
    v_def := pg_get_functiondef('public.taam_visit_reminder_notify()'::regprocedure);
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_n <> 1 then raise warning '[round move] 리마인드에서 자리를 정확히 한 곳 못 찾음(%)', v_n;
    else execute replace(v_def, v_old, v_new); raise notice '[round move] 리마인드 중복 방지에 날짜를 넣었습니다'; end if;
  end if;

  -- 7-2 캘린더 발송 현황 — 푸시 기록은 그 단계의 날(KST)에 보낸 것만 · 알림 줄은 방문일 · 마감 알림은 마감일
  select p.prosrc into v_src from pg_proc p where p.oid = to_regprocedure('public._taam_vr_seat_status(uuid)');
  if v_src is null then raise warning '[round move] _taam_vr_seat_status 없음 — 건너뜀';
  elsif v_src like '%VR_DATEKEY_20261116%' then raise notice '[round move] 발송 현황 이미 새 판';
  elsif md5(v_src) <> 'b42fdace23b67d970608cf8fa1cf98b0' then raise warning '[round move] 발송 현황 본문이 다릅니다(md5 %) — 건드리지 않음', md5(v_src);
  else
    v_def := pg_get_functiondef('public._taam_vr_seat_status(uuid)'::regprocedure);
    v_old := E'       where l.ticket_key = t.id::text and l.days = v_d and l.user_id = t.user_id\n';
    v_new := E'       where l.ticket_key = t.id::text and l.days = v_d and l.user_id = t.user_id\n'
          || E'         and (l.at at time zone \'Asia/Seoul\')::date = v_day   -- VR_DATEKEY_20261116 옛 방문일로 보낸 기록은 새 날짜의 「보냄」이 아니다\n';
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_n <> 1 then raise warning '[round move] 발송 현황 ① 자리 %', v_n; return; end if;
    v_def := replace(v_def, v_old, v_new);
    v_old := E'         and n.payload ->> \'ticket_id\' = t.id::text and n.payload ->> \'days\' = v_d::text\n';
    v_new := E'         and n.payload ->> \'ticket_id\' = t.id::text and n.payload ->> \'days\' = v_d::text\n'
          || E'         and coalesce(n.payload ->> \'date\', to_char(v_vd, \'YYYY-MM-DD\')) = to_char(v_vd, \'YYYY-MM-DD\')\n';
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_n <> 1 then raise warning '[round move] 발송 현황 ② 자리 %', v_n; return; end if;
    v_def := replace(v_def, v_old, v_new);
    v_old := E'     where n.user_id = t.user_id and n.type = \'visit_reminder\' and n.payload ->> \'kind\' = \'cancel_deadline\'\n'
          || E'       and n.payload ->> \'ticket_id\' = t.id::text\n';
    v_new := v_old || E'       and coalesce(n.payload ->> \'deadline\', to_char(v_vd - 31, \'YYYY-MM-DD\')) = to_char(v_vd - 31, \'YYYY-MM-DD\')\n';
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_n <> 1 then raise warning '[round move] 발송 현황 ③ 자리 %', v_n; return; end if;
    execute replace(v_def, v_old, v_new);
    raise notice '[round move] 발송 현황에 날짜를 넣었습니다';
  end if;
end $mig$;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① 중복·시간대 가드에 회차 이동 통과(ROUND_MOVE_20261116 · 회원 잠금은 기다리지 않음)' as what,
       case when exists (select 1 from pg_proc where oid = to_regprocedure('public.taam_guard_purchase_unique()') and prosrc like '%ROUND_MOVE_20261116%')
             and exists (select 1 from pg_proc where oid = to_regprocedure('public.taam_guard_purchase_unique()') and prosrc like '%ROUND_MOVE_MEMBER_BUSY%')
            then '✅' else '❌ 가드 본문이 저장소 판과 달라 손대지 않음 — 트리거도 안 만듦' end as result
union all
select '② 트리거 넷(이동 · 앱 저장 잠금 · 좌석 날짜 고정 · 초대 날짜 고정)',
       case when (select count(*) from pg_trigger where not tgisinternal and tgenabled = 'O' and tgname in
                   ('trg_taam_tp_round_move', 'trg_taam_tp_round_lock', 'trg_taam_guard_ticket_zdate_pin', 'trg_taam_guard_invite_date_pin')) = 4
            then '✅' else '❌' end
union all
select '③ 회원 리마인드 중복 방지에 방문일(VR_DATEKEY_20261116)',
       case when exists (select 1 from pg_proc where proname = 'taam_visit_reminder_notify' and prosrc like '%VR_DATEKEY_20261116%') then '✅'
            else '❌ 리마인드 본문이 달라 손대지 않음 — 옮긴 예약의 리마인드가 다시 안 갈 수 있다' end
union all
select '④ 캘린더 발송 현황에 방문일(VR_DATEKEY_20261116)',
       case when exists (select 1 from pg_proc where proname = '_taam_vr_seat_status' and prosrc like '%VR_DATEKEY_20261116%') then '✅'
            else '❌ 발송 현황 본문이 달라 손대지 않음' end
union all
select '⑤ RPC 다섯 · 비로그인 실행 불가',
       case when (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
                   ('taam_round_move_preview','taam_round_reschedule','taam_round_move_resync','taam_round_moves','taam_round_move_notify')
                   and not has_function_privilege('anon', p.oid, 'execute')) = 5 then '✅' else '❌' end
union all
select '⑥ 이동 기록 표 RLS 켬',
       case when (select relrowsecurity from pg_class where oid = 'public.ticket_round_moves'::regclass) then '✅' else '❌' end
union all
select '⑦ 의존 함수(_taam_ksk_seat_sync · _taam_member_push · _taam_rest_name_l10n · _taam_purchase_exc_find · _taam_fee_caller_ok · _taam_uid_is_super)',
       case when to_regprocedure('public._taam_ksk_seat_sync(uuid)') is not null
             and to_regprocedure('public._taam_uid_is_super()') is not null
             and to_regproc('public._taam_member_push') is not null
             and to_regprocedure('public._taam_rest_name_l10n(text,text)') is not null
             and to_regprocedure('public._taam_purchase_exc_find(uuid,text,text,integer)') is not null
             and to_regprocedure('public._taam_fee_caller_ok()') is not null then '✅' else '❌' end
union all
select '⑧ 회차 날짜와 다른 살아 있는 좌석 행(정보 · 정산 좌석 제외)',
       (select count(*)::text from public.tickets k join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
         where lower(coalesce(k.status,'')) not in ('cancelled','canceled','expired','failed','refunded') and coalesce(k.purchase_id,'') not like 'KSK-%'
           and public._taam_pu_visit_date(k.reservation_date) is distinct from public._taam_pu_visit_date(tp.date))
union all
select '⑨ 회차 날짜와 다른 보냄·결제 초대(정보)',
       (select count(*)::text from public.reservation_invites i join public.ticket_products tp on tp.id::text = i.ticket_product_id::text
         where lower(coalesce(i.status,'')) in ('sent','paid') and public._taam_pu_visit_date(i.visit_date) is distinct from public._taam_pu_visit_date(tp.date));
