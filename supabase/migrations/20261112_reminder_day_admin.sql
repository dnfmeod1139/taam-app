-- ═══════════════════════════════════════════════════════════════
-- 슈퍼어드민 방문 리마인드는 날짜마다 한 번 · 캘린더에서 손님 리마인드 발송 확인 · 연회비 알림에 계산 근거 (2026-11-12 운영 요청)
--
-- 왜:
--   ① 「슈퍼어드민 알림이 각 회원마다 3개·4개씩 온다 — 피곤하고 쓸모없다. 일정을 알려주는 푸시로 한 번만 오고, 누가 오는지는
--      캘린더에서, 그 사람들한테 푸시가 갔는지만 확인되면 된다」.
--      2026-10-27 판(_taam_visit_reminder_admin)은 캘린더 일정 하나마다 회원 리마인드와 같은 모양의 줄을 슈퍼어드민에게 따로 보냈다
--      (히가시아자부 아마모토 11/13 = 4줄).
--   ② 「연회비 알림이 한 달씩 일찍 온다 — 한 달 먼저 알려 주는 건지 1년을 다르게 세는 건지」. 계산은 맞다(기준일 30일 전 미리 알림 단계).
--      그런데 알림이 「D-30 · 2년차」로만 적혀 무엇을 기준으로 셌는지 안 보였고, 「2년차」는 **시작된 연차 수**라
--      기준일(12/11)부터 내는 연회비(3년차)와 어긋났다.
-- 무엇:
--   A 표 visit_reminder_push_log + taam_visit_reminder_push_mark(p_rows) — Edge notify-visit-reminder 가 send-push 결과(기기 수·성공·실패)를
--     알림 줄 id 마다 적는다. 서버만 쓴다(RLS · 정책 없음). 회원은 자기 알림 줄을 고치거나 지울 수 있어 그 줄만으로는 「갔다」의 근거가 못 된다.
--   B _taam_vr_day_msg — 「내일 방문 일정 — 히가시아자부 아마모토 4건 · 8명」 + [날짜] + 매장마다 한 줄(시간 · 건수 · 인원) 세 언어
--   C _taam_visit_reminder_admin 교체 — 대상(전 일정: 좌석 행 확정·수동 · 좌석 없는 결제 초대 · 수동 기록)·설정(remind7/3/1)은 그대로,
--     **슈퍼어드민마다 · 방문일마다 · 일수마다 한 줄**(rkey day:YYYY-MM-DD · fmt day). 같은 날짜·일수로 옛 일정별 줄이 이미 있으면 보내지 않는다.
--     가드: 2026-10-27 판(md5 b3b1c4af…)일 때만 · 이미 새 판(VR_ADMIN_DAY_20261112)이면 ✅ · 모르는 판 ❌ 건너뜀.
--     taam_visit_reminder_notify(회원 리마인드 + 이 함수 + 취소 마감일)는 손대지 않는다.
--   D taam_visit_reminder_status(p_date, 구매 id[], 초대 id[]) — 슈퍼어드민 캘린더가 줄마다 「회원 리마인드 3일 전 ✓ · 하루 전 예정」 ·
--     「알림톡 …」 · 「대상 아님(이유)」을 그린다. 규칙은 리마인드 함수와 같다(회원: 확정 행 · 운영 행 제외 · remind7/3/1 · 기본 3·1 /
--     비회원: 결제 링크(회원 없음)·수동 좌석 + 번호 9자리↑ · 3일·하루 전 · guest_remind_log). 슈퍼어드민·서버만.
--   E taam_membership_fee_notify 교체 — 줄마다 「3년차 연회비 ₩ · 기준일 (N일 남음)」 + 「└ 실제 가입일 2024.12.11 + 납부 2년 = 2026.12.11 · 30일 전 미리 알림」.
--     제목은 단계가 하나면 「💰 연회비 납부 30일 전 알림 · N명」. 대상·단계·기록(membership_fee_notices)은 그대로. 가드 md5 3067b7bb… · 새 판 표시 FEE_NOTIFY_V2_20261112.
-- 회원에게 가는 것은 바뀌지 않는다. 회귀: bash sql/_test/t_reminder_day_admin.sh
-- ═══════════════════════════════════════════════════════════════

-- ── A 푸시 결과 기록 ──
create table if not exists public.visit_reminder_push_log (
  notif_id   uuid primary key,                 -- notifications.id (이번 실행이 넣은 줄)
  user_id    uuid,
  ticket_key text,                             -- 회원: tickets.id · 취소 마감일: cd-<id> · 슈퍼어드민: day:YYYY-MM-DD
  days       int,
  http       int,                              -- send-push 응답 상태
  matched    int,                              -- 그 회원의 등록 기기 수(설정으로 거르기 전)
  attempted  int,                              -- 보낸 기기 수(알림 설정으로 거른 뒤)
  ok         int,
  failed     int,
  err        text,
  at         timestamptz not null default now()
);
comment on table public.visit_reminder_push_log is '방문 리마인드 푸시 결과(Edge notify-visit-reminder 가 적는다) — 슈퍼어드민 캘린더의 「리마인드 발송」 표시. 2026-11-12';
create index if not exists visit_reminder_push_log_ticket on public.visit_reminder_push_log (ticket_key);
alter table public.visit_reminder_push_log enable row level security;
revoke all on table public.visit_reminder_push_log from anon, authenticated;

create or replace function public.taam_visit_reminder_push_mark(p_rows jsonb)
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare v_n int := 0;
begin
  -- 서버(Edge service_role · SQL Editor)만 — 로그인 세션은 슈퍼어드민이어도 쓰지 않는다(기록은 실제 발송의 결과여야 한다)
  if auth.uid() is not null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not (session_user = 'postgres'
          or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return 0; end if;
  insert into public.visit_reminder_push_log (notif_id, user_id, ticket_key, days, http, matched, attempted, ok, failed, err)
  select (x->>'notif_id')::uuid,
         case when (x->>'user_id') ~* '^[0-9a-f-]{36}$' then (x->>'user_id')::uuid end,
         left(x->>'ticket_key', 80),
         case when (x->>'days') ~ '^-?[0-9]{1,3}$' then (x->>'days')::int end,
         case when (x->>'http') ~ '^[0-9]{1,3}$' then (x->>'http')::int end,
         case when (x->>'matched') ~ '^[0-9]{1,4}$' then (x->>'matched')::int end,
         case when (x->>'attempted') ~ '^[0-9]{1,4}$' then (x->>'attempted')::int end,
         case when (x->>'ok') ~ '^[0-9]{1,4}$' then (x->>'ok')::int end,
         case when (x->>'failed') ~ '^[0-9]{1,4}$' then (x->>'failed')::int end,
         left(x->>'err', 200)
    from jsonb_array_elements(p_rows) x
   where (x->>'notif_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  on conflict (notif_id) do update
    set http = excluded.http, matched = excluded.matched, attempted = excluded.attempted, ok = excluded.ok,
        failed = excluded.failed, err = excluded.err, at = now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.taam_visit_reminder_push_mark(jsonb) from public, anon, authenticated;

-- ── B 날짜 묶음 문구 ──
--   p_rests: [{ko, en, ja, n, pax, times:['20:30', …]}] (매장 이름순)
create or replace function public._taam_vr_day_msg(p_date date, p_days int, p_rests jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  v_dow int; d_ko text := ''; d_en text := ''; d_ja text := '';
  e jsonb; tm text; v_mt text[]; v_h int; v_h12 int;
  tk text[]; te text[]; tj text[];
  l_ko text := ''; l_en text := ''; l_ja text := '';
  v_k int := 0; v_n int := 0; v_pax int := 0; n int; px int;
  nm_ko text; nm_en text; nm_ja text; f_ko text; f_en text; f_ja text; f_n int; f_px int;
  h_ko text; h_en text; h_ja text; ti_ko text; ti_en text; ti_ja text;
begin
  if p_date is not null then
    v_dow := extract(dow from p_date)::int;
    d_ko := extract(year from p_date)::int || '년 ' || extract(month from p_date)::int || '월 ' || extract(day from p_date)::int || '일('
            || (array['일','월','화','수','목','금','토'])[v_dow + 1] || ')';
    d_en := (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[v_dow + 1] || ', '
            || (array['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'])[extract(month from p_date)::int] || ' '
            || extract(day from p_date)::int || ', ' || extract(year from p_date)::int;
    d_ja := extract(year from p_date)::int || '年' || extract(month from p_date)::int || '月' || extract(day from p_date)::int || '日('
            || (array['日','月','火','水','木','金','土'])[v_dow + 1] || ')';
  end if;
  for e in select x from jsonb_array_elements(case when jsonb_typeof(p_rests) = 'array' then p_rests else '[]'::jsonb end) x loop
    v_k := v_k + 1;
    n := greatest(coalesce(case when (e->>'n') ~ '^[0-9]{1,6}$' then (e->>'n')::int end, 0), 0);
    px := greatest(coalesce(case when (e->>'pax') ~ '^[0-9]{1,6}$' then (e->>'pax')::int end, 0), 0);
    v_n := v_n + n; v_pax := v_pax + px;
    nm_ko := coalesce(nullif(btrim(e->>'ko'), ''), '매장 미상');
    nm_en := coalesce(nullif(btrim(e->>'en'), ''), nullif(btrim(e->>'ko'), ''), 'Unknown venue');
    nm_ja := coalesce(nullif(btrim(e->>'ja'), ''), nullif(btrim(e->>'ko'), ''), '店舗不明');
    tk := '{}'; te := '{}'; tj := '{}';
    for tm in select jsonb_array_elements_text(case when jsonb_typeof(e->'times') = 'array' then e->'times' else '[]'::jsonb end) loop
      v_mt := regexp_match(btrim(coalesce(tm, '')), '^(\d{1,2}):(\d{2})');
      if v_mt is not null and v_mt[1]::int between 0 and 23 then
        v_h := v_mt[1]::int; v_h12 := case when v_h % 12 = 0 then 12 else v_h % 12 end;
        tk := tk || (case when v_h < 12 then '오전 ' else '오후 ' end || v_h12 || ':' || v_mt[2]);
        te := te || (v_h12 || ':' || v_mt[2] || case when v_h < 12 then ' AM' else ' PM' end);
        tj := tj || (case when v_h < 12 then '午前' else '午後' end || v_h12 || ':' || v_mt[2]);
      elsif nullif(btrim(coalesce(tm, '')), '') is not null then
        tk := tk || left(btrim(tm), 20); te := te || left(btrim(tm), 20); tj := tj || left(btrim(tm), 20);
      end if;
    end loop;
    l_ko := l_ko || E'\n• ' || nm_ko || coalesce(' · ' || nullif(array_to_string(tk, ', '), ''), '') || ' · ' || n || '건 ' || px || '명';
    l_en := l_en || E'\n• ' || nm_en || coalesce(' · ' || nullif(array_to_string(te, ', '), ''), '') || ' · ' || n || case when n = 1 then ' booking, ' else ' bookings, ' end || px || case when px = 1 then ' guest' else ' guests' end;
    l_ja := l_ja || E'\n• ' || nm_ja || coalesce(' · ' || nullif(array_to_string(tj, ', '), ''), '') || ' · ' || n || '件 ' || px || '名';
    if v_k = 1 then f_ko := nm_ko; f_en := nm_en; f_ja := nm_ja; f_n := n; f_px := px; end if;
  end loop;
  h_ko := case when p_days = 1 then '내일 방문 일정' when p_days is null or p_days < 1 then '방문 일정' else p_days || '일 뒤 방문 일정' end;
  h_en := case when p_days = 1 then 'Visits tomorrow' when p_days is null or p_days < 1 then 'Visits' else 'Visits in ' || p_days || ' days' end;
  h_ja := case when p_days = 1 then '明日のご来店予定' when p_days is null or p_days < 1 then 'ご来店予定' else p_days || '日後のご来店予定' end;
  if v_k = 1 then
    ti_ko := h_ko || ' — ' || f_ko || ' ' || f_n || '건 · ' || f_px || '명';
    ti_en := h_en || ' — ' || f_en || ' · ' || f_n || case when f_n = 1 then ' booking · ' else ' bookings · ' end || f_px || case when f_px = 1 then ' guest' else ' guests' end;
    ti_ja := h_ja || ' — ' || f_ja || ' ' || f_n || '件 · ' || f_px || '名';
  else
    ti_ko := h_ko || ' — ' || v_k || '곳 · ' || v_n || '건 · ' || v_pax || '명';
    ti_en := h_en || ' — ' || v_k || ' venues · ' || v_n || ' bookings · ' || v_pax || ' guests';
    ti_ja := h_ja || ' — ' || v_k || '店舗 · ' || v_n || '件 · ' || v_pax || '名';
  end if;
  return jsonb_build_object(
    'ko', jsonb_build_object('title', ti_ko, 'body', '[날짜] : ' || d_ko || l_ko || E'\n\n누가 오는지 · 손님 리마인드 발송은 티켓 캘린더에서 확인하세요.'),
    'en', jsonb_build_object('title', ti_en, 'body', '[Date] : ' || d_en || l_en || E'\n\nSee the ticket calendar for guests and their reminders.'),
    'ja', jsonb_build_object('title', ti_ja, 'body', '[日付] : ' || d_ja || l_ja || E'\n\nご来店者とリマインド送信はチケットカレンダーで確認できます。'));
end $$;
revoke all on function public._taam_vr_day_msg(date, int, jsonb) from public, anon;

-- ── C 슈퍼어드민 몫 — 날짜마다 한 번 ──
drop table if exists _vrd;
create temp table _vrd(k text primary key, status text);
do $do$
declare v_src text; v_md5 text;
begin
  select p.prosrc, md5(p.prosrc) into v_src, v_md5 from pg_proc p where p.oid = to_regprocedure('public._taam_visit_reminder_admin()');
  if v_src is null then insert into _vrd values ('C', '❌ 라이브에 _taam_visit_reminder_admin 이 없다 — 20261027_visit_reminder_admin.sql 먼저'); return; end if;
  if v_src like '%VR_ADMIN_DAY_20261112%' then insert into _vrd values ('C', '✅ 이미 새 판(날짜마다 한 번)'); return; end if;
  if v_md5 <> 'b3b1c4af844cf4731f93befe7e1b2bff' then
    insert into _vrd values ('C', '❌ 라이브 본문이 2026-10-27 판(b3b1c4af…)과 다르다 — 건너뜀 (md5 ' || v_md5 || ')'); return;
  end if;
  execute $fn$
create or replace function public._taam_visit_reminder_admin()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $body$
-- VR_ADMIN_DAY_20261112 — 슈퍼어드민마다 · 방문일마다 · 일수마다 한 줄. 대상·설정은 2026-10-27 판 그대로
declare v_cnt int := 0; v_rows jsonb; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  with sa as (
    select p.id, coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np
      from public.profiles p
     where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = ''
  ), ent as (
    -- 좌석 행 — 확정·수동만(홀드 PAYH/INVH/LINK 결제 전 · 취소 · 만료 · 게스트석 확정 대기 제외)
    select nullif(btrim(t.restaurant_name), '')                        as rest_raw,
           coalesce(nullif(btrim(t.visit_time), ''), '')               as vtime,
           public.taam_visit_date(t.reservation_date)                  as vd,
           greatest(coalesce(t.party_size, 1), 1)                      as pax,
           coalesce(nullif(btrim(t.restaurant_id::text), ''),
                    (select tp.rest_id::text from public.ticket_products tp where tp.id::text = t.ticket_product_id::text limit 1)) as rest_id
      from public.tickets t
      left join public.profiles pu on pu.id = t.user_id
     where lower(coalesce(t.status, '')) in ('active', 'manual')
       and not (coalesce(to_jsonb(pu)->>'is_test', '') = 'true' and coalesce(t.purchase_id, '') !~ '^(KSK|LINK|MAN)-')
    union all
    -- 결제된 초대 중 좌석 행이 한 번도 없었던 것(캘린더는 초대로 보여 준다)
    select nullif(btrim(i.restaurant_name), ''), coalesce(nullif(btrim(i.visit_time), ''), ''),
           public.taam_visit_date(i.visit_date), greatest(coalesce(i.pax, 1), 1),
           coalesce(nullif(btrim(i.restaurant_id::text), ''),
                    (select tp.rest_id::text from public.ticket_products tp where tp.id::text = i.ticket_product_id::text limit 1))
      from public.reservation_invites i
      left join public.profiles pi on pi.id = i.invitee_user_id
     where lower(coalesce(i.status, '')) = 'paid'
       and coalesce(to_jsonb(pi)->>'is_test', '') <> 'true'
       and not exists (select 1 from public.tickets t
                        where coalesce(t.purchase_id, '') not like 'INVH-%'
                          and (t.extra_data->>'inviteId' = i.id::text
                               or (t.extra_data->>'inviteId' is null and t.purchase_id like 'INV-' || left(i.id::text, 8) || '-%')))
    union all
    -- 수동 기록(좌석 연동 없음) — 날짜만
    select nullif(btrim(coalesce(to_jsonb(m)->>'venue_name', '')), ''), '', m.ymd, greatest(coalesce(m.pax, 1), 1),
           nullif(btrim(coalesce(m.venue_id::text, '')), '')
      from public.daegwan_manual m
  ), due as (
    select e.*, (e.vd - v_today) as d from ent e where e.vd is not null and (e.vd - v_today) in (1, 3, 7)
  ), want as (
    -- 슈퍼어드민 본인 설정 — 회원과 같은 규칙(boolean 이 아니면 기본: 3일·하루 전)
    select s.id as admin_id, u.*
      from due u cross join sa s
     where coalesce(case when jsonb_typeof(s.np -> ('remind' || u.d::text)) = 'boolean' then (s.np ->> ('remind' || u.d::text))::boolean end,
                    u.d in (1, 3)) is true
  ), fresh as (
    -- 같은 날짜·같은 일수는 한 번 — 옛 일정별 줄(2026-10-27 판)이 이미 있어도 보내지 않는다 · 글자 비교 ·
    --   회원이 taam_notify_admins 로 꽂은 줄(via)은 세지 않는다(꽂아서 슈퍼어드민 리마인드를 막을 수 있었다)
    select distinct w.admin_id, w.vd, w.d
      from want w
     where not exists (
       select 1 from public.notifications n
        where n.user_id = w.admin_id
          and n.type = 'visit_reminder'
          and n.payload ->> 'admin' = 'true'
          and coalesce(n.payload ->> 'via', '') <> 'taam_notify_admins'
          and n.payload ->> 'date' = to_char(w.vd, 'YYYY-MM-DD')
          and n.payload ->> 'days' = w.d::text)
  ), per_rest as (
    select w.admin_id, w.vd, w.d,
           coalesce(max(nullif(btrim(to_jsonb(r)->>'name'), '')), max(w.rest_raw))           as nm_ko,
           max(nullif(btrim(to_jsonb(r)->>'name_en'), ''))                                   as nm_en,
           max(case when coalesce(to_jsonb(r)->>'i18n_jp_approved', '') <> 'false' then nullif(btrim(to_jsonb(r)->>'name_jp'), '') end) as nm_ja,
           count(*)::int as n, sum(w.pax)::int as pax,
           coalesce(jsonb_agg(distinct w.vtime order by w.vtime) filter (where w.vtime <> ''), '[]'::jsonb) as times
      from want w
      join fresh f on f.admin_id = w.admin_id and f.vd = w.vd and f.d = w.d
      left join public.restaurants r on r.id::text = w.rest_id
     group by w.admin_id, w.vd, w.d, coalesce(nullif(w.rest_id, ''), 'n:' || coalesce(w.rest_raw, ''))
  ), per_day as (
    select pr.admin_id, pr.vd, pr.d,
           jsonb_agg(jsonb_build_object('ko', pr.nm_ko, 'en', pr.nm_en, 'ja', pr.nm_ja, 'n', pr.n, 'pax', pr.pax, 'times', pr.times)
                     order by pr.nm_ko) as rests,
           sum(pr.n)::int as n, sum(pr.pax)::int as pax, min(pr.nm_ko) as first_rest
      from per_rest pr
     group by pr.admin_id, pr.vd, pr.d
  ), msg as (
    select pd.*, public._taam_vr_day_msg(pd.vd, pd.d, pd.rests) as i18n from per_day pd
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select m.admin_id, 'visit_reminder', m.i18n->'ko'->>'title', m.i18n->'ko'->>'body', '/',
           jsonb_build_object('kind', 'visit_reminder', 'admin', true, 'fmt', 'day', 'rkey', 'day:' || to_char(m.vd, 'YYYY-MM-DD'),
                              'days', m.d, 'date', to_char(m.vd, 'YYYY-MM-DD'), 'count', m.n, 'pax', m.pax,
                              'rests', m.rests, 'i18n', m.i18n)
      from msg m
    returning id, user_id, title, body, url, payload
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'user_id', i.user_id, 'title', i.title, 'body', i.body, 'url', i.url,
           'days', (i.payload ->> 'days')::int,          -- 서버가 방금 넣은 줄이라 숫자다
           'ticket_id', i.payload ->> 'rkey',            -- Edge 의 푸시 tag(visit-reminder-day:…) — 날짜마다 하나(D-3 위에 D-1 이 덮인다)
           'rest', coalesce(i.payload -> 'rests' -> 0 ->> 'ko', ''), 'vtime', '', 'i18n', i.payload -> 'i18n')), '[]'::jsonb)
    into v_cnt, v_rows
    from ins i;
  return jsonb_build_object('made', v_cnt, 'rows', v_rows, 'skipped', 0);
end $body$
$fn$;
  execute 'revoke all on function public._taam_visit_reminder_admin() from public, anon, authenticated';
  insert into _vrd values ('C', '✅ 교체(날짜마다 한 번)');
end $do$;

-- ── D 캘린더용 — 손님 리마인드 발송 현황 ──
--   한 좌석 행의 상태. kind: member(회원 푸시) · guest(비회원 알림톡) · none(대상 아님 · why)
--   stages[]: {d, day, st, at, push} — st: sent · plan(예정) · off(회원 설정 꺼짐) · late(그 뒤에 예약) · missed(⚠ 안 감) · fail · skip
create or replace function public._taam_vr_seat_status(p_tid uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  t record; v_pid text; v_st text; v_vd date; v_ex jsonb;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_now_kst timestamp := now() at time zone 'Asia/Seoul';
  v_np jsonb; v_on boolean; v_d int; v_day date; v_stages jsonb := '[]'::jsonb; r record; g record;
  v_nonmember_link boolean; v_flags boolean; v_member boolean; v_guest boolean; v_phone text; v_kr boolean;
  v_created_kst timestamp; v_all_off boolean; v_cd jsonb;
begin
  if p_tid is null then return jsonb_build_object('kind', 'none', 'why', 'no_seat'); end if;
  select * into t from public.tickets where id = p_tid;
  if not found then return jsonb_build_object('kind', 'none', 'why', 'no_seat'); end if;
  v_pid := coalesce(t.purchase_id, ''); v_st := lower(coalesce(t.status, '')); v_ex := coalesce(t.extra_data, '{}'::jsonb);
  v_vd := public.taam_visit_date(t.reservation_date);
  v_created_kst := t.created_at at time zone 'Asia/Seoul';
  v_nonmember_link := v_pid like 'LINK-%' and nullif(v_ex->>'memberUid', '') is null;
  v_flags := coalesce((v_ex ? 'kashikiri') or ((v_ex ? 'linkInvite') and nullif(v_ex->>'memberUid', '') is null) or (v_ex ? 'manualEntry'), false);
  -- 회원 리마인드(taam_visit_reminder_notify)와 같은 거름
  v_member := t.user_id is not null and v_st = 'active' and v_pid not like 'KSK-%' and not v_nonmember_link and v_pid not like 'MAN-%' and not v_flags;
  v_phone := regexp_replace(coalesce(t.buyer_phone, ''), '[^0-9]', '', 'g');
  -- 비회원 알림톡(taam_guest_reminder_targets)과 같은 거름
  v_guest := v_st in ('active', 'manual') and length(v_phone) >= 9 and (v_nonmember_link or v_pid like 'MAN-%');
  if v_st not in ('active', 'manual') then return jsonb_build_object('kind', 'none', 'why', 'status', 'st', v_st); end if;
  if not v_member and not v_guest then
    return jsonb_build_object('kind', 'none', 'why',
      case when v_pid like 'KSK-%' then 'ksk' when v_pid like 'MAN-%' or v_nonmember_link then 'nophone' else 'ops' end);
  end if;
  if v_vd is null then return jsonb_build_object('kind', case when v_member then 'member' else 'guest' end, 'why', 'no_date', 'stages', '[]'::jsonb); end if;

  if v_member then
    select coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) into v_np from public.profiles p where p.id = t.user_id;
    v_np := coalesce(v_np, '{}'::jsonb);
    v_all_off := jsonb_typeof(v_np->'all') = 'boolean' and (v_np->>'all')::boolean = false;
    foreach v_d in array array[7, 3, 1] loop
      v_day := v_vd - v_d;
      v_on := coalesce(case when jsonb_typeof(v_np -> ('remind' || v_d::text)) = 'boolean' then (v_np ->> ('remind' || v_d::text))::boolean end, v_d in (1, 3));
      -- 보낸 기록: 서버가 적은 푸시 결과(지워지지 않는다) → 없으면 회원 알림 줄(옛 기록 · 회원이 지울 수 있다)
      select l.at, l.http, l.matched, l.attempted, l.ok, l.failed into r
        from public.visit_reminder_push_log l
       where l.ticket_key = t.id::text and l.days = v_d and l.user_id = t.user_id
       order by l.at desc limit 1;
      if found then
        v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'sent', 'at', r.at,
                      'push', jsonb_build_object('http', r.http, 'matched', r.matched, 'attempted', r.attempted, 'ok', r.ok, 'failed', r.failed));
        continue;
      end if;
      select n.created_at into r
        from public.notifications n
       where n.user_id = t.user_id and n.type = 'visit_reminder'
         and n.payload ->> 'ticket_id' = t.id::text and n.payload ->> 'days' = v_d::text
         and coalesce(n.payload ->> 'admin', '') <> 'true' and coalesce(n.payload ->> 'via', '') <> 'taam_notify_admins'
         and coalesce(n.payload ->> 'kind', 'visit_reminder') <> 'cancel_deadline'
       order by n.created_at desc limit 1;
      if found then
        v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'sent', 'at', r.created_at, 'push', null);
      elsif not v_on then
        v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'off');
      elsif v_day > v_today or (v_day = v_today and v_now_kst::time < time '11:30') then
        v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'plan');
      elsif v_created_kst > (v_day + time '11:00') then
        v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'late');
      else
        v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'missed');
      end if;
    end loop;
    -- 취소 마감일(방문 31일 전) — 보낸 것만 보여 준다(대상 규칙이 따로다)
    select jsonb_build_object('d', 31, 'day', v_vd - 31, 'st', 'sent', 'at', n.created_at,
             'push', (select jsonb_build_object('http', l.http, 'matched', l.matched, 'attempted', l.attempted, 'ok', l.ok, 'failed', l.failed)
                        from public.visit_reminder_push_log l where l.notif_id = n.id))
      into v_cd
      from public.notifications n
     where n.user_id = t.user_id and n.type = 'visit_reminder' and n.payload ->> 'kind' = 'cancel_deadline'
       and n.payload ->> 'ticket_id' = t.id::text
     order by n.created_at desc limit 1;
    return jsonb_build_object('kind', 'member', 'vd', v_vd, 'all_off', v_all_off, 'stages', v_stages, 'deadline', v_cd);
  end if;

  -- 비회원 알림톡 — 3일·하루 전 · 국내 휴대폰만(해외 번호는 Edge 가 skip 으로 적는다)
  v_kr := (case when v_phone like '82%' then '0' || substr(v_phone, 3) else v_phone end) ~ '^01[016789][0-9]{7,8}$';
  foreach v_d in array array[3, 1] loop
    v_day := v_vd - v_d;
    select gl.result, gl.sent_at into g from public.guest_remind_log gl where gl.ticket_id = t.id and gl.d = v_d;
    if found then
      v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'at', g.sent_at,
                    'st', case when g.result = 'sent' then 'sent' when g.result like 'skip%' then 'skip' else 'fail' end,
                    'res', left(coalesce(g.result, ''), 80));
    elsif v_day > v_today or (v_day = v_today and v_now_kst::time < time '11:30') then
      v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'plan');
    elsif v_created_kst > (v_day + time '11:00') then
      v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'late');
    else
      v_stages := v_stages || jsonb_build_object('d', v_d, 'day', v_day, 'st', 'missed');
    end if;
  end loop;
  return jsonb_build_object('kind', 'guest', 'vd', v_vd, 'kr', v_kr, 'stages', v_stages);
end $$;
revoke all on function public._taam_vr_seat_status(uuid) from public, anon, authenticated;

create or replace function public.taam_visit_reminder_status(p_date date, p_pids text[] default null, p_invites text[] default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_items jsonb := '{}'::jsonb; v_pid text; v_iid text; v_tid uuid; v_inv record; v_one jsonb;
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(array_length(p_pids, 1), 0) > 400 or coalesce(array_length(p_invites, 1), 0) > 400 then
    raise exception 'TOO_MANY' using errcode = '22023';
  end if;
  -- 좌석 행(구매 id) — 같은 구매 id 가 둘이면 살아 있는 것 · 최신
  foreach v_pid in array coalesce(p_pids, '{}'::text[]) loop
    continue when v_pid is null or v_pid = '' or v_items ? ('p:' || v_pid);
    select t.id into v_tid from public.tickets t
     where t.purchase_id = v_pid
     order by (lower(coalesce(t.status, '')) in ('active', 'manual')) desc, t.created_at desc limit 1;
    v_items := v_items || jsonb_build_object('p:' || v_pid, public._taam_vr_seat_status(case when found then v_tid end));
  end loop;
  -- 초대 — 그 초대의 좌석(INV-)으로 본다(보낸 사람의 홀드 INVH- 는 좌석이 아니다). 좌석이 없으면 회원 리마인드가 없다
  foreach v_iid in array coalesce(p_invites, '{}'::text[]) loop
    continue when v_iid is null or v_iid !~* '^[0-9a-f-]{36}$' or v_items ? ('i:' || v_iid);
    select i.id, i.invitee_user_id into v_inv from public.reservation_invites i where i.id::text = v_iid;
    if not found then continue; end if;
    select t.id into v_tid from public.tickets t
     where coalesce(t.purchase_id, '') not like 'INVH-%'
       and (t.extra_data->>'inviteId' = v_inv.id::text
            or (t.extra_data->>'inviteId' is null and t.purchase_id like 'INV-' || left(v_inv.id::text, 8) || '-%'))
     order by (lower(coalesce(t.status, '')) = 'active') desc, t.created_at desc limit 1;
    if found then v_one := public._taam_vr_seat_status(v_tid);
    else v_one := jsonb_build_object('kind', 'none', 'why', 'seatless_invite'); end if;
    v_items := v_items || jsonb_build_object('i:' || v_iid, v_one);
  end loop;
  return jsonb_build_object('date', p_date, 'today', (now() at time zone 'Asia/Seoul')::date,
                            'now_kst', to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD"T"HH24:MI'), 'items', v_items);
end $$;
revoke all on function public.taam_visit_reminder_status(date, text[], text[]) from public, anon;
grant execute on function public.taam_visit_reminder_status(date, text[], text[]) to authenticated;

-- ── E 연회비 알림 — 몇 년차 · 계산 근거 · 몇 일 전 알림인지 ──
do $do$
declare v_src text; v_md5 text;
begin
  select p.prosrc, md5(p.prosrc) into v_src, v_md5 from pg_proc p where p.oid = to_regprocedure('public.taam_membership_fee_notify(date)');
  if v_src is null then insert into _vrd values ('E', '❌ 라이브에 taam_membership_fee_notify 가 없다 — 20261017_membership_fee_due.sql 먼저'); return; end if;
  if v_src like '%FEE_NOTIFY_V2_20261112%' then insert into _vrd values ('E', '✅ 이미 새 판(계산 근거)'); return; end if;
  if v_md5 <> '3067b7bb7f09fbc016291862dfeef0bc' then
    insert into _vrd values ('E', '❌ 라이브 본문이 2026-10-17 판(3067b7bb…)과 다르다 — 건너뜀 (md5 ' || v_md5 || ')'); return;
  end if;
  execute $fn$
create or replace function public.taam_membership_fee_notify(p_today date default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $body$
-- FEE_NOTIFY_V2_20261112 — 대상·단계·기록은 2026-10-17 판 그대로. 줄에 「N년차 연회비 · 기준일 (N일 남음)」 + 「└ 기준 날짜 + 납부 N년 = 기준일 · 30일 전 미리 알림」
declare
  v_today   date  := coalesce(p_today, (now() at time zone 'Asia/Seoul')::date);
  v_stages  int[] := array[30, 7, 0, -7, -30];
  r record; v_stage int; v_new int;
  v_lines text[] := '{}'; v_push_lines text[] := '{}'; v_members jsonb := '[]'::jsonb; v_cnt int := 0;
  v_title text; v_body text := ''; v_push_body text; v_n int := 0; v_push jsonb := null; v_line text; v_shown int := 0;
  v_nth int; v_when text; v_base text; v_stage_lbl text; v_stage_set int[] := '{}';
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for r in
    select * from public.taam_membership_fee_due(null, v_today) d
     where d.due_date is not null and d.days_left <= 30
     order by d.due_date, d.display_name
  loop
    -- 도달한 단계 중 가장 급한 것 하나만 알리고, 그 위 단계는 알린 것으로 적는다 — 첫 실행에 밀린 회원이 다섯 번 쌓이지 않게
    select min(s) into v_stage from unnest(v_stages) s where r.days_left <= s;
    if v_stage is null then continue; end if;
    insert into public.membership_fee_notices (user_id, due_date, stage)
      select r.user_id, r.due_date, s from unnest(v_stages) s where s >= v_stage
      on conflict do nothing;
    get diagnostics v_new = row_count;
    if v_new = 0 then continue; end if;                 -- 이 단계는 이미 알렸다
    v_cnt := v_cnt + 1;
    if not (v_stage = any(v_stage_set)) then v_stage_set := v_stage_set || v_stage; end if;
    -- 이번에 내는 연차 = 납부 건수 + 1 (years 는 「시작된 연차 수」라 기준일부터 내는 해와 어긋난다)
    v_nth := coalesce(r.paid, 0) + 1;
    v_when := case when r.days_left > 0 then r.days_left || '일 남음' when r.days_left = 0 then '오늘' else abs(r.days_left) || '일 지남' end;
    v_base := case r.anchor_kind
                when 'joined' then '실제 가입일 ' || to_char(r.anchor_date, 'YYYY.MM.DD')
                when 'start'  then '첫 구매·초대 결제일 ' || to_char(r.anchor_date, 'YYYY.MM.DD')
                else '가입일 ' || coalesce(to_char(coalesce(r.anchor_date, r.joined_at), 'YYYY.MM.DD'), '?') end;
    v_stage_lbl := case v_stage when 30 then '30일 전 미리 알림' when 7 then '7일 전 알림' when 0 then '당일 알림'
                                when -7 then '7일 지남 알림' else '30일 지남 알림' end;
    v_lines := v_lines || (coalesce(nullif(r.display_name, ''), left(r.user_id::text, 8)) || ' · ' || coalesce(r.tier, '?') || ' · '
      || v_nth || '년차 연회비 ' || r.fee_hint || ' · 기준일 ' || to_char(r.due_date, 'YYYY.MM.DD') || ' (' || v_when || ')'
      || case when coalesce(r.short, 0) > 0 then ' · 부족 ' || r.short || '건' else '' end
      || E'\n  └ ' || v_base || ' + 납부 ' || coalesce(r.paid, 0) || '년'
      || case when r.implicit_first then '(첫해는 가입 때 제외)' else '' end
      || ' = ' || to_char(r.due_date, 'YYYY.MM.DD') || ' · ' || v_stage_lbl);
    v_push_lines := v_push_lines || (coalesce(nullif(r.display_name, ''), left(r.user_id::text, 8)) || ' · ' || v_nth || '년차 · '
      || to_char(r.due_date, 'YYYY.MM.DD') || ' (' || v_when || ')');
    v_members := v_members || jsonb_build_object('uid', r.user_id, 'name', r.display_name, 'tier', r.tier, 'due', r.due_date,
                                                 'days_left', r.days_left, 'stage', v_stage, 'short', r.short,
                                                 'nth', v_nth, 'paid', r.paid, 'anchor_kind', r.anchor_kind, 'anchor_date', r.anchor_date);
  end loop;
  if v_cnt = 0 then return jsonb_build_object('ok', true, 'today', v_today, 'notified', 0); end if;
  v_title := case when array_length(v_stage_set, 1) = 1 then
               case v_stage_set[1] when 30 then '💰 연회비 납부 30일 전 알림 · ' when 7 then '💰 연회비 납부 7일 전 알림 · '
                                   when 0 then '💰 오늘이 연회비 납부 기준일 · ' when -7 then '💰 연회비 기준일 7일 지남 · '
                                   else '💰 연회비 기준일 30일 지남 · ' end || v_cnt || '명'
             else '💰 연회비 납부 시기 ' || v_cnt || '명' end;
  -- 인앱 본문: 벨이 body 를 그대로 그리므로 1000자 안에서 **회원 단위**로 넣고, 넘치면 「외 N명」(중간 절단 금지). 전원은 /?feedue=1 화면과 payload.members 에
  foreach v_line in array v_lines loop
    exit when length(v_body) + length(v_line) + 1 > 940;
    v_body := v_body || case when v_body = '' then '' else E'\n' end || v_line;
    v_shown := v_shown + 1;
  end loop;
  if v_shown < v_cnt then v_body := v_body || E'\n외 ' || (v_cnt - v_shown) || '명 — 전원은 「연회비 납부 시기」 화면에서'; end if;
  v_push_body := array_to_string(v_push_lines[1:8], E'\n') || case when v_cnt > 8 then E'\n외 ' || (v_cnt - 8) || '명' else '' end;
  insert into public.notifications (user_id, type, title, body, url, payload)
  select p.id, 'membership_fee_due', v_title, v_body, '/?feedue=1',
         jsonb_build_object('today', v_today, 'count', v_cnt, 'members', v_members, 'via', 'taam_membership_fee_notify')
    from public.profiles p
   where p.role in ('superadmin', 'super_admin') and p.deleted_at is null;
  get diagnostics v_n = row_count;
  begin
    v_push := public.taam_admin_push(v_title, v_push_body, '/?feedue=1', 'mfee-' || to_char(v_today, 'YYYYMMDD'), 'admin');
  exception when others then
    v_push := jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;
  return jsonb_build_object('ok', true, 'today', v_today, 'notified', v_cnt, 'superadmins', v_n, 'push', v_push);
end $body$
$fn$;
  execute 'revoke all on function public.taam_membership_fee_notify(date) from public, anon';
  execute 'grant execute on function public.taam_membership_fee_notify(date) to authenticated';
  insert into _vrd values ('E', '✅ 교체(계산 근거)');
end $do$;

-- ── 확인 (하나로 · 건수만 — 공개 로그) ──
select 'A' as 항목, '푸시 결과 표 · 서버만 쓴다' as 내용,
       case when to_regclass('public.visit_reminder_push_log') is not null
             and exists (select 1 from pg_class c where c.oid = 'public.visit_reminder_push_log'::regclass and c.relrowsecurity)
             and not has_table_privilege('authenticated', 'public.visit_reminder_push_log', 'select')
             and not has_function_privilege('authenticated', 'public.taam_visit_reminder_push_mark(jsonb)', 'execute')
            then '✅' else '❌' end as 결과
union all select 'B', '날짜 묶음 문구 예시',
       case when public._taam_vr_day_msg(date '2026-11-13', 1,
                   '[{"ko":"히가시아자부 아마모토","n":4,"pax":8,"times":["20:30"]}]'::jsonb)->'ko'->>'title'
                 = '내일 방문 일정 — 히가시아자부 아마모토 4건 · 8명' then '✅' else '❌' end
union all select k, status, case when status like '✅%' then '✅' else '❌' end from _vrd
union all select 'D', '발송 현황 조회 — 회원·anon 막힘',
       case when to_regprocedure('public.taam_visit_reminder_status(date,text[],text[])') is not null
             and not has_function_privilege('anon', 'public.taam_visit_reminder_status(date,text[],text[])', 'execute')
             and not has_function_privilege('authenticated', 'public._taam_vr_seat_status(uuid)', 'execute')
            then '✅' else '❌' end
union all select 'ⓘ', '정보 — 30일 안 연회비 기준일 회원 수', (select count(*) from public.taam_membership_fee_due() d where d.days_left between 0 and 30)::text;
