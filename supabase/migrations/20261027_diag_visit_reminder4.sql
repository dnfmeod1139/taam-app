-- ═══════════════════════════════════════════════════════════════
-- 진단 4(읽기 전용) — 진단 3 에서 보낸 두 요청의 응답 (2026-10-27)
--   121 두 번째 테스트 푸시(새 send-push · 슈퍼어드민만) · 122 Edge notify-visit-reminder 실제 경로(ver · made · push · guest)
-- ═══════════════════════════════════════════════════════════════
create temp table _vr4(seq serial, 구분 text, 내용 text);
do $do$
declare h record; j jsonb; k bigint;
begin
  foreach k in array array[121, 122] loop
    begin
      select * into h from net._http_response where id = k;
      if not found then insert into _vr4(구분, 내용) values ('요청 ' || k, '⚠ 응답 줄이 없다'); continue; end if;
      begin j := h.content::jsonb; exception when others then j := null; end;
      insert into _vr4(구분, 내용) values (case k when 121 then '두 번째 테스트 푸시(121)' else 'Edge 실제 경로(122)' end,
        'HTTP ' || coalesce(h.status_code::text, '-') || ' · '
        || case when k = 121 and j is not null then '시도 ' || coalesce(j->'summary'->>'attempted', '-') || ' · 성공 ' || coalesce(j->'summary'->>'ok', '-') || ' · 실패 ' || coalesce(j->'summary'->>'failed', '-')
                when k = 122 and j is not null then 'ver ' || coalesce(j->>'ver', '(없음 — 옛 판)') || ' · ok ' || coalesce(j->>'ok', '-') || ' · made ' || coalesce(j->>'made', '-')
                     || ' · push ' || coalesce(j->>'push_sent', '-') || '/' || coalesce(j->>'push_failed', '-') || ' · 알림톡 ' || left(coalesce((j->'guest')::text, '-'), 120)
                else left(coalesce(h.content, h.error_msg, ''), 160) end);
    exception when others then insert into _vr4(구분, 내용) values ('요청 ' || k, '⚠ 못 읽음: ' || left(sqlerrm, 120)); end;
  end loop;
end $do$;
select 구분, 내용 from _vr4 order by seq;
