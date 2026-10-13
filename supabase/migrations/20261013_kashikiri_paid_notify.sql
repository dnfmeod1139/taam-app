-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 정산·링크 초대 결제가 완료되면 슈퍼어드민에게 알린다 (인앱 + 푸시) · 2026-10-13
--
-- 왜 — 정산 링크(/pay/?t=)로 들어오는 결제(연회비 포함)는 토스가 승인해도 앱에는 아무 소식이 없었다.
--   kashikiri_charges.status 가 paid 로 바뀌는 순간이 유일한 길목이라 거기에 건다. Edge(kashikiri-confirm)·
--   어드민 수동 처리 어느 경로든 같다. 슈퍼어드민에게만 간다.
-- 어떻게
--   AFTER UPDATE OF status → ① notifications 에 슈퍼어드민마다 한 줄(type kashikiri_paid)
--                            ② send-push 에 role:superadmin 으로 한 번 (pg_net · Vault 시크릿 이름은 app_config.restock_push 와 같다)
--   ⚠ 결제 확정을 알림이 막으면 안 된다 — 예외는 전부 warning 으로 삼킨다. pg_net·설정이 없으면 푸시만 건너뛴다.
-- ═══════════════════════════════════════════════════════════════════════════

-- 슈퍼어드민 푸시 한 번 — restock_push 설정의 Vault 시크릿·URL 을 재사용한다 (URL 의 함수 이름만 send-push 로)
create or replace function public.taam_admin_push(p_title text, p_body text, p_url text default '/', p_tag text default null, p_category text default 'admin')
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  if to_regclass('public.app_config') is null then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name,'') = '' or coalesce(v_url,'') = '' then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  v_url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/send-push');
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    return jsonb_build_object('ok', false, 'reason', 'no_pg_net');
  end if;
  begin
    select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  exception when others then v_jwt := null; end;
  if coalesce(v_jwt,'') = '' then return jsonb_build_object('ok', false, 'reason', 'no_secret'); end if;
  select net.http_post(
           url     := v_url,
           headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt),
           body    := jsonb_build_object('to', 'role:superadmin',
                        'payload', jsonb_build_object('title', p_title, 'body', p_body, 'url', coalesce(p_url, '/'),
                                                      'category', coalesce(p_category, 'admin'), 'tag', coalesce(p_tag, 'admin-' || extract(epoch from now())::bigint))))
    into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req);
end $$;
revoke all on function public.taam_admin_push(text, text, text, text, text) from public;

-- 금액 표기 — 승인 통화 그대로 (USD 센트 · JPY 정수 · 그 밖은 원화)
create or replace function public._taam_ksk_money(p_cur text, p_pay numeric, p_krw integer)
returns text language sql immutable as $$
  select case
    when upper(coalesce(p_cur,'KRW')) = 'USD' and p_pay is not null then '$' || to_char(p_pay, 'FM999,999,990.00')
    when upper(coalesce(p_cur,'KRW')) = 'JPY' and p_pay is not null then '¥' || to_char(round(p_pay), 'FM999,999,990')
    else '₩' || to_char(coalesce(p_krw, 0), 'FM999,999,990')
  end
$$;

create or replace function public.taam_kashikiri_paid_notify()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_ev record; v_title text; v_body text; v_url text; v_n int := 0; v_who text; v_amt text; v_tag text;
begin
  if coalesce(new.status,'') <> 'paid' or coalesce(old.status,'') = 'paid' then return new; end if;
  begin
    select e.venue_name, e.event_date, e.event_time into v_ev from public.kashikiri_events e where e.id = new.event_id;
    v_who := coalesce(nullif(btrim(new.payer_name), ''), nullif(btrim(new.label), ''), '결제자');
    v_amt := public._taam_ksk_money(new.pay_currency, new.pay_amount, new.amount_krw);
    v_title := case when coalesce(new.link_invite, false) then '🔗 링크 초대 결제 완료' else '💳 정산 결제 완료' end;
    v_body  := coalesce(v_ev.venue_name, '회차') || ' ' || coalesce(to_char(v_ev.event_date, 'YYYY.MM.DD'), '')
            || coalesce(' ' || to_char(v_ev.event_time, 'HH24:MI'), '')
            || ' · ' || v_who || ' · ' || v_amt
            || case when upper(coalesce(new.pay_currency,'KRW')) <> 'KRW' then ' (₩' || to_char(coalesce(new.amount_krw,0), 'FM999,999,990') || ')' else '' end;
    v_url := '/';
    v_tag := 'ksk-paid-' || new.id::text;
    insert into public.notifications (user_id, type, title, body, url, payload)
    select p.id, 'kashikiri_paid', v_title, left(v_body, 1000), v_url,
           jsonb_build_object('charge_id', new.id, 'event_id', new.event_id, 'team_id', new.team_id,
                              'amount_krw', new.amount_krw, 'pay_currency', new.pay_currency, 'pay_amount', new.pay_amount,
                              'link_invite', coalesce(new.link_invite, false), 'via', 'trg_taam_kashikiri_paid_notify')
      from public.profiles p
     where p.role in ('superadmin', 'super_admin');
    get diagnostics v_n = row_count;
    if v_n > 0 then
      begin perform public.taam_admin_push(v_title, v_body, v_url, v_tag, 'admin');
      exception when others then raise warning '[ksk paid notify] push 실패: %', sqlerrm; end;
    end if;
  exception when others then
    raise warning '[ksk paid notify] 알림 실패(결제 확정은 그대로): %', sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists trg_taam_kashikiri_paid_notify on public.kashikiri_charges;
create trigger trg_taam_kashikiri_paid_notify
  after update of status on public.kashikiri_charges
  for each row execute function public.taam_kashikiri_paid_notify();

-- 푸시 설정이 갖춰졌는가 — app_config 가 없는 환경(로컬 픽스처)에서도 파싱이 깨지지 않게 동적 SQL 로 본다
create or replace function public._taam_admin_push_ready()
returns boolean language plpgsql stable as $$
declare v_ok boolean := false;
begin
  if to_regclass('public.app_config') is null then return false; end if;
  execute $q$select exists (select 1 from public.app_config where key = 'restock_push'
                              and coalesce(value->>'vault_secret','') <> '' and coalesce(value->>'url','') <> '')$q$ into v_ok;
  return coalesce(v_ok, false);
end $$;

-- ── 확인 (한 표) — ❌ 가 없어야 정상 ──
select '① 결제 완료 알림 트리거' as what,
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_kashikiri_paid_notify') then '✅' else '❌' end as result
union all
select '② 슈퍼어드민 푸시 함수', case when to_regproc('public.taam_admin_push') is not null then '✅' else '❌' end
union all
select '③ 푸시 설정(app_config.restock_push — Vault 이름·URL)',
       case when public._taam_admin_push_ready() then '✅' else '⚠ 없음 — 인앱 알림만 가고 푸시는 건너뜀' end
union all
select '④ 받을 슈퍼어드민 수', '✅ ' || (select count(*) from public.profiles where role in ('superadmin','super_admin'))::text || '명';
