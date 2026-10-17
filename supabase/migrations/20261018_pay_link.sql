-- ═══════════════════════════════════════════════════════════════
-- 결제 링크 재구성 — 용도 셋(티켓 좌석 · 멤버십 · 자유 금액)을 한 RPC 로 (2026-10-18)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 링크 하나를 보내는 데 대관 회차(매장·날짜 필수) → 상세 → 환율 폼 → 보내기 시트 → 복사, 화면 4개를 지났고
--     연회비는 매장 이름을 임의로 적어 우회한 뒤 예치금 부여·연회비 기록을 세 화면에서 따로 손으로 적었다(2026-10-17 조사).
-- 무엇이 바뀌나 (뼈대는 그대로 — kashikiri_charges 한 줄 = 링크 = 토스 주문 · /pay · kashikiri-confirm · mark_paid_v2 · 트리거 3종)
--   ① kashikiri_charges 에 purpose('ticket'|'membership'|'custom') · title · subtitle · payload · applied_at 이 생기고 event_id 가 비어도 된다.
--      매장·날짜가 없는 결제(멤버십·자유 금액)는 회차 없이 청구만 만든다. 옛 대관 정산 회차 흐름은 그대로 돈다(purpose 'custom').
--   ② taam_pay_link_create(p_purpose, p) — 티켓은 taam_link_invite_create 에 위임(금액은 서버 · 좌석 홀드 · 매장 어드민 허용)하고
--      회원을 고르면 결제 뒤 그 회원의 티켓이 된다. 멤버십은 taam_membership_price 설정값(국내 M 1,125만/T 315만 · 해외 $9,900/$3,000 · 갱신은 연회비만)이
--      기본이고 바꾸면 사유 메모가 필수. 자유 금액은 어드민 입력. 외화는 외화로 적고 원화 = round(외화×환율)(환율은 링크에 못 박는다 — 「들어올 때 한 번」).
--   ③ 결제(paid)되면 멤버십 링크는 membership_fees 에 연회비를 **자동 기록**(수단 link · 외화·환율 · source pay_link · source_ref 청구 id)한다.
--      **예치금 부여는 자동이 아니다**(2026-10-17 운영 결정) — 슈퍼어드민 알림에 「예치금 부여 ₩… 필요」로 적어 주고 앱 버튼이 부여 화면을 채워 준다.
--      환불(refunded)되면 그 자동 기록을 지운다. 기록 실패는 결제를 막지 않고(warning) 슈퍼어드민 알림 ⚠ 로 남긴다.
--   ④ /pay 가 쓰는 공개 RPC(charge_public · order_start)는 회차가 없어도 제목·부제로 그린다. 결제 완료 알림은 용도별 문구.
--   ⑤ 환불 견적: 멤버십·자유 금액은 「슈퍼어드민 판단으로 전액」(admin_full) — 티켓 규정(30분/D-31)은 티켓 링크에만.
-- 지키는 것: 금액·통화는 서버가 정한다(브라우저 값은 대조만) · 예치금·원장은 이 파일이 건드리지 않는다 · mark_paid_v2 는 service_role 전용 그대로 ·
--           anon 은 공개 RPC 둘만 · 회원은 kashikiri_charges 에 쓰지 못한다(RLS 종전).
-- 2차(적대 리뷰 62 에이전트 → 확정 15 · 전부 반영): 매장 어드민이 회원 uid 를 붙이던 구멍(슈퍼어드민만) · 회원 소유가 된 LINK- 행이 중복 가드에서 빠지던 것(memberUid 면 센다 ·
--   만들 때 같은 회차/같은 시간대 선검사 · 이전이 가드에 막히면 결제는 살리고 소유자만 보류) · 어드민 메모·실패 원문이 회원에게 읽히던 것(kashikiri_charge_admin 표로) ·
--   이름 없는 회원 · 링크 초대 직접 경로의 purpose · 기록 실패 때 알림 문구.
-- 회귀: bash sql/_test/t_pay_link.sh
-- ═══════════════════════════════════════════════════════════════

-- ── 0) 컬럼 ──
alter table public.kashikiri_charges
  add column if not exists purpose      text not null default 'custom',
  add column if not exists title        text,
  add column if not exists subtitle     text,
  add column if not exists payload      jsonb not null default '{}'::jsonb,
  add column if not exists applied_at   timestamptz,
  add column if not exists applied_note text,
  add column if not exists created_by   uuid;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'kashikiri_charges_purpose_chk') then
    alter table public.kashikiri_charges add constraint kashikiri_charges_purpose_chk check (purpose in ('ticket','membership','custom'));
  end if;
end $$;
alter table public.kashikiri_charges alter column event_id drop not null;
update public.kashikiri_charges set purpose = 'ticket' where coalesce(link_invite, false) and purpose = 'custom';

-- 링크 초대 직접 경로(초대 화면 riLink* → taam_link_invite_create)는 그대로 살아 있어 purpose 기본값 'custom' 으로 들어온다 — link_invite 면 'ticket' 으로
create or replace function public.taam_charge_purpose_default()
returns trigger language plpgsql as $$
begin
  if coalesce(new.link_invite, false) and coalesce(new.purpose, 'custom') = 'custom' then new.purpose := 'ticket'; end if;
  return new;
end $$;
drop trigger if exists trg_charge_purpose_default on public.kashikiri_charges;
create trigger trg_charge_purpose_default before insert on public.kashikiri_charges
  for each row execute function public.taam_charge_purpose_default();

-- 어드민만 읽는 메모 — 회원은 자기 청구 행을 읽을 수 있다(kc_mine) 그래서 금액 수정 사유·실패 원문·만든 어드민은 이 표에 둔다
create table if not exists public.kashikiri_charge_admin (
  charge_id  uuid primary key references public.kashikiri_charges(id) on delete cascade,
  note       text,
  fail_note  text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.kashikiri_charge_admin enable row level security;
drop policy if exists kca_super on public.kashikiri_charge_admin;
create policy kca_super on public.kashikiri_charge_admin for all to authenticated
  using (public.is_super_admin(auth.uid())) with check (public.is_super_admin(auth.uid()));
grant select on public.kashikiri_charge_admin to authenticated;

-- 중복 가드의 운영 행 판정 — 회원 소유가 된 LINK- 행(결제 뒤 memberUid)은 그 회원의 예약으로 센다 (20261014 판은 LINK- 를 전부 뺐다)
create or replace function public._taam_ticket_is_ops(p_purchase_id text, p_extra jsonb)
returns boolean
language sql immutable
as $$
  select (coalesce(p_purchase_id, '') ~ '^(KSK|MAN|INVH)-'
          or (coalesce(p_purchase_id, '') ~ '^LINK-' and coalesce(nullif(p_extra ->> 'memberUid', ''), '') = '')
          or coalesce(p_extra ->> 'manualEntry', '') in ('true','1')
          or coalesce(p_extra ->> 'inviteHold',  '') in ('true','1')
          or coalesce(p_extra ->> 'kashikiri',   '') in ('true','1')
          or (coalesce(p_extra ->> 'linkInvite',  '') in ('true','1') and coalesce(nullif(p_extra ->> 'memberUid', ''), '') = ''))
$$;

-- 멤버십 금액 설정 — 있는 값은 건드리지 않는다 (deposit_amount 10,125,000 · annual_fee_cash 1,125,000 은 2026-09-02 시드)
do $$
begin
  if to_regclass('public.membership_settings') is not null then
    insert into public.membership_settings (k, v, note) values
      ('t_total_krw', '3150000'::jsonb, 'T 가입 총액 (원) — 연회비 630,000 + 예치금 2,520,000'),
      ('t_fee_krw',   '630000'::jsonb,  'T 연회비 (원)'),
      ('m_total_usd', '9900'::jsonb,    '해외 M 가입 총액 ($) — 연회비 $990 + 예치금 $8,910'),
      ('m_fee_usd',   '990'::jsonb,     '해외 M 연회비 ($)'),
      ('t_total_usd', '3000'::jsonb,    '해외 T 가입 총액 ($) — 연회비 $300 + 예치금 $2,700'),
      ('t_fee_usd',   '300'::jsonb,     '해외 T 연회비 ($)')
    on conflict (k) do nothing;
  end if;
end $$;

-- ── 1) 멤버십 금액 규칙 — 설정값에서 ──
create or replace function public.taam_membership_price(p_tier text, p_kind text default 'join', p_currency text default 'KRW')
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_set jsonb; v_tier text := upper(coalesce(p_tier,'')); v_kind text := lower(coalesce(nullif(p_kind,''),'join')); v_cur text := upper(coalesce(nullif(p_currency,''),'KRW'));
        v_total numeric; v_fee numeric;
begin
  if v_tier not in ('M','T') then raise exception 'BAD_TIER' using errcode = '22023'; end if;
  if v_kind not in ('join','renew') then raise exception 'BAD_KIND' using errcode = '22023'; end if;
  if to_regclass('public.membership_settings') is null then raise exception 'NO_PRICE_RULE' using errcode = 'P0002'; end if;
  select jsonb_object_agg(k, v) into v_set from public.membership_settings;
  if v_cur = 'KRW' then
    if v_tier = 'M' then
      v_fee := (v_set->>'annual_fee_cash')::numeric; v_total := (v_set->>'deposit_amount')::numeric + v_fee;
    else
      v_fee := (v_set->>'t_fee_krw')::numeric; v_total := (v_set->>'t_total_krw')::numeric;
    end if;
  elsif v_cur = 'USD' then
    if v_tier = 'M' then v_fee := (v_set->>'m_fee_usd')::numeric; v_total := (v_set->>'m_total_usd')::numeric;
    else v_fee := (v_set->>'t_fee_usd')::numeric; v_total := (v_set->>'t_total_usd')::numeric; end if;
  else
    raise exception 'NO_PRICE_RULE' using errcode = 'P0002';   -- JPY 등: 규정이 없다 — 어드민이 금액을 직접 적어야 한다(사유 메모 필수)
  end if;
  if v_total is null or v_fee is null then raise exception 'NO_PRICE_RULE' using errcode = 'P0002'; end if;
  if v_kind = 'renew' then v_total := v_fee; end if;
  return jsonb_build_object('tier', v_tier, 'kind', v_kind, 'currency', v_cur, 'total', v_total, 'fee', v_fee, 'deposit', v_total - v_fee);
end $$;
revoke all on function public.taam_membership_price(text, text, text) from public, anon;
grant execute on function public.taam_membership_price(text, text, text) to authenticated;

-- ── 2) 링크 만들기 — 한 입구 ──
create or replace function public.taam_pay_link_create(p_purpose text, p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid(); v_super boolean := false;
  v_res json; v_cid uuid; v_user uuid; v_ch public.kashikiri_charges%rowtype;
  v_cur text; v_fx numeric; v_pay numeric; v_krw bigint; v_fee numeric; v_total numeric; v_fee_krw bigint;
  v_tier text; v_kind text; v_price jsonb; v_over boolean := false; v_note text;
  v_name text; v_phone text; v_title text; v_sub text; v_days int; v_tp public.ticket_products%rowtype;
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
      if exists (select 1 from public.tickets k where k.user_id = v_user and k.ticket_product_id::text = p->>'ticket_id'
                   and coalesce(k.status,'') not in ('cancelled','canceled','expired') and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)) then
        raise exception 'DUPLICATE_PURCHASE' using errcode = '23505';
      end if;
      if exists (select 1 from public.tickets k where k.user_id = v_user and k.reservation_date = p->>'visit_date'
                   and coalesce(k.status,'') not in ('cancelled','canceled','expired') and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
                   and ((nullif(p->>'visit_time','') is null or nullif(btrim(coalesce(k.visit_time,'')),'') is null)
                        or ((p->>'visit_time') < '16:00') = (btrim(k.visit_time) < '16:00'))) then
        raise exception 'TIME_CONFLICT' using errcode = '23505';
      end if;
    end if;
    v_res := public.taam_link_invite_create(p->>'ticket_id', p->>'name', p->>'phone', (p->>'pax')::int, p->>'currency',
                                            nullif(p->>'fx','')::numeric, p->>'visit_date', nullif(p->>'visit_time',''));
    v_cid := (v_res->>'charge_id')::uuid;
    select * into v_tp from public.ticket_products where id::text = p->>'ticket_id';
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
    return jsonb_build_object('ok', true, 'purpose', 'ticket', 'charge_id', v_ch.id, 'token', v_ch.token,
                              'url', 'https://taam-app.vercel.app/pay/?t=' || v_ch.token,
                              'amount_krw', v_ch.amount_krw, 'pay_currency', v_ch.pay_currency, 'pay_amount', v_ch.pay_amount,
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
end $$;
revoke all on function public.taam_pay_link_create(text, jsonb) from public, anon;
grant execute on function public.taam_pay_link_create(text, jsonb) to authenticated;

-- ── 3) 결제 페이지 읽기 — 회차가 없어도 제목·부제로 (anon · 그 청구 한 건만) ──
create or replace function public.taam_kashikiri_charge_public(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;
  select jsonb_build_object(
    'id',           c.id,
    'label',        c.label,
    'purpose',      coalesce(c.purpose, 'custom'),
    'title',        c.title,
    'subtitle',     c.subtitle,
    'amount_krw',   c.amount_krw,
    'amount_jpy',   c.amount_jpy,
    'pay_currency', coalesce(c.pay_currency, 'KRW'),
    'pay_amount',   coalesce(c.pay_amount, c.amount_krw),
    'pay_fx',       c.pay_fx,
    'status',       c.status,
    'expires_at',   c.expires_at,
    'paid_at',      c.approved_at,
    'receipt_url',  c.receipt_url,
    'venue_name',   coalesce(e.venue_name, c.title),
    'venue_name_en', nullif(btrim(coalesce(r.name_en, '')), ''),
    'venue_name_jp', nullif(btrim(coalesce(r.name_jp, '')), ''),
    'event_date',   e.event_date,
    'event_time',   e.event_time,
    'fx_rate',      e.fx_rate,
    'fx_note',      e.fx_note,
    'team_seq',     t.seq,
    'team_pax',     t.pax,
    'split_count', case
      when c.team_id is not null then (select count(*) from public.kashikiri_charges x where x.team_id = c.team_id and x.status <> 'cancelled')
      when c.event_id is not null then (select count(*) from public.kashikiri_charges x where x.event_id = c.event_id and x.status <> 'cancelled')
      else 1 end,
    'mship', case when c.purpose = 'membership' then jsonb_build_object('tier', c.payload->>'tier', 'kind', c.payload->>'kind') end
  ) into v
  from public.kashikiri_charges c
  left join public.kashikiri_events e on e.id = c.event_id
  left join public.kashikiri_teams t on t.id = c.team_id
  left join public.restaurants r on r.id::text = e.venue_id
  where c.token = p_token;
  return v;
end $$;
revoke all on function public.taam_kashikiri_charge_public(text) from public;
grant execute on function public.taam_kashikiri_charge_public(text) to anon, authenticated;

-- ── 4) 결제 시작 — 주문명도 용도별 (속도 제한·만료·멱등 주문번호는 종전 그대로) ──
create or replace function public.taam_kashikiri_order_start(p_token text, p_name text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare c public.kashikiri_charges%rowtype; v_order text; e_row public.kashikiri_events%rowtype; v_oname text;
begin
  if p_token is null or length(p_token) < 16 then raise exception '없는 링크입니다' using errcode = 'P0002'; end if;
  if to_regprocedure('public.taam_rate_hit(text,integer,interval)') is not null then
    if not public.taam_rate_hit('ksk_start:' || left(p_token, 16), 30, interval '10 minutes') then
      raise exception '요청이 너무 잦습니다. 잠시 후 다시 시도해주세요' using errcode = 'P0001';
    end if;
  end if;
  select * into c from public.kashikiri_charges where token = p_token;
  if not found then raise exception '없는 링크입니다' using errcode = 'P0002'; end if;
  if c.status = 'paid' then return jsonb_build_object('already_paid', true, 'order_id', c.order_id); end if;
  if c.status in ('cancelled','expired','refunded') then return jsonb_build_object('blocked', c.status); end if;
  if c.expires_at is not null and now() > c.expires_at then
    update public.kashikiri_charges set status = 'expired' where id = c.id;
    return jsonb_build_object('blocked', 'expired');
  end if;
  if c.event_id is not null then select * into e_row from public.kashikiri_events where id = c.event_id; end if;
  v_order := coalesce(c.order_id, 'KSK-' || replace(c.id::text, '-', ''));
  update public.kashikiri_charges
     set order_id = v_order,
         payer_name = coalesce(nullif(left(btrim(p_name), 60), ''), payer_name)
   where id = c.id;
  v_oname := case
    when c.purpose = 'membership' then '[TAAM] ' || coalesce(c.title, '멤버십')
    when e_row.id is null then '[TAAM] ' || coalesce(c.title, '결제')
    else '[TAAM] ' || to_char(e_row.event_date, 'MM/DD') || ' ' || coalesce(e_row.venue_name, 'TAAM') end;
  return jsonb_build_object('order_id', v_order, 'currency', coalesce(c.pay_currency, 'KRW'),
                            'amount', coalesce(c.pay_amount, c.amount_krw), 'amount_krw', c.amount_krw,
                            'order_name', left(v_oname, 100), 'purpose', coalesce(c.purpose, 'custom'));
end $$;
revoke all on function public.taam_kashikiri_order_start(text, text) from public;
grant execute on function public.taam_kashikiri_order_start(text, text) to anon, authenticated;

-- ── 5) 좌석 동기화 트리거 — 회차 없는 청구는 건너뛴다 (몸체는 seat_sync5 와 같다) ──
create or replace function public.taam_ksk_seat_on_charge()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_res json;
begin
  if tg_op = 'DELETE' then
    if old.event_id is not null and not coalesce(old.link_invite, false) then
      begin perform public._taam_ksk_seat_sync(old.event_id);
      exception when query_canceled or others then raise warning '[ksk_seat] charge % 삭제 동기화 실패: % %', old.id, sqlstate, sqlerrm; end;
    end if;
    return old;
  end if;
  if new.event_id is null or coalesce(new.link_invite, false) then return new; end if;
  if new.status is distinct from old.status then
    begin
      v_res := public._taam_ksk_seat_sync(new.event_id);
      if jsonb_array_length(coalesce((v_res->'short')::jsonb, '[]'::jsonb)) > 0 then
        raise warning '[ksk_seat] charge % 좌석 못 잡음(결제 기록은 유지): %', new.id, v_res->'short';
      end if;
    exception when query_canceled or others then
      raise warning '[ksk_seat] charge % 동기화 실패 (결제 기록은 유지): % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

-- ── 6) 링크 초대 홀드 확정 — 회원을 고른 링크면 결제 뒤 그 회원의 티켓이 된다 ──
create or replace function public.taam_link_invite_on_charge()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(new.link_invite, false) then return new; end if;
  if new.status = 'paid' and coalesce(old.status,'') <> 'paid' then
    begin
      update public.tickets
         set status = 'active',
             user_id = coalesce(new.user_id, user_id),                       -- 🆕 회원 링크면 소유자 이전 — memberUid 가 적히면 중복 가드가 그 회원의 예약으로 센다
             buyer_name = coalesce(nullif(new.payload->>'member_name',''), nullif(new.payer_name,''), buyer_name),
             extra_data = coalesce(extra_data,'{}'::jsonb)
                          || jsonb_build_object('paidAt', coalesce(new.approved_at, now()), 'paymentKey', new.payment_key)
                          || case when new.user_id is not null then jsonb_build_object('memberUid', new.user_id) else '{}'::jsonb end
       where status = 'hold' and purchase_id like 'LINK-%' and extra_data->>'chargeId' = new.id::text;
    exception when others then
      -- 소유자 이전이 중복 가드(DUPLICATE_PURCHASE/TIME_CONFLICT)에 막힌 경우 — 돈은 이미 승인됐다. 좌석은 확정하고 소유자만 보류한 뒤 슈퍼어드민에게 알린다
      raise warning '[link_invite] 소유자 이전 실패 (좌석은 확정 · 소유자 보류): % %', sqlstate, sqlerrm;
      update public.tickets
         set status = 'active',
             buyer_name = coalesce(nullif(new.payer_name,''), buyer_name),
             extra_data = coalesce(extra_data,'{}'::jsonb)
                          || jsonb_build_object('paidAt', coalesce(new.approved_at, now()), 'paymentKey', new.payment_key, 'memberUidPending', new.user_id, 'ownerTransferError', left(sqlerrm, 120))
       where status = 'hold' and purchase_id like 'LINK-%' and extra_data->>'chargeId' = new.id::text;
      begin
        insert into public.notifications (user_id, type, title, body, url, payload)
        select p.id, 'kashikiri_paid', '⚠ 결제 링크 소유자 이전 실패', coalesce(new.title,'티켓') || ' · ' || coalesce(new.label,'') || ' — 결제는 확정됐지만 회원에게 붙이지 못했습니다 (' || left(sqlerrm, 80) || '). 캘린더에서 확인하세요', '/',
               jsonb_build_object('charge_id', new.id, 'via', 'taam_link_invite_on_charge')
          from public.profiles p where p.role in ('superadmin','super_admin');
      exception when others then null; end;
    end;
  elsif new.status in ('cancelled','expired','failed','refunded') and coalesce(old.status,'') not in ('cancelled','expired','refunded') then
    update public.tickets set status = 'cancelled',
           extra_data = coalesce(extra_data,'{}'::jsonb) || jsonb_build_object('cancelledBy', 'charge_' || new.status, 'cancelledAt', now())
     where status in ('hold','active') and purchase_id like 'LINK-%' and extra_data->>'chargeId' = new.id::text;
  end if;
  return new;
end $$;

-- ── 7) 멤버십 링크 결제 → 연회비 기록 자동 (예치금 부여는 사람이) · 환불 → 기록 삭제 ──
create or replace function public.taam_pay_link_on_paid()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_fee_krw bigint; v_cur text; v_fee numeric; v_tier text; v_kind text; v_date date;
begin
  if coalesce(new.purpose,'') <> 'membership' then return new; end if;
  if new.status = 'paid' and coalesce(old.status,'') <> 'paid' and new.applied_at is null then
    begin
      if to_regclass('public.membership_fees') is null then raise exception 'membership_fees 표가 없다'; end if;
      if new.user_id is null then raise exception '회원이 없는 멤버십 링크'; end if;
      v_cur := upper(coalesce(new.pay_currency,'KRW')); v_tier := new.payload->>'tier'; v_kind := coalesce(new.payload->>'kind','join');
      v_fee := (new.payload->>'fee')::numeric; v_fee_krw := coalesce((new.payload->>'fee_krw')::bigint, case when v_cur = 'KRW' then v_fee::bigint else round(v_fee * coalesce(new.pay_fx,0))::bigint end);
      v_date := (coalesce(new.approved_at, now()) at time zone 'Asia/Seoul')::date;
      insert into public.membership_fees (user_id, paid_at, amount_krw, fx_currency, fx_amount, method, tier, note, source, source_ref, created_by)
      values (new.user_id, v_date, coalesce(v_fee_krw, 0)::int,
              case when v_cur in ('USD','JPY') then v_cur end, case when v_cur in ('USD','JPY') then v_fee end,
              'link', case when v_tier in ('M','T') then v_tier end,
              coalesce(new.title, '멤버십') || ' — 결제 링크 자동 기록' || case when v_kind = 'join' then ' · 예치금 부여 ₩' || to_char(coalesce((new.payload->>'deposit_krw')::bigint, 0), 'FM999,999,990') || ' 는 부여 화면에서' else '' end,
              'pay_link', new.id::text, (select a.created_by from public.kashikiri_charge_admin a where a.charge_id = new.id));
      update public.kashikiri_charges set applied_at = now(), applied_note = 'fee_recorded' where id = new.id;
    exception when others then
      raise warning '[pay_link] 연회비 자동 기록 실패 (결제는 유지): % %', sqlstate, sqlerrm;
      begin
        update public.kashikiri_charges set applied_note = 'fee_record_failed' where id = new.id;   -- 원문은 회원이 못 읽는 어드민 표에
        insert into public.kashikiri_charge_admin (charge_id, fail_note) values (new.id, left(sqlstate || ' ' || sqlerrm, 300))
          on conflict (charge_id) do update set fail_note = excluded.fail_note;
        insert into public.notifications (user_id, type, title, body, url, payload)
        select p.id, 'membership_fee_due', '⚠ 연회비 자동 기록 실패', coalesce(new.title,'멤버십') || ' · ' || coalesce(new.label,'') || ' — 회원 원장 연회비 탭에 직접 적어 주세요 (' || left(sqlerrm, 120) || ')', '/?feedue=1',
               jsonb_build_object('charge_id', new.id, 'via', 'taam_pay_link_on_paid')
          from public.profiles p where p.role in ('superadmin','super_admin') and p.deleted_at is null;
      exception when others then null; end;
    end;
  elsif new.status = 'refunded' and coalesce(old.status,'') = 'paid' then
    begin
      if to_regclass('public.membership_fees') is not null then
        delete from public.membership_fees where source = 'pay_link' and source_ref = new.id::text;
      end if;
      update public.kashikiri_charges set applied_note = coalesce(applied_note,'') || ' · refunded_fee_removed' where id = new.id;
    exception when others then raise warning '[pay_link] 환불 뒤 연회비 기록 삭제 실패: %', sqlerrm; end;
  end if;
  return new;
end $$;
drop trigger if exists trg_pay_link_on_paid on public.kashikiri_charges;
create trigger trg_pay_link_on_paid after update of status on public.kashikiri_charges
  for each row execute function public.taam_pay_link_on_paid();

-- ── 8) 결제 완료 알림 — 용도별 문구 (회차 없어도) ──
create or replace function public.taam_kashikiri_paid_notify()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_venue text; v_date date; v_time time; v_title text; v_body text; v_url text; v_n int := 0; v_who text; v_amt text; v_tag text; v_purpose text;
begin
  if coalesce(new.status,'') <> 'paid' or coalesce(old.status,'') = 'paid' then return new; end if;
  begin
    v_purpose := coalesce(new.purpose, case when coalesce(new.link_invite,false) then 'ticket' else 'custom' end);
    if new.event_id is not null then
      select e.venue_name, e.event_date, e.event_time into v_venue, v_date, v_time from public.kashikiri_events e where e.id = new.event_id;   -- record 변수는 회차가 없을 때 「not assigned」로 터진다 — 스칼라로
    end if;
    v_who := coalesce(nullif(btrim(new.payer_name), ''), nullif(btrim(new.label), ''), '결제자');
    v_amt := public._taam_ksk_money(new.pay_currency, new.pay_amount, new.amount_krw);
    v_url := '/';
    v_tag := 'ksk-paid-' || new.id::text;
    if v_purpose = 'membership' then
      v_title := '💳 멤버십 결제 완료';
      v_body  := coalesce(new.label, v_who) || ' · ' || coalesce(new.title, '멤버십') || ' · ' || v_amt
              || case when upper(coalesce(new.pay_currency,'KRW')) <> 'KRW' then ' (₩' || to_char(coalesce(new.amount_krw,0), 'FM999,999,990') || ')' else '' end
              || case when coalesce(new.payload->>'kind','join') = 'join'
                      then ' → 예치금 부여 ₩' || to_char(coalesce((new.payload->>'deposit_krw')::bigint, 0), 'FM999,999,990') || ' 필요' else '' end
              || case when (select c.applied_note from public.kashikiri_charges c where c.id = new.id) like 'fee_record_failed%'
                      then ' · ⚠ 연회비 자동 기록 실패 — 원장 연회비 탭에 직접 적어 주세요'     -- 앞 트리거(trg_pay_link_on_paid · 이름순)가 적은 값을 다시 읽는다
                      else ' · 연회비 기록은 자동' end;
      v_url := '/?feedue=1';
    elsif v_date is null then
      v_title := case when coalesce(new.link_invite,false) then '🔗 링크 초대 결제 완료' else '💳 결제 완료' end;
      v_body  := coalesce(new.title, '결제') || ' · ' || v_who || ' · ' || v_amt
              || case when upper(coalesce(new.pay_currency,'KRW')) <> 'KRW' then ' (₩' || to_char(coalesce(new.amount_krw,0), 'FM999,999,990') || ')' else '' end;
    else
      v_title := case when coalesce(new.link_invite, false) then '🔗 링크 초대 결제 완료' else '💳 정산 결제 완료' end;
      v_body  := coalesce(v_venue, '회차') || ' ' || coalesce(to_char(v_date, 'YYYY.MM.DD'), '')
              || coalesce(' ' || to_char(v_time, 'HH24:MI'), '')
              || ' · ' || v_who || ' · ' || v_amt
              || case when upper(coalesce(new.pay_currency,'KRW')) <> 'KRW' then ' (₩' || to_char(coalesce(new.amount_krw,0), 'FM999,999,990') || ')' else '' end;
    end if;
    insert into public.notifications (user_id, type, title, body, url, payload)
    select p.id, 'kashikiri_paid', v_title, left(v_body, 1000), v_url,
           jsonb_build_object('charge_id', new.id, 'event_id', new.event_id, 'team_id', new.team_id, 'purpose', v_purpose,
                              'amount_krw', new.amount_krw, 'pay_currency', new.pay_currency, 'pay_amount', new.pay_amount,
                              'link_invite', coalesce(new.link_invite, false), 'via', 'trg_taam_kashikiri_paid_notify')
      from public.profiles p
     where p.role in ('superadmin', 'super_admin');
    get diagnostics v_n = row_count;
    if v_n > 0 then
      begin perform public.taam_admin_push(v_title, v_body, v_url, v_tag, 'admin');
      exception when others then raise warning '[ksk paid notify] push 실패: %', sqlerrm; end;
    end if;
  exception when others then
    raise warning '[ksk paid notify] 알림 실패(결제 확정은 그대로): %', sqlerrm;
  end;
  return new;
end $$;

-- ── 9) 환불 견적 — 멤버십·자유 금액은 슈퍼어드민 판단으로 전액 (티켓 규정은 티켓 링크에만) ──
create or replace function public.taam_link_invite_refund_quote(p_charge_id text)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_ch  public.kashikiri_charges%rowtype;
  v_tk  public.tickets%rowtype;
  v_days int; v_agency bigint := 0; v_refund bigint := 0; v_policy text; v_visit date;
begin
  select * into v_ch from public.kashikiri_charges where id::text = p_charge_id;
  if not found then raise exception 'CHARGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_ch.status <> 'paid' then
    return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'refund_krw', 0, 'refund_amount', 0, 'policy', 'not_paid');
  end if;
  if coalesce(v_ch.purpose,'') in ('membership','custom') and not coalesce(v_ch.link_invite,false) then
    v_refund := v_ch.amount_krw; v_policy := 'admin_full';
  else
    select * into v_tk from public.tickets where purchase_id like 'LINK-%' and extra_data->>'chargeId' = v_ch.id::text order by created_at desc limit 1;
    v_agency := coalesce((v_tk.extra_data->>'agencyFee')::bigint, 0) * greatest(coalesce(v_tk.party_size,1),1);
    begin v_visit := to_date(v_tk.reservation_date, 'YYYY.MM.DD'); exception when others then v_visit := null; end;
    v_days := case when v_visit is null then null else (v_visit - (now() at time zone 'Asia/Seoul')::date) end;
    if v_ch.approved_at is not null and now() - v_ch.approved_at <= interval '30 minutes' then
      v_refund := v_ch.amount_krw; v_policy := 'within_30min_full';
    elsif v_days is null or v_days >= 31 then
      v_refund := greatest(0, v_ch.amount_krw - v_agency); v_policy := 'd31_minus_agency';
    else
      v_refund := 0; v_policy := 'after_d30_none';
    end if;
  end if;
  return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'currency', v_ch.pay_currency, 'purpose', coalesce(v_ch.purpose,'custom'),
    'paid_krw', v_ch.amount_krw, 'paid_amount', v_ch.pay_amount, 'agency_krw', v_agency, 'days_left', v_days,
    'refund_krw', v_refund,
    'refund_amount', case when v_ch.pay_currency = 'KRW' then v_refund
                          when v_ch.pay_currency = 'JPY' then round(v_refund / nullif(v_ch.pay_fx,0))
                          else round(v_refund / nullif(v_ch.pay_fx,0), 2) end,
    'policy', v_policy, 'payment_key', v_ch.payment_key);
end $$;

-- ── 10) 목록 — 새 화면이 읽는다 (슈퍼어드민 · 최근 N건 · 회원 필터) ──
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
select '① kashikiri_charges.purpose · title · payload · applied_at' as 항목,
       case when (select count(*) from information_schema.columns where table_schema='public' and table_name='kashikiri_charges' and column_name in ('purpose','title','subtitle','payload','applied_at','created_by')) = 6 then '✅' else '❌' end as 결과
union all select '② event_id 가 비어도 됨', case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='kashikiri_charges' and column_name='event_id' and is_nullable='YES') then '✅' else '❌' end
union all select '③ 멤버십 금액 규칙 (국내 M 11,250,000 / T 3,150,000 · 해외 M $9,900 / T $3,000)',
       case when to_regprocedure('public.taam_membership_price(text,text,text)') is null then '❌'
            when (public.taam_membership_price('M','join','KRW')->>'total') = '11250000' and (public.taam_membership_price('T','join','KRW')->>'total') = '3150000'
             and (public.taam_membership_price('M','join','USD')->>'total') = '9900' and (public.taam_membership_price('T','renew','USD')->>'total') = '300' then '✅'
            else '⚠ 설정값 다름: M ' || (public.taam_membership_price('M','join','KRW')->>'total') || ' · T ' || (public.taam_membership_price('T','join','KRW')->>'total') end
union all select '④ 만들기·목록 RPC', case when to_regprocedure('public.taam_pay_link_create(text,jsonb)') is not null and to_regprocedure('public.taam_pay_link_list(integer,uuid,text)') is not null then '✅' else '❌' end
union all select '⑤ 공개 RPC(charge_public · order_start) 새 판', case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_charge_public') and prosrc like '%''purpose''%')
             and exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_order_start') and prosrc like '%purpose%') then '✅' else '❌' end
union all select '⑥ 트리거 — 연회비 자동 기록 · 좌석(회차 없음 건너뜀) · 홀드 소유자 이전 · 알림 용도별',
       case when exists (select 1 from pg_trigger where tgname='trg_pay_link_on_paid' and not tgisinternal)
             and exists (select 1 from pg_proc where oid = to_regproc('public.taam_ksk_seat_on_charge') and prosrc like '%event_id is null%')
             and exists (select 1 from pg_proc where oid = to_regproc('public.taam_link_invite_on_charge') and prosrc like '%memberUid%')
             and exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_paid_notify') and prosrc like '%멤버십 결제 완료%') then '✅' else '❌' end
union all select '⑦ anon 은 공개 RPC 둘만', case when has_function_privilege('anon','public.taam_pay_link_create(text,jsonb)','execute') or has_function_privilege('anon','public.taam_pay_link_list(integer,uuid,text)','execute') or has_function_privilege('anon','public.taam_membership_price(text,text,text)','execute') then '❌ anon 이 부를 수 있음'
            when has_function_privilege('anon','public.taam_kashikiri_charge_public(text)','execute') and has_function_privilege('anon','public.taam_kashikiri_order_start(text,text)','execute') then '✅' else '❌ 공개 RPC 권한 빠짐' end
union all select '⑧ 의존 함수 존재 (taam_link_invite_create · _taam_ksk_money · taam_admin_push · membership_fees 표)',
       case when to_regproc('public.taam_link_invite_create') is not null and to_regproc('public._taam_ksk_money') is not null and to_regproc('public.taam_admin_push') is not null and to_regclass('public.membership_fees') is not null then '✅' else '❌ 빠진 것 있음 — 20260929_link_invite · 20261013_kashikiri_paid_notify · 20261015_membership_fees 를 먼저' end
union all select '⑧-b 어드민 메모 표 · purpose 기본 트리거 · 운영 행 판정(memberUid)',
       case when to_regclass('public.kashikiri_charge_admin') is not null and exists (select 1 from pg_trigger where tgname='trg_charge_purpose_default' and not tgisinternal)
             and not public._taam_ticket_is_ops('LINK-x', '{"memberUid":"u"}'::jsonb) and public._taam_ticket_is_ops('LINK-x', '{}'::jsonb) then '✅' else '❌' end
union all select '⑨ 기존 청구 purpose 분류', (select count(*) from public.kashikiri_charges where purpose='ticket')::text || ' 티켓(링크 초대) · ' || (select count(*) from public.kashikiri_charges where purpose='custom')::text || ' 정산';
