-- ═══════════════════════════════════════════════════════════════
-- 비회원 결제 손님 → 게스트 회원 초대 · 가입하면 티켓이 그 계정에 붙는다 (2026-10-19)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN. 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 결제 링크로 카드 결제한 비회원 손님은 앱 계정이 없어 리마인드(푸시)도 못 받고 다음 예약도 직접 못 한다. 결제 직후가 가입 권유가 가장 잘 되는
--     순간이라(결제 완료 화면 「멤버십 알아보기」), 그 자리에서 **게스트 회원(A 등급 · 90일)** 초대 코드를 바로 준다. 가입하면 결제한 티켓이 그 계정의 것이 되어
--     푸시 리마인드·구매내역·멤버십 시작일(첫 구매)에 들어간다.
-- 무엇:
--   ① trg_taam_guest_invite_on_paid (kashikiri_charges AFTER UPDATE OF status): 티켓 링크(link_invite) 결제가 paid 가 되고 회원이 아니고(user_id null) 결제자 번호가 있으면
--      invite_codes 에 게스트 초대장(invitee_tier 'A' · invitee_phone = 결제자 번호 · invited_by 'pay_link' · 30일 만료)을 만들고 코드를 payload.guest_invite_code 에 적는다.
--      같은 번호에 아직 안 쓴 게스트 초대장이 있으면 그 코드를 다시 쓴다. 실패해도 결제 확정은 막지 않는다(warning).
--   ② taam_kashikiri_charge_public 이 paid·비회원 청구에 guest_invite {code, expires_at} 를 함께 준다 → /pay 완료 화면이 「게스트 회원으로 가입」을 그린다(앱 링크 /?invite=코드).
--      ⚠ 라이브 함수 교체 — md5 가 저장소 원본(20261018_pay_link.sql 판)과 같을 때만.
--   ③ 가입하면 티켓을 붙인다 — taam_guest_attach_tickets(uid, code, phone): 그 청구의 LINK- 좌석 행(active · memberUid 없음)의 user_id 를 새 회원으로 바꾸고
--      extra_data.memberUid 를 적는다(그 뒤로는 회원 행 — 리마인드·중복 가드·구매내역이 본다). 청구의 user_id·payload.member_uid 도 맞춘다.
--      부르는 곳: trg_taam_guest_attach_on_invite_used(invite_codes · used 가 true 로 바뀔 때 — consume-invite Edge · 코드로 회원을 찾는다) ·
--                 trg_taam_guest_attach_on_profile(profiles AFTER INSERT · 가입한 번호와 결제자 번호가 같은 게스트 초대 청구). 둘 다 실패를 삼킨다(가입을 막지 않는다).
-- 지키는 것: 초대장은 번호에 묶인다(초대장에 적힌 번호와 가입 OTP 번호가 같아야 — 가입 문지기 trg_taam_guard_signup · consume-invite 가 대조) · 등급은 'A'(게스트 · 90일 · 서버 가드가 초대코드 값으로만 올린다) ·
--     예치금·원장은 건드리지 않는다 · 티켓 소유 이전은 security definer 안에서(행 가드는 서버 호출로 통과) · 회원 세션이 직접 쓰는 길은 없다(함수 execute 는 서버만).
-- 회귀: bash sql/_test/t_guest_invite.sh
-- ═══════════════════════════════════════════════════════════════

-- ── 0) 코드 생성 — 'G' + 7자 (헷갈리는 글자 0/O/1/I 제외) · 앱 코드 입력칸 8자 ──
create or replace function public._taam_guest_invite_code()
returns text language plpgsql volatile as $$
declare v text; i int := 0; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  loop
    v := 'G';
    for i in 1..7 loop v := v || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from public.invite_codes c where c.code = v);
  end loop;
  return v;
end $$;

-- ── 1) 결제되면 게스트 초대장 ──
create or replace function public.taam_guest_invite_on_paid()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_digits text; v_key text; v_code text; v_kr boolean; v_exp_type text; v_inv_type text; v_exp timestamptz := now() + interval '30 days';
  v_exp_sql text; v_inv_sql text; v_exp_txt text;
begin
  if new.status <> 'paid' or coalesce(old.status, '') = 'paid' then return new; end if;
  if not coalesce(new.link_invite, false) then return new; end if;
  if new.user_id is not null or nullif(new.payload->>'member_uid', '') is not null then return new; end if;   -- 회원 링크는 소유 이전이 따로 간다
  if nullif(new.payload->>'guest_invite_code', '') is not null then return new; end if;
  begin
    if to_regclass('public.invite_codes') is null then return new; end if;
    v_digits := regexp_replace(coalesce(new.payer_phone, ''), '[^0-9]', '', 'g');
    if length(v_digits) < 9 then return new; end if;
    v_key := regexp_replace(regexp_replace(v_digits, '^82', ''), '^0+', '');
    v_kr  := v_digits ~ '^(0?1[016789]|821[016789])';
    -- 같은 번호의 살아 있는(안 쓴·안 지난) 게스트 초대장이 있으면 재사용
    select c.code into v_code
      from public.invite_codes c
     where coalesce(c.used, false) = false
       and c.invitee_tier = 'A'
       and regexp_replace(regexp_replace(regexp_replace(coalesce(c.invitee_phone, ''), '[^0-9]', '', 'g'), '^82', ''), '^0+', '') = v_key
       and (public._taam_ts_safe(c.expires_at::text) is null or public._taam_ts_safe(c.expires_at::text) > now())
     order by c.invited_at desc nulls last limit 1;
    if v_code is null then
      v_code := public._taam_guest_invite_code();
      select data_type into v_exp_type from information_schema.columns where table_schema = 'public' and table_name = 'invite_codes' and column_name = 'expires_at';
      select data_type into v_inv_type from information_schema.columns where table_schema = 'public' and table_name = 'invite_codes' and column_name = 'invited_at';
      v_exp_txt := to_char(v_exp at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
      v_exp_sql := case when v_exp_type like 'timestamp%' then quote_literal(v_exp::text) || '::timestamptz' else quote_literal(v_exp_txt) end;
      v_inv_sql := case when v_inv_type like 'timestamp%' then 'now()' else quote_literal(to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) end;
      execute format(
        'insert into public.invite_codes (code, type, country, invitee_name, invitee_phone, invitee_email, invitee_tier, invite_message, invited_by, invited_at, expires_at, used) values (%L, %L, %L, %L, %L, %L, %L, %L, %L, %s, %s, false)',
        v_code, 'signup', case when v_kr then 'KR' else 'EN' end, left(coalesce(nullif(btrim(new.label), ''), nullif(btrim(new.payer_name), ''), '게스트'), 40),
        new.payer_phone, '', 'A', 'TAAM 결제 링크 손님 게스트 초대 (결제 ' || to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD') || ')', 'pay_link', v_inv_sql, v_exp_sql);
    end if;
    update public.kashikiri_charges
       set payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('guest_invite_code', v_code, 'guest_invite_expires', v_exp_txt)
     where id = new.id;
  exception when others then
    raise warning '[guest_invite] 초대장 만들기 실패 (결제는 유지): % %', sqlstate, sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists trg_taam_guest_invite_on_paid on public.kashikiri_charges;
create trigger trg_taam_guest_invite_on_paid after update of status on public.kashikiri_charges
  for each row execute function public.taam_guest_invite_on_paid();

-- ── 2) /pay 읽기 — guest_invite 를 함께 (라이브 함수 · md5 가드) ──
drop table if exists _gi; create temp table _gi(name text primary key, status text);
do $do$
declare v_live text;
begin
  select md5(p.prosrc) into v_live from pg_proc p where p.oid = to_regproc('public.taam_kashikiri_charge_public');
  if v_live is null then insert into _gi values ('taam_kashikiri_charge_public', '❌ 함수 없음 — 20261018_pay_link.sql 먼저');
  elsif v_live <> 'ad41b46f50cff2582cd82ca66f521aff' then insert into _gi values ('taam_kashikiri_charge_public', '❌ 라이브 본문이 저장소 원본(20261018_pay_link.sql 판)과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  else
    execute $fn$
create or replace function public.taam_kashikiri_charge_public(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $b$
declare v jsonb;
begin
  if p_token is null or length(p_token) < 16 then return null; end if;
  select jsonb_build_object(
    'id',           c.id,
    'label',        c.label,
    'purpose',      coalesce(c.purpose, 'custom'),
    'title',        c.title,
    'subtitle',     c.subtitle,
    'amount_krw',   c.amount_krw,
    'amount_jpy',   c.amount_jpy,
    'pay_currency', coalesce(c.pay_currency, 'KRW'),
    'pay_amount',   coalesce(c.pay_amount, c.amount_krw),
    'pay_fx',       c.pay_fx,
    'status',       c.status,
    'expires_at',   c.expires_at,
    'paid_at',      c.approved_at,
    'receipt_url',  c.receipt_url,
    'venue_name',   coalesce(e.venue_name, c.title),
    'venue_name_en', nullif(btrim(coalesce(r.name_en, '')), ''),
    'venue_name_jp', nullif(btrim(coalesce(r.name_jp, '')), ''),
    'event_date',   e.event_date,
    'event_time',   e.event_time,
    'fx_rate',      e.fx_rate,
    'fx_note',      e.fx_note,
    'team_seq',     t.seq,
    'team_pax',     t.pax,
    'split_count', case
      when c.team_id is not null then (select count(*) from public.kashikiri_charges x where x.team_id = c.team_id and x.status <> 'cancelled')
      when c.event_id is not null then (select count(*) from public.kashikiri_charges x where x.event_id = c.event_id and x.status <> 'cancelled')
      else 1 end,
    'mship', case when c.purpose = 'membership' then jsonb_build_object('tier', c.payload->>'tier', 'kind', c.payload->>'kind') end,
    -- 🆕 2026-10-19 비회원 티켓 결제가 끝나면 게스트 회원 초대 코드를 함께 준다(결제 완료 화면의 「게스트 회원 가입」) — 결제된 뒤, 회원이 아닌 청구에만
    'guest_invite', case when c.status = 'paid' and c.user_id is null and nullif(c.payload->>'guest_invite_code', '') is not null
                         then jsonb_build_object('code', c.payload->>'guest_invite_code', 'expires_at', c.payload->>'guest_invite_expires') end
  ) into v
  from public.kashikiri_charges c
  left join public.kashikiri_events e on e.id = c.event_id
  left join public.kashikiri_teams t on t.id = c.team_id
  left join public.restaurants r on r.id::text = e.venue_id
  where c.token = p_token;
  return v;
end $b$
    $fn$;
    insert into _gi values ('taam_kashikiri_charge_public', '✅ 교체');
  end if;
end $do$;

-- ── 3) 가입하면 티켓을 붙인다 ──
create or replace function public.taam_guest_attach_tickets(p_uid uuid, p_code text default null, p_phone text default null)
returns int language plpgsql volatile security definer set search_path = public as $$
declare v_key text; v_n int := 0; r record;
begin
  if p_uid is null then return 0; end if;
  v_key := regexp_replace(regexp_replace(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), '^82', ''), '^0+', '');
  for r in
    select c.id as charge_id
      from public.kashikiri_charges c
     where coalesce(c.link_invite, false) and c.status = 'paid' and c.user_id is null
       and nullif(c.payload->>'guest_invite_code', '') is not null
       and ( (p_code is not null and c.payload->>'guest_invite_code' = p_code)
          or (length(v_key) >= 8 and regexp_replace(regexp_replace(regexp_replace(coalesce(c.payer_phone, ''), '[^0-9]', '', 'g'), '^82', ''), '^0+', '') = v_key) )
  loop
    update public.tickets t
       set user_id = p_uid,
           extra_data = coalesce(t.extra_data, '{}'::jsonb) || jsonb_build_object('memberUid', p_uid, 'attachedBy', 'guest_signup', 'attachedAt', now())
     where t.purchase_id like 'LINK-%' and t.extra_data->>'chargeId' = r.charge_id::text
       and lower(coalesce(t.status, '')) = 'active' and nullif(t.extra_data->>'memberUid', '') is null;
    v_n := v_n + 1;
    update public.kashikiri_charges
       set user_id = p_uid, payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('member_uid', p_uid, 'member_name', (select display_name from public.profiles where id = p_uid), 'attached_by', 'guest_signup')
     where id = r.charge_id;
  end loop;
  return v_n;
end $$;
revoke all on function public.taam_guest_attach_tickets(uuid, text, text) from public, anon, authenticated;

create or replace function public.taam_guest_attach_on_invite_used()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_key text;
begin
  if not coalesce(new.used, false) or coalesce(old.used, false) then return new; end if;
  if coalesce(new.invited_by, '') <> 'pay_link' or coalesce(new.invitee_tier, '') <> 'A' then return new; end if;
  begin
    v_key := regexp_replace(regexp_replace(regexp_replace(coalesce(nullif(new.used_by_phone, ''), new.invitee_phone, ''), '[^0-9]', '', 'g'), '^82', ''), '^0+', '');
    if length(v_key) >= 8 then
      select p.id into v_uid from public.profiles p
       where regexp_replace(regexp_replace(regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g'), '^82', ''), '^0+', '') = v_key
       order by p.created_at desc nulls last limit 1;
    end if;
    if v_uid is not null then perform public.taam_guest_attach_tickets(v_uid, new.code, coalesce(nullif(new.used_by_phone, ''), new.invitee_phone)); end if;
  exception when others then
    raise warning '[guest_invite] 가입 뒤 티켓 붙이기 실패 (초대 사용 표시는 유지): % %', sqlstate, sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists trg_taam_guest_attach_on_invite_used on public.invite_codes;
create trigger trg_taam_guest_attach_on_invite_used after update of used on public.invite_codes
  for each row execute function public.taam_guest_attach_on_invite_used();

create or replace function public.taam_guest_attach_on_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if nullif(new.phone, '') is null then return new; end if;
  begin perform public.taam_guest_attach_tickets(new.id, null, new.phone);
  exception when others then raise warning '[guest_invite] 가입 직후 티켓 붙이기 실패 (가입은 유지): % %', sqlstate, sqlerrm; end;
  return new;
end $$;
drop trigger if exists trg_taam_guest_attach_on_profile on public.profiles;
create trigger trg_taam_guest_attach_on_profile after insert on public.profiles
  for each row execute function public.taam_guest_attach_on_profile();

-- ── 확인 — 한 표 ──
select '① /pay 읽기 함수 교체' as 항목, status as 결과 from _gi
union all select '② 트리거 셋 (결제→초대장 · 초대 사용→붙이기 · 가입→붙이기)',
       case when (select count(*) from pg_trigger where tgname in ('trg_taam_guest_invite_on_paid','trg_taam_guest_attach_on_invite_used','trg_taam_guest_attach_on_profile') and not tgisinternal) = 3 then '✅' else '❌' end
union all select '③ 의존 — invite_codes(invitee_tier·invitee_phone·invited_by) · _taam_ts_safe · tickets.extra_data',
       case when to_regclass('public.invite_codes') is not null and to_regproc('public._taam_ts_safe') is not null
             and (select count(*) from information_schema.columns where table_schema='public' and table_name='invite_codes' and column_name in ('invitee_tier','invitee_phone','invited_by','used')) = 4 then '✅' else '❌ sql/signup_guard.sql · invite_codes 컬럼 확인' end
union all select '④ 공개 RPC 가 guest_invite 를 준다', case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_charge_public') and prosrc like '%guest_invite%') then '✅' else '❌' end
union all select '⑤ 붙이기 함수는 서버만', case when has_function_privilege('authenticated', 'public.taam_guest_attach_tickets(uuid,text,text)', 'execute') or has_function_privilege('anon', 'public.taam_guest_attach_tickets(uuid,text,text)', 'execute') then '❌' else '✅' end
order by 1;
