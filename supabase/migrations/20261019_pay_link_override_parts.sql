-- ═══════════════════════════════════════════════════════════════
-- 결제 링크 · 티켓 좌석 금액 수정을 항목별로 — 식사비 · 대행비 · 주류 미니멈(1인) × 인원 (2026-10-19 운영 요청)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 「금액 수정」이 받을 금액 한 칸뿐이라 무엇을 깎았는지(식사·대행·주류) 남지 않았고, 환불 견적 D-31 은 언제나 **정가 대행비**를 뺐다 —
--     대행비를 깎아 받은 링크는 환불 때 낸 것보다 많은 대행비를 떼고(소환불), 올려 받은 링크는 덜 뗐다(과환불).
-- 무엇:
--   ① taam_pay_link_create('ticket', p) 가 p.parts = {meal, agency, wine}(1인 · 링크 통화 · 빈 값 0)를 받는다. 받을 금액 = (식사+대행+주류) × 인원을 **서버가 센다**
--      (USD 센트 · KRW/JPY 정수 · 앱이 보낸 total 이 다르면 PARTS_TOTAL_MISMATCH · 음수·숫자 아님 BAD_PARTS). 정가 항목과 셋 다 같으면 수정이 아니다(정가 그대로 · 사유 불필요).
--      다르면 종전 금액 수정 규칙 그대로(슈퍼어드민만 · 사유 필수 · 좌석 행 payAmount 지움) + payload.override_parts = {meal, agency, wine, pax, currency} ·
--      어드민 메모에 「(1인 식사 … + 대행 … + 주류 … × N인)」. 총액이 정가와 같아도 대행비가 다르면 수정으로 친다(환불 기준이 바뀐다). p.total 만 보내는 옛 앱 판도 그대로 돈다.
--   ② taam_link_invite_refund_quote 는 payload.override_parts.agency 가 있고 **항목 합 × 인원이 지금 청구액과 같을 때만** 그 값(× 그 인원)을 대행비로 뺀다(원화·외화 모두) — 아니면 종전(좌석 행 스냅샷).
--   ③ taam_pay_link_set_amount(미결제 금액 변경)는 총액을 바꾸면 override_parts 를 지운다(메모 「항목 내역 해제」) — 낡은 항목이 환불 기준으로 남지 않게(적대 리뷰).
--   ⚠ 둘 다 라이브 함수 교체 — 본문 md5 가 저장소 직전 판(create 75a262d65111c7b646584f4ee02eb6aa · quote fa4c2c741daaf83d97ad05edf99bae2b)과 같을 때만. 이미 새 판(override_parts)이면 ✅ · 모르는 판 ❌ 건너뜀.
--   청구 행(kashikiri_charges)은 슈퍼어드민(kc_super)과 결제한 회원 본인(kc_mine)만 읽는다 — 매장 어드민에게 협의 항목이 새지 않는다.
-- 회귀: bash sql/_test/t_pay_link.sh · 스크래치 paylink.js
-- ═══════════════════════════════════════════════════════════════

drop table if exists _plp; create temp table _plp(name text primary key, status text);
do $do$
declare v_live text; v_src text;
begin
  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regprocedure('public.taam_pay_link_create(text,jsonb)');
  if v_live is null then
    insert into _plp values ('taam_pay_link_create', '❌ 라이브에 함수가 없다 — 20261018_pay_link.sql 먼저');
  elsif v_src like '%override_parts%' then
    insert into _plp values ('taam_pay_link_create', '✅ 이미 새 판(항목별 금액)');
  elsif v_live <> '75a262d65111c7b646584f4ee02eb6aa' then
    insert into _plp values ('taam_pay_link_create', '❌ 라이브 본문이 저장소 직전 판과 다르다 — 건너뜀 (md5 ' || v_live || ') · 20261019_pay_link_ticket_override.sql 먼저');
  else
    execute $fn$
create or replace function public.taam_pay_link_create(p_purpose text, p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $b$
declare
  v_uid uuid := auth.uid(); v_super boolean := false;
  v_res json; v_cid uuid; v_user uuid; v_ch public.kashikiri_charges%rowtype;
  v_cur text; v_fx numeric; v_pay numeric; v_krw bigint; v_fee numeric; v_total numeric; v_fee_krw bigint;
  v_tier text; v_kind text; v_price jsonb; v_over boolean := false; v_note text;
  v_name text; v_phone text; v_title text; v_sub text; v_days int; v_tp public.ticket_products%rowtype;
  v_vdate date; v_vslot text;
  v_pm numeric; v_pa numeric; v_pw numeric; v_lpm numeric; v_lpa numeric; v_lpw numeric; v_parts boolean := false; v_npax int; v_pfx jsonb; v_ptxt text;   -- 🆕 2026-10-19 항목별 금액
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  begin v_super := coalesce(public._taam_uid_is_super(), false); exception when others then v_super := false; end;
  p := coalesce(p, '{}'::jsonb);

  -- ── 티켓 좌석: 금액·홀드·권한(슈퍼어드민 또는 그 매장 어드민)은 링크 초대 함수가 그대로 맡는다 ──
  if p_purpose = 'ticket' then
    v_user := nullif(p->>'user_id', '')::uuid;
    if v_user is not null then
      if not v_super then raise exception '권한이 없습니다' using errcode = '42501'; end if;   -- 회원 지정(결제 뒤 소유 이전)은 슈퍼어드민만 — 매장 어드민이 임의 회원에게 티켓을 붙이지 못하게
      if not exists (select 1 from public.profiles where id = v_user and deleted_at is null) then
        raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
      end if;
      -- 「한 회원 = 한 회차 1건 · 같은 날 같은 시간대 1건」을 만들 때 먼저 본다 (결제 뒤 소유 이전이 가드에 막히지 않게)
      --   가드(taam_guard_purchase_unique · 20261014)와 **같은 식**으로 센다 — 날짜 파서 _taam_pu_visit_date · 시간대 taam_time_slot · 빈 날짜·시각은 회차(ticket_products)로 보충.
      --   (문자열 '16:00' 비교에 빈 visit_time 을 무조건 겹침으로 보던 선검사는 가드가 허락하는 점심+저녁 링크를 거절했다 — 3차 리뷰)
      if exists (select 1 from public.tickets k where k.user_id = v_user and k.ticket_product_id::text = p->>'ticket_id'
                   and coalesce(k.status,'') not in ('cancelled','canceled','expired') and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)) then
        raise exception 'DUPLICATE_PURCHASE' using errcode = '23505';
      end if;
      select * into v_tp from public.ticket_products where id::text = p->>'ticket_id';
      v_vdate := coalesce(public._taam_pu_visit_date(p->>'visit_date'), public._taam_pu_visit_date(v_tp.date));
      v_vslot := public.taam_time_slot(coalesce(nullif(btrim(coalesce(p->>'visit_time','')),''), nullif(btrim(coalesce(v_tp.time,'')),'')));
      if v_vdate is not null and exists (
           select 1 from public.tickets k
             left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
            where k.user_id = v_user
              and coalesce(k.status,'') not in ('cancelled','canceled','expired')
              and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
              and coalesce(public._taam_pu_visit_date(k.reservation_date), public._taam_pu_visit_date(tp.date)) = v_vdate
              and ( v_vslot is null
                    or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) is null
                    or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) = v_vslot )) then
        raise exception 'TIME_CONFLICT' using errcode = '23505';
      end if;
    end if;
    v_res := public.taam_link_invite_create(p->>'ticket_id', p->>'name', p->>'phone', (p->>'pax')::int, p->>'currency',
                                            nullif(p->>'fx','')::numeric, p->>'visit_date', nullif(p->>'visit_time',''));
    v_cid := (v_res->>'charge_id')::uuid;
    if v_tp.id is null then select * into v_tp from public.ticket_products where id::text = p->>'ticket_id'; end if;
    update public.kashikiri_charges
       set purpose = 'ticket',
           title = coalesce(v_tp.rest_name, '티켓'),
           subtitle = coalesce(p->>'visit_date','') || case when nullif(p->>'visit_time','') is not null then ' ' || (p->>'visit_time') else '' end,
           user_id = coalesce(v_user, user_id),
           payload = jsonb_build_object('ticket_id', p->>'ticket_id', 'pax', (p->>'pax')::int, 'member_uid', v_user,
                                        'member_name', (select display_name from public.profiles where id = v_user))
     where id = v_cid
    returning * into v_ch;
    insert into public.kashikiri_charge_admin (charge_id, created_by) values (v_cid, v_uid) on conflict (charge_id) do update set created_by = excluded.created_by;
    -- 🆕 2026-10-19 금액 수동 설정 — 슈퍼어드민만 · 서버 정가(외화는 확정 해외 정가 기준)와 다르면 사유 필수 · 정가·사유·누가는 어드민 표(회원이 못 읽는 곳)에, 청구 payload 엔 표시 플래그만.
    --   좌석 홀드·정산 회차는 그대로(금액만 바뀐다). 토스 주문·/pay·완료 알림·환불 견적은 모두 청구 금액을 읽으므로 따로 손댈 곳이 없다.
    --   사유가 없으면 예외 → 같은 트랜잭션의 홀드까지 되돌아간다(반쪽 링크가 안 남는다). 정가와 같은 금액은 수정이 아니다(권한도 사유도 묻지 않는다 · 메모는 남긴다).
    --   ⚠ 좌석 행(tickets)에는 협의 금액을 적지 않는다 — 매장 어드민이 자기 매장 행을 읽는다(KSK- 와 같은 원칙). payAmount 를 지우고 priceOverride 만.
    v_total := nullif(p->>'total','')::numeric;
    v_note := nullif(btrim(coalesce(p->>'note','')), '');
    v_cur := upper(coalesce(nullif(p->>'currency',''), 'KRW'));
    v_fx := case when v_cur = 'KRW' then 1 else nullif(p->>'fx','')::numeric end;
    -- 🆕 2026-10-19 항목별 금액 — 1인 기준 식사비·대행비·주류 미니멈(링크 통화). 받을 금액 = 세 항목 합 × 인원을 **서버가 다시 센다**(앱이 보낸 total 은 대조만 · PARTS_TOTAL_MISMATCH).
    --   정가 항목과 셋 다 같으면 수정이 아니다(외화 환산 센트 차이로 「수정」이 되지 않게 · 정가 그대로).
    --   다르면 payload.override_parts 에 적는다 — 환불 견적 D-31 이 「손님이 낸 대행비」로 이 값을 뺀다. 청구 행은 슈퍼어드민·결제 회원만 읽는다(매장 어드민 못 읽음 · 좌석 행엔 안 적는다).
    if jsonb_typeof(p->'parts') = 'object' then
      v_npax := greatest(coalesce(nullif(p->>'pax','')::int, 1), 1);
      begin
        v_pm := coalesce(nullif(btrim(coalesce(p->'parts'->>'meal', '')), '')::numeric, 0);
        v_pa := coalesce(nullif(btrim(coalesce(p->'parts'->>'agency', '')), '')::numeric, 0);
        v_pw := coalesce(nullif(btrim(coalesce(p->'parts'->>'wine', '')), '')::numeric, 0);
      exception when others then raise exception 'BAD_PARTS' using errcode = '22023';
      end;
      if v_pm < 0 or v_pa < 0 or v_pw < 0 then raise exception 'BAD_PARTS' using errcode = '22023'; end if;
      v_pm := case v_cur when 'USD' then round(v_pm, 2) else round(v_pm) end;
      v_pa := case v_cur when 'USD' then round(v_pa, 2) else round(v_pa) end;
      v_pw := case v_cur when 'USD' then round(v_pw, 2) else round(v_pw) end;
      if v_pm + v_pa + v_pw <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
      v_pay := (v_pm + v_pa + v_pw) * v_npax;
      v_pay := case v_cur when 'USD' then round(v_pay, 2) else round(v_pay) end;
      if v_total is not null and (case v_cur when 'USD' then round(v_total, 2) else round(v_total) end) <> v_pay then
        raise exception 'PARTS_TOTAL_MISMATCH' using errcode = '22023';
      end if;
      -- 정가 항목(1인 · 링크 통화) — 원화는 회차 요금, 외화는 확정 해외 정가 또는 원화 ÷ 환율(앱 _plListParts 와 같은 식)
      if v_cur = 'KRW' then
        v_lpm := coalesce(v_tp.meal_fee, 0); v_lpa := coalesce(v_tp.agency_fee, 0); v_lpw := coalesce(v_tp.wine_min, 0);
      else
        v_pfx := case when coalesce(v_fx, 0) > 0 then public.taam_ticket_price_fx(p->>'ticket_id', 1, v_cur, v_fx) end;
        v_lpm := case when v_pfx is null then null
                      when coalesce((v_pfx->'parts'->'meal'->>'fixed')::boolean, false) then (v_pfx->'parts'->'meal'->>'per')::numeric
                      when v_pfx->'parts' ? 'meal' then (case v_cur when 'USD' then round((v_pfx->'parts'->'meal'->>'krw_per')::numeric / v_fx, 2) else round((v_pfx->'parts'->'meal'->>'krw_per')::numeric / v_fx) end)
                      else 0 end;
        v_lpa := case when v_pfx is null then null
                      when coalesce((v_pfx->'parts'->'agency'->>'fixed')::boolean, false) then (v_pfx->'parts'->'agency'->>'per')::numeric
                      when v_pfx->'parts' ? 'agency' then (case v_cur when 'USD' then round((v_pfx->'parts'->'agency'->>'krw_per')::numeric / v_fx, 2) else round((v_pfx->'parts'->'agency'->>'krw_per')::numeric / v_fx) end)
                      else 0 end;
        v_lpw := case when v_pfx is null then null
                      when coalesce((v_pfx->'parts'->'wine'->>'fixed')::boolean, false) then (v_pfx->'parts'->'wine'->>'per')::numeric
                      when v_pfx->'parts' ? 'wine' then (case v_cur when 'USD' then round((v_pfx->'parts'->'wine'->>'krw_per')::numeric / v_fx, 2) else round((v_pfx->'parts'->'wine'->>'krw_per')::numeric / v_fx) end)
                      else 0 end;
      end if;
      if v_pm is distinct from v_lpm or v_pa is distinct from v_lpa or v_pw is distinct from v_lpw then
        v_parts := true; v_total := v_pay;
      else
        v_total := null;   -- 정가 항목 그대로 — 수정 아님
      end if;
    end if;
    if v_total is not null then
      v_pay := case v_cur when 'USD' then round(v_total, 2) else round(v_total) end;
      if v_pay <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
      if v_pay <> v_ch.pay_amount or v_parts then
        if not v_super then raise exception 'PRICE_OVERRIDE_FORBIDDEN' using errcode = '42501'; end if;
        if v_note is null then raise exception 'OVERRIDE_NOTE_REQUIRED' using errcode = '22023'; end if;
        if v_cur <> 'KRW' and coalesce(v_fx, 0) <= 0 then raise exception 'FX_MISSING' using errcode = '22023'; end if;
        v_krw := case v_cur when 'KRW' then v_pay::bigint else round(v_pay * v_fx)::bigint end;
        v_ptxt := case when v_parts then ' (1인 식사 ' || public._taam_ksk_money(v_cur, v_pm, v_pm::int) || ' + 대행 ' || public._taam_ksk_money(v_cur, v_pa, v_pa::int)
                                        || ' + 주류 ' || public._taam_ksk_money(v_cur, v_pw, v_pw::int) || ' × ' || v_npax || '인)' else '' end;
        v_note := '[금액 수정] 정가 ' || public._taam_ksk_money(v_ch.pay_currency, v_ch.pay_amount, v_ch.amount_krw) || ' → ' || public._taam_ksk_money(v_cur, v_pay, v_krw::int) || v_ptxt || ' · ' || v_note;
        if v_pay <> v_ch.pay_amount then
          update public.kashikiri_charges
             set amount_krw = v_krw::int, pay_amount = v_pay, amount_jpy = case when v_cur = 'JPY' then v_pay::int end,
                 payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('price_override', true)
           where id = v_cid
          returning * into v_ch;
          update public.tickets set extra_data = (coalesce(extra_data, '{}'::jsonb) - 'payAmount') || jsonb_build_object('priceOverride', true)
           where purchase_id = v_res->>'purchase_id';
        end if;
        if v_parts then
          update public.kashikiri_charges
             set payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('override_parts',
                           jsonb_build_object('meal', v_pm, 'agency', v_pa, 'wine', v_pw, 'pax', v_npax, 'currency', v_cur))
           where id = v_cid
          returning * into v_ch;
        end if;
      end if;
    end if;
    if v_note is not null then update public.kashikiri_charge_admin set note = v_note where charge_id = v_cid; end if;
    return jsonb_build_object('ok', true, 'purpose', 'ticket', 'charge_id', v_ch.id, 'token', v_ch.token,
                              'url', 'https://taam-app.vercel.app/pay/?t=' || v_ch.token,
                              'amount_krw', v_ch.amount_krw, 'pay_currency', v_ch.pay_currency, 'pay_amount', v_ch.pay_amount,
                              'price_override', coalesce((v_ch.payload->>'price_override')::boolean, false),
                              'override_parts', v_ch.payload->'override_parts',
                              'expires_at', v_ch.expires_at, 'title', v_ch.title, 'subtitle', v_ch.subtitle, 'purchase_id', v_res->>'purchase_id');
  end if;

  if not v_super then raise exception '권한이 없습니다' using errcode = '42501'; end if;
  v_cur := upper(coalesce(nullif(p->>'currency',''), 'KRW'));
  if v_cur not in ('KRW','USD','JPY') then raise exception '통화(%)를 알 수 없습니다', v_cur using errcode = '22023'; end if;
  v_fx := nullif(p->>'fx','')::numeric;
  if v_cur <> 'KRW' and coalesce(v_fx, 0) <= 0 then raise exception '외화로 보내려면 환율(1%=₩)이 필요합니다', v_cur using errcode = '22023'; end if;
  if v_cur = 'KRW' then v_fx := 1; end if;
  v_note := nullif(btrim(coalesce(p->>'note','')), '');

  -- ── 멤버십 ──
  if p_purpose = 'membership' then
    v_user := nullif(p->>'user_id','')::uuid;
    if v_user is null then raise exception 'MEMBER_REQUIRED' using errcode = '22023'; end if;
    select display_name into v_name from public.profiles where id = v_user and deleted_at is null;
    if not found then raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002'; end if;
    v_name := coalesce(nullif(btrim(coalesce(v_name,'')), ''), '회원 ' || left(v_user::text, 8));   -- 이름 없는 회원(label NOT NULL)
    v_tier := upper(coalesce(p->>'tier','')); v_kind := lower(coalesce(nullif(p->>'kind',''),'join'));
    if v_tier not in ('M','T') then raise exception 'BAD_TIER' using errcode = '22023'; end if;
    if v_kind not in ('join','renew') then raise exception 'BAD_KIND' using errcode = '22023'; end if;
    begin v_price := public.taam_membership_price(v_tier, v_kind, v_cur); exception when others then v_price := null; end;
    v_total := nullif(p->>'total','')::numeric; v_fee := nullif(p->>'fee','')::numeric;
    if v_price is not null then
      v_over := (v_total is not null and v_total <> (v_price->>'total')::numeric) or (v_fee is not null and v_fee <> (v_price->>'fee')::numeric);
      v_total := coalesce(v_total, (v_price->>'total')::numeric); v_fee := coalesce(v_fee, (v_price->>'fee')::numeric);
    else
      v_over := true;   -- 규정이 없는 통화(JPY 등)는 전부 어드민 입력
    end if;
    if v_total is null or v_fee is null then raise exception 'NO_PRICE_RULE' using errcode = 'P0002'; end if;
    if v_over and v_note is null then raise exception 'OVERRIDE_NOTE_REQUIRED' using errcode = '22023'; end if;
    if v_total <= 0 or v_fee < 0 or v_fee > v_total then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
    v_pay := case v_cur when 'USD' then round(v_total, 2) else round(v_total) end;
    v_fee := case v_cur when 'USD' then round(v_fee, 2) else round(v_fee) end;
    v_krw := case v_cur when 'KRW' then v_pay::bigint else round(v_pay * v_fx)::bigint end;
    v_fee_krw := case v_cur when 'KRW' then v_fee::bigint else round(v_fee * v_fx)::bigint end;
    v_title := '멤버십 ' || v_tier || case v_kind when 'join' then ' 가입' else ' 갱신 (연회비)' end;   -- 결제 페이지 머리에 TAAM 워드마크가 따로 있다
    v_sub := v_name;
    v_days := greatest(1, least(60, coalesce(nullif(p->>'expires_days','')::int, 14)));
    insert into public.kashikiri_charges (event_id, team_id, label, user_id, amount_krw, pay_currency, pay_fx, pay_amount, expires_at,
                                          purpose, title, subtitle, payload, created_by)
    values (null, null, v_name, v_user, v_krw::int, v_cur, v_fx, v_pay, now() + make_interval(days => v_days),
            'membership', v_title, v_sub,
            jsonb_build_object('tier', v_tier, 'kind', v_kind, 'currency', v_cur, 'fx', v_fx,
                               'total', v_pay, 'fee', v_fee, 'deposit', v_pay - v_fee,
                               'total_krw', v_krw, 'fee_krw', v_fee_krw, 'deposit_krw', v_krw - v_fee_krw,
                               'override', v_over, 'member_name', v_name),
            null)
    returning * into v_ch;
    insert into public.kashikiri_charge_admin (charge_id, note, created_by) values (v_ch.id, v_note, v_uid);   -- 사유 메모는 회원이 못 읽는 표에

  -- ── 자유 금액 ──
  elsif p_purpose = 'custom' then
    v_name := nullif(btrim(coalesce(p->>'name','')), '');
    if v_name is null then raise exception '이름이 필요합니다' using errcode = '22023'; end if;
    v_phone := nullif(regexp_replace(coalesce(p->>'phone',''), '[^0-9+]', '', 'g'), '');
    v_total := nullif(p->>'amount','')::numeric;
    if v_total is null or v_total <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
    v_pay := case v_cur when 'USD' then round(v_total, 2) else round(v_total) end;
    v_krw := case v_cur when 'KRW' then v_pay::bigint else round(v_pay * v_fx)::bigint end;
    v_user := nullif(p->>'user_id','')::uuid;
    v_title := coalesce(nullif(btrim(coalesce(p->>'memo','')),''), '결제');
    v_sub := v_name;
    v_days := greatest(1, least(60, coalesce(nullif(p->>'expires_days','')::int, 7)));
    insert into public.kashikiri_charges (event_id, team_id, label, payer_phone, user_id, amount_krw, pay_currency, pay_fx, pay_amount, expires_at,
                                          purpose, title, subtitle, payload, created_by)
    values (null, null, v_name, v_phone, v_user, v_krw::int, v_cur, v_fx, v_pay, now() + make_interval(days => v_days),
            'custom', v_title, v_sub, jsonb_build_object('memo', nullif(p->>'memo','')), null)
    returning * into v_ch;
    insert into public.kashikiri_charge_admin (charge_id, note, created_by) values (v_ch.id, v_note, v_uid);
  else
    raise exception 'BAD_PURPOSE' using errcode = '22023';
  end if;

  return jsonb_build_object('ok', true, 'purpose', v_ch.purpose, 'charge_id', v_ch.id, 'token', v_ch.token,
                            'url', 'https://taam-app.vercel.app/pay/?t=' || v_ch.token,
                            'amount_krw', v_ch.amount_krw, 'pay_currency', v_ch.pay_currency, 'pay_amount', v_ch.pay_amount,
                            'expires_at', v_ch.expires_at, 'title', v_ch.title, 'subtitle', v_ch.subtitle, 'payload', v_ch.payload);
end $b$;
    $fn$;
    insert into _plp values ('taam_pay_link_create', '✅ 교체 (항목별 금액 · override_parts)');
  end if;

  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_refund_quote(text)');
  if v_live is null then
    insert into _plp values ('taam_link_invite_refund_quote', '❌ 라이브에 함수가 없다');
  elsif v_src like '%override_parts%' then
    insert into _plp values ('taam_link_invite_refund_quote', '✅ 이미 새 판(항목별 대행비)');
  elsif v_live <> 'fa4c2c741daaf83d97ad05edf99bae2b' then
    insert into _plp values ('taam_link_invite_refund_quote', '❌ 라이브 본문이 저장소 직전 판과 다르다 — 건너뜀 (md5 ' || v_live || ') · 20261019_link_invite_refund_agency.sql 먼저');
  else
    execute $fn$
create or replace function public.taam_link_invite_refund_quote(p_charge_id text)
returns json language plpgsql stable security definer set search_path = public as $b$
declare
  v_ch  public.kashikiri_charges%rowtype;
  v_tk  public.tickets%rowtype;
  v_days int; v_agency bigint := 0; v_refund bigint := 0; v_policy text; v_visit date;
  v_cur text; v_pax int; v_agency_pay numeric := 0; v_refund_amt numeric := 0; v_fxq jsonb; v_ov_agency numeric; v_ov_pax int; v_ov_sum numeric;
begin
  select * into v_ch from public.kashikiri_charges where id::text = p_charge_id;
  if not found then raise exception 'CHARGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_ch.status <> 'paid' then
    return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'refund_krw', 0, 'refund_amount', 0, 'policy', 'not_paid');
  end if;
  v_cur := upper(coalesce(v_ch.pay_currency, 'KRW'));
  if coalesce(v_ch.purpose,'') in ('membership','custom') and not coalesce(v_ch.link_invite,false) then
    v_refund := v_ch.amount_krw; v_refund_amt := coalesce(v_ch.pay_amount, v_ch.amount_krw); v_policy := 'admin_full';
  else
    select * into v_tk from public.tickets where purchase_id like 'LINK-%' and extra_data->>'chargeId' = v_ch.id::text order by created_at desc limit 1;
    v_pax := greatest(coalesce(v_tk.party_size,1),1);
    v_agency := coalesce((v_tk.extra_data->>'agencyFee')::bigint, 0) * v_pax;
    -- 🆕 2026-10-19 링크를 만들 때 항목별로 적은 대행비(payload.override_parts.agency · 1인 · 결제 통화)가 있으면 그 값이 손님이 낸 대행비다 — 좌석 행 스냅샷(정가)보다 먼저.
    --   단, 항목 합 × 그 인원이 **지금 청구액과 같을 때만**(같은 통화) — 그 뒤 금액이 바뀌었으면(금액 변경 · 직접 수정) 항목은 낡았으니 쓰지 않고 종전 스냅샷으로(적대 리뷰: 면제한 대행비가 금액 변경 뒤 전액 환불되던 것).
    begin
      if jsonb_typeof(v_ch.payload->'override_parts') = 'object' and upper(coalesce(v_ch.payload->'override_parts'->>'currency', '')) = v_cur then
        v_ov_agency := coalesce(nullif(btrim(coalesce(v_ch.payload->'override_parts'->>'agency', '')), '')::numeric, 0);
        v_ov_pax := greatest(coalesce(nullif(btrim(coalesce(v_ch.payload->'override_parts'->>'pax', '')), '')::int, v_pax), 1);
        v_ov_sum := (coalesce(nullif(btrim(coalesce(v_ch.payload->'override_parts'->>'meal', '')), '')::numeric, 0) + v_ov_agency
                     + coalesce(nullif(btrim(coalesce(v_ch.payload->'override_parts'->>'wine', '')), '')::numeric, 0)) * v_ov_pax;
        v_ov_sum := case v_cur when 'USD' then round(v_ov_sum, 2) else round(v_ov_sum) end;
        if v_ov_sum is distinct from (case when v_cur = 'KRW' then coalesce(v_ch.pay_amount, v_ch.amount_krw) else v_ch.pay_amount end) then v_ov_agency := null; end if;
      end if;
    exception when others then v_ov_agency := null; end;
    if v_ov_agency is not null then v_pax := v_ov_pax; end if;
    if v_ov_agency is not null and v_cur = 'KRW' then v_agency := round(v_ov_agency)::bigint * v_pax; end if;
    -- 🆕 2026-10-19 외화 링크는 **결제 통화**로 센다 — 손님이 낸 대행비(agencyPay 스냅샷 · 확정 외화 또는 원화÷환율)를 빼고 원화는 round(외화×환율).
    --   종전 「amount_krw − 원화 정가 대행비」는 확정 외화 대행비(amount_krw = round(외화×환율))와 기준이 달라 환율 차액만큼 과·소환불했다(적대 리뷰).
    --   스냅샷이 없는 옛 행(2026-10-18 확정 정가 판 사이)은 지금 회차 요금으로 어림 — 확정이면 확정값, 아니면 원화 대행비 ÷ 환율.
    if v_cur <> 'KRW' then
      v_agency_pay := coalesce(v_ov_agency, nullif(btrim(coalesce(v_tk.extra_data->>'agencyPay','')), '')::numeric);
      if v_ov_agency is not null then v_agency := round(v_ov_agency * v_pax * coalesce(v_ch.pay_fx, 0))::bigint; end if;
      if v_agency_pay is null then
        begin v_fxq := public.taam_ticket_price_fx(v_tk.ticket_product_id::text, 1, v_cur, v_ch.pay_fx); exception when others then v_fxq := null; end;
        v_agency_pay := case when coalesce((v_fxq->'parts'->'agency'->>'fixed')::boolean, false) then (v_fxq->'parts'->'agency'->>'per')::numeric
                             when coalesce(v_ch.pay_fx, 0) > 0 then (case v_cur when 'USD' then round(coalesce((v_tk.extra_data->>'agencyFee')::numeric, 0) / v_ch.pay_fx, 2)
                                                                                 else round(coalesce((v_tk.extra_data->>'agencyFee')::numeric, 0) / v_ch.pay_fx) end)
                             else 0 end;
      end if;
      v_agency_pay := coalesce(v_agency_pay, 0) * v_pax;
    end if;
    begin v_visit := to_date(v_tk.reservation_date, 'YYYY.MM.DD'); exception when others then v_visit := null; end;
    v_days := case when v_visit is null then null else (v_visit - (now() at time zone 'Asia/Seoul')::date) end;
    if v_ch.approved_at is not null and now() - v_ch.approved_at <= interval '30 minutes' then
      v_refund := v_ch.amount_krw; v_refund_amt := coalesce(v_ch.pay_amount, v_ch.amount_krw); v_policy := 'within_30min_full';
    elsif v_days is null or v_days >= 31 then
      if v_cur = 'KRW' then
        v_refund := greatest(0, v_ch.amount_krw - v_agency); v_refund_amt := v_refund;
      else
        v_refund_amt := greatest(0, coalesce(v_ch.pay_amount, 0) - v_agency_pay);
        v_refund_amt := case v_cur when 'USD' then round(v_refund_amt, 2) else round(v_refund_amt) end;
        v_refund := round(v_refund_amt * coalesce(v_ch.pay_fx, 0))::bigint;
      end if;
      v_policy := 'd31_minus_agency';
    else
      v_refund := 0; v_refund_amt := 0; v_policy := 'after_d30_none';
    end if;
  end if;
  return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'currency', v_ch.pay_currency, 'purpose', coalesce(v_ch.purpose,'custom'),
    'paid_krw', v_ch.amount_krw, 'paid_amount', v_ch.pay_amount, 'agency_krw', v_agency, 'agency_pay', v_agency_pay, 'days_left', v_days,
    'refund_krw', v_refund,
    'refund_amount', case when v_cur = 'KRW' then v_refund
                          when v_cur = 'JPY' then round(v_refund_amt)
                          else round(v_refund_amt, 2) end,
    'policy', v_policy, 'payment_key', v_ch.payment_key);
end $b$;
    $fn$;
    insert into _plp values ('taam_link_invite_refund_quote', '✅ 교체 (항목별 대행비 우선)');
  end if;
end $do$;


-- ── ③ 미결제 링크 금액 변경 — 총액을 바꾸면 항목 내역(override_parts)을 지운다 (20261019_pay_link_ticket_override.sql 판 + 이 한 가지) ──
--   항목 합 × 인원이 새 총액과 맞지 않게 되면 그 대행비를 환불 기준으로 쓸 수 없다(면제한 대행비가 금액 변경 뒤 전액 환불되던 것 · 적대 리뷰).
--   지우면 환불 견적은 좌석 행 스냅샷(정가 대행비)으로 돌아간다 — 메모에 「항목 내역 해제」를 남긴다. 항목을 다시 정하려면 끊고 새 링크를 만든다.
--   md5 가드 없이 바꾼다 — 같은 날(20261019_pay_link_ticket_override.sql) 만든 함수이고 다른 곳에서 고친 판이 없다.
create or replace function public.taam_pay_link_set_amount(p_charge_id uuid, p_total numeric, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_super boolean := false; v_ch public.kashikiri_charges%rowtype; v_cur text; v_pay numeric; v_krw bigint; v_note text; v_old text; v_had_parts boolean := false;
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  begin v_super := coalesce(public._taam_uid_is_super(), false); exception when others then v_super := false; end;
  if not v_super then raise exception '권한이 없습니다' using errcode = '42501'; end if;
  select * into v_ch from public.kashikiri_charges where id = p_charge_id for update;
  if not found then raise exception 'CHARGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_ch.status <> 'pending' then raise exception 'NOT_PENDING' using errcode = '55000'; end if;
  if v_ch.expires_at is not null and v_ch.expires_at < now() then raise exception 'LINK_EXPIRED' using errcode = '55000'; end if;
  -- 손님이 이미 결제를 시작한 링크(order_start 가 order_id 를 적음)는 금액을 못 바꾼다 — kashikiri-confirm 이 청구를 읽은 뒤 mark_paid_v2 가 다시 읽는 사이에 금액이 바뀌면
  -- 토스는 승인됐는데 우리 기록은 pending 인 최악의 모양이 난다. 끊고 새 링크를 만든다(홀드는 새 링크가 다시 잡는다).
  if v_ch.order_id is not null then raise exception 'PAYMENT_STARTED' using errcode = '55000'; end if;
  if coalesce(v_ch.purpose, case when coalesce(v_ch.link_invite, false) then 'ticket' else 'custom' end) not in ('ticket', 'custom') then
    raise exception 'BAD_PURPOSE' using errcode = '22023';
  end if;
  -- 대관 정산 청구(회차에 붙은 조 몫 · 옛 행은 purpose 가 custom 으로 백필됐다)는 정산 시트가 회차 총액을 검사한다 — 여기서 바꾸면 시트와 어긋난다
  if v_ch.event_id is not null and not coalesce(v_ch.link_invite, false) then raise exception 'SETTLEMENT_CHARGE' using errcode = '22023'; end if;
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if v_note is null then raise exception 'OVERRIDE_NOTE_REQUIRED' using errcode = '22023'; end if;
  v_cur := upper(coalesce(v_ch.pay_currency, 'KRW'));
  if v_cur <> 'KRW' and coalesce(v_ch.pay_fx, 0) <= 0 then raise exception 'FX_MISSING' using errcode = '22023'; end if;   -- 환율 없는 외화 행의 원화를 1 로 지어내지 않는다
  v_pay := case v_cur when 'USD' then round(p_total, 2) else round(p_total) end;
  if v_pay is null or v_pay <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  if v_pay = v_ch.pay_amount then
    return jsonb_build_object('ok', true, 'changed', false, 'amount_krw', v_ch.amount_krw, 'pay_amount', v_ch.pay_amount, 'pay_currency', v_cur);
  end if;
  v_had_parts := coalesce(jsonb_typeof(coalesce(v_ch.payload, '{}'::jsonb)->'override_parts') = 'object', false);
  v_krw := case v_cur when 'KRW' then v_pay::bigint else round(v_pay * v_ch.pay_fx)::bigint end;
  v_old := public._taam_ksk_money(v_cur, v_ch.pay_amount, v_ch.amount_krw);
  update public.kashikiri_charges
     set amount_krw = v_krw::int, pay_amount = v_pay, amount_jpy = case when v_cur = 'JPY' then v_pay::int end,
         payload = (coalesce(payload, '{}'::jsonb) - 'override_parts') || jsonb_build_object('price_override', true)   -- 총액이 바뀌면 항목 내역은 낡는다 — 지운다(환불은 정가 대행비 기준으로)
   where id = v_ch.id
  returning * into v_ch;
  update public.tickets set extra_data = (coalesce(extra_data, '{}'::jsonb) - 'payAmount') || jsonb_build_object('priceOverride', true)   -- 협의 금액은 좌석 행에 안 적는다(매장 어드민이 읽는다)
   where purchase_id like 'LINK-%' and extra_data->>'chargeId' = v_ch.id::text and lower(coalesce(status, '')) in ('hold', 'active');
  insert into public.kashikiri_charge_admin (charge_id, note, created_by)
  values (v_ch.id, '[금액 변경 ' || to_char(now() at time zone 'Asia/Seoul', 'MM-DD HH24:MI') || '] ' || v_old || ' → ' || public._taam_ksk_money(v_cur, v_pay, v_krw::int)
                   || case when v_had_parts then ' (항목 내역 해제 — 환불은 정가 대행비 기준)' else '' end || ' · ' || v_note, v_uid)
  on conflict (charge_id) do update set note = coalesce(public.kashikiri_charge_admin.note || E'\n', '') || excluded.note;
  return jsonb_build_object('ok', true, 'changed', true, 'amount_krw', v_ch.amount_krw, 'pay_amount', v_ch.pay_amount, 'pay_currency', v_cur, 'parts_cleared', v_had_parts);
end $$;
revoke all on function public.taam_pay_link_set_amount(uuid, numeric, text) from public, anon;
grant execute on function public.taam_pay_link_set_amount(uuid, numeric, text) to authenticated;
comment on function public.taam_pay_link_set_amount(uuid, numeric, text) is '미결제(pending) 티켓·자유 금액 결제 링크의 금액을 바꾼다 — 슈퍼어드민만 · 사유 필수 · 외화는 링크 환율로 원화 환산 · 어드민 표에 기록 · 총액을 바꾸면 항목 내역(override_parts)을 지운다. 2026-10-19';

-- ── 확인 — 한 표 ──
select '① ' || name || ' 교체' as 항목, status as 결과 from _plp
union all select '③ 두 판이 override_parts 를 안다', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_pay_link_create(text,jsonb)') and p.prosrc like '%override_parts%')
             and exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_refund_quote(text)') and p.prosrc like '%override_parts%') then '✅' else '❌ 옛 판 — 항목별 금액이 저장·환불에 안 쓰인다' end
union all select '⑤ 금액 변경이 항목 내역을 지운다', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_pay_link_set_amount(uuid,numeric,text)') and p.prosrc like '%- ''override_parts''%') then '✅' else '❌' end
union all select '④ 의존 — taam_ticket_price_fx · _taam_ksk_money', case when to_regprocedure('public.taam_ticket_price_fx(text,integer,text,numeric)') is not null and to_regprocedure('public._taam_ksk_money(text,numeric,integer)') is not null then '✅' else '❌' end
order by 1;
