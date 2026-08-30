-- ═══════════════════════════════════════════════════════════════
-- TAAM — 예치금 잔액을 회원이 직접 못 쓰게 한다 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 열려 있나
--   profiles_update_own 이 (auth.uid() = id) OR is_superadmin() 이다.
--   자기 행을 고칠 수 있다는 뜻이고, 잔액 컬럼도 자기 행에 있다.
--
--       update profiles set membership_deposit_balance = 99999999
--        where id = <내 id>
--
--   role 은 앞서 트리거로 막았지만(guard_profile_role.sql) 잔액은 그대로였다.
--   role 보다 이쪽이 더 직접적이다 — 올린 만큼 티켓을 살 수 있다.
--
-- 왜 지금까지 못 막았나
--   구매·취소·환불이 전부 「회원 세션이 자기 잔액을 직접 고치는」 구조였다.
--   그냥 막으면 그 자리에서 결제가 멈춘다. 그래서 순서가 있다.
--
--       ① 서버 함수를 만든다            ← 이 파일 ①
--       ② 앱이 그 함수를 부르게 바꾼다   ← index.html (BUILD 2026.08.30-w)
--       ③ 배포하고, 구매·취소가 되는지 실제로 확인한다
--       ④ 그 다음에 직접 쓰기를 막는다   ← 이 파일 ④ (따로 실행)
--
--   ①②③ 이 끝나기 전에 ④ 를 돌리면 결제가 멈춘다. ④ 는 파일 아래쪽에
--   따로 떼어 뒀다. 오늘 ①②③ 까지만 하고, ④ 는 확인한 다음에 한다.
--
-- 덤으로 고쳐지는 것
--   지금 앱은 「잔액을 읽고 → 계산하고 → 덮어쓴다」. 두 창에서 동시에
--   구매하면 나중 것이 앞 것을 덮어써서 차감 하나가 사라진다.
--   ① 의 함수는 행을 잠그고 증감으로 처리해서 그런 일이 없다.
--
-- 실행: Supabase SQL Editor. ①②③ 는 지금, ④ 는 앱 배포 확인 후.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 잔액을 서버에서 증감한다
-- ═══════════════════════════════════════════════════════════════
--   델타(증감분)를 받는다. 「새 잔액」을 받지 않는 것이 요점이다 —
--   새 잔액을 받으면 계산이 클라이언트에 남아서 막는 의미가 없다.
--
--   음수로 차감, 양수로 환원. 0 아래로는 안 내려간다.
--   자기 것이거나 슈퍼어드민일 때만 통한다.
-- 요청자가 슈퍼어드민인가. guard_profile_role.sql 에도 같은 것이 있지만,
--   이 파일만 돌려도 되게 여기서도 만든다. 정의가 같으므로 겹쳐도 무해하다.
--   ⚠ 없는 상태로 아래 ④ 가드를 올리면 잔액 수정이 전부 죽는다 — 그래서 미리 만든다.
create or replace function public._taam_uid_is_super()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.role in ('super_admin','superadmin')
  )
$$;

create or replace function public.taam_apply_deposit_delta(
  p_user_id   uuid,
  p_mem_delta bigint,
  p_gen_delta bigint
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_mem  bigint;
  v_gen  bigint;
  v_nmem bigint;
  v_ngen bigint;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;

  -- 자기 것이거나 슈퍼어드민
  if p_user_id <> v_uid and not exists (
       select 1 from public.profiles p
        where p.id = v_uid and p.role in ('super_admin','superadmin')
     ) then
    raise exception '다른 회원의 예치금은 바꿀 수 없습니다' using errcode = '42501';
  end if;

  -- 행을 잠그고 읽는다. 여기가 「읽고 덮어쓰기」와 갈리는 자리다 —
  -- 동시에 두 건이 들어와도 하나씩 차례로 처리된다.
  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0)
    into v_mem, v_gen
    from public.profiles
   where id = p_user_id
     for update;

  if not found then
    raise exception '회원을 찾을 수 없습니다' using errcode = 'P0002';
  end if;

  v_nmem := greatest(0, v_mem + coalesce(p_mem_delta, 0));
  v_ngen := greatest(0, v_gen + coalesce(p_gen_delta, 0));

  update public.profiles
     set membership_deposit_balance = v_nmem,
         general_deposit_balance    = v_ngen,
         deposit_balance            = v_nmem + v_ngen
   where id = p_user_id;

  return json_build_object(
    'mem',   v_nmem,
    'gen',   v_ngen,
    'total', v_nmem + v_ngen,
    'mem_before', v_mem,
    'gen_before', v_gen
  );
end;
$$;

revoke all on function public.taam_apply_deposit_delta(uuid, bigint, bigint) from public;
grant execute on function public.taam_apply_deposit_delta(uuid, bigint, bigint) to authenticated;

comment on function public.taam_apply_deposit_delta(uuid, bigint, bigint) is
  '예치금 잔액을 서버에서 증감한다. 자기 것 또는 슈퍼어드민만. 행 잠금으로 동시 갱신 유실을 막는다.';


-- ═══════════════════════════════════════════════════════════════
-- ② 잘 도는지 (내 잔액에 0 을 더해 본다 — 값이 안 변한다)
-- ═══════════════════════════════════════════════════════════════
--   슈퍼어드민 계정으로 SQL Editor 에서 돌리면 auth.uid() 가 없어서
--   에러가 난다. 그건 정상이다 — 함수가 로그인을 요구한다는 뜻이다.
--   여기서는 함수가 만들어졌는지만 본다.
select p.proname                    as "함수",
       pg_get_function_arguments(p.oid) as "인자",
       case when p.prosecdef then 'SECURITY DEFINER' else 'INVOKER' end as "권한"
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta';


-- ═══════════════════════════════════════════════════════════════
-- ③ 옆문도 같이 본다 — deposit_transactions
-- ═══════════════════════════════════════════════════════════════
--   잔액을 직접 못 고치게 해도, deposit_transactions 에 입금 기록을
--   직접 넣을 수 있으면 같은 결과가 된다(합산 트리거가 있으면 특히).
--   지금 정책이 무엇인지 보고 판단한다. 결과를 보내주세요.
select 'deposit_transactions' as "테이블",
       policyname             as "정책",
       cmd                    as "동작",
       coalesce(with_check, qual, '(없음)') as "조건"
from pg_policies
where schemaname = 'public' and tablename = 'deposit_transactions'

union all

select 'tickets', policyname, cmd, coalesce(with_check, qual, '(없음)')
from pg_policies
where schemaname = 'public' and tablename = 'tickets'

order by 1, 3, 2;


-- ═══════════════════════════════════════════════════════════════
-- ④ ⚠ 여기서부터는 앱 배포를 확인한 뒤에 실행한다
-- ═══════════════════════════════════════════════════════════════
-- 먼저 이것부터 확인하세요 (시크릿창)
--   · 앱 BUILD 가 2026.08.30-w 이상인가
--   · 티켓을 예치금으로 한 건 구매해 보고 잔액이 줄어드는가
--   · 그 건을 취소해 보고 잔액이 돌아오는가
--
-- 확인 전에 이걸 돌리면 구매·취소가 그 자리에서 멈춥니다.
-- 확인이 끝났으면 아래 블록만 따로 복사해서 실행하세요.
-- ───────────────────────────────────────────────────────────────
/*

create or replace function public.taam_guard_deposit_balance()
returns trigger
language plpgsql
set search_path = public
as $guard$
begin
  -- 잔액이 안 바뀌면 볼 것 없다.
  --
  -- ⚠ deposit_balance 는 **일부러 안 본다.** 이 값은 원본이 아니라 합계다.
  --   profiles 에 sync 트리거가 둘 붙어 있고(trg_sync_deposit_balance ·
  --   trg_taam_sync_deposit_balance), 그중 뒤엣것은 컬럼을 안 가리고
  --   **모든 UPDATE 마다** deposit_balance := 멤버십 + 일반 로 다시 쓴다.
  --   그래서 합계가 어긋나 있던 행은 이름만 바꿔도 그 자리에서 교정된다.
  --   합계까지 보면 그 교정을 「잔액을 바꿨다」고 오해할 수 있다.
  --
  --   지금 이름들로는 마침 이 가드가 sync 보다 먼저 돈다
  --   (BEFORE 트리거는 이름 알파벳 순 · trg_taam_g… < trg_taam_s…).
  --   그래서 합계를 봐도 오늘은 문제가 안 난다 — 로컬에서 확인했다.
  --   다만 그건 **이름 덕분이지 설계 덕분이 아니다.** 순서를 뒤집어 보니
  --   그 즉시 멀쩡한 이름 변경이 막혔다. 트리거 이름 하나에 결제 화면이
  --   걸리는 구조를 남기지 않는다. 원본 둘만 본다 — 순서와 무관해진다.
  if new.membership_deposit_balance is not distinct from old.membership_deposit_balance
     and new.general_deposit_balance is not distinct from old.general_deposit_balance then
    return new;
  end if;

  -- 서버가 하는 일은 막지 않는다.
  --   taam_apply_deposit_delta 는 SECURITY DEFINER 라 소유자 권한으로 돌고,
  --   여기 current_user 는 'authenticated' 가 아니다. 그래서 통과한다.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- 슈퍼어드민의 예치금 부여·조정은 계속 돼야 한다
  if public._taam_uid_is_super() then
    return new;
  end if;

  -- 여기까지 왔으면 회원이 자기 잔액을 직접 고치려 한 것이다.
  --   role 과 달리 조용히 되돌리지 않고 막는다 — 돈이라 흔적이 남아야 하고,
  --   앱이 이 경로를 더 쓰지 않으므로 정상 요청이 죽을 일이 없다.
  raise exception '예치금은 직접 바꿀 수 없습니다 (taam_apply_deposit_delta 를 쓰세요)'
    using errcode = '42501';
end;
$guard$;

drop trigger if exists trg_taam_guard_deposit_balance on public.profiles;
create trigger trg_taam_guard_deposit_balance
  before update on public.profiles
  for each row execute function public.taam_guard_deposit_balance();

comment on function public.taam_guard_deposit_balance() is
  '회원이 자기 예치금 잔액을 직접 고치지 못하게 막는다. RPC·슈퍼어드민은 통과.';

-- 붙었는지
select tgname as "트리거"
from pg_trigger
where tgrelid = 'public.profiles'::regclass
  and tgname = 'trg_taam_guard_deposit_balance';

*/
-- ───────────────────────────────────────────────────────────────
-- ⑤ 되돌리려면 (구매가 막히면 즉시)
-- ───────────────────────────────────────────────────────────────
--   drop trigger if exists trg_taam_guard_deposit_balance on public.profiles;
--
--   이 한 줄이면 원래대로 돌아간다. ① 의 함수는 남겨둬도 무해하다.
--
-- ───────────────────────────────────────────────────────────────
-- 남은 것
-- ───────────────────────────────────────────────────────────────
--   ⓐ tickets 도 자기 행을 고칠 수 있다 (price · party_size · status).
--      돈이 바로 움직이진 않지만 기록이 어긋난다. ③ 결과를 보고 정한다.
--   ⓑ membership_tier · membership_expires_at 도 자기 행이라 바꿀 수 있다.
--      가입 흐름이 초대코드 등급을 여기에 쓰고 있어 같이 막으면 가입이 깨진다.
--      이것도 서버로 옮긴 뒤에 막는다.
