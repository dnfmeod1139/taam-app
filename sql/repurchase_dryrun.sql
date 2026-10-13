-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 재구매 제한 라이브 드라이런 (2026-10-13)
--   「각 매장의 재구매 제한이 실제로 걸리는가」를 라이브 DB 에서 **실제 회원·실제 설정**으로 확인한다.
--   매장마다 살아 있는 예약을 하나 골라, 그 회원 이름으로 기존 방문일 +1~3일 의 가짜 홀드(PAYH-DRYRUN-…)를
--   회원 세션(authenticated · auth.uid() = 그 회원)으로 넣어 본다. 트리거가 막으면 REPURCHASE_BLOCKED 가 돌아오고,
--   막지 않았으면 함수가 스스로 예외를 올려 **그 자리에서 되돌린다** — 어떤 경우에도 행이 남지 않는다.
--   실행: Supabase SQL Editor 에 통째로. 결과 표의 「결과」 열이 ✅ 막힘 이면 그 매장의 제한이 살아 있는 것이다.
--   ❌ 통과 가 한 줄이라도 있으면 그 매장은 제한이 안 걸리는 것 — 메시지와 함께 보고한다.
--   ⚠ 면제(어드민·심사 계정)·예약 없는 매장은 검증할 수 없어 그렇게 적는다.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._taam_repurchase_dryrun()
returns table("매장" text, "제한(일)" int, "회원" text, "기존 방문" text, "시도 방문" text, "결과" text, "메시지" text)
language plpgsql
as $fn$
declare
  c      record;
  v_msg  text;
  v_try  date;
  v_i    int;
  v_res  text;
  v_cnt0 int;
begin
  create temp table _dr_cand on commit drop as
  select r.id::text as rid, r.name as rname, r.repurchase_day as days,
         k.user_id, coalesce(k.display_name, '(이름없음)') as member, k.role, k.exempt,
         k.reservation_date as prev_raw, public.taam_visit_date(k.reservation_date) as prev_date
    from public.restaurants r
    left join lateral (
      select k.user_id, k.reservation_date, k.created_at, p.display_name, p.role,
             coalesce(p.single_device_exempt, false) as exempt
        from public.tickets k
        left join public.profiles p on p.id = k.user_id
       where k.restaurant_id::text = r.id::text
         and k.user_id is not null
         and coalesce(k.status, '') not in ('cancelled','canceled','expired','hold')
         and coalesce(k.purchase_id, '') !~ '^(MAN|INVH|KSK|LINK)-'
         and coalesce(k.extra_data ->> 'manualEntry', '') not in ('true','1')
         and coalesce(k.extra_data ->> 'inviteHold',  '') not in ('true','1')
         and public.taam_visit_date(k.reservation_date) is not null
       order by (coalesce(p.role,'') in ('admin','superadmin','super_admin') or coalesce(p.single_device_exempt,false)) asc,
                k.created_at desc
       limit 1) k on true
   where coalesce(r.repurchase_day, 0) > 0
   order by r.name;

  for c in select * from _dr_cand loop
    "매장" := c.rname; "제한(일)" := c.days; "회원" := c.member;
    "기존 방문" := coalesce(c.prev_raw, '');
    if c.user_id is null then
      "시도 방문" := ''; "결과" := '— 예약 없음'; "메시지" := '살아 있는 예약이 없어 검증 불가 (허용만 가능한 상태)';
      return next; continue;
    end if;
    if coalesce(c.role,'') in ('admin','superadmin','super_admin') or c.exempt then
      "시도 방문" := ''; "결과" := '— 면제 계정'; "메시지" := '어드민·심사 계정은 가드가 면제라 검증 불가';
      return next; continue;
    end if;

    v_res := null;
    for v_i in 1..3 loop
      v_try := c.prev_date + v_i;
      execute 'set local role authenticated';
      perform set_config('request.jwt.claims', json_build_object('sub', c.user_id::text, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', c.user_id::text, true);
      begin
        insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, reservation_date, visit_time,
                                   party_size, price, status, purchase_id, extra_data)
        values (c.user_id, c.rid, c.rname, 'DRYRUN-' || c.rid, to_char(v_try, 'YYYY.MM.DD'), '11:30',
                2, 0, 'hold', 'PAYH-DRYRUN-' || left(c.rid, 8) || '-' || v_i, '{"seatHold":true,"dryrun":true}'::jsonb);
        raise exception 'DRYRUN_NOT_BLOCKED';
      exception when others then
        v_msg := sqlerrm;
      end;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      perform set_config('request.jwt.claim.sub', '', true);

      if v_msg like '%REPURCHASE_BLOCKED%' then v_res := '✅ 막힘';
      elsif v_msg like '%DRYRUN_NOT_BLOCKED%' then v_res := '❌ 통과 (제한이 안 걸림)';
      elsif v_msg like '%TIME_CONFLICT%' or v_msg like '%DUPLICATE_PURCHASE%' then v_res := null;   -- 다른 가드가 먼저 — 다음 날짜로
      elsif v_msg like '%TIER_BLOCKED%' then v_res := '⚠ 등급 가드가 먼저 막음';
      elsif v_msg ilike '%row-level security%' or v_msg ilike '%permission denied%' then v_res := '⚠ 권한/RLS 가 먼저 막음';
      else v_res := '⚠ 다른 오류';
      end if;
      exit when v_res is not null;
    end loop;
    if v_res is null then v_res := '⚠ 같은 시간대/중복 가드가 매번 먼저 막음'; end if;
    "시도 방문" := to_char(v_try, 'YYYY.MM.DD') || ' 11:30';
    "결과" := v_res; "메시지" := left(v_msg, 160);
    return next;
  end loop;

  select count(*) into v_cnt0 from public.restaurants where coalesce(repurchase_day, 0) = 0;
  "매장" := '(제한 없음 매장)'; "제한(일)" := 0; "회원" := ''; "기존 방문" := ''; "시도 방문" := '';
  "결과" := '— 규칙 없음'; "메시지" := v_cnt0::text || '개 매장은 repurchase_day 가 0/비어 있어 같은 매장 재구매에 제한이 없다';
  return next;
end $fn$;
revoke all on function public._taam_repurchase_dryrun() from public, anon, authenticated;

select * from public._taam_repurchase_dryrun();
