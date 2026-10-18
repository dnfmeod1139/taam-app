-- ═══════════════════════════════════════════════════════════════
-- 결제 링크 · 티켓 좌석 금액 수동 설정 / 미결제 링크 금액 변경 (2026-10-19 운영 요청)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 티켓 좌석 링크(회원 연결 포함)의 금액은 서버 정가 (식사+대행+주류)×인원 뿐이었다. 할인·특약·일부 선결제처럼 다른 금액으로 받을 길이 없어
--     자유 금액 링크로 우회하면 좌석 홀드·회원 연결이 빠졌다. 운영 요청: 만들 때 금액을 직접 정하고, 보낸 뒤(미결제)에도 바꿀 수 있게.
-- 무엇:
--   ① taam_pay_link_create('ticket', p) 에 p.total(링크 통화 금액) · p.note(사유) — **슈퍼어드민만**(매장 어드민은 PRICE_OVERRIDE_FORBIDDEN) · 정가와 다르면 **사유 필수**(OVERRIDE_NOTE_REQUIRED · 멤버십 수정과 같은 규칙).
--      청구(kashikiri_charges)의 amount_krw·pay_amount 를 바꾸고(외화는 round(외화×환율) — 정산 링크 외화 규칙과 같음), payload 에 price_override=true 만, 정가→수정액·사유는 kashikiri_charge_admin.note 에.
--      LINK- 홀드 행(tickets)에는 협의 금액을 **적지 않는다** — extra_data.payAmount 를 지우고 priceOverride=true 만(price 칸은 정가×인원 그대로 — 매장 어드민이 자기 매장 행을 읽는다 · KSK- 와 같은 원칙 · 적대 리뷰).
--      정가와 **같은** 금액은 수정이 아니다(매장 어드민이 정가를 보내도 통과 · 메모만 어드민 표에 남는다). 외화 정가는 확정 해외 정가 기준(20261019_link_invite_ovs_prices.sql). 사유 없으면 예외 → 홀드까지 롤백.
--   ② taam_pay_link_set_amount(p_charge_id, p_total, p_note) — **미결제(pending · 만료 전)** 티켓·자유 금액 링크의 금액을 바꾼다(슈퍼어드민만 · 사유 필수). 멤버십 링크는 payload 의 총액/연회비/예치금 몫이 함께 움직여야 해서 제외(BAD_PURPOSE · 끊고 다시 만든다).
--      대관 정산 청구(회차 있음 · link_invite 아님)는 SETTLEMENT_CHARGE — 정산 시트(총액 검사)에서 다룬다. 외화인데 환율이 없는 행은 FX_MISSING(1로 지어내지 않는다).
--      이미 결제된 건은 NOT_PENDING — 환불로 처리한다. 손님이 결제를 한 번이라도 시작한 링크(order_id 있음)는 PAYMENT_STARTED — 확정 Edge 가 청구를 읽고 mark_paid_v2 가 다시 읽는 사이에 금액이 바뀌면 「토스 승인 · 우리 기록 pending」이 나므로 끊고 새로 만든다.
--   ⚠ taam_pay_link_create 는 라이브 함수 교체 — 본문 md5 가 저장소 3차 판(20261018_pay_link.sql · 7d7ec299e9f956d41e692d79007f9d1d)과 같을 때만. 이미 새 판(PRICE_OVERRIDE_FORBIDDEN)이면 ✅ 그대로, 모르는 판이면 ❌ 건너뜀.
--   ③ taam_pay_link_list 에 order_id · price_override 를 더한다(목록이 「금액 변경」 버튼을 결제 시작 전 링크에만 보이고 (금액 수정) 태그를 단다 · setof jsonb 라 키 추가는 옛 앱에도 무해).
-- 의존: _taam_ksk_money(20261013_kashikiri_paid_notify.sql · 라이브 ✅) · kashikiri_charge_admin(20261018 · 라이브 ✅).
-- 회귀: bash sql/_test/t_pay_link.sh · 스크래치 paylink.js
-- ═══════════════════════════════════════════════════════════════

drop table if exists _plo; create temp table _plo(name text primary key, status text);
do $do$
declare v_live text; v_src text;
begin
  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regprocedure('public.taam_pay_link_create(text,jsonb)');
  if v_live is null then
    insert into _plo values ('taam_pay_link_create', '❌ 라이브에 함수가 없다 — 20261018_pay_link.sql 먼저');
  elsif v_src like '%PRICE_OVERRIDE_FORBIDDEN%' then
    insert into _plo values ('taam_pay_link_create', '✅ 이미 새 판(금액 수정)');
  elsif v_live <> '7d7ec299e9f956d41e692d79007f9d1d' then
    insert into _plo values ('taam_pay_link_create', '❌ 라이브 본문이 저장소 3차 판과 다르다 — 건너뜀 (md5 ' || v_live || ')');
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
    if v_total is not null then
      v_cur := upper(coalesce(nullif(p->>'currency',''), 'KRW'));
      v_fx := case when v_cur = 'KRW' then 1 else nullif(p->>'fx','')::numeric end;
      v_pay := case v_cur when 'USD' then round(v_total, 2) else round(v_total) end;
      if v_pay <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
      if v_pay <> v_ch.pay_amount then
        if not v_super then raise exception 'PRICE_OVERRIDE_FORBIDDEN' using errcode = '42501'; end if;
        if v_note is null then raise exception 'OVERRIDE_NOTE_REQUIRED' using errcode = '22023'; end if;
        if v_cur <> 'KRW' and coalesce(v_fx, 0) <= 0 then raise exception 'FX_MISSING' using errcode = '22023'; end if;
        v_krw := case v_cur when 'KRW' then v_pay::bigint else round(v_pay * v_fx)::bigint end;
        v_note := '[금액 수정] 정가 ' || public._taam_ksk_money(v_ch.pay_currency, v_ch.pay_amount, v_ch.amount_krw) || ' → ' || public._taam_ksk_money(v_cur, v_pay, v_krw::int) || ' · ' || v_note;
        update public.kashikiri_charges
           set amount_krw = v_krw::int, pay_amount = v_pay, amount_jpy = case when v_cur = 'JPY' then v_pay::int end,
               payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('price_override', true)
         where id = v_cid
        returning * into v_ch;
        update public.tickets set extra_data = (coalesce(extra_data, '{}'::jsonb) - 'payAmount') || jsonb_build_object('priceOverride', true)
         where purchase_id = v_res->>'purchase_id';
      end if;
    end if;
    if v_note is not null then update public.kashikiri_charge_admin set note = v_note where charge_id = v_cid; end if;
    return jsonb_build_object('ok', true, 'purpose', 'ticket', 'charge_id', v_ch.id, 'token', v_ch.token,
                              'url', 'https://taam-app.vercel.app/pay/?t=' || v_ch.token,
                              'amount_krw', v_ch.amount_krw, 'pay_currency', v_ch.pay_currency, 'pay_amount', v_ch.pay_amount,
                              'price_override', coalesce((v_ch.payload->>'price_override')::boolean, false),
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
end $b$
    $fn$;
    insert into _plo values ('taam_pay_link_create', '✅ 교체 (티켓 금액 수동 설정)');
  end if;
end $do$;

-- ── ② 미결제 링크 금액 변경 ──
create or replace function public.taam_pay_link_set_amount(p_charge_id uuid, p_total numeric, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_super boolean := false; v_ch public.kashikiri_charges%rowtype; v_cur text; v_pay numeric; v_krw bigint; v_note text; v_old text;
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
  v_krw := case v_cur when 'KRW' then v_pay::bigint else round(v_pay * v_ch.pay_fx)::bigint end;
  v_old := public._taam_ksk_money(v_cur, v_ch.pay_amount, v_ch.amount_krw);
  update public.kashikiri_charges
     set amount_krw = v_krw::int, pay_amount = v_pay, amount_jpy = case when v_cur = 'JPY' then v_pay::int end,
         payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('price_override', true)
   where id = v_ch.id
  returning * into v_ch;
  update public.tickets set extra_data = (coalesce(extra_data, '{}'::jsonb) - 'payAmount') || jsonb_build_object('priceOverride', true)   -- 협의 금액은 좌석 행에 안 적는다(매장 어드민이 읽는다)
   where purchase_id like 'LINK-%' and extra_data->>'chargeId' = v_ch.id::text and lower(coalesce(status, '')) in ('hold', 'active');
  insert into public.kashikiri_charge_admin (charge_id, note, created_by)
  values (v_ch.id, '[금액 변경 ' || to_char(now() at time zone 'Asia/Seoul', 'MM-DD HH24:MI') || '] ' || v_old || ' → ' || public._taam_ksk_money(v_cur, v_pay, v_krw::int) || ' · ' || v_note, v_uid)
  on conflict (charge_id) do update set note = coalesce(public.kashikiri_charge_admin.note || E'\n', '') || excluded.note;
  return jsonb_build_object('ok', true, 'changed', true, 'amount_krw', v_ch.amount_krw, 'pay_amount', v_ch.pay_amount, 'pay_currency', v_cur);
end $$;
revoke all on function public.taam_pay_link_set_amount(uuid, numeric, text) from public, anon;
grant execute on function public.taam_pay_link_set_amount(uuid, numeric, text) to authenticated;
comment on function public.taam_pay_link_set_amount(uuid, numeric, text) is '미결제(pending) 티켓·자유 금액 결제 링크의 금액을 바꾼다 — 슈퍼어드민만 · 사유 필수 · 외화는 링크 환율로 원화 환산 · 어드민 표에 기록. 2026-10-19';

-- ── ③ 목록 RPC — order_id · price_override 추가 (20261018 판 + 두 키) ──
create or replace function public.taam_pay_link_list(p_limit int default 60, p_user_id uuid default null, p_purpose text default null)
returns setof jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public._taam_uid_is_super(), false) then raise exception '권한이 없습니다' using errcode = '42501'; end if;
  return query
  select jsonb_build_object(
      'id', c.id, 'purpose', coalesce(c.purpose,'custom'), 'title', coalesce(c.title, e.venue_name), 'subtitle', coalesce(c.subtitle, to_char(e.event_date,'YYYY.MM.DD')),
      'label', c.label, 'user_id', c.user_id, 'member_name', p.display_name,
      'amount_krw', c.amount_krw, 'pay_currency', coalesce(c.pay_currency,'KRW'), 'pay_amount', coalesce(c.pay_amount, c.amount_krw),
      'status', c.status, 'token', c.token, 'created_at', c.created_at, 'expires_at', c.expires_at, 'approved_at', c.approved_at,
      'applied_at', c.applied_at, 'applied_note', c.applied_note, 'link_invite', coalesce(c.link_invite,false), 'event_id', c.event_id,
      'payload', coalesce(c.payload,'{}'::jsonb), 'refund_krw', c.refund_krw, 'payer_phone', c.payer_phone,
      'order_id', c.order_id, 'price_override', coalesce((c.payload->>'price_override')::boolean, false),   -- 🆕 2026-10-19 결제 시작 여부 · 금액 수정 태그
      'note', a.note, 'fail_note', a.fail_note, 'created_by', a.created_by)
    from public.kashikiri_charges c
    left join public.kashikiri_events e on e.id = c.event_id
    left join public.profiles p on p.id = c.user_id
    left join public.kashikiri_charge_admin a on a.charge_id = c.id
   where (p_user_id is null or c.user_id = p_user_id)
     and (p_purpose is null or coalesce(c.purpose,'custom') = p_purpose)
   order by c.created_at desc
   limit greatest(1, least(coalesce(p_limit, 60), 300));
end $$;
revoke all on function public.taam_pay_link_list(int, uuid, text) from public, anon;
grant execute on function public.taam_pay_link_list(int, uuid, text) to authenticated;

-- ── 확인 — 한 표 ──
select '① taam_pay_link_create 교체' as 항목, status as 결과 from _plo
union all select '② taam_pay_link_set_amount · anon 없음', case when to_regprocedure('public.taam_pay_link_set_amount(uuid,numeric,text)') is not null and not has_function_privilege('anon', 'public.taam_pay_link_set_amount(uuid,numeric,text)', 'execute') then '✅' else '❌' end
union all select '③ 의존 — _taam_ksk_money · kashikiri_charge_admin', case when to_regprocedure('public._taam_ksk_money(text,numeric,integer)') is not null and to_regclass('public.kashikiri_charge_admin') is not null then '✅' else '❌ 20261013_kashikiri_paid_notify.sql · 20261018_pay_link.sql' end
union all select '⑤ 목록 RPC 가 order_id · price_override 를 준다', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_pay_link_list(integer,uuid,text)') and p.prosrc like '%price_override%') then '✅' else '❌' end
union all select '④ 새 판이 price_override 를 안다', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_pay_link_create(text,jsonb)') and p.prosrc like '%PRICE_OVERRIDE_FORBIDDEN%') then '✅' else '❌' end
order by 1;
