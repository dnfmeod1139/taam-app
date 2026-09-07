-- ════════════════════════════════════════════════════════════════
-- 일본어 검수 게이트 개방 (2026-09-07)
--
-- ⚠ 이 파일은 저장소에 두는 것만으로는 반영되지 않는다.
--   Supabase SQL Editor 에서 직접 RUN 해야 한다.
--
-- 왜 필요한가
--   i18n_jp_approved 는 「AI 음차가 틀릴 수 있으니 검수 후 일본어를 공개한다」는
--   취지로 default false 로 만들어졌다. 그런데 이 값을 true 로 바꾸는 화면을
--   끝내 만들지 않았다 — 앱 전체에서 이 컬럼은 읽기만 하고 쓰기가 0건이다.
--
--   화면 렌더(pickI18nField)는 이 값이 false 면 일본어 번역이 있어도 버리고
--   한국어로 폴백한다. 결과적으로 매장명·주소·티켓 설명·파트너 소개의
--   일본어가 구조적으로 영원히 노출되지 않았다.
--   (chefs 테이블에는 이 컬럼이 없어 계보도 일본어만 정상 동작했다)
--
-- 무엇을 하나
--   1) 기본값을 true 로 바꾼다 — 앞으로 들어오는 행은 바로 일본어가 나온다.
--   2) 기존 행을 일괄 개방한다.
--
--   컬럼은 남겨둔다. 나중에 특정 매장의 일본어 표기가 틀린 것이 발견되면
--   그 행만 false 로 내려 한국어 폴백으로 되돌릴 수 있다(개별 escape hatch).
-- ════════════════════════════════════════════════════════════════

-- 1) 앞으로 들어올 행
alter table public.restaurants     alter column i18n_jp_approved set default true;
alter table public.ticket_products alter column i18n_jp_approved set default true;
alter table public.venue_partners  alter column i18n_jp_approved set default true;

-- 2) 이미 쌓인 행 — false 인 것만 연다 (이미 true 인 행은 건드리지 않는다)
update public.restaurants     set i18n_jp_approved = true where i18n_jp_approved is distinct from true;
update public.ticket_products set i18n_jp_approved = true where i18n_jp_approved is distinct from true;
update public.venue_partners  set i18n_jp_approved = true where i18n_jp_approved is distinct from true;

-- ── 확인 (union all 하나로) ─────────────────────────────────────
select 'restaurants'     as 테이블,
       count(*)                                          as 전체,
       count(*) filter (where i18n_jp_approved)          as 일본어_공개,
       count(*) filter (where name_jp is not null
                          and btrim(name_jp) <> '')      as 일본어_번역있음
  from public.restaurants
union all
select 'ticket_products',
       count(*),
       count(*) filter (where i18n_jp_approved),
       count(*) filter (where ticket_desc_jp is not null
                          and btrim(ticket_desc_jp) <> '')
  from public.ticket_products
union all
select 'venue_partners',
       count(*),
       count(*) filter (where i18n_jp_approved),
       count(*) filter (where custom_name_jp is not null
                          and btrim(custom_name_jp) <> '')
  from public.venue_partners;

-- 기대: 「전체」와 「일본어_공개」가 같아야 한다.
--   「일본어_번역있음」이 전체보다 적으면 그만큼은 아직 번역이 안 된 행이다
--   → 어드민 화면의 일괄 AI 번역을 돌리면 채워진다.
