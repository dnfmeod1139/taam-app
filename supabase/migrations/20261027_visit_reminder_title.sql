-- ═══════════════════════════════════════════════════════════════
-- 방문 리마인드 제목 — 「미토우 방문 3일 전입니다」 · 하루 전 「내일은 미토우 방문일입니다」 (2026-10-27 운영 결정)
--
-- 왜: 「예약 안내」 테스트를 받아 보고 「예약 안내라고 하지 말고 (레스토랑 이름) 방문 (날짜) 전입니다 — 그래야 리마인드가 된다」.
--   하루 전만 「1일 전」 대신 「내일」(추천안 · 운영 선택). 본문(레스토랑·날짜·시간·인원 + 매장 문구)은 그대로.
-- 무엇:
--   ① _taam_visit_remind_msg 에 일수(p_days · 기본 null) — 5 인자 판을 지우고 6 인자로(둘 다 두면 5 인자 호출이 「not unique」)
--      일수 없음(null) = 「예약 안내」 그대로 · EN 「Your visit to Mitou is in 3 days / … is tomorrow」 · JA 「味豆へのご来店まであと3日です / 明日は味豆へのご来店日です」
--      매장 이름을 전혀 모르면 이름 없이
--   ② taam_visit_reminder_notify — 라이브 본문에서 문구 호출에 일수(w.d)만 더한다(md5 가드: 20261027 「예약 안내」 판 ae6336f8… · 이미 새 판(VR_TITLE_20261027)이면 ✅ · 모르는 판 ❌ 건너뜀)
--   ③ 문구 화면 미리보기 = 하루 전 알림(내일 날짜 · 그 매장 가장 가까운 회차 시각 · 2인)
-- 회귀: bash sql/_test/t_visit_reminder_format.sh (끝부분 · 제목)
-- ═══════════════════════════════════════════════════════════════

-- ── ① 문구 만들기 — 일수 ──
drop function if exists public._taam_visit_remind_msg(jsonb, date, text, int, jsonb);
create or replace function public._taam_visit_remind_msg(p_rest jsonb, p_date date, p_time text, p_pax int, p_notes jsonb, p_days int default null)
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
  v_known boolean := nullif(btrim(p_rest->>'ko'), '') is not null or nullif(btrim(p_rest->>'en'), '') is not null or nullif(btrim(p_rest->>'ja'), '') is not null;
  ti_ko text; ti_en text; ti_ja text;
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
  -- 제목 (2026-10-27 운영 결정) — 7일·3일 전 「미토우 방문 3일 전입니다」 · 하루 전 「내일은 미토우 방문일입니다」 · 일수가 없으면(미리보기 밖) 「예약 안내」
  --   매장 이름을 모르면 이름 없이(「방문 3일 전입니다」 · 「내일은 방문일입니다」)
  if p_days is null or p_days < 1 then
    ti_ko := '예약 안내'; ti_en := 'Reservation Reminder'; ti_ja := 'ご予約のご案内';
  elsif p_days = 1 then
    ti_ko := case when v_known then '내일은 ' || r_ko || ' 방문일입니다' else '내일은 방문일입니다' end;
    ti_en := case when v_known then 'Your visit to ' || r_en || ' is tomorrow' else 'Your visit is tomorrow' end;
    ti_ja := case when v_known then '明日は' || r_ja || 'へのご来店日です' else '明日はご来店日です' end;
  else
    ti_ko := case when v_known then r_ko || ' 방문 ' || p_days || '일 전입니다' else '방문 ' || p_days || '일 전입니다' end;
    ti_en := case when v_known then 'Your visit to ' || r_en || ' is in ' || p_days || ' days' else 'Your visit is in ' || p_days || ' days' end;
    ti_ja := case when v_known then r_ja || 'へのご来店まであと' || p_days || '日です' else 'ご来店まであと' || p_days || '日です' end;
  end if;
  return jsonb_build_object(
    'ko', jsonb_build_object('title', ti_ko, 'body', b_ko),
    'en', jsonb_build_object('title', ti_en, 'body', b_en),
    'ja', jsonb_build_object('title', ti_ja, 'body', b_ja));
end $$;
revoke all on function public._taam_visit_remind_msg(jsonb, date, text, int, jsonb, int) from public, anon;

-- ── ③ 미리보기 = 하루 전 알림 ──
create or replace function public.taam_visit_notes_preview(p_rest_id text, p jsonb default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_rest jsonb; v_time text; r record;
begin
  if not public._taam_rest_note_ok(p_rest_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select jsonb_build_object('ko', nullif(btrim(to_jsonb(x)->>'name'), ''),
                            'en', nullif(btrim(to_jsonb(x)->>'name_en'), ''),
                            'ja', case when coalesce(to_jsonb(x)->>'i18n_jp_approved', '') <> 'false' then nullif(btrim(to_jsonb(x)->>'name_jp'), '') end)
    into v_rest from public.restaurants x where x.id::text = btrim(p_rest_id);
  for r in select tp.time as t from public.ticket_products tp
            where tp.rest_id::text = btrim(p_rest_id) and public.taam_visit_date(tp.date) >= (now() at time zone 'Asia/Seoul')::date
            order by public.taam_visit_date(tp.date) limit 1 loop
    v_time := r.t;
  end loop;
  return public._taam_visit_remind_msg(coalesce(v_rest, '{}'::jsonb),
                                       (now() at time zone 'Asia/Seoul')::date + 1, coalesce(nullif(btrim(v_time), ''), '18:30'), 2,
                                       coalesce(p, (select to_jsonb(n) from public.restaurant_visit_notes n where n.restaurant_id = btrim(p_rest_id)), '{}'::jsonb), 1);
end $$;
revoke all on function public.taam_visit_notes_preview(text, jsonb) from public, anon;
grant execute on function public.taam_visit_notes_preview(text, jsonb) to authenticated;

-- ── ② 리마인드 함수 — 문구 호출에 일수만 더한다 ──
drop table if exists _vrt2;
create temp table _vrt2(name text primary key, status text);
do $do$
declare v_src text; v_md5 text; v_def text; v_old text := 'w.vd, w.vtime, w.pax, to_jsonb(vn)) as i18n'; v_n int;
begin
  select p.prosrc, md5(p.prosrc), pg_get_functiondef(p.oid) into v_src, v_md5, v_def from pg_proc p where p.oid = to_regproc('public.taam_visit_reminder_notify');
  if v_src is null then
    insert into _vrt2 values ('taam_visit_reminder_notify', '❌ 라이브에 함수가 없다'); return;
  elsif v_src like '%VR_TITLE_20261027%' then
    insert into _vrt2 values ('taam_visit_reminder_notify', '✅ 이미 새 판(제목에 매장·일수)'); return;
  elsif v_md5 <> 'ae6336f8af7d8b98ded80c0708fcd42a' then
    insert into _vrt2 values ('taam_visit_reminder_notify', '❌ 라이브 본문이 「예약 안내」 판(ae6336f8…)과 다르다 — 건너뜀 (md5 ' || v_md5 || ')'); return;
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then
    insert into _vrt2 values ('taam_visit_reminder_notify', '❌ 문구 호출 자리가 ' || v_n || '곳 — 건너뜀'); return;
  end if;
  v_def := replace(v_def, v_old, 'w.vd, w.vtime, w.pax, to_jsonb(vn), w.d) as i18n   -- VR_TITLE_20261027 제목에 매장·일수');
  execute v_def;
  insert into _vrt2 values ('taam_visit_reminder_notify', '✅ 교체(제목에 매장·일수)');
end $do$;

-- ── 확인 (하나로) ──
select '①' as 항목, '제목 예시(미토우 · 3일 전 / 하루 전 / 일수 없음)' as 내용,
       case when public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 5, null, 3)->'ko'->>'title' = '미토우 방문 3일 전입니다'
             and public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 5, null, 1)->'ko'->>'title' = '내일은 미토우 방문일입니다'
             and public._taam_visit_remind_msg('{"ko":"미토우","en":"Mitou"}', date '2026-09-10', '18:30', 5, null, 1)->'en'->>'title' = 'Your visit to Mitou is tomorrow'
             and public._taam_visit_remind_msg('{"ko":"미토우"}', date '2026-09-10', '18:30', 5, null)->'ko'->>'title' = '예약 안내'
             and public._taam_visit_remind_msg('{"ko":"미토우"}', date '2026-09-10', '18:30', 5, null, 3)->'ko'->>'body' = E'[레스토랑] : 미토우\n[날짜] : 2026년 9월 10일(목)\n[시간] : 오후 6:30\n[인원] : 5'
            then '✅' else '❌' end as 결과
union all select '②', status, case when status like '✅%' then '✅' else '❌' end from _vrt2
union all select '③', '5 인자 판 없음(호출이 모호하지 않다)', case when to_regprocedure('public._taam_visit_remind_msg(jsonb,date,text,integer,jsonb)') is null then '✅' else '❌' end;
