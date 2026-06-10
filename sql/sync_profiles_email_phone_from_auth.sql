-- ═══════════════════════════════════════════════════════════════
-- profiles.email / phone 강제 동기화 (auth.users → profiles)
-- 작성일: 2026-05-22
-- 목적:
--   회원/어드민은 이메일 또는 전화번호로 가입.
--   슈퍼어드민이 구매자 상세 모달에서 연락(지각/소통)할 수 있도록
--   profiles.email 과 profiles.phone 중 최소 하나는 무조건 채워져 있어야 함.
--   auth.users 의 데이터를 profiles 로 강제 sync.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 진단: 연락처가 모두 빈 회원 찾기 ──
select
  p.id,
  p.display_name,
  p.email   as profile_email,
  p.phone   as profile_phone,
  u.email   as auth_email,
  u.phone   as auth_phone,
  u.raw_user_meta_data->>'phone' as meta_phone,
  case
    when (p.email is null or p.email='')
     and (p.phone is null or p.phone='')
    then '❌ 연락처 모두 없음'
    else '✅ OK'
  end as status
from public.profiles p
left join auth.users u on u.id = p.id
order by status desc, p.created_at desc nulls last
limit 50;

-- ── 2. profiles.email 일괄 sync (NULL/빈 값만 보충) ──
update public.profiles p
set email = u.email
from auth.users u
where u.id = p.id
  and u.email is not null
  and u.email != ''
  and (p.email is null or p.email = '');

-- ── 3. profiles.phone 일괄 sync (NULL/빈 값만 보충) ──
update public.profiles p
set phone = coalesce(u.phone, u.raw_user_meta_data->>'phone')
from auth.users u
where u.id = p.id
  and (coalesce(u.phone, u.raw_user_meta_data->>'phone') is not null)
  and (coalesce(u.phone, u.raw_user_meta_data->>'phone') != '')
  and (p.phone is null or p.phone = '');

-- ── 4. auto-sync 트리거 (이미 있으면 교체) ──
--    auth.users insert/update 시 profiles 의 email/phone 자동 동기화
create or replace function public.sync_profile_contact_from_auth()
returns trigger
language plpgsql
security definer
as $$
begin
  update public.profiles
  set
    email = coalesce(nullif(public.profiles.email,''), new.email),
    phone = coalesce(nullif(public.profiles.phone,''), new.phone, new.raw_user_meta_data->>'phone')
  where id = new.id;
  return new;
end;
$$;

drop trigger if exists trg_sync_profile_contact on auth.users;
create trigger trg_sync_profile_contact
after insert or update of email, phone, raw_user_meta_data on auth.users
for each row execute function public.sync_profile_contact_from_auth();

-- ── 5. 검증: sync 후 상태 ──
select
  count(*) filter (where email is not null and email != '') as has_email,
  count(*) filter (where phone is not null and phone != '') as has_phone,
  count(*) filter (where (email is null or email='') and (phone is null or phone='')) as no_contact,
  count(*) as total
from public.profiles;

-- 완료
do $$ begin
  raise notice '✅ profiles.email/phone 강제 sync + auto-sync 트리거 설치 완료';
end $$;
