-- ═══════════════════════════════════════════════════════════════
-- TAAM — 설치 상태 점검 (2026-08-28)
-- ═══════════════════════════════════════════════════════════════
-- 읽기 전용. 아무것도 바꾸지 않는다.
--
-- 이 세션에서 만든 SQL 이 실제로 DB 에 반영됐는지 한 번에 본다.
-- 저장소에 파일이 있는 것과 DB 에 적용된 것은 다르다 —
-- 그 간극이 "코드는 고쳤는데 왜 안 되지" 의 단골 원인이다.
--
-- 「해야 함」 이 하나라도 있으면 그 파일을 SQL Editor 에서 실행한다.
-- ═══════════════════════════════════════════════════════════════

select * from (
  -- ① 알림 이력 RPC — 회원 행동을 슈퍼어드민 벨에 남긴다
  select 1 as "순서", 'taam_notify_admins()' as "항목",
         'sql/notify_admins_rpc.sql' as "파일",
         case when exists (select 1 from pg_proc where proname = 'taam_notify_admins')
              then '✅ 설치됨' else '❌ 해야 함' end as "상태",
         '없으면 슈퍼어드민 벨에 이력이 안 쌓인다 (푸시만 감)' as "안 하면"

  union all
  -- ② 초대 홀드 조회 RPC — 초대 결제 자기차단 방지
  select 2, 'taam_invite_hold_slots()', 'sql/invite_hold_slots.sql',
         case when exists (select 1 from pg_proc where proname = 'taam_invite_hold_slots')
              then '✅ 설치됨' else '⚠ 권장' end,
         '없어도 pax 폴백으로 동작. 있으면 더 정확하다'

  union all
  -- ③ 알림 설정 컬럼 — 기기 간 동기화 + 발송 단계 존중
  select 3, 'profiles.notif_prefs', 'sql/notif_prefs_server.sql',
         case when exists (select 1 from information_schema.columns
                            where table_schema='public' and table_name='profiles'
                              and column_name='notif_prefs')
              then '✅ 설치됨' else '❌ 해야 함' end,
         '없으면 알림 설정이 기기마다 따로 놀고 껐는데도 푸시가 온다'

  union all
  -- ④ 본인 profiles UPDATE 정책 — 알림 설정 저장에 필요
  select 4, '정책 "profiles update own"', 'sql/notif_prefs_server.sql',
         case when exists (select 1 from pg_policies
                            where schemaname='public' and tablename='profiles'
                              and policyname='profiles update own')
              then '✅ 설치됨' else '❌ 해야 함' end,
         '없으면 알림 설정 저장이 조용히 0행으로 실패한다'

  union all
  -- ⑤ 앱 업데이트 안내 설정
  select 5, 'app_config.app_version', 'sql/app_version_config.sql',
         case when exists (select 1 from public.app_config where key='app_version')
              then '✅ 설치됨' else '❌ 해야 함' end,
         '없으면 강제 업데이트 안내가 뜨지 않는다 (APP_UPDATE_LIVE 는 켜져 있음)'

  union all
  -- ⑥ 환율 — 엔화 기준율
  select 6, '환율 설정 (엔화 포함)', '어드민 → 환율 설정',
         case when coalesce((select (value->>'rate_jpy')::numeric
                               from public.app_config where key='fx_settings'), 0) > 0
              then '✅ 설치됨' else '⚠ 권장' end,
         '엔 기준율이 0 이면 JPY 회원에게 원화로 보인다'

  union all
  -- ⑦ 좌석 정원 트리거
  select 7, '트리거 enforce_ticket_capacity', 'sql/ticket_capacity_guard.sql',
         case when exists (select 1 from pg_trigger where tgname='trg_enforce_ticket_capacity')
              then '✅ 설치됨' else '❌ 해야 함' end,
         '없으면 정원을 넘겨 팔린다 (오버북)'

  union all
  -- ⑧ 매진 자동 동기화 트리거
  select 8, '트리거 sync_ticket_soldout', 'sql/seat_soldout_sync.sql',
         case when exists (select 1 from pg_trigger where tgname='trg_sync_ticket_soldout')
              then '✅ 설치됨' else '❌ 해야 함' end,
         '없으면 자리가 차도 매진으로 안 바뀐다'
) t order by "순서";


-- ═══════════════════════════════════════════════════════════════
-- 남은 정리 대상 — 있으면 손봐야 하는 데이터
-- ═══════════════════════════════════════════════════════════════
select * from (
  -- 좌석에 안 붙은 초대 (앞으로 날짜만)
  select 1 as "순서", '좌석 미연결 초대' as "항목",
         count(*)::text || '건' as "값",
         'sql/invite_unlinked_repair.sql — 결제돼도 정원에서 안 깎인다' as "조치"
    from public.reservation_invites
   where ticket_product_id is null and status in ('sent','paid')
     and length(visit_date) = 10
     and to_date(visit_date,'YYYY.MM.DD') >= current_date

  union all
  -- 5분이 지났는데 안 풀린 결제 홀드
  select 2, '만료된 결제 홀드',
         count(*)::text || '건',
         'sql/seat_hold_repair.sql — 자리를 붙잡고 있어 판매가 막힌다'
    from public.tickets
   where coalesce(status,'') = 'hold'
     and purchase_id like 'PAYH-%'
     and created_at < now() - interval '10 minutes'

  union all
  -- 예치금 주머니가 아직 어긋난 회원
  select 3, '주머니 보정 남은 회원',
         count(*)::text || '명',
         'sql/deposit_pocket_repair.sql — 멤버십이 일반으로 넘어간 채다'
    from (
      select rf.user_id
        from (select user_id, metadata->>'purchase_id' pid, sum(amount) amt
                from public.deposit_transactions
               where change_type='ticket_refund' and deposit_type='general'
                 and metadata->>'purchase_id' is not null group by 1,2) rf
        join (select user_id,
                     coalesce(metadata->>'purchase_id',
                       case when metadata->>'invite_id' is not null
                            then 'INV-'||left(metadata->>'invite_id',8) end) pid,
                     sum(case when deposit_type='membership' then abs(amount) else 0 end) mo
                from public.deposit_transactions
               where change_type='ticket_purchase'
                 and (metadata->>'purchase_id' is not null or metadata->>'invite_id' is not null)
               group by 1,2) p
          on p.user_id=rf.user_id
         and (p.pid=rf.pid or (rf.pid like 'INV-%' and p.pid=left(rf.pid,12)))
       where p.mo > 0
       group by rf.user_id
       having sum(round(rf.amt * p.mo::numeric / nullif(p.mo,0))) > 0
    ) x
    join public.profiles pr on pr.id = x.user_id
   where pr.general_deposit_balance > 0

  union all
  -- 푸시 구독이 없는 회원 (알림을 못 받는다)
  select 4, '푸시 구독 없는 회원',
         count(*)::text || '명',
         '그 회원은 알림을 못 받는다. 앱/웹을 한 번 열면 자동 등록된다'
    from public.profiles p
   where not exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
     and coalesce(p.deposit_balance,0) > 0
) t order by "순서";
