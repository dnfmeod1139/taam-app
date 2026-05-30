-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 접근 제어 보조 RPC (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 목적:
--   일반 회원이 "어떤 티켓이 화이트리스트 적용 중인지" 를 알아야
--   클라이언트에서 정확히 차단 가능 (회원 ID 노출 없이).
--
--   ticket_access_lists 의 SELECT RLS 는 일반 회원에게 본인 항목만 보여줌
--   → "내가 들어있지 않은 allow 티켓" 은 캐시에 없음 → 차단 못함
--
--   해결: SECURITY DEFINER RPC 가 ticket_id 만 distinct 로 반환.
--         user_id 같은 개인정보는 절대 노출 안 됨.
--
-- 실행: Supabase SQL Editor 1회.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.ticket_ids_with_allowlist()
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select distinct ticket_id
  from public.ticket_access_lists
  where access_type = 'allow';
$$;

comment on function public.ticket_ids_with_allowlist() is
  '화이트리스트 적용 중인 ticket_id 목록 (회원 ID 비공개). 클라이언트 가드가 "이 티켓은 초대 전용" 인지 판단할 때 사용.';

grant execute on function public.ticket_ids_with_allowlist() to authenticated;

do $$ begin raise notice '✅ ticket_ids_with_allowlist() RPC 설치 완료'; end $$;
