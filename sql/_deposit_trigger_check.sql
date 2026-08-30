-- ═══════════════════════════════════════════════════════════════
-- ⚠ ④ 가드를 올리기 전에 반드시 이것부터 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 왜 급한가
--   deposit_transactions 의 INSERT 정책이 (auth.uid() = user_id) 였다.
--   회원이 자기 이름으로 거래기록을 직접 넣을 수 있다는 뜻이다.
--
--   그 자체로는 숫자 한 줄일 뿐인데, **거래기록을 보고 잔액을 다시 계산하는
--   트리거가 있으면** 이야기가 달라진다. 가짜 입금 한 줄이 곧 잔액이 된다.
--   그런 트리거가 있다는 정황이 코드에 있다 — index.html 에
--   「트리거가 자동 갱신 못 하는 경우 대비」, 「트리거가 합산 덮어쓰면서
--   차감 흔적 증발」 이라는 주석이 남아 있다.
--
-- 그리고 ④ 의 안전도 여기에 달렸다
--   그 트리거가 SECURITY DEFINER 면  → ④ 를 올려도 그 경로는 계속 통한다
--                                      (= 옆문이 남는다. 같이 막아야 한다)
--   SECURITY INVOKER(기본) 면        → ④ 가 그 트리거까지 막아버려서
--                                      **앱의 정상 거래기록 INSERT 가 전부 실패한다.**
--                                      구매가 그 자리에서 멈춘다.
--
--   즉 결과를 모르고 ④ 를 올리면 둘 중 하나가 난다 — 안 막히거나, 결제가 죽거나.
--
-- 실행: Supabase SQL Editor. 읽기만 한다.
-- ═══════════════════════════════════════════════════════════════

select t.tgname                                   as "트리거",
       c.relname                                  as "테이블",
       case when p.prosecdef then 'DEFINER (소유자 권한)'
            else 'INVOKER (호출자 권한)' end       as "실행 권한",
       pg_get_triggerdef(t.oid)                   as "정의",
       pg_get_functiondef(p.oid)                  as "함수 본문"
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where not t.tgisinternal
  and c.relname in ('deposit_transactions', 'profiles')
order by c.relname, t.tgname;

-- 아무 줄도 안 나오면
--   거래기록을 잔액으로 옮기는 트리거가 없다는 뜻이다. 그러면
--   deposit_transactions 는 「기록」일 뿐이라 급한 구멍은 아니다
--   (그래도 가짜 기록으로 내역을 어지럽힐 수는 있으니 나중에 정리한다).
--   이 경우 ④ 는 그대로 올려도 된다.
