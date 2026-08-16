-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원 국가 구분(profiles.country) 도입 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 왜 필요한가
--   국가 정보가 invite_codes.country 에만 있고 회원 레코드엔 없었다.
--   그래서 회원 목록·통계에서 국내/해외를 전혀 구분할 수 없었다.
--   앱 코드(pvVerifyPhone)는 이미 profiles.country 에 'KR' 을 쓰려고
--   시도하고 있었지만 컬럼이 없어 조용히 실패하고 있었다.
--
-- 왜 invite_codes 로 백필하지 않는가  ★중요★
--   invite_codes.country 는 '실제 거주국'이 아니라 '가입 경로'다.
--   2026-08 이전에는 국내 SMS 인증 경로가 없어서 국내 회원도 전부
--   이메일(EN) 경로로 가입했고, 발급 화면 기본값도 EN 이었다.
--   실제로 조회해보면 EN 13 / KR 2 로 나오지만 현재 회원은 전원 국내다.
--   → 그 값을 그대로 옮기면 국내 회원 13명이 해외로 잘못 분류된다.
--   → 기존 회원은 전원 'KR' 로 시작하고, 이후 가입자는 초대코드의
--     country 를 그대로 기록한다. 예외는 슈퍼어드민이 회원 관리
--     모달에서 직접 바꾼다.
-- ═══════════════════════════════════════════════════════════════

-- 1) 컬럼 추가
alter table public.profiles add column if not exists country text;

-- 2) 기존 회원 전원 국내로 분류 (위 주석의 근거)
update public.profiles
   set country = 'KR'
 where country is null;

-- 3) 이후 가입자 기본값 — 앱이 명시적으로 넣지만 누락 대비
alter table public.profiles alter column country set default 'KR';

-- 4) 값 제한 (KR = 국내 / EN = 해외)
do $$
begin
  alter table public.profiles
    add constraint profiles_country_chk check (country in ('KR','EN'));
exception
  when duplicate_object then null;
  when duplicate_table  then null;
end $$;

-- 5) 회원 목록 필터용
create index if not exists idx_profiles_country on public.profiles(country);

-- 확인
select country, count(*) as 회원수
from public.profiles
where deleted_at is null
group by country
order by 2 desc;

do $$ begin raise notice '✅ profiles.country 도입 완료 — 기존 회원 전원 KR'; end $$;
