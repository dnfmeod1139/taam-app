-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) 2 — 방문 리마인드: 테스트 푸시 결과 · 빠진 예약이 있나 (2026-10-27)
-- 1차(20261027_diag_visit_reminder.sql) 결과: 크론은 매일 11:00 KST 성공 · 오늘 made 0 · 앞으로 10일 안 방문 0건 ·
--   그런데 리마인드 알림이 전체 8건 · 마지막 10-07 → 그 뒤 방문이 정말 없었는지, 방문일을 못 읽어 빠진 예약이 있는지 본다.
--   K 테스트 푸시(request_id 119)의 send-push 응답 — 시도·성공·실패 · 실패 사유(기기 주소는 찍지 않는다)
--   L 회원 예약(함수와 같은 거름 · 상태 무관 · 취소·홀드 제외)의 방문일 분포 — 못 읽음 · 지남 · 0~10일 · 11~60 · 61~365 · 그 뒤
--   M 방문일을 못 읽는 예약 — reservation_date 모양별 건수 · 회차 날짜(ticket_products.date)로는 읽히는지
--   N 지난 45일 방문(회원 예약)마다 리마인드를 받았나 — 날짜(KST)별 방문 수 · 리마인드 받은 수 · 받았어야 할 몫(설정 기본 1·3일)
-- 이름·전화·이메일은 찍지 않는다. 아무것도 쓰지 않는다.
-- ═══════════════════════════════════════════════════════════════

create temp table _vr2(seq serial, 구분 text, 내용 text);

-- ── K 테스트 푸시 응답 ──
do $do$
declare h record; j jsonb; d jsonb;
begin
  begin
    select * into h from net._http_response where id = 119;
    if not found then
      insert into _vr2(구분, 내용) values ('K 테스트 푸시', '⚠ 응답 줄이 없다(아직 안 왔거나 지워짐)');
    else
      begin j := h.content::jsonb; exception when others then j := null; end;
      insert into _vr2(구분, 내용) values ('K 테스트 푸시',
        to_char(h.created at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') || ' KST · HTTP ' || coalesce(h.status_code::text, '-')
        || case when j is not null then ' · 시도 ' || coalesce(j->'summary'->>'attempted', '-') || ' · 성공 ' || coalesce(j->'summary'->>'ok', '-')
                || ' · 실패 ' || coalesce(j->'summary'->>'failed', '-') || ' · 만료 지움 ' || coalesce(j->'summary'->>'removed', '-')
                || ' · pick ' || left(coalesce((j->'pick')::text, '-'), 120)
             else ' · ' || left(coalesce(h.content, h.error_msg, ''), 160) end);
      if j is not null and jsonb_typeof(j->'details') = 'array' then
        for d in select * from jsonb_array_elements(j->'details') loop
          insert into _vr2(구분, 내용) values ('K 기기별',
            case when (d->>'ok') = 'true' then '성공' else '실패' end || ' · ' || coalesce(d->>'via', d->>'kind', '') || ' status ' || coalesce(d->>'status', '-')
            || coalesce(' · ' || left(coalesce(d->>'reason', d->>'error'), 90), ''));
        end loop;
      end if;
    end if;
  exception when others then
    insert into _vr2(구분, 내용) values ('K 테스트 푸시', '⚠ 못 읽음: ' || left(sqlerrm, 120));
  end;
end $do$;

-- 회원 예약(함수와 같은 거름 · 상태는 아래에서 가른다)
create temp table _vr2_t as
select t.id, t.user_id, t.status, t.purchase_id, t.reservation_date, t.created_at, t.ticket_product_id,
       public.taam_visit_date(t.reservation_date) as vd,
       public.taam_visit_days_left(t.reservation_date) as d,
       p.notif_prefs as prefs
  from public.tickets t
  join public.profiles p on p.id = t.user_id
 where t.user_id is not null
   and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'refunded')
   and coalesce(t.purchase_id, '') not like 'KSK-%'
   and coalesce(t.purchase_id, '') not like 'MAN-%'
   and not (coalesce(t.purchase_id, '') like 'LINK-%' and nullif(t.extra_data->>'memberUid', '') is null)
   and not coalesce((t.extra_data ? 'kashikiri') or ((t.extra_data ? 'linkInvite') and nullif(t.extra_data->>'memberUid', '') is null) or (t.extra_data ? 'manualEntry'), false);

-- ── L 방문일 분포 ──
insert into _vr2(구분, 내용)
select 'L 방문일 분포 (상태 ' || coalesce(status, '-') || ')',
       '총 ' || count(*) || ' · 못 읽음 ' || count(*) filter (where d is null) || ' · 지남 ' || count(*) filter (where d < 0)
       || ' · 오늘 ' || count(*) filter (where d = 0) || ' · 1~10일 ' || count(*) filter (where d between 1 and 10)
       || ' · 11~60일 ' || count(*) filter (where d between 11 and 60) || ' · 61~365일 ' || count(*) filter (where d between 61 and 365)
       || ' · 그 뒤 ' || count(*) filter (where d > 365)
       || ' · 가장 가까운 앞날 ' || coalesce(to_char(min(vd) filter (where d >= 0), 'YYYY-MM-DD'), '-')
  from _vr2_t group by status order by status;

-- ── M 방문일을 못 읽는 예약 ──
insert into _vr2(구분, 내용)
select 'M 못 읽는 방문일 모양', coalesce(string_agg(x.shape || ' ' || x.n || '건(회차 날짜로는 읽힘 ' || x.tp_ok || ')', ' · '), '없음')
  from (
    select case when coalesce(btrim(v.reservation_date), '') = '' then '빈 값'
                when v.reservation_date ~ '^\d{1,2}[.\-/]\d{1,2}$' then 'MM.DD(연도 없음)'
                else '기타(' || left(regexp_replace(v.reservation_date, '\d', '9', 'g'), 16) || ')' end as shape,
           count(*) as n,
           count(*) filter (where public.taam_visit_date(tp.date) is not null) as tp_ok
      from _vr2_t v
      left join public.ticket_products tp on tp.id::text = v.ticket_product_id::text
     where v.d is null
     group by 1
  ) x;

-- ── N 지난 45일 방문마다 리마인드를 받았나 ──
insert into _vr2(구분, 내용)
select 'N 방문 ' || to_char(v.vd, 'MM-DD'),
       '회원 예약 ' || count(*) || '건 · 리마인드 받음 ' || count(*) filter (where exists (
             select 1 from public.notifications n where n.user_id = v.user_id and n.type = 'visit_reminder' and n.payload->>'ticket_id' = v.id::text))
       || ' · 하루 전 받음 ' || count(*) filter (where exists (
             select 1 from public.notifications n where n.user_id = v.user_id and n.type = 'visit_reminder' and n.payload->>'ticket_id' = v.id::text and n.payload->>'days' = '1'))
       || ' · 구매가 방문 하루 전보다 늦음 ' || count(*) filter (where (v.created_at at time zone 'Asia/Seoul')::date >= v.vd - 1)
       || ' · 상태 ' || string_agg(distinct coalesce(v.status, '-'), '/')
  from _vr2_t v
 where v.vd between (now() at time zone 'Asia/Seoul')::date - 45 and (now() at time zone 'Asia/Seoul')::date - 1
 group by v.vd
 order by v.vd desc;
insert into _vr2(구분, 내용)
select 'N 합계(지난 45일)', '방문 ' || count(*) || '건 · 리마인드 받은 예약 ' || count(*) filter (where exists (
             select 1 from public.notifications n where n.user_id = v.user_id and n.type = 'visit_reminder' and n.payload->>'ticket_id' = v.id::text))
  from _vr2_t v
 where v.vd between (now() at time zone 'Asia/Seoul')::date - 45 and (now() at time zone 'Asia/Seoul')::date - 1;

-- ── O 지금까지의 리마인드 8건 — 언제·며칠 전 ──
insert into _vr2(구분, 내용)
select 'O 리마인드 ' || to_char(n.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI'),
       coalesce(n.payload->>'days', '-') || '일 전 · ' || coalesce(n.payload->>'rest', '-') || ' · 회원 …' || right(n.user_id::text, 4)
  from public.notifications n
 where n.type = 'visit_reminder' and coalesce(n.payload->>'test', '') <> 'true'
 order by n.created_at desc limit 12;

select 구분, 내용 from _vr2 order by seq;
