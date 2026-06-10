-- ═══════════════════════════════════════════════════════════════
-- TAAM 티켓 업로드 승인 게이트 — 서버 강제 (ticket_products 트리거)
-- 작성: 2026-06-10
-- ⚠ 반드시 admin_grants.sql 실행 + admin_grants 가 채워진 뒤에 실행할 것.
--    (안 그러면 어드민 신규 업로드가 'NOT_YOUR_RESTAURANT' 로 막힘)
-- ═══════════════════════════════════════════════════════════════
-- 강제 규칙 (비-슈퍼어드민 = 일반 어드민):
--   · INSERT(신규 업로드): status 는 'pending' 이어야 하고, rest_id 는 본인 권한 매장이어야 함.
--   · UPDATE: status 를 'pending' → 'active' 로 올리는 승인은 슈퍼어드민만.
--   · 그 외(이미 active 인 티켓 재저장·soldout 토글 등)는 그대로 허용 → saveTickets 흐름 안 깨짐.
-- 슈퍼어드민은 전부 허용 (승인·게시).
-- 안전성: 트리거는 '나쁜 전이'에만 예외 발생 → 읽기/일반 저장에 영향 없음.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.enforce_ticket_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 슈퍼어드민은 무조건 통과 (승인·게시 권한)
  if public.is_super_admin(auth.uid()) then
    return NEW;
  end if;

  if TG_OP = 'INSERT' then
    -- 신규 업로드는 반드시 승인 대기 상태
    if coalesce(NEW.status, '') <> 'pending' then
      raise exception 'ADMIN_MUST_UPLOAD_PENDING' using errcode = 'P0001';
    end if;
    -- 본인 권한 매장만
    if NEW.rest_id is null or not public.is_ticket_admin_of(NEW.rest_id) then
      raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
    end if;

  elsif TG_OP = 'UPDATE' then
    -- pending → active 승격(=게시 승인)은 슈퍼어드민만
    if OLD.status = 'pending' and NEW.status = 'active' then
      raise exception 'ONLY_SUPERADMIN_APPROVES' using errcode = 'P0001';
    end if;
    -- pending 상태 티켓의 소유 매장 변경 차단(우회 방지)
    if NEW.rest_id is distinct from OLD.rest_id and not public.is_ticket_admin_of(NEW.rest_id) then
      raise exception 'NOT_YOUR_RESTAURANT' using errcode = 'P0001';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_enforce_ticket_approval on public.ticket_products;
create trigger trg_enforce_ticket_approval
  before insert or update on public.ticket_products
  for each row execute function public.enforce_ticket_approval();

comment on function public.enforce_ticket_approval is
  '티켓 업로드 승인 게이트: 어드민 신규=pending+본인매장, pending→active 승격=슈퍼어드민만.';

-- ── 검증 ──
-- 어드민 계정으로:  insert into ticket_products(... status='active' ...)  → 'ADMIN_MUST_UPLOAD_PENDING' 나야 정상
-- 어드민 계정으로:  update ticket_products set status='active' where status='pending'  → 'ONLY_SUPERADMIN_APPROVES'
