-- ═══════════════════════════════════════════════════════════════
-- TAAM — 일반 회원(A 등급)은 「일반공개」 티켓만 산다 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 무엇을 만드나
--   초대는 같지만 멤버십과 완전히 갈리는 등급 하나. 티켓은 「일반공개」로
--   분류된 것만 살 수 있고, 계보도·컨텐츠는 유료 회원 전용이 된다.
--
-- 왜 새 축이 아니라 membership_tier 인가
--   서버가 이미 이 값으로 티켓을 막고 있다(trg_taam_guard_ticket_tier).
--   심지어 taam_tier_rank 에 A(1) 이 이미 들어 있고, 초대코드 제약도
--   ('A','T','M') 로 열려 있다(sql/ticket_min_tier.sql). role 로 새 축을
--   만들면 그 가드와 RLS 를 전부 다시 훑어야 하고, 그 과정에서 하나를
--   빠뜨린다. 이미 도는 길에 얹는다.
--
-- ⚠ 여기가 이 파일의 전부다 — 기본값을 뒤집지 않는다
--   「min_tier 가 비면 T 이상」으로 바꾸고 싶은 유혹이 있다. 그러면
--   기존 티켓이 저절로 유료 전용이 되니 깔끔해 보인다.
--   그런데 **등급이 아예 없는 옛 회원**(membership_tier is null)이 있다.
--   그 사람들은 rank 0 이라 모든 티켓에서 튕긴다 — 멀쩡한 회원이 갑자기
--   아무것도 못 산다. 라이브를 깨는 변경이다.
--
--   그래서 반대로 간다: **A 등급만 추가로 막는다.**
--     · min_tier 비어 있음  → A 는 막힘, 그 밖(T·M·등급없음)은 종전 그대로
--     · min_tier = 'A'      → 일반공개. 전부 통과
--     · min_tier = 'T'·'M'  → 종전 그대로
--   지금 A 등급인 회원이 한 명도 없으므로, 이 변경으로 **아무도 영향받지
--   않는다.** A 를 발급하는 순간부터만 의미가 생긴다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ 앱보다 **먼저** 실행한다.
--   읽는 법: 맨 아래 표에 ❌ 가 한 줄도 없어야 정상.
-- ═══════════════════════════════════════════════════════════════

-- 「일반공개」가 무엇인지 한 곳에 적어 둔다. 값이 흩어지면 반드시 어긋난다.
create or replace function public.taam_tier_is_open(p_min_tier text)
returns boolean
language sql immutable
as $$
  select upper(coalesce(btrim(p_min_tier), '')) = 'A'
$$;

comment on function public.taam_tier_is_open(text) is
  '이 티켓이 「일반공개」인가. min_tier = A 하나뿐이다 — 비어 있는 것은 일반공개가 아니다.';


-- ═══════════════════════════════════════════════════════════════
-- 티켓 구매 가드 — A 등급 규칙을 얹는다
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_guard_ticket_tier()
returns trigger
language plpgsql
security definer
set search_path = public
as $tier$
declare
  v_need text;
  v_mine text;
begin
  -- 티켓 상품과 무관한 행(수동입력·좌석홀드)은 대상이 아니다
  if new.ticket_product_id is null or btrim(new.ticket_product_id::text) = '' then
    return new;
  end if;
  if coalesce(new.purchase_id, '') like 'MAN-%' then return new; end if;
  if coalesce(new.purchase_id, '') like 'INV-%'  then return new; end if;
  if coalesce(new.purchase_id, '') like 'INVH-%' then return new; end if;
  if coalesce(new.status, '') in ('cancelled','canceled') then return new; end if;

  -- 슈퍼어드민만 면제. 운영·검수에서 모든 티켓을 열어봐야 한다.
  --   ⚠ 파트너 어드민(role='admin')은 면제하지 않는다.
  if public._taam_uid_is_super() then return new; end if;

  select upper(coalesce(btrim(tp.min_tier), ''))
    into v_need
    from public.ticket_products tp
   where tp.id::text = new.ticket_product_id::text;

  v_mine := public.taam_user_tier(new.user_id);

  -- 🆕 2026.09: 일반 회원(A)은 **「일반공개」로 분류된 티켓만** 산다.
  --   min_tier 가 비어 있는 티켓은 「아무나」가 아니라 「기본 = 유료 회원」이다.
  --   이 한 줄이 없으면 A 를 발급하는 순간 기존 티켓 전부가 일반공개가 된다.
  if upper(coalesce(v_mine, '')) = 'A' and not public.taam_tier_is_open(v_need) then
    raise exception
      'TIER_BLOCKED: 이 티켓은 멤버십 회원만 구매할 수 있습니다 (회원 등급 A)'
      using errcode = '42501';
  end if;

  -- 🆕 「일반공개」는 **하한이 아니라 개방**이다. 누구나 통과한다.
  --   ⚠ 여기를 빼면 min_tier='A' 가 「A 등급 이상」으로 읽혀서, 등급이 아예
  --     없는 옛 회원(rank 0)이 일반공개 티켓에서 튕긴다. 일반공개로 열어
  --     놓고 못 사게 되는, 정반대의 결과가 된다.
  if public.taam_tier_is_open(v_need) then
    return new;
  end if;

  -- 제한 없는 티켓 (또는 티켓 상품을 못 찾음) → 통과
  if v_need is null or public.taam_tier_rank(v_need) = 0 then
    return new;
  end if;

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
  '등급 제한 티켓(min_tier)을 서버에서 막는다. A 등급은 min_tier=A(일반공개)만 구매 가능. 슈퍼어드민·초대·수동입력은 예외.';


-- ═══════════════════════════════════════════════════════════════
-- 초대코드 — A 를 발급할 수 있어야 한다
-- ═══════════════════════════════════════════════════════════════
--   sql/ticket_min_tier.sql 이 이미 열어 뒀지만, 옛 제약이 남아 있는
--   환경이 있을 수 있다. 남아 있으면 A 초대코드 발급이 통째로 실패한다.
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'invite_codes_tier_check') then
    alter table public.invite_codes drop constraint invite_codes_tier_check;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'invite_codes_invitee_tier_chk') then
    alter table public.invite_codes
      add constraint invite_codes_invitee_tier_chk
      check (invitee_tier is null or upper(invitee_tier) in ('A','T','M'));
  end if;
end $$;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 함수' as "구분", p.name as "이름",
       case when not exists (
              select 1 from pg_proc pr
               where pr.pronamespace = 'public'::regnamespace and pr.proname = p.name)
            then '❌ 없음' else '✅' end as "상태"
  from (values ('taam_tier_is_open'),('taam_guard_ticket_tier'),('taam_tier_rank')) as p(name)

union all
select '② A 규칙이 가드에 들어갔나', 'taam_guard_ticket_tier',
       case when prosrc like '%taam_tier_is_open%' then '✅ 들어감' else '❌ 없음' end
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_guard_ticket_tier'

union all
select '③ 초대코드가 A 를 받나', 'invite_codes',
       case when exists (select 1 from pg_constraint
                          where conname = 'invite_codes_invitee_tier_chk')
            then '✅' else '❌ 제약 없음' end

union all
-- 지금 A 등급 회원 — 0 이면 이 변경으로 아무도 영향받지 않는다
select '④ 지금 A 등급 회원', count(*)::text || ' 명', '✅'
  from public.profiles where upper(coalesce(membership_tier,'')) = 'A'

union all
-- 「일반공개」로 열려 있는 티켓
select '⑤ 일반공개 티켓 (min_tier=A)', count(*)::text || ' 건', '✅'
  from public.ticket_products where public.taam_tier_is_open(min_tier)

union all
-- A 가 못 사게 될 티켓 (지금 제한 없는 것들 — 기본이 유료 전용이 된다)
select '⑥ 기본 = 유료 전용이 되는 티켓', count(*)::text || ' 건', '✅'
  from public.ticket_products
 where coalesce(btrim(min_tier), '') = ''

 order by 1, 2;
