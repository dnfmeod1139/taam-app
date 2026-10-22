-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 예치금 환불 한도(taam_refund_cap) 라이브 본문이 저장소(sql/refund_policy_server.sql) 판과 같은지 · 같은 구매 id 를 쓰는 티켓 행이 둘 이상인 구매 수 (2026-10-22)
-- 왜: 카드 승인취소 2차 검증이 예치금 쪽 구멍 둘을 짚었다 — ① 인원 줄임으로 이미 돌려준 예치금(ticket_pax_change)을 「이미 환불」로 안 센다 ② 같은 구매 id 의 새 행(회원이 넣는 홀드)을 골라 금액·인원·방문일을 읽는다.
--     고치기 전에 라이브 본문을 확인한다(md5 · 줄 수). 데이터는 집계만.
-- ═══════════════════════════════════════════════════════════════
select 'refund_cap md5' as 항목, coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('public.taam_refund_cap(uuid,text)')), '(없음)') as 값
union all select 'refund_cap 줄 수', coalesce((select (select count(*) from regexp_split_to_table(prosrc, E'\n'))::text from pg_proc where oid = to_regprocedure('public.taam_refund_cap(uuid,text)')), '-')
union all select 'refund_cap 에 ticket_pax_change', coalesce((select (prosrc like '%ticket_pax_change%')::text from pg_proc where oid = to_regprocedure('public.taam_refund_cap(uuid,text)')), '-')
union all select 'apply_deposit_delta 가 refund_cap 을 부른다', coalesce((select bool_or(prosrc like '%taam_refund_cap%')::text from pg_proc where proname = 'taam_apply_deposit_delta'), '-')
union all select '같은 구매 id 의 티켓 행이 둘 이상인 PAY 구매', (select count(*) from (select purchase_id from public.tickets where purchase_id ~ '^PAY' group by purchase_id having count(*) > 1) x)::text
union all select '인원 줄임 원장 줄(ticket_pax_change · 양수) 구매 수', (select count(distinct metadata->>'purchase_id') from public.deposit_transactions where change_type = 'ticket_pax_change' and amount > 0)::text
union all select '인원 줄임 원장이 있는데 그 구매에 회원 ticket_refund 도 있는 구매 수', (select count(*) from (select distinct d.metadata->>'purchase_id' p from public.deposit_transactions d where d.change_type = 'ticket_pax_change' and d.amount > 0) x
                                                                       where exists (select 1 from public.deposit_transactions r where r.change_type = 'ticket_refund' and r.amount > 0 and r.metadata->>'purchase_id' = x.p))::text;
