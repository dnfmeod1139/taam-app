-- ═══════════════════════════════════════════════════════════════
-- TAAM — 보안 점검 반영 (2026-10-29) — 초대 코드 표 비로그인 차단 · 인원 변경 환불 한도
-- ═══════════════════════════════════════════════════════════════
--   보안 점검 워크플로(6 렌즈 → 발견마다 재현·영향 반박 2명 · 확정 8)가 짚은 것 중 **서버만으로 막을 수 있는 것**.
--   (같은 날 20261029_partner_grants.sql 이 _taam_auth_email 의 anon 구멍과 profiles 글자 검사를 함께 고친다.)
--
--   ① invite_codes — 라이브 정책 `invite_codes_read` 가 **roles public · USING true** 였다(진단 20261029_diag_admin_surface.sql 의 Actions 로그).
--      비로그인(anon)도 공개 키로 전 초대장의 이름·전화·이메일·등급·코드·사용 여부를 읽었다(재현).
--      앱이 초대장을 읽는 곳은 전부 **로그인 뒤**(가입 직후 등급 조회 · OTP 확인 뒤 대조 · 프로필 보충 · 어드민 화면) — 비로그인 읽기는 없다.
--      코드 확인은 Edge verify-invite(service_role) · 사용 처리는 consume-invite(service_role)라 영향 없다.
--      → 그 정책을 authenticated 로 좁히고 anon 의 표 권한을 거둔다. ⚠ 로그인한 회원끼리는 아직 서로 읽힌다 —
--        회원 읽기를 「자기 줄만」으로 좁히려면 가입·로그인 흐름의 다섯 읽기를 서버 함수로 옮겨야 한다(인증 담당 · 보고서에 안).
--   ② taam_change_party_size — 매장 어드민이 부르는 인원 변경이 **호출자가 적은 환불액**(결제액 이하면 무엇이든)을 그 행 주인의 예치금에 넣었다.
--      운영 행(수동 MAN- · 초대 홀드 INVH-)은 그 행을 넣은 어드민의 것이라, 승인된 파트너가 자기 수동 좌석의 금액을 올리고(수동 수정 RPC) 인원을 줄여
--      **자기 예치금을 만들 수 있었다**(재현). 회원 구매에서도 한 명 줄이며 결제액 전부(대행비 포함)를 돌려줄 수 있었다.
--      → 운영 행(MAN-·INVH-·KSK-·LINK-)은 거부 · 슈퍼어드민이 아니면 자기 구매는 못 바꾸고 **확정(active) 구매만** · 환불은 **줄인 인원 몫**
--        (1인 몫 = min(행 금액 ÷ 인원, 회차 정가 1인) − 대행비(구매 30분 뒤) · 앞선 감소가 남긴 대행비는 빼고 나눈다)까지 ·
--        카드가 섞이지 않은 구매는 **원장에 적힌 이 구매의 예치금 결제 − 이미 돌려준 것**까지(2차 리뷰: 회원이 금액을 적은 미결제 홀드로
--        파트너가 그 회원 예치금을 만들 수 있었다 — 행 금액은 홀드일 때 회원이 쓰는 칸이다).
--      슈퍼어드민은 종전 그대로. 라이브 본문에 정확히 그 줄이 있을 때만 덧댄다(pg_get_functiondef · 모양이 다르면 ⚠ 로 두고 건드리지 않는다).
-- ═══════════════════════════════════════════════════════════════
create temp table if not exists _sa(항목 text, 결과 text);
truncate _sa;

-- ── ① invite_codes ──
do $do$
begin
  if to_regclass('public.invite_codes') is null then insert into _sa values ('① invite_codes', '⚠ 표 없음'); return; end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'invite_codes' and policyname = 'invite_codes_read') then
    execute 'alter policy invite_codes_read on public.invite_codes to authenticated';
    insert into _sa values ('① invite_codes_read → authenticated 만', '✅');
  else
    insert into _sa values ('① invite_codes_read 정책', '⚠ 없음(이름이 다르다 — 아래 정책 목록을 보세요)');
  end if;
  execute 'revoke all on public.invite_codes from anon';
  insert into _sa values ('① invite_codes anon 권한 회수', '✅');
exception when others then insert into _sa values ('① invite_codes', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── ② taam_change_party_size ──
do $do$
declare
  v_def text; v_new text;
  a1 text := $a$  if t.status in ('cancelled', 'canceled') then
    raise exception 'ALREADY_CANCELLED';
  end if;
$a$;
  b1 text := $b$
  -- 🆕 2026-10-29 보안 점검: 운영 행(수동 MAN- · 초대 홀드 INVH- · 정산 KSK- · 결제 링크 LINK-)은 인원 변경 환불 대상이 아니다
  --   (수동은 taam_manual_entry_update · 링크·정산은 환불 뒤 새로) — 매장 어드민이 자기 수동 좌석으로 예치금을 만들던 길
  if coalesce(t.purchase_id, '') ~ '^(MAN|INVH|KSK|LINK)-' then
    raise exception 'PAX_CHANGE_NOT_FOR_OPS: 수동·초대 홀드·결제 링크·정산 좌석은 인원 변경 환불 대상이 아닙니다';
  end if;
$b$;
  a2 text := $a$  if v_refund > v_price then
    raise exception 'REFUND_TOO_LARGE: 결제액(%)을 넘을 수 없습니다', v_price;
  end if;
$a$;
  b2 text := $b$
  -- 🆕 2026-10-29 보안 점검: 매장 어드민(파트너)의 인원 변경 환불 한도 — 서버가 기록한 돈만 믿는다
  --   ① 확정(active) 구매만 — 홀드·확정 대기·만료 행은 돈을 낸 적이 없다(회원이 금액을 적은 PAYH- 홀드로 예치금을 만들던 길 · 2차 리뷰 재현)
  --   ② 이 매장의 회차에 붙은 행만 · 자기 구매는 못 바꾼다
  --   ③ 1인 몫 = min(행 금액 ÷ 인원, 회차 정가 1인) − 대행비(구매 30분이 지났으면) · 앞선 감소가 남긴 대행비는 빼고 나눈다(한 명씩 줄이면 대행비가 새던 것)
  --   ④ 예치금으로 돌려줄 몫 ≤ 원장에 적힌 이 구매의 예치금 결제 − 이미 돌려준 것(환불·인원 변경)
  if not v_is_super then
    if t.user_id = v_uid then
      raise exception 'FORBIDDEN_OWN: 자기 구매의 인원은 바꿀 수 없습니다';
    end if;
    if coalesce(t.status, '') <> 'active' then
      raise exception 'PAX_CHANGE_NOT_PAID: 결제가 확정된 예약만 인원을 바꿀 수 있습니다 (상태: %)', coalesce(t.status, '');
    end if;
    declare
      v_tp_rest  text;
      v_ag       integer := 0;
      v_lp1      bigint;
      v_orig     integer := v_old_pax;
      v_per      integer;
      v_cap      integer;
      v_led_paid bigint := 0;
      v_led_back bigint := 0;
      v_dep_cap  bigint;
      v_card_on  boolean := (coalesce(t.extra_data->>'cardPaid', '') ~ '^\d{1,12}$' and (t.extra_data->>'cardPaid')::bigint > 0)
                            or coalesce(t.extra_data->>'paidBy', '') = 'card+deposit';
    begin
      select tp.rest_id::text, coalesce(tp.agency_fee, 0) into v_tp_rest, v_ag
        from public.ticket_products tp where tp.id::text = t.ticket_product_id::text;
      if v_tp_rest is null or v_tp_rest <> coalesce(t.restaurant_id::text, '') then
        raise exception 'PAX_CHANGE_BAD_ROUND: 이 매장 회차의 예약이 아닙니다';
      end if;
      v_ag := greatest(coalesce(v_ag, 0), case when coalesce(t.extra_data->>'agencyFee', '') ~ '^\d{1,9}$' then (t.extra_data->>'agencyFee')::integer else 0 end);
      if t.created_at is not null and t.created_at <= now() and t.created_at > now() - interval '30 minutes' then v_ag := 0; end if;
      if jsonb_typeof(t.extra_data->'pax_changes') = 'array' and coalesce(t.extra_data->'pax_changes'->0->>'from', '') ~ '^\d{1,4}$' then
        v_orig := greatest(v_old_pax, (t.extra_data->'pax_changes'->0->>'from')::integer);
      end if;
      v_per := floor(greatest(0, v_price::numeric - v_ag::numeric * v_orig) / greatest(v_old_pax, 1))::integer;
      if to_regprocedure('public.taam_ticket_price_krw(text, integer)') is not null then
        execute 'select public.taam_ticket_price_krw($1, 1)' into v_lp1 using t.ticket_product_id::text;
        if v_lp1 is not null and v_lp1 > 0 then v_per := least(v_per, greatest(0, v_lp1 - v_ag)::integer); end if;
      end if;
      v_cap := (v_old_pax - p_new_pax) * greatest(0, v_per);
      if v_refund > v_cap then
        raise exception 'REFUND_TOO_LARGE: 매장 어드민은 줄인 인원 몫(₩%)까지만 돌려줄 수 있습니다', v_cap;
      end if;
      select coalesce(sum(abs(amount)) filter (where change_type = 'ticket_purchase' and amount < 0), 0),
             coalesce(sum(abs(amount)) filter (where change_type in ('ticket_refund', 'ticket_pax_change') and amount > 0), 0)
        into v_led_paid, v_led_back
        from public.deposit_transactions
       where user_id = t.user_id and metadata->>'purchase_id' = p_purchase_id;
      v_dep_cap := greatest(0, v_led_paid - v_led_back);
      -- 카드가 섞이지 않은 구매는 환불 전부가 예치금으로 간다 — 원장에 낸 예치금보다 많이는 못 돌려준다
      if not v_card_on and v_refund > v_dep_cap then
        raise exception 'REFUND_TOO_LARGE: 이 예약에 예치금으로 낸 기록(₩%)보다 많이 돌려줄 수 없습니다', v_dep_cap;
      end if;
    end;
  end if;
$b$;
begin
  if to_regprocedure('public.taam_change_party_size(text, integer, integer, text)') is null then
    insert into _sa values ('② taam_change_party_size', '⚠ 함수 없음'); return;
  end if;
  v_def := pg_get_functiondef('public.taam_change_party_size(text, integer, integer, text)'::regprocedure);
  if v_def like '%PAX_CHANGE_NOT_FOR_OPS%' then insert into _sa values ('② taam_change_party_size', '✅ 이미 새 판'); return; end if;
  if (length(v_def) - length(replace(v_def, a1, ''))) / length(a1) <> 1 or (length(v_def) - length(replace(v_def, a2, ''))) / length(a2) <> 1 then
    insert into _sa values ('② taam_change_party_size', '⚠ 라이브 본문 모양이 저장소와 다르다 — 건드리지 않음(손으로 대조 필요)'); return;
  end if;
  v_new := replace(replace(v_def, a1, a1 || b1), a2, a2 || b2);
  execute v_new;
  insert into _sa values ('② taam_change_party_size', '✅ 덧댐(운영 행 거부 · 파트너 환불 한도)');
exception when others then insert into _sa values ('② taam_change_party_size', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── 확인 (하나로 · ❌ 가 없어야 정상) ──
select 항목, 결과 from _sa
union all
select '① anon 이 invite_codes 를 못 읽는다', case when has_table_privilege('anon', 'public.invite_codes', 'select') then '❌' else '✅' end
 where to_regclass('public.invite_codes') is not null
union all
select '① invite_codes 정책(정보)', string_agg(policyname || ' · ' || cmd || ' · ' || array_to_string(roles, ','), ' | ' order by policyname)
  from pg_policies where schemaname = 'public' and tablename = 'invite_codes'
union all
select '② 인원 변경 덧댐', case when exists (select 1 from pg_proc where proname = 'taam_change_party_size' and prosrc like '%PAX_CHANGE_NOT_FOR_OPS%') then '✅' else '⚠ 덧대지 못함(위 줄)' end;
