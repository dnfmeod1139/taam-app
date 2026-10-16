-- ═══════════════════════════════════════════════════════════════
-- 재구매 해제 알림 대상 함수 — 호출자 검사 (2026-10-16 · 적대 리뷰)
-- ═══════════════════════════════════════════════════════════════
-- taam_repurchase_release_targets(회차) 는 옛 7일 자동 해제(sql/repurchase_release_7days.sql)가 만든 security definer 함수인데
-- 호출자 검사가 없고 authenticated 전체에 열려 있어, 로그인한 회원이면 누구나 다른 회원의 uid·이름·방문일을 읽을 수 있었다.
-- 2026-10-16 부터 앱이 「재구매 해제 뒤 푸시 묻기」(_tuRepurchaseAskPush)에서 이 함수를 쓰므로, 슈퍼어드민(또는 SQL Editor·service_role)만 부르게 조인다.
-- 몸체(대상 고르는 규칙)는 그대로다. anon 실행 권한도 걷는다.
-- 회귀: bash sql/_test/t_rpc_caller_guard.sh
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_repurchase_release_targets(p_ticket_id text)
returns table (user_id uuid, display_name text, prev_visit date, gap int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- 슈퍼어드민 · SQL Editor(postgres) · service_role 만. 회원·비로그인은 거절.
  if not ( public._taam_uid_is_super()
           or ( auth.uid() is null
                and ( session_user = 'postgres'
                      or coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role' = 'service_role' ) ) ) then
    raise exception '권한이 없습니다 (슈퍼어드민 전용)' using errcode = '42501';
  end if;
  return query
  with tk as (
    select tp.id::text as tid, tp.rest_id::text as rid,
           public.taam_date_or_null(tp.date) as tdate
    from public.ticket_products tp
    where tp.id::text = p_ticket_id
  ),
  tgt as (
    select distinct on (k.user_id)
           k.user_id,
           k.reservation_date::date as prev_visit,
           abs(k.reservation_date::date - tk.tdate) as gap
    from public.tickets k
    join tk on k.restaurant_id::text = tk.rid
    join public.restaurants r on r.id::text = tk.rid
    where k.user_id is not null
      and k.reservation_date is not null
      and tk.tdate is not null
      and coalesce(k.status,'') not in ('cancelled','canceled')
      and k.purchase_id not like 'MAN-%'
      and k.purchase_id not like 'INVH-%'
      and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
      and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
      and coalesce(r.repurchase_day, 0) > 0
      and abs(k.reservation_date::date - tk.tdate) > 0
      and abs(k.reservation_date::date - tk.tdate) < r.repurchase_day
      -- 이미 이 티켓을 산 사람은 뺀다
      and not exists (
        select 1 from public.tickets b
         where b.user_id = k.user_id
           and b.ticket_product_id::text = tk.tid
           and coalesce(b.status,'') not in ('cancelled','canceled')
      )
    order by k.user_id, abs(k.reservation_date::date - tk.tdate)
  )
  select t.user_id,
         coalesce(p.display_name, '(이름 없음)'),
         t.prev_visit,
         t.gap
  from tgt t
  left join public.profiles p on p.id = t.user_id;
end;
$$;

revoke all     on function public.taam_repurchase_release_targets(text) from public;
revoke execute on function public.taam_repurchase_release_targets(text) from anon;
grant  execute on function public.taam_repurchase_release_targets(text) to authenticated;

comment on function public.taam_repurchase_release_targets(text) is
  '재구매 제한에 걸려 있던 회원(이 매장 재구매 창 안 방문·예정 · 이 회차 미보유) — 슈퍼어드민 전용(2026-10-16). 앱의 재구매 해제 푸시가 쓴다.';

-- ═══════════════════════════════════════════════════════════════
-- 확인 (하나로) — ❌ 가 한 줄도 없어야 정상
-- ═══════════════════════════════════════════════════════════════
select '① 함수 (plpgsql · 호출자 검사)' as 항목,
       case when (select prosrc from pg_proc where oid = to_regprocedure('public.taam_repurchase_release_targets(text)')) like '%슈퍼어드민 전용%' then '✅' else '❌' end as 결과
union all
select '② anon 실행 권한 없음',
       case when not has_function_privilege('anon', 'public.taam_repurchase_release_targets(text)', 'execute') then '✅' else '❌' end
union all
select '③ authenticated 실행 권한(안에서 슈퍼어드민만 통과)',
       case when has_function_privilege('authenticated', 'public.taam_repurchase_release_targets(text)', 'execute') then '✅' else '❌' end;
