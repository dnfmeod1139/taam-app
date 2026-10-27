-- ═══════════════════════════════════════════════════════════════
-- 방문 리마인드 — 슈퍼어드민은 캘린더의 전 일정을 받는다 (2026-10-27 운영 요청)
--
-- 왜: 「티켓 캘린더에 우댕으로 수동 추가하는 건 내가 가는 일정이다 — 슈퍼어드민 계정으로 나도 알림 받게 · 슈퍼어드민은 전 일정 리마인드」.
--   회원 리마인드는 회원 본인 예약만 돈다 — 수동 추가(MAN- 좌석 · daegwan_manual 기록)·정산(KSK-)·비회원 링크(LINK-)는 소유자가 어드민이라 빠졌다.
-- 무엇:
--   ① _taam_visit_reminder_admin() — 슈퍼어드민마다, 캘린더의 일정 하나마다 회원과 같은 모양의 리마인드 한 줄
--      일정 = tickets 의 확정(active)·수동(manual) 행 전부(회원 구매 · 초대 · 결제 링크 · 정산 · 수동 예약 — 홀드·취소·만료·확정 대기 제외)
--             + 결제된 초대 중 좌석 행이 없는 것(매진 회차·회차 없는 날로 보낸 초대 — 캘린더는 초대로 보여 준다)
--             + daegwan_manual 기록(날짜만 · 시각 없음)
--      테스트 계정이 회원으로 산 것은 뺀다(운영 행 KSK-/LINK-/MAN- 은 소유자가 어드민이라 그대로 센다)
--      언제 = 슈퍼어드민 본인의 알림 설정(remind7/3/1 · 기본 3일·하루 전) · 문구 = 「미토우 방문 3일 전입니다」(하루 전 「내일은 …」) + 본문 넷 + **[예약자] : 이름** + 매장 문구
--      중복: 같은 일정·같은 일수는 한 번(슈퍼어드민이 회원으로 산 티켓은 회원 리마인드가 이미 보냈으니 건너뛴다) · 글자 비교(payload 는 회원이 쓸 수 있는 칸)
--            회원이 taam_notify_admins 로 꽂은 줄(via)은 세지 않는다 · 한 번에 슈퍼어드민마다 50건까지(넘친 수는 admin_skipped + 알림함 한 줄)
--   ② taam_visit_reminder_notify — 라이브 본문 끝에서 ① 을 불러 돌려주는 줄에 더한다(Edge 가 그대로 푸시 · Edge 변경 없음).
--      ① 이 실패해도 회원 리마인드는 그대로 나간다(예외 블록 · warning). 가드: 「제목에 매장·일수」 판(VR_TITLE_20261027 · md5 3e902422…)일 때만 · 이미 새 판(VR_ADMIN_20261027)이면 ✅ · 모르는 판 ❌ 건너뜀
-- 회원에게 가는 것은 바뀌지 않는다. 회귀: bash sql/_test/t_visit_reminder_admin.sh
-- ═══════════════════════════════════════════════════════════════

-- 본문에 [예약자] 줄을 넣는다 — 넷째 줄([인원]) 뒤 · 매장 문구([유의사항]·[안내말씀]) 앞
create or replace function public._taam_vr_add_who(p jsonb, p_who text)
returns jsonb
language plpgsql immutable
as $$
declare k text; lb text; b text; pos int; v_out jsonb := p; v_who text := left(nullif(btrim(coalesce(p_who, '')), ''), 60);
begin
  if p is null or v_who is null then return p; end if;
  foreach k in array array['ko','en','ja'] loop
    if jsonb_typeof(p->k) = 'object' and (p->k->>'body') is not null then
      lb := case k when 'ko' then '[예약자] : ' when 'en' then '[Name] : ' else '[ご予約者] : ' end;
      b := p->k->>'body'; pos := position(E'\n\n' in b);
      b := case when pos > 0 then substr(b, 1, pos - 1) || E'\n' || lb || v_who || substr(b, pos) else b || E'\n' || lb || v_who end;
      v_out := jsonb_set(v_out, array[k, 'body'], to_jsonb(b));
    end if;
  end loop;
  return v_out;
end $$;
revoke all on function public._taam_vr_add_who(jsonb, text) from public, anon;

-- ── ① 슈퍼어드민 몫 ──
create or replace function public._taam_visit_reminder_admin()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_cnt int := 0; v_rows jsonb; v_skip int := 0; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  with sa as (
    select p.id, coalesce(to_jsonb(p)->'notif_prefs', '{}'::jsonb) as np
      from public.profiles p
     where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = ''
  ), ent as (
    -- 좌석 행 — 확정·수동만(홀드 PAYH/INVH/LINK 결제 전 · 취소 · 만료 · 게스트석 확정 대기 제외)
    select 't:' || t.id::text                                          as rkey,
           t.id::text                                                  as ticket_id,
           null::text                                                  as manual_id,
           nullif(btrim(t.restaurant_name), '')                        as rest_raw,
           coalesce(nullif(btrim(t.visit_time), ''), '')               as vtime,
           public.taam_visit_date(t.reservation_date)                  as vd,
           greatest(coalesce(t.party_size, 1), 1)                      as pax,
           coalesce(nullif(btrim(t.restaurant_id::text), ''),
                    (select tp.rest_id::text from public.ticket_products tp where tp.id::text = t.ticket_product_id::text limit 1)) as rest_id,
           coalesce(nullif(btrim(t.buyer_name), ''), nullif(btrim(pu.display_name), ''), '-') as who
      from public.tickets t
      left join public.profiles pu on pu.id = t.user_id
     where lower(coalesce(t.status, '')) in ('active', 'manual')
       and not (coalesce(to_jsonb(pu)->>'is_test', '') = 'true' and coalesce(t.purchase_id, '') !~ '^(KSK|LINK|MAN)-')
    union all
    -- 결제된 초대 중 좌석 행이 없는 것 — 매진 회차·회차 없는 날로 보낸 초대(「연결 안 함」)는 결제돼도 티켓 행이 안 생긴다. 캘린더는 초대로 보여 준다
    select 'i:' || i.id::text, null, null,
           nullif(btrim(i.restaurant_name), ''), coalesce(nullif(btrim(i.visit_time), ''), ''),
           public.taam_visit_date(i.visit_date), greatest(coalesce(i.pax, 1), 1),
           coalesce(nullif(btrim(i.restaurant_id::text), ''),
                    (select tp.rest_id::text from public.ticket_products tp where tp.id::text = i.ticket_product_id::text limit 1)),
           coalesce(nullif(btrim(pi.display_name), ''), '-')
      from public.reservation_invites i
      left join public.profiles pi on pi.id = i.invitee_user_id
     where lower(coalesce(i.status, '')) = 'paid'
       and coalesce(to_jsonb(pi)->>'is_test', '') <> 'true'
       -- 좌석 행이 한 번이라도 있었으면(취소·반환 포함) 뺀다 — 결제 뒤 반환·환불하면 좌석만 cancelled 가 되고 초대는 paid 로 남는다(적대 리뷰) · 보낸 사람의 홀드(INVH-)는 좌석이 아니다
       and not exists (select 1 from public.tickets t
                        where coalesce(t.purchase_id, '') not like 'INVH-%'
                          and (t.extra_data->>'inviteId' = i.id::text
                               or (t.extra_data->>'inviteId' is null and t.purchase_id like 'INV-' || left(i.id::text, 8) || '-%')))
    union all
    -- 수동 기록(좌석 연동 없음) — 날짜만
    select 'm:' || m.id::text, null, m.id::text,
           nullif(btrim(coalesce(to_jsonb(m)->>'venue_name', '')), ''), '', m.ymd, greatest(coalesce(m.pax, 1), 1),
           nullif(btrim(coalesce(m.venue_id::text, '')), ''), coalesce(nullif(btrim(m.name), ''), '-')
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
    -- 같은 일정·같은 일수는 한 번 — 슈퍼어드민이 회원으로 산 티켓은 회원 리마인드 줄(ticket_id)이 이미 있다 · 글자 비교
    --   회원이 taam_notify_admins 로 꽂은 줄(via)은 세지 않는다 — 꽂아서 슈퍼어드민 리마인드를 막을 수 있었다(적대 리뷰) · rkey 는 서버가 적은 슈퍼어드민 줄(admin)만
    select w.*, row_number() over (partition by w.admin_id order by w.vd, w.d, w.vtime, w.rkey) as rn
      from want w
     where not exists (
       select 1 from public.notifications n
        where n.user_id = w.admin_id
          and n.type = 'visit_reminder'
          and n.payload ->> 'days' = w.d::text
          and coalesce(n.payload ->> 'via', '') <> 'taam_notify_admins'
          and ((n.payload ->> 'rkey' = w.rkey and n.payload ->> 'admin' = 'true')
               or (w.ticket_id is not null and n.payload ->> 'ticket_id' = w.ticket_id)))
  ), msg as (
    -- 한 번에 슈퍼어드민마다 50건까지 — 수동 기록이 대량으로 들어와도 그날 회원·손님 리마인드(Edge 의 뒤 순서)가 밀리지 않게
    select f.*,
           public._taam_vr_add_who(
             public._taam_visit_remind_msg(
               jsonb_build_object('ko', coalesce(f.rest_raw, nullif(btrim(to_jsonb(r)->>'name'), '')),
                                  'en', nullif(btrim(to_jsonb(r)->>'name_en'), ''),
                                  'ja', case when coalesce(to_jsonb(r)->>'i18n_jp_approved', '') <> 'false' then nullif(btrim(to_jsonb(r)->>'name_jp'), '') end),
               f.vd, f.vtime, f.pax, to_jsonb(vn), f.d),
             f.who) as i18n
      from fresh f
      left join public.restaurants r on r.id::text = f.rest_id
      left join public.restaurant_visit_notes vn on vn.restaurant_id = f.rest_id
     where f.rn <= 50
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select m.admin_id, 'visit_reminder', m.i18n->'ko'->>'title', m.i18n->'ko'->>'body', '/',
           jsonb_build_object('kind', 'visit_reminder', 'admin', true, 'fmt', 'v2', 'rkey', m.rkey,
                              'ticket_id', m.ticket_id, 'manual_id', m.manual_id, 'days', m.d,
                              'rest', coalesce(m.rest_raw, ''), 'time', m.vtime, 'date', to_char(m.vd, 'YYYY-MM-DD'),
                              'pax', m.pax, 'rest_id', m.rest_id, 'who', m.who, 'i18n', m.i18n)
      from msg m
    returning id, user_id, title, body, url, payload
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'user_id', i.user_id, 'title', i.title, 'body', i.body, 'url', i.url,
           'days', (i.payload ->> 'days')::int,          -- 서버가 방금 넣은 줄이라 숫자다
           'ticket_id', i.payload ->> 'rkey',            -- Edge 의 푸시 tag(visit-reminder-…) — 일정마다 하나
           'rest', i.payload ->> 'rest', 'vtime', i.payload ->> 'time', 'i18n', i.payload -> 'i18n')), '[]'::jsonb),
         (select count(*)::int from fresh where rn > 50)
    into v_cnt, v_rows, v_skip
    from ins i;
  -- 상한을 넘었으면 슈퍼어드민 알림함에 한 줄(하루 한 번) — 넘친 일정은 그날 다시 안 간다(일수가 바뀐다). 조용히 빠지지 않게
  if v_skip > 0 then
    insert into public.notifications (user_id, type, title, body, url, payload)
    select p.id, 'visit_reminder_overflow', '방문 리마인드 ' || v_skip || '건 상한 초과',
           '한 번에 50건까지 보냅니다 — 나머지 ' || v_skip || '건은 티켓 캘린더에서 확인해 주세요.', '/',
           jsonb_build_object('kind', 'visit_reminder_overflow', 'skipped', v_skip, 'date', to_char(v_today, 'YYYY-MM-DD'))
      from public.profiles p
     where p.role in ('superadmin', 'super_admin') and coalesce(to_jsonb(p)->>'deleted_at', '') = ''
       and not exists (select 1 from public.notifications n where n.user_id = p.id and n.type = 'visit_reminder_overflow'
                         and n.payload ->> 'date' = to_char(v_today, 'YYYY-MM-DD'));
  end if;
  return jsonb_build_object('made', v_cnt, 'rows', v_rows, 'skipped', v_skip);
end $$;
revoke all on function public._taam_visit_reminder_admin() from public, anon, authenticated;

-- ── ② 리마인드 함수 끝에 ① 을 붙인다 ──
drop table if exists _vra;
create temp table _vra(name text primary key, status text);
do $do$
declare v_src text; v_md5 text; v_def text; n1 int; n2 int;
  a_decl text := 'declare v_cnt int := 0; v_rows jsonb;';
  a_ret  text := '  return jsonb_build_object(''made'', v_cnt, ''rows'', v_rows);';
begin
  select p.prosrc, md5(p.prosrc), pg_get_functiondef(p.oid) into v_src, v_md5, v_def from pg_proc p where p.oid = to_regproc('public.taam_visit_reminder_notify');
  if v_src is null then insert into _vra values ('taam_visit_reminder_notify', '❌ 라이브에 함수가 없다'); return; end if;
  if v_src like '%VR_ADMIN_20261027%' then insert into _vra values ('taam_visit_reminder_notify', '✅ 이미 새 판(슈퍼어드민 전 일정)'); return; end if;
  if v_md5 <> '3e902422c5a93c8e593d617ba93518a2' then
    insert into _vra values ('taam_visit_reminder_notify', '❌ 라이브 본문이 「제목에 매장·일수」 판(3e902422…)과 다르다 — 건너뜀 (md5 ' || v_md5 || ')'); return;
  end if;
  n1 := (length(v_def) - length(replace(v_def, a_decl, ''))) / length(a_decl);
  n2 := (length(v_def) - length(replace(v_def, a_ret, ''))) / length(a_ret);
  if n1 <> 1 or n2 <> 1 then insert into _vra values ('taam_visit_reminder_notify', '❌ 붙일 자리를 못 찾음(' || n1 || '·' || n2 || ') — 건너뜀'); return; end if;
  v_def := replace(v_def, a_decl, 'declare v_cnt int := 0; v_rows jsonb; v_adm jsonb;   -- VR_ADMIN_20261027 슈퍼어드민 전 일정');
  v_def := replace(v_def, a_ret,
'  -- VR_ADMIN_20261027 슈퍼어드민: 캘린더 전 일정(수동 추가 포함) — 회원 줄 뒤에(슈퍼어드민이 회원으로 산 티켓은 위에서 이미 들어가 건너뛴다).
  --   실패해도 회원 리마인드는 그대로 나간다(이 블록만 되돌린다)
  begin
    v_adm := public._taam_visit_reminder_admin();
  exception when others then
    raise warning ''visit reminder admin part failed: %'', sqlerrm;
    v_adm := null;
  end;
  return jsonb_build_object(''made'', v_cnt + coalesce((v_adm->>''made'')::int, 0),
                            ''rows'', coalesce(v_rows, ''[]''::jsonb) || coalesce(v_adm->''rows'', ''[]''::jsonb),
                            ''admin_made'', coalesce((v_adm->>''made'')::int, 0),
                            ''admin_skipped'', coalesce((v_adm->>''skipped'')::int, 0));');
  execute v_def;
  insert into _vra values ('taam_visit_reminder_notify', '✅ 교체(슈퍼어드민 전 일정 붙임)');
end $do$;

-- ── 확인 (하나로 · 건수만 — 공개 로그) ──
select '①' as 항목, '슈퍼어드민 몫 함수 · [예약자] 줄' as 내용,
       case when to_regproc('public._taam_visit_reminder_admin') is not null
             and public._taam_vr_add_who(public._taam_visit_remind_msg('{"ko":"미토우"}', date '2026-09-10', '18:30', 5, '{"notice":"주차 불가"}', 1), '우댕')->'ko'->>'body'
                 = E'[레스토랑] : 미토우\n[날짜] : 2026년 9월 10일(목)\n[시간] : 오후 6:30\n[인원] : 5\n[예약자] : 우댕\n\n[유의사항]\n주차 불가'
            then '✅' else '❌' end as 결과
union all select '②', status, case when status like '✅%' then '✅' else '❌' end from _vra
union all select '③', '의존: 수동 기록 표(daegwan_manual)', case when to_regclass('public.daegwan_manual') is not null then '✅' else '⚠ 없음 — 슈퍼어드민 몫이 실패해 회원 리마인드만 나간다' end
union all
select '④', '슈퍼어드민이 받을 일정(앞으로 · 종류별 건수 · 날짜 없음): ' ||
       coalesce((select string_agg(k || ' ' || n, ' · ' order by k) from (
         select case when t.purchase_id like 'MAN-%' then '수동 예약' when t.purchase_id like 'KSK-%' then '정산' when t.purchase_id like 'LINK-%' then '결제 링크'
                     when t.purchase_id like 'INV-%' then '초대' else '회원 구매' end as k, count(*) as n
           from public.tickets t left join public.profiles pu on pu.id = t.user_id
          where lower(coalesce(t.status, '')) in ('active', 'manual') and public.taam_visit_date(t.reservation_date) >= (now() at time zone 'Asia/Seoul')::date
            and not (coalesce(to_jsonb(pu)->>'is_test', '') = 'true' and coalesce(t.purchase_id, '') !~ '^(KSK|LINK|MAN)-')
          group by 1
         union all
         select '초대(좌석 행 없음)', count(*) from public.reservation_invites i left join public.profiles pi on pi.id = i.invitee_user_id
          where lower(coalesce(i.status, '')) = 'paid' and public.taam_visit_date(i.visit_date) >= (now() at time zone 'Asia/Seoul')::date
            and coalesce(to_jsonb(pi)->>'is_test', '') <> 'true'
            and not exists (select 1 from public.tickets t where coalesce(t.purchase_id, '') not like 'INVH-%'
                              and (t.extra_data->>'inviteId' = i.id::text or (t.extra_data->>'inviteId' is null and t.purchase_id like 'INV-' || left(i.id::text, 8) || '-%')))
         union all
         select '수동 기록', count(*) from public.daegwan_manual m where m.ymd >= (now() at time zone 'Asia/Seoul')::date
       ) z where n > 0), '없음'), 'ⓘ';
