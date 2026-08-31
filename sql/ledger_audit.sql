-- ═══════════════════════════════════════════════════════════════
-- TAAM — 예치금 원장에 위조된 행이 있는가 (1단계 · 읽기만) · 2026-08-31
-- ═══════════════════════════════════════════════════════════════
-- 설계: docs/DESIGN_ledger_server_side.md
--
-- 왜 재나
--   deposit_transactions 의 INSERT 정책이 「본인 행이면 통과」라, 회원이
--   자기 이름으로 아무 거래기록이나 넣을 수 있다. 돈은 못 움직이지만
--   ① 감사 기록이 오염되고 ② 환불 주머니(멤버십/일반) 비율이 바뀐다.
--
--   막는 건 4단계짜리 작업이다. **그 전에 지금 상태를 안다.**
--   이미 위조된 게 있으면 규모를 알고 시작하고, 없으면 「지금부터 막는」
--   문제로 좁혀진다.
--
-- ⚠ 읽기만 한다. 아무것도 바꾸지 않는다.
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--       결과가 **한 화면**에 나오도록 union all 로 묶었다.
-- ═══════════════════════════════════════════════════════════════

with
-- ── 회원별 원장 합계 vs 실제 잔액 ──────────────────────────────
recon as (
  select p.id,
         coalesce(p.display_name, p.phone, '(이름없음)') as who,
         coalesce(p.membership_deposit_balance,0) + coalesce(p.general_deposit_balance,0) as bal,
         coalesce((select sum(d.amount) from public.deposit_transactions d
                    where d.user_id = p.id), 0) as led
    from public.profiles p
),
-- ── 티켓 구매인데 그런 티켓이 없는 행 ──────────────────────────
orphan as (
  select d.id, d.user_id, d.metadata->>'purchase_id' as pid, d.amount
    from public.deposit_transactions d
   where d.change_type = 'ticket_purchase'
     and d.metadata->>'purchase_id' is not null
     and not exists (select 1 from public.tickets t
                      where t.purchase_id = d.metadata->>'purchase_id')
),
-- ── 같은 구매·같은 주머니에 차감 행이 둘 이상 ──────────────────
dup as (
  select d.metadata->>'purchase_id' as pid, d.deposit_type, count(*) as n
    from public.deposit_transactions d
   where d.change_type = 'ticket_purchase'
     and d.metadata->>'purchase_id' is not null
   group by 1, 2
  having count(*) > 1
),
-- ── 남의 구매를 참조하는 행 (소유자 불일치) ────────────────────
crossref as (
  select d.id, d.user_id, d.metadata->>'purchase_id' as pid
    from public.deposit_transactions d
    join public.tickets t on t.purchase_id = d.metadata->>'purchase_id'
   where d.metadata->>'purchase_id' is not null
     and t.user_id is distinct from d.user_id
)
select '① 전체 원장 행'                as "항목",
       count(*)::text                  as "값",
       '—'                             as "비고"
  from public.deposit_transactions
union all
select '② 잔액과 원장이 어긋난 회원',
       count(*)::text,
       case when count(*) = 0 then '✅ 없음'
            else '⚠ 아래 ②-1 에 목록' end
  from recon where bal <> led
union all
select '②-1  ' || who,
       '잔액 ' || bal::text || ' / 원장 ' || led::text,
       '차이 ' || (bal - led)::text
  from recon where bal <> led
union all
select '③ 티켓이 없는 구매 기록',
       count(*)::text,
       case when count(*) = 0 then '✅ 없음' else '⚠ 확인 필요' end
  from orphan
union all
select '③-1  구매ID ' || coalesce(pid,'(없음)'),
       amount::text,
       '그런 티켓이 없다'
  from orphan
union all
select '④ 같은 구매·주머니에 중복 차감',
       count(*)::text,
       case when count(*) = 0 then '✅ 없음' else '⚠ 위조 의심' end
  from dup
union all
select '④-1  구매ID ' || coalesce(pid,'(없음)'),
       deposit_type || ' ' || n::text || '행',
       '한 주머니에 한 행이어야 정상'
  from dup
union all
select '⑤ 남의 구매를 참조하는 행',
       count(*)::text,
       case when count(*) = 0 then '✅ 없음' else '🔴 위조' end
  from crossref
union all
select '⑤-1  구매ID ' || coalesce(pid,'(없음)'),
       user_id::text,
       '이 구매의 주인이 아니다'
  from crossref
order by 1;


-- ═══════════════════════════════════════════════════════════════
-- 읽는 법
-- ═══════════════════════════════════════════════════════════════
--   ② 잔액 ≠ 원장
--      원장은 「돈이 움직인 이유」의 기록이다. 합계가 잔액과 다르면
--      어딘가에서 기록 없이 잔액이 움직였거나, 기록만 있고 잔액이 안 움직였다.
--      ⚠ 슈퍼어드민이 손으로 잔액을 조정하면 정상적으로 어긋난다 —
--        2026-08-30 감사에서 사장님 계정 두 개가 ±1,000 으로 나왔고
--        그건 테스트 흔적이었다. 회원 계정에서 나오면 그때 파고든다.
--
--   ③ 티켓 없는 구매 기록
--      옛 데이터일 수도 있고(티켓을 지웠다), 위조일 수도 있다.
--      금액과 시각을 보고 판단한다.
--
--   ④ 중복 차감  ⑤ 남의 구매 참조
--      정상 흐름에서는 생길 수 없다. 나오면 위조로 본다.
--
-- ═══════════════════════════════════════════════════════════════
-- 다음 단계
-- ═══════════════════════════════════════════════════════════════
--   전부 ✅ 면 「지금부터 막는」 문제만 남는다 → 2단계
--   (docs/DESIGN_ledger_server_side.md)
