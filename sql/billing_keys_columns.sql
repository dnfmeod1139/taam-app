-- ═══════════════════════════════════════════════════════════════
-- TAAM — billing_keys 컬럼 권한 조이기 (2026-09-14)
-- ═══════════════════════════════════════════════════════════════
-- 회원 세션이 billing_key(토스 승인 자격증명) 원문을 읽을 수 있었다 — RLS 는 행만 가리고
-- 컬럼은 못 가린다. 승인은 시크릿 키가 있어야 하니 그 값만으로 돈이 나가진 않지만,
-- 브라우저에 자격증명을 흘릴 이유가 없다. 표시에 필요한 컬럼만 SELECT 를 주고,
-- UPDATE 는 앱이 실제로 바꾸는 두 컬럼(is_default · deleted_at)만 준다.
--
-- ⚠ 순서: 앱 빌드 2026.09.14-o(카드 목록이 컬럼을 지정해 읽음)가 라이브인 뒤에 돌린다.
--   옛 빌드의 select('*') 는 이 뒤로 permission denied 가 된다(결제수단 화면만).
--   Edge Function(service_role)·SECURITY DEFINER 함수는 영향 없다.
--
-- 실행: Supabase SQL Editor. 여러 번 돌려도 안전. 마지막 표 ❌ 0.
-- ═══════════════════════════════════════════════════════════════
do $$
begin
  if to_regclass('public.billing_keys') is null then raise notice 'billing_keys 없음'; return; end if;
  revoke select, insert, update, delete on public.billing_keys from authenticated, anon;
  grant select (id, user_id, card_company, card_number, card_type, is_default, created_at, deleted_at)
    on public.billing_keys to authenticated;
  grant update (is_default, deleted_at) on public.billing_keys to authenticated;
end $$;

select '① billing_key 컬럼을 회원이 못 읽나 ⭐' as "구분",
       case when has_column_privilege('authenticated', 'public.billing_keys', 'billing_key', 'select') then '❌ 아직 읽힘' else '✅' end as "상태",
       '' as "메모"
union all
select '② 표시 컬럼은 읽히나',
       case when has_column_privilege('authenticated', 'public.billing_keys', 'card_number', 'select')
             and has_column_privilege('authenticated', 'public.billing_keys', 'deleted_at', 'select') then '✅' else '❌ 카드 목록이 깨진다' end, ''
union all
select '③ UPDATE 는 is_default·deleted_at 만',
       case when has_column_privilege('authenticated', 'public.billing_keys', 'is_default', 'update')
             and not has_column_privilege('authenticated', 'public.billing_keys', 'billing_key', 'update')
             and not has_column_privilege('authenticated', 'public.billing_keys', 'user_id', 'update') then '✅' else '❌' end, ''
order by 1;
