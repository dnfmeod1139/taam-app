-- ═══════════════════════════════════════════════════════════════
-- 2026-11-04 조기 예약금 반환 (좌석 유지 · 방문 예정)
--
-- 배경: 예치금 관리 「반환 완료 처리」는 언제나 티켓을 cancelled 로 썼다(방문 뒤에 누르는 버튼이라).
--   2026-11-03 운영자가 예치금 정리 중 히가시아자부 아마모토 11/13 2인 초대(유수봉)를 방문 전에 「반환」했다 —
--   회원이 실제로 갈 예약인데 좌석이 풀리고, 11-03 초대 동기화 트리거가 초대장까지 「취소」로 바꿨다(11-04 SQL 로 되돌림).
--   운영 결정: 방문 전 반환은 슈퍼어드민에게 묻는다 — 「좌석 열기(예약 취소)」 또는 「조기 예약금 반환(좌석 유지 · 방문 예정)」.
--   조기 반환은 티켓을 그대로(active) 두고 extra_data.deposit_return.early = true 만 적는다(결제 사실 칸 가드가 지키는 칸 — 회원이 못 쓴다).
--
-- A. trg_taam_guard_ledger_refund_processed (deposit_transactions BEFORE INSERT)
--    슈퍼어드민이 이미 반환·환불을 처리한 예약(tickets.extra_data 의 super_admin_processed_at 또는 deposit_return — 보호 칸)에는
--    회원 세션이 양수 ticket_refund 를 더 쓰지 못한다(REFUND_ALREADY_PROCESSED). 조기 반환한 예약을 회원이 방문 31일 이상 전에
--    스스로 취소하면 taam_refund_cap(총액 − 대행비 − 이미 돌려준 돈)이 대행비·추가 차감 몫을 다시 돌려줄 수 있었다(회차 대행비가 0 이거나
--    추가 차감이 있으면). 같은 구멍이 슈퍼어드민 「환불 처리」(위약) 뒤 회원이 RPC 로 환불을 더 부르는 길에도 있었다(종전부터).
--    슈퍼어드민 · 서버(Edge · SQL Editor · auth.uid() null) · 인원 줄임(ticket_pax_change) · 0원 이하는 그대로.
-- B. 판매 현황(taam_ticket_sales_report): 방문 전날보다 앞선 'returned' 환불은 취소로 센다(return_before_visit) — 조기 반환은 예외.
--    앱 구매: 티켓이 살아 있고(취소 아님) deposit_return.early = true 면 「방문 후 반환」과 같게(ret_ok) ·
--    초대: 그 초대의 좌석 행이 살아 있고 early 면 같게. 라이브 본문을 pg_get_functiondef 로 읽어 정확히 그 자리만 바꾼다
--    (모양이 다르면 ⚠ 로 두고 건드리지 않는다 · 이미 바꿨으면 ✅).
-- 회귀: bash sql/_test/t_early_return.sh · bash sql/_test/t_ticket_sales.sh (E 절)
-- ═══════════════════════════════════════════════════════════════

-- ── A. 처리된 예약의 회원 환불 막기 ──
create or replace function public.taam_guard_ledger_refund_processed()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_pid text;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;   -- 서버 · SQL Editor · 슈퍼어드민
  if coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(new.amount, 0) <= 0 then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is null then return new; end if;
  if exists (select 1 from public.tickets t
              where t.purchase_id = v_pid and t.user_id = new.user_id
                and (coalesce(t.extra_data->>'super_admin_processed_at', '') <> ''
                     or jsonb_typeof(t.extra_data->'deposit_return') = 'object')) then
    raise exception 'REFUND_ALREADY_PROCESSED: 이미 TAAM 이 반환·환불을 처리한 예약입니다 — TAAM 에 문의해 주세요 (구매 %)', v_pid
      using errcode = '42501';
  end if;
  return new;
end $$;
comment on function public.taam_guard_ledger_refund_processed() is
  '슈퍼어드민이 반환·환불을 처리한 예약(super_admin_processed_at · deposit_return)에는 회원 세션이 양수 ticket_refund 를 더 쓰지 못한다(조기 반환 뒤 회원 취소로 대행비가 다시 돌아가던 길). 2026-11-04';
revoke all on function public.taam_guard_ledger_refund_processed() from public, anon, authenticated;
drop trigger if exists trg_taam_guard_ledger_refund_processed on public.deposit_transactions;
create trigger trg_taam_guard_ledger_refund_processed
  before insert on public.deposit_transactions
  for each row execute function public.taam_guard_ledger_refund_processed();

-- ── B. 판매 현황 — 조기 반환은 취소가 아니다 ──
drop table if exists _taam_er_b;
create temp table _taam_er_b(st text, note text);
do $b$
declare
  v_oid oid := to_regprocedure('public.taam_ticket_sales_report(date,date,text,boolean)');
  v_def text; v_new text;
  c_app_old constant text := $q$(vdate is null or (((l->>'ret_at')::timestamptz) at time zone 'Asia/Seoul')::date >= vdate - 1)$q$;
  c_app_new constant text := $q$(vdate is null or (((l->>'ret_at')::timestamptz) at time zone 'Asia/Seoul')::date >= vdate - 1 or (not is_cx and coalesce(x->'deposit_return'->>'early', '') = 'true'))$q$;
  c_j_old   constant text := $q$to_jsonb(tk)->>'visit_status' as visit_st,$q$;
  c_j_new   constant text := $q$to_jsonb(tk)->>'visit_status' as visit_st, tk.extra_data->'deposit_return'->>'early' as tk_early /* EARLY_RETURN_20261104 */,$q$;
  c_inv_old constant text := $q$(vdate is null or ((l_ret_at::timestamptz) at time zone 'Asia/Seoul')::date >= vdate - 1)$q$;
  c_inv_new constant text := $q$(vdate is null or ((l_ret_at::timestamptz) at time zone 'Asia/Seoul')::date >= vdate - 1 or (coalesce(tk_early, '') = 'true' and lower(coalesce(tk_status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired')))$q$;
  n_app int; n_j int; n_inv int;
begin
  if v_oid is null then insert into _taam_er_b values ('⚠', '판매 현황 함수가 없다 — 건너뜀'); return; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('EARLY_RETURN_20261104' in v_def) > 0 then insert into _taam_er_b values ('✅', '이미 새 판'); return; end if;
  n_app := (length(v_def) - length(replace(v_def, c_app_old, ''))) / length(c_app_old);
  n_j   := (length(v_def) - length(replace(v_def, c_j_old, ''))) / length(c_j_old);
  n_inv := (length(v_def) - length(replace(v_def, c_inv_old, ''))) / length(c_inv_old);
  if n_app <> 2 or n_j <> 1 or n_inv <> 1 then
    insert into _taam_er_b values ('⚠', format('모양이 다르다(앱 %s · 초대 좌석 칸 %s · 초대 %s — 2·1·1 이어야) — 건드리지 않음', n_app, n_j, n_inv));
    return;
  end if;
  v_new := replace(replace(replace(v_def, c_app_old, c_app_new), c_j_old, c_j_new), c_inv_old, c_inv_new);
  execute v_new;
  insert into _taam_er_b values ('✅', '덧댐 — 앱 2곳 · 초대 2곳');
end $b$;

-- ── 확인 — 한 표 ──
drop table if exists _taam_er_chk; create temp table _taam_er_chk(k text, v text);
insert into _taam_er_chk
select '① 처리된 예약의 회원 환불 가드', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ledger_refund_processed' and not tgisinternal) then '✅' else '❌' end
union all
select '② 판매 현황 조기 반환', (select st || ' ' || note from _taam_er_b limit 1)
union all
select '③ 조기 반환으로 표시된 살아 있는 티켓(정보)', count(*)::text
  from public.tickets t where coalesce(t.extra_data->'deposit_return'->>'early', '') = 'true'
   and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired');
select k, v from _taam_er_chk;
