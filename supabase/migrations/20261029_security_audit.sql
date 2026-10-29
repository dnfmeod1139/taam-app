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
--      → 운영 행(MAN-·INVH-·KSK-·LINK-)은 거부 · 슈퍼어드민이 아니면 자기 구매는 못 바꾸고 환불은 **줄인 인원 몫**(1인 결제액 × 줄인 인원, 구매 30분이 지났으면 대행비 제외)까지.
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
  -- 🆕 2026-10-29 보안 점검: 매장 어드민(파트너)은 줄인 인원 몫까지만 — 1인 결제액 × 줄인 인원(구매 30분이 지났으면 대행비 제외) · 자기 구매는 못 바꾼다
  if not v_is_super then
    if t.user_id = v_uid then
      raise exception 'FORBIDDEN_OWN: 자기 구매의 인원은 바꿀 수 없습니다';
    end if;
    declare
      v_per integer := floor(v_price::numeric / greatest(v_old_pax, 1))::integer;
      v_ag  integer := 0;
      v_cap integer;
    begin
      select coalesce(tp.agency_fee, 0) into v_ag from public.ticket_products tp where tp.id::text = t.ticket_product_id::text;
      v_ag := greatest(coalesce(v_ag, 0), case when coalesce(t.extra_data->>'agencyFee', '') ~ '^\d{1,9}$' then (t.extra_data->>'agencyFee')::integer else 0 end);
      if t.created_at is not null and t.created_at <= now() and t.created_at > now() - interval '30 minutes' then v_ag := 0; end if;
      v_cap := (v_old_pax - p_new_pax) * greatest(0, v_per - v_ag);
      if v_refund > v_cap then
        raise exception 'REFUND_TOO_LARGE: 매장 어드민은 줄인 인원 몫(₩%)까지만 돌려줄 수 있습니다', v_cap;
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
