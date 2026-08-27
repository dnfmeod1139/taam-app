-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 좌석 홀드 조회 RPC (2026-08-27)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   연결 초대는 발송 순간 tickets 에 status='hold' 행(INVH-)을 넣어 좌석을 잡는다.
--   그런데 taam_ticket_sold_slots 는 hold 행도 '판매됨'으로 센다. 그래서 초대받은
--   회원이 결제하려 하면 "내 초대가 잡아둔 좌석" 때문에 정원이 다 찬 것으로 보여
--   본인 결제가 거절된다 — 자기차단.
--     예) 정원 2석 티켓에 2인 초대 → 서버 판매 2 → 잔여 0 → 「결제 불가」 100% 발생
--   (2026-08-27 아카 11/12 미공개 티켓에서 실제로 발생)
--
--   그 홀드 행의 user_id 는 초대를 보낸 호스트다. 초대받은 회원은 RLS 때문에
--   tickets 를 직접 읽을 수 없다. 그래서 SECURITY DEFINER RPC 로 "이 초대가 잡고
--   있는 좌석 수"만 돌려준다. 좌석 수 외의 정보는 노출하지 않는다.
--
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent)
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_invite_hold_slots(p_invite_id text)
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'total', coalesce(sum(party_size), 0)::int,
    's1',    count(*) filter (where party_size = 1)::int
  )
    from public.tickets
   where coalesce(status, '') = 'hold'
     and (
           coalesce(extra_data->>'inviteId', '') = p_invite_id
        or purchase_id like 'INVH-' || left(p_invite_id, 8) || '-%'
     );
$$;

grant execute on function public.taam_invite_hold_slots(text) to authenticated;

-- 확인
select public.taam_invite_hold_slots('00000000-0000-0000-0000-000000000000') as "빈_초대_결과";
