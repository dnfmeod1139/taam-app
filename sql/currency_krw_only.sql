-- ═══════════════════════════════════════════════════════════════
-- TAAM — 전원 원화로 고정 (2026-09-14)
-- ═══════════════════════════════════════════════════════════════
-- 외화(USD·JPY) 회원의 화면(≈ 추정치)과 청구(원화 정가)가 따로 놀아 혼란을 줬다.
-- 표시·확정 정가·환율을 정리할 때까지 전원 원화로 청구·표시한다.
-- 앱은 FX_CURRENCY_LIVE=false 로 표시를 원화로 잠갔고, 서버(toss-order)는
-- profiles.currency 를 청구 통화로 쓰므로 여기서 값도 KRW 로 맞춘다.
-- 옛 값은 currency_prev 에 남긴다 — 되돌릴 때 그대로 복구한다.
-- 실행: Supabase SQL Editor. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists currency_prev text;
update public.profiles
   set currency_prev = coalesce(currency_prev, currency),
       currency      = 'KRW'
 where currency is distinct from 'KRW';

select '통화별 회원 수' as "구분", coalesce(currency, '(null)') as "currency", count(*)::text as "명"
  from public.profiles group by currency
union all
select '외화였던 회원(보관)', coalesce(currency_prev, '(없음)'), count(*)::text
  from public.profiles where currency_prev in ('USD','JPY') group by currency_prev
order by 1, 2;

-- ── 되돌리기 (외화를 다시 열 때, 앱 FX_CURRENCY_LIVE=true 와 함께) ──
-- update public.profiles set currency = currency_prev where currency_prev in ('USD','JPY');
