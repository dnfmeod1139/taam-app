-- 진단 5(읽기 전용) — 새 제목 테스트 2건(request 123 · 124 · 슈퍼어드민만)의 send-push 응답 (2026-10-27)
create temp table _vr5(seq serial, 구분 text, 내용 text);
do $do$
declare h record; j jsonb; k bigint;
begin
  foreach k in array array[123, 124] loop
    begin
      select * into h from net._http_response where id = k;
      if not found then insert into _vr5(구분, 내용) values ('요청 ' || k, '⚠ 응답 줄이 없다'); continue; end if;
      begin j := h.content::jsonb; exception when others then j := null; end;
      insert into _vr5(구분, 내용) values (case k when 123 then '3일 전 테스트(123)' else '하루 전 테스트(124)' end,
        'HTTP ' || coalesce(h.status_code::text, '-') || ' · '
        || case when j is not null then '시도 ' || coalesce(j->'summary'->>'attempted', '-') || ' · 성공 ' || coalesce(j->'summary'->>'ok', '-') || ' · 실패 ' || coalesce(j->'summary'->>'failed', '-') || ' · 건너뜀 ' || coalesce(j->'summary'->>'skipped', '-')
                else left(coalesce(h.content, h.error_msg, ''), 160) end);
    exception when others then insert into _vr5(구분, 내용) values ('요청 ' || k, '⚠ 못 읽음: ' || left(sqlerrm, 120)); end;
  end loop;
end $do$;
select 구분, 내용 from _vr5 order by seq;
