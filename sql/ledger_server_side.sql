-- ═══════════════════════════════════════════════════════════════
-- TAAM — 원장 서버화 2단계: 잔액을 옮기는 함수가 원장도 쓴다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 설계: docs/DESIGN_ledger_server_side.md
--
-- 1단계 결과 (2026-08-31)
--   위조는 없었다. 티켓 없는 구매 0 · 중복 차감 0 · 남의 구매 참조 0.
--   잔액↔원장 불일치는 사장님 계정 두 개의 ±1,000 테스트 흔적뿐.
--   그러니 「지금부터 막는」 문제만 남는다.
--
-- 이 단계에서 무엇이 달라지나 — **아무것도 안 달라진다.**
--   함수에 p_entries 를 받는 길을 낸다. 앱은 아직 안 넘긴다.
--   안 넘기면 지금과 **완전히 같게** 동작한다.
--   3단계에서 앱 call site 를 하나씩 옮길 때 비로소 쓰인다.
--
-- 왜 잔액과 원장을 한 함수에 묶나
--   지금은 잔액은 RPC 가, 원장은 앱이 따로 쓴다. **갈라져 있는 것 자체가
--   문제다.** 중간이 끊기면 한쪽만 남고, 앱이 원장을 쓸 수 있는 한 위조도
--   막을 수 없다. 한 트랜잭션으로 묶으면 둘 다 해결된다.
--
-- 서버가 검산한다
--   entries 의 amount 합계가 (mem_delta + gen_delta) 와 **반드시 같아야 한다.**
--   다르면 거부한다. 이러면 원장이 잔액 움직임과 어긋날 수가 없다 —
--   1단계에서 잰 ②번 항목이 구조적으로 0이 된다.
--
--   balance_after 도 서버가 센다. 앱이 보낸 값은 쓰지 않는다.
--   시작값은 **바꾸기 전 총액**이고 항목 순서대로 누적한다 — 앱이 적던
--   중간값(멤버십 차감 직후 잔액 → 최종 잔액)과 같은 의미가 된다.
--
-- ⚠ 함수를 지웠다 다시 만든다. 그 사이에 결제가 들어오면 실패한다.
--   그래서 **하나의 트랜잭션**으로 감쌌다. begin/commit 을 지우지 말 것.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 앱 배포 필요 없음 — 앱은 지금처럼 3개 인자로 부른다.
-- ═══════════════════════════════════════════════════════════════

begin;

-- 같은 이름의 옛 시그니처를 전부 걷는다.
--   인자를 하나 더하면서 DEFAULT 를 주면, 3개로 부를 때 옛것과 새것이
--   겹쳐서 「function is not unique」로 죽는다. 그래서 지우고 다시 만든다.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
  loop
    execute 'drop function ' || r.sig;
    raise notice '[ledger] 옛 시그니처 제거: %', r.sig;
  end loop;
end $$;

create function public.taam_apply_deposit_delta(
  p_user_id   uuid,
  p_mem_delta bigint,
  p_gen_delta bigint,
  p_entries   jsonb default null   -- [{deposit_type, change_type, amount, description, metadata, payment_id}, ...]
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_super boolean;
  v_mem   bigint;
  v_gen   bigint;
  v_nmem  bigint;
  v_ngen  bigint;
  v_sum   bigint := 0;
  v_run   bigint;
  v_n     int := 0;
  e       jsonb;
  v_type  text;
  v_amt   bigint;
  v_pid_t text;
  v_pid   uuid;
  v_extra jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;

  v_super := exists (select 1 from public.profiles p
                      where p.id = v_uid and p.role in ('super_admin','superadmin'));

  -- 자기 것이거나 슈퍼어드민
  if p_user_id <> v_uid and not v_super then
    raise exception '다른 회원의 예치금은 바꿀 수 없습니다' using errcode = '42501';
  end if;

  -- ── entries 를 먼저 검산한다. 잔액을 건드리기 전에. ──────────────
  if p_entries is not null then
    if jsonb_typeof(p_entries) <> 'array' then
      raise exception 'LEDGER_BAD_SHAPE: entries 는 배열이어야 합니다' using errcode = '22023';
    end if;

    for e in select * from jsonb_array_elements(p_entries) loop
      v_type := lower(coalesce(e->>'deposit_type', ''));
      if v_type not in ('membership', 'general') then
        raise exception 'LEDGER_BAD_TYPE: deposit_type 은 membership/general 만 (받은 값 %)',
          coalesce(e->>'deposit_type','(없음)') using errcode = '22023';
      end if;
      if coalesce(e->>'change_type', '') = '' then
        raise exception 'LEDGER_NO_CHANGE_TYPE: change_type 이 비어 있습니다' using errcode = '22023';
      end if;
      begin
        v_amt := (e->>'amount')::bigint;
      exception when others then
        raise exception 'LEDGER_BAD_AMOUNT: amount 가 숫자가 아닙니다 (받은 값 %)',
          coalesce(e->>'amount','(없음)') using errcode = '22023';
      end;
      v_sum := v_sum + v_amt;
      v_n := v_n + 1;
    end loop;

    -- ⭐ 핵심 검산: 원장 합계 = 잔액 움직임
    if v_sum <> coalesce(p_mem_delta,0) + coalesce(p_gen_delta,0) then
      raise exception 'LEDGER_MISMATCH: 원장 합계(%)가 잔액 변동(%)과 다릅니다',
        v_sum, coalesce(p_mem_delta,0) + coalesce(p_gen_delta,0)
        using errcode = '22023';
    end if;
  end if;

  -- ── 행을 잠그고 읽는다 ────────────────────────────────────────
  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0)
    into v_mem, v_gen
    from public.profiles
   where id = p_user_id
     for update;

  if not found then
    raise exception '회원을 찾을 수 없습니다' using errcode = 'P0002';
  end if;

  v_nmem := greatest(0, v_mem + coalesce(p_mem_delta, 0));
  v_ngen := greatest(0, v_gen + coalesce(p_gen_delta, 0));

  update public.profiles
     set membership_deposit_balance = v_nmem,
         general_deposit_balance    = v_ngen
   where id = p_user_id;

  -- ── 원장 — 같은 트랜잭션에서 ──────────────────────────────────
  --   balance_after 는 **바꾸기 전 총액**에서 시작해 항목 순서대로 누적한다.
  --   앱이 적던 중간값과 같은 의미가 된다. 앱이 보낸 값은 쓰지 않는다.
  if p_entries is not null and v_n > 0 then
    v_run := v_mem + v_gen;
    for e in select * from jsonb_array_elements(p_entries) loop
      v_amt := (e->>'amount')::bigint;
      v_run := v_run + v_amt;

      -- ⚠ payment_id 는 **uuid 컬럼**이고 e->>'payment_id' 는 text 다.
      --   그냥 넣으면 값이 무엇이든 상관없이 죽는다 — 앱이 payment_id 를
      --   아예 안 보내도 마찬가지다. 문장을 **짤 때** 걸리는 오류라서
      --   (42804) 원장을 넘기는 모든 결제가 통째로 막혔다.
      --   2026-09-04, 초대 티켓 결제에서 「예치금 차감 실패」로 드러났다.
      --
      --   그렇다고 무조건 ::uuid 로 바꾸면 안 된다. 여기 들어오는 값이
      --   언제나 payments 행의 uuid 라는 보장이 없다 — 티켓 구매 쪽은
      --   PortOne 결제ID('taam-...')를 payment_id 라는 이름으로 들고 다닌다.
      --   그 값이 하루라도 섞여 들어오면 이번엔 **결제 중에** 터진다.
      --   그래서 uuid 모양일 때만 컬럼에 넣고, 아니면 metadata 에 남긴다.
      --   버리지 않는다 — 나중에 되짚을 수 있어야 한다.
      v_pid_t := nullif(btrim(coalesce(e->>'payment_id', '')), '');
      if v_pid_t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_pid   := v_pid_t::uuid;
        v_extra := '{}'::jsonb;
      else
        v_pid   := null;
        v_extra := case when v_pid_t is null then '{}'::jsonb
                        else jsonb_build_object('payment_ref', v_pid_t) end;
      end if;

      insert into public.deposit_transactions
        (user_id, deposit_type, change_type, amount, balance_after,
         description, payment_id, metadata)
      values (
        p_user_id,
        lower(e->>'deposit_type'),
        e->>'change_type',
        v_amt,
        v_run,
        nullif(e->>'description', ''),
        v_pid,
        coalesce(e->'metadata', '{}'::jsonb)
          || v_extra
          || jsonb_build_object('server_written', true)
      );
    end loop;
  end if;

  return json_build_object(
    'mem',     v_nmem,
    'gen',     v_ngen,
    'total',   v_nmem + v_ngen,
    'entries', v_n
  );
end;
$$;

revoke all on function public.taam_apply_deposit_delta(uuid, bigint, bigint, jsonb) from public;
grant execute on function public.taam_apply_deposit_delta(uuid, bigint, bigint, jsonb) to authenticated;

comment on function public.taam_apply_deposit_delta(uuid, bigint, bigint, jsonb) is
  '예치금 잔액 이동 + (선택) 원장 기록을 한 트랜잭션으로. entries 합계가 잔액 변동과 다르면 거부. balance_after 는 서버가 센다.';

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다 (SQL Editor 는 마지막 결과만 보여준다)
-- ═══════════════════════════════════════════════════════════════
select '① 함수가 4인자인가' as "구분",
       case when count(*) = 1 then '✅' else '❌ ' || count(*)::text || '개' end as "상태",
       coalesce(max(pg_get_function_arguments(p.oid)), '(없음)') as "메모"
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
union all
-- ⭐ 이번 사고의 핵심. text 를 uuid 컬럼에 그대로 넣던 줄이 남아 있으면
--    원장을 넘기는 결제가 전부 「예치금 차감 실패」로 막힌다.
select '② payment_id 를 안전하게 넣나 ⭐',
       case when max(p.prosrc) like '%nullif(e->>''payment_id''%' then '❌ 옛 판 — 결제가 막힌다'
            when max(p.prosrc) like '%v_pid_t::uuid%'            then '✅ 고쳐짐'
            else '❌ 알 수 없음' end,
       'uuid 모양일 때만 넣고 아니면 metadata.payment_ref 로'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
union all
-- ⚠ 「짐작하지 말고 실제 타입을 본다」 — 이번 사고가 정확히 그것이었다
select '③ payment_id 컬럼의 실제 타입',
       coalesce(max(data_type), '(컬럼 없음)'),
       'uuid 여야 정상'
  from information_schema.columns
 where table_schema = 'public' and table_name = 'deposit_transactions'
   and column_name = 'payment_id'
 order by 1;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   sql/deposit_server_side.sql 의 ① 블록(3인자 버전)을 다시 돌린다.
--   단 그 전에 4인자 버전을 지워야 겹치지 않는다:
--     drop function if exists public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb);
--
-- ═══════════════════════════════════════════════════════════════
-- 다음 (3단계)
-- ═══════════════════════════════════════════════════════════════
--   앱 call site 9곳을 **하나씩** 옮긴다. 한 곳 → 배포 → 그 흐름을 실제로
--   돌려 보고 → 다음. 순서는 위험이 낮은 것부터:
--     정원 초과 자동 환불 → 초대 티켓 결제 → 취소 환원 → 예치금 반환
--     → 티켓 구매 → 슈퍼어드민 부여
--   9곳이 전부 옮겨진 뒤에만 4단계(INSERT 정책 조이기)로 간다.
