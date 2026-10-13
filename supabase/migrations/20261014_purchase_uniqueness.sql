-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 중복 구매·같은 시간대 차단 · 2026-10-13
--
-- 2026-10-13 카타오리 5/21 회차가 같은 회원에게 두 번 팔렸다. 재구매 가드(trg_taam_repurchase_guard)는
-- 「같은 날 두 건은 인원추가·동반」이라고 보고 같은 날짜를 일부러 통과시키고, 좌석 엔진은 회원별 규칙이 없어서
-- 「한 회원 = 한 회차 1건」을 지키는 코드가 서버 어디에도 없었다. 운영 결정(2026-10-13):
--   ① 같은 회원이 같은 회차를 두 번 사는 것은 **어떤 경로든** 막는다           → DUPLICATE_PURCHASE
--   ② 같은 날, 같은 시간대(점심/저녁)에 다른 매장(또는 같은 매장의 다른 회차)을 사는 것도 막는다 → TIME_CONFLICT
--      시간대 = 방문 시각 16:00 전이면 점심, 16:00 부터 저녁 (taam_time_slot). 점심+저녁처럼 시간대가 다르면 허용.
--      시각을 모르는 행(비어 있음·형식 불명)은 **겹치는 것으로** 본다 — 막는 쪽이 기본이다.
--
-- 적용 대상: user_id 가 있는 살아 있는 행(status 가 cancelled/canceled/expired 가 아닌 것). hold 도 센다 —
--   더블탭·두 기기 동시 결제의 두 번째 홀드를 여기서 거른다(앱은 자기 홀드를 재사용하므로 정상 재시도는 안 걸린다).
-- 제외: 운영 행(KSK-·LINK-·MAN-·INVH- / extra_data manualEntry·inviteHold·kashikiri·linkInvite) — user_id 가 회원이 아니라
--   어드민(회차 작성자)이라 서로 부딪힌다. INV-(확정된 초대)는 회원 것이므로 **센다**.
-- UPDATE 도 본다: 초대 확정(taam_invite_confirm_hold)은 INVH- 홀드를 UPDATE 로 INV- 확정 행으로 바꾸며 소유자를
--   초대받은 회원으로 옮긴다 — 그 회원이 이미 같은 회차를 갖고 있으면 여기서 막힌다(예치금 차감과 같은 트랜잭션이라 함께 되돌아간다).
--   다만 소유자·회차·날짜·시각이 그대로이고 이미 살아 있던 행의 갱신(출석 처리·금액 보정 등)은 건너뛴다 — 옛 중복 행이
--   영영 손댈 수 없게 되면 안 된다. 취소(status → cancelled)도 언제나 통과한다.
-- 호출자를 가리지 않는다: 슈퍼어드민·service_role(Edge toss-confirm 폴백 INSERT)도 같은 규칙이다 — 「어떤 일이 있어도」.
--   toss-confirm 폴백 행은 reservation_date·visit_time 이 비어 있으므로 ticket_products.date/time 으로 보충해 센다.
-- 이미 들어 있는 중복(카타오리 5/21 등)은 건드리지 않는다 — 확인 표 ⑤⑥ 에 수만 센다. 정리는 어드민이 취소로.
-- 회귀: bash sql/_test/t_purchase_unique.sh
-- ═══════════════════════════════════════════════════════════════════════════

-- 방문 시각 문자열 → 'lunch' | 'dinner' | null.  '19:00' · '12:30' · '7:00 PM' · '오후 7시' 를 읽는다.
create or replace function public.taam_time_slot(p_time text)
returns text
language plpgsql immutable
as $$
declare m text[]; h int;
begin
  if p_time is null or btrim(p_time) = '' then return null; end if;
  m := regexp_match(p_time, '(\d{1,2})(?::(\d{2}))?');
  if m is null then return null; end if;
  h := m[1]::int;
  if p_time ~* '(pm|오후)' and h < 12 then h := h + 12; end if;
  if p_time ~* '(am|오전)' and h = 12 then h := 0; end if;
  if h < 0 or h > 23 then return null; end if;
  return case when h < 16 then 'lunch' else 'dinner' end;
end $$;
comment on function public.taam_time_slot(text) is '방문 시각 → lunch(16시 전) | dinner(16시 부터) | null(모름). 같은 시간대 겹침 판정용 (2026-10-13).';

-- 방문일 문자열 → date | null.  '2027.05.21' · '2027.5.21' · '2027-05-21' · 'YYYY/M/D'. 연도 없는 '05.21' 은 null.
create or replace function public.taam_visit_date(p_text text)
returns date
language plpgsql immutable
as $$
declare m text[];
begin
  if p_text is null then return null; end if;
  m := regexp_match(btrim(p_text), '^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})');
  if m is null then return null; end if;
  return make_date(m[1]::int, m[2]::int, m[3]::int);
exception when others then
  return null;
end $$;

-- 운영 행인가 (회원 구매가 아니라 어드민이 만든 자리)
create or replace function public._taam_ticket_is_ops(p_purchase_id text, p_extra jsonb)
returns boolean
language sql immutable
as $$
  select coalesce(p_purchase_id, '') ~ '^(KSK|LINK|MAN|INVH)-'
      or coalesce(p_extra ->> 'manualEntry', '') in ('true','1')
      or coalesce(p_extra ->> 'inviteHold',  '') in ('true','1')
      or coalesce(p_extra ->> 'kashikiri',   '') in ('true','1')
      or coalesce(p_extra ->> 'linkInvite',  '') in ('true','1')
$$;

create or replace function public.taam_guard_purchase_unique()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prev   record;
  v_date   date;
  v_time   text;
  v_slot   text;
  v_tp     text;
begin
  if new.user_id is null then return new; end if;
  if coalesce(new.status, '') in ('cancelled','canceled','expired') then return new; end if;
  if public._taam_ticket_is_ops(new.purchase_id, new.extra_data) then return new; end if;

  -- 이미 살아 있던 행의 「열쇠 밖」 갱신은 건너뛴다 (출석·금액·메모). 소유자/회차/날짜/시각이 바뀌거나 죽은 행이 살아나면 본다.
  if tg_op = 'UPDATE' then
    if old.user_id is not distinct from new.user_id
       and old.ticket_product_id::text is not distinct from new.ticket_product_id::text
       and old.reservation_date is not distinct from new.reservation_date
       and old.visit_time is not distinct from new.visit_time
       and coalesce(old.status, '') not in ('cancelled','canceled','expired') then
      return new;
    end if;
  end if;

  v_tp := new.ticket_product_id::text;

  -- ① 같은 회차 중복 — 어떤 경로든
  if v_tp is not null and v_tp <> '' then
    select k.purchase_id, k.status
      into v_prev
      from public.tickets k
     where k.user_id = new.user_id
       and k.ticket_product_id::text = v_tp
       and k.id is distinct from new.id
       and coalesce(k.purchase_id, '') is distinct from coalesce(new.purchase_id, '')
       and coalesce(k.status, '') not in ('cancelled','canceled','expired')
       and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
     order by k.created_at
     limit 1;
    if found then
      raise exception 'DUPLICATE_PURCHASE: 이미 구매한 회차입니다 (기존 % · %)', v_prev.purchase_id, v_prev.status
        using errcode = '42501';
    end if;
  end if;

  -- ② 같은 날 같은 시간대 — 날짜·시각이 비어 있으면(toss-confirm 폴백 INSERT) 회차에서 보충한다
  v_date := public.taam_visit_date(new.reservation_date);
  v_time := nullif(btrim(coalesce(new.visit_time, '')), '');
  if (v_date is null or v_time is null) and v_tp is not null and v_tp <> '' then
    select coalesce(v_date, public.taam_visit_date(tp.date)), coalesce(v_time, nullif(btrim(coalesce(tp.time,'')), ''))
      into v_date, v_time
      from public.ticket_products tp
     where tp.id::text = v_tp;
  end if;
  if v_date is null then return new; end if;   -- 날짜를 끝내 모르면 못 센다 (회차 없는 옛 행)
  v_slot := public.taam_time_slot(v_time);

  select k.purchase_id, k.restaurant_name, k.reservation_date, k.visit_time
    into v_prev
    from public.tickets k
    left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
   where k.user_id = new.user_id
     and k.id is distinct from new.id
     and coalesce(k.purchase_id, '') is distinct from coalesce(new.purchase_id, '')
     and coalesce(k.status, '') not in ('cancelled','canceled','expired')
     and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
     and coalesce(public.taam_visit_date(k.reservation_date), public.taam_visit_date(tp.date)) = v_date
     and ( v_slot is null
           or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) is null
           or public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) = v_slot )
   order by k.created_at
   limit 1;
  if found then
    raise exception 'TIME_CONFLICT: 같은 날 같은 시간대에 이미 예약이 있습니다 (% · % %)',
      coalesce(v_prev.restaurant_name, '다른 매장'), coalesce(v_prev.reservation_date, v_date::text), coalesce(v_prev.visit_time, '')
      using errcode = '42501';
  end if;

  return new;
end $$;

drop trigger if exists trg_taam_guard_purchase_unique on public.tickets;
create trigger trg_taam_guard_purchase_unique
  before insert or update of user_id, status, ticket_product_id, reservation_date, visit_time
  on public.tickets
  for each row execute function public.taam_guard_purchase_unique();

-- ── 확인 (한 표) — ❌ 가 없어야 정상. ⑤⑥ 은 이미 들어 있는 겹침의 수(정보) ──
with live as (
  select k.user_id, k.ticket_product_id::text as tp, k.purchase_id, k.restaurant_name,
         coalesce(public.taam_visit_date(k.reservation_date), public.taam_visit_date(tp.date)) as vd,
         public.taam_time_slot(coalesce(nullif(btrim(coalesce(k.visit_time,'')),''), tp.time)) as slot
    from public.tickets k
    left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
   where k.user_id is not null
     and coalesce(k.status,'') not in ('cancelled','canceled','expired')
     and not public._taam_ticket_is_ops(k.purchase_id, k.extra_data)
)
select '① 트리거 trg_taam_guard_purchase_unique' as what,
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_purchase_unique') then '✅' else '❌' end as result
union all
select '② 시간대 판정 12:00→lunch · 19:00→dinner · 빈값→null',
       case when public.taam_time_slot('12:00') = 'lunch' and public.taam_time_slot('19:00') = 'dinner' and public.taam_time_slot('') is null then '✅' else '❌' end
union all
select '③ 날짜 판정 2027.5.21 = 2027-05-21',
       case when public.taam_visit_date('2027.5.21') = date '2027-05-21' and public.taam_visit_date('05.21') is null then '✅' else '❌' end
union all
select '④ 운영 행 제외 KSK-/LINK-/MAN-/INVH-',
       case when public._taam_ticket_is_ops('KSK-1','{}') and public._taam_ticket_is_ops('INVH-1','{}') and not public._taam_ticket_is_ops('INV-1','{}') and not public._taam_ticket_is_ops('PAYH-1','{}') then '✅' else '❌' end
union all
select '⑤ 이미 들어 있는 같은 회차 중복 (회원·회차 쌍)',
       '✅ ' || (select count(*) from (select user_id, tp from live where tp is not null group by user_id, tp having count(*) > 1) d)::text || '쌍'
union all
select '⑥ 이미 들어 있는 같은 날 같은 시간대 겹침 (회원·날짜 쌍)',
       '✅ ' || (select count(*) from (select user_id, vd from live where vd is not null group by user_id, vd, coalesce(slot,'?') having count(distinct purchase_id) > 1) d)::text || '쌍';
