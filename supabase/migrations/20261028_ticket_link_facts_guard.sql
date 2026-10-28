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
-- 무엇: BEFORE INSERT/UPDATE 트리거 trg_taam_guard_ticket_linkfacts —
--   UPDATE: 로그인한 **회원**(role 이 admin·superadmin 아님)이 **자기 행**(바꾸기 전·후 소유자가 자기)을 고칠 때 아래 칸의 변경을 되돌린다(예외 아님 · 같은 갱신의 다른 칸은 그대로 — 취소 처리 등은 막지 않는다).
--     chargeId · token · currency · payAmount · fx · agencyFee · agencyPay · priceOverride · ovsFixed · eventId · convertedFrom · inviteId · memberUidPending · ownerTransferError · createdBy
--   INSERT: 회원이 자기 이름으로 넣는 행(홀드 PAYH- 뿐)에서 연결 칸(chargeId · token · eventId · convertedFrom · inviteId)을 지운다 — 남의 청구·초대에 자기 홀드를 붙여
--     「연결 대기」 목록에서 숨기거나 알림 판단을 흐리던 길. agencyFee 같은 표시용 스냅샷은 INSERT 에서 건드리지 않는다(앱의 구매 기록이 쓴다).
--   서버(auth.uid() null — Edge·SQL Editor·크론) · 슈퍼어드민 · 매장 어드민 · 소유자가 바뀌는 갱신(초대 확정·링크 결제 뒤 회원 이전)은 그대로.
-- 회귀: bash sql/_test/t_ticket_linkfacts.sh
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_ticket_linkfacts()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
  v_keys text[] := array['chargeId','token','currency','payAmount','fx','agencyFee','agencyPay','priceOverride','ovsFixed','eventId','convertedFrom',
                         'inviteId','memberUidPending','ownerTransferError','createdBy'];
  v_ins  text[] := array['chargeId','token','eventId','convertedFrom','inviteId'];
  v_old jsonb; v_new jsonb; k text;
begin
  if v_uid is null then return new; end if;
  if coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  select coalesce(role, 'user') into v_role from public.profiles where id = v_uid;
  if coalesce(v_role, 'user') in ('admin', 'superadmin', 'super_admin') then return new; end if;   -- 매장 어드민의 흐름(초대 홀드·수동 좌석)은 종전대로
  if tg_op = 'INSERT' then
    if new.user_id = v_uid and new.extra_data is not null and jsonb_typeof(new.extra_data) = 'object' then
      foreach k in array v_ins loop new.extra_data := new.extra_data - k; end loop;
    end if;
    return new;
  end if;
  if old.user_id is distinct from v_uid or new.user_id is distinct from v_uid then return new; end if;   -- 소유자가 바뀌는 갱신·남의 행은 다른 가드가 본다
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
  '회원이 자기 좌석 행의 결제 링크·초대 연결 칸(chargeId·agencyFee·agencyPay…)을 못 바꾼다(되돌림) · 회원 INSERT 의 연결 칸은 지움. 2026-10-28';
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
select '③ 기대는 함수 — is_super_admin', case when to_regproc('public.is_super_admin') is not null then '✅' else '❌' end;
