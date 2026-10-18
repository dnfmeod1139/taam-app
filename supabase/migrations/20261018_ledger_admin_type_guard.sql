-- ═══════════════════════════════════════════════════════════════
-- 원장 유형 가드 — 「관리자 부여/차감」 모양의 줄은 슈퍼어드민·서버만 쓴다 (2026-10-18)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: taam_apply_deposit_delta(sql/refund_policy_server.sql)는 회원(비슈퍼어드민) 호출에서 **양수 항목만** change_type 을 검사한다
--     (환불 ticket_refund + purchase_id 한도). 음수 항목은 change_type 이 비어 있지 않으면 무엇이든 받아 그대로 원장에 넣는다 —
--     그래서 회원이 앱 없이 RPC 를 직접 불러 자기 원장에 `admin_deduct`(관리자 차감) 모양의 음수 줄을 쓸 수 있었다(2026-09-14 부터).
--     자기 돈을 자기가 빼는 것이라 금전 손실은 없지만 원장 라벨이 거짓이 되고(「관리자 차감」인데 관리자가 한 적 없음), 원장 전수 대사·
--     부여/차감 로그가 그 줄을 어드민 행위로 센다. 2026-10-18 연회비 기록 트리거 리뷰에서 이 구멍이 「슈퍼어드민 전용 표 쓰기」로 이어지는 길이
--     드러나 그쪽은 호출자 검사로 닫았고(20261018_fee_deduct_record.sql 2차), 여기서는 구멍 자체를 닫는다.
-- 무엇: deposit_transactions BEFORE INSERT 트리거. 로그인 호출자(auth.uid() 있음)가 슈퍼어드민이 아니면 change_type 이 `admin_` 으로 시작하는 줄
--     (admin_grant · admin_deduct · 앞으로 생길 admin_*)을 LEDGER_TYPE_FORBIDDEN 으로 거절한다 — RPC 안에서 나는 예외라 잔액 변동까지 통째로 롤백된다.
-- 왜 RPC 를 고치지 않고 트리거인가: taam_apply_deposit_delta 는 모든 돈이 지나는 라이브 함수라 본문 교체는 위험이 크다(저장소 원본과 라이브가
--     같은지 보장 못 함 · CLAUDE.md 「라이브 함수 둘을 바꾸므로 md5 가 같을 때만」). 트리거는 덧대기만 하고 다른 길(RPC·직접 INSERT·앞으로의 RPC 개정)에도 같이 걸린다.
-- 영향 범위: 회원 세션의 admin_* 줄만. 회원 정상 경로(ticket_purchase · ticket_refund · membership_payment · user_charge)는 그대로 ·
--     슈퍼어드민 부여/차감 · 서버(SQL Editor·크론·Edge service_role = auth.uid() null)는 그대로.
-- 회귀: bash sql/_test/t_ledger_type_guard.sh
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_guard_ledger_change_type()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is not null
     and not coalesce(public.is_super_admin(auth.uid()), false)
     and lower(coalesce(new.change_type, '')) like 'admin\_%' escape '\' then
    raise exception 'LEDGER_TYPE_FORBIDDEN: 관리자 유형(%)의 원장 줄은 슈퍼어드민만 쓸 수 있습니다', new.change_type
      using errcode = '42501';
  end if;
  return new;
end $$;
comment on function public.taam_guard_ledger_change_type() is
  '회원 세션(auth.uid() 있고 슈퍼어드민 아님)이 admin_* change_type 의 원장 줄을 쓰면 거절(42501). 서버·슈퍼어드민은 그대로. 2026-10-18';

drop trigger if exists trg_taam_guard_ledger_change_type on public.deposit_transactions;
create trigger trg_taam_guard_ledger_change_type
  before insert on public.deposit_transactions
  for each row execute function public.taam_guard_ledger_change_type();

-- ── 확인 — 한 표 ──
select '① 트리거 trg_taam_guard_ledger_change_type (before insert on deposit_transactions)' as 항목,
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_guard_ledger_change_type' and c.relname = 'deposit_transactions' and not t.tgisinternal) then '✅' else '❌' end as 결과
union all select '② 함수 · is_super_admin(uuid) 존재',
       case when to_regproc('public.taam_guard_ledger_change_type') is not null and to_regprocedure('public.is_super_admin(uuid)') is not null then '✅' else '❌' end
union all select '③ 종전 가드 공존 (trg_sync_split_balance · trg_taam_fee_from_deduct)',
       case when exists (select 1 from pg_trigger where tgname = 'trg_sync_split_balance' and not tgisinternal)
             and exists (select 1 from pg_trigger where tgname = 'trg_taam_fee_from_deduct' and not tgisinternal) then '✅' else '⚠ 둘 중 하나 없음 — 이 파일과 무관(각 파일 참조)' end
union all select '④ 지금까지 비슈퍼어드민 회원 원장에 로그인 호출로 들어간 admin_* 줄 수 (정보 · 서버 호출(server_caller)·granted_by 가 슈퍼어드민인 줄은 뺀다 — 0 이 아니면 원장 대사 때 참고)',
       (select count(*) from public.deposit_transactions t
         where t.change_type like 'admin\_%' escape '\'
           and nullif(t.metadata->>'server_caller','') is null
           and not exists (select 1 from public.profiles p where p.id = t.user_id and p.role in ('superadmin','super_admin'))
           and not exists (select 1 from public.profiles a where a.id::text = t.metadata->>'granted_by' and a.role in ('superadmin','super_admin')))::text;
