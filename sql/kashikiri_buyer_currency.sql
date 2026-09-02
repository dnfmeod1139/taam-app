-- ═══════════════════════════════════════════════════════════════
-- TAAM — 구매자를 불러올 때 그 회원의 통화도 같이 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   정산 링크에서 통화를 사람마다 손으로 골라야 했다. 그런데 해외 회원은
--   이미 profiles.currency 에 지정돼 있다(슈퍼어드민 → 회원 관리).
--   앱이 그걸 이미 쓰고 있는데(_taamUserCur · fxIsOverseas) 정산 화면만
--   모르고 있었다 — 아는 것을 또 묻고 있었다.
--
--   해외 손님이 섞인 자리에서 「누가 해외였더라」를 기억해 누르는 것은
--   반드시 틀린다. 틀리면 그 사람 카드에 원화가 찍히고 환가료가 붙는다.
--
-- 무엇을 바꾸나 — 함수 하나. 표도 데이터도 안 건드린다.
--   taam_kashikiri_buyers 가 currency 를 함께 돌려준다.
--   ⚠ 여전히 **금액은 안 돌려준다.** 티켓 가격은 「예약금」이고 정산 금액은
--     현장에서 나온다 — 한 화면에 같이 띄우면 반드시 섞인다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ sql/kashikiri_send.sql 다음에. 안 돌려도 앱은 돈다 —
--     통화가 안 와서 전부 원화로 잡힐 뿐이다(종전과 같음).
--   읽는 법: 맨 아래 ✅ 두 줄이면 정상.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_kashikiri_buyers(p_ticket_product_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  if coalesce(p_ticket_product_id, '') = '' then return '[]'::jsonb; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'ticket_id', t.id,
           'user_id',   t.user_id,
           'name',      coalesce(nullif(trim(t.buyer_name), ''),
                                 nullif(trim(p.display_name), ''), '구매자'),
           'phone',     coalesce(nullif(trim(t.buyer_phone), ''), nullif(trim(p.phone), '')),
           'pax',       coalesce(t.party_size, 1),
           'visit_date', t.reservation_date,
           -- 🆕 그 회원에게 지정된 통화. 미지정이면 KRW —
           --    「모르면 원화」가 맞다. 짐작해서 외화로 청구하면
           --    국내 회원 카드에 해외 결제가 찍힌다.
           'currency',  upper(coalesce(nullif(trim(p.currency), ''), 'KRW'))
         ) order by t.created_at), '[]'::jsonb)
    into v
    from public.tickets t
    left join public.profiles p on p.id = t.user_id
   where t.ticket_product_id = p_ticket_product_id
     and coalesce(t.status, '') = 'active';

  return v;
end;
$$;

revoke all on function public.taam_kashikiri_buyers(text) from public;
grant execute on function public.taam_kashikiri_buyers(text) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 함수에 통화가 들어갔나' as "구분",
       case when prosrc like '%''currency''%' then '✅ 들어감' else '❌ 없음' end as "상태",
       '' as "값"
  from pg_proc
 where pronamespace = 'public'::regnamespace and proname = 'taam_kashikiri_buyers'

union all
-- 통화가 지정된 회원이 몇 명인가 (0 이면 전부 원화로 잡힌다 — 그게 정상일 수도 있다)
select '② 통화 지정된 회원',
       count(*)::text || ' 명',
       coalesce(string_agg(distinct upper(currency), ' · '), '—')
  from public.profiles
 where currency is not null and upper(currency) <> 'KRW'

 order by 1;
