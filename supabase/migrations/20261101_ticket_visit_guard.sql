-- ═══════════════════════════════════════════════════════════════
-- TAAM — 방문 기록(visit_status · visit_marked_at · visit_marked_by)은 회원·매장 어드민 세션이 직접 못 쓴다 (2026-11-01)
-- ═══════════════════════════════════════════════════════════════
--   2026-08-31 판 행 가드(sql/ticket_visit_record.sql)에는 「방문 기록은 직접 바꿀 수 없습니다(taam_set_ticket_visit 를 쓰세요)」 검사가 있었는데,
--   2026-09-13 재작성(sql/audit_hardening_2026-09-13.sql · taam_guard_ticket_row)에서 그 검사가 빠졌고 그 뒤 어느 마이그레이션도 다시 넣지 않았다.
--   그래서 회원이 자기 tickets 행에 visit_status='attended' 를 직접 적을 수 있었다(RLS tickets_update_own 은 행 단위 · INSERT 가드도 이 칸을 안 본다).
--   회원 원장 「반환 · 대행비」(2026-11-01)가 이 칸으로 「방문 완료 · 처리 필요」를 가르면서 처음으로 돈에 닿는 신호가 됐다(적대 리뷰) —
--   D-30 안 취소(환불 0)를 「방문 후 반환」(정가 − 대행비)으로 둔갑시키는 길. 앱은 방문일이 지난 뒤의 기록만 믿게 바꿨고, 서버는 여기서 닫는다.
--
--   규칙(별도 트리거 · 종전 가드 본문은 안 건드린다):
--     · 앱이 직접 보낸 문장(current_user 가 authenticated/anon · 슈퍼어드민 제외)에서 UPDATE 로 세 칸이 바뀌면 **되돌린다**(예외 아님 — 같은 UPDATE 의
--       다른 칸(취소 등)을 날리지 않게 · membership_joined · fee_exempt 가드와 같은 방식) · INSERT 는 세 칸을 비운다.
--     · 방문 기록은 RPC taam_set_ticket_visit(security definer · 매장 권한·방문일 검사)만 — 그 안에서는 current_user 가 함수 소유자라 이 가드를 지나지 않는다.
--     · 서버(service_role · SQL Editor · Edge · 다른 definer 함수)도 그대로.
--   회귀: bash sql/_test/t_visit_guard.sh
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_guard_ticket_visit()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 서버(service_role · postgres · SECURITY DEFINER RPC · 트리거)는 막지 않는다 — 기존 행 가드와 같은 판정
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.visit_status := null; new.visit_marked_at := null; new.visit_marked_by := null;
    return new;
  end if;
  if new.visit_status is distinct from old.visit_status then new.visit_status := old.visit_status; end if;
  if new.visit_marked_at is distinct from old.visit_marked_at then new.visit_marked_at := old.visit_marked_at; end if;
  if new.visit_marked_by is distinct from old.visit_marked_by then new.visit_marked_by := old.visit_marked_by; end if;
  return new;
end;
$$;

-- 트리거는 기록 RPC 가 security definer 일 때만 건다(2차 리뷰) — definer 가 아닌 판이 라이브에 있으면 파트너의 방문 기록이 이 가드에 되돌려져 기능이 죽는다.
--   그 경우 트리거를 걸지 않고 아래 확인 표 ③ 이 ❌ 로 멈춘다(워크플로가 실패로 기록 · 다음 푸시에 새 파일로). 함수가 아예 없으면(방문 기록 미설치) 가드만 건다.
do $do$
begin
  if exists (select 1 from pg_proc where proname = 'taam_set_ticket_visit' and pronamespace = 'public'::regnamespace and not prosecdef) then
    raise notice 'taam_set_ticket_visit 에 security definer 가 아닌 판이 있다 — 가드를 걸지 않는다';
    return;
  end if;
  execute 'drop trigger if exists trg_taam_guard_ticket_visit on public.tickets';
  execute 'create trigger trg_taam_guard_ticket_visit before insert or update of visit_status, visit_marked_at, visit_marked_by on public.tickets for each row execute function public.taam_guard_ticket_visit()';
end $do$;

comment on function public.taam_guard_ticket_visit() is
  '방문 기록 세 칸은 회원·매장 어드민 세션이 직접 못 쓴다(UPDATE 되돌림 · INSERT 비움) — taam_set_ticket_visit(definer)·서버만. 2026-11-01';

-- ── 확인 — 한 표 ──
select '① 트리거 trg_taam_guard_ticket_visit (before insert/update of visit_status… on tickets)' as 항목,
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_guard_ticket_visit' and c.relname = 'tickets' and not t.tgisinternal) then '✅' else '❌' end as 결과
union all select '② 함수 security invoker(앱이 직접 보낸 문장만 본다) · _taam_uid_is_super 존재',
       case when (select not prosecdef from pg_proc where oid = to_regproc('public.taam_guard_ticket_visit'))
             and to_regproc('public._taam_uid_is_super') is not null then '✅' else '❌' end
union all select '③ 기록 RPC taam_set_ticket_visit 가 security definer(가드를 지난다 · 오버로드가 있어도 전부)',
       case when not exists (select 1 from pg_proc where proname = 'taam_set_ticket_visit' and pronamespace = 'public'::regnamespace)
              then '⚠ 함수 없음 — sql/ticket_visit_record.sql 미실행(방문 기록 자체가 없다)'
            when exists (select 1 from pg_proc where proname = 'taam_set_ticket_visit' and pronamespace = 'public'::regnamespace and not prosecdef)
              then '❌ definer 아닌 판이 있다 — 매장 어드민의 방문 기록이 이 가드에 되돌려진다'
            else '✅' end
union all select '④ 정보 — 방문 기록을 행 소유자(회원) 자신이 찍었거나, 찍은 시각은 있는데 사람이 없는 행 수(회원이 직접 적었을 수 있는 모양 · 2026-08-31 백필(시각·사람 둘 다 없음)은 안 센다 · 원장 「⚠ 방문일 전 기록」과 함께 본다)',
       (select count(*) from public.tickets t
         where t.visit_status is not null
           and (t.visit_marked_by = t.user_id or (t.visit_marked_at is not null and t.visit_marked_by is null))
           and not exists (select 1 from public.profiles p where p.id = t.user_id and p.role in ('superadmin','super_admin')))::text;
