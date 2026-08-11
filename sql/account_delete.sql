-- ═══════════════════════════════════════════════════════════════
-- TAAM — 인앱 계정 삭제 RPC (2026-08)
-- App Store Guideline 5.1.1(v) / Google Play 데이터 삭제 정책 대응
-- Supabase SQL Editor 에서 실행 (idempotent)
--   · 본인만 호출 가능 (auth.uid() 기준)
--   · profiles.deleted_at 소프트 삭제 → 기존 로그인 차단 로직이 그대로 동작
--   · 개인식별정보(이름·전화·이메일)는 즉시 마스킹 (재식별 불가)
--   · 거래 기록(tickets/deposit_transactions)은 전자상거래법상 보존 의무 → 유지
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles add column if not exists deleted_at timestamptz;

create or replace function public.taam_delete_my_account()
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return json_build_object('ok', false, 'error', 'not authenticated');
  end if;

  -- 이미 삭제된 계정이면 성공 처리(멱등)
  if exists (select 1 from public.profiles where id = v_uid and deleted_at is not null) then
    return json_build_object('ok', true, 'already', true);
  end if;

  update public.profiles
     set deleted_at   = now(),
         display_name = '탈퇴회원',
         phone        = null,
         email        = null,
         display_name_en = null
   where id = v_uid;

  -- 결제수단(빌링키)도 함께 해지
  begin
    update public.billing_keys set deleted_at = now()
     where user_id = v_uid and deleted_at is null;
  exception when others then null;
  end;

  -- 푸시 구독 해제
  begin
    delete from public.push_subscriptions where user_id = v_uid;
  exception when others then null;
  end;

  return json_build_object('ok', true);
end;
$$;

revoke execute on function public.taam_delete_my_account() from public;
grant  execute on function public.taam_delete_my_account() to authenticated;

do $$ begin raise notice '✅ 인앱 계정 삭제 RPC(taam_delete_my_account) 설치 완료'; end $$;
