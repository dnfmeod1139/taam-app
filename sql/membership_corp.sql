-- ═══════════════════════════════════════════════════════════════
-- TAAM 멤버십 — 법인 문의 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 법인은 **셀프 결제 플로우가 없다.** 문의 접수까지만 받고 상담으로 잇는다.
--   연회비가 미정이고, 계약·세금계산서·환불 규정이 개인과 다르다.
--   화면에서 금액을 정하게 두면 상담 전에 숫자가 굳는다.
--
-- ⚠ 문의에는 회사명·담당자·연락처가 들어간다. 신청서와 같은 급이다 —
--   표는 잠그고 RPC 로만 넣고 읽는다.
--
-- 실행: Supabase SQL Editor. ⚠ membership_settings.sql 다음.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.corporate_inquiries (
  id         uuid primary key default gen_random_uuid(),
  company    text not null,
  contact    text not null,
  phone      text not null,
  email      text,
  memo       text,
  lang       text not null default 'ko',
  status     text not null default 'new',   -- new|talking|closed
  admin_memo text,
  created_at timestamptz not null default now()
);
create index if not exists idx_corp_inq_status on public.corporate_inquiries (status, created_at desc);

alter table public.corporate_inquiries enable row level security;
revoke all on public.corporate_inquiries from anon, authenticated;

comment on table public.corporate_inquiries is
  '법인 도입 문의. 셀프 결제 없음 — 상담으로 잇는다. 표는 잠그고 RPC 로만.';

create or replace function public.taam_corp_inquire(
  p_company text, p_contact text, p_phone text,
  p_email text default null, p_memo text default null, p_lang text default 'ko'
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_phone text; r public.corporate_inquiries%rowtype;
begin
  v_phone := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  if coalesce(btrim(p_company),'') = '' then
    raise exception '회사명을 적어 주세요' using errcode = '22023';
  end if;
  if coalesce(btrim(p_contact),'') = '' then
    raise exception '담당자를 적어 주세요' using errcode = '22023';
  end if;
  if v_phone is null or length(v_phone) < 8 then
    raise exception '연락처를 확인해 주세요' using errcode = '22023';
  end if;

  -- 같은 회사·번호로 상담 중이면 새로 만들지 않는다
  select * into r from public.corporate_inquiries
   where phone = v_phone and status in ('new','talking')
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'already', true, 'id', r.id);
  end if;

  insert into public.corporate_inquiries (company, contact, phone, email, memo, lang)
  values (btrim(p_company), btrim(p_contact), v_phone,
          nullif(btrim(coalesce(p_email,'')), ''), nullif(btrim(coalesce(p_memo,'')), ''),
          lower(coalesce(nullif(btrim(p_lang),''), 'ko')))
  returning * into r;
  return jsonb_build_object('ok', true, 'already', false, 'id', r.id);
end;
$$;
revoke all on function public.taam_corp_inquire(text,text,text,text,text,text) from public;
grant execute on function public.taam_corp_inquire(text,text,text,text,text,text) to anon, authenticated;

create or replace function public.taam_corp_list(p_limit int default 200)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_out jsonb;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_out
    from (select * from public.corporate_inquiries
           order by created_at desc
           limit greatest(1, least(coalesce(p_limit,200), 500))) x;
  return v_out;
end;
$$;
revoke all on function public.taam_corp_list(int) from public;
grant execute on function public.taam_corp_list(int) to authenticated;

create or replace function public.taam_corp_status(p_id uuid, p_status text, p_memo text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare r public.corporate_inquiries%rowtype; v text;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  v := lower(btrim(coalesce(p_status,'')));
  if v not in ('new','talking','closed') then
    raise exception '상태(%)를 알 수 없습니다', p_status using errcode = '22023';
  end if;
  update public.corporate_inquiries
     set status = v, admin_memo = coalesce(nullif(btrim(p_memo),''), admin_memo)
   where id = p_id returning * into r;
  if not found then raise exception '문의를 찾을 수 없습니다' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'status', r.status);
end;
$$;
revoke all on function public.taam_corp_status(uuid, text, text) from public;
grant execute on function public.taam_corp_status(uuid, text, text) to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 법인 문의 표' as "구분",
       case when to_regclass('public.corporate_inquiries') is not null then '✅' else '❌' end as "상태", '' as "메모"
union all
select '② 표가 통째로 잠겼나 ⭐',
       case when not has_table_privilege('anon','public.corporate_inquiries','select')
             and not has_table_privilege('authenticated','public.corporate_inquiries','select')
            then '✅ RPC 로만' else '❌ 열려 있다' end, ''
union all
select '③ 비회원도 문의할 수 있나',
       case when has_function_privilege('anon',
              'public.taam_corp_inquire(text,text,text,text,text,text)','execute')
            then '✅' else '❌' end, ''
union all
select '④ 함수 3개',
       case when count(*) = 3 then '✅' else '❌ ' || count(*)::text || '/3' end,
       coalesce(string_agg(proname, ' · ' order by proname), '—')
  from pg_proc
 where pronamespace='public'::regnamespace
   and proname in ('taam_corp_inquire','taam_corp_list','taam_corp_status')
union all
select '⑤ 법인 슬롯 설정',
       coalesce((select v#>>'{}' from public.membership_settings where k='corp_slots'), '❌') || '사',
       '예치금 비율 ' || coalesce((select v#>>'{}' from public.membership_settings where k='corp_deposit_ratio'), '?') || '%'
 order by 1;
