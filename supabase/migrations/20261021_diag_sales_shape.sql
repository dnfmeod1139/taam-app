-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 티켓 판매 금액이 표마다 어떻게 적혀 있나 (2026-10-21)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 「티켓 전체·월별 판매금액을 볼 수 있는 기능」. 판매가 여러 갈래(예치금·카드 PAYC · 초대 INV · 결제 링크 LINK · 정산 KSK · 수동 MAN)로
--     남고 금액·환불이 표마다 다르게 적힌다. 화면을 만들기 전에 라이브의 실제 모양(컬럼·건수·합계)을 본다.
-- 무엇: SELECT 만 한다. 이름·번호 같은 개인 정보는 찍지 않는다(집계만). 결과는 Actions 로그(① SQL migrations)에 남는다.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_sales()
returns table(sec text, info text)
language plpgsql as $$
declare r record;
begin
  -- A. 관련 표의 컬럼
  for r in
    select c.table_name, string_agg(c.column_name || ':' || c.data_type, ', ' order by c.ordinal_position) as cols
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name in ('tickets','payment_orders','payments','kashikiri_charges','reservation_invites','daegwan_manual','deposit_transactions')
     group by c.table_name order by c.table_name
  loop
    sec := 'A 컬럼 ' || r.table_name; info := r.cols; return next;
  end loop;

  -- B. tickets — 구매 id 앞머리 × 상태
  if to_regclass('public.tickets') is not null then
   begin
    for r in execute $q$
      select coalesce(nullif(substring(coalesce(purchase_id,'') from '^([A-Za-z]+)-'), ''), '(없음)') as pfx,
             lower(coalesce(status,'')) as st, count(*) as n, coalesce(sum(price),0) as amt, coalesce(sum(party_size),0) as pax,
             count(*) filter (where coalesce(price,0) = 0) as zero,
             to_char(min(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') as first, to_char(max(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') as last
        from public.tickets group by 1, 2 order by 1, 2 $q$
    loop
      sec := 'B 구매 ' || r.pfx || ' · ' || r.st; info := r.n || '건 · ₩' || to_char(r.amt, 'FM999,999,999,999') || ' · ' || r.pax || '명 · 금액0 ' || r.zero || '건 · ' || coalesce(r.first,'') || '~' || coalesce(r.last,''); return next;
    end loop;
    -- B2. extra_data 에 실린 금액 관련 키 (살아 있는 행)
    for r in execute $q$
      select k, count(*) as n
        from public.tickets t, jsonb_object_keys(coalesce(t.extra_data,'{}'::jsonb)) k
       where lower(coalesce(t.status,'')) not in ('cancelled','expired')
         and k ~* '(fee|amount|amt|price|pay|paid|charge|card|deposit|fx|currency|refund|method|via|agency|meal|wine)'
       group by k order by n desc limit 40 $q$
    loop
      sec := 'B2 extra_data 키'; info := r.k || ' : ' || r.n; return next;
    end loop;
   exception when others then sec := 'B 오류'; info := sqlerrm; return next; end;
  end if;

  -- C. deposit_transactions — 유형별 합
  if to_regclass('public.deposit_transactions') is not null then
   begin
    for r in execute $q$
      select coalesce(change_type,'(없음)') as ct, count(*) as n, coalesce(sum(amount),0) as amt,
             to_char(min(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') as first, to_char(max(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') as last
        from public.deposit_transactions group by 1 order by 2 desc $q$
    loop
      sec := 'C 원장 ' || r.ct; info := r.n || '줄 · 합 ₩' || to_char(r.amt, 'FM999,999,999,999') || ' · ' || coalesce(r.first,'') || '~' || coalesce(r.last,''); return next;
    end loop;
    for r in execute $q$
      select k, count(*) as n
        from public.deposit_transactions d, jsonb_object_keys(coalesce(d.metadata,'{}'::jsonb)) k
       where d.change_type in ('ticket_purchase','ticket_refund')
       group by k order by n desc limit 30 $q$
    loop
      sec := 'C2 원장 metadata 키(티켓)'; info := r.k || ' : ' || r.n; return next;
    end loop;
   exception when others then sec := 'C 오류'; info := sqlerrm; return next; end;
  end if;

  -- D. payment_orders — 카드 결제
  if to_regclass('public.payment_orders') is not null then
    begin
      for r in execute $q$
        select coalesce(to_jsonb(p)->>'status','?') as st, coalesce(to_jsonb(p)->>'kind', to_jsonb(p)->>'type', to_jsonb(p)->>'order_type', '?') as kind,
               count(*) as n, coalesce(sum((to_jsonb(p)->>'amount')::numeric),0) as amt
          from public.payment_orders p group by 1, 2 order by 1, 2 $q$
      loop
        sec := 'D 카드 주문 ' || r.st || ' · ' || r.kind; info := r.n || '건 · ₩' || to_char(r.amt, 'FM999,999,999,999'); return next;
      end loop;
    exception when others then sec := 'D 오류'; info := sqlerrm; return next; end;
  end if;

  -- E. kashikiri_charges — 정산·결제 링크
  if to_regclass('public.kashikiri_charges') is not null then
    begin
      for r in execute $q$
        select coalesce(purpose,'?') as pu, coalesce(status,'?') as st, coalesce(pay_currency,'KRW') as cur, coalesce(link_invite,false) as li,
               count(*) as n, coalesce(sum(amount_krw),0) as krw, coalesce(sum(pay_amount),0) as pay
          from public.kashikiri_charges group by 1,2,3,4 order by 1,2,3,4 $q$
      loop
        sec := 'E 링크·정산 ' || r.pu || ' · ' || r.st || ' · ' || r.cur || case when r.li then ' · 링크초대' else '' end;
        info := r.n || '건 · ₩' || to_char(r.krw, 'FM999,999,999,999') || ' · 결제통화 ' || r.pay; return next;
      end loop;
    exception when others then sec := 'E 오류'; info := sqlerrm; return next; end;
  end if;

  -- F. reservation_invites — 초대
  if to_regclass('public.reservation_invites') is not null then
    begin
      for r in execute $q$
        select coalesce(status,'?') as st, count(*) as n, coalesce(sum((to_jsonb(i)->>'total_amount')::numeric),0) as amt, coalesce(sum((to_jsonb(i)->>'agency_fee')::numeric),0) as ag
          from public.reservation_invites i group by 1 order by 1 $q$
      loop
        sec := 'F 초대 ' || r.st; info := r.n || '건 · 합계 ₩' || to_char(r.amt, 'FM999,999,999,999') || ' · 대행비 ₩' || to_char(r.ag, 'FM999,999,999,999'); return next;
      end loop;
    exception when others then sec := 'F 오류'; info := sqlerrm; return next; end;
  end if;

  -- G. daegwan_manual — 연결 없는 수동 기록
  if to_regclass('public.daegwan_manual') is not null then
    begin
      for r in execute $q$
        select count(*) as n, coalesce(sum((to_jsonb(m)->>'amount')::numeric),0) as amt from public.daegwan_manual m $q$
      loop
        sec := 'G 수동 기록(연결 없음)'; info := r.n || '건 · ₩' || to_char(r.amt, 'FM999,999,999,999'); return next;
      end loop;
    exception when others then sec := 'G 오류'; info := sqlerrm; return next; end;
  end if;

  -- H. 같은 구매가 두 곳에 — 예치금 원장의 ticket_purchase 합과 PAYC/INV 행 price 합 (월별, 결제일 KST)
  if to_regclass('public.tickets') is not null and to_regclass('public.deposit_transactions') is not null then
   begin
    for r in execute $q$
      with t as (
        select to_char(created_at at time zone 'Asia/Seoul','YYYY-MM') as ym,
               sum(price) filter (where purchase_id ~ '^PAYC-' and lower(status) not in ('cancelled','expired','hold')) as payc,
               sum(price) filter (where purchase_id ~ '^INV-' and lower(status) not in ('cancelled','expired','hold')) as inv,
               sum(price) filter (where purchase_id ~ '^MAN-' and lower(status) not in ('cancelled','expired')) as man
          from public.tickets group by 1),
      d as (
        select to_char(created_at at time zone 'Asia/Seoul','YYYY-MM') as ym,
               -sum(amount) filter (where change_type = 'ticket_purchase') as dp, sum(amount) filter (where change_type = 'ticket_refund') as rf
          from public.deposit_transactions group by 1)
      select coalesce(t.ym, d.ym) as ym, coalesce(t.payc,0) as payc, coalesce(t.inv,0) as inv, coalesce(t.man,0) as man, coalesce(d.dp,0) as dp, coalesce(d.rf,0) as rf
        from t full join d on d.ym = t.ym order by 1 $q$
    loop
      sec := 'H 월별 ' || r.ym; info := 'PAYC ₩' || to_char(r.payc,'FM999,999,999,999') || ' · INV ₩' || to_char(r.inv,'FM999,999,999,999') || ' · MAN ₩' || to_char(r.man,'FM999,999,999,999')
             || ' · 원장 구매 ₩' || to_char(r.dp,'FM999,999,999,999') || ' · 원장 환불 ₩' || to_char(r.rf,'FM999,999,999,999'); return next;
    end loop;
   exception when others then sec := 'H 오류'; info := sqlerrm; return next; end;
  end if;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_sales();
