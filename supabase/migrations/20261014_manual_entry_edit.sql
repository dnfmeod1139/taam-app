-- ═══════════════════════════════════════════════════════════════
-- 티켓 캘린더 「수동 추가」 내역 수정 — 좌석 연동 행(MAN-) · 2026-10-14
-- ═══════════════════════════════════════════════════════════════
-- 왜 RPC 인가
--   캘린더의 「＋ 수동 추가」가 본 티켓에 연결되면 tickets 에 MAN- 행이 들어간다(status 'manual', 소유자 = 입력한 어드민).
--   이 행을 고치는 길이 없었다 — ×(취소) 뒤 다시 추가해야 했고, 그 사이 좌석이 풀려 다른 회원이 채갈 수 있다.
--   직접 UPDATE 는 둘이 막는다.
--     ① trg_taam_guard_ticket_row — 매장 어드민 세션은 party_size·price 를 못 고친다(의도된 잠금, 풀지 않는다).
--     ② trg_enforce_ticket_capacity 는 BEFORE INSERT 에만 걸려 있다 — UPDATE 로 인원을 늘리면 정원 검사가 통째로 없어
--        오버셀이 난다(ticket_pax_change.sql 이 인원 증가를 막아 둔 이유).
--   그래서 SECURITY DEFINER 로 서버가 자기 권한으로 돌며 안에서 권한·정원을 직접 본다(taam_set_ticket_memo 와 같은 틀).
--
-- 무엇을 고치나
--   이름 · 손님 번호(국내 휴대폰 — 알림톡 수신처) · 인원 · 받은 금액(price) · 유형(초대/오프라인) · 메모.
--   연결 티켓·날짜·시간·매장은 바꾸지 않는다 — 좌석을 다른 회차로 옮기는 일이라 ×(취소) 뒤 다시 추가한다.
--
-- 인원을 늘릴 때
--   정원 트리거와 같은 잠금(tkcap_<회차>)을 잡고 **총 정원(①)만** 본다 — (이 행을 뺀 살아 있는 인원) + 새 인원 ≤ total_pax.
--   1인 한도·허용 인원·조각 차단·고정 슬롯은 회원 자가 구매를 다듬는 규칙이라 어드민이 매장과 잡은 자리에는 안 건다
--   (정산 좌석 KSK- 와 같은 취급 · 20260929_kashikiri_seat_sync3). 정원이 없는 회차(ticket_products 없음 · total_pax 0)는 제한 없음.
--   줄일 때는 검사가 없다. 어느 쪽이든 trg_sync_ticket_soldout 이 회차의 매진·판매중을 되돌린다 — 앱은 status 를 밀지 않는다.
--
-- 누가
--   슈퍼어드민 — 전부 · 매장 어드민 — 자기 매장 행만(is_restaurant_admin_of 또는 taam_is_rest_admin — 둘 중 하나라도 true).
--   회원 세션이 남의 행을 겨눠도 번호·이름을 되돌려 주지 않는다(FORBIDDEN 한 줄).
--
-- 남기는 것
--   extra_data.edits 에 {at, by, name, role, from, to} 를 쌓는다(최근 30건) + edited_at / edited_by. 바뀐 게 없으면 쓰지 않는다.
--
-- 연결 안 한 수동 기록(daegwan_manual)은 RLS 가 이미 어드민에게 전부 열려 있어 앱이 직접 UPDATE 한다 — 이 파일과 무관.
-- 회귀: bash sql/_test/t_manual_edit.sh
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_manual_entry_update(
  p_purchase_id text,
  p_name        text,
  p_phone       text,
  p_pax         integer,
  p_amount      integer,
  p_ttype       text,
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
  v_actor_name  text := '';
  t             public.tickets%rowtype;
  v_ex          jsonb;
  v_name        text;
  v_digits      text;
  v_phone       text;
  v_pax         integer;
  v_amount      integer;
  v_ttype       text;
  v_memo        text;
  v_cap         integer;
  v_sold        integer;
  v_from        jsonb;
  v_to          jsonb;
  v_changed     text[] := '{}';
  v_edits       jsonb;
  k             text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- ── 대상 행 (잠근다 — 같은 행을 두 어드민이 동시에 고치는 경주) ──
  select * into t from public.tickets where purchase_id = p_purchase_id for update;
  if not found then
    raise exception 'PURCHASE_NOT_FOUND: %', p_purchase_id;
  end if;

  v_ex := coalesce(t.extra_data, '{}'::jsonb);
  if not (coalesce(t.purchase_id, '') like 'MAN-%' or coalesce(v_ex->>'manualEntry', '') = 'true') then
    raise exception 'NOT_MANUAL: 수동 추가 행만 고칠 수 있습니다';
  end if;
  if coalesce(t.status, '') in ('cancelled', 'canceled', 'expired') then
    raise exception 'ALREADY_CANCELLED';
  end if;

  -- ── 권한 (taam_set_ticket_memo · taam_change_party_size 와 같은 판정) ──
  select (role in ('super_admin', 'superadmin')), coalesce(display_name, '')
    into v_is_super, v_actor_name
    from public.profiles where id = v_uid;
  v_is_super := coalesce(v_is_super, false);

  if not v_is_super then
    if to_regprocedure('public.is_restaurant_admin_of(text)') is not null then
      execute 'select public.is_restaurant_admin_of($1)' into v_is_resadmin using t.restaurant_id::text;
    end if;
    if not coalesce(v_is_resadmin, false) and to_regprocedure('public.taam_is_rest_admin(text)') is not null then
      execute 'select public.taam_is_rest_admin($1)' into v_is_resadmin using t.restaurant_id::text;
    end if;
    if not coalesce(v_is_resadmin, false) then
      raise exception 'FORBIDDEN: 슈퍼어드민 또는 해당 매장 어드민만 고칠 수 있습니다';
    end if;
  end if;

  -- ── 값 정리 ──
  v_name := nullif(btrim(coalesce(p_name, '')), '');
  if v_name is null then v_name := '수동 예약'; end if;          -- 추가 때(tcalManualSave)와 같은 기본값
  if length(v_name) > 80 then
    raise exception 'NAME_TOO_LONG: 이름은 80자까지입니다';
  end if;

  -- 번호: 앱 _krMobile · Edge krMobile 과 같은 규칙 — 국내 휴대폰만. 비우면 ''(알림톡 안 보냄), 다른 번호면 거절.
  v_digits := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
  if v_digits like '+82%' then
    v_digits := '0' || substr(v_digits, 4);
  elsif v_digits like '82%' and length(v_digits) >= 11 then
    v_digits := '0' || substr(v_digits, 3);
  end if;
  v_digits := regexp_replace(v_digits, '[^0-9]', '', 'g');
  if v_digits = '' then
    v_phone := '';
  elsif v_digits ~ '^01[016789][0-9]{7,8}$' then
    v_phone := v_digits;
  else
    raise exception 'BAD_PHONE: 국내 휴대폰 번호(010-…)만 받습니다';
  end if;

  v_pax := coalesce(p_pax, t.party_size, 1);
  if v_pax < 1 or v_pax > 99 then
    raise exception 'BAD_PAX: 인원은 1~99명이어야 합니다';
  end if;
  v_amount := greatest(0, coalesce(p_amount, t.price, 0));
  v_ttype  := case when p_ttype in ('초대', '오프라인') then p_ttype else coalesce(v_ex->>'ttype', '오프라인') end;
  v_memo   := btrim(coalesce(p_memo, ''));
  if length(v_memo) > 1000 then
    raise exception 'MEMO_TOO_LONG: 메모는 1000자까지입니다';
  end if;

  v_from := jsonb_build_object(
    'name',  coalesce(t.buyer_name, ''),
    'phone', coalesce(t.buyer_phone, ''),
    'pax',   coalesce(t.party_size, 0),
    'price', coalesce(t.price, 0),
    'ttype', coalesce(v_ex->>'ttype', '오프라인'),
    'memo',  coalesce(v_ex->>'memo', ''));
  v_to := jsonb_build_object(
    'name', v_name, 'phone', v_phone, 'pax', v_pax, 'price', v_amount, 'ttype', v_ttype, 'memo', v_memo);

  if v_from = v_to then
    -- 바뀐 게 없으면 쓰지 않는다 — 빈 수정 기록이 쌓이지 않게
    return jsonb_build_object('ok', true, 'purchase_id', t.purchase_id, 'changed', '[]'::jsonb,
      'name', v_name, 'phone', v_phone, 'pax', v_pax, 'price', v_amount, 'ttype', v_ttype, 'memo', v_memo);
  end if;
  foreach k in array array['name', 'phone', 'pax', 'price', 'ttype', 'memo'] loop
    if v_from->k is distinct from v_to->k then v_changed := array_append(v_changed, k); end if;
  end loop;

  -- ── 인원을 늘리면 정원을 본다 (정원 트리거와 같은 잠금 · 총 정원만) ──
  if v_pax > coalesce(t.party_size, 0) and t.ticket_product_id is not null then
    select total_pax into v_cap from public.ticket_products where id = t.ticket_product_id;
    if coalesce(v_cap, 0) > 0 then
      perform pg_advisory_xact_lock(hashtext('tkcap_' || t.ticket_product_id));
      select coalesce(sum(party_size), 0) into v_sold
        from public.tickets
       where ticket_product_id = t.ticket_product_id
         and coalesce(status, '') <> 'cancelled'
         and id <> t.id;                                        -- 이 행의 옛 인원은 빼고 센다
      if v_sold + v_pax > v_cap then
        raise exception 'TICKET_SOLD_OUT: 잔여 % 석, 요청 % 명', greatest(0, v_cap - v_sold), v_pax
          using errcode = 'P0001';
      end if;
    end if;
  end if;

  -- ── 수정 기록 (최근 30건) ──
  v_edits := coalesce(v_ex->'edits', '[]'::jsonb);
  if jsonb_typeof(v_edits) <> 'array' then v_edits := '[]'::jsonb; end if;
  v_edits := v_edits || jsonb_build_array(jsonb_build_object(
    'at',   now(),
    'by',   v_uid,
    'name', nullif(v_actor_name, ''),
    'role', case when v_is_super then 'super_admin' else 'restaurant_admin' end,
    'from', v_from,
    'to',   v_to));
  if jsonb_array_length(v_edits) > 30 then
    select coalesce(jsonb_agg(e order by n), '[]'::jsonb) into v_edits
      from (select e, n from jsonb_array_elements(v_edits) with ordinality as x(e, n)
             order by n desc limit 30) s;
  end if;

  v_ex := v_ex || jsonb_build_object(
    'ttype', v_ttype, 'memo', v_memo,
    'edited_at', now(), 'edited_by', v_uid, 'edits', v_edits);

  -- SECURITY DEFINER 라 current_user 가 소유자여서 trg_taam_guard_ticket_row 를 지난다(확정 RPC 와 같은 길).
  -- user_id·status·ticket_product_id·reservation_date·visit_time 은 건드리지 않으므로 trg_taam_guard_ticket_unique 도 돌지 않는다.
  update public.tickets
     set buyer_name  = v_name,
         buyer_phone = v_phone,
         party_size  = v_pax,
         price       = v_amount,
         extra_data  = v_ex
   where id = t.id;

  return jsonb_build_object(
    'ok', true, 'purchase_id', t.purchase_id, 'changed', to_jsonb(v_changed),
    'name', v_name, 'phone', v_phone, 'pax', v_pax, 'price', v_amount, 'ttype', v_ttype, 'memo', v_memo,
    'edit_count', jsonb_array_length(v_edits));
end;
$$;

revoke all on function public.taam_manual_entry_update(text, text, text, integer, integer, text, text) from public;
grant execute on function public.taam_manual_entry_update(text, text, text, integer, integer, text, text) to authenticated;

comment on function public.taam_manual_entry_update(text, text, text, integer, integer, text, text) is
  '티켓 캘린더 수동 추가(MAN-) 행 수정 — 이름·번호·인원·받은금액·유형·메모. 슈퍼어드민 또는 매장 어드민. 인원 증가는 총 정원 검사(tkcap 잠금). 연결 티켓·날짜는 바꾸지 않는다. 2026-10-14';

-- ═══════════════════════════════════════════════════════════════
-- 확인 (하나로) — ❌ 가 한 줄도 없어야 정상
-- ═══════════════════════════════════════════════════════════════
select '함수 taam_manual_entry_update' as 항목,
       case when to_regprocedure('public.taam_manual_entry_update(text,text,text,integer,integer,text,text)') is not null then '✅' else '❌ 없음' end as 결과
union all
select 'security definer',
       case when coalesce((select prosecdef from pg_proc where oid = to_regprocedure('public.taam_manual_entry_update(text,text,text,integer,integer,text,text)')), false) then '✅' else '❌' end
union all
select 'authenticated 실행 권한',
       case when has_function_privilege('authenticated', 'public.taam_manual_entry_update(text,text,text,integer,integer,text,text)', 'execute') then '✅' else '❌' end
union all
select 'anon 실행 권한 없음',
       case when not has_function_privilege('anon', 'public.taam_manual_entry_update(text,text,text,integer,integer,text,text)', 'execute') then '✅' else '❌ anon 이 부를 수 있음' end
union all
select '정원 트리거는 그대로 INSERT 전용 (이 파일이 건드리지 않음)',
       case when exists (select 1 from pg_trigger where tgname = 'trg_enforce_ticket_capacity' and not tgisinternal) then '✅' else '— (로컬 픽스처엔 없음)' end;
