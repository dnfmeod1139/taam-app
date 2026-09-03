-- ═══════════════════════════════════════════════════════════════
-- TAAM — 파트너 레스토랑 계정 (2026-09-03)
-- ═══════════════════════════════════════════════════════════════
-- 무엇인가
--   협의 자리에서 바로 건넬 수 있도록 **미리 만들어 두는** 매장용 계정.
--   아이디·비밀번호 한 쌍이고, 로그인하면 지금의 어드민 권한 그대로다.
--   안 쓰면 그만이고, 쓰게 되면 그 자리에서 건네면 된다.
--
-- 권한은 새로 만들지 않는다
--   ⚠ 어드민 권한은 이미 admin_grants 가 준다. 파트너 계정도 **같은 표**를
--     쓴다. 권한 경로를 하나 더 만들면 나중에 「이 사람은 왜 어드민이지」를
--     두 군데서 찾아야 한다.
--   이 표는 「누구에게 어떤 아이디를 발급했나」를 적어 두는 장부일 뿐이다.
--
-- ⚠ 비밀번호는 여기 없다.
--   Supabase Auth 가 가진다. 이 표에는 해시조차 두지 않는다 —
--   두면 언젠가 새어 나간다. 잊어버리면 재발급한다(재설정, 조회 아님).
--
-- 실행: Supabase SQL Editor. admin_grants.sql 다음.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.partner_accounts (
  login_id      text primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  rest_id       text,                        -- restaurants.id
  label         text,                        -- 매장명 (표시용)
  memo          text,                        -- 「누구에게 언제 건넸나」 메모
  issued_at     timestamptz not null default now(),
  issued_by     uuid references auth.users(id),
  handed_at     timestamptz,                 -- 실제로 건넨 시각. null = 아직 안 건넴
  last_login_at timestamptz,                 -- 한 번이라도 썼나
  disabled      boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists idx_pa_user on public.partner_accounts(user_id);
create index if not exists idx_pa_rest on public.partner_accounts(rest_id);

comment on table public.partner_accounts is
  '매장에 미리 발급해 두는 어드민 계정 장부. 권한 자체는 admin_grants 가 준다. 비밀번호는 여기 없다 — Supabase Auth 가 가진다.';

-- ── RLS ────────────────────────────────────────────────────────
--   ⚠ Supabase 는 새 public 테이블을 anon·authenticated 에게 열어 둔다.
--     먼저 전부 회수하고, 필요한 것만 준다.
alter table public.partner_accounts enable row level security;
revoke all on table public.partner_accounts from anon, authenticated;

drop policy if exists pa_super_all on public.partner_accounts;
create policy pa_super_all on public.partner_accounts
  for all using (is_super_admin(auth.uid())) with check (is_super_admin(auth.uid()));

-- 본인 행은 읽을 수 있다 — 로그인한 매장이 「내 아이디가 뭐였지」를 볼 수 있게.
drop policy if exists pa_self_read on public.partner_accounts;
create policy pa_self_read on public.partner_accounts
  for select using (user_id = auth.uid());

grant select on public.partner_accounts to authenticated;


-- ── 목록 (슈퍼어드민) ──────────────────────────────────────────
--   매장명은 restaurants 에서 최신으로 끌어온다 — label 은 발급 시점 값이라
--   매장 이름이 바뀌면 낡는다.
create or replace function public.taam_partner_accounts()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_out jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.issued_at desc), '[]'::jsonb) into v_out
    from (select pa.login_id, pa.rest_id, pa.memo, pa.issued_at, pa.handed_at,
                 pa.last_login_at, pa.disabled,
                 coalesce(r.name, pa.label) as label,
                 -- 권한이 실제로 붙어 있나. 여기가 비면 로그인은 되는데
                 -- 어드민이 아니다 — 가장 헷갈리는 고장이라 같이 준다.
                 exists(select 1 from public.admin_grants g
                         where g.user_id = pa.user_id
                           and g.rest_id is not null) as has_grant
            from public.partner_accounts pa
            left join public.restaurants r on r.id::text = pa.rest_id::text) x;
  return v_out;
end;
$$;
revoke all on function public.taam_partner_accounts() from public;
grant execute on function public.taam_partner_accounts() to authenticated;


-- ── 건넸다고 표시 (슈퍼어드민) ─────────────────────────────────
create or replace function public.taam_partner_mark_handed(p_login_id text, p_on boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  update public.partner_accounts
     set handed_at = case when coalesce(p_on, false) then now() else null end
   where login_id = p_login_id;
  get diagnostics n = row_count;
  if n = 0 then raise exception '그런 아이디가 없습니다' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'handed', coalesce(p_on, false));
end;
$$;
revoke all on function public.taam_partner_mark_handed(text, boolean) from public;
grant execute on function public.taam_partner_mark_handed(text, boolean) to authenticated;


-- ── 메모 (슈퍼어드민) ──────────────────────────────────────────
create or replace function public.taam_partner_memo(p_login_id text, p_memo text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  update public.partner_accounts set memo = nullif(btrim(coalesce(p_memo,'')), '')
   where login_id = p_login_id;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.taam_partner_memo(text, text) from public;
grant execute on function public.taam_partner_memo(text, text) to authenticated;


-- ── 로그인했다고 남긴다 (파트너 본인) ──────────────────────────
--   「만들어만 두고 안 쓰는 계정」을 가려내는 유일한 단서다.
--   ⚠ 본인 행만 건드린다. login_id 를 받지 않는 이유 — 받으면 남의 행을
--     찍을 수 있게 된다. auth.uid() 로만 찾는다.
create or replace function public.taam_partner_touch()
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  update public.partner_accounts
     set last_login_at = now()
   where user_id = auth.uid();
end;
$$;
revoke all on function public.taam_partner_touch() from public;
grant execute on function public.taam_partner_touch() to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 장부 표가 생겼나' as "구분",
       case when to_regclass('public.partner_accounts') is not null then '✅' else '❌' end as "상태",
       '' as "메모"
union all
select '② 아무나 못 읽나 ⭐',
       case when relrowsecurity then '✅ RLS 켜짐' else '❌ 열려 있음' end,
       '슈퍼어드민 + 본인 행만'
  from pg_class where oid = 'public.partner_accounts'::regclass
union all
select '③ 함수 넷',
       case when count(*) = 4 then '✅' else '❌ ' || count(*)::text || '개' end,
       string_agg(proname, ', ' order by proname)
  from pg_proc
 where pronamespace = 'public'::regnamespace
   and proname in ('taam_partner_accounts','taam_partner_mark_handed',
                   'taam_partner_memo','taam_partner_touch')
union all
select '④ 권한 표(admin_grants)가 있나 ⭐',
       case when to_regclass('public.admin_grants') is not null then '✅' else '❌ admin_grants.sql 먼저' end,
       '파트너 계정도 이 표로 어드민이 된다'
union all
select '⑤ 지금 발급된 계정',
       coalesce((select count(*)::text from public.partner_accounts), '0') || '개',
       '아직 안 만들었으면 0'
 order by 1;
