-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 연도 없는 방문일('MM.DD')이 어디에 얼마나 남아 있나 (2026-10-19)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 「티켓 캘린더 2027년 6월에 2026년 6월 티켓이 또 보인다 · 올린 적 없다」.
--     연도 없이 저장된 옛 회차('06.17')를 앱이 「오늘 기준 120일 넘게 지났으면 내년」으로 읽어 2027 로 옮긴다.
--     고치기(연도 채우기) 전에 라이브의 실제 컬럼·행을 본다(CLAUDE.md 「SQL 을 쓰기 전에 실제 컬럼 타입을 조회한다」).
-- 무엇: SELECT 만 한다. 아무것도 바꾸지 않는다. 결과는 Actions 로그(① SQL migrations)에 표로 남는다.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_yearless()
returns table(sec text, info text)
language plpgsql as $$
declare r record; n bigint; q text;
begin
  -- A. 날짜·작성 시각 컬럼과 타입
  for r in
    select c.table_name, c.column_name, c.data_type
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name in ('ticket_products','tickets','reservation_invites','daegwan_manual','kashikiri_events','venue_capacity','ticket_capacity')
       and c.column_name in ('date','reservation_date','visit_date','ymd','event_date','created_at','updated_at','date_year')
     order by c.table_name, c.column_name
  loop
    sec := 'A 컬럼'; info := r.table_name || '.' || r.column_name || ' : ' || r.data_type; return next;
  end loop;

  -- B. ticket_products — 연도 없는 date
  if to_regclass('public.ticket_products') is not null then
    execute $q$select count(*) from public.ticket_products where coalesce(date,'') !~ '^\s*\d{4}'$q$ into n;
    sec := 'B 회차 연도 없음 · 건수'; info := n::text; return next;
    for r in execute $q$
      select tp.id, tp.rest_name, tp.date, tp.time, tp.status,
             to_jsonb(tp)->>'created_at' as created_at, to_jsonb(tp)->>'updated_at' as updated_at
        from public.ticket_products tp
       where coalesce(tp.date,'') !~ '^\s*\d{4}'
       order by (to_jsonb(tp)->>'created_at') nulls first, tp.id
       limit 200 $q$
    loop
      sec := 'B 회차 연도 없음'; info := r.id || ' | ' || coalesce(r.rest_name,'?') || ' | ' || coalesce(r.date,'(빈)') || ' ' || coalesce(r.time,'')
             || ' | ' || coalesce(r.status,'') || ' | 작성 ' || coalesce(r.created_at,'(없음)') || ' | 수정 ' || coalesce(r.updated_at,'(없음)'); return next;
    end loop;
    -- B2. 연도 있는 회차 중 2027-06 (진짜로 올라온 것이 있는지)
    for r in execute $q$
      select tp.id, tp.rest_name, tp.date, tp.time, tp.status, to_jsonb(tp)->>'created_at' as created_at
        from public.ticket_products tp
       where tp.date ~ '^\s*2027\D0?6\D'
       order by tp.date limit 50 $q$
    loop
      sec := 'B2 2027년 6월 회차(연도 있음)'; info := r.id || ' | ' || coalesce(r.rest_name,'?') || ' | ' || r.date || ' ' || coalesce(r.time,'') || ' | ' || coalesce(r.status,'') || ' | 작성 ' || coalesce(r.created_at,'(없음)'); return next;
    end loop;
    -- B3. 날짜 형식 분포
    for r in execute $q$
      select case when coalesce(date,'') ~ '^\s*\d{4}\D\d{1,2}\D\d{1,2}' then 'YYYY.MM.DD'
                  when coalesce(date,'') ~ '^\s*\d{1,2}\D\d{1,2}\s*$' then 'MM.DD'
                  when coalesce(date,'') = '' then '(빈)' else '기타:' || left(date, 20) end as fmt, count(*) as n
        from public.ticket_products group by 1 order by 2 desc $q$
    loop
      sec := 'B3 회차 날짜 형식'; info := r.fmt || ' : ' || r.n; return next;
    end loop;
  end if;

  -- C. tickets — 연도 없는 reservation_date
  if to_regclass('public.tickets') is not null then
    for r in execute $q$
      select case when reservation_date is null or btrim(reservation_date::text) = '' then '(빈)'
                  when reservation_date::text ~ '^\s*\d{4}' then 'YYYY…'
                  when reservation_date::text ~ '^\s*\d{1,2}\D\d{1,2}\s*$' then 'MM.DD'
                  else '기타' end as fmt, coalesce(status,'') as st, count(*) as n
        from public.tickets group by 1, 2 order by 1, 3 desc $q$
    loop
      sec := 'C 구매 방문일 형식'; info := r.fmt || ' · ' || r.st || ' : ' || r.n; return next;
    end loop;
    for r in execute $q$
      select t.purchase_id, t.status, t.reservation_date::text as rd, t.ticket_product_id, tp.date as tp_date, tp.rest_name,
             t.created_at::text as created_at, t.party_size
        from public.tickets t left join public.ticket_products tp on tp.id = t.ticket_product_id
       where t.reservation_date is not null and t.reservation_date::text !~ '^\s*\d{4}' and btrim(t.reservation_date::text) <> ''
       order by t.created_at limit 120 $q$
    loop
      sec := 'C 구매 연도 없음'; info := coalesce(r.purchase_id,'?') || ' | ' || coalesce(r.status,'') || ' | 방문 ' || r.rd || ' | 회차 ' || coalesce(r.ticket_product_id,'?')
             || ' (' || coalesce(r.tp_date,'회차 없음') || ' ' || coalesce(r.rest_name,'') || ') | ' || coalesce(r.party_size::text,'') || '명 | 작성 ' || coalesce(r.created_at,''); return next;
    end loop;
  end if;

  -- D. reservation_invites — visit_date
  if to_regclass('public.reservation_invites') is not null then
    begin
      for r in execute $q$
        select case when visit_date is null then '(빈)' when visit_date::text ~ '^\s*\d{4}' then 'YYYY…' else 'MM.DD/기타' end as fmt, count(*) as n
          from public.reservation_invites group by 1 order by 1 $q$
      loop
        sec := 'D 초대 방문일 형식'; info := r.fmt || ' : ' || r.n; return next;
      end loop;
      for r in execute $q$
        select id::text as id, restaurant_name, visit_date::text as vd, status, created_at::text as created_at
          from public.reservation_invites where visit_date is not null and visit_date::text !~ '^\s*\d{4}' order by created_at limit 60 $q$
      loop
        sec := 'D 초대 연도 없음'; info := r.id || ' | ' || coalesce(r.restaurant_name,'') || ' | ' || r.vd || ' | ' || coalesce(r.status,'') || ' | 작성 ' || coalesce(r.created_at,''); return next;
      end loop;
    exception when others then sec := 'D 오류'; info := sqlerrm; return next; end;
  end if;

  -- E. daegwan_manual — ymd
  if to_regclass('public.daegwan_manual') is not null then
    begin
      for r in execute $q$
        select case when ymd is null then '(빈)' when ymd::text ~ '^\s*\d{4}' then 'YYYY…' else 'MM.DD/기타' end as fmt, count(*) as n
          from public.daegwan_manual group by 1 order by 1 $q$
      loop
        sec := 'E 수동 기록 날짜 형식'; info := r.fmt || ' : ' || r.n; return next;
      end loop;
    exception when others then sec := 'E 오류'; info := sqlerrm; return next; end;
  end if;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_yearless();
