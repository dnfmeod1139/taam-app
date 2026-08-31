-- ═══════════════════════════════════════════════════════════════
-- TAAM — 되돌릴 지점 만들기 (스냅샷) · 2026-08-31
-- ═══════════════════════════════════════════════════════════════
-- 왜 만드나
--   오늘 데이터를 대량으로 바꿨다.
--     · chefs 396장의 사진을 base64 → Storage URL 로 교체
--     · profiles 에 가드 트리거 3개 (role · 예치금 · 등급)
--     · tickets 에 가드 트리거 2개 (재구매 · 등급)
--   다음 작업(레스토랑 사진 8건, 부팅 최적화)에 들어가기 전에 지금 상태를
--   통째로 떠 둔다. 무언가 잘못되면 이 표에서 되돌릴 수 있다.
--
-- ⚠ 반드시 public 이 아닌 스키마에 만든다
--   Supabase 는 public 스키마를 REST API 로 그대로 노출한다. 거기에
--   public.profiles_backup 같은 걸 만들면 **RLS 가 꺼진 채로** 생기고,
--   회원 정보 사본이 anon 키만으로 통째로 읽힌다.
--   taam_backup 스키마는 노출 목록에 없으므로 API 로 닿지 않는다.
--   그래도 anon·authenticated 권한을 명시적으로 회수한다 (두 겹).
--
-- ⚠ 이건 「지금 상태」의 사본이다
--   오늘 바꾸기 **전** 상태로 되돌리려면 Supabase 자동 백업(대시보드 →
--   Database → Backups)을 써야 한다. 이 스냅샷은 앞으로의 작업에 대한
--   안전망이지, 오늘 작업을 되돌리는 용도가 아니다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--       여러 번 돌리면 그때그때 새 시각으로 다시 뜬다(덮어쓴다).
-- ═══════════════════════════════════════════════════════════════

create schema if not exists taam_backup;

-- 노출 차단 — 두 겹. (스키마 노출 목록에 없어도 명시적으로 막는다)
revoke all on schema taam_backup from anon, authenticated;
revoke all on all tables in schema taam_backup from anon, authenticated;
alter default privileges in schema taam_backup revoke all on tables from anon, authenticated;

do $$
declare
  v_stamp text := to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDD_HH24MI');
  v_tbl   text;
  v_tbls  text[] := array[
    'chefs',            -- 오늘 사진 396장 교체
    'restaurants',      -- 다음 작업 대상
    'profiles',         -- 가드 3개가 붙은 테이블
    'tickets',          -- 가드 2개가 붙은 테이블
    'ticket_products',
    'deposit_transactions',
    'invite_codes',
    'reservation_invites'
  ];
  v_n bigint;
begin
  foreach v_tbl in array v_tbls loop
    if not exists (select 1 from information_schema.tables
                    where table_schema='public' and table_name=v_tbl) then
      raise notice '[backup] public.% 없음 — 건너뜀', v_tbl;
      continue;
    end if;
    execute format(
      'drop table if exists taam_backup.%I; create table taam_backup.%I as table public.%I',
      v_tbl || '_' || v_stamp, v_tbl || '_' || v_stamp, v_tbl);
    execute format('select count(*) from taam_backup.%I', v_tbl || '_' || v_stamp) into v_n;
    raise notice '[backup] % → taam_backup.%_%  (% 행)', v_tbl, v_tbl, v_stamp, v_n;
  end loop;
end $$;

-- 새로 생긴 표에도 권한 회수를 한 번 더 (default privileges 이전에 만들어진 경우 대비)
revoke all on all tables in schema taam_backup from anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 무엇이 얼마나 떠졌나
-- ═══════════════════════════════════════════════════════════════
--   ⚠ reltuples 는 ANALYZE 전이면 -1 이라 못 쓴다. 실제로 센다.
select c.relname                                     as "스냅샷",
       (xpath('/row/n/text()',
          query_to_xml(format('select count(*) as n from taam_backup.%I', c.relname),
                       false, true, '')))[1]::text::bigint as "행수",
       pg_size_pretty(pg_total_relation_size(c.oid))  as "크기"
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'taam_backup' and c.relkind = 'r'
order by c.relname;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리는 법 (예: restaurants 를 스냅샷 시점으로)
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 통째로 되돌리면 그 사이 들어온 새 데이터도 사라진다.
--     보통은 **바뀐 컬럼만** 되돌리는 게 맞다. 예를 들어 사진만:
--
--   update public.restaurants r
--      set photo_card = b.photo_card
--     from taam_backup.restaurants_20260831_1200 b
--    where b.id = r.id and r.photo_card is distinct from b.photo_card;
--
--   행 전체를 되돌려야 하면:
--     begin;
--       delete from public.restaurants;
--       insert into public.restaurants select * from taam_backup.restaurants_20260831_1200;
--     commit;   -- ⚠ 외래키가 걸린 테이블에서는 순서를 따져야 한다
--
-- ═══════════════════════════════════════════════════════════════
-- 오래된 스냅샷 지우기
-- ═══════════════════════════════════════════════════════════════
--   용량을 먹으므로 확인이 끝나면 지운다. 목록은 위 확인 쿼리로 본다.
--     drop table if exists taam_backup.<이름>;
--
--   ⚠ Storage 는 이 스냅샷에 포함되지 않는다.
--     이제 사진이 chef-photos 버킷에 있고 DB 에는 URL 만 있다. 버킷을
--     지우면 스냅샷을 되돌려도 사진은 돌아오지 않는다. 버킷은 지우지 말 것.
