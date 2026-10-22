-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 키사누키 5/20 「좌석 전환 실패 · PRICE_CHANGED (화면 900,000 · 현재 1,800,000)」 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 2026-10-22 13:21 KST 홀드 PAYH-1792639539840_1792642891762 의 확정이 PRICE_CHANGED 로 거절됐다.
--     서버는 「홀드 행의 회차 × 홀드 행의 인원」으로 다시 센다(taam_purchase_confirm_deposit). 같은 5/20 을 1인 ₩900,000 에 산 회원이 있으니
--     홀드 행이 ① 2인으로 적혔거나 ② 다른 회차(같이 올린 9/02)를 가리킨다. 결제 팝업은 메모리에 홀드 id 가 있으면 회차·인원을 안 보고 재사용한다.
-- 무엇: SELECT 만. 이름·번호·이메일·uid 를 찍지 않는다(그 회원은 「그 회원」). 결과는 Actions 로그.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_holdfail()
returns table(sec text, info text)
language plpgsql as $$
declare r record; r2 record; v_uid uuid; v_pid text := 'PAYH-1792639539840_1792642891762'; v_since timestamptz := timestamptz '2026-10-22 00:00+09';
begin
  select user_id into v_uid from public.tickets where purchase_id = v_pid order by created_at desc limit 1;
  sec := 'A 홀드 행 있음'; info := case when v_uid is null then '없음(삭제됐거나 다른 id)' else '있음' end; return next;

  -- A. 그 홀드 행
  for r in select t.*, to_jsonb(t) tj from public.tickets t where t.purchase_id = v_pid loop
    sec := 'A 홀드';
    info := '회차 ' || coalesce(r.ticket_product_id,'?') || ' · 방문 ' || coalesce(r.reservation_date,'?') || ' ' || coalesce(r.visit_time,'')
         || ' · 인원 ' || coalesce(r.party_size::text,'?') || ' · price ' || coalesce(r.price::text,'?') || ' · 상태 ' || coalesce(r.status,'?')
         || ' · 만든 시각 ' || to_char(r.created_at at time zone 'Asia/Seoul','HH24:MI:SS')
         || ' · extra 키[' || coalesce((select string_agg(k, ',' order by k) from jsonb_object_keys(coalesce(r.extra_data,'{}'::jsonb)) k), '') || ']'
         || ' · heldAt ' || coalesce(r.extra_data->>'heldAt','');
    return next;
  end loop;

  -- B. 같은 업로드의 회차들 (id 가 붙어 있다: Date.now() · +1 · +2 …)
  for r in
    select tp.id::text as id, to_jsonb(tp) j from public.ticket_products tp
     where tp.id::text ~ '^17926395398[0-9]{2}$' order by tp.id::text
  loop
    sec := 'B 회차 ' || r.id;
    info := '날짜 ' || coalesce(r.j->>'date','?') || ' ' || coalesce(r.j->>'time','') || ' · 매장 ' || coalesce(r.j->>'restaurant_name', r.j->>'rest_name', '')
         || ' · 식사 ' || coalesce(r.j->>'meal_fee','?') || ' · 대행 ' || coalesce(r.j->>'agency_fee','?') || ' · 주류 ' || coalesce(r.j->>'wine_min','?')
         || ' · 정원 ' || coalesce(r.j->>'total_pax','?') || ' · 상태 ' || coalesce(r.j->>'status','?')
         || ' · 서버 요금 1인 ' || coalesce(public.taam_ticket_price_krw(r.id, 1)::text,'null') || ' / 2인 ' || coalesce(public.taam_ticket_price_krw(r.id, 2)::text,'null')
         || ' · 슬롯 ' || coalesce(left((r.j->'slots')::text, 80), '없음')
         || ' · 수정 ' || coalesce(to_char((r.j->>'updated_at')::timestamptz at time zone 'Asia/Seoul','HH24:MI:SS'), '?');
    return next;
  end loop;

  -- C. 그 회원의 오늘 PAYH 행 (어느 회차 · 인원 · 상태 · 시각)
  if v_uid is not null then
    for r in
      select t.purchase_id, t.ticket_product_id, t.reservation_date, t.party_size, t.price, t.status, t.created_at
        from public.tickets t where t.user_id = v_uid and t.created_at >= v_since order by t.created_at
    loop
      sec := 'C 그 회원 오늘 행';
      info := to_char(r.created_at at time zone 'Asia/Seoul','HH24:MI:SS') || ' · ' || left(coalesce(r.purchase_id,''), 4) || '… 회차 ' || coalesce(r.ticket_product_id,'?')
           || ' · 방문 ' || coalesce(r.reservation_date,'?') || ' · 인원 ' || coalesce(r.party_size::text,'?') || ' · price ' || coalesce(r.price::text,'?')
           || ' · ' || coalesce(r.status,'?') || case when r.purchase_id = v_pid then '  ← 실패한 홀드' else '' end;
      return next;
    end loop;

    -- D. 그 회원의 오늘 원장 (돈이 움직였나)
    for r in
      select d.change_type, d.deposit_type, d.amount, d.created_at, d.metadata->>'purchase_id' as pid
        from public.deposit_transactions d where d.user_id = v_uid and d.created_at >= v_since order by d.created_at
    loop
      sec := 'D 그 회원 오늘 원장';
      info := to_char(r.created_at at time zone 'Asia/Seoul','HH24:MI:SS') || ' · ' || r.change_type || ' ' || coalesce(r.deposit_type,'') || ' ₩' || to_char(r.amount,'FM999,999,999')
           || case when r.pid = v_pid then ' · 실패한 홀드의 구매 id' when r.pid is null then '' else ' · 다른 구매 id' end;
      return next;
    end loop;
    if not found then sec := 'D 그 회원 오늘 원장'; info := '없음 — 돈이 움직이지 않았다'; return next; end if;

    -- D2. 카드 주문
    if to_regclass('public.payment_orders') is not null then
      for r in execute 'select status, amount, created_at from public.payment_orders where user_id = $1 and created_at >= $2 order by created_at' using v_uid, v_since loop
        sec := 'D2 그 회원 오늘 카드 주문'; info := to_char(r.created_at at time zone 'Asia/Seoul','HH24:MI:SS') || ' · ' || r.status || ' ₩' || r.amount; return next;
      end loop;
    end if;

    -- E. 그 회원이 받은 오늘 알림 종류 (본문 없이)
    if to_regclass('public.app_errors') is not null then
      begin
        for r in execute 'select to_jsonb(e) j from public.app_errors e where (to_jsonb(e)->>''user_id'') = $1::text and (to_jsonb(e)->>''created_at'')::timestamptz >= $2 order by (to_jsonb(e)->>''created_at'')' using v_uid, v_since loop
          sec := 'E 그 회원 오늘 앱 오류'; info := coalesce(r.j->>'kind','?') || ' · ' || left(coalesce(r.j->>'message', r.j->>'msg', ''), 160); return next;
        end loop;
      exception when others then sec := 'E 앱 오류'; info := '읽기 실패: ' || sqlerrm; return next; end;
    end if;
  end if;

  -- F. 회차별 지금 점유 (hold 포함)
  for r in
    select tp.id::text as id from public.ticket_products tp where tp.id::text ~ '^17926395398[0-9]{2}$' order by 1
  loop
    begin
      sec := 'F 점유 ' || r.id; info := coalesce(public.taam_ticket_sold_slots(r.id)::text, 'null'); return next;
    exception when others then sec := 'F 점유 ' || r.id; info := '읽기 실패: ' || sqlerrm; return next; end;
    for r2 in
      select t.status, count(*) n, sum(t.party_size) pax from public.tickets t where t.ticket_product_id = r.id group by 1 order by 1
    loop
      sec := 'F 행 ' || r.id; info := coalesce(r2.status,'?') || ' ' || r2.n || '건 ' || coalesce(r2.pax,0) || '명'; return next;
    end loop;
  end loop;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_holdfail();
