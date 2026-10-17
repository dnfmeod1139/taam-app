-- ═══════════════════════════════════════════════════════════════
-- 멤버십 연회비 기록 시드 + 가입일 보강 (2026-10-17 · 운영 확인 반영)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor. A 블록과 B 블록을 따로 RUN (에디터는 마지막 결과만 보여 준다).
-- 연회비 규정(2026-10-17 운영 확인) — 「부여 금액 = 총액 − 연회비」라 첫해 연회비는 예치금 부여 줄에 숨어 있다:
--   국내 M 11,250,000 (연회비 1,125,000 공제 → 예치금 10,125,000) · 국내 T 3,150,000 (630,000 → 2,520,000)
--   해외 M $9,900 ($990 → $8,910) · 해외 T $3,000 ($300 → $2,700)  · 원화 환산은 부여 줄의 적용환율(1342.315)
-- 이미 넣은 것: 8/31 관리 차감 8명(2026-10-16) · 10,125,000 부여 15명 첫해(2026-10-17).
-- 잔액·원장(deposit_transactions)은 건드리지 않는다. 같은 (회원·납부일·금액) 기록이 있으면 건너뛴다(두 번 돌려도 안전).
-- 이름이 정확히 한 명에게만 맞을 때만 넣는다(공백 무시 · 탈퇴 계정 제외). ⚠/❌ 는 회원 원장 탭에서 직접.
-- ═══════════════════════════════════════════════════════════════

-- ── A. 확정분 — 가입일 두 명 + T·해외 첫해 + 구자호·유수봉 2년차(가입 기념일에 구두 안내 → 이체 · 예치금과 무관) · 2026-10-17 실행 ✅ 9/9 ──
with jd(name, d) as (values ('심종보', date '2025-02-10'), ('최보민', date '2025-01-15')),
jc as (
  select j.name, j.d, p.id from jd j
  left join public.profiles p on regexp_replace(coalesce(p.display_name, ''), '\s', '', 'g') = j.name and p.deleted_at is null
),
jn as (select name, count(id) as n from jc group by name),
ju as (
  update public.profiles p set membership_joined_at = c.d
    from jc c join jn on jn.name = c.name
   where jn.n = 1 and p.id = c.id and p.membership_joined_at is distinct from c.d
  returning p.id
),
fee(name, paid_at, amount_krw, fx_cur, fx_amt, tier, note) as (values
  ('박영준',            date '2026-06-03',  630000, null::text, null::numeric, 'T', '첫해 연회비 — 가입 송금에서 공제 (T 315만 − 63만)'),
  ('남기욱',            date '2026-06-02',  630000, null, null, 'T', '첫해 연회비 — 가입 송금에서 공제 (T 315만 − 63만)'),
  ('이승주',            date '2026-08-31',  630000, null, null, 'T', '첫해 연회비 — 가입 송금에서 공제 (T 315만 − 63만)'),
  ('Eric Cheok',        date '2026-08-27', 1328892, 'USD', 990, 'M', '첫해 연회비 — $9,900 중 $990 공제 (× 1342.315)'),
  ('Michael Minku Lee', date '2026-10-13',  402695, 'USD', 300, 'T', '첫해 연회비 — $3,000 중 $300 공제 (× 1342.315)'),
  ('구자호',            date '2025-12-20', 1125000, null, null, 'M', '2년차(2026년) 연회비 — 가입 기념일에 구두 안내 후 이체로 납부 (예치금 무관)'),
  ('유수봉',            date '2026-07-16', 1125000, null, null, 'M', '2년차(2026년) 연회비 — 가입 기념일에 구두 안내 후 이체로 납부 (예치금 무관)')
),
fc as (
  select f.*, p.id from fee f
  left join public.profiles p on regexp_replace(coalesce(p.display_name, ''), '\s', '', 'g') = regexp_replace(f.name, '\s', '', 'g') and p.deleted_at is null
),
fn as (select name, count(id) as n from fc group by name),
fi as (
  insert into public.membership_fees (user_id, paid_at, amount_krw, fx_currency, fx_amount, method, tier, note, source, source_ref)
  select c.id, c.paid_at, c.amount_krw, c.fx_cur, c.fx_amt, 'transfer', c.tier, c.note, 'ledger', 'seed 2026-10-17 A'
    from fc c join fn on fn.name = c.name
   where fn.n = 1 and c.id is not null
     and not exists (select 1 from public.membership_fees m where m.user_id = c.id and m.paid_at = c.paid_at and m.amount_krw = c.amount_krw)
  returning user_id, paid_at
)
select '가입일' as 구분, j.name as 회원, to_char(j.d, 'YYYY-MM-DD') as 날짜, null::int as 금액,
       case when jn.n = 0 then '❌ 못 찾음' when jn.n > 1 then '⚠ 같은 이름 ' || jn.n || '명' when u.id is not null then '✅ 적음' else '＝ 이미 같음' end as 결과
  from jd j join jn on jn.name = j.name
  left join jc c on c.name = j.name and jn.n = 1
  left join ju u on u.id = c.id
union all
select '연회비', f.name, to_char(f.paid_at, 'YYYY-MM-DD'), f.amount_krw,
       case when fn.n = 0 then '❌ 못 찾음' when fn.n > 1 then '⚠ 같은 이름 ' || fn.n || '명' when i.user_id is not null then '✅ 넣음' else '＝ 이미 있음' end
  from fee f join fn on fn.name = f.name
  left join fc c on c.name = f.name and fn.n = 1
  left join fi i on i.user_id = c.id and i.paid_at = f.paid_at
order by 1, 3, 2;

-- ── B. 앱 이전 가입자의 첫해 연회비 — 기록용 (날짜 = 가입일). 탭 머리 「부족 1건」을 없앤다 · 2026-10-17 실행 ✅ 9/9 ──
with fee(name, paid_at, amount_krw, tier) as (values
  ('임태규', date '2024-12-11', 1125000, 'M'),
  ('이지영', date '2024-12-15', 1125000, 'M'),
  ('구자호', date '2024-12-20', 1125000, 'M'),
  ('최보민', date '2025-01-15', 1125000, 'M'),
  ('김지훈', date '2025-01-20', 1125000, 'M'),
  ('심종보', date '2025-02-10', 1125000, 'M'),
  ('유수봉', date '2025-07-16', 1125000, 'M'),
  ('이윤석', date '2025-08-02', 1125000, 'M'),
  ('이항빈', date '2025-10-21',  630000, 'T')
),
fc as (
  select f.*, p.id from fee f
  left join public.profiles p on regexp_replace(coalesce(p.display_name, ''), '\s', '', 'g') = f.name and p.deleted_at is null
),
fn as (select name, count(id) as n from fc group by name),
fi as (
  insert into public.membership_fees (user_id, paid_at, amount_krw, method, tier, note, source, source_ref)
  select c.id, c.paid_at, c.amount_krw, 'transfer', c.tier, '첫해 연회비 — 앱 이전 납부 (기록용 · 날짜 = 가입일)', 'legacy', 'seed 2026-10-17 B'
    from fc c join fn on fn.name = c.name
   where fn.n = 1 and c.id is not null
     and not exists (select 1 from public.membership_fees m where m.user_id = c.id and m.paid_at = c.paid_at and m.amount_krw = c.amount_krw)
  returning user_id, paid_at
)
select f.name as 회원, to_char(f.paid_at, 'YYYY-MM-DD') as 납부일, f.amount_krw as 금액,
       case when fn.n = 0 then '❌ 못 찾음' when fn.n > 1 then '⚠ 같은 이름 ' || fn.n || '명' when i.user_id is not null then '✅ 넣음' else '＝ 이미 있음' end as 결과
  from fee f join fn on fn.name = f.name
  left join fc c on c.name = f.name and fn.n = 1
  left join fi i on i.user_id = c.id and i.paid_at = f.paid_at
order by f.paid_at, f.name;

-- ── C. 메모 정정 (2026-10-17) — A 를 먼저 돌린 라이브에는 「앱 원장 이전에 차감 · 추정」 메모가 들어갔다. 실제는 가입 기념일에 구두 안내 뒤 이체. 두 줄이 나와야 한다 ──
with upd as (
  update public.membership_fees f
     set note = '2년차(2026년) 연회비 — 가입 기념일에 구두 안내 후 이체로 납부 (예치금 무관)'
   where f.source_ref = 'seed 2026-10-17 A' and f.amount_krw = 1125000
     and f.user_id in (select id from public.profiles where regexp_replace(coalesce(display_name, ''), '\s', '', 'g') in ('구자호', '유수봉') and deleted_at is null)
  returning f.user_id, f.paid_at, f.note
)
select p.display_name as 회원, to_char(u.paid_at, 'YYYY-MM-DD') as 납부일, u.note as 메모
  from upd u join public.profiles p on p.id = u.user_id
 order by 2;

-- ── D. 확인(읽기 전용) — 연회비 기록은 예치금을 움직이지 않는다. 「최근24시간_원장_줄」이 전원 0 이어야 한다 ──
select p.display_name as 회원, p.membership_tier as 등급,
       (select count(*) from public.membership_fees f where f.user_id = p.id) as 연회비_기록,
       (select count(*) from public.deposit_transactions t where t.user_id = p.id and t.created_at > now() - interval '24 hours') as 최근24시간_원장_줄,
       p.membership_deposit_balance as 멤버십_예치금, p.general_deposit_balance as 일반_예치금
  from public.profiles p
 where p.deleted_at is null
   and regexp_replace(coalesce(p.display_name, ''), '\s', '', 'g') in ('임태규','이지영','구자호','최보민','김지훈','심종보','유수봉','이윤석','이항빈','박영준','남기욱','이승주','EricCheok','MichaelMinkuLee')
 order by p.display_name;
