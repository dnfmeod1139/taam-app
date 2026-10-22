-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 초대(reservation_invites)를 받는 회원이 어떤 칸을 고칠 수 있나 · 확정 함수가 결제를 확인하나 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 저장소의 RLS(resinv_update)는 초대받은 회원에게 자기 초대 행의 **모든 칸** UPDATE 를 허용하고, 앱 riPay 는 그 행의 total_amount 로 예치금을 뺀다.
--     확정 RPC taam_invite_confirm_hold 는 초대 status='paid' 만 보고 원장 결제를 확인하지 않는다(저장소 판).
--     → 회원이 status·금액을 고쳐 덜 내거나 안 내고 좌석을 확정할 수 있는지 — 라이브에 저장소에 없는 가드가 있는지 본다. 공격은 하지 않는다.
-- 무엇: 카탈로그 SELECT 만(정책·트리거·권한·함수 본문 요약). 개인 정보 없음. 결과는 Actions 로그.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_invguard()
returns table(sec text, info text)
language plpgsql as $$
declare r record; v_src text;
begin
  -- A. RLS 켜짐 · 정책
  for r in select relrowsecurity rls, relforcerowsecurity frc from pg_class where oid = 'public.reservation_invites'::regclass loop
    sec := 'A RLS'; info := 'enabled=' || r.rls || ' · force=' || r.frc; return next;
  end loop;
  for r in select policyname, cmd, roles::text roles, coalesce(qual,'') q, coalesce(with_check,'') w from pg_policies where schemaname='public' and tablename='reservation_invites' order by cmd, policyname loop
    sec := 'A 정책 ' || r.cmd || ' ' || r.policyname; info := 'roles ' || r.roles || ' · using ' || left(r.q, 220) || case when r.w <> '' then ' · check ' || left(r.w, 160) else '' end; return next;
  end loop;
  -- B. 트리거
  for r in select t.tgname, p.proname, t.tgenabled, pg_get_triggerdef(t.oid) def from pg_trigger t join pg_proc p on p.oid = t.tgfoid
            where t.tgrelid = 'public.reservation_invites'::regclass and not t.tgisinternal order by 1 loop
    sec := 'B 트리거 ' || r.tgname; info := r.proname || ' · ' || r.tgenabled || ' · ' || left(r.def, 200); return next;
  end loop;
  if not found then sec := 'B 트리거'; info := '없음'; return next; end if;
  -- C. 권한 — authenticated 의 UPDATE (표 · 칸)
  sec := 'C 권한 authenticated UPDATE(표)'; info := has_table_privilege('authenticated','public.reservation_invites','UPDATE')::text; return next;
  for r in select column_name from information_schema.column_privileges where table_schema='public' and table_name='reservation_invites' and grantee='authenticated' and privilege_type='UPDATE' order by 1 loop
    sec := 'C 칸 UPDATE'; info := r.column_name; return next;
  end loop;
  -- D. 확정 함수가 원장(결제)을 확인하나 · 금액을 어디서 가져오나
  for r in select p.oid, pg_get_function_identity_arguments(p.oid) args, p.prosrc, p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public' and p.proname in ('taam_invite_confirm_hold','taam_release_invite_hold') order by p.proname loop
    v_src := r.prosrc;
    sec := 'D 함수 (' || r.args || ')'; info := 'md5 ' || md5(v_src) || ' · definer ' || r.prosecdef
         || ' · 원장 확인 ' || (v_src ~* 'deposit_transactions')::text || ' · total_amount 사용 ' || (v_src ~* 'total_amount')::text
         || ' · status=paid 검사 ' || (v_src ~* $q$'paid'$q$)::text; return next;
  end loop;
  -- E. 지금 데이터 — 초대 금액이 회차 정가와 다른 paid 초대 · 원장 결제가 초대 합계보다 작은 paid 초대 (건수만)
  begin
    for r in
      with i as (
        select i.id, i.invitee_user_id, i.total_amount, i.pax, i.status,
               (select -sum(d.amount) from public.deposit_transactions d
                 where d.user_id = i.invitee_user_id and d.change_type = 'ticket_purchase' and d.amount < 0
                   and (d.metadata->>'invite_id' = i.id::text or d.metadata->>'purchase_id' like 'INV-' || left(i.id::text, 8) || '-%')) as paid_ledger
          from public.reservation_invites i where i.status = 'paid')
      select count(*) n,
             count(*) filter (where paid_ledger is null) no_ledger,
             count(*) filter (where paid_ledger is not null and paid_ledger < coalesce(total_amount,0)) under,
             count(*) filter (where paid_ledger is not null and paid_ledger > coalesce(total_amount,0)) over_
        from i
    loop
      sec := 'E paid 초대'; info := r.n || '건 · 원장 결제 없음 ' || r.no_ledger || ' · 원장 < 초대 합계 ' || r.under || ' · 원장 > 초대 합계 ' || r.over_; return next;
    end loop;
  exception when others then sec := 'E 오류'; info := sqlerrm; return next; end;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_invguard();
