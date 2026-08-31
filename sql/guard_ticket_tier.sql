-- ═══════════════════════════════════════════════════════════════
-- TAAM — 등급 제한 티켓을 서버가 막는다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제였나
--   ticket_products.min_tier ('M'|'T'|'A') 는 「이 등급 이상만 살 수 있다」는
--   규칙인데, **앱에만 있었다.** 서버는 아무것도 안 봤다.
--
--   그리고 앱 쪽 판정에 구멍이 있었다 — _tkUserTier() 가 파트너 어드민을
--   무조건 'M' 으로 올려 줬다. 그래서 membership_tier 가 T 인 파트너 어드민이
--   M 전용 티켓의 상세 진입과 구매를 **둘 다** 통과했다. 라이브에서 확인했다.
--   앱은 BUILD 2026.08.31-l 에서 고쳤다.
--
--   앱만 고치면 앱을 거치지 않은 요청은 그대로 통과한다. 재구매 제한과
--   같은 자리에서 같은 방식으로 막는다.
--
-- 등급 계산은 앱과 한 글자도 어긋나면 안 된다
--   앱 _refreshUserGrade() 의 규칙을 그대로 옮긴다.
--     · membership_tier='M' 이고 만료일이 미래 → M
--     · membership_tier='M' 인데 만료됐거나 만료일이 없다 → **T** (null 아님)
--       (예전에 null 로 떨어뜨렸다가, 만료된 M 회원이 A 회원보다 아래가 돼
--        등급 티켓을 하나도 못 사는 사고가 났다. 회원인 이상 T 아래로는
--        내려가지 않는다.)
--     · 'T' → T · 'A' → A · 그 외 → 등급 없음(0)
--
-- 무엇을 통과시키나 (재구매 가드와 같은 예외 목록)
--   · 서버가 하는 일 (current_user 가 authenticated/anon 이 아님)
--   · MAN- (어드민 수동 입력) · INVH- (초대 좌석 홀드) · INV- (초대 구매)
--   · 취소 행
--   · 슈퍼어드민
--   ⚠ 파트너 어드민은 **통과시키지 않는다.** 바로 그것이 이번 구멍이었다.
--     파트너 어드민은 레스토랑 사장님이지 상위 등급 회원이 아니다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════


-- 컬럼이 없는 DB 에서도 아래가 죽지 않게 (있으면 아무 일도 안 한다)
alter table public.ticket_products
  add column if not exists min_tier text;


-- ═══════════════════════════════════════════════════════════════
-- ① 등급 위계 — M(3) > T(2) > A(1) > 없음(0)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_tier_rank(p_tier text)
returns int
language sql
immutable
as $$
  select case upper(coalesce(btrim(p_tier), ''))
           when 'M' then 3
           when 'T' then 2
           when 'A' then 1
           else 0
         end
$$;


-- ═══════════════════════════════════════════════════════════════
-- ② 이 회원의 실효 등급 — 앱 _refreshUserGrade() 와 같은 규칙
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_user_tier(p_user_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tier text;
  v_exp  timestamptz;
begin
  select upper(coalesce(btrim(p.membership_tier), '')), p.membership_expires_at
    into v_tier, v_exp
    from public.profiles p
   where p.id = p_user_id;

  if not found then return null; end if;

  if v_tier = 'M' then
    -- 만료일이 미래여야 M 이다. 아니면 T 로 내려앉힌다 (null 이 아니다)
    if v_exp is not null and v_exp > now() then return 'M'; end if;
    return 'T';
  end if;

  if v_tier in ('T','A') then return v_tier; end if;
  return null;
end;
$$;

comment on function public.taam_user_tier(uuid) is
  '회원의 실효 등급. 만료된 M 은 T 로 내려앉힌다 (앱 _refreshUserGrade 와 같은 규칙).';


-- ═══════════════════════════════════════════════════════════════
-- ③ 가드 — 등급 미달이면 INSERT 를 막는다
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_ticket_tier()
returns trigger
language plpgsql
set search_path = public
as $tier$
declare
  v_need text;
  v_mine text;
begin
  -- 서버(RPC·크론·service_role)가 하는 일은 막지 않는다
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if new.user_id is null or new.ticket_product_id is null then
    return new;
  end if;

  -- 어드민 수동 입력 · 초대 좌석 홀드 · 초대 구매는 등급 제한 밖이다.
  --   초대는 어드민이 사람을 골라 보낸 것이라 등급으로 다시 거를 이유가 없다.
  if new.purchase_id like 'MAN-%'
     or new.purchase_id like 'INVH-%'
     or new.purchase_id like 'INV-%'
     or coalesce(new.extra_data ->> 'manualEntry', '') in ('true','1')
     or coalesce(new.extra_data ->> 'inviteHold',  '') in ('true','1') then
    return new;
  end if;

  if coalesce(new.status, '') in ('cancelled','canceled') then
    return new;
  end if;

  -- 슈퍼어드민만 면제. 운영·검수에서 모든 티켓을 열어봐야 한다.
  --   ⚠ 파트너 어드민(role='admin')은 면제하지 않는다 — 그게 이번 구멍이었다.
  if public._taam_uid_is_super() then
    return new;
  end if;

  select upper(coalesce(btrim(tp.min_tier), ''))
    into v_need
    from public.ticket_products tp
   where tp.id::text = new.ticket_product_id::text;

  -- 제한 없는 티켓 (또는 티켓 상품을 못 찾음) → 통과
  if v_need is null or public.taam_tier_rank(v_need) = 0 then
    return new;
  end if;

  v_mine := public.taam_user_tier(new.user_id);

  if public.taam_tier_rank(v_mine) >= public.taam_tier_rank(v_need) then
    return new;
  end if;

  raise exception
    'TIER_BLOCKED: 이 티켓은 % 등급 이상만 구매할 수 있습니다 (회원 등급 %)',
    v_need, coalesce(v_mine, '없음')
    using errcode = '42501';
end;
$tier$;

drop trigger if exists trg_taam_guard_ticket_tier on public.tickets;
create trigger trg_taam_guard_ticket_tier
  before insert on public.tickets
  for each row execute function public.taam_guard_ticket_tier();

comment on function public.taam_guard_ticket_tier() is
  '등급 제한 티켓(min_tier)을 서버에서 막는다. 슈퍼어드민·초대·수동입력은 예외.';


-- ═══════════════════════════════════════════════════════════════
-- ④ 확인 — 지금 등급 제한이 걸린 티켓과, 그걸 이미 산 사람
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 「지금 규칙으로는 못 살 사람」이 이미 산 건이 있는지 본다.
--     있어도 자동으로 취소하지 않는다 — 사람이 보고 정할 일이다.
--     (파트너 어드민이 M 전용을 산 건이 여기 잡힐 수 있다)
select tp.rest_name                              as "매장",
       tp.date                                   as "티켓 날짜",
       upper(tp.min_tier)                        as "필요 등급",
       coalesce(pr.display_name, pr.phone)       as "구매자",
       coalesce(pr.role, 'user')                 as "역할",
       coalesce(public.taam_user_tier(k.user_id), '없음') as "구매자 등급",
       k.purchase_id                             as "구매ID",
       k.status                                  as "상태",
       case when public.taam_tier_rank(public.taam_user_tier(k.user_id))
               >= public.taam_tier_rank(tp.min_tier)
            then '정상'
            else '⚠ 지금 규칙으로는 못 사는 건' end as "판정"
from public.tickets k
join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
left join public.profiles pr on pr.id = k.user_id
where public.taam_tier_rank(tp.min_tier) > 0
  and coalesce(k.status,'') not in ('cancelled','canceled')
  and k.purchase_id not like 'MAN-%'
  and k.purchase_id not like 'INVH-%'
order by "판정" desc, tp.date;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   drop trigger if exists trg_taam_guard_ticket_tier on public.tickets;
--
--   이 한 줄이면 원래대로 돌아간다. 함수는 남겨둬도 무해하다.
