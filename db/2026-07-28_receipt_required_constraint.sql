-- ================================================================
--  SPRINTERS OS · Migración v1.4 · Comprobante obligatorio (constraint)
--  PostgreSQL 15 / Supabase · 2026-07-28
--
--  REQUISITO: 2026-07-13_events_transfer_receipts.sql y
--             2026-07-28_running_transfer_and_afterrun_price.sql ya aplicadas.
--  ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR:
--    python db/sb_mgmt.py migrate db/2026-07-28_receipt_required_constraint.sql
--
--  ALCANCE:
--    Hoy el "comprobante obligatorio" solo se garantizaba en el frontend
--    (el botón de confirmar quedaba deshabilitado sin archivo). Esto lo
--    blinda también en la base: ninguna fila de event_registrations ni de
--    subscriptions puede quedar en pending_review/verified/rejected sin
--    receipt_url cargado. Si algún código (frontend, función, panel admin)
--    intenta guardar ese estado sin comprobante, Postgres lo rechaza.
-- ================================================================

DO $$ BEGIN
  ALTER TABLE public.event_registrations
    ADD CONSTRAINT chk_event_reg_receipt_required
    CHECK (payment_status = 'not_required' OR receipt_url IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.subscriptions
    ADD CONSTRAINT chk_sub_receipt_required
    CHECK (payment_status = 'not_required' OR receipt_url IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON CONSTRAINT chk_event_reg_receipt_required ON public.event_registrations IS
  'Comprobante obligatorio: no se puede pasar de not_required (evento gratis / recién reservado) '
  'a pending_review/verified/rejected sin receipt_url. Refuerza a nivel de base lo que ya exige el frontend.';
COMMENT ON CONSTRAINT chk_sub_receipt_required ON public.subscriptions IS
  'Mismo criterio que event_registrations: comprobante obligatorio para cualquier estado que no sea not_required.';
