-- ═══════════════════════════════════════════════════════════════
-- 예치금 대조 — 잔액과 거래기록이 맞는가 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 왜 보나
--   오늘까지 회원 세션이 자기 예치금 잔액을 직접 쓸 수 있었다.
--   실제로 그런 일이 있었는지는 「지금 잔액」과 「거래기록의 합」을
--   맞춰보면 드러난다. 앱을 거친 변화는 반드시 기록을 남기기 때문에,
--   기록 없이 잔액만 늘어난 계정이 있으면 그건 앱 밖에서 생긴 것이다.
--
-- ⚠ 어긋난다고 곧바로 조작은 아니다
--   아래 셋은 정상인데도 어긋나 보인다. 결과를 볼 때 같이 감안한다.
--     · 기록을 남기기 전의 옛 데이터 (거래기록 도입 이전 잔액)
--     · 슈퍼어드민이 화면에서 직접 조정한 값 중 기록을 안 남긴 경우
--     · 연회비 예치금처럼 다른 경로로 들어온 최초 입금
--   그래서 이 조회는 「범인 찾기」가 아니라 **볼 곳을 좁히는 것**이다.
--   금액이 크고 부호가 플러스(기록보다 잔액이 많다)인 줄부터 본다.
--
-- 실행: Supabase SQL Editor. 읽기만 한다 — 아무것도 바꾸지 않는다.
-- ═══════════════════════════════════════════════════════════════

with tx as (
  select user_id, sum(amount)::bigint as 기록합, count(*) as 건수,
         max(created_at) as 마지막기록
  from public.deposit_transactions
  group by user_id
)
select coalesce(p.display_name, '(이름 없음)')            as "회원",
       coalesce(p.email, p.phone, '(연락처 없음)')        as "연락처",
       coalesce(p.deposit_balance,
                coalesce(p.membership_deposit_balance,0)
                + coalesce(p.general_deposit_balance,0))  as "지금 잔액",
       coalesce(t.기록합, 0)                              as "거래기록 합",
       coalesce(p.deposit_balance,
                coalesce(p.membership_deposit_balance,0)
                + coalesce(p.general_deposit_balance,0))
         - coalesce(t.기록합, 0)                          as "차이",
       coalesce(t.건수, 0)                                as "거래 건수",
       (t.마지막기록 at time zone 'UTC')::date            as "마지막 거래"
from public.profiles p
left join tx t on t.user_id = p.id
where p.deleted_at is null
  and coalesce(p.deposit_balance,
               coalesce(p.membership_deposit_balance,0)
               + coalesce(p.general_deposit_balance,0))
      <> coalesce(t.기록합, 0)
order by abs(coalesce(p.deposit_balance,
                      coalesce(p.membership_deposit_balance,0)
                      + coalesce(p.general_deposit_balance,0))
             - coalesce(t.기록합, 0)) desc
limit 50;

-- ───────────────────────────────────────────────────────────────
-- 참고 — 한 회원을 자세히 보려면 (id 를 넣어 실행)
-- ───────────────────────────────────────────────────────────────
--   select created_at, change_type, deposit_type, amount, balance_after, description
--   from public.deposit_transactions
--   where user_id = '<그 회원 id>'
--   order by created_at;
--
--   기록 사이의 balance_after 가 매끄럽게 이어지지 않고 갑자기 뛰면,
--   그 구간에서 기록 없는 변화가 있었다는 뜻이다.
