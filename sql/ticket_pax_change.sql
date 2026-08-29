-- ═══════════════════════════════════════════════════════════════
-- TAAM — 판매된 티켓의 인원 변경 (1단계: 감소만) (2026-08-29)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   이미 결제된 예약의 인원이 줄어드는 일은 계속 생긴다. 지금은 표현할
--   방법이 「취소 후 재구매」뿐인데, 그게 네 가지를 망가뜨린다.
--
--     ① D-30 이내면 환불이 0원이다. 인원을 줄이려고 취소하면 돈은 안
--        돌아오고 좌석만 풀린다. 인원 감소는 취소가 아닌데 취소로 처리된다.
--     ② 취소하는 순간 좌석이 열려 다른 회원이 채갈 수 있다.
--     ③ 원장이 두 건으로 쪼개져 감사 추적이 끊긴다.
--     ④ 카드분은 토스에서 수동 환불 → 재결제 왕복이 생긴다.
--
--   그래서 인원 변경을 별도 연산으로 만든다. tickets 행은 그대로 살아
--   있고 party_size · price 만 바뀐다. 좌석도 원장도 예약 건도 안 끊긴다.
--
-- 왜 RPC 인가 (클라이언트에서 하면 안 되는 이유)
--   · profiles 잔액 UPDATE 는 슈퍼어드민만 허용돼 있다
--     (admin_deposit_grant_policies.sql + guard_deposit_balance 트리거).
--   · tickets 는 레스토랑 어드민에게 SELECT 만 열려 있다
--     (tickets_admin_rls.sql).
--   두 잠금은 의도된 것이라 풀지 않는다. 대신 SECURITY DEFINER 로 서버가
--   자기 권한으로 돌면서 안에서 직접 권한을 검사한다. 돈이 움직이는 자리가
--   한 군데로 모이고, 한 트랜잭션이라 절반만 적용되는 상태가 없다.
--
-- 누가 부를 수 있나
--   · 슈퍼어드민 — 전부
--   · 레스토랑 어드민 — 자기 매장 구매만 (is_restaurant_admin_of)
--   ⚠ 어드민이 돌려줄 금액을 직접 정할 수 있다. 회원 예치금이 그 사람 손으로
--     움직인다는 뜻이다. 그래서 실행자·사유·금액·전후 인원을 전부 남긴다.
--     승인제로 바꾸고 싶어지면 아래 v_is_super 검사만 조이면 된다.
--
-- 환불 금액은 호출자가 정한다
--   정책 기본값(30분 이내 전액 / D-31 이상 대행비 제외 / D-30 이하 0)은
--   앱이 계산해 미리 채워 보여주고, 실행자가 고칠 수 있다. 서버는 범위만
--   본다 — 0 이상, 실제 결제액 이하.
--
-- 1단계는 감소만 한다
--   증가는 정원 검사가 필요한데, trg_enforce_ticket_capacity 가
--   `before insert` 에만 걸려 있어 UPDATE 로 인원을 올리면 서버 검사가
--   통째로 없다. 오버셀이 난다. 증가를 열려면 그 트리거부터 확장해야 한다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 실행해도 안전.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 인원 변경 RPC
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_change_party_size(
  p_purchase_id  text,
  p_new_pax      integer,
  p_refund       integer,
  p_reason       text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_is_super     boolean := false;
  v_is_resadmin  boolean := false;
  t              public.tickets%rowtype;
  v_old_pax      integer;
  v_price        integer;
  v_refund       integer;
  v_ex           jsonb;
  v_dep_used     integer;
  v_dep_paid_back integer := 0;
  v_card_paid    integer;
  v_is_card      boolean;
  v_dep_refund   integer;
  v_card_refund  integer;
  v_mem_out      integer := 0;
  v_gen_out      integer := 0;
  v_split_mem    integer := 0;
  v_split_gen    integer := 0;
  v_mem_bal      integer;
  v_gen_bal      integer;
  v_new_total    integer;
  v_now          timestamptz := now();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- ── 대상 구매 ──
  select * into t from public.tickets where purchase_id = p_purchase_id;
  if not found then
    raise exception 'PURCHASE_NOT_FOUND: %', p_purchase_id;
  end if;
  if t.status in ('cancelled', 'canceled') then
    raise exception 'ALREADY_CANCELLED';
  end if;

  -- ── 권한 ──
  select (role in ('super_admin','superadmin')) into v_is_super
    from public.profiles where id = v_uid;
  v_is_super := coalesce(v_is_super, false);

  if not v_is_super then
    -- is_restaurant_admin_of 는 tickets_admin_rls.sql 이 만든다.
    -- 없으면 슈퍼어드민만 쓸 수 있게 두고 조용히 거절한다 — 없는 함수를
    -- 부르다 죽는 것보다 낫다.
    if to_regprocedure('public.is_restaurant_admin_of(text)') is not null then
      execute 'select public.is_restaurant_admin_of($1)'
        into v_is_resadmin using t.restaurant_id::text;
    end if;
    if not coalesce(v_is_resadmin, false) then
      raise exception 'FORBIDDEN: 슈퍼어드민 또는 해당 매장 어드민만 변경할 수 있습니다';
    end if;
  end if;

  -- ── 인원 검사 (1단계 = 감소만) ──
  v_old_pax := coalesce(t.party_size, 1);
  if p_new_pax is null or p_new_pax < 1 then
    raise exception 'BAD_PAX: 1명 이상이어야 합니다';
  end if;
  if p_new_pax > v_old_pax then
    -- 늘리려면 정원 검사가 필요한데 UPDATE 경로에는 그 트리거가 없다.
    raise exception 'INCREASE_NOT_SUPPORTED: 인원 증가는 아직 지원하지 않습니다 (정원 검사 미비)';
  end if;
  if p_new_pax = v_old_pax then
    raise exception 'NO_CHANGE: 인원이 같습니다';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REASON_REQUIRED: 사유를 입력해야 합니다';
  end if;

  -- ── 환불액 범위 ──
  v_price  := coalesce(t.price, 0);
  v_refund := greatest(0, coalesce(p_refund, 0));
  if v_refund > v_price then
    raise exception 'REFUND_TOO_LARGE: 결제액(%)을 넘을 수 없습니다', v_price;
  end if;

  -- ── 카드분 / 예치금분 분리 (취소 환불과 같은 규칙) ──
  --   카드로 낸 금액을 예치금에 적립하면서 토스에서도 환불하면 이중이 된다.
  --   예치금으로 낸 만큼만 예치금으로 돌리고, 나머지는 카드 환불 대기로 남긴다.
  v_ex        := coalesce(t.extra_data, '{}'::jsonb);
  v_dep_used  := coalesce((v_ex->>'depositUsed')::integer, 0);
  v_card_paid := coalesce((v_ex->>'cardPaid')::integer, 0);
  v_is_card   := (v_card_paid > 0) or (v_ex->>'paidBy' = 'card+deposit');

  if v_is_card then
    -- ⚠ 이미 예치금으로 돌려준 만큼을 뺀다.
    --   depositUsed 는 결제 시점 값이라 변경이 반복돼도 줄지 않는다. 그대로 쓰면
    --   두 번째 변경에서 「예치금으로 낸 돈」을 또 한도로 잡아, 예치금으로 낸 것보다
    --   많은 금액이 예치금으로 돌아가고 카드 환불은 그만큼 모자라게 된다.
    select coalesce(sum(abs(amount)), 0) into v_dep_paid_back
      from public.deposit_transactions
     where user_id = t.user_id
       and change_type in ('ticket_pax_change', 'ticket_refund')
       and metadata->>'purchase_id' = p_purchase_id;

    v_dep_refund  := least(v_refund, greatest(0, v_dep_used - v_dep_paid_back));
    v_card_refund := greatest(0, v_refund - v_dep_refund);
  else
    v_dep_refund  := v_refund;
    v_card_refund := 0;
  end if;

  -- ── 예치금은 나간 주머니로 되돌린다 (_depRefundSplit 과 같은 규칙) ──
  if v_dep_refund > 0 then
    select
      coalesce(sum(abs(amount)) filter (where deposit_type = 'membership'), 0),
      coalesce(sum(abs(amount)) filter (where deposit_type <> 'membership'), 0)
      into v_mem_out, v_gen_out
    from public.deposit_transactions
    where user_id = t.user_id
      and change_type = 'ticket_purchase'
      and metadata->>'purchase_id' = p_purchase_id;

    if (v_mem_out + v_gen_out) <= 0 then
      -- 기록이 없으면 멤버십 우선 — 차감이 '멤버십 먼저' 라서 그게 대칭이다
      v_split_mem := v_dep_refund;
      v_split_gen := 0;
    else
      v_split_mem := least(v_dep_refund,
        round(v_dep_refund::numeric * v_mem_out / (v_mem_out + v_gen_out))::integer);
      v_split_gen := v_dep_refund - v_split_mem;
    end if;

    select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0)
      into v_mem_bal, v_gen_bal
    from public.profiles where id = t.user_id for update;

    v_new_total := (v_mem_bal + v_split_mem) + (v_gen_bal + v_split_gen);

    update public.profiles
       set membership_deposit_balance = v_mem_bal + v_split_mem,
           general_deposit_balance    = v_gen_bal + v_split_gen,
           deposit_balance            = v_new_total
     where id = t.user_id;

    -- 주머니가 둘로 나뉘면 두 건으로 남긴다 — 어디로 돌아갔는지 보여야 한다
    if v_split_mem > 0 then
      insert into public.deposit_transactions
        (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
      values (t.user_id, 'membership', 'ticket_pax_change', v_split_mem, v_new_total,
        coalesce(t.restaurant_name, '티켓') || ' 인원 변경 ' || v_old_pax || '인 → ' || p_new_pax || '인 — ' || p_reason,
        jsonb_build_object(
          'purchase_id', p_purchase_id, 'ticket_id', t.ticket_product_id,
          'pax_from', v_old_pax, 'pax_to', p_new_pax,
          'refund_total', v_refund, 'deposit_refund', v_dep_refund,
          'card_refund_pending', v_card_refund,
          'reason', p_reason, 'actor', v_uid,
          'actor_role', case when v_is_super then 'super_admin' else 'restaurant_admin' end));
    end if;
    if v_split_gen > 0 then
      insert into public.deposit_transactions
        (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
      values (t.user_id, 'general', 'ticket_pax_change', v_split_gen, v_new_total,
        coalesce(t.restaurant_name, '티켓') || ' 인원 변경 ' || v_old_pax || '인 → ' || p_new_pax || '인 — ' || p_reason,
        jsonb_build_object(
          'purchase_id', p_purchase_id, 'ticket_id', t.ticket_product_id,
          'pax_from', v_old_pax, 'pax_to', p_new_pax,
          'refund_total', v_refund, 'deposit_refund', v_dep_refund,
          'card_refund_pending', v_card_refund,
          'reason', p_reason, 'actor', v_uid,
          'actor_role', case when v_is_super then 'super_admin' else 'restaurant_admin' end));
    end if;
  end if;

  -- ── 티켓 행 갱신 ──
  --   price 는 '실제로 낸 순액' 이다. 돌려준 만큼 줄인다. 나중에 이 건을
  --   전부 취소하면 그 줄어든 금액을 기준으로 계산돼야 맞다.
  --   pax_changes 는 덧붙이기만 한다 — 이력을 덮어쓰지 않는다.
  v_ex := v_ex || jsonb_build_object(
    'pax_changes',
    coalesce(v_ex->'pax_changes', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'at', v_now, 'from', v_old_pax, 'to', p_new_pax,
      'refund', v_refund, 'deposit_refund', v_dep_refund, 'card_refund', v_card_refund,
      'price_before', v_price, 'price_after', greatest(0, v_price - v_refund),
      'reason', p_reason, 'actor', v_uid,
      'actor_role', case when v_is_super then 'super_admin' else 'restaurant_admin' end)));

  -- 카드로 돌려줄 게 있으면 대기로 남긴다 (취소 때와 같은 모양).
  -- 여러 번 변경될 수 있으니 배열로 쌓는다.
  if v_card_refund > 0 then
    v_ex := v_ex || jsonb_build_object(
      'card_refund_queue',
      coalesce(v_ex->'card_refund_queue', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'amount', v_card_refund, 'order_id', v_ex->>'order_id',
        'reason', '인원 변경 ' || v_old_pax || '인 → ' || p_new_pax || '인 — ' || p_reason,
        'requested_at', v_now, 'status', 'pending')));
  end if;

  update public.tickets
     set party_size = p_new_pax,
         price      = greatest(0, v_price - v_refund),
         extra_data = v_ex
   where purchase_id = p_purchase_id;

  return jsonb_build_object(
    'ok', true,
    'purchase_id', p_purchase_id,
    'user_id', t.user_id,
    'restaurant_name', t.restaurant_name,
    'pax_from', v_old_pax,
    'pax_to', p_new_pax,
    'price_before', v_price,
    'price_after', greatest(0, v_price - v_refund),
    'refund_total', v_refund,
    'deposit_refund', v_dep_refund,
    'deposit_membership', v_split_mem,
    'deposit_general', v_split_gen,
    'card_refund_pending', v_card_refund,
    'actor_role', case when v_is_super then 'super_admin' else 'restaurant_admin' end);
end;
$$;

revoke all on function public.taam_change_party_size(text, integer, integer, text) from public;
grant execute on function public.taam_change_party_size(text, integer, integer, text) to authenticated;

comment on function public.taam_change_party_size(text, integer, integer, text) is
  '판매된 티켓의 인원 감소 + 차액 환불. 슈퍼어드민 또는 해당 매장 어드민만. 한 트랜잭션.';


-- ═══════════════════════════════════════════════════════════════
-- ② 확인 — 함수가 올라갔는지
-- ═══════════════════════════════════════════════════════════════
select proname as "함수",
       pg_get_function_identity_arguments(oid) as "인자",
       prosecdef as "security_definer"
from pg_proc
where proname = 'taam_change_party_size';


-- ═══════════════════════════════════════════════════════════════
-- ③ 인원이 변경된 구매 보기 (읽기 전용)
-- ═══════════════════════════════════════════════════════════════
select
  t.purchase_id                                        as "구매ID",
  coalesce(t.restaurant_name, '')                      as "매장",
  coalesce(p.display_name, '')                         as "회원",
  t.party_size                                         as "현재인원",
  t.price                                              as "현재금액",
  jsonb_array_length(coalesce(t.extra_data->'pax_changes', '[]'::jsonb)) as "변경횟수",
  t.extra_data->'pax_changes'                          as "변경이력",
  case when jsonb_array_length(coalesce(t.extra_data->'card_refund_queue','[]'::jsonb)) > 0
       then '⚠ 토스에서 부분취소 필요' else '' end     as "카드환불"
from public.tickets t
left join public.profiles p on p.id = t.user_id
where t.extra_data ? 'pax_changes'
order by t.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ④ 되돌리기 — 잘못 실행했을 때
-- ═══════════════════════════════════════════════════════════════
--   자동 원복은 만들지 않았다. 예치금이 이미 움직였고, 그 사이 회원이
--   그 잔액을 썼을 수 있어 기계적으로 되돌리면 잔액이 음수가 된다.
--   ③ 의 「변경이력」에 전후 값이 다 있으므로, 슈퍼어드민이 값을 보고
--   손으로 되돌린다. 아래는 그 형태다.
/*
-- 1) 인원·금액 원복 (변경이력의 from · price_before 를 넣는다)
update public.tickets
   set party_size = 4,
       price      = 1800000
 where purchase_id = '여기에-구매ID';

-- 2) 돌려준 예치금 회수 (변경이력의 deposit_refund 를 뺀다)
--    ⚠ 잔액이 부족하면 guard_deposit_balance 트리거가 막는다. 그게 맞다.
update public.profiles
   set general_deposit_balance = general_deposit_balance - 0,
       membership_deposit_balance = membership_deposit_balance - 0,
       deposit_balance = membership_deposit_balance + general_deposit_balance
 where id = '여기에-회원-UUID';
*/
