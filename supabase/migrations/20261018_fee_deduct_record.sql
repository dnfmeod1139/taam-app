-- ═══════════════════════════════════════════════════════════════
-- 예치금 「관리 차감」을 연회비 납부로 함께 기록 — 한 트랜잭션 (2026-10-18)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 연회비 갱신은 대부분 예치금에서 뺀다(운영 확인 2026-10-18). 그런데 「연회비 납부 시기」가 납부로 세는 것은 membership_fees 기록과
--     앱 카드 결제 줄뿐이라, 예치금 부여·차감 탭에서 차감한 뒤 연회비 탭에 한 줄을 더 적어야 기준일이 1년 밀렸다. 안 적으면 그 회원이 계속
--     「부족」으로 남고 7일·30일 뒤 알림이 다시 왔다(8/31 일괄 차감도 그래서 나중에 SQL 로 옮겨 적었다).
-- 무엇: deposit_transactions 에 admin_deduct 줄이 들어올 때 metadata.membership_fee 가 있으면 같은 트랜잭션 안에서 membership_fees 에
--     한 줄을 적는다(method 'deposit' · source 'deposit_deduct' · source_ref = 원장 줄 id). 앱의 차감 모달 「연회비 납부로 기록」 체크가 그 metadata 를 싣는다.
--     metadata.membership_fee 는 true 또는 {amount_krw, paid_at, tier, period_from, period_to, note, by} — 빈 칸은 차감 금액 · KST 오늘 · 회원 등급(M/T) · 차감 설명으로.
-- 지키는 것:
--   · 기록을 못 적으면 **차감도 취소된다**(FEE_RECORD_FAILED 로 예외) — 「돈은 빠졌는데 기록은 없다」가 이 기능이 없애려는 바로 그 모양이다.
--     어드민이 명시적으로 켠 체크라 조용히 넘기지 않는다 — 부여(+)·회원 결제 줄에 플래그가 실려 와도 같은 이유로 거절한다. 플래그가 없는 줄(종전 전부)은 이 트리거가 보지 않는다.
--   · 잔액·원장은 건드리지 않는다 — membership_fees 는 종전대로 기록만(「다시 입금되는 거냐」 2026-10-17 확인).
--   · 같은 원장 줄로 두 번 적히지 않는다(source_ref 중복 검사).
--   · 차감을 되돌려(부여) 주더라도 기록은 자동으로 지우지 않는다 — 연회비 탭에서 사람이 지운다.
-- 앱: 차감(－)일 때만 보이는 체크 + 납부일(기본 오늘) · 「연회비 납부 시기」 줄과 원장 연회비 탭의 「예치금에서 차감」이 모달을 채워 연다(feeDueDeduct · _adgOpenForFee).
-- 회귀: bash sql/_test/t_fee_deduct.sh
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_fee_from_deduct()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  mf jsonb; v_amt int; v_tier text; v_date date; v_by uuid; v_note text; v_from date; v_to date;
begin
  mf := new.metadata -> 'membership_fee';
  if mf is null or jsonb_typeof(mf) = 'null' then return new; end if;
  if jsonb_typeof(mf) = 'boolean' then
    if not (mf)::text::boolean then return new; end if;
    mf := '{}'::jsonb;
  elsif jsonb_typeof(mf) <> 'object' then
    mf := '{}'::jsonb;
  end if;
  -- 플래그가 켜져 있는데 「관리 차감」 줄이 아니면(부여·회원 결제 등) 조용히 넘기지 않고 거절한다 — 어드민이 「연회비로 기록」을 켠 뜻을 들어줄 수 없는 줄이다
  begin
    if coalesce(new.change_type, '') <> 'admin_deduct' then raise exception '관리 차감(admin_deduct) 줄이 아니다 (%)', coalesce(new.change_type, ''); end if;
    if to_regclass('public.membership_fees') is null then raise exception 'membership_fees 표가 없다 (20261015_membership_fees.sql)'; end if;
    if new.amount is null or new.amount >= 0 then raise exception '차감(음수) 줄이 아니다 (amount %)', new.amount; end if;
    if exists (select 1 from public.membership_fees f where f.source = 'deposit_deduct' and f.source_ref = new.id::text) then return new; end if;
    v_amt := coalesce(nullif(mf->>'amount_krw', '')::bigint, -(new.amount)::bigint)::int;
    if v_amt <= 0 then raise exception '금액이 0 이하 (%)', v_amt; end if;
    v_tier := upper(nullif(btrim(coalesce(mf->>'tier', '')), ''));
    if v_tier is null then
      select upper(p.membership_tier) into v_tier from public.profiles p where p.id = new.user_id;
    end if;
    if v_tier not in ('M', 'T') then v_tier := null; end if;
    v_date := coalesce(nullif(mf->>'paid_at', '')::date, (coalesce(new.created_at, now()) at time zone 'Asia/Seoul')::date);
    v_from := nullif(mf->>'period_from', '')::date;
    v_to   := nullif(mf->>'period_to', '')::date;
    v_note := left(coalesce(nullif(btrim(coalesce(mf->>'note', '')), ''), nullif(btrim(coalesce(new.description, '')), ''), '예치금 차감과 함께 기록'), 300);
    v_by   := coalesce(nullif(mf->>'by', '')::uuid, nullif(new.metadata->>'granted_by', '')::uuid, auth.uid());
    insert into public.membership_fees (user_id, paid_at, amount_krw, method, tier, period_from, period_to, note, source, source_ref, created_by)
    values (new.user_id, v_date, v_amt, 'deposit', v_tier, v_from, v_to, v_note, 'deposit_deduct', new.id::text, v_by);
  exception when others then
    raise exception 'FEE_RECORD_FAILED: 연회비 기록을 못 적어 차감도 취소했습니다 — %', sqlerrm using errcode = 'P0001';
  end;
  return new;
end $$;
comment on function public.taam_fee_from_deduct() is
  'admin_deduct 원장 줄에 metadata.membership_fee 가 있으면 같은 트랜잭션으로 membership_fees 에 기록(method deposit · source deposit_deduct). 실패하면 차감도 취소(FEE_RECORD_FAILED). 2026-10-18';

drop trigger if exists trg_taam_fee_from_deduct on public.deposit_transactions;
create trigger trg_taam_fee_from_deduct
  after insert on public.deposit_transactions
  for each row execute function public.taam_fee_from_deduct();

-- ── 확인 — 한 표 ──
select '① 트리거 trg_taam_fee_from_deduct (after insert on deposit_transactions)' as 항목,
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_fee_from_deduct' and c.relname = 'deposit_transactions' and not t.tgisinternal) then '✅' else '❌' end as 결과
union all select '② 함수 taam_fee_from_deduct · security definer',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_fee_from_deduct') and prosecdef) then '✅' else '❌' end
union all select '③ 의존 — membership_fees 표 · stamp 트리거 · deposit_transactions.metadata 컬럼',
       case when to_regclass('public.membership_fees') is not null
             and exists (select 1 from pg_trigger where tgname = 'trg_taam_membership_fees_stamp' and not tgisinternal)
             and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'deposit_transactions' and column_name = 'metadata') then '✅' else '❌ 20261015_membership_fees.sql 먼저' end
union all select '④ 원장 트리거 공존 (trg_sync_split_balance 그대로)',
       case when exists (select 1 from pg_trigger where tgname = 'trg_sync_split_balance' and not tgisinternal) then '✅' else '⚠ trg_sync_split_balance 없음 — 부여 누적이 안 더해진다 (이 파일과 무관 · sql/admin_grant_via_rpc.sql)' end
union all select '⑤ 지금까지 차감과 함께 적힌 기록 수 (설치 직후 0)',
       (select count(*) from public.membership_fees where source = 'deposit_deduct')::text;
