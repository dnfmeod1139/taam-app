-- ═══════════════════════════════════════════════════════════════
-- 회원은 자기 좌석 행의 결제 링크·초대 연결 칸을 못 바꾼다 (2026-10-28 · 💳 결제 내역 보안 리뷰에서 찾은 옛 구멍)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다. 마지막 표에 ❌ 가 없어야 정상. 데이터는 바꾸지 않는다(트리거 하나).
-- 왜(재현 — 실제 taam_guard_ticket_row · taam_guard_ticket_payfacts 위에서 authenticated 회원 세션으로):
--   결제 사실 칸 가드(20261022_card_refund_quote2.sql A)는 linkInvite·memberUid 는 지키지만 chargeId 는 안 지켰다.
--   결제 링크로 회원 소유가 된 LINK- 좌석(2026-10-18 부터 · 2026-10-23 「예약으로 연결」)의 주인이 자기 행의 extra_data.chargeId 를 바꾸면
--     ① 링크 환불 견적(taam_link_invite_refund_quote)이 좌석을 못 찾아 방문일이 비고 대행비 0 으로 — D-1 에도 **전액 환불** 견적
--     ② 환불 트리거가 chargeId 로 좌석을 접으므로 환불 뒤에도 **좌석이 살아 있다**.
--   같은 견적이 좌석 행의 agencyFee·agencyPay(1인 대행비 스냅샷)를 D-31 에서 뺀다 — 주인이 0 으로 바꾸면 환불 불가 대행비까지 돌아간다.
-- 무엇: BEFORE INSERT/UPDATE 트리거 trg_taam_guard_ticket_linkfacts — **앱이 직접 보낸 문장만** 본다(SECURITY INVOKER · current_user 가 authenticated/anon 일 때 —
--   기존 INSERT·행 가드와 같은 방식). 서버 함수(security definer — 링크 만들기·초대 확정·결제 확정·정산 동기화)·Edge(service_role)·SQL Editor 는 그대로 지난다.
--   (1·2차 판은 역할(profiles.role)로 회원/매장 어드민을 갈랐는데, 파트너 계정은 role 'user' + admin_grants 라 매장 어드민의 결제 링크 만들기(security definer)가
--    회원 홀드로 잡혀 chargeId 가 지워지고 결제돼도 좌석이 안 열릴 뻔했다 — 3차 리뷰. 문장의 주인으로 가르면 역할을 볼 필요가 없다.)
--   UPDATE: 슈퍼어드민이 아니면 아래 칸의 변경을 되돌린다(어느 행이든 · 예외 아님 · 같은 갱신의 다른 칸은 그대로 — 취소 처리 등은 막지 않는다).
--     chargeId · token · currency · payAmount · fx · agencyFee · agencyPay · priceOverride · ovsFixed · eventId · convertedFrom · inviteId · memberUidPending · ownerTransferError · createdBy
--     · paidAt · paymentKey · confirmed_at · confirmed_by · invitePaid · inserted (paidAt·confirmed_at 이 연회비 기준일(첫 구매·초대 결제일)을 움직였다)
--     앱의 어느 화면도 이 칸을 직접 고치지 않는다(서버 함수가 쓴다) — 매장 어드민의 결제 링크 좌석(비회원 링크는 만든 어드민 소유)·회원 소유 좌석 모두.
--   INSERT: 결제 링크·정산 좌석(LINK- · KSK-)은 앱이 직접 못 만든다(LINK_SEAT_SERVER_ONLY — 매장 어드민이 같은 chargeId 로 새 홀드를 넣어 견적이 그 행을 집게 하던 길 · 3차 리뷰).
--     그 밖의 직접 INSERT 에서 연결 칸(chargeId · token · eventId · convertedFrom · inviteId)을 지운다 — 남의 청구·초대에 자기 홀드를 붙이던 길.
--     단 매장 어드민의 초대 홀드(INVH-)는 inviteId 를 둔다(앱이 직접 넣는다). agencyFee 같은 표시용 스냅샷은 INSERT 에서 건드리지 않는다.
-- 회귀: bash sql/_test/t_ticket_linkfacts.sh
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_ticket_linkfacts()
returns trigger
language plpgsql set search_path = public
as $$
declare
  v_keys text[] := array['chargeId','token','currency','payAmount','fx','agencyFee','agencyPay','priceOverride','ovsFixed','eventId','convertedFrom',
                         'inviteId','memberUidPending','ownerTransferError','createdBy',
                         'paidAt','paymentKey','confirmed_at','confirmed_by','invitePaid','inserted'];
  v_ins  text[] := array['chargeId','token','eventId','convertedFrom','inviteId'];
  v_old jsonb; v_new jsonb; k text;
begin
  -- 앱이 직접 보낸 문장만 — 서버 함수(security definer 안에서는 current_user 가 함수 소유자)·Edge·SQL Editor 는 그대로
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if coalesce(public._taam_uid_is_super(), false) then return new; end if;
  if tg_op = 'INSERT' then
    if coalesce(new.purchase_id, '') ~ '^(LINK|KSK)-' then
      raise exception 'LINK_SEAT_SERVER_ONLY: 결제 링크·정산 좌석은 서버만 만듭니다' using errcode = '42501';
    end if;
    if new.extra_data is not null and jsonb_typeof(new.extra_data) = 'object' then
      foreach k in array v_ins loop
        if k = 'inviteId' and coalesce(new.purchase_id, '') like 'INVH-%' then continue; end if;   -- 매장 어드민의 초대 홀드
        new.extra_data := new.extra_data - k;
      end loop;
    end if;
    return new;
  end if;
  v_old := coalesce(old.extra_data, '{}'::jsonb);
  v_new := coalesce(new.extra_data, '{}'::jsonb);
  if jsonb_typeof(v_new) <> 'object' then new.extra_data := old.extra_data; return new; end if;
  if jsonb_typeof(v_old) <> 'object' then v_old := '{}'::jsonb; end if;
  foreach k in array v_keys loop
    if (v_new->k) is distinct from (v_old->k) then
      if v_old ? k then v_new := jsonb_set(v_new, array[k], v_old->k); else v_new := v_new - k; end if;
    end if;
  end loop;
  new.extra_data := v_new;
  return new;
end $$;
revoke all on function public.taam_guard_ticket_linkfacts() from public, anon, authenticated;
comment on function public.taam_guard_ticket_linkfacts() is
  '앱이 직접 보낸 tickets 문장(슈퍼어드민 제외)은 결제 링크·초대 연결 칸(chargeId·agencyFee·agencyPay·paidAt…)을 못 바꾼다(되돌림) · LINK-/KSK- 직접 INSERT 거절 · 직접 INSERT 의 연결 칸 지움(INVH- 의 inviteId 는 둠). 2026-10-28 3차';
drop trigger if exists trg_taam_guard_ticket_linkfacts on public.tickets;
create trigger trg_taam_guard_ticket_linkfacts
  before insert or update on public.tickets
  for each row execute function public.taam_guard_ticket_linkfacts();

-- ── 확인 (하나로 · ❌ 가 없어야 정상 · 이름·금액 없음) ──
select '① 함수 taam_guard_ticket_linkfacts' as 항목, case when to_regproc('public.taam_guard_ticket_linkfacts') is not null then '✅' else '❌' end as 결과
union all
select '② 트리거 trg_taam_guard_ticket_linkfacts (tickets · BEFORE INSERT/UPDATE)',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ticket_linkfacts' and tgrelid = 'public.tickets'::regclass and not tgisinternal) then '✅' else '❌' end
union all
select '③ 기대는 함수 — _taam_uid_is_super', case when to_regproc('public._taam_uid_is_super') is not null then '✅' else '❌' end
union all
select '④ SECURITY INVOKER (앱이 직접 보낸 문장만 본다)', case when not (select prosecdef from pg_proc where oid = 'public.taam_guard_ticket_linkfacts'::regproc) then '✅' else '❌' end;
