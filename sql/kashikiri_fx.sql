-- ═══════════════════════════════════════════════════════════════
-- TAAM — 대관: 엔화 원금 · 적용 환율 (2026-09-01)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   대관은 매장에 **엔화로** 지급하고 회원에게는 **원화로** 받는다.
--   회원 결제 화면에 「엔화 원금 · 적용 환율 · 원화 확정액」 셋이 다 보여야
--   나중에 「왜 이 금액이냐」를 되짚을 수 있다. 환율을 안 남기면 그날의
--   근거가 사라지고, 분쟁이 나면 아무도 재현하지 못한다.
--
-- 왜 새 테이블이 아닌가
--   reservation_invites 가 이미 「회원 · 매장 · 일시 · 인원 · 식사 · 주류 ·
--   총액 · 결제상태」를 갖고 있다. 대관 한 팀 = 초대 한 장이다.
--   회차(kashikiri_events)로 팀을 묶는 건 화면상의 편의일 뿐, 9/10 운영에는
--   없어도 된다. 한 번 굴려보고 실제로 불편했던 것만 만든다 —
--   미리 설계하면 안 쓰는 컬럼이 생긴다.
--
-- 무엇을 넣나 — 컬럼 넷. 전부 nullable.
--   비어 있으면 화면이 아무것도 안 보여준다(기존 원화 초대와 완전히 동일).
--   그래서 이 SQL 을 안 돌려도 앱은 그대로 돈다. 앱은 이 컬럼을 INSERT 에
--   싣지 않고, 발송 성공 뒤 따로 UPDATE 한다 — 컬럼이 없는 DB 에서 초대
--   발송이 통째로 실패하는 사고를 피한다(tile_photo 와 같은 이유).
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   읽는 법: 마지막 표에 컬럼 넷이 ✅ 로 다 나오면 정상.
-- ═══════════════════════════════════════════════════════════════

alter table public.reservation_invites
  add column if not exists jpy_meal  integer;        -- 1인 식사 엔화 (액면가)
alter table public.reservation_invites
  add column if not exists jpy_drink integer;        -- 1인 주류 엔화 (미니멈)
alter table public.reservation_invites
  add column if not exists fx_rate   numeric(12,4);  -- 적용 환율 (1엔당 원)
alter table public.reservation_invites
  add column if not exists fx_note   text;           -- 환율 근거 문구 (화면에 그대로 표기)

comment on column public.reservation_invites.jpy_meal  is
  '대관 — 1인 식사 엔화 원금. 매장 수령액과 같은 액면가.';
comment on column public.reservation_invites.jpy_drink is
  '대관 — 1인 주류 엔화(미니멈).';
comment on column public.reservation_invites.fx_rate   is
  '대관 — 결제 시점에 못박은 환율(1엔당 원). 나중에 환율이 변해도 이 값이 근거다.';
comment on column public.reservation_invites.fx_note   is
  '환율 근거 문구. 회원 결제 화면에 그대로 보여준다 — 숨기면 분쟁이 난다.';

-- ⚠ RLS 는 손대지 않는다. 이미 「본인 초대 · 호스트 · 슈퍼어드민」으로 걸려 있고,
--   컬럼을 더해도 그 정책이 그대로 적용된다.


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다 (SQL Editor 는 마지막 결과만 보여준다)
-- ═══════════════════════════════════════════════════════════════
select '① ' || c.name as "구분",
       case when a.attname is null then '❌ 없음' else '✅ ' || format_type(a.atttypid, a.atttypmod) end as "상태",
       '' as "값"
  from (values ('jpy_meal'),('jpy_drink'),('fx_rate'),('fx_note')) as c(name)
  left join pg_attribute a
    on a.attrelid = 'public.reservation_invites'::regclass
   and a.attname  = c.name
   and a.attnum > 0 and not a.attisdropped

union all
select '② 엔화가 들어간 초대',
       count(*)::text || ' 건',
       coalesce(string_agg(distinct restaurant_name, ' · '), '—')
  from public.reservation_invites
 where jpy_meal is not null or jpy_drink is not null

 order by 1;
