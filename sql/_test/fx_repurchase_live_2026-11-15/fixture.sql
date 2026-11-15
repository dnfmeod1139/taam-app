create schema auth; create table auth.users(id uuid primary key);
do $$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
             if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
             if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role bypassrls; end if; end $$;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('taam.uid', true),'')::uuid $$;
create table public.profiles(id uuid primary key, role text, single_device_exempt boolean default false, display_name text);
create table public.restaurants(id uuid primary key, name text, repurchase_day int);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, status text default 'active',
  repurchase_open boolean not null default false, repurchase_open_at timestamptz);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text,
  ticket_product_id text, ticket_type text, reservation_date text, visit_time text, party_size int default 2, price int default 0,
  status text default 'hold', purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now(), buyer_name text);
create table public.purchase_rule_exceptions(id uuid primary key default gen_random_uuid(), user_id uuid, ticket_product_id text,
  allow_dup boolean default false, allow_time boolean default false, extra int default 1, expires_at timestamptz, revoked_at timestamptz, created_at timestamptz default now());
create table public.purchase_rule_exception_uses(exception_id uuid, user_id uuid, ticket_product_id text, purchase_id text, kind text,
  constraint preu_once unique (exception_id, purchase_id, kind));
-- live bodies (pg_get_functiondef output) for helpers not in repo md5 scan
CREATE OR REPLACE FUNCTION public._taam_uid_is_super() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ select exists ( select 1 from public.profiles p where p.id = auth.uid() and p.role in ('super_admin','superadmin') ) $function$;
CREATE OR REPLACE FUNCTION public.is_super_admin(uid uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ select coalesce((select role in ('super_admin', 'superadmin') from public.profiles where id = uid), false); $function$;
CREATE OR REPLACE FUNCTION public.is_superadmin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ select coalesce((select role in ('super_admin','superadmin') from public.profiles where id = auth.uid()), false); $function$;
-- partner approval stubs (no partners in these tests)
create or replace function public.taam_rest_admin_ok(p text) returns boolean language sql stable as $$ select false $$;
create or replace function public._taam_tp_seat_check(a text, b text) returns text language sql stable as $$ select 'ok' $$;
