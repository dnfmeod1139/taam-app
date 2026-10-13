-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 재구매 제한 「이 회차만」 수동 해제 — 슈퍼어드민 권한 · 2026-10-13
--
-- 매장 등록의 재구매 제한(일수)은 그대로 두고, 자리가 남아 있는 회차에 한해 슈퍼어드민이 언제든
-- 그 회차의 재구매 제한을 풀거나 되돌린다. 자동 해제(7일)는 2026-10-13 에 폐지했으므로 이것이 유일한 해제 길이다.
--   · ticket_products.repurchase_open  — 이 회차에 한해 제한 해제 (기본 false)
--   · taam_repurchase_released(ticket) — 가드가 부르는 판정. 이제 이 플래그를 돌려준다
--   · taam_ticket_repurchase_open(ticket, open) — 슈퍼어드민만. 앱 티켓 리스트의 「재구매 해제」 버튼
-- ⚠ 파일 이름을 20261014 로 둔 이유: 20261013_repurchase_no_release.sql(언제나 false) **뒤에** 돌아야 한다.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.ticket_products add column if not exists repurchase_open    boolean not null default false;
alter table public.ticket_products add column if not exists repurchase_open_at timestamptz;

create or replace function public.taam_repurchase_released(p_ticket_id text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select tp.repurchase_open from public.ticket_products tp where tp.id::text = p_ticket_id), false)
$$;
comment on function public.taam_repurchase_released(text) is
  '이 회차의 재구매 제한이 풀렸는가 — 슈퍼어드민이 ticket_products.repurchase_open 을 켠 회차만 true (2026-10-13 수동 해제).';

create or replace function public.taam_ticket_repurchase_open(p_ticket_id text, p_open boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_row public.ticket_products%rowtype;
begin
  if not public._taam_uid_is_super() then
    raise exception '슈퍼어드민만 재구매 제한을 풀 수 있습니다' using errcode = '42501';
  end if;
  update public.ticket_products
     set repurchase_open    = coalesce(p_open, false),
         repurchase_open_at = case when coalesce(p_open, false) then now() else null end
   where id::text = p_ticket_id
   returning * into v_row;
  if not found then raise exception '티켓을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'ticket_id', v_row.id, 'open', v_row.repurchase_open, 'at', v_row.repurchase_open_at);
end $$;
revoke all on function public.taam_ticket_repurchase_open(text, boolean) from public;
grant execute on function public.taam_ticket_repurchase_open(text, boolean) to authenticated;

-- ── 확인 (한 표) — ❌ 가 없어야 정상 ──
select '① 컬럼 repurchase_open' as what,
       case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='ticket_products' and column_name='repurchase_open') then '✅' else '❌' end as result
union all
select '② 없는 회차는 false', case when public.taam_repurchase_released('nope') = false then '✅' else '❌' end
union all
select '③ 해제 RPC', case when to_regproc('public.taam_ticket_repurchase_open') is not null then '✅' else '❌' end
union all
select '④ 지금 해제된 회차 수', '✅ ' || (select count(*) from public.ticket_products where repurchase_open)::text || '건';
