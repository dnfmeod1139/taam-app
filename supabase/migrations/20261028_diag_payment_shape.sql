-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 카드·예치금 결제 내역 화면을 만들기 전에 라이브에 무엇이 남아 있나 (2026-10-28)
--   공개 저장소라 Actions 로그도 공개다 — 이름·번호·금액·키 값은 찍지 않는다. 칸 이름 · 키 이름 · 건수만.
--   A payment_orders: 칸 · 상태/수단/통화/용도별 건수 · metadata 최상위 키 · metadata.toss 키 · 카드 하위 키(있는 비율) · cancels 개수 · app_cancels
--   B kashikiri_charges: 칸 · 용도/상태/수단/통화 건수 · payload 키
--   C deposit_transactions: change_type × 부호 건수(최근 180일) · ticket_purchase metadata 키
--   D tickets.extra_data 카드 관련 키 건수
--   E billing_keys 칸 · payments(옛 포트원) 표 유무·건수
-- 아무것도 쓰지 않는다.
-- ═══════════════════════════════════════════════════════════════
create temp table _dps(seq serial, 구분 text, 내용 text);

-- ── A payment_orders ──
insert into _dps(구분, 내용)
select 'A 칸', string_agg(column_name || ':' || data_type, ' · ' order by ordinal_position)
  from information_schema.columns where table_schema = 'public' and table_name = 'payment_orders';

do $do$
declare r record; v text;
begin
  if to_regclass('public.payment_orders') is null then insert into _dps(구분, 내용) values ('A', '⚠ 표 없음'); return; end if;
  for r in execute $q$
    select coalesce(status,'-') st, coalesce(method,'-') me, coalesce(to_jsonb(o)->>'currency','-') cu,
           coalesce(to_jsonb(o)->>'kind', to_jsonb(o)->>'purpose', to_jsonb(o)->>'type', '-') ki,
           coalesce(metadata->>'paid_via','-') pv, count(*) n,
           to_char(min(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') mn, to_char(max(created_at) at time zone 'Asia/Seoul','YYYY-MM-DD') mx
      from public.payment_orders o group by 1,2,3,4,5 order by 6 desc limit 30 $q$ loop
    insert into _dps(구분, 내용) values ('A 건수', 'status ' || r.st || ' · method ' || r.me || ' · cur ' || r.cu || ' · kind ' || r.ki || ' · via ' || r.pv || ' → ' || r.n || '건 (' || r.mn || '~' || r.mx || ')');
  end loop;
  select string_agg(k || ' ' || n, ' · ' order by n desc) into v from (
    select k, count(*) n from public.payment_orders o, jsonb_object_keys(case when jsonb_typeof(o.metadata) = 'object' then o.metadata else '{}'::jsonb end) k group by k) z;
  insert into _dps(구분, 내용) values ('A metadata 키', coalesce(v, '-'));
  select string_agg(k || ' ' || n, ' · ' order by n desc) into v from (
    select k, count(*) n from public.payment_orders o, jsonb_object_keys(case when jsonb_typeof(o.metadata->'toss') = 'object' then o.metadata->'toss' else '{}'::jsonb end) k group by k) z;
  insert into _dps(구분, 내용) values ('A metadata.toss 키', coalesce(v, '없음'));
  select string_agg(k || ' ' || n, ' · ' order by n desc) into v from (
    select k, count(*) n from public.payment_orders o, jsonb_object_keys(case when jsonb_typeof(o.metadata->'toss'->'card') = 'object' then o.metadata->'toss'->'card' else '{}'::jsonb end) k group by k) z;
  insert into _dps(구분, 내용) values ('A toss.card 키', coalesce(v, '없음'));
  select string_agg(k || ' ' || n, ' · ' order by n desc) into v from (
    select k, count(*) n from public.payment_orders o, jsonb_object_keys(case when jsonb_typeof(o.metadata->'toss'->'easyPay') = 'object' then o.metadata->'toss'->'easyPay' else '{}'::jsonb end) k group by k) z;
  insert into _dps(구분, 내용) values ('A toss.easyPay 키', coalesce(v, '없음'));
  select 'paid ' || count(*) filter (where status = 'paid') || ' 중 toss 있음 ' || count(*) filter (where status = 'paid' and jsonb_typeof(metadata->'toss') = 'object')
         || ' · card 있음 ' || count(*) filter (where status = 'paid' and jsonb_typeof(metadata->'toss'->'card') = 'object')
         || ' · cancels 있는 행 ' || count(*) filter (where jsonb_typeof(metadata->'toss'->'cancels') = 'array' and jsonb_array_length(metadata->'toss'->'cancels') > 0)
         || ' · app_cancels 있는 행 ' || count(*) filter (where jsonb_typeof(metadata->'app_cancels') = 'array')
         || ' · payment_key 있음 ' || count(*) filter (where nullif(payment_key,'') is not null)
         || ' · receipt_url 있음 ' || count(*) filter (where nullif(to_jsonb(o)->>'receipt_url','') is not null)
         || ' · toss.mId 종류 ' || count(distinct metadata->'toss'->>'mId')
    into v from public.payment_orders o;
  insert into _dps(구분, 내용) values ('A 채움 비율', v);
  select string_agg(k || ' ' || n, ' · ' order by n desc) into v from (
    select coalesce(metadata->'toss'->>'status','-') || '/' || coalesce(metadata->'toss'->>'method','-') k, count(*) n from public.payment_orders where jsonb_typeof(metadata->'toss') = 'object' group by 1) z;
  insert into _dps(구분, 내용) values ('A toss 상태/수단', coalesce(v, '-'));
exception when others then insert into _dps(구분, 내용) values ('A', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── B kashikiri_charges ──
insert into _dps(구분, 내용)
select 'B 칸', string_agg(column_name || ':' || data_type, ' · ' order by ordinal_position)
  from information_schema.columns where table_schema = 'public' and table_name = 'kashikiri_charges';
do $do$
declare r record; v text;
begin
  for r in execute $q$
    select coalesce(to_jsonb(c)->>'purpose','-') pu, coalesce(status,'-') st, coalesce(to_jsonb(c)->>'method','-') me, coalesce(to_jsonb(c)->>'pay_currency','-') cu,
           coalesce(to_jsonb(c)->>'link_invite','-') li, (event_id is not null) ev, count(*) n
      from public.kashikiri_charges c group by 1,2,3,4,5,6 order by 7 desc limit 30 $q$ loop
    insert into _dps(구분, 내용) values ('B 건수', 'purpose ' || r.pu || ' · status ' || r.st || ' · method ' || r.me || ' · cur ' || r.cu || ' · link ' || r.li || ' · 회차 ' || r.ev || ' → ' || r.n || '건');
  end loop;
  select string_agg(k || ' ' || n, ' · ' order by n desc) into v from (
    select k, count(*) n from public.kashikiri_charges c, jsonb_object_keys(case when jsonb_typeof(to_jsonb(c)->'payload') = 'object' then to_jsonb(c)->'payload' else '{}'::jsonb end) k group by k) z;
  insert into _dps(구분, 내용) values ('B payload 키', coalesce(v, '-'));
exception when others then insert into _dps(구분, 내용) values ('B', '⚠ ' || left(sqlerrm, 160));
end $do$;
insert into _dps(구분, 내용)
select 'B 관리 표 칸', coalesce(string_agg(column_name || ':' || data_type, ' · ' order by ordinal_position), '없음')
  from information_schema.columns where table_schema = 'public' and table_name = 'kashikiri_charge_admin';

-- ── C deposit_transactions ──
insert into _dps(구분, 내용)
select 'C 칸', string_agg(column_name || ':' || data_type, ' · ' order by ordinal_position)
  from information_schema.columns where table_schema = 'public' and table_name = 'deposit_transactions';
insert into _dps(구분, 내용)
select 'C 유형(180일)', string_agg(k || ' ' || n, ' · ' order by n desc)
  from (select coalesce(change_type,'-') || case when amount < 0 then '(-)' else '(+)' end || '/' || coalesce(deposit_type,'-') k, count(*) n
          from public.deposit_transactions where created_at > now() - interval '180 days' group by 1) z;
insert into _dps(구분, 내용)
select 'C ticket_purchase metadata 키', string_agg(k || ' ' || n, ' · ' order by n desc)
  from (select k, count(*) n from public.deposit_transactions d, jsonb_object_keys(case when jsonb_typeof(d.metadata) = 'object' then d.metadata else '{}'::jsonb end) k
         where d.change_type in ('ticket_purchase','ticket_refund') group by k) z;

-- ── D tickets.extra_data 카드 관련 ──
insert into _dps(구분, 내용)
select 'D 티켓 extra_data(카드 관련 키)', string_agg(k || ' ' || n, ' · ' order by n desc)
  from (select k, count(*) n from public.tickets t, jsonb_object_keys(case when jsonb_typeof(t.extra_data) = 'object' then t.extra_data else '{}'::jsonb end) k
         where k in ('cardPaid','paidBy','order_id','orderId','card_refund_pending','depositUsed','card_currency','card_amount_fx','payAmount','paymentKey','payment_key','tossPaymentKey','server_confirmed','confirmed_at','depositReturn','deposit_return')
         group by k) z;

-- ── E billing_keys · payments ──
insert into _dps(구분, 내용)
select 'E billing_keys 칸', coalesce(string_agg(column_name || ':' || data_type, ' · ' order by ordinal_position), '없음')
  from information_schema.columns where table_schema = 'public' and table_name = 'billing_keys';
do $do$
declare v text;
begin
  if to_regclass('public.payments') is null then insert into _dps(구분, 내용) values ('E payments(옛 포트원)', '표 없음'); return; end if;
  execute 'select ''건수 '' || count(*) || '' · 칸 '' || (select string_agg(column_name, '','' order by ordinal_position) from information_schema.columns where table_schema = ''public'' and table_name = ''payments'') from public.payments' into v;
  insert into _dps(구분, 내용) values ('E payments(옛 포트원)', v);
exception when others then insert into _dps(구분, 내용) values ('E payments', '⚠ ' || left(sqlerrm, 160));
end $do$;

select 구분, 내용 from _dps order by seq;
