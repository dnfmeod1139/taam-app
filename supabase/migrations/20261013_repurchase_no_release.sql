-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 재구매 제한 「발매 7일 뒤 자동 해제」 폐지 · 2026-10-13
--
-- 2026-08-31 에 넣은 규칙: 판매 오픈 7일이 지난 회차는 재구매 제한을 풀었다(안 팔린 자리는 나눌
-- 경쟁자가 없다는 전제). 운영 결정으로 뺀다 — 제한 일수(30·60·90·120·180) 동안 **내내** 막는다.
-- 함수 이름은 그대로 둔다(가드·알림 함수가 부른다). 뜻만 「해제 없음」으로.
--   · taam_repurchase_released(ticket) → 언제나 false
--   · taam_repurchase_release_days()   → 36500 (사실상 없음 · 0 을 주면 「즉시 해제」가 돼 버린다)
-- 앱의 _repReleasedByAge 도 같은 날 false 로 맞췄다 (빌드 2026.10.13-c).
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.taam_repurchase_release_days()
returns int language sql immutable as $$ select 36500 $$;
comment on function public.taam_repurchase_release_days() is
  '재구매 제한 자동 해제 일수 — 2026-10-13 폐지. 36500 = 사실상 해제 없음 (0 은 즉시 해제라 쓰지 않는다).';

create or replace function public.taam_repurchase_released(p_ticket_id text)
returns boolean
language sql stable security definer set search_path = public
as $$ select false $$;
comment on function public.taam_repurchase_released(text) is
  '판매 오픈 후 자동 해제 — 2026-10-13 폐지. 언제나 false (제한 일수 내내 막는다).';

-- ── 확인 (한 표) — ❌ 가 없어야 정상 ──
select '① 해제 판정이 언제나 false' as what,
       case when public.taam_repurchase_released('any') = false then '✅' else '❌' end as result
union all
select '② 해제 일수 = 사실상 없음',
       case when public.taam_repurchase_release_days() >= 36500 then '✅ ' || public.taam_repurchase_release_days()::text else '❌' end
union all
select '③ 가드 트리거 살아 있음',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_repurchase_guard') then '✅' else '❌ 없음 — sql/repurchase_release_7days.sql 확인' end;
