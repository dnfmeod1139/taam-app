-- ═══════════════════════════════════════════════════════════════
-- TAAM 멤버십 — 심사 신청 받기 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 무엇
--   정원 33인 단일 등급(1,125만). 아무나 사서 들어오는 게 아니라
--   **신청 → 개별 심사 → 오퍼 → 결제** 순서로 들어온다.
--   이 파일은 그 첫 칸, 「신청을 받아 쌓는 곳」이다.
--
--   applied → screening → offered → paid / declined / expired
--   (offered 부터는 다음 파일에서. 여기서는 applied·screening·declined 까지)
--
-- 왜 답변을 jsonb 로 두나
--   질문이 바뀐다. 「연간 일본 방문 횟수」를 지우고 다른 걸 물을 수도 있는데,
--   그때마다 컬럼을 늘리면 옛 신청서를 읽을 수 없게 된다. 질문지 자체를
--   같이 저장해 두면 **그때 무엇을 물었는지**가 신청서에 남는다.
--
-- ⚠ 가격은 이 표에 없다. 심사 신청 화면은 가격을 보여주지 않는다 —
--   가격이 처음 공개되는 곳은 오퍼 페이지다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   읽는 법: 맨 아래가 전부 ✅ 여야 정상.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 신청서 ──────────────────────────────────────────────────
create table if not exists public.membership_applications (
  id           uuid primary key default gen_random_uuid(),
  -- 앱에서 낸 신청이면 회원 id 가 붙는다. 공개 페이지에서 낸 것은 null.
  user_id      uuid references auth.users(id) on delete set null,
  name         text,
  phone        text not null,
  -- 그때 물었던 질문과 답을 통째로. 질문이 바뀌어도 옛 신청서가 읽힌다.
  answers      jsonb not null default '{}'::jsonb,
  referral_code text,
  lang         text not null default 'ko',
  source       text not null default 'app',       -- app | web | kashikiri | dm
  status       text not null default 'applied',   -- applied|screening|declined
  admin_memo   text,
  decided_at   timestamptz,
  decided_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);

create index if not exists idx_mship_app_status  on public.membership_applications (status, created_at desc);
create index if not exists idx_mship_app_phone   on public.membership_applications (phone);

alter table public.membership_applications enable row level security;

-- 회원은 **자기 신청만** 본다. 남의 신청서에는 연락처와 답변이 들어 있다.
drop policy if exists mship_app_self_read on public.membership_applications;
create policy mship_app_self_read on public.membership_applications
  for select to authenticated
  using (user_id = auth.uid() or is_super_admin(auth.uid()));

-- ⚠ INSERT·UPDATE 정책은 일부러 만들지 않는다.
--   넣는 것도 고치는 것도 아래 RPC 로만 한다 — 그래야 상태값과
--   중복 검사를 한 곳에서 지킬 수 있다.

-- 권한을 기본값에 기대지 않는다.
--   Supabase 는 public 의 새 표에 anon·authenticated 까지 전부 열어 두는
--   default privileges 가 걸려 있다. RLS 가 막아 주긴 하지만, 「정책이
--   하나 잘못 들어가면 그 순간 열리는」 상태로 두지 않는다.
revoke all on public.membership_applications from anon, authenticated;
grant select on public.membership_applications to authenticated;   -- RLS 가 자기 것만 남긴다

comment on table public.membership_applications is
  'TAAM 멤버십 심사 신청. 넣기·고치기는 RPC 로만. 가격 정보는 여기 없다(오퍼 단계).';


-- ── ② 신청하기 — 회원도 비회원도 ──────────────────────────────
--   같은 번호로 이미 심사 중인 신청이 있으면 새로 만들지 않고 그것을
--   돌려준다. 두 번 눌렀다고 큐에 두 장이 쌓이면 심사하는 사람이
--   같은 사람을 두 번 본다.
create or replace function public.taam_mship_apply(
  p_name     text,
  p_phone    text,
  p_answers  jsonb,
  p_lang     text default 'ko',
  p_referral text default null,
  p_source   text default 'app'
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_phone text;
  v_uid   uuid := auth.uid();
  v_row   public.membership_applications%rowtype;
begin
  v_phone := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  if v_phone is null or length(v_phone) < 8 then
    raise exception '연락처를 확인해 주세요' using errcode = '22023';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception '이름을 적어 주세요' using errcode = '22023';
  end if;

  -- 이미 심사 중이면 그대로 돌려준다 (두 번 눌러도 한 장)
  select * into v_row
    from public.membership_applications
   where phone = v_phone and status in ('applied','screening')
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'already', true, 'id', v_row.id,
                              'status', v_row.status, 'created_at', v_row.created_at);
  end if;

  insert into public.membership_applications
    (user_id, name, phone, answers, referral_code, lang, source)
  values
    (v_uid, btrim(p_name), v_phone,
     coalesce(p_answers, '{}'::jsonb),
     nullif(btrim(upper(coalesce(p_referral,''))), ''),
     lower(coalesce(nullif(btrim(p_lang),''), 'ko')),
     lower(coalesce(nullif(btrim(p_source),''), 'app')))
  returning * into v_row;

  return jsonb_build_object('ok', true, 'already', false, 'id', v_row.id,
                            'status', v_row.status, 'created_at', v_row.created_at);
end;
$$;

-- 공개 페이지(로그인 없이)에서도 신청할 수 있어야 한다.
-- ⚠ anon 에게 여는 건 이 함수 하나뿐이다. 표는 여전히 RLS 로 잠겨 있어
--   신청은 넣을 수 있어도 **남의 신청서를 읽을 수는 없다.**
revoke all on function public.taam_mship_apply(text, text, jsonb, text, text, text) from public;
grant execute on function public.taam_mship_apply(text, text, jsonb, text, text, text)
  to anon, authenticated;


-- ── ③ 내 신청 상태 ────────────────────────────────────────────
--   앱에서 「심사 신청함」을 보여주기 위한 것. 남의 것은 안 나온다.
create or replace function public.taam_mship_my_application()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when a.id is null then null else jsonb_build_object(
           'id', a.id, 'status', a.status, 'created_at', a.created_at,
           'decided_at', a.decided_at) end
    from (select * from public.membership_applications
           where user_id = auth.uid()
           order by created_at desc limit 1) a
$$;

revoke all on function public.taam_mship_my_application() from public;
grant execute on function public.taam_mship_my_application() to authenticated;


-- ── ④ 어드민 — 심사 큐 ────────────────────────────────────────
create or replace function public.taam_mship_apply_list(
  p_status text default null,
  p_limit  int  default 100
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
    into v
    from (select a.id, a.user_id, a.name, a.phone, a.answers, a.referral_code,
                 a.lang, a.source, a.status, a.admin_memo, a.created_at, a.decided_at,
                 p.membership_tier
            from public.membership_applications a
            left join public.profiles p on p.id = a.user_id
           where p_status is null or a.status = p_status
           order by a.created_at desc
           limit greatest(1, least(coalesce(p_limit,100), 500))) x;
  return v;
end;
$$;

revoke all on function public.taam_mship_apply_list(text, int) from public;
grant execute on function public.taam_mship_apply_list(text, int) to authenticated;


-- ── ⑤ 어드민 — 상태 바꾸기 ────────────────────────────────────
--   여기서는 applied ↔ screening ↔ declined 까지만 다룬다.
--   offered 는 오퍼 링크를 만들 때 그쪽에서 세운다 — 상태만 바꾸고
--   링크가 없으면 「통과시켰는데 보낼 게 없는」 상태가 된다.
create or replace function public.taam_mship_apply_status(
  p_id     uuid,
  p_status text,
  p_memo   text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_row public.membership_applications%rowtype; v_st text;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  v_st := lower(btrim(coalesce(p_status,'')));
  if v_st not in ('applied','screening','declined') then
    raise exception '상태(%)를 알 수 없습니다', p_status using errcode = '22023';
  end if;

  update public.membership_applications
     set status     = v_st,
         admin_memo = coalesce(nullif(btrim(p_memo),''), admin_memo),
         decided_at = case when v_st = 'declined' then now() else null end,
         decided_by = case when v_st = 'declined' then auth.uid() else null end
   where id = p_id
   returning * into v_row;
  if not found then raise exception '신청을 찾을 수 없습니다' using errcode = 'P0002'; end if;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status);
end;
$$;

revoke all on function public.taam_mship_apply_status(uuid, text, text) from public;
grant execute on function public.taam_mship_apply_status(uuid, text, text) to authenticated;


-- ── ⑥ 정원·잔여석 ─────────────────────────────────────────────
--   오퍼 페이지에 「현재 잔여 n석」을 적는다. 자동 계산이 아니라
--   **어드민이 손으로 정하는 값**이다 — 진행 중인 오퍼·구두 약속까지
--   세어야 하는데 그건 DB가 모른다.
create table if not exists public.membership_seats (
  id          int primary key default 1,
  capacity    int not null default 33,
  taken       int not null default 0,
  corp_slots  int not null default 5,
  updated_at  timestamptz not null default now(),
  constraint membership_seats_one_row check (id = 1),
  constraint membership_seats_sane    check (capacity >= 0 and taken >= 0)
);
insert into public.membership_seats (id) values (1) on conflict (id) do nothing;

alter table public.membership_seats enable row level security;
-- 잔여석은 오퍼 페이지에 적히는 값이라 누구나 읽는다. 쓰기는 RPC 로만.
drop policy if exists mship_seats_read on public.membership_seats;
create policy mship_seats_read on public.membership_seats
  for select to anon, authenticated using (true);

revoke all on public.membership_seats from anon, authenticated;
grant select on public.membership_seats to anon, authenticated;

create or replace function public.taam_mship_seats_set(p_capacity int, p_taken int)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v public.membership_seats%rowtype;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  if coalesce(p_capacity,0) < 0 or coalesce(p_taken,0) < 0 then
    raise exception '음수는 넣을 수 없습니다' using errcode = '22023';
  end if;
  update public.membership_seats
     set capacity = p_capacity, taken = p_taken, updated_at = now()
   where id = 1 returning * into v;
  return jsonb_build_object('ok', true, 'capacity', v.capacity, 'taken', v.taken,
                            'left', greatest(0, v.capacity - v.taken));
end;
$$;

revoke all on function public.taam_mship_seats_set(int, int) from public;
grant execute on function public.taam_mship_seats_set(int, int) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 신청 표' as "구분",
       case when to_regclass('public.membership_applications') is not null then '✅' else '❌' end as "상태",
       '' as "메모"

union all
select '② 신청 표가 잠겨 있나 (RLS)',
       case when relrowsecurity then '✅' else '❌ 열려 있다' end, ''
  from pg_class where oid = 'public.membership_applications'::regclass

union all
select '③ 비회원도 신청할 수 있나',
       case when has_function_privilege('anon',
              'public.taam_mship_apply(text,text,jsonb,text,text,text)', 'execute')
            then '✅' else '❌' end, ''

union all
select '④ 남의 신청서는 못 읽나',
       case when not has_table_privilege('anon', 'public.membership_applications', 'select')
              or not exists (select 1 from pg_policies
                              where tablename='membership_applications' and 'anon' = any(roles))
            then '✅' else '❌ anon 이 읽는다' end, ''

union all
select '⑤ 어드민 함수 3개',
       case when count(*) = 3 then '✅' else '❌ ' || count(*)::text || '/3' end,
       coalesce(string_agg(proname, ' · ' order by proname), '—')
  from pg_proc
 where pronamespace = 'public'::regnamespace
   and proname in ('taam_mship_apply_list','taam_mship_apply_status','taam_mship_seats_set')

union all
select '⑥ 정원',
       case when to_regclass('public.membership_seats') is not null then '✅' else '❌' end,
       coalesce((select capacity::text || '석 중 ' || taken::text || '석 사용'
                   from public.membership_seats where id = 1), '—')

 order by 1;
