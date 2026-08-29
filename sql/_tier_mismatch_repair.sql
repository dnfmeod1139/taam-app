-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 등급이 프로필에 반영되지 않은 회원 찾기·고치기 (2026-08-29)
-- ═══════════════════════════════════════════════════════════════
-- 무슨 일이 있었나
--   초대코드에 M 등급을 지정해 보내도 가입한 회원은 전부 T 로 들어갔다.
--
--   일반 가입 경로(verify-invite)가 만드는 객체에 등급 칸이 아예 없었다.
--   슈퍼어드민 경로만 invite_codes 원본을 통째로 넘겨 등급이 실려 있었고,
--   실제 회원은 100% 그 경로를 타지 않는다. 그래서 `등급 || 'T'` 가
--   언제나 'T' 로 떨어졌다.
--   게다가 뒤이어 도는 백필은 「등급이 이미 있다」고 판단해 건너뛰므로
--   영영 고쳐지지 않았다.
--
--   앱은 2026.08-29 부터 코드로 invite_codes 를 직접 읽어 확정한다.
--   앞으로는 안 생긴다. 이 파일은 그 이전에 잘못 들어간 회원만 고친다.
--
-- ⚠ 이 파일은 위에서 아래로 통째로 돌리는 파일이 아니다.
--   ①(확인) 을 보고, ②(고칠 문장) 를 눈으로 훑은 뒤 실행한다.
--   값을 바꾸는 블록은 주석 안에 있다 — 쓸 때 /* */ 를 벗긴다.
--
-- 실행: Supabase SQL Editor
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 어긋난 회원 찾기 — 초대는 M/A 인데 프로필은 T
-- ═══════════════════════════════════════════════════════════════
--   초대코드와 회원을 잇는 방법이 세 가지다. 셋 다 본다.
--     · invite_codes.member_id      = profiles.id      (가장 확실)
--     · used_by_email / invitee_email  ↔ profiles.email
--     · used_by_phone / invitee_phone  ↔ profiles.phone (숫자만 비교)
--
--   ⚠ 「고칠 등급」이 비어 있거나 프로필과 같으면 아래 목록에 안 나온다.
--     정상이라는 뜻이다.
with inv as (
  select
    i.code, i.invitee_tier, i.used_at, i.member_id,
    lower(trim(coalesce(nullif(i.used_by_email,''), i.invitee_email, ''))) as em,
    regexp_replace(coalesce(nullif(i.used_by_phone,''), i.invitee_phone, ''), '[^0-9]', '', 'g') as ph
  from public.invite_codes i
  where i.invitee_tier in ('M','A','T')
),
m as (
  select
    p.id, p.display_name, p.membership_tier, p.membership_expires_at, p.created_at,
    i.code, i.invitee_tier, i.used_at,
    -- 무엇으로 이었는지 — 근거가 약한 매칭을 눈으로 걸러낼 수 있게 남긴다
    case
      when i.member_id = p.id then 'member_id'
      when i.em <> '' and i.em = lower(trim(coalesce(p.email,''))) then 'email'
      else 'phone'
    end as matched_by,
    row_number() over (partition by p.id order by i.used_at desc nulls last) as rn
  from public.profiles p
  join inv i
    on  i.member_id = p.id
    or (i.em <> '' and i.em = lower(trim(coalesce(p.email,''))))
    or (length(i.ph) >= 8
        and i.ph = regexp_replace(coalesce(p.phone,''), '[^0-9]', '', 'g'))
)
select
  left(m.id::text, 8)                              as "회원ID앞8",
  coalesce(m.display_name, '(이름없음)')            as "회원",
  m.membership_tier                                as "지금등급",
  m.invitee_tier                                   as "초대등급",
  m.code                                           as "초대코드",
  m.matched_by                                     as "매칭근거",
  to_char(m.created_at, 'YY-MM-DD')                as "가입일",
  case when m.membership_expires_at is null then '없음'
       else to_char(m.membership_expires_at, 'YY-MM-DD') end as "멤버십만료",
  case
    when m.matched_by = 'phone' then '⚠ 전화번호로만 이었다 — 사람 확인 후 적용'
    else '✅ 고칠 수 있음'
  end                                              as "판정"
from m
where m.rn = 1
  and m.invitee_tier is distinct from m.membership_tier
order by
  case m.matched_by when 'member_id' then 0 when 'email' then 1 else 2 end,
  m.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ② 고칠 문장 만들기 — 여기서는 실행되지 않는다
-- ═══════════════════════════════════════════════════════════════
--   ① 에서 「✅ 고칠 수 있음」인 줄만 문장을 만든다.
--   전화번호로만 이어진 건은 제외했다 — 번호가 겹치거나 바뀌었을 수 있어
--   사람이 확인하고 손으로 고치는 편이 안전하다.
--
--   M 등급은 멤버십 만료일도 같이 넣는다 (가입일 + 365일, 현재 정책).
--   이미 만료일이 있으면 건드리지 않는다.
with inv as (
  select
    i.code, i.invitee_tier, i.used_at, i.member_id,
    lower(trim(coalesce(nullif(i.used_by_email,''), i.invitee_email, ''))) as em
  from public.invite_codes i
  where i.invitee_tier in ('M','A','T')
),
m as (
  select
    p.id, p.display_name, p.membership_tier, p.membership_expires_at, p.created_at,
    i.code, i.invitee_tier,
    row_number() over (partition by p.id order by i.used_at desc nulls last) as rn
  from public.profiles p
  join inv i
    on  i.member_id = p.id
    or (i.em <> '' and i.em = lower(trim(coalesce(p.email,''))))
)
select
  coalesce(m.display_name, left(m.id::text,8))     as "회원",
  m.membership_tier || ' → ' || m.invitee_tier      as "무엇을",
  m.code                                            as "근거코드",
  'update public.profiles set membership_tier = ''' || m.invitee_tier || ''''
    || case when m.invitee_tier = 'M' and m.membership_expires_at is null
            then ', membership_expires_at = '''
                 || to_char(m.created_at + interval '365 days', 'YYYY-MM-DD"T"HH24:MI:SSOF') || ''''
            else '' end
    || ' where id = ''' || m.id::text || ''';'      as "실행문"
from m
where m.rn = 1
  and m.invitee_tier is distinct from m.membership_tier
order by m.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ③ 되돌리기 — 잘못 바꿨을 때
-- ═══════════════════════════════════════════════════════════════
--   ② 를 돌리기 전에 ① 결과를 캡처해 두면 그대로 되돌릴 수 있다.
--   등급 하나만 바꾸는 일이라 아래 형태로 한 명씩 원복하면 된다.
/*
update public.profiles
   set membership_tier = 'T', membership_expires_at = null
 where id = '여기에-회원-UUID';
*/


-- ═══════════════════════════════════════════════════════════════
-- ④ 확인 — 고친 뒤 다시 ① 을 돌린다. 0 건이면 끝이다
-- ═══════════════════════════════════════════════════════════════
select membership_tier as "등급", count(*) as "인원"
from public.profiles
group by membership_tier
order by 1;
