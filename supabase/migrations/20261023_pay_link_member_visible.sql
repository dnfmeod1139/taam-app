-- ═══════════════════════════════════════════════════════════════
-- 결제 링크로 낸 예약을 회원이 본다 — ① 결제된 링크 → 회원 예약으로 연결(슈퍼어드민) ② 결제되면 회원에게 알림·푸시 (2026-10-23)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다. 마지막 표에 ❌ 가 없어야 정상.
-- 왜: 에릭(회원)에게 보낸 스시 사이토 2027.03.15 2인 $1,800 결제 링크가 **자유 금액(custom)** 링크였다(티켓 링크 금액 수정 기능 · 2026-10-19 전).
--     자유 금액 링크는 좌석 행(tickets)이 없어 회원 「예약 내역」에 안 보이고, 좌석은 슈퍼어드민이 캘린더 「수동 추가」(MAN- · 어드민 소유)로 따로 잡았다 — 회원은 자기가 결제한 예약을 못 봤다.
--     결제가 끝나도 회원에게는 아무 알림이 없었다(슈퍼어드민에게만 「결제 완료」).
--     진단: 20261023_diag_link_member.sql · _member2.sql (결제된 청구 3건 — 정산 1 · 자유 금액 2 · 결제된 티켓 링크 0).
-- 무엇:
--   1. taam_pay_link_attach_ticket(청구, 회차, 인원, 회원?, 대체할 수동 좌석?, 메모?, 알림?) — 슈퍼어드민·서버만.
--      좌석 행이 없는 결제(자유 금액 · 티켓)는 그 회원 소유 LINK- 좌석 행을 새로 만들고(가격은 정가×인원 · 결제액은 청구에 · 대행비 스냅샷 agencyFee/agencyPay — 환불 견적이 본다),
--      고른 수동 좌석(MAN- · 같은 회차)은 **같은 트랜잭션에서 취소**해 자리를 넘긴다(정원 두 번 안 먹게). 청구는 티켓 링크로 바뀐다(purpose ticket · link_invite · 회원 · 제목·부제 = 회차 · payload 에 원래 제목).
--      좌석 행은 있는데 회원 것이 아닌 결제(비회원 결제 · 결제 뒤 소유자 이전 보류 memberUidPending)는 그 행을 회원에게 넘긴다.
--      중복 가드(같은 회차·같은 시간대)는 그대로 — 막히면 그 오류를 돌려준다(「🔓 구매 규정 예외」로 허용한 뒤 다시).
--      회원에게 알림함 「예약이 등록되었습니다」 + 푸시(세 벌). 어드민 메모에 한 줄.
--   2. taam_pay_link_unattached(limit) — 회원 예약 내역에 안 보이는 결제 목록(좌석 행 없음 · 또는 좌석이 회원 것 아님).
--   3. trg_taam_pay_link_member_notify — 청구가 paid 가 되는 순간 그 청구의 회원(user_id)에게 알림함 + 푸시(용도별 문구 · 결제 통화 금액만 — 원화·환율은 안 적는다).
--      결제 확정을 막지 않는다(예외는 warning). 푸시는 _taam_member_push(app_config.restock_push 의 Vault 이름·URL 재사용 · send-push 에 uid:<회원>).
-- 회귀: bash sql/_test/t_pay_link_attach.sh
-- ═══════════════════════════════════════════════════════════════

-- ── 0) 회원 한 명에게 푸시 — taam_admin_push 와 같은 설정 · to = uid:<회원> · i18n 세 벌 ──
create or replace function public._taam_member_push(p_uid uuid, p_title text, p_body text, p_url text default '/', p_tag text default null,
                                                    p_category text default 'system', p_i18n jsonb default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint; v_payload jsonb;
begin
  if p_uid is null then return jsonb_build_object('ok', false, 'reason', 'no_uid'); end if;
  if to_regclass('public.app_config') is null then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name,'') = '' or coalesce(v_url,'') = '' then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  v_url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/send-push');
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return jsonb_build_object('ok', false, 'reason', 'no_pg_net'); end if;
  begin
    select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  exception when others then v_jwt := null; end;
  if coalesce(v_jwt,'') = '' then return jsonb_build_object('ok', false, 'reason', 'no_secret'); end if;
  v_payload := jsonb_build_object('title', p_title, 'body', p_body, 'url', coalesce(p_url, '/'), 'category', coalesce(p_category, 'system'),
                                  'tag', coalesce(p_tag, 'taam-' || extract(epoch from now())::bigint));
  if p_i18n is not null and jsonb_typeof(p_i18n) = 'object' then v_payload := v_payload || jsonb_build_object('i18n', p_i18n); end if;
  select net.http_post(url := v_url,
                       headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt),
                       body := jsonb_build_object('to', 'uid:' || p_uid::text, 'payload', v_payload))
    into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req);
exception when others then
  return jsonb_build_object('ok', false, 'reason', left(sqlerrm, 200));
end $$;
revoke all on function public._taam_member_push(uuid, text, text, text, text, text, jsonb) from public, anon, authenticated;

-- 회차 이름의 언어별 표기(매장 name_en/name_jp · 없으면 한국어)
create or replace function public._taam_rest_name_l10n(p_ticket_id text, p_lang text)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(case lower(coalesce(p_lang,'ko'))
                    when 'en' then nullif(btrim(coalesce(to_jsonb(r)->>'name_en', '')), '')
                    when 'ja' then nullif(btrim(coalesce(to_jsonb(r)->>'name_jp', '')), '')
                    else null end,
                  tp.rest_name)
    from public.ticket_products tp
    left join public.restaurants r on r.id::text = tp.rest_id::text
   where tp.id::text = p_ticket_id
$$;
revoke all on function public._taam_rest_name_l10n(text, text) from public, anon, authenticated;

-- ── 1) 결제 → 회원 예약으로 연결 ──
create or replace function public.taam_pay_link_attach_ticket(
  p_charge_id uuid, p_ticket_id text, p_pax int, p_user uuid default null,
  p_replace_pid text default null, p_note text default null, p_notify boolean default true)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_ch public.kashikiri_charges%rowtype; v_tp public.ticket_products%rowtype; v_seat public.tickets%rowtype;
  v_user uuid; v_name text; v_phone text; v_rep_pid text; v_rep_id uuid; v_pid text; v_mode text;
  v_list bigint; v_cur text; v_fx numeric; v_fxq jsonb; v_ag_krw bigint; v_ag_pay numeric; v_vd date; v_vtime text;
  v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_line text; v_label text; v_push jsonb := null; v_en text; v_ja text; v_bko text;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN: 슈퍼어드민만 연결할 수 있습니다' using errcode = '42501'; end if;
  select * into v_ch from public.kashikiri_charges where id = p_charge_id for update;
  if not found then raise exception 'CHARGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_ch.status <> 'paid' then raise exception 'NOT_PAID: 결제된 청구만 연결합니다 (지금 %)', v_ch.status using errcode = '22023'; end if;
  if coalesce(v_ch.purpose, 'custom') = 'membership' then raise exception 'BAD_PURPOSE: 멤버십 결제는 예약이 아닙니다' using errcode = '22023'; end if;
  if v_ch.event_id is not null and not coalesce(v_ch.link_invite, false) then
    raise exception 'SETTLEMENT_CHARGE: 대관 정산 청구는 정산 화면의 「티켓 연결」로 좌석을 잡습니다' using errcode = '22023';
  end if;

  -- 회원
  v_user := coalesce(p_user, v_ch.user_id);
  if v_user is null then raise exception 'MEMBER_REQUIRED: 연결할 회원을 고르세요' using errcode = '22023'; end if;
  if p_user is not null and v_ch.user_id is not null and p_user <> v_ch.user_id then
    raise exception 'MEMBER_MISMATCH: 이 결제는 다른 회원의 것으로 적혀 있습니다' using errcode = '22023';
  end if;
  select display_name, phone into v_name, v_phone from public.profiles where id = v_user and deleted_at is null;
  if not found then raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002'; end if;

  -- 이미 좌석 행이 있나
  select * into v_seat from public.tickets t
   where t.extra_data->>'chargeId' = v_ch.id::text and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired')
   order by t.created_at desc limit 1;

  if v_seat.id is not null then
    -- ── B. 좌석은 있는데 회원 것이 아니다(비회원 결제 · 소유자 이전 보류) → 그 행을 회원에게 ──
    if v_seat.user_id = v_user and coalesce(v_seat.extra_data->>'memberUid', '') = v_user::text then
      raise exception 'ALREADY_ATTACHED: 이미 이 회원의 예약입니다 (%)', v_seat.purchase_id using errcode = '22023';
    end if;
    if p_ticket_id is not null and btrim(p_ticket_id) <> '' and v_seat.ticket_product_id::text is distinct from btrim(p_ticket_id) then
      raise exception 'SEAT_OTHER_TICKET: 이 결제의 좌석은 다른 회차에 있습니다' using errcode = '22023';
    end if;
    update public.tickets
       set user_id = v_user,
           buyer_name = coalesce(nullif(v_name, ''), buyer_name),
           extra_data = (coalesce(extra_data, '{}'::jsonb) - 'memberUidPending' - 'ownerTransferError')
                        || jsonb_build_object('memberUid', v_user, 'attachedBy', auth.uid(), 'attachedAt', now())
     where id = v_seat.id;
    v_pid := v_seat.purchase_id; v_mode := 'transfer';
    select * into v_tp from public.ticket_products where id::text = v_seat.ticket_product_id::text;
    v_vd := coalesce(public._taam_pu_visit_date(v_seat.reservation_date), public._taam_pu_visit_date(v_tp.date));
    v_vtime := coalesce(nullif(v_seat.visit_time, ''), v_tp.time, '');
    p_pax := coalesce(v_seat.party_size, p_pax);
  else
    -- ── A. 좌석 행이 없다(자유 금액 · 좌석 없이 끝난 결제) → 그 회원 소유 LINK- 좌석 행을 만든다 ──
    select * into v_tp from public.ticket_products where id::text = btrim(coalesce(p_ticket_id, ''));
    if not found then raise exception 'TICKET_NOT_FOUND: 회차를 고르세요' using errcode = 'P0002'; end if;
    if coalesce(p_pax, 0) < 1 or p_pax > 20 then raise exception 'BAD_PAX: 인원은 1~20' using errcode = '22023'; end if;
    v_vd := public._taam_pu_visit_date(v_tp.date);
    if v_vd is null then raise exception 'TICKET_DATE_UNKNOWN: 회차 날짜(연도 포함)를 읽지 못했습니다' using errcode = '22023'; end if;
    v_vtime := coalesce(v_tp.time, '');

    -- 대신할 수동 좌석(MAN- · 같은 회차) — 먼저 취소해 자리를 넘긴다(정원을 두 번 먹지 않게)
    v_rep_pid := nullif(btrim(coalesce(p_replace_pid, '')), '');
    if v_rep_pid is not null then
      select id into v_rep_id from public.tickets
       where purchase_id = v_rep_pid and purchase_id like 'MAN-%' and lower(coalesce(status, '')) in ('manual', 'active')
         and ticket_product_id::text = v_tp.id::text
       for update;
      if v_rep_id is null then raise exception 'REPLACE_NOT_FOUND: 이 회차의 살아 있는 수동 좌석(MAN-)이 아닙니다 (%)', v_rep_pid using errcode = '22023'; end if;
      update public.tickets
         set status = 'cancelled',
             extra_data = coalesce(extra_data, '{}'::jsonb) || jsonb_build_object('cancelledBy', 'converted_to_pay_link', 'cancelledAt', now(), 'convertedToCharge', v_ch.id::text)
       where id = v_rep_id;
    end if;

    -- 대행비 스냅샷(환불 견적 D-31 이 뺀다) — 결제 통화로. 확정 해외 대행비가 있으면 그 값
    v_cur := upper(coalesce(v_ch.pay_currency, 'KRW'));
    v_fx := case when v_cur = 'KRW' then 1 else v_ch.pay_fx end;
    v_list := coalesce(public.taam_ticket_price_krw(v_tp.id::text, p_pax), 0);
    v_ag_krw := coalesce(v_tp.agency_fee, 0);
    if v_cur = 'KRW' then
      v_ag_pay := v_ag_krw;
    else
      begin v_fxq := public.taam_ticket_price_fx(v_tp.id::text, 1, v_cur, v_fx); exception when others then v_fxq := null; end;
      if coalesce((v_fxq->'parts'->'agency'->>'fixed')::boolean, false) then
        v_ag_pay := (v_fxq->'parts'->'agency'->>'per')::numeric; v_ag_krw := round(v_ag_pay * coalesce(v_fx, 0))::bigint;
      elsif coalesce(v_fx, 0) > 0 then
        v_ag_pay := case v_cur when 'USD' then round(v_ag_krw / v_fx, 2) else round(v_ag_krw / v_fx) end;
      else
        v_ag_pay := null;
      end if;
    end if;

    v_pid := 'LINK-' || left(v_ch.id::text, 8) || '-' || (extract(epoch from clock_timestamp()) * 1000)::bigint;
    -- price 는 원화 정가 × 인원(매장 어드민이 읽는 칸 — 결제액이 아니다 · 결제액은 청구에). 협의 금액은 좌석 행에 적지 않는다(priceOverride 표시만)
    insert into public.tickets (user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
                                reservation_date, visit_time, party_size, price, status, purchase_id,
                                buyer_name, buyer_phone, extra_data, created_at)
    values (v_user, v_tp.rest_id::text, v_tp.rest_name, v_tp.id::text, coalesce(v_tp.type_class, ''),
            to_char(v_vd, 'YYYY.MM.DD'), v_vtime, p_pax, v_list, 'active', v_pid,
            coalesce(nullif(v_name, ''), nullif(v_ch.payer_name, ''), v_ch.label, ''), coalesce(nullif(v_phone, ''), v_ch.payer_phone, ''),
            jsonb_build_object('linkInvite', true, 'chargeId', v_ch.id::text, 'memberUid', v_user, 'currency', v_cur, 'fx', v_fx,
                               'agencyFee', v_ag_krw, 'agencyPay', v_ag_pay, 'paidAt', coalesce(v_ch.approved_at, now()), 'paymentKey', v_ch.payment_key,
                               'attachedBy', auth.uid(), 'attachedAt', now(), 'attachedFrom', coalesce(v_ch.purpose, 'custom'))
            || case when v_rep_pid is not null then jsonb_build_object('convertedFrom', v_rep_pid) else '{}'::jsonb end
            || case when coalesce(v_ch.amount_krw, 0) <> v_list then jsonb_build_object('priceOverride', true) else '{}'::jsonb end,
            now());
    v_mode := 'created';
  end if;

  -- 청구 — 티켓 링크로(회원 · 회차 제목) · 원래 제목은 payload 에
  update public.kashikiri_charges
     set purpose = 'ticket', link_invite = true, user_id = v_user,
         title = coalesce(v_tp.rest_name, title),
         subtitle = coalesce(to_char(v_vd, 'YYYY.MM.DD'), '') || case when coalesce(v_vtime, '') <> '' then ' ' || v_vtime else '' end,
         payload = coalesce(payload, '{}'::jsonb)
                   || jsonb_build_object('ticket_id', v_tp.id::text, 'pax', p_pax, 'member_uid', v_user, 'member_name', v_name,
                                         'attached_purchase_id', v_pid, 'attached_at', now(), 'attached_mode', v_mode)
                   || case when coalesce(v_ch.purpose, 'custom') <> 'ticket' then jsonb_build_object('attached_from', coalesce(v_ch.purpose, 'custom'),
                                                                                                     'orig_title', v_ch.title, 'orig_subtitle', v_ch.subtitle) else '{}'::jsonb end
   where id = v_ch.id;

  v_line := '[예약 연결 ' || to_char(now() at time zone 'Asia/Seoul', 'MM-DD HH24:MI') || '] ' || coalesce(v_tp.rest_name, '') || ' ' || coalesce(to_char(v_vd, 'YYYY.MM.DD'), '')
            || ' · ' || p_pax || '인 · ' || v_pid || case when v_rep_pid is not null then ' · ' || v_rep_pid || ' 대체' else '' end || coalesce(' · ' || v_note, '');
  insert into public.kashikiri_charge_admin (charge_id, note, created_by) values (v_ch.id, v_line, auth.uid())
  on conflict (charge_id) do update set note = coalesce(nullif(public.kashikiri_charge_admin.note, '') || E'\n', '') || excluded.note;

  -- 회원 알림(알림함 + 푸시 세 벌)
  if coalesce(p_notify, true) then
    v_label := coalesce(to_char(v_vd, 'YYYY.MM.DD'), '') || case when coalesce(v_vtime, '') <> '' then ' ' || v_vtime else '' end;
    v_bko := coalesce(v_tp.rest_name, '예약') || ' · ' || v_label || ' · ' || p_pax || '인 — 결제하신 예약이 예약 내역에 추가되었습니다';
    v_en := coalesce(public._taam_rest_name_l10n(v_tp.id::text, 'en'), v_tp.rest_name, 'Booking') || ' · ' || v_label || ' · ' || p_pax || ' guest' || case when p_pax > 1 then 's' else '' end
            || ' — the booking you paid for is now in your bookings';
    v_ja := coalesce(public._taam_rest_name_l10n(v_tp.id::text, 'ja'), v_tp.rest_name, 'ご予約') || ' · ' || v_label || ' · ' || p_pax || '名 — お支払い済みのご予約が予約履歴に追加されました';
    begin
      insert into public.notifications (user_id, type, title, body, url, payload)
      values (v_user, 'pay_link_attached', '예약이 등록되었습니다', v_bko, '/?open_ticket_hist=1',
              jsonb_build_object('charge_id', v_ch.id, 'purchase_id', v_pid, 'ticket_product_id', v_tp.id::text, 'pax', p_pax));
    exception when others then raise warning '[attach] 회원 알림 실패: %', sqlerrm; end;
    v_push := public._taam_member_push(v_user, '예약이 등록되었습니다', v_bko, '/?open_ticket_hist=1', 'taam-plat-' || v_ch.id::text, 'pay_link',
                jsonb_build_object('ko', jsonb_build_object('title', '예약이 등록되었습니다', 'body', v_bko),
                                   'en', jsonb_build_object('title', 'Your booking has been added', 'body', v_en),
                                   'ja', jsonb_build_object('title', 'ご予約が登録されました', 'body', v_ja)));
  end if;

  return jsonb_build_object('ok', true, 'mode', v_mode, 'purchase_id', v_pid, 'replaced', v_rep_pid, 'member_name', v_name,
                            'ticket', jsonb_build_object('id', v_tp.id::text, 'rest', v_tp.rest_name, 'date', to_char(v_vd, 'YYYY.MM.DD'), 'time', v_vtime, 'pax', p_pax),
                            'push', v_push);
end $$;
revoke all on function public.taam_pay_link_attach_ticket(uuid, text, int, uuid, text, text, boolean) from public, anon;
grant execute on function public.taam_pay_link_attach_ticket(uuid, text, int, uuid, text, text, boolean) to authenticated;

-- ── 2) 회원 예약 내역에 안 보이는 결제 ──
create or replace function public.taam_pay_link_unattached(p_limit int default 50)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) into v
    from (
      select coalesce(c.approved_at, c.created_at) at,
             jsonb_build_object('id', c.id, 'purpose', coalesce(c.purpose, 'custom'), 'link_invite', c.link_invite,
                                'title', c.title, 'subtitle', c.subtitle, 'label', c.label, 'payer_name', c.payer_name,
                                'user_id', c.user_id, 'member_name', p.display_name, 'member_tier', p.membership_tier,
                                'pay_currency', c.pay_currency, 'pay_amount', c.pay_amount, 'amount_krw', c.amount_krw,
                                'approved_at', c.approved_at, 'payload', c.payload, 'admin_note', a.note,
                                'seat', case when s.id is null then null
                                             else jsonb_build_object('purchase_id', s.purchase_id, 'status', s.status, 'pax', s.party_size, 'ticket_product_id', s.ticket_product_id,
                                                                     'rest', s.restaurant_name, 'date', s.reservation_date, 'time', s.visit_time,
                                                                     'pending_member', s.extra_data->>'memberUidPending') end,
                                'reason', case when s.id is null then 'no_seat' when coalesce(s.extra_data->>'memberUidPending', '') <> '' then 'transfer_pending' else 'not_member' end) j
        from public.kashikiri_charges c
        left join public.profiles p on p.id = c.user_id
        left join public.kashikiri_charge_admin a on a.charge_id = c.id
        left join lateral (select * from public.tickets t
                            where t.extra_data->>'chargeId' = c.id::text and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired')
                            order by t.created_at desc limit 1) s on true
       where c.status = 'paid'
         and coalesce(c.purpose, 'custom') in ('custom', 'ticket')
         and (c.event_id is null or coalesce(c.link_invite, false))
         and (s.id is null or coalesce(s.extra_data->>'memberUid', '') = '')
       order by coalesce(c.approved_at, c.created_at) desc
       limit least(greatest(coalesce(p_limit, 50), 1), 200)
    ) x;
  return v;
end $$;
revoke all on function public.taam_pay_link_unattached(int) from public, anon;
grant execute on function public.taam_pay_link_unattached(int) to authenticated;

-- ── 3) 결제되면 회원에게 알린다 ──
create or replace function public.taam_pay_link_member_notify()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_role text; v_title text; v_body text; v_url text; v_amt text; v_en jsonb; v_ja jsonb; v_pur text; v_pax int; v_tp text; v_lab text; v_rest_en text; v_rest_ja text; v_seen boolean;
begin
  if coalesce(new.status, '') <> 'paid' or coalesce(old.status, '') = 'paid' then return new; end if;
  if new.user_id is null then return new; end if;
  begin
    select coalesce(role, 'user') into v_role from public.profiles where id = new.user_id and deleted_at is null;
    if v_role is null then return new; end if;
    v_pur := coalesce(new.purpose, 'custom');
    v_amt := public._taam_ksk_money(new.pay_currency, new.pay_amount, new.amount_krw);   -- 결제 통화 그대로(원화·환율은 회원에게 안 적는다)
    v_pax := nullif(new.payload->>'pax', '')::int;
    v_tp := nullif(new.payload->>'ticket_id', '');
    v_lab := coalesce(nullif(new.title, ''), '결제') || case when coalesce(new.subtitle, '') <> '' then ' · ' || new.subtitle else '' end;
    -- 티켓 링크인데 좌석이 회원 것으로 안 붙었으면(소유자 이전 보류 · 좌석 없음) 「예약 내역에서 확인」이라고 하지 않는다 — 슈퍼어드민이 「예약으로 연결」하면 그때 알린다
    v_seen := v_pur = 'ticket' and exists (select 1 from public.tickets t where t.extra_data->>'chargeId' = new.id::text and t.user_id = new.user_id
                                              and coalesce(t.extra_data->>'memberUid', '') = new.user_id::text and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired'));
    if v_pur = 'ticket' and v_seen then
      v_title := '예약 결제가 완료되었습니다';
      v_body := v_lab || case when v_pax is not null then ' · ' || v_pax || '인' else '' end || ' — 예약 내역에서 확인하실 수 있습니다';
      v_url := '/?open_ticket_hist=1';
      v_rest_en := coalesce(case when v_tp is not null then public._taam_rest_name_l10n(v_tp, 'en') end, new.title, 'Booking');
      v_rest_ja := coalesce(case when v_tp is not null then public._taam_rest_name_l10n(v_tp, 'ja') end, new.title, 'ご予約');
      v_en := jsonb_build_object('title', 'Booking payment complete',
                'body', v_rest_en || case when coalesce(new.subtitle, '') <> '' then ' · ' || new.subtitle else '' end
                        || case when v_pax is not null then ' · ' || v_pax || ' guest' || case when v_pax > 1 then 's' else '' end else '' end || ' — see it in your bookings');
      v_ja := jsonb_build_object('title', '予約のお支払いが完了しました',
                'body', v_rest_ja || case when coalesce(new.subtitle, '') <> '' then ' · ' || new.subtitle else '' end
                        || case when v_pax is not null then ' · ' || v_pax || '名' else '' end || ' — 予約履歴でご確認いただけます');
    elsif v_pur = 'membership' then
      v_title := '멤버십 결제가 완료되었습니다';
      v_body := v_lab || ' · ' || v_amt || ' — 감사합니다';
      v_url := '/';
      v_en := jsonb_build_object('title', 'Membership payment complete', 'body', v_lab || ' · ' || v_amt || ' — thank you');
      v_ja := jsonb_build_object('title', 'メンバーシップのお支払いが完了しました', 'body', v_lab || ' · ' || v_amt || ' — ありがとうございます');
    else
      v_title := '결제가 완료되었습니다';
      v_body := v_lab || ' · ' || v_amt;
      v_url := '/';
      v_en := jsonb_build_object('title', 'Payment complete', 'body', v_body);
      v_ja := jsonb_build_object('title', 'お支払いが完了しました', 'body', v_body);
    end if;
    insert into public.notifications (user_id, type, title, body, url, payload)
    values (new.user_id, 'pay_link_paid', v_title, left(v_body, 1000), v_url,
            jsonb_build_object('charge_id', new.id, 'purpose', v_pur, 'pay_currency', new.pay_currency, 'pay_amount', new.pay_amount));
    perform public._taam_member_push(new.user_id, v_title, v_body, v_url, 'taam-plpaid-' || new.id::text, 'pay_link',
              jsonb_build_object('ko', jsonb_build_object('title', v_title, 'body', v_body), 'en', v_en, 'ja', v_ja));
  exception when others then
    raise warning '[pay_link] 회원 결제 알림 실패(결제는 그대로): %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists trg_taam_pay_link_member_notify on public.kashikiri_charges;
create trigger trg_taam_pay_link_member_notify after update of status on public.kashikiri_charges
  for each row execute function public.taam_pay_link_member_notify();

-- ── 확인 — 한 표 ──
drop table if exists _plmv_chk; create temp table _plmv_chk(k text, v text);
insert into _plmv_chk
select '① RPC 둘 · 푸시 도우미 · 이름 도우미', case when to_regprocedure('public.taam_pay_link_attach_ticket(uuid,text,integer,uuid,text,text,boolean)') is not null
                                              and to_regprocedure('public.taam_pay_link_unattached(integer)') is not null
                                              and to_regprocedure('public._taam_member_push(uuid,text,text,text,text,text,jsonb)') is not null
                                              and to_regprocedure('public._taam_rest_name_l10n(text,text)') is not null then '✅' else '❌' end
union all select '② 결제 → 회원 알림 트리거', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_pay_link_member_notify' and tgrelid = 'public.kashikiri_charges'::regclass and not tgisinternal) then '✅' else '❌' end
union all select '③ anon 은 못 부른다 · 회원은 도우미를 못 부른다', case when not has_function_privilege('anon', 'public.taam_pay_link_attach_ticket(uuid,text,integer,uuid,text,text,boolean)', 'execute')
                                                        and not has_function_privilege('anon', 'public.taam_pay_link_unattached(integer)', 'execute')
                                                        and not has_function_privilege('authenticated', 'public._taam_member_push(uuid,text,text,text,text,text,jsonb)', 'execute') then '✅' else '❌' end
union all select '④ 도우미가 기대는 함수 (taam_ticket_price_krw · _taam_pu_visit_date · _taam_ksk_money · _taam_fee_caller_ok)',
       case when to_regprocedure('public.taam_ticket_price_krw(text,integer)') is not null and to_regprocedure('public._taam_pu_visit_date(text)') is not null
             and to_regprocedure('public._taam_ksk_money(text,numeric,integer)') is not null and to_regprocedure('public._taam_fee_caller_ok()') is not null then '✅' else '❌' end
union all select '⑤ 회원 예약 내역에 안 보이는 결제 (정보)', (select count(*) from public.kashikiri_charges c
                                                    where c.status = 'paid' and coalesce(c.purpose, 'custom') in ('custom', 'ticket') and (c.event_id is null or coalesce(c.link_invite, false))
                                                      and not exists (select 1 from public.tickets t where t.extra_data->>'chargeId' = c.id::text
                                                                        and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired') and coalesce(t.extra_data->>'memberUid', '') <> ''))::text || '건';
select k as 항목, v as 결과 from _plmv_chk order by 1;
