-- ═══════════════════════════════════════════════════════════════
-- 취소 마감일(D-31) 당일 리마인드 — 회원 (2026-11-07 운영 요청)
--
-- 왜: 「티켓 규정상 취소 시 위약금을 무는 때부터 … 마감 당일 알림을 지금 시스템 그대로 두고 추가」 · 회원 기본 켬.
--   티켓 규정(legal/refund.html 제3조 2항): 방문 31일 전(D-31)까지 취소 → 대행비 제외 환불 · D-30 부터 환불 없음.
--   서버 환불 한도(taam_refund_cap)도 같은 날짜로 센다 — 방문일(_taam_refund_visit_date(reservation_date)) − 오늘(KST) ≥ 31.
--   그래서 「방문일 − 오늘 = 31」인 날이 환불받고 취소할 수 있는 마지막 날이다. 그날 오전 11시(기존 리마인드 크론) 회원에게 알린다.
-- 무엇:
--   ① _taam_cancel_deadline_msg(rest, 방문일, 시각, 인원, 결제 링크 여부) — 세 언어 문구.
--      제목 「미토우 · 오늘이 환불 가능한 마지막 날입니다」 · 본문 = 방문 리마인드와 같은 네 줄([레스토랑]·[날짜]·[시간]·[인원]) +
--      「오늘(11월 17일) 밤 12시(한국 시간)까지 취소하시면 대행비를 제외한 금액이 환불됩니다. / 내일부터는 취소해도 환불되지 않습니다.」
--      결제 링크로 산 예약(LINK- · 카드)은 앱에서 직접 취소하지 않으므로 「취소는 TAAM 에 문의해 주세요」를 덧붙인다.
--   ② _taam_cancel_deadline_remind() — 대상: 회원 본인의 확정(active) 예약 — 방문 리마인드와 같은 거름(운영 행 KSK-·MAN-·INVH-·비회원 LINK- 제외)
--        + 이미 TAAM 이 반환·환불을 처리한 예약(조기 반환 등 · super_admin_processed_at / deposit_return) 제외 — 회원 취소로 더 돌려받을 돈이 없다
--        + 패키지 줄(extra_data.pkg) 제외 — 패키지는 통째로만 취소되고 줄마다 마감이 달라 따로 다룬다
--      설정: notif_prefs.remind31(boolean 이 아니면 기본 켬) · all=false 면 보내지 않는다.
--      중복: 같은 티켓·같은 마감일은 한 번(글자 비교 — payload 는 회원이 쓸 수 있는 칸이다) · 방문일이 바뀌면 새 마감일로 다시.
--      알림함: type visit_reminder · payload kind cancel_deadline · days 31 · url /?open_ticket_hist=1(누르면 티켓 구매 내역 — 취소 버튼이 거기 있다)
--   ③ taam_visit_reminder_notify — 라이브 본문의 마지막 return 앞에서 ② 를 불러 돌려주는 줄에 더한다.
--      Edge(notify-visit-reminder)가 그대로 푸시한다 — category remind31 · tag visit-reminder-cd-<티켓>.
--      ② 가 실패해도 방문 리마인드·슈퍼어드민 몫은 그대로 나간다(예외 블록 · warning).
--      가드: 슈퍼어드민 전 일정 판(VR_ADMIN_20261027 · md5 052a4a4b…)일 때만 · 이미 새 판(VR_DEADLINE_20261107)이면 ✅ · 모르는 판 ❌ 건너뜀.
-- 방문 리마인드(7·3·1일 전 · 회원 설정 그대로)와 슈퍼어드민 몫은 바뀌지 않는다. 돈·티켓은 건드리지 않는다(알림만).
-- 회귀: bash sql/_test/t_cancel_deadline.sh
-- ═══════════════════════════════════════════════════════════════

-- ── ① 문구 ──
create or replace function public._taam_cancel_deadline_msg(p_rest jsonb, p_vd date, p_vtime text, p_pax int, p_link boolean)
returns jsonb
language plpgsql immutable
as $$
declare
  base jsonb; dl date;
  n_ko text; n_en text; n_ja text;
  a_ko text; a_en text; a_ja text;
begin
  if p_vd is null then return null; end if;
  dl := p_vd - 31;
  base := public._taam_visit_remind_msg(p_rest, p_vd, p_vtime, p_pax, null, 31);
  n_ko := left(nullif(btrim(coalesce(p_rest->>'ko', '')), ''), 60);
  n_en := left(coalesce(nullif(btrim(coalesce(p_rest->>'en', '')), ''), n_ko), 60);
  n_ja := left(coalesce(nullif(btrim(coalesce(p_rest->>'ja', '')), ''), n_ko), 60);
  a_ko := '오늘(' || extract(month from dl)::int || '월 ' || extract(day from dl)::int || '일) 밤 12시(한국 시간)까지 취소하시면 대행비를 제외한 금액이 환불됩니다.'
          || E'\n' || '내일부터는 취소해도 환불되지 않습니다.'
          || case when coalesce(p_link, false) then E'\n' || '취소는 TAAM 에 문의해 주세요.' else '' end;
  a_en := 'Cancel by midnight today (' || to_char(dl, 'Mon FMDD') || ', Korea time) for a refund excluding the reservation service fee.'
          || E'\n' || 'From tomorrow, cancellations are non-refundable.'
          || case when coalesce(p_link, false) then E'\n' || 'To cancel, please contact TAAM.' else '' end;
  a_ja := '本日（' || extract(month from dl)::int || '月' || extract(day from dl)::int || '日）24時（日本・韓国時間）までにキャンセルされた場合、予約代行手数料を除いた金額を返金いたします。'
          || E'\n' || '明日以降のキャンセルは返金されません。'
          || case when coalesce(p_link, false) then E'\n' || 'キャンセルはTAAMまでお問い合わせください。' else '' end;
  return jsonb_build_object(
    'ko', jsonb_build_object('title', coalesce(n_ko || ' · ', '') || '오늘이 환불 가능한 마지막 날입니다',
                             'body', coalesce(base->'ko'->>'body', '') || E'\n\n' || a_ko),
    'en', jsonb_build_object('title', coalesce(n_en || ' · ', '') || 'Today is the last day to cancel with a refund',
                             'body', coalesce(base->'en'->>'body', '') || E'\n\n' || a_en),
    'ja', jsonb_build_object('title', coalesce(n_ja || ' · ', '') || '本日が返金可能な最終日です',
                             'body', coalesce(base->'ja'->>'body', '') || E'\n\n' || a_ja));
end $$;
revoke all on function public._taam_cancel_deadline_msg(jsonb, date, text, int, boolean) from public, anon;

-- ── ② 회원 몫 ──
create or replace function public._taam_cancel_deadline_remind()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_cnt int := 0; v_rows jsonb; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  with due as (
    select t.id                                                        as ticket_id,
           t.user_id,
           nullif(btrim(t.restaurant_name), '')                        as rest_raw,
           coalesce(nullif(btrim(t.visit_time), ''), '')               as vtime,
           -- 환불 한도(taam_refund_cap)와 같은 날짜 — 마감을 알리는 날과 실제로 환불이 끊기는 날이 어긋나지 않게
           public._taam_refund_visit_date(t.reservation_date)          as vd,
           greatest(coalesce(t.party_size, 1), 1)                      as pax,
           coalesce(nullif(btrim(t.restaurant_id::text), ''),
                    (select tp.rest_id::text from public.ticket_products tp where tp.id::text = t.ticket_product_id::text limit 1)) as rest_id,
           (coalesce(t.purchase_id, '') like 'LINK-%')                 as is_link
      from public.tickets t
     where t.user_id is not null
       and lower(coalesce(t.status, '')) = 'active'
       -- 방문 리마인드와 같은 거름 — 어드민이 잡은 좌석(KSK- · 비회원 LINK- · MAN- · 보낸 사람의 초대 홀드)은 회원의 예약이 아니다
       and coalesce(t.purchase_id, '') not like 'KSK-%'
       and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
       and coalesce(t.purchase_id, '') not like 'MAN-%'
       and coalesce(t.purchase_id, '') not like 'INVH-%'
       and not coalesce((t.extra_data ? 'kashikiri') or ((t.extra_data ? 'linkInvite') and nullif(t.extra_data->>'memberUid', '') is null)
                        or (t.extra_data ? 'manualEntry'), false)
       -- TAAM 이 이미 반환·환불을 처리한 예약(조기 반환 등) — 회원 취소로 더 돌려받을 돈이 없다(서버가 막는다)
       and not coalesce((t.extra_data ? 'super_admin_processed_at') or (t.extra_data ? 'deposit_return'), false)
       -- 패키지 줄 — 통째로만 취소되고 줄마다 마감이 다르다
       and not coalesce(t.extra_data ? 'pkg', false)
  ), pick as (
    select * from due where vd is not null and vd - v_today = 31
  ), want as (
    -- 기본 켬 — 회원이 「취소 마감일 알림」을 끈 것(remind31=false)과 알림 전체를 끈 것(all=false)만 뺀다
    select k.*
      from pick k
      join public.profiles p on p.id = k.user_id
     where coalesce(case when jsonb_typeof(p.notif_prefs -> 'remind31') = 'boolean' then (p.notif_prefs ->> 'remind31')::boolean end, true) is true
       and coalesce(case when jsonb_typeof(p.notif_prefs -> 'all') = 'boolean' then (p.notif_prefs ->> 'all')::boolean end, true) is true
       and coalesce(to_jsonb(p)->>'deleted_at', '') = ''
  ), msg as (
    select w.*,
           public._taam_cancel_deadline_msg(
             -- 티켓에 적힌 이름 → 매장 등록 이름 · 일본어는 승인 안 된(i18n_jp_approved=false) 이름을 쓰지 않는다(방문 리마인드와 같다)
             jsonb_build_object('ko', coalesce(w.rest_raw, nullif(btrim(to_jsonb(r)->>'name'), '')),
                                'en', nullif(btrim(to_jsonb(r)->>'name_en'), ''),
                                'ja', case when coalesce(to_jsonb(r)->>'i18n_jp_approved', '') <> 'false' then nullif(btrim(to_jsonb(r)->>'name_jp'), '') end),
             w.vd, w.vtime, w.pax, w.is_link) as i18n
      from want w
      left join public.restaurants r on r.id::text = w.rest_id
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select m.user_id, 'visit_reminder', m.i18n->'ko'->>'title', m.i18n->'ko'->>'body', '/?open_ticket_hist=1',
           jsonb_build_object('kind', 'cancel_deadline', 'fmt', 'v2', 'ticket_id', m.ticket_id, 'days', 31,
                              'deadline', to_char(m.vd - 31, 'YYYY-MM-DD'), 'date', to_char(m.vd, 'YYYY-MM-DD'),
                              'rest', coalesce(m.rest_raw, ''), 'time', m.vtime, 'pax', m.pax, 'rest_id', m.rest_id,
                              'link', m.is_link, 'i18n', m.i18n)
      from msg m
     where m.i18n is not null
       -- 같은 티켓·같은 마감일은 한 번 — 글자 비교(회원은 자기 알림 줄의 payload 를 쓸 수 있다 · ::cast 금지)
       and not exists (
         select 1 from public.notifications n
          where n.user_id = m.user_id
            and n.type = 'visit_reminder'
            and n.payload ->> 'kind' = 'cancel_deadline'
            and n.payload ->> 'ticket_id' = m.ticket_id::text
            and n.payload ->> 'deadline' = to_char(m.vd - 31, 'YYYY-MM-DD'))
    -- 이번 실행이 실제로 넣은 행만 돌려받는다(시간 창으로 다시 긁으면 푸시가 두 번 간다)
    returning id, user_id, title, body, url, payload
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'user_id', i.user_id, 'title', i.title, 'body', i.body, 'url', i.url,
           'days', 31,                                          -- Edge 가 category remind31 로 보낸다(send-push 가 그 설정을 한 번 더 본다)
           'ticket_id', 'cd-' || (i.payload ->> 'ticket_id'),   -- Edge 의 푸시 tag(visit-reminder-cd-…) — 방문 리마인드와 겹치지 않게
           'rest', i.payload ->> 'rest', 'vtime', i.payload ->> 'time', 'i18n', i.payload -> 'i18n')), '[]'::jsonb)
    into v_cnt, v_rows
    from ins i;
  return jsonb_build_object('made', v_cnt, 'rows', v_rows);
end $$;
revoke all on function public._taam_cancel_deadline_remind() from public, anon, authenticated;

-- ── ③ 리마인드 함수 끝에 ② 를 붙인다 ──
drop table if exists _cdl;
create temp table _cdl(name text primary key, status text);
do $do$
declare v_src text; v_md5 text; v_def text; n1 int; n2 int;
  a_decl text := $s$v_adm jsonb;   -- VR_ADMIN_20261027 슈퍼어드민 전 일정$s$;
  a_ret  text := $s$  return jsonb_build_object('made', v_cnt + coalesce((v_adm->>'made')::int, 0),
                            'rows', coalesce(v_rows, '[]'::jsonb) || coalesce(v_adm->'rows', '[]'::jsonb),
                            'admin_made', coalesce((v_adm->>'made')::int, 0),
                            'admin_skipped', coalesce((v_adm->>'skipped')::int, 0));$s$;
begin
  select p.prosrc, md5(p.prosrc), pg_get_functiondef(p.oid) into v_src, v_md5, v_def from pg_proc p where p.oid = to_regproc('public.taam_visit_reminder_notify');
  if v_src is null then insert into _cdl values ('taam_visit_reminder_notify', '❌ 라이브에 함수가 없다'); return; end if;
  if v_src like '%VR_DEADLINE_20261107%' then insert into _cdl values ('taam_visit_reminder_notify', '✅ 이미 새 판(취소 마감일)'); return; end if;
  if v_md5 <> '052a4a4bd7fe297529b982bb446e9a45' then
    insert into _cdl values ('taam_visit_reminder_notify', '❌ 라이브 본문이 슈퍼어드민 전 일정 판(052a4a4b…)과 다르다 — 건너뜀 (md5 ' || v_md5 || ')'); return;
  end if;
  n1 := (length(v_def) - length(replace(v_def, a_decl, ''))) / length(a_decl);
  n2 := (length(v_def) - length(replace(v_def, a_ret, ''))) / length(a_ret);
  if n1 <> 1 or n2 <> 1 then insert into _cdl values ('taam_visit_reminder_notify', '❌ 붙일 자리를 못 찾음(' || n1 || '·' || n2 || ') — 건너뜀'); return; end if;
  v_def := replace(v_def, a_decl, $s$v_adm jsonb; v_cdl jsonb;   -- VR_ADMIN_20261027 슈퍼어드민 전 일정 · VR_DEADLINE_20261107 취소 마감일$s$);
  v_def := replace(v_def, a_ret,
$s$  -- VR_DEADLINE_20261107 회원: 취소 마감일(방문 31일 전 · 환불받고 취소할 수 있는 마지막 날) 당일 — 「오늘이 환불 가능한 마지막 날입니다」.
  --   방문 리마인드(7·3·1일 전)와 따로 · 실패해도 위 리마인드는 그대로 나간다(이 블록만 되돌린다)
  begin
    v_cdl := public._taam_cancel_deadline_remind();
  exception when others then
    raise warning 'cancel deadline reminder failed: %', sqlerrm;
    v_cdl := null;
  end;
  return jsonb_build_object('made', v_cnt + coalesce((v_adm->>'made')::int, 0) + coalesce((v_cdl->>'made')::int, 0),
                            'rows', coalesce(v_rows, '[]'::jsonb) || coalesce(v_cdl->'rows', '[]'::jsonb) || coalesce(v_adm->'rows', '[]'::jsonb),
                            'admin_made', coalesce((v_adm->>'made')::int, 0),
                            'admin_skipped', coalesce((v_adm->>'skipped')::int, 0),
                            'deadline_made', coalesce((v_cdl->>'made')::int, 0));$s$);
  execute v_def;
  insert into _cdl values ('taam_visit_reminder_notify', '✅ 교체(취소 마감일 붙임)');
end $do$;

-- ── 확인 (하나로 · 건수만 — 공개 로그) ──
select '①' as 항목, '문구: 제목 · 본문 네 줄 + 마감 안내(예시 미토우 2026-12-18 19:30 3인 → 마감 11월 17일)' as 내용,
       case when public._taam_cancel_deadline_msg('{"ko":"미토우","en":"Mitou","ja":"味豆"}', date '2026-12-18', '19:30', 3, false)->'ko'->>'title'
                 = '미토우 · 오늘이 환불 가능한 마지막 날입니다'
             and public._taam_cancel_deadline_msg('{"ko":"미토우","en":"Mitou","ja":"味豆"}', date '2026-12-18', '19:30', 3, false)->'ko'->>'body'
                 = E'[레스토랑] : 미토우\n[날짜] : 2026년 12월 18일(금)\n[시간] : 오후 7:30\n[인원] : 3\n\n오늘(11월 17일) 밤 12시(한국 시간)까지 취소하시면 대행비를 제외한 금액이 환불됩니다.\n내일부터는 취소해도 환불되지 않습니다.'
             and public._taam_cancel_deadline_msg('{"ko":"미토우","en":"Mitou"}', date '2026-12-18', '19:30', 3, false)->'en'->>'body' like '%Cancel by midnight today (Nov 17, Korea time)%'
            then '✅' else '❌' end as 결과
union all select '②', status, case when status like '✅%' then '✅' else '❌' end from _cdl
union all select '③', '의존: 환불 날짜 함수(_taam_refund_visit_date) · 방문 문구 함수(_taam_visit_remind_msg)',
       case when to_regproc('public._taam_refund_visit_date') is not null and to_regproc('public._taam_visit_remind_msg') is not null then '✅' else '❌ 없음' end
union all
select '④', '앞으로 30일 안에 마감일이 오는 회원 예약 수(날짜·이름 없음): ' ||
       (select count(*) from public.tickets t
         where t.user_id is not null and lower(coalesce(t.status, '')) = 'active'
           and coalesce(t.purchase_id, '') !~ '^(KSK|MAN|INVH)-'
           and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
           and not coalesce((t.extra_data ? 'super_admin_processed_at') or (t.extra_data ? 'deposit_return') or (t.extra_data ? 'pkg'), false)
           and public._taam_refund_visit_date(t.reservation_date) - (now() at time zone 'Asia/Seoul')::date between 31 and 61), 'ⓘ';
