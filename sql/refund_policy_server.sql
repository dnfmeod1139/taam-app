-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 환불 정책을 서버가 센다 (2026-09-14 밤)
-- ═══════════════════════════════════════════════════════════════════════════
-- 실행: Supabase SQL Editor 에서 통째로 RUN.  결과: 맨 아래 확인 표에 ❌ 가 없어야 정상.
--
-- 왜: 취소 환불액은 앱의 calculateTicketRefund 가 계산해 _depApplyDelta 로 넘겼고,
--     서버(taam_apply_deposit_delta ④)는 「낸 돈 − 이미 환불」 한도만 봤다.
--     그래서 앱을 고친 회원은 D-5 티켓을 전액 환불받거나 환불 불가 대행비까지 되찾을 수 있었다.
--
-- 무엇: 회원(슈퍼어드민·service_role 이 아닌 호출)의 ticket_refund 양수 원장에
--       taam_refund_cap(회원, purchase_id) 를 한 번 더 씌운다.
--         · 티켓 생성 30분 이내         → 낸 돈 전액
--         · 방문일 D-31 이상(KST 날짜차) → 낸 돈 − 대행비×인원
--         · 방문일 모름                  → 낸 돈 − 대행비×인원 (앱과 같은 보수 처리)
--         · D-30 이하                    → 0
--       tickets 행이 없으면(옛 구매) 종전 한도(낸 돈 − 이미 환불)만 적용 — 정당한 옛 환불을 막지 않는다.
--       슈퍼어드민 예외 환불은 v_super 라 이 한도를 타지 않는다 (종전과 같다).
--
-- 앱은 그대로다. 앱이 정책대로 계산한 값은 이 한도 안에 들어오므로 아무 변화가 없고,
-- 정책 밖 요청만 LEDGER_REFUND_POLICY 로 거부된다.
-- 되돌리기: sql/ledger_close_member_insert.sql 의 함수를 다시 RUN (④ 만 종전으로).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── ① 방문일 파서 (visit_reminder 의 taam_visit_date 와 같은 규칙, 독립 복사본) ──
create or replace function public._taam_refund_visit_date(p_raw text)
returns date language plpgsql immutable as $$
declare s text; d date;
begin
  s := btrim(coalesce(p_raw, ''));
  if s = '' then return null; end if;
  s := btrim(regexp_replace(s, '[^0-9]+', '-', 'g'), '-');
  begin d := to_date(s, 'YYYY-MM-DD'); exception when others then return null; end;
  if d < date '2020-01-01' or d > date '2100-01-01' then return null; end if;
  return d;
end $$;

-- ── ② 정책 한도 ──
create or replace function public.taam_refund_cap(p_user_id uuid, p_purchase_id text)
returns bigint
language plpgsql stable security definer set search_path = public
as $$
declare
  v_paid   bigint := 0;
  v_back   bigint := 0;
  v_base   bigint;
  v_tk     record;
  v_agency bigint := 0;
  v_vd     date;
  v_days   int;
begin
  select coalesce(-sum(amount), 0) into v_paid
    from public.deposit_transactions
   where user_id = p_user_id and change_type = 'ticket_purchase'
     and metadata->>'purchase_id' = p_purchase_id and amount < 0;
  select coalesce(sum(amount), 0) into v_back
    from public.deposit_transactions
   where user_id = p_user_id and change_type = 'ticket_refund'
     and metadata->>'purchase_id' = p_purchase_id and amount > 0;
  v_base := greatest(0, v_paid - v_back);

  if to_regclass('public.tickets') is null then return v_base; end if;
  select t.created_at, t.party_size, t.reservation_date, t.ticket_product_id::text as tpid
    into v_tk
    from public.tickets t
   where t.purchase_id = p_purchase_id and t.user_id = p_user_id
   order by t.created_at desc nulls last
   limit 1;
  if not found then return v_base; end if;                      -- 옛 구매: 종전 한도만

  -- 30분 이내 전액
  if v_tk.created_at is not null and now() - v_tk.created_at <= interval '30 minutes' then
    return v_base;
  end if;

  -- 대행비 × 인원
  begin
    select coalesce(tp.agency_fee, 0)::bigint * greatest(coalesce(v_tk.party_size, 1), 1)
      into v_agency
      from public.ticket_products tp
     where tp.id::text = v_tk.tpid;
  exception when others then v_agency := 0; end;
  v_agency := coalesce(v_agency, 0);

  v_vd := public._taam_refund_visit_date(v_tk.reservation_date);
  if v_vd is null then
    return greatest(0, least(v_base, v_paid - v_agency - v_back));   -- 방문일 모름: 대행비 제외
  end if;
  v_days := v_vd - (now() at time zone 'Asia/Seoul')::date;
  if v_days >= 31 then
    return greatest(0, least(v_base, v_paid - v_agency - v_back));
  end if;
  return 0;                                                         -- D-30 이하: 환불 불가
end $$;
revoke all on function public.taam_refund_cap(uuid, text) from public, anon, authenticated;
comment on function public.taam_refund_cap(uuid, text) is
  '회원 취소 환불의 서버 한도. 30분 전액 · D-31 이상 대행비 제외 · D-30 이하 0. tickets 없으면 낸 돈−환불.';

-- ── ③ taam_apply_deposit_delta — ④ 구매별 한도에 정책 한도를 덧댄다 (그 밖은 2026-09-14 ledger_close 와 동일) ──
create or replace function public.taam_apply_deposit_delta(
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
  v_cap   bigint;          -- 🆕 2026-09-14 정책 한도 (30분·D-31·대행비)
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
        -- 🆕 2026-09-14 환불 정책도 서버가 센다 — 앱이 계산한 금액을 믿지 않는다.
        --   30분 이내 전액 · 방문 D-31 이상 대행비 제외 · D-30 이하 환불 불가.
        v_cap := public.taam_refund_cap(p_user_id, r_ref.pur);
        if r_ref.amt > v_cap then
          raise exception 'LEDGER_REFUND_POLICY: 구매 % 환불 한도 % (30분 내 전액 · D-31 이상 대행비 제외 · D-30 이하 불가), 이번 요청 %',
            r_ref.pur, v_cap, r_ref.amt using errcode = '42501';
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

-- ── 확인 (한 표) ──
select '① taam_refund_cap' as item, case when to_regprocedure('public.taam_refund_cap(uuid,text)') is not null then '✅' else '❌' end as ok
union all select '② 회원이 직접 못 부름', case when not has_function_privilege('authenticated','public.taam_refund_cap(uuid,text)','execute') then '✅' else '❌' end
union all select '③ apply_delta 가 정책을 본다', case when (select prosrc like '%LEDGER_REFUND_POLICY%' from pg_proc where proname='taam_apply_deposit_delta' limit 1) then '✅' else '❌' end
union all select '④ apply_delta 종전 규칙 유지', case when (select prosrc like '%LEDGER_REFUND_EXCEEDS%' and prosrc like '%LEDGER_INSUFFICIENT%' from pg_proc where proname='taam_apply_deposit_delta' limit 1) then '✅' else '❌' end
union all select '⑤ 회원이 apply_delta 는 부른다', case when has_function_privilege('authenticated','public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)','execute') then '✅' else '❌' end;
