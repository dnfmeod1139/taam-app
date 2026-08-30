-- ═══════════════════════════════════════════════════════════════
-- TAAM — 예약에 운영 메모 달기 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   「어제 그 손님 어떻게 됐지」를 기억으로 이어붙이고 있다. 늦게 온 손님,
--   알러지, 매장과 통화한 내용, 다음에 조심할 것 — 지금은 적을 데가 없어서
--   담당자가 바뀌면 통째로 사라진다.
--
--   회원이 쓴 요청사항(extra_data.memo)과는 다른 칸에 넣는다. 섞으면
--   회원이 쓴 말과 우리가 쓴 말을 구별할 수 없게 되고, 나중에 회원에게
--   보여줄 수 있는 것과 없는 것을 가를 수 없다.
--
-- 왜 RPC 인가 (클라이언트에서 UPDATE 하면 안 되는 이유)
--   tickets 는 레스토랑 어드민에게 SELECT 만 열려 있다
--   (tickets_admin_rls.sql). 그 잠금은 의도된 것이라 풀지 않는다.
--   메모 하나 때문에 tickets 를 통째로 UPDATE 가능하게 열면, 같은 문으로
--   price · party_size · status 도 열린다. 돈이 걸린 칸이다.
--   그래서 SECURITY DEFINER 로 서버가 자기 권한으로 돌면서, 안에서
--   권한을 검사하고 extra_data 의 그 칸 하나만 바꾼다.
--
-- 누가 부를 수 있나
--   · 슈퍼어드민 — 전부
--   · 레스토랑 어드민 — 자기 매장 예약만 (is_restaurant_admin_of)
--   taam_change_party_size 와 같은 판정을 쓴다. 권한 규칙이 두 벌이 되면
--   한쪽만 고쳐지는 날이 온다.
--
-- 누가 언제 썼는지 남긴다
--   메모는 나중에 「누가 이렇게 적었지」가 반드시 나온다. 본문만 남기면
--   그때 아무도 답을 못 한다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 실행해도 안전.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_set_ticket_memo(
  p_purchase_id text,
  p_memo        text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid         uuid := auth.uid();
  v_is_super    boolean := false;
  v_is_resadmin boolean := false;
  v_role        text;
  v_name        text;
  t             public.tickets%rowtype;
  v_memo        text;
  v_ex          jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into t from public.tickets where purchase_id = p_purchase_id;
  if not found then
    raise exception 'PURCHASE_NOT_FOUND: %', p_purchase_id;
  end if;

  -- ── 권한 ── (taam_change_party_size 와 같은 판정)
  select (role in ('super_admin','superadmin')), coalesce(display_name, '')
    into v_is_super, v_name
    from public.profiles where id = v_uid;
  v_is_super := coalesce(v_is_super, false);

  if not v_is_super then
    -- is_restaurant_admin_of 는 tickets_admin_rls.sql 이 만든다.
    -- 없으면 슈퍼어드민만 쓸 수 있게 두고 거절한다 — 없는 함수를 부르다
    -- 죽는 것보다 낫다.
    if to_regprocedure('public.is_restaurant_admin_of(text)') is not null then
      execute 'select public.is_restaurant_admin_of($1)'
        into v_is_resadmin using t.restaurant_id::text;
    end if;
    if not coalesce(v_is_resadmin, false) then
      raise exception 'FORBIDDEN: 슈퍼어드민 또는 해당 매장 어드민만 메모를 쓸 수 있습니다';
    end if;
  end if;

  -- ── 본문 ──
  --   빈 값이면 칸을 지운다. 빈 문자열을 남기면 「메모 있음」으로 보인다.
  v_memo := nullif(btrim(coalesce(p_memo, '')), '');
  if v_memo is not null and length(v_memo) > 1000 then
    raise exception 'MEMO_TOO_LONG: 1000자까지 쓸 수 있습니다';
  end if;

  v_role := case when v_is_super then 'super_admin' else 'restaurant_admin' end;
  v_ex   := coalesce(t.extra_data, '{}'::jsonb);

  if v_memo is null then
    v_ex := v_ex - 'admin_memo' - 'admin_memo_meta';
  else
    v_ex := jsonb_set(v_ex, '{admin_memo}', to_jsonb(v_memo), true);
    v_ex := jsonb_set(v_ex, '{admin_memo_meta}', jsonb_build_object(
              'at',   to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
              'by',   v_uid,
              'name', nullif(v_name, ''),
              'role', v_role), true);
  end if;

  update public.tickets set extra_data = v_ex where purchase_id = p_purchase_id;

  return jsonb_build_object(
    'ok',   true,
    'memo', v_memo,
    'meta', v_ex -> 'admin_memo_meta'
  );
end;
$$;

revoke all on function public.taam_set_ticket_memo(text,text) from public;
grant execute on function public.taam_set_ticket_memo(text,text) to authenticated;

comment on function public.taam_set_ticket_memo(text,text) is
  '예약에 운영 메모 달기. 슈퍼어드민 또는 해당 매장 어드민만. 빈 값이면 삭제.';


-- ═══════════════════════════════════════════════════════════════
-- 확인
-- ═══════════════════════════════════════════════════════════════
select proname as "함수",
       pg_get_function_identity_arguments(oid) as "인자"
from pg_proc
where proname = 'taam_set_ticket_memo';

-- 지금 메모가 달린 예약 (없으면 0건이 정상)
select purchase_id                              as "구매번호",
       restaurant_name                          as "매장",
       buyer_name                               as "회원",
       extra_data ->> 'admin_memo'              as "운영 메모",
       extra_data -> 'admin_memo_meta' ->> 'name' as "쓴 사람"
from public.tickets
where extra_data ? 'admin_memo'
order by reservation_date desc
limit 20;
