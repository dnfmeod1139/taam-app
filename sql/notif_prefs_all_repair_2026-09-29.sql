-- notif_prefs.all=false 복구 — 2026-09-29
-- 알림 설정의 「전체」가 「모든 항목이 켜져 있을 때만 켜짐」으로 계산돼, 7일 전 리마인드가 기본 꺼짐이 된 뒤(09-28)
-- 항목 하나만 건드려도 all=false 로 저장됐다. send-push 는 all=false 를 「이 회원에게 아무 푸시도 보내지 말라」로 읽는다.
-- 앱(2026.09.29-f 이후)은 「하나라도 켜져 있으면 전체 켜짐」으로 고쳤다. 이미 잘못 저장된 회원을 되돌린다:
--   all=false 인데 항목 중 하나라도 true 인 회원 → all=true. (모든 항목을 직접 끈 회원은 그대로 둔다.)
-- ① 미리보기 (읽기 전용)
select p.id, p.display_name, p.notif_prefs
  from public.profiles p
 where p.notif_prefs->>'all' = 'false'
   and exists (select 1 from jsonb_each(p.notif_prefs) e
                where e.key in ('fav','ticket','charge','use','refund','remind7','remind3','remind1')
                  and e.value = 'true'::jsonb);
-- ② 적용 (①의 목록이 맞으면)
-- update public.profiles p
--    set notif_prefs = p.notif_prefs || '{"all": true}'::jsonb
--  where p.notif_prefs->>'all' = 'false'
--    and exists (select 1 from jsonb_each(p.notif_prefs) e
--                 where e.key in ('fav','ticket','charge','use','refund','remind7','remind3','remind1')
--                   and e.value = 'true'::jsonb);
