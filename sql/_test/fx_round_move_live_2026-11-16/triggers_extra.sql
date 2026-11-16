-- 라이브 트리거 정의(2026-11-16 조회) — fx_repurchase triggers.sql 에 없는 것
CREATE TRIGGER trg_sync_ticket_soldout AFTER INSERT OR DELETE OR UPDATE ON public.tickets FOR EACH ROW EXECUTE FUNCTION sync_ticket_soldout();
CREATE TRIGGER trg_taam_guard_text_input BEFORE INSERT OR UPDATE ON public.tickets FOR EACH ROW EXECUTE FUNCTION taam_guard_text_input();
CREATE TRIGGER trg_taam_guard_ticket_crp_member BEFORE UPDATE OF extra_data ON public.tickets FOR EACH ROW EXECUTE FUNCTION taam_guard_ticket_crp_member();
CREATE TRIGGER trg_taam_guard_ticket_linkfacts BEFORE INSERT OR UPDATE ON public.tickets FOR EACH ROW EXECUTE FUNCTION taam_guard_ticket_linkfacts();
CREATE TRIGGER trg_taam_guard_ticket_processed_cardq BEFORE UPDATE OF extra_data ON public.tickets FOR EACH ROW EXECUTE FUNCTION taam_guard_ticket_processed_cardq();
CREATE TRIGGER trg_touch_ticket_product AFTER INSERT OR DELETE OR UPDATE ON public.tickets FOR EACH ROW EXECUTE FUNCTION touch_ticket_product_on_seat_change();
CREATE TRIGGER trg_enforce_ticket_approval BEFORE INSERT OR UPDATE ON public.ticket_products FOR EACH ROW EXECUTE FUNCTION enforce_ticket_approval();
CREATE TRIGGER trg_taam_tp_date_year BEFORE INSERT OR UPDATE OF date ON public.ticket_products FOR EACH ROW EXECUTE FUNCTION _taam_tp_date_year();
CREATE TRIGGER trg_taam_tp_keep_hidden BEFORE UPDATE OF status ON public.ticket_products FOR EACH ROW EXECUTE FUNCTION taam_guard_tp_keep_hidden();
CREATE TRIGGER trg_taam_tp_status_recalc BEFORE INSERT OR UPDATE OF status, total_pax ON public.ticket_products FOR EACH ROW EXECUTE FUNCTION taam_tp_status_recalc();
CREATE TRIGGER trg_taam_guard_invite_host BEFORE INSERT OR UPDATE ON public.reservation_invites FOR EACH ROW EXECUTE FUNCTION taam_guard_invite_host();
CREATE TRIGGER trg_taam_guard_invite_rest BEFORE INSERT OR UPDATE ON public.reservation_invites FOR EACH ROW EXECUTE FUNCTION taam_guard_invite_rest();
CREATE TRIGGER trg_taam_guard_invite_row BEFORE UPDATE ON public.reservation_invites FOR EACH ROW EXECUTE FUNCTION taam_guard_invite_row();
CREATE TRIGGER trg_taam_guard_text_input BEFORE INSERT OR UPDATE ON public.reservation_invites FOR EACH ROW EXECUTE FUNCTION taam_guard_text_input();
CREATE TRIGGER trg_ksk_seat_on_event AFTER UPDATE OF ticket_product_id, event_date, event_time ON public.kashikiri_events FOR EACH ROW EXECUTE FUNCTION taam_ksk_seat_on_event();
-- 클라이언트가 쓰는 표 권한 (라이브: 슈퍼어드민 직접 upsert · 회원 RLS)
alter table public.ticket_products enable row level security;
create policy tp_read on public.ticket_products for select to authenticated, anon using (true);
create policy tp_super_write on public.ticket_products for all to authenticated using (public.is_superadmin()) with check (public.is_superadmin());
alter table public.reservation_invites enable row level security;
create policy ri_all on public.reservation_invites for all to authenticated using (true) with check (true);
grant all on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant execute on all functions in schema public to authenticated, service_role;
