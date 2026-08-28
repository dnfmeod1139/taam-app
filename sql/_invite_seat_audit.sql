-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 ↔ 좌석 전수 점검 (2026-08-28)
-- ═══════════════════════════════════════════════════════════════
-- 읽기 전용. 한 줄도 바꾸지 않는다. 마지막에 고칠 SQL 을 문자열로 만들어
-- 줄 뿐, 실행은 사람이 눈으로 보고 따로 한다.
--
-- 왜 만들었나
--   초대를 취소·회수하면 좌석 홀드(INVH- 행)도 같이 풀려야 캘린더에서
--   사라진다. 지금 코드는 세 경로(회원 취소 · 슈퍼어드민 회수 · 결제 확정)
--   모두에서 해제를 부르지만, **그 수정 이전에 어긋난 채 남은 건**은
--   코드를 고쳐도 저절로 낫지 않는다. 그걸 찾아내는 게 이 파일이다.
--
-- 규칙 — 초대 상태별로 있어야 할 좌석 행
--   sent       연결 티켓 있음 → 활성 INVH- 한 줄. INV- 는 없어야 한다
--   sent       연결 티켓 없음 → 좌석 행 없음이 정상 (티켓 발행 전에 보낸 옛 초대)
--   paid                      → 활성 INV- 한 줄. INVH- 는 남아 있으면 안 된다(이중 점유)
--   cancelled / expired       → 활성 좌석 행이 하나도 없어야 한다
--
--   '활성' = tickets.status 가 'cancelled' 가 아닌 것. 코드가 쓰는 기준과 같다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN → 표 여섯 개.
--   ① 초대 기준 전수 점검      ② 주인 없는 좌석 행
--   ③ 요약 집계                ④ 고칠 SQL (좌석)
--   ⑤ 고칠 SQL (낡은 초대 상태)   — ④·⑤ 는 문장만 만든다. 실행은 사람이 한다
--   ⑥ 결제·환불 정합 (돌려준 돈이 맞나)
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 초대 기준 전수 점검 — 초대 한 건마다 좌석이 규칙대로 있는가
-- ═══════════════════════════════════════════════════════════════
--   「판정」이 ✅ 가 아닌 줄만 손대면 된다. 나머지는 정상이다.
with inv as (
  select i.*,
         left(i.id::text, 8) as id8,
         (select count(*) from public.tickets t
           where t.purchase_id like 'INVH-' || left(i.id::text,8) || '-%'
             and coalesce(t.status,'') <> 'cancelled')                     as hold_live,
         (select count(*) from public.tickets t
           where t.purchase_id like 'INVH-' || left(i.id::text,8) || '-%') as hold_all,
         (select count(*) from public.tickets t
           where ( t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'
                or coalesce(t.extra_data->>'inviteId','') = i.id::text )
             and t.purchase_id not like 'INVH-%'
             and coalesce(t.status,'') <> 'cancelled')                     as paid_live,
         (select coalesce(sum(t.party_size),0) from public.tickets t
           where t.purchase_id like 'INVH-' || left(i.id::text,8) || '-%'
             and coalesce(t.status,'') <> 'cancelled')                     as hold_pax,
         -- 🆕 2026.08-28: 취소된 좌석 행이 있는지 따로 센다.
         --   이게 없으면 '결제했는데 좌석이 없다' 가 두 가지를 뭉뚱그린다 —
         --   ① 좌석을 잃어버렸다(사고)  ② 구매를 취소해 좌석이 정상 반납됐다(정상).
         --   실제로 9건 중 전부가 ②였다. 앱이 취소 때 초대 상태를 안 내려서
         --   'paid' 로 남아 있었을 뿐이다.
         (select count(*) from public.tickets t
           where t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'
             and coalesce(t.status,'') = 'cancelled')                      as paid_cx,
         -- 환불 거래가 있으면 '돈까지 정상으로 되돌아갔다' 는 증거가 된다
         exists (select 1 from public.deposit_transactions d
                  where d.change_type = 'ticket_refund'
                    and coalesce(d.metadata->>'purchase_id','')
                        like 'INV-' || left(i.id::text,8) || '-%')         as refunded
    from public.reservation_invites i
)
select
  to_char(inv.created_at, 'MM-DD HH24:MI')                        as "보낸시각",
  inv.id8                                                         as "초대ID앞8",
  inv.status                                                      as "초대상태",
  coalesce(pr.display_name, left(inv.invitee_user_id::text,8))    as "받는분",
  inv.restaurant_name                                             as "매장",
  inv.visit_date                                                  as "방문일",
  inv.pax                                                         as "인원",
  case when inv.ticket_product_id is null then '없음' else '있음' end as "티켓연결",
  inv.hold_live                                                   as "활성홀드",
  inv.paid_live                                                   as "활성구매",
  inv.hold_pax                                                    as "홀드인원",
  inv.paid_cx                                                     as "취소된좌석",
  case when inv.refunded then '있음' else '' end                   as "환불기록",
  case
    -- 취소·회수·만료인데 좌석이 살아 있다 → 캘린더에 유령으로 남는다
    when inv.status in ('cancelled','expired') and (inv.hold_live > 0 or inv.paid_live > 0)
      then '❌ 취소된 초대인데 좌석이 살아 있음 — 캘린더에 남는다'
    -- 결제됐는데 홀드가 안 풀렸다 → 같은 초대가 좌석을 두 번 먹는다
    when inv.status = 'paid' and inv.hold_live > 0
      then '❌ 결제 완료인데 홀드도 살아 있음 — 좌석 이중 점유'
    -- 결제 후 구매를 취소한 건. 좌석도 돈도 정상 반납됐고 초대 상태만 안 내려갔다.
    --   앱은 2026.08-28 부터 취소 시 초대 상태를 같이 내린다. 그 이전 건이 여기 남는다.
    when inv.status = 'paid' and inv.paid_live = 0 and inv.paid_cx > 0 and inv.refunded
      then '· 구매 취소됨 — 좌석·환불 정상. 초대 상태만 낡음(⑤에서 정리)'
    when inv.status = 'paid' and inv.paid_live = 0 and inv.paid_cx > 0
      then '⚠ 좌석은 취소됐는데 환불 기록이 없음 — 돈을 확인해야 한다'
    -- 취소 흔적조차 없다 → 애초에 좌석이 안 만들어졌다는 뜻
    when inv.status = 'paid' and inv.paid_live = 0
      then '⚠ 결제 완료인데 좌석 행이 아예 없음 — 캘린더에 안 보임'
    -- 보냈고 티켓에 연결돼 있는데 홀드가 없다 → 남이 그 자리를 사 갈 수 있다
    when inv.status = 'sent' and inv.ticket_product_id is not null and inv.hold_live = 0
      then '⚠ 발송 중인데 좌석 홀드 없음 — 자리가 안 잡혀 있다'
    -- 홀드가 두 줄 이상 → 인원이 부풀어 보인다
    when inv.status = 'sent' and inv.hold_live > 1
      then '❌ 홀드가 ' || inv.hold_live || '줄 — 인원 중복'
    -- 티켓 없이 보낸 옛 초대. 붙일 대상이 없으니 좌석도 없는 게 맞다
    when inv.status = 'sent' and inv.ticket_product_id is null
      then '· 티켓 미발행 초대 — 좌석 없음이 정상'
    -- 좌석은 규칙대로지만 48시간이 지났다. 자동 만료가 돌았다면 여기 없어야 한다
    when inv.status = 'sent' and inv.created_at < now() - interval '48 hours'
      then '⚠ 48시간 지났는데 아직 sent — 만료 스윕 확인'
    when inv.status in ('cancelled','expired')
      then '✅ 좌석 정리됨'
    else '✅ 규칙대로'
  end                                                             as "판정"
from inv
left join public.profiles pr on pr.id = inv.invitee_user_id
order by
  case
    when inv.status in ('cancelled','expired') and (inv.hold_live > 0 or inv.paid_live > 0) then 0
    when inv.status = 'paid' and inv.hold_live > 0                                          then 0
    when inv.status = 'paid' and inv.paid_live = 0 and inv.paid_cx > 0 and inv.refunded     then 8
    when inv.status = 'paid' and inv.paid_live = 0                                          then 1
    when inv.status = 'sent' and inv.ticket_product_id is not null and inv.hold_live = 0    then 1
    when inv.status = 'sent' and inv.hold_live > 1                                          then 0
    when inv.status = 'sent' and inv.created_at < now() - interval '48 hours'                then 2
    else 9
  end,
  inv.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ② 주인 없는 좌석 행 — 초대가 지워졌는데 자리만 남은 것
-- ═══════════════════════════════════════════════════════════════
--   발송 직후 좌석 부족으로 초대를 롤백(delete)할 때 홀드 행이 남을 수 있다.
--   이런 줄은 아무도 참조하지 않으면서 정원만 먹는다.
select
  to_char(t.created_at, 'MM-DD HH24:MI')  as "만든시각",
  t.purchase_id                           as "구매ID",
  t.status                                as "좌석상태",
  t.restaurant_name                       as "매장",
  t.reservation_date                      as "방문일",
  t.party_size                            as "인원",
  t.buyer_name                            as "표시이름",
  substr(coalesce(t.extra_data->>'inviteId',''), 1, 8) as "가리키는초대",
  '❌ 초대가 없다 — 자리만 먹고 있음'      as "판정"
from public.tickets t
where coalesce(t.status,'') <> 'cancelled'
  and ( t.purchase_id like 'INVH-%' or t.purchase_id like 'INV-%' )
  and not exists (
    select 1 from public.reservation_invites i
     where left(i.id::text,8) = split_part(t.purchase_id, '-', 2)
        or i.id::text = coalesce(t.extra_data->>'inviteId','')
  )
order by t.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ③ 요약 — 몇 건이 어긋나 있나
-- ═══════════════════════════════════════════════════════════════
with inv as (
  select i.id, i.status, i.ticket_product_id,
         (select count(*) from public.tickets t
           where t.purchase_id like 'INVH-' || left(i.id::text,8) || '-%'
             and coalesce(t.status,'') <> 'cancelled') as hold_live,
         (select count(*) from public.tickets t
           where ( t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'
                or coalesce(t.extra_data->>'inviteId','') = i.id::text )
             and t.purchase_id not like 'INVH-%'
             and coalesce(t.status,'') <> 'cancelled') as paid_live,
         (select count(*) from public.tickets t
           where t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'
             and coalesce(t.status,'') = 'cancelled')  as paid_cx,
         exists (select 1 from public.deposit_transactions d
                  where d.change_type = 'ticket_refund'
                    and coalesce(d.metadata->>'purchase_id','')
                        like 'INV-' || left(i.id::text,8) || '-%') as refunded
    from public.reservation_invites i
)
select '취소·회수됐는데 좌석이 살아 있음' as "항목",
       count(*) as "건수", '❌ 캘린더에 유령으로 남는다' as "뜻"
  from inv where status in ('cancelled','expired') and (hold_live > 0 or paid_live > 0)
union all
select '결제 완료인데 홀드도 살아 있음',
       count(*), '❌ 좌석 이중 점유 — 잔여석이 실제보다 적게 나온다'
  from inv where status = 'paid' and hold_live > 0
union all
select '결제 완료인데 좌석 행이 아예 없음',
       count(*), '⚠ 캘린더에 손님이 안 보인다 — 진짜 사고'
  from inv where status = 'paid' and paid_live = 0 and paid_cx = 0
union all
select '구매 취소됨 — 초대 상태만 낡음',
       count(*), '· 좌석·환불 정상. ⑤ 로 상태만 맞추면 된다'
  from inv where status = 'paid' and paid_live = 0 and paid_cx > 0 and refunded
union all
select '좌석은 취소됐는데 환불 기록 없음',
       count(*), '⚠ 돈을 확인해야 한다'
  from inv where status = 'paid' and paid_live = 0 and paid_cx > 0 and not refunded
union all
select '발송 중인데 홀드 없음(연결 초대)',
       count(*), '⚠ 자리가 안 잡혀 남이 사 갈 수 있다'
  from inv where status = 'sent' and ticket_product_id is not null and hold_live = 0
union all
select '홀드가 2줄 이상',
       count(*), '❌ 인원이 부풀어 보인다'
  from inv where status = 'sent' and hold_live > 1
union all
-- 여기 건수가 있으면 sql/invite_hold_expiry.sql 의 pg_cron 스윕이 안 돌고 있다는 뜻이다.
-- (앱의 48시간 가드는 초대받은 사람이 결제창을 열어야만 작동한다 — 안 열면 영영 남는다)
select '48시간 넘게 sent 로 남은 연결 초대',
       count(*), '⚠ 만료 스윕(pg_cron)이 안 도는 듯 — invite_hold_expiry.sql 확인'
  from public.reservation_invites
 where status = 'sent' and ticket_product_id is not null
   and created_at < now() - interval '48 hours'
union all
select '주인 없는 좌석 행',
       (select count(*) from public.tickets t
         where coalesce(t.status,'') <> 'cancelled'
           and ( t.purchase_id like 'INVH-%' or t.purchase_id like 'INV-%' )
           and not exists (select 1 from public.reservation_invites i
                            where left(i.id::text,8) = split_part(t.purchase_id,'-',2)
                               or i.id::text = coalesce(t.extra_data->>'inviteId',''))),
       '❌ 정원만 먹고 있다';


-- ═══════════════════════════════════════════════════════════════
-- ④ 고칠 SQL — 여기서는 실행되지 않는다. 보고 나서 직접 돌린다
-- ═══════════════════════════════════════════════════════════════
--   ①·② 에서 ❌ 로 나온 좌석 행을 cancelled 로 돌리는 문장을 만들어 준다.
--   ⚠ '결제 완료인데 좌석 행 없음(⚠)' 은 여기서 만들지 않는다 —
--     없는 자리를 새로 만드는 일이라 사람이 판단해야 한다.
--
--   먼저 「대상」열을 눈으로 훑고, 지워도 되는 줄인지 확인한 다음
--   「실행문」을 복사해 새 쿼리로 RUN 한다.
select
  t.purchase_id                                     as "대상",
  t.restaurant_name || ' · ' || coalesce(t.reservation_date,'') || ' · '
    || coalesce(t.buyer_name,'') || ' ' || t.party_size || '인'  as "무엇을",
  case
    when i.id is null                            then '주인 없는 좌석'
    when i.status in ('cancelled','expired')     then '취소된 초대의 잔여 좌석'
    when i.status = 'paid'                       then '결제 후 안 풀린 홀드'
    else '홀드 중복'
  end                                               as "이유",
  'update public.tickets set status = ''cancelled'' where purchase_id = '''
    || t.purchase_id || ''';'                       as "실행문"
from public.tickets t
left join public.reservation_invites i
       on left(i.id::text,8) = split_part(t.purchase_id, '-', 2)
       or i.id::text = coalesce(t.extra_data->>'inviteId','')
where coalesce(t.status,'') <> 'cancelled'
  and ( t.purchase_id like 'INVH-%' or t.purchase_id like 'INV-%' )
  and (
        i.id is null                                                     -- 주인 없음
    or  i.status in ('cancelled','expired')                              -- 취소된 초대
    or (i.status = 'paid'  and t.purchase_id like 'INVH-%')               -- 결제 후 홀드 잔존
  )
order by t.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ⑤ 낡은 초대 상태 정리 — 여기서는 실행되지 않는다
-- ═══════════════════════════════════════════════════════════════
--   구매를 취소해 좌석도 환불도 정상으로 끝났는데 reservation_invites.status 만
--   'paid' 로 남은 건이다. 앱은 2026.08-28 부터 취소 시 초대 상태를 같이 내리므로
--   앞으로는 안 생긴다. 그 이전에 쌓인 것만 여기서 맞춘다.
--
--   ⚠ 왜 정리해야 하나 — 발송함이 이 건들을 「✓ 결제 완료」로 세어
--     PAID 건수·금액이 실제보다 커 보이고, 회수 버튼도 뜨지 않는다.
--
--   ⚠ 안전장치 — 좌석이 살아 있거나(paid_live>0) 환불 기록이 없으면 제외한다.
--     둘 중 하나라도 걸리면 그건 정리가 아니라 조사 대상이다.
--
--   「무엇을」 열을 눈으로 훑고 나서 「실행문」을 복사해 새 쿼리로 RUN 한다.
with inv as (
  select i.*,
         (select count(*) from public.tickets t
           where ( t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'
                or coalesce(t.extra_data->>'inviteId','') = i.id::text )
             and t.purchase_id not like 'INVH-%'
             and coalesce(t.status,'') <> 'cancelled')  as paid_live,
         (select count(*) from public.tickets t
           where t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'
             and coalesce(t.status,'') = 'cancelled')   as paid_cx,
         exists (select 1 from public.deposit_transactions d
                  where d.change_type = 'ticket_refund'
                    and coalesce(d.metadata->>'purchase_id','')
                        like 'INV-' || left(i.id::text,8) || '-%') as refunded
    from public.reservation_invites i
   where i.status = 'paid'
)
select
  left(inv.id::text, 8)                               as "초대ID앞8",
  coalesce(pr.display_name, '')                       as "받는분",
  inv.restaurant_name || ' · ' || coalesce(inv.visit_date,'')
    || ' · ' || inv.pax || '인'                        as "무엇을",
  to_char(inv.created_at, 'MM-DD HH24:MI')            as "보낸시각",
  '좌석 취소 ' || inv.paid_cx || '건 · 환불 기록 있음'  as "근거",
  'update public.reservation_invites set status = ''cancelled'' where id = '''
    || inv.id::text || ''' and status = ''paid'';'    as "실행문"
from inv
left join public.profiles pr on pr.id = inv.invitee_user_id
where inv.paid_live = 0
  and inv.paid_cx > 0
  and inv.refunded
order by inv.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ⑥ 초대 결제·환불 정합 — 돌려준 돈이 맞나
-- ═══════════════════════════════════════════════════════════════
--   읽기 전용. 취소된 초대 구매만 본다(살아 있는 결제는 환불이 없는 게 당연하다).
--
--   기준 — calculateTicketRefund 는 네 갈래 전부에서
--     환불액 + 유보액 = 결제액  이 되게 계산한다.
--       30분 이내      → 전액 환불 · 유보 0
--       D-31 이상      → 결제액 − 대행비 · 유보 = 대행비
--       D-30 이하      → 환불 0 · 유보 = 전액
--       슈퍼어드민 예외 → 전액 환불 · 유보 0
--     그래서 「회원부담 = 대행비유보」가 성립해야 한다.
--
--   ⚠ 그런데 실제 운영에서는 여기에 없는 차감이 있다 —
--     교통비 부담분, 앱 도입 이전에 발생한 대행비 같은 것들. 반환할 때
--     사유를 적어 차감하므로 「부담 > 유보」가 곧 잘못은 아니다.
--     그래서 판정을 ❌ 로 단정하지 않고, 환불 내용(사유)을 같이 띄운다.
--     사유가 납득되면 정상이다. 사유가 없거나 말이 안 되면 그때 파고든다.
--
--   ⚠ 결제 기록 매칭 — 초대 결제 차감에 purchase_id 를 남기기 시작한 것은
--     2026.08-28 부터다. 그 이전 건은 metadata.invite_id 로만 남아 있어
--     둘 다 봐야 한다. purchase_id 만 보면 옛 건이 통째로 '결제 기록 없음' 이 된다.
with tx as (
  select d.*,
         coalesce(
           d.metadata->>'purchase_id',
           case when d.metadata->>'invite_id' is not null
                then 'INV-' || left(d.metadata->>'invite_id', 8) end
         ) as pid
    from public.deposit_transactions d
   where d.change_type in ('ticket_purchase','ticket_refund')
),
inv as (
  select i.*,
         (select count(*) from public.tickets t
           where ( t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'
                or coalesce(t.extra_data->>'inviteId','') = i.id::text )
             and t.purchase_id not like 'INVH-%'
             and coalesce(t.status,'') <> 'cancelled') as paid_live
    from public.reservation_invites i
)
select
  left(inv.id::text,8)                                                       as "초대ID앞8",
  coalesce(pr.display_name,'')                                               as "받는분",
  inv.restaurant_name                                                        as "매장",
  inv.pax                                                                    as "인원",
  count(*) filter (where tx.change_type = 'ticket_purchase')                 as "결제건",
  count(*) filter (where tx.change_type = 'ticket_refund')                   as "환불건",
  coalesce(-sum(tx.amount) filter (where tx.change_type='ticket_purchase'),0) as "결제합",
  coalesce( sum(tx.amount) filter (where tx.change_type='ticket_refund'),0)   as "환불합",
  coalesce(-sum(tx.amount),0)                                                as "회원부담",
  coalesce(sum((tx.metadata->>'agency_held')::bigint)
             filter (where tx.change_type='ticket_refund'),0)                as "대행비유보",
  -- 사유를 읽어야 판단이 된다. 여러 건이면 이어붙인다.
  string_agg(tx.description, ' / ')
    filter (where tx.change_type = 'ticket_refund')                          as "환불 내용(사유)",
  case
    when count(*) filter (where tx.change_type='ticket_purchase') = 0
      then '⚠ 결제 기록을 못 찾음 — 따로 확인'
    when coalesce(-sum(tx.amount),0) = coalesce(sum((tx.metadata->>'agency_held')::bigint)
             filter (where tx.change_type='ticket_refund'),0)
      then '✅ 정책대로 (부담 = 유보한 대행비)'
    when coalesce(-sum(tx.amount),0) > coalesce(sum((tx.metadata->>'agency_held')::bigint)
             filter (where tx.change_type='ticket_refund'),0)
      then '⚠ 대행비 말고 더 뗐다 — 옆의 사유를 읽어보고 판단'
    else '❌ 결제액보다 더 돌려줬다 — 확인 필요'
  end                                                                        as "판정"
from inv
left join public.profiles pr on pr.id = inv.invitee_user_id
join tx on tx.pid = 'INV-' || left(inv.id::text,8)
        or tx.pid like 'INV-' || left(inv.id::text,8) || '-%'
where inv.paid_live = 0
group by inv.id, pr.display_name, inv.restaurant_name, inv.pax, inv.created_at
order by inv.created_at desc;
