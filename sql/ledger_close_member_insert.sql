-- ═══════════════════════════════════════════════════════════════
-- TAAM — 원장 서버화 4단계: 회원은 원장을 직접 쓰지 못한다 (2026-09-14)
-- ═══════════════════════════════════════════════════════════════
-- 설계: docs/DESIGN_ledger_server_side.md 「4단계 — INSERT 정책을 조인다」
-- 앞 단계: sql/ledger_server_side.sql (2단계 · 2026-09-13 핫픽스 포함)
--
-- 왜 지금 조이나
--   회원 경로는 전부 taam_apply_deposit_delta 에 원장(p_entries)을 넘긴다.
--   앱에 남은 deposit_transactions INSERT 는 ① 서버가 원장을 못 썼을 때의
--   폴백(옛 3인자 함수일 때만 도는 죽은 길) ② 슈퍼어드민 화면뿐이다.
--   그런데 정책은 아직 「자기 user_id 면 INSERT 허용」이라, 회원이 REST 로
--   가짜 환불·구매 행을 얼마든지 남길 수 있다. 잔액은 안 움직여도(가드)
--   **원장이 오염되면 환불 한도(낸 돈 − 이미 환불)가 틀어진다** — 위조한
--   ticket_purchase 행이 「낸 돈」으로 세어져 환불 한도가 늘어난다.
--
-- 이 파일이 하는 것 — 세 가지
--   ① taam_apply_deposit_delta 에 **서버 호출 길**을 낸다.
--      Edge Function(service_role) · SQL Editor(postgres) 는 auth.uid() 가
--      없어서 지금은 「로그인이 필요합니다」로 막힌다. 그래서 toss-confirm ·
--      toss-billing-charge 가 profiles 를 직접 고치고 원장을 따로 넣는다 —
--      앱에서 걷어낸 바로 그 모양이 서버에 남아 있었다. 서버 호출은
--      슈퍼어드민과 같게 본다(회원 한도 검사 없음).
--   ② 원장을 넘겼는데 잔액이 모자라면 **거부**한다 (LEDGER_INSUFFICIENT).
--      종전에는 greatest(0, …) 로 조용히 덜 빼고 원장에는 요청한 금액을
--      그대로 남겼다 — 「원장 합계 = 잔액 움직임」 검산이 여기서 새고 있었다.
--      원장 없는 옛 3인자 호출은 종전대로 0 에서 멈춘다(호환).
--      반환값에 prev_mem / prev_gen 을 더해 호출자가 실제 움직임을 셀 수 있다.
--   ③ deposit_transactions INSERT 정책: 본인 → **슈퍼어드민만**.
--      회원 원장은 오직 SECURITY DEFINER 함수(RPC)가 쓴다.
--
-- 순서 — 이 SQL 은 앱·Edge 를 **안 바꿔도 안전**하다
--   · RPC 는 인자·동작이 호환된다 (기존 호출 그대로 통과)
--   · Edge 는 service_role 이라 RLS 를 안 탄다 — 정책 변경의 영향 없음
--   · 앱의 회원 INSERT 는 죽은 폴백뿐. 하나(membership 예치금 결제의 이력)는
--     같은 날 앱에서 RPC 원장으로 옮겼다(빌드 2026.09.14-h)
--   그 다음 Edge 두 개(toss-confirm · toss-billing-charge)를 재배포한다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
-- 결과: 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════

begin;

-- ── ① · ② 함수 ─────────────────────────────────────────────────
-- 옛 시그니처 정리 (인자 수가 같아도 create or replace 가 안 되는 경우 대비)
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
  v_jwt   text := '';
  v_super boolean := false;
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
  v_paid  bigint;          -- 그 구매로 낸 돈
  v_back  bigint;          -- 이미 돌려받은 돈
  r_ref   record;
begin
  -- ── 누가 부르나 ─────────────────────────────────────────────
  --   auth.uid() 가 있으면 회원/슈퍼어드민(프로필 role 로 판정).
  --   없으면 🆕 서버 호출인지 본다:
  --     · Edge Function 은 service_role 키로 PostgREST 를 거친다 →
  --       request.jwt.claims.role = 'service_role'
  --     · SQL Editor · pg_cron 은 postgres 세션이다 → session_user = 'postgres'
  --   ⚠ security definer 안에서 current_user 는 소유자(postgres)라 못 쓴다.
  --     session_user 는 접속 역할 그대로다 (PostgREST 는 authenticator).
  if v_uid is null then
    begin
      v_jwt := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '');
    exception when others then
      v_jwt := '';
    end;
    if v_jwt = 'service_role' or session_user = 'postgres' then
      v_super := true;
    else
      raise exception '로그인이 필요합니다' using errcode = '42501';
    end if;
  else
    v_super := exists (select 1 from public.profiles p
                        where p.id = v_uid and p.role in ('super_admin','superadmin'));
  end if;

  -- 자기 것이거나 슈퍼어드민(서버 포함)
  if not v_super and p_user_id <> v_uid then
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

  -- ── 2026-09-13 회원은 돈을 만들지 못한다 ──────────────────────
  --   슈퍼어드민(서버 포함)이 아니면 잔액을 늘리는 길은 「낸 돈 한도 안의 환불」뿐이다.
  if not v_super then
    -- ① 원장 없이 양수 → 거부. 「그냥 더해 줘」는 없다.
    if p_entries is null and coalesce(p_mem_delta,0) + coalesce(p_gen_delta,0) > 0 then
      raise exception 'LEDGER_CREDIT_DENIED: 잔액을 늘리려면 환불 원장이 필요합니다' using errcode = '42501';
    end if;
    -- ② 각 주머니도 따로 본다 — 합이 0 이어도 한쪽에서 빼서 다른 쪽에 넣는 식은 안 된다
    if p_entries is null and (coalesce(p_mem_delta,0) > 0 or coalesce(p_gen_delta,0) > 0) then
      raise exception 'LEDGER_CREDIT_DENIED: 주머니를 늘리려면 환불 원장이 필요합니다' using errcode = '42501';
    end if;
    if p_entries is not null then
      -- ③ 양수 항목은 전부 ticket_refund + purchase_id 여야 한다
      for e in select * from jsonb_array_elements(p_entries) loop
        v_amt := (e->>'amount')::bigint;
        if v_amt > 0 then
          if coalesce(e->>'change_type','') <> 'ticket_refund'
             or coalesce(nullif(btrim(e->'metadata'->>'purchase_id'), ''), '') = '' then
            raise exception 'LEDGER_CREDIT_DENIED: 회원의 양수 원장은 환불(ticket_refund + purchase_id)만 됩니다 (받은 값 %)',
              coalesce(e->>'change_type','(없음)') using errcode = '42501';
          end if;
        end if;
      end loop;
      -- ④ 구매별로: 이번 환불 + 이미 돌려받은 것 ≤ 그 구매로 낸 돈
      for r_ref in
        select x->'metadata'->>'purchase_id' as pur, sum((x->>'amount')::bigint) as amt
          from jsonb_array_elements(p_entries) x
         where (x->>'amount')::bigint > 0
         group by 1
      loop
        select coalesce(-sum(amount), 0) into v_paid
          from public.deposit_transactions
         where user_id = p_user_id and change_type = 'ticket_purchase'
           and metadata->>'purchase_id' = r_ref.pur and amount < 0;
        select coalesce(sum(amount), 0) into v_back
          from public.deposit_transactions
         where user_id = p_user_id and change_type = 'ticket_refund'
           and metadata->>'purchase_id' = r_ref.pur and amount > 0;
        if r_ref.amt > v_paid - v_back then
          raise exception 'LEDGER_REFUND_EXCEEDS: 구매 % 로 낸 돈 %, 이미 환불 %, 이번 요청 % — 한도를 넘습니다',
            r_ref.pur, v_paid, v_back, r_ref.amt using errcode = '42501';
        end if;
      end loop;
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

  -- 🆕 2026-09-14 원장을 넘겼으면 잔액이 모자랄 때 거부한다.
  --   조용히 0 에서 멈추면 원장에는 요청 금액이, 잔액에는 그보다 작은 움직임이
  --   남아 둘이 어긋난다. 호출자는 이 오류를 받고 「예치금 부족」으로 처리한다.
  --   (원장 없는 옛 3인자 호출은 종전대로 0 에서 멈춘다 — 호환)
  if p_entries is not null and v_n > 0
     and (v_mem + coalesce(p_mem_delta,0) < 0 or v_gen + coalesce(p_gen_delta,0) < 0) then
    raise exception 'LEDGER_INSUFFICIENT: 잔액(멤버십 %, 일반 %)이 요청(%, %)에 못 미칩니다',
      v_mem, v_gen, coalesce(p_mem_delta,0), coalesce(p_gen_delta,0) using errcode = '42501';
  end if;

  v_nmem := greatest(0, v_mem + coalesce(p_mem_delta, 0));
  v_ngen := greatest(0, v_gen + coalesce(p_gen_delta, 0));

  update public.profiles
     set membership_deposit_balance = v_nmem,
         general_deposit_balance    = v_ngen
   where id = p_user_id;

  -- ── 원장 — 같은 트랜잭션에서 ──────────────────────────────────
  --   balance_after 는 **바꾸기 전 총액**에서 시작해 항목 순서대로 누적한다.
  if p_entries is not null and v_n > 0 then
    v_run := v_mem + v_gen;
    for e in select * from jsonb_array_elements(p_entries) loop
      v_amt := (e->>'amount')::bigint;
      v_run := v_run + v_amt;

      -- payment_id 는 uuid 컬럼. uuid 모양일 때만 넣고 아니면 metadata.payment_ref 로
      --   (2026-09-04 사고 — sql/ledger_server_side.sql 참조)
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
          || case when v_uid is null then jsonb_build_object('server_caller', coalesce(nullif(v_jwt,''), session_user::text))
                  else '{}'::jsonb end
      );
    end loop;
  end if;

  return json_build_object(
    'mem',      v_nmem,
    'gen',      v_ngen,
    'total',    v_nmem + v_ngen,
    'prev_mem', v_mem,
    'prev_gen', v_gen,
    'entries',  v_n
  );
end;
$$;

revoke all on function public.taam_apply_deposit_delta(uuid, bigint, bigint, jsonb) from public;
grant execute on function public.taam_apply_deposit_delta(uuid, bigint, bigint, jsonb) to authenticated, service_role;

comment on function public.taam_apply_deposit_delta(uuid, bigint, bigint, jsonb) is
  '예치금 잔액 이동 + (선택) 원장 기록을 한 트랜잭션으로. entries 합계가 잔액 변동과 다르면 거부. balance_after 는 서버가 센다. service_role/postgres 호출은 슈퍼어드민과 같다. 원장을 넘겼는데 잔액이 모자라면 LEDGER_INSUFFICIENT.';

-- ── ③ 정책: 회원의 원장 직접 INSERT 를 닫는다 ─────────────────────
--   SECURITY DEFINER 함수 안의 INSERT 는 소유자(postgres)로 돌아 정책을 안 탄다.
--   슈퍼어드민 화면(adminGrantDeposit · 환불 0원 기록)은 그대로 통과한다.
drop policy if exists deposit_tx_insert_own    on public.deposit_transactions;
drop policy if exists deposit_tx_insert_server on public.deposit_transactions;
create policy deposit_tx_insert_server on public.deposit_transactions
  for insert to authenticated
  with check (public._taam_uid_is_super());

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다 (SQL Editor 는 마지막 결과만 보여준다)
-- ═══════════════════════════════════════════════════════════════
select '① 함수가 4인자 하나인가' as "구분",
       case when count(*) = 1 then '✅' else '❌ ' || count(*)::text || '개' end as "상태",
       coalesce(max(pg_get_function_arguments(p.oid)), '(없음)') as "메모"
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
union all
select '② 서버 호출 길이 열렸나 ⭐',
       case when max(p.prosrc) like '%service_role%' and max(p.prosrc) like '%session_user = ''postgres''%'
            then '✅' else '❌ 옛 판' end,
       'Edge(service_role) · SQL Editor(postgres) 가 슈퍼어드민처럼'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
union all
select '③ 잔액 부족 시 거부하나 ⭐',
       case when max(p.prosrc) like '%LEDGER_INSUFFICIENT%' then '✅' else '❌ 옛 판 — 원장과 잔액이 어긋날 수 있다' end,
       '원장을 넘긴 호출만. 옛 3인자 호출은 종전대로'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
union all
select '④ 회원 자가 충전 방어 유지',
       case when max(p.prosrc) like '%LEDGER_CREDIT_DENIED%' and max(p.prosrc) like '%LEDGER_REFUND_EXCEEDS%'
            then '✅' else '❌' end,
       '2026-09-13 핫픽스가 그대로 들어 있어야 한다'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
union all
select '⑤ service_role 실행 권한',
       case when has_function_privilege('service_role', 'public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)', 'execute')
             and has_function_privilege('authenticated', 'public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)', 'execute')
            then '✅' else '❌' end,
       'authenticated · service_role 둘 다'
union all
select '⑥ 원장 INSERT 정책 = 슈퍼어드민만 ⭐',
       case when count(*) filter (where policyname = 'deposit_tx_insert_server') = 1
             and count(*) filter (where policyname = 'deposit_tx_insert_own') = 0
            then '✅' else '❌ ' || string_agg(policyname, ', ') end,
       coalesce(string_agg(policyname || '[' || cmd || ']', ' · '), '(정책 없음)')
  from pg_policies
 where schemaname = 'public' and tablename = 'deposit_transactions'
union all
select '⑦ deposit_transactions RLS 켜짐',
       case when relrowsecurity then '✅' else '❌ RLS 꺼짐 — 정책이 무의미' end,
       ''
  from pg_class where oid = to_regclass('public.deposit_transactions')
order by 1;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   함수: sql/ledger_server_side.sql 을 다시 돌린다 (drop 후 재생성 포함).
--   정책:
--     drop policy if exists deposit_tx_insert_server on public.deposit_transactions;
--     create policy deposit_tx_insert_own on public.deposit_transactions
--       for insert to authenticated
--       with check ((auth.uid() = user_id) or public.is_superadmin());
