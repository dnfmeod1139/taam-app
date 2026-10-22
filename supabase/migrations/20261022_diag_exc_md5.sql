-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 구매 규정 예외(슈퍼어드민 협의 구매)를 넣기 전에 바꿀 라이브 함수 본문이 저장소 판과 같은지 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 중복 가드(taam_guard_purchase_unique · 20261014)와 결제 링크 만들기(taam_pay_link_create · 20261019_pay_link_override_parts)의
--     본문을 md5 가드로 바꿀 예정 — 라이브 본문 md5 가 저장소 판과 다르면 교체가 건너뛰어진다. 먼저 본다.
-- 무엇: SELECT 만 · 함수 이름 · md5 · 트리거 연결만(데이터 없음).
-- ═══════════════════════════════════════════════════════════════
select 'guard' as 함수, coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('public.taam_guard_purchase_unique()')), '(없음)') as md5,
       '7e6c53a6513c61de94377047dbd94b64' as 저장소
union all select 'pay_link_create', coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('public.taam_pay_link_create(text,jsonb)')), '(없음)'), '350c0c486abf2fe012a49025e23431c0'
union all select 'is_ops', coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('public._taam_ticket_is_ops(text,jsonb)')), '(없음)'), '0833f46be29199689edb1d494ba47894'
union all select 'trigger → ' || coalesce((select p.proname from pg_trigger g join pg_proc p on p.oid = g.tgfoid where g.tgname = 'trg_taam_guard_ticket_unique' and not g.tgisinternal limit 1), '(없음)'),
       coalesce((select pg_get_triggerdef(g.oid) from pg_trigger g where g.tgname = 'trg_taam_guard_ticket_unique' and not g.tgisinternal limit 1), '-'), '-'
union all select 'tickets.ticket_product_id 타입', coalesce((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.tickets'::regclass and attname = 'ticket_product_id'), '-'), '-'
union all select 'ticket_products.id 타입', coalesce((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.ticket_products'::regclass and attname = 'id'), '-'), '-'
union all select 'reservation_invites.ticket_product_id 타입', coalesce((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.reservation_invites'::regclass and attname = 'ticket_product_id'), '-'), '-'
union all select 'pgcrypto gen_random_uuid', case when to_regproc('gen_random_uuid') is not null then '있음' else '없음' end, '-';
