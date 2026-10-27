-- ═══════════════════════════════════════════════════════════════
-- 방문 리마인드 문구 — 「예약 안내」 + 레스토랑 · 날짜 · 시간 · 인원 (+ 매장별 유의사항 · 안내말씀) (2026-10-27)
--
-- 왜: 「이렇게 오고 있는데 문구 수정하자」(운영 요청 2026-10-27). 종전 문구는 「내일 방문 예정입니다 / 스시 아라이 · 12:00 예약이 내일입니다.」.
--   새 문구:
--     예약 안내
--     [레스토랑] : 미토우
--     [날짜] : 2026년 9월 10일(목)
--     [시간] : 오후 6:30
--     [인원] : 5
--
--     [유의사항]
--     …매장이 적은 글…
--
--     [안내말씀]
--     …매장이 적은 글…
--   유의사항 · 안내말씀은 매장 어드민(자기 매장)·슈퍼어드민이 앱에서 적는다(「📩 방문 안내 문구」). 비어 있으면 그 칸은 안 나간다 — 지금은 넷만 나간다.
--
-- 무엇:
--   ① 표 restaurant_visit_notes(매장 id · 유의사항/안내말씀 한국어 + 영어·일본어(선택) · 적은 사람 · 시각) — 직접 접근 없음, RPC 로만
--   ② RPC taam_visit_notes_get(매장 id | null=전부 · 슈퍼어드민) · taam_visit_notes_set(매장 id, jsonb) · taam_visit_notes_preview(매장 id, jsonb)
--      권한: 슈퍼어드민·서버 또는 그 매장 어드민(taam_is_rest_admin · is_restaurant_admin_of 중 있는 것) · 칸마다 300자
--   ③ 문구 만들기 _taam_visit_remind_msg(매장 이름 ko/en/ja, 방문일, 시각, 인원, 문구) → {ko,en,ja}{title,body} — 한 곳에서만 만든다
--   ④ taam_visit_reminder_notify 교체(대상·설정·중복 규칙은 그대로 · 문구만) — 라이브 본문 md5 가 알려진 판(회원 소유 LINK- 포함 3b8771fc…)일 때만.
--      이미 새 판(VR_FMT_20261027)이면 ✅ 그대로 · 모르는 판이면 ❌ 로 건너뛴다(대시보드에서 손본 판을 덮지 않게).
--      돌려주는 줄에 i18n(세 언어)을 싣는다 — Edge notify-visit-reminder 가 그대로 푸시에 쓴다(없으면 옛 문구를 스스로 만든다).
-- 회귀: bash sql/_test/t_visit_reminder_format.sh
-- ═══════════════════════════════════════════════════════════════

-- ── ① 매장별 문구 ──
create table if not exists public.restaurant_visit_notes (
  restaurant_id text primary key,
  notice     text,
  notice_en  text,
  notice_ja  text,
  message    text,
  message_en text,
  message_ja text,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
comment on table public.restaurant_visit_notes is '방문 리마인드(예약 안내)의 매장별 [유의사항]·[안내말씀] — 매장 어드민·슈퍼어드민이 RPC 로 적는다. 2026-10-27';
alter table public.restaurant_visit_notes enable row level security;
revoke all on public.restaurant_visit_notes from anon, authenticated;

-- 권한 — 슈퍼어드민·서버(_taam_fee_caller_ok) 또는 그 매장 어드민
create or replace function public._taam_rest_note_ok(p_rest_id text)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare v boolean := false;
begin
  if coalesce(btrim(p_rest_id), '') = '' then return false; end if;
  if coalesce(public._taam_fee_caller_ok(), false) then return true; end if;
  if auth.uid() is null then return false; end if;
  if to_regprocedure('public.taam_is_rest_admin(text)') is not null then
    begin execute 'select coalesce(public.taam_is_rest_admin($1), false)' into v using btrim(p_rest_id); exception when others then v := false; end;
    if v then return true; end if;
  end if;
  if to_regprocedure('public.is_restaurant_admin_of(text)') is not null then
    begin execute 'select coalesce(public.is_restaurant_admin_of($1), false)' into v using btrim(p_rest_id); exception when others then v := false; end;
    if v then return true; end if;
  end if;
  return false;
end $$;
revoke all on function public._taam_rest_note_ok(text) from public, anon;

-- ── ③ 문구 만들기 (한 곳) ──
create or replace function public._taam_visit_remind_msg(p_rest jsonb, p_date date, p_time text, p_pax int, p_notes jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  v_mt text[]; v_h int; v_mi text; v_h12 int;
  t_ko text; t_en text; t_ja text; d_ko text; d_en text; d_ja text;
  v_dow int; v_pax text := greatest(coalesce(p_pax, 1), 1)::text;
  v_notes jsonb := coalesce(p_notes, '{}'::jsonb);
  r_ko text := nullif(btrim(p_rest->>'ko'), '');
  r_en text; r_ja text;
  n_ko text; n_en text; n_ja text; m_ko text; m_en text; m_ja text;
  b_ko text; b_en text; b_ja text;
begin
  -- 매장 이름: 그 언어 이름 → 한국어 이름 → 언어별 「예약하신 매장」(이름을 전혀 모를 때만)
  r_en := coalesce(nullif(btrim(p_rest->>'en'), ''), r_ko, 'Your reservation');
  r_ja := coalesce(nullif(btrim(p_rest->>'ja'), ''), r_ko, 'ご予約');
  r_ko := coalesce(r_ko, '예약하신 매장');
  -- 날짜 (언제나 연도 · 요일)
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
  -- 시각 — 'HH:MM' 이면 오전/오후 12시간제, 못 읽으면 적힌 그대로, 비면 줄을 뺀다
  v_mt := regexp_match(btrim(coalesce(p_time, '')), '^(\d{1,2}):(\d{2})');
  if v_mt is not null and v_mt[1]::int between 0 and 23 then
    v_h := v_mt[1]::int; v_mi := v_mt[2];
    v_h12 := case when v_h % 12 = 0 then 12 else v_h % 12 end;
    t_ko := case when v_h < 12 then '오전 ' else '오후 ' end || v_h12 || ':' || v_mi;
    t_en := v_h12 || ':' || v_mi || case when v_h < 12 then ' AM' else ' PM' end;
    t_ja := case when v_h < 12 then '午前' else '午後' end || v_h12 || ':' || v_mi;
  elsif nullif(btrim(coalesce(p_time, '')), '') is not null then
    t_ko := btrim(p_time); t_en := t_ko; t_ja := t_ko;
  end if;
  -- 매장 문구 — 언어별 칸이 비면 한국어
  n_ko := nullif(btrim(coalesce(v_notes->>'notice', '')), '');
  n_en := coalesce(nullif(btrim(coalesce(v_notes->>'notice_en', '')), ''), n_ko);
  n_ja := coalesce(nullif(btrim(coalesce(v_notes->>'notice_ja', '')), ''), n_ko);
  m_ko := nullif(btrim(coalesce(v_notes->>'message', '')), '');
  m_en := coalesce(nullif(btrim(coalesce(v_notes->>'message_en', '')), ''), m_ko);
  m_ja := coalesce(nullif(btrim(coalesce(v_notes->>'message_ja', '')), ''), m_ko);

  b_ko := '[레스토랑] : ' || r_ko || coalesce(E'\n[날짜] : ' || d_ko, '') || coalesce(E'\n[시간] : ' || t_ko, '') || E'\n[인원] : ' || v_pax
          || coalesce(E'\n\n[유의사항]\n' || n_ko, '') || coalesce(E'\n\n[안내말씀]\n' || m_ko, '');
  b_en := '[Restaurant] : ' || r_en || coalesce(E'\n[Date] : ' || d_en, '') || coalesce(E'\n[Time] : ' || t_en, '') || E'\n[Guests] : ' || v_pax
          || coalesce(E'\n\n[Notes]\n' || n_en, '') || coalesce(E'\n\n[Message]\n' || m_en, '');
  b_ja := '[レストラン] : ' || r_ja || coalesce(E'\n[日付] : ' || d_ja, '') || coalesce(E'\n[時間] : ' || t_ja, '') || E'\n[人数] : ' || v_pax
          || coalesce(E'\n\n[ご注意事項]\n' || n_ja, '') || coalesce(E'\n\n[ご案内]\n' || m_ja, '');
  return jsonb_build_object(
    'ko', jsonb_build_object('title', '예약 안내', 'body', b_ko),
    'en', jsonb_build_object('title', 'Reservation Reminder', 'body', b_en),
    'ja', jsonb_build_object('title', 'ご予約のご案内', 'body', b_ja));
end $$;
revoke all on function public._taam_visit_remind_msg(jsonb, date, text, int, jsonb) from public, anon;

-- ── ② RPC ──
-- 읽기 — 매장 하나(그 매장 어드민·슈퍼어드민) · null 이면 전부(슈퍼어드민)
create or replace function public.taam_visit_notes_get(p_rest_id text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if p_rest_id is null then
    if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
    return coalesce((select jsonb_agg(to_jsonb(n) order by n.restaurant_id) from public.restaurant_visit_notes n), '[]'::jsonb);
  end if;
  if not public._taam_rest_note_ok(p_rest_id) then raise exception 'FORBIDDEN: 이 매장의 문구는 볼 수 없습니다' using errcode = '42501'; end if;
  return coalesce((select to_jsonb(n) from public.restaurant_visit_notes n where n.restaurant_id = btrim(p_rest_id)),
                  jsonb_build_object('restaurant_id', btrim(p_rest_id)));
end $$;

-- 쓰기 — 칸마다 300자 · 전부 비우면 줄을 지운다
create or replace function public.taam_visit_notes_set(p_rest_id text, p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare k text; v jsonb := '{}'::jsonb; s text; v_any boolean := false; v_row public.restaurant_visit_notes%rowtype;
begin
  if not public._taam_rest_note_ok(p_rest_id) then raise exception 'FORBIDDEN: 이 매장의 문구는 바꿀 수 없습니다' using errcode = '42501'; end if;
  foreach k in array array['notice','notice_en','notice_ja','message','message_en','message_ja'] loop
    s := nullif(btrim(replace(coalesce(p->>k, ''), E'\r', '')), '');
    if s is not null and char_length(s) > 300 then raise exception 'TOO_LONG: % 는 300자까지입니다 (지금 %자)', k, char_length(s) using errcode = '22001'; end if;
    v := v || jsonb_build_object(k, s);
    if s is not null then v_any := true; end if;
  end loop;
  if not v_any then
    delete from public.restaurant_visit_notes where restaurant_id = btrim(p_rest_id);
    return jsonb_build_object('ok', true, 'restaurant_id', btrim(p_rest_id), 'cleared', true);
  end if;
  insert into public.restaurant_visit_notes as n (restaurant_id, notice, notice_en, notice_ja, message, message_en, message_ja, updated_by, updated_at)
  values (btrim(p_rest_id), v->>'notice', v->>'notice_en', v->>'notice_ja', v->>'message', v->>'message_en', v->>'message_ja', auth.uid(), now())
  on conflict (restaurant_id) do update
     set notice = excluded.notice, notice_en = excluded.notice_en, notice_ja = excluded.notice_ja,
         message = excluded.message, message_en = excluded.message_en, message_ja = excluded.message_ja,
         updated_by = excluded.updated_by, updated_at = now()
  returning * into v_row;
  return jsonb_build_object('ok', true, 'row', to_jsonb(v_row));
end $$;

-- 미리보기 — 화면이 서버와 같은 문구를 보여 주게(예시: 그 매장의 가장 가까운 회차 · 없으면 7일 뒤 18:30 · 2인)
create or replace function public.taam_visit_notes_preview(p_rest_id text, p jsonb default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_rest jsonb; v_date date; v_time text; r record;
begin
  if not public._taam_rest_note_ok(p_rest_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select jsonb_build_object('ko', nullif(btrim(to_jsonb(x)->>'name'), ''),
                            'en', nullif(btrim(to_jsonb(x)->>'name_en'), ''),
                            'ja', case when coalesce(to_jsonb(x)->>'i18n_jp_approved', '') <> 'false' then nullif(btrim(to_jsonb(x)->>'name_jp'), '') end)
    into v_rest from public.restaurants x where x.id::text = btrim(p_rest_id);
  for r in select public.taam_visit_date(tp.date) as d, tp.time as t from public.ticket_products tp
            where tp.rest_id::text = btrim(p_rest_id) and public.taam_visit_date(tp.date) >= (now() at time zone 'Asia/Seoul')::date
            order by 1 limit 1 loop
    v_date := r.d; v_time := r.t;
  end loop;
  return public._taam_visit_remind_msg(coalesce(v_rest, '{}'::jsonb),
                                       coalesce(v_date, (now() at time zone 'Asia/Seoul')::date + 7), coalesce(nullif(btrim(v_time), ''), '18:30'), 2,
                                       coalesce(p, (select to_jsonb(n) from public.restaurant_visit_notes n where n.restaurant_id = btrim(p_rest_id)), '{}'::jsonb));
end $$;

revoke all on function public.taam_visit_notes_get(text) from public, anon;
revoke all on function public.taam_visit_notes_set(text, jsonb) from public, anon;
revoke all on function public.taam_visit_notes_preview(text, jsonb) from public, anon;
grant execute on function public.taam_visit_notes_get(text) to authenticated;
grant execute on function public.taam_visit_notes_set(text, jsonb) to authenticated;
grant execute on function public.taam_visit_notes_preview(text, jsonb) to authenticated;

-- ── ④ 리마인드 함수 — 문구만 바꾼다 (md5 가드) ──
drop table if exists _vrf;
create temp table _vrf(name text primary key, status text);

do $do$
declare v_live text; v_src text;
begin
  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regproc('public.taam_visit_reminder_notify');
  if v_live is null then
    insert into _vrf values ('taam_visit_reminder_notify', '❌ 라이브에 함수가 없다 — sql/visit_reminder.sql 먼저');
  elsif v_src like '%VR_FMT_20261027%' then
    insert into _vrf values ('taam_visit_reminder_notify', '✅ 이미 새 판(예약 안내)');
  elsif v_live = '3b8771fc6bde3213d6d63f5e7be4c4d7' then
    execute $fn$
create or replace function public.taam_visit_reminder_notify()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $b$
declare v_cnt int := 0; v_rows jsonb;
begin
  -- VR_FMT_20261027 — 문구: 「예약 안내」 + 레스토랑·날짜·시간·인원 (+ 매장 유의사항·안내말씀). 대상·설정·중복 규칙은 20261019 판 그대로
  with due as (
    select t.id            as ticket_id,
           t.user_id,
           coalesce(nullif(btrim(t.restaurant_name), ''), '예약하신 매장') as rest_nm,
           nullif(btrim(t.restaurant_name), '')                            as rest_raw,
           coalesce(nullif(btrim(t.visit_time), ''), '')                   as vtime,
           public.taam_visit_days_left(t.reservation_date)                 as d,
           public.taam_visit_date(t.reservation_date)                      as vd,
           greatest(coalesce(t.party_size, 1), 1)                          as pax,
           coalesce(nullif(btrim(t.restaurant_id::text), ''),
                    (select tp.rest_id::text from public.ticket_products tp where tp.id::text = t.ticket_product_id::text limit 1)) as rest_id
      from public.tickets t
     where t.user_id is not null
       -- 확정된 예약만. 'hold'(좌석 잡아둔 미결제)·'cancelled'·'expired' 는 제외한다.
       and lower(coalesce(t.status,'')) = 'active'
       -- 어드민이 잡은 좌석(KSK- · 비회원 LINK- · MAN-)은 회원의 예약이 아니다. 회원 소유 LINK-(memberUid)는 회원의 예약이다
       and coalesce(t.purchase_id, '') not like 'KSK-%'
       and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
       and coalesce(t.purchase_id, '') not like 'MAN-%'
       and not coalesce((t.extra_data ? 'kashikiri') or ((t.extra_data ? 'linkInvite') and nullif(t.extra_data->>'memberUid', '') is null) or (t.extra_data ? 'manualEntry'), false)
  ), pick as (
    select * from due where d in (1, 3, 7)
  ), want as (
    -- 회원이 켜 둔 것만. 설정을 안 만졌으면 3일·1일만 보낸다(7일은 기본 꺼짐). boolean 이 아닌 값은 기본값으로 본다
    select k.*
      from pick k
      join public.profiles p on p.id = k.user_id
     where coalesce(
             case when jsonb_typeof(p.notif_prefs -> ('remind' || k.d::text)) = 'boolean'
                  then (p.notif_prefs ->> ('remind' || k.d::text))::boolean else null end,
             k.d in (1, 3)
           ) is true
  ), msg as (
    -- 문구는 _taam_visit_remind_msg 한 곳에서 — 세 언어 · 매장 이름 영어/일본어 · 매장 문구
    select w.*,
           public._taam_visit_remind_msg(
             -- 티켓에 적힌 이름 → 매장 등록 이름 · 일본어는 승인 안 된(i18n_jp_approved=false) 이름을 쓰지 않는다(앱 _tbRestName 과 같다)
             jsonb_build_object('ko', coalesce(w.rest_raw, nullif(btrim(to_jsonb(r)->>'name'), '')),
                                'en', nullif(btrim(to_jsonb(r)->>'name_en'), ''),
                                'ja', case when coalesce(to_jsonb(r)->>'i18n_jp_approved', '') <> 'false' then nullif(btrim(to_jsonb(r)->>'name_jp'), '') end),
             w.vd, w.vtime, w.pax, to_jsonb(vn)) as i18n
      from want w
      left join public.restaurants r on r.id::text = w.rest_id
      left join public.restaurant_visit_notes vn on vn.restaurant_id = w.rest_id
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select m.user_id,
           'visit_reminder',
           m.i18n->'ko'->>'title',
           m.i18n->'ko'->>'body',
           '/',
           jsonb_build_object('ticket_id', m.ticket_id, 'days', m.d,
                              'kind', 'visit_reminder', 'fmt', 'v2',
                              'rest', m.rest_nm, 'time', m.vtime,
                              'date', to_char(m.vd, 'YYYY-MM-DD'), 'pax', m.pax, 'rest_id', m.rest_id,
                              'i18n', m.i18n)
      from msg m
     -- 같은 티켓·같은 일수로는 한 번만. 하루가 지나면 일수가 달라져 다시 나간다.
     where not exists (
       select 1 from public.notifications n
        where n.user_id = m.user_id
          and n.type = 'visit_reminder'
          and n.payload ->> 'ticket_id' = m.ticket_id::text
          -- 글자로 비교한다 — 회원은 자기 알림 줄의 payload 를 쓸 수 있어(notif_insert·notif_update_own) days 에 'x' 를 넣으면
          --   ::int 가 터져 그날 리마인드 전체(+ 비회원 알림톡)가 멈췄다 (2026-10-27 적대 리뷰 · 20261019 판부터)
          and n.payload ->> 'days' = m.d::text)
    -- 이번 실행이 **실제로 넣은 행만** 돌려받는다(시간 창으로 다시 긁으면 푸시가 두 번 간다)
    returning id, user_id, title, body, url, payload
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id',        i.id,
           'user_id',   i.user_id,
           'title',     i.title,
           'body',      i.body,
           'url',       i.url,
           'days',      (i.payload ->> 'days')::int,
           'ticket_id', i.payload ->> 'ticket_id',
           'rest',      i.payload ->> 'rest',
           'vtime',     i.payload ->> 'time',
           'i18n',      i.payload -> 'i18n'
         )), '[]'::jsonb)
    into v_cnt, v_rows
    from ins i;

  return jsonb_build_object('made', v_cnt, 'rows', v_rows);
end;
$b$
    $fn$;
    execute 'revoke all on function public.taam_visit_reminder_notify() from public';
    insert into _vrf values ('taam_visit_reminder_notify', '✅ 교체(예약 안내 문구)');
  else
    insert into _vrf values ('taam_visit_reminder_notify', '❌ 라이브 본문이 알려진 판(3b8771fc…)과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  end if;
end $do$;

-- ── 확인 (하나로) ──
select '①' as 항목, '매장 문구 표' as 내용, case when to_regclass('public.restaurant_visit_notes') is not null then '✅' else '❌' end as 결과
union all select '②', 'RPC 셋(get·set·preview)', case when to_regprocedure('public.taam_visit_notes_get(text)') is not null and to_regprocedure('public.taam_visit_notes_set(text,jsonb)') is not null and to_regprocedure('public.taam_visit_notes_preview(text,jsonb)') is not null then '✅' else '❌' end
union all select '③', '문구 예시(미토우 2026-09-10 18:30 5인)', case when public._taam_visit_remind_msg('{"ko":"미토우"}', date '2026-09-10', '18:30', 5, null)->'ko'->>'body'
                    = E'[레스토랑] : 미토우\n[날짜] : 2026년 9월 10일(목)\n[시간] : 오후 6:30\n[인원] : 5' then '✅' else '❌' end
union all select '④', status, case when status like '✅%' then '✅' else '❌' end from _vrf
union all select '⑤', '의존: 권한 함수(_taam_fee_caller_ok · 매장 어드민 판정)', case when to_regproc('public._taam_fee_caller_ok') is not null
                    and (to_regprocedure('public.taam_is_rest_admin(text)') is not null or to_regprocedure('public.is_restaurant_admin_of(text)') is not null) then '✅' else '❌' end;
