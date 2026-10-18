-- ═══════════════════════════════════════════════════════════════
-- 마이그레이션 기록 기준선 — 「이미 손으로 돌린 파일」을 _taam_migrations 에 적는다 (2026-10-18)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN (GitHub 시크릿을 넣기 **전에**). 결과 표를 읽는다 — 아래 「읽는 법」.
-- 왜: .github/workflows/supabase.yml 은 supabase/migrations/2*.sql 중 public._taam_migrations 에 **기록이 없는 파일을 전부** 순서대로 실행한다.
--     그 표는 워크플로가 한 번도 돈 적이 없어 비어 있다. 이 상태로 시크릿을 넣으면 첫 푸시에서 지금까지 손으로 돌린 30개 파일을 전부 다시
--     돌리려 든다 — 대부분 create or replace 라 무해하지만, 라이브 함수 md5 를 비교해 다르면 ❌ 를 찍는 파일(seat_sync2 등)에서 멈추고,
--     한 번 돌린 시드·백필이 또 돌 수 있다. 그래서 「라이브에 그 파일의 흔적(함수·트리거·표·컬럼)이 있는 파일」을 적용된 것으로 적어 둔다.
-- 무엇: 파일마다 「이 파일이 만든 대표 객체」가 라이브에 있는지 보고, 있으면 _taam_migrations 에 (name, sha='baseline-2026-10-18') 로 넣는다.
--     없는 파일은 넣지 않는다 → 표에 「⚠ 라이브에 없음」으로 뜬다. 그 파일은 (a) 지금 SQL Editor 에서 직접 돌리고 이 파일을 다시 RUN 하거나
--     (b) 그대로 두면 시크릿을 넣은 뒤 첫 main 푸시 때 워크플로가 실행한다 — 오래된 파일은 (a) 가 안전하다.
--     같은 함수를 여러 판으로 고친 파일(seat_sync 1~6 · invite_confirm_hold/owner · manual_entry_edit 1·2)은 대표 객체만 보므로
--     「있음」이 「최신 판」을 보장하지는 않는다 — 그 판들은 CLAUDE.md 에 라이브 적용 기록이 있어 그대로 적는다.
-- 여러 번 RUN 해도 된다 — 이미 적힌 파일은 건너뛴다. 옛 0001~0003 은 손대지 않는다(워크플로도 안 본다).
-- ═══════════════════════════════════════════════════════════════

create table if not exists public._taam_migrations(
  name text primary key, applied_at timestamptz not null default now(), sha text);
alter table public._taam_migrations enable row level security;
revoke all on public._taam_migrations from anon, authenticated;

with files(name, what, present) as (values
  ('20260928_invite_confirm_hold.sql',          'fn taam_invite_confirm_hold',             to_regproc('public.taam_invite_confirm_hold') is not null),
  ('20260929_kashikiri_seat_pax.sql',           'fn taam_ksk_seat_set_pax',                to_regproc('public.taam_ksk_seat_set_pax') is not null),
  ('20260929_kashikiri_seat_sync.sql',          'fn _taam_ksk_seat_sync',                  to_regproc('public._taam_ksk_seat_sync') is not null),
  ('20260929_kashikiri_seat_sync2.sql',         'fn _taam_ksk_seat_sync (2차 · 대표 객체 같음)', to_regproc('public._taam_ksk_seat_sync') is not null),
  ('20260929_kashikiri_seat_sync3.sql',         'fn _taam_ksk_seat_sync (3차 · 대표 객체 같음)', to_regproc('public._taam_ksk_seat_sync') is not null),
  ('20260929_kashikiri_seat_sync4.sql',         'fn _taam_ksk_seat_sync (4차 · 대표 객체 같음)', to_regproc('public._taam_ksk_seat_sync') is not null),
  ('20260929_kashikiri_seat_sync5.sql',         'fn taam_kashikiri_link_ticket',           to_regproc('public.taam_kashikiri_link_ticket') is not null),
  ('20260929_kashikiri_seat_sync6.sql',         'fn _taam_ksk_seat_sync (6차 · 대표 객체 같음)', to_regproc('public._taam_ksk_seat_sync') is not null),
  ('20260929_kashikiri_send_fx_input.sql',      'fn taam_kashikiri_send',                  to_regproc('public.taam_kashikiri_send') is not null),
  ('20260929_link_invite.sql',                  'fn taam_link_invite_create',              to_regproc('public.taam_link_invite_create') is not null),
  ('20260929_pay_venue_i18n.sql',               'charge_public 에 venue_name_en',           exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_charge_public') and prosrc like '%venue_name_en%')),
  ('20260929_ticket_restock.sql',               'table ticket_restock_events',             to_regclass('public.ticket_restock_events') is not null),
  ('20261003_invite_confirm_owner.sql',         'invite_confirm_hold 에 invitee_user_id',   exists (select 1 from pg_proc where oid = to_regproc('public.taam_invite_confirm_hold') and prosrc like '%invitee_user_id%')),
  ('20261004_invite_owner_guard.sql',           'trg trg_taam_guard_invite_owner',         exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_invite_owner' and not tgisinternal)),
  ('20261005_ticket_products_status_recalc.sql','trg trg_taam_tp_status_recalc',           exists (select 1 from pg_trigger where tgname = 'trg_taam_tp_status_recalc' and not tgisinternal)),
  ('20261013_kashikiri_paid_notify.sql',        'fn taam_admin_push',                      to_regproc('public.taam_admin_push') is not null),
  ('20261013_member_start.sql',                 'fn taam_member_start',                    to_regproc('public.taam_member_start') is not null),
  ('20261013_repurchase_no_release.sql',        'fn taam_repurchase_release_days',         to_regproc('public.taam_repurchase_release_days') is not null),
  ('20261014_manual_entry_edit.sql',            'fn taam_manual_entry_update',             to_regproc('public.taam_manual_entry_update') is not null),
  ('20261014_manual_entry_edit2.sql',           'manual_entry_update 에 STALE_EDIT',        exists (select 1 from pg_proc where proname = 'taam_manual_entry_update' and prosrc like '%STALE_EDIT%')),
  ('20261014_purchase_uniqueness.sql',          'trg trg_taam_guard_ticket_unique',        exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ticket_unique' and not tgisinternal)),
  ('20261014_repurchase_manual_release.sql',    'col ticket_products.repurchase_open',     exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ticket_products' and column_name = 'repurchase_open')),
  ('20261015_membership_fees.sql',              'table membership_fees',                   to_regclass('public.membership_fees') is not null),
  ('20261015_membership_joined.sql',            'col profiles.membership_joined_at',       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'membership_joined_at')),
  ('20261016_rpc_caller_guard.sql',             'fn taam_repurchase_release_targets',      to_regproc('public.taam_repurchase_release_targets') is not null),
  ('20261017_membership_fee_due.sql',           'table membership_fee_notices',            to_regclass('public.membership_fee_notices') is not null),
  ('20261017_membership_fee_exempt.sql',        'col profiles.fee_exempt',                 exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'fee_exempt')),
  ('20261018_fee_deduct_record.sql',            'trg trg_taam_fee_from_deduct',            exists (select 1 from pg_trigger where tgname = 'trg_taam_fee_from_deduct' and not tgisinternal)),
  ('20261018_ledger_admin_type_guard.sql',      'trg trg_taam_guard_ledger_change_type',   exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ledger_change_type' and not tgisinternal)),
  ('20261018_pay_link.sql',                     'table kashikiri_charge_admin',            to_regclass('public.kashikiri_charge_admin') is not null)
), ins as (
  insert into public._taam_migrations(name, sha)
  select f.name, 'baseline-2026-10-18' from files f
   where f.present and not exists (select 1 from public._taam_migrations m where m.name = f.name)
  returning name
)
select f.name as 파일, f.what as 감지_대상,
       case when f.present then '✅ 라이브에 있음' else '⚠ 라이브에 없음 — 직접 돌리거나 워크플로가 실행' end as 상태,
       case when f.name in (select name from ins) then '기록함(이번)'
            when exists (select 1 from public._taam_migrations m where m.name = f.name) then '기록 있음(전부터)'
            else '기록 안 함' end as _taam_migrations
  from files f
 order by f.name;
