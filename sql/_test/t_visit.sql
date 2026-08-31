do $$ begin
  if not exists(select 1 from pg_roles where rolname='authenticated') then
    create role authenticated; end if;
end $$;
grant usage on schema public, auth to authenticated;
grant select, insert, update on all tables in schema public to authenticated;
grant execute on all functions in schema public, auth to authenticated;

-- 배우들
insert into auth.users(id) values
 ('11111111-1111-1111-1111-111111111111'),  -- 회원
 ('22222222-2222-2222-2222-222222222222'),  -- 그 매장 어드민
 ('33333333-3333-3333-3333-333333333333'),  -- 다른 매장 어드민
 ('99999999-9999-9999-9999-999999999999') on conflict do nothing;  -- 슈퍼어드민
insert into public.profiles(id,role,display_name) values
 ('11111111-1111-1111-1111-111111111111','member','회원'),
 ('22222222-2222-2222-2222-222222222222','admin','우리매장어드민'),
 ('33333333-3333-3333-3333-333333333333','admin','남의매장어드민'),
 ('99999999-9999-9999-9999-999999999999','super_admin','슈퍼') on conflict (id) do nothing;
insert into public.restaurants(id,name) values
 ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','우리매장'),
 ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','남의매장') on conflict (id) do nothing;
insert into public.restaurant_admins(user_id,restaurant_id) values
 ('22222222-2222-2222-2222-222222222222','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
 ('33333333-3333-3333-3333-333333333333','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

insert into public.tickets(id,user_id,restaurant_id,purchase_id,status,price,reservation_date) values
 ('d0000001-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','P1','active',100000,'2026-08-01'),
 ('d0000002-0000-4000-8000-000000000002','11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','P2','active',100000,'2026-12-25'),
 ('d0000003-0000-4000-8000-000000000003','11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','P3','cancelled',100000,'2026-08-02'),
 ('d0000004-0000-4000-8000-000000000004','11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','P4','manual',0,'수동입력');
insert into public.reservation_requests(user_id,venue_id,visit_status,reserve_date) values
 ('11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','attended','2026-07-01');
