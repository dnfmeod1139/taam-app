-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 취소됐는데 환불 기록이 없는(또는 대행비보다 많이 남은) 앱 구매 7건 (2026-10-21)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 20261021_diag_sales_recon.sql 결과 — 원장 티켓 줄은 전부 판매에 붙었다(구매 152줄 · 환불 68줄 · 남는 것은 9/10 사고의
--     결제·되돌림 한 쌍뿐). 그런데 취소된 앱 구매 중 4건(₩3,001,000)은 환불 줄이 아예 없고 3건(₩306,000)은 대행비보다 많이 남았다.
--     D-30 이후 취소라 규정상 0 인지, 「예치금 부여」 같은 다른 길로 돌려줬는지 금액·날짜만으로 가린다.
-- 무엇: SELECT 만. 이름·번호·uid·구매 id·메모 원문을 찍지 않는다(금액·날짜·예/아니오만). 결과는 Actions 로그.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_recon2()
returns table(sec text, info text)
language plpgsql as $$
declare j jsonb; r record; n int := 0;
begin
  j := public.taam_ticket_sales_report(null, null, 'paid', true);
  for r in
    select x->>'k' as k, x->>'uid' as uid, x->>'pm' as pm,
           coalesce((x->>'gross')::numeric,0) g, coalesce((x->>'net')::numeric,0) net, coalesce((x->>'ag_gross')::numeric,0) ag,
           coalesce((x->>'rf_cancel')::numeric,0) + coalesce((x->>'rf_penalty')::numeric,0) + coalesce((x->>'rf_pax')::numeric,0) rf,
           coalesce((x->>'rf_card_pending')::numeric,0) cp, coalesce((x->>'card')::numeric,0) card,
           (x->>'paid_at')::timestamptz paid_at, x->>'visit' visit, coalesce((x->>'test')::boolean, false) test
      from jsonb_array_elements(j->'rows') x
     where x->>'ch' = 'app' and x->>'st' = 'cancelled'
       and coalesce((x->>'net')::numeric,0) > 0
       and (coalesce((x->>'rf_cancel')::numeric,0) + coalesce((x->>'rf_penalty')::numeric,0) + coalesce((x->>'rf_pax')::numeric,0) = 0
            or coalesce((x->>'net')::numeric,0) > coalesce((x->>'ag_gross')::numeric,0))
     order by 4 desc
  loop
    n := n + 1;
    declare tk record; g record; ed jsonb; begin
      select t.status, nullif(to_jsonb(t)->>'cancelled_at','')::timestamptz as cancelled_at, t.created_at, t.price, coalesce(t.extra_data,'{}'::jsonb) ex into tk
        from public.tickets t where t.purchase_id = r.k order by t.created_at desc limit 1;
      ed := coalesce(tk.ex, '{}'::jsonb);
      sec := 'S' || n || (case when r.test then ' (테스트 계정)' else '' end);
      info := '판매 ₩' || to_char(r.g,'FM999,999,999') || ' · 남은 순 ₩' || to_char(r.net,'FM999,999,999') || ' · 대행비 몫 ₩' || to_char(r.ag,'FM999,999,999')
           || ' · 환불 ₩' || to_char(r.rf,'FM999,999,999') || ' · 카드 ₩' || to_char(r.card,'FM999,999,999') || ' · 카드 환불 대기 ₩' || to_char(r.cp,'FM999,999,999')
           || ' · 결제 ' || coalesce(to_char(r.paid_at at time zone 'Asia/Seoul','YYYY-MM-DD'),'?') || ' · 방문 ' || coalesce(r.visit,'?')
           || ' · 취소 ' || coalesce(to_char(tk.cancelled_at at time zone 'Asia/Seoul','YYYY-MM-DD'),'(기록 없음)')
           || ' · 티켓 price ₩' || coalesce(to_char(tk.price,'FM999,999,999'),'?')
           || ' · 키[' || coalesce((select string_agg(k, ',' order by k) from jsonb_object_keys(ed) k
                                      where k ~* '(cancel|refund|return|deposit|card|paid|penalty|agency|invite|manual|kashi|link)'), '') || ']';
      return next;
      -- 같은 회원의 결제 뒤 120일 안 원장 줄(티켓 줄 제외) — 유형 · 금액 · 날짜 · 설명에 환불/취소/반환 낱말이 있나
      for g in
        select d.change_type ct, d.amount amt, to_char(d.created_at at time zone 'Asia/Seoul','YYYY-MM-DD') dt,
               coalesce(to_jsonb(d)->>'description','') ~ '(환불|취소|반환|refund|cancel)' as kw,
               coalesce(d.metadata::text,'') ~ '(환불|취소|반환|refund|cancel|purchase_id)' as mkw
          from public.deposit_transactions d
         where d.user_id::text = r.uid and d.change_type not in ('ticket_purchase','ticket_refund','ticket_pax_change')
           and d.created_at >= r.paid_at and d.created_at < r.paid_at + interval '120 days'
         order by d.created_at limit 8
      loop
        sec := '  └ S' || n || ' 원장'; info := g.ct || ' ₩' || to_char(g.amt,'FM999,999,999') || ' · ' || g.dt || case when g.kw or g.mkw then ' · 환불·취소 낱말 있음' else '' end;
        return next;
      end loop;
    end;
  end loop;
  if n = 0 then sec := 'S'; info := '해당 없음'; return next; end if;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_recon2();
