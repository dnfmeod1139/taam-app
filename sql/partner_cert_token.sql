-- ═══════════════════════════════════════════════════════════════
-- TAAM — 파트너 증서는 토큰이 있어야 열린다 (2026-09-13)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   partner_agreement_get(p_id) 가 anon 에게 열려 있고 id 가 1,2,3… 순번이라
--   누구든 ?cert=1 부터 세어 올라가면 **파트너 셰프 전원의 서명 이미지·이름·
--   협의 금액**을 긁어갈 수 있었다. 증서 링크가 곧 열쇠인데, 열쇠가 순번이었다.
--   감사(2026-09-13) 렌즈 둘(RLS·공개 페이지)이 짚었고 코드로 확인했다.
--
-- 고치는 모양
--   행마다 임의 토큰(cert_token, uuid 122비트)을 두고, 조회는 id + 토큰이
--   **둘 다** 맞아야 한다. 승인(partner_agree)이 토큰을 같이 돌려주고,
--   페이지는 ?cert=<id>&t=<token> 으로 공유한다.
--
--   ⚠ 1인자 판(partner_agreement_get(bigint))은 **항상 거부**로 바꾼다.
--     지우지 않는다 — 지우면 옛 페이지가 404 를, 남기면 ok:false 를 받는다.
--     그래서 이 SQL 을 먼저 돌려도 안전하다: 배포 전에도 구멍은 닫히고,
--     옛 링크는 「토큰 필요」로 멈춘다(열리지 않는 것이 맞다).
--
--   ⚠ 이미 나간 증서 링크(?cert=<id>)는 이 SQL 뒤로 열리지 않는다.
--     파트너에게 새 링크를 다시 보내야 한다 — 슈퍼어드민은 아래 확인 쿼리
--     ③으로 id·토큰을 볼 수 있다.
--
-- 실행: Supabase SQL Editor. 여러 번 돌려도 안전. 페이지(partner/) 배포와 짝.
-- ═══════════════════════════════════════════════════════════════

alter table public.partner_agreements add column if not exists cert_token text;
update public.partner_agreements
   set cert_token = replace(gen_random_uuid()::text, '-', '')
 where cert_token is null;
alter table public.partner_agreements
  alter column cert_token set default replace(gen_random_uuid()::text, '-', '');
create unique index if not exists idx_partner_agreements_token on public.partner_agreements (cert_token);

-- ── 승인 — 같은 시그니처, 토큰을 같이 돌려준다 ──────────────────
create or replace function public.partner_agree(p_code text, p_restaurant text, p_chef text, p_name text, p_ua text default null, p_signature text default null, p_min text default null, p_meal text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare new_id bigint; ts timestamptz; tok text;
begin
  if coalesce(trim(p_name),'') = '' then
    return json_build_object('ok', false, 'error', 'name required');
  end if;
  insert into public.partner_agreements(code, restaurant_name, chef_name, signer_name, user_agent, signature_data, agreed_min, agreed_meal)
  values (nullif(trim(p_code),''), nullif(trim(p_restaurant),''), nullif(trim(p_chef),''), trim(p_name), left(coalesce(p_ua,''),400), p_signature, nullif(trim(p_min),''), nullif(trim(p_meal),''))
  returning id, agreed_at, cert_token into new_id, ts, tok;
  return json_build_object('ok', true, 'id', new_id, 'agreed_at', ts, 'token', tok);
end;
$$;
revoke execute on function public.partner_agree(text,text,text,text,text,text,text,text) from public;
grant  execute on function public.partner_agree(text,text,text,text,text,text,text,text) to anon;
grant  execute on function public.partner_agree(text,text,text,text,text,text,text,text) to authenticated;

-- ── 조회 — id + 토큰. 1인자 판은 항상 거부 ────────────────────────
create or replace function public.partner_agreement_get(p_id bigint)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object('ok', false, 'reason', 'token_required');
$$;
revoke execute on function public.partner_agreement_get(bigint) from public;
grant  execute on function public.partner_agreement_get(bigint) to anon;
grant  execute on function public.partner_agreement_get(bigint) to authenticated;

create or replace function public.partner_agreement_get(p_id bigint, p_token text)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select json_build_object(
        'ok', true,
        'restaurant_name', coalesce(restaurant_name,''),
        'chef_name', coalesce(chef_name,''),
        'signer_name', coalesce(signer_name,''),
        'agreed_at', agreed_at,
        'signature_data', signature_data,
        'agreed_meal', coalesce(agreed_meal,''),
        'agreed_min', coalesce(agreed_min,'')
      )
      from public.partner_agreements
     where id = p_id
       and length(coalesce(p_token,'')) >= 16
       and cert_token = p_token),
    json_build_object('ok', false)
  );
$$;
revoke execute on function public.partner_agreement_get(bigint, text) from public;
grant  execute on function public.partner_agreement_get(bigint, text) to anon;
grant  execute on function public.partner_agreement_get(bigint, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 토큰 없는 행 ⭐' as "구분",
       (select count(*)::text from public.partner_agreements where cert_token is null) || '건',
       '0 이어야 정상' as "메모"
union all
select '② id 만으로 열리나 ⭐',
       case when (public.partner_agreement_get((select min(id) from public.partner_agreements)))->>'ok' = 'true'
            then '❌ 아직 열린다' else '✅ 막힘' end,
       '1인자 조회는 항상 ok:false'
union all
select '③ 다시 보낼 링크 (id · 토큰)',
       coalesce((select string_agg(id || '=' || cert_token, ' / ' order by id) from public.partner_agreements), '(없음)'),
       '?cert=<id>&t=<토큰> — 파트너에게 새 링크로'
 order by 1;
