-- ═══════════════════════════════════════════════════════════════
-- 수동 추가 내역 수정 RPC 2차 — 적대 리뷰(45 에이전트, 2026-10-14) 반영
-- ═══════════════════════════════════════════════════════════════
-- 1차(20261014_manual_entry_edit.sql)를 라이브에 올린 뒤 적대 리뷰에서 확정된 것 셋을 고친다. 함수 시그니처가 바뀌므로(8번째 인자)
-- 옛 7인자 판을 지우고 다시 만든다 — 같은 이름의 오버로드가 둘 남으면 PostgREST 가 어느 쪽을 고를지 모호해진다.
--
-- ① 낡은 화면이 남의 수정을 되돌린다 (STALE_EDIT)
--    for update 는 「쓰기」만 직렬화한다. 캘린더는 열 때만 tickets 를 읽으므로(실시간 갱신 없음), A 가 인원 2→3 으로 고친 뒤
--    B 가 옛 화면(인원 2)에서 이름만 고쳐 저장하면 앱이 여섯 칸을 전부 보내 인원이 2 로 조용히 되돌아갔다 — 그 순간 회차가
--    매진→판매중으로 풀려 취소표 푸시가 전원에게 나가고, 수정 기록은 B 가 3→2 로 줄인 것으로 남았다.
--    → 앱이 「내가 본 값」(p_expect: name·phone·pax·price·ttype·memo)을 함께 보내고, 서버는 지금 행과 한 칸이라도 다르면
--      STALE_EDIT 로 거절한다(텍스트 비교 · p_expect 에 있는 키만). 앱은 그 자리에서 다시 읽어 보여 준다.
--    NULL 은 「그대로 둔다」로 통일한다 — 종전엔 pax·price·ttype 만 그대로 두고 name 은 '수동 예약', phone·memo 는 '' 로 바꿨다.
-- ② 번호를 바꾸면 「✓ 카톡」 표시가 거짓이 된다
--    처음 적은 번호가 틀려 엉뚱한 사람에게 알림톡이 나간 뒤 번호만 고치면, kakao_sent_at 이 남아 캘린더가 새 번호 옆에
--    「✓ 카톡 10.14」 를 보여 줬다. → 번호가 바뀌면 kakao_* 네 키를 지운다(옛 번호는 edits[].from.phone 에 남는다).
--    응답에 phone_changed 를 실어 앱이 「새 번호로 지금 보낼까요?」를 묻는다 — 자동으로 보내지는 않는다.
-- ③ (앱 쪽) 함수 없음 폴백이 옛 스냅샷으로 extra_data 를 통째로 덮던 것 · 저장 버튼 이중 클릭 · 선검사 정원 컬럼 — index.html 에서 고쳤다.
--
-- 회귀: bash sql/_test/t_manual_edit.sh (1차 → 2차 순서로 올려 라이브와 같은 상태를 만든다)
-- ═══════════════════════════════════════════════════════════════

drop function if exists public.taam_manual_entry_update(text, text, text, integer, integer, text, text);

create or replace function public.taam_manual_entry_update(
  p_purchase_id text,
  p_name        text,
  p_phone       text,
  p_pax         integer,
  p_amount      integer,
  p_ttype       text,
  p_memo        text,
  p_expect      jsonb default null      -- 앱이 화면에 보여 준 값 {name,phone,pax,price,ttype,memo} — 지금 행과 다르면 STALE_EDIT
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
  v_old_phone   text;
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

  -- ── 대상 행 — 잠금은 「동시에 쓰는」 경주만 막는다. 「낡은 화면에서 쓰는」 경주는 아래 p_expect 가 막는다 ──
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

  -- ── 값 정리 — NULL 은 「그대로 둔다」 ──
  if p_name is null then
    v_name := coalesce(nullif(btrim(coalesce(t.buyer_name, '')), ''), '수동 예약');
  else
    v_name := coalesce(nullif(btrim(p_name), ''), '수동 예약');     -- 추가 때(tcalManualSave)와 같은 기본값
  end if;
  if length(v_name) > 80 then
    raise exception 'NAME_TOO_LONG: 이름은 80자까지입니다';
  end if;

  -- 번호: 앱 _krMobile · Edge krMobile 과 같은 규칙 — 국내 휴대폰만. 비우면 ''(알림톡 안 보냄), 다른 번호면 거절.
  v_old_phone := coalesce(t.buyer_phone, '');
  if p_phone is null then
    v_phone := v_old_phone;
  else
    v_digits := regexp_replace(p_phone, '[^0-9+]', '', 'g');
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
  end if;

  v_pax := coalesce(p_pax, t.party_size, 1);
  if v_pax < 1 or v_pax > 99 then
    raise exception 'BAD_PAX: 인원은 1~99명이어야 합니다';
  end if;
  v_amount := greatest(0, coalesce(p_amount, t.price, 0));
  v_ttype  := case when p_ttype in ('초대', '오프라인') then p_ttype else coalesce(v_ex->>'ttype', '오프라인') end;
  if p_memo is null then
    v_memo := coalesce(v_ex->>'memo', '');
  else
    v_memo := btrim(p_memo);
  end if;
  if length(v_memo) > 1000 then
    raise exception 'MEMO_TOO_LONG: 메모는 1000자까지입니다';
  end if;

  v_from := jsonb_build_object(
    'name',  coalesce(t.buyer_name, ''),
    'phone', v_old_phone,
    'pax',   coalesce(t.party_size, 0),
    'price', coalesce(t.price, 0),
    'ttype', coalesce(v_ex->>'ttype', '오프라인'),
    'memo',  coalesce(v_ex->>'memo', ''));
  v_to := jsonb_build_object(
    'name', v_name, 'phone', v_phone, 'pax', v_pax, 'price', v_amount, 'ttype', v_ttype, 'memo', v_memo);

  -- ── 낡은 화면 검사 — 앱이 본 값이 지금 행과 다르면 쓰지 않는다 (텍스트 비교 · 보낸 키만) ──
  if p_expect is not null and jsonb_typeof(p_expect) = 'object' then
    foreach k in array array['name', 'phone', 'pax', 'price', 'ttype', 'memo'] loop
      if (p_expect ? k) and (p_expect->>k) is distinct from (v_from->>k) then
        raise exception 'STALE_EDIT: 다른 어드민이 먼저 고쳤습니다 — 새로 고친 뒤 다시 확인하세요 (%)', k
          using errcode = 'P0001';
      end if;
    end loop;
  end if;

  if v_from = v_to then
    -- 바뀐 게 없으면 쓰지 않는다 — 빈 수정 기록이 쌓이지 않게
    return jsonb_build_object('ok', true, 'purchase_id', t.purchase_id, 'changed', '[]'::jsonb, 'phone_changed', false,
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

  -- ── 번호가 바뀌면 「보냈다」 표시를 지운다 — 새 번호는 아직 안내를 받은 적이 없다 (옛 번호는 edits[].from.phone 에 남는다) ──
  if v_phone is distinct from v_old_phone then
    v_ex := v_ex - 'kakao_sent_at' - 'kakao_result' - 'kakao_tries' - 'kakao_last_try';
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
    'phone_changed', (v_phone is distinct from v_old_phone),
    'name', v_name, 'phone', v_phone, 'pax', v_pax, 'price', v_amount, 'ttype', v_ttype, 'memo', v_memo,
    'edit_count', jsonb_array_length(v_edits));
end;
$$;

revoke all     on function public.taam_manual_entry_update(text, text, text, integer, integer, text, text, jsonb) from public;
revoke execute on function public.taam_manual_entry_update(text, text, text, integer, integer, text, text, jsonb) from anon;   -- Supabase 기본 권한이 붙인 것
grant  execute on function public.taam_manual_entry_update(text, text, text, integer, integer, text, text, jsonb) to authenticated;

comment on function public.taam_manual_entry_update(text, text, text, integer, integer, text, text, jsonb) is
  '티켓 캘린더 수동 추가(MAN-) 행 수정 — 이름·번호·인원·받은금액·유형·메모. 슈퍼어드민 또는 매장 어드민. 인원 증가는 총 정원 검사(tkcap 잠금). p_expect(앱이 본 값)와 다르면 STALE_EDIT. 번호가 바뀌면 kakao_* 초기화. NULL 은 그대로. 2026-10-14 2차';

-- ═══════════════════════════════════════════════════════════════
-- 확인 (하나로) — ❌ 가 한 줄도 없어야 정상
-- ═══════════════════════════════════════════════════════════════
select '새 함수 (8인자 · p_expect)' as 항목,
       case when to_regprocedure('public.taam_manual_entry_update(text,text,text,integer,integer,text,text,jsonb)') is not null then '✅' else '❌ 없음' end as 결과
union all
select '옛 7인자 함수 제거됨',
       case when to_regprocedure('public.taam_manual_entry_update(text,text,text,integer,integer,text,text)') is null then '✅' else '❌ 아직 있음 (PostgREST 모호)' end
union all
select '같은 이름 함수가 하나뿐',
       case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'taam_manual_entry_update') = 1 then '✅' else '❌' end
union all
select 'security definer',
       case when coalesce((select prosecdef from pg_proc where oid = to_regprocedure('public.taam_manual_entry_update(text,text,text,integer,integer,text,text,jsonb)')), false) then '✅' else '❌' end
union all
select 'authenticated 실행 권한',
       case when has_function_privilege('authenticated', 'public.taam_manual_entry_update(text,text,text,integer,integer,text,text,jsonb)', 'execute') then '✅' else '❌' end
union all
select 'anon 실행 권한 없음',
       case when not has_function_privilege('anon', 'public.taam_manual_entry_update(text,text,text,integer,integer,text,text,jsonb)', 'execute') then '✅' else '❌ anon 이 부를 수 있음' end;
