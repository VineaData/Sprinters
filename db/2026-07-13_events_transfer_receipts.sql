-- ================================================================
--  SPRINTERS OS · Migración v1.2 · Transferencia + comprobante para eventos
--  PostgreSQL 15 / Supabase · 2026-07-13
--
--  REQUISITO: v1.0.0 (.claude/sprinters-schema.sql) y v1.1.0
--             (db/2026-06-25_schema_v1.1_running_social.sql) ya aplicadas.
--             Este script es ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR (elegí una):
--    A) python db/sb_mgmt.py migrate db/2026-07-13_events_transfer_receipts.sql
--    B) Supabase Dashboard → SQL Editor → New query → pegar completo → Run
--    Verificar después: Table Editor (events / event_registrations con
--    columnas nuevas) y Storage (bucket 'payment-receipts', privado).
--
--  ALCANCE:
--    Se saca Mercado Pago del flujo de EVENTOS (Flujo B del doc de MP
--    quedaba bloqueado por el onboarding Marketplace de cada local — ver
--    "Sprinters Web - Mercado Pago.md"). En su lugar: el usuario transfiere
--    y sube el comprobante; un admin lo revisa y aprueba manualmente.
--    (Las suscripciones mensuales Running/Social siguen con Mercado Pago,
--    eso no cambia acá.)
--
--    Además se agregan a events los campos que la vista de detalle del
--    evento necesita (descripción, itinerario, after-run, badge Pro) que
--    "Sprinters Web - Plan Rediseño v2.md" ya tenía listados como pendientes.
-- ================================================================


-- ================================================================
-- 1. EVENTS — campos para la vista de detalle
-- ================================================================
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS description             TEXT,
  ADD COLUMN IF NOT EXISTS itinerary                JSONB   NOT NULL DEFAULT '[]',  -- [{time,label}]
  ADD COLUMN IF NOT EXISTS has_after_run            BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS included_in_running_pro  BOOLEAN NOT NULL DEFAULT FALSE; -- badge "incluido en Pro"

COMMENT ON COLUMN public.events.itinerary IS
  'Itinerario del evento en orden. Cada item: {"time":"09:30","label":"Salida Prado Español"}.';
COMMENT ON COLUMN public.events.included_in_running_pro IS
  'Si TRUE, los usuarios con Training Pro activo entran sin costo (badge en la vista de evento).';


-- ================================================================
-- 2. ESTADO DE REVISIÓN DE COMPROBANTE (transferencia manual)
-- ================================================================
DO $$ BEGIN
  CREATE TYPE payment_review_status_type AS ENUM ('not_required', 'pending_review', 'verified', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ================================================================
-- 3. EVENT_REGISTRATIONS — after-run + comprobante de transferencia
-- ================================================================
ALTER TABLE public.event_registrations
  ADD COLUMN IF NOT EXISTS after_run            BOOLEAN                     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS receipt_url           TEXT,                                              -- bucket privado 'payment-receipts'
  ADD COLUMN IF NOT EXISTS receipt_uploaded_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS payment_status        payment_review_status_type NOT NULL DEFAULT 'not_required',
  ADD COLUMN IF NOT EXISTS payment_reviewed_by   UUID                        REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS payment_reviewed_at   TIMESTAMPTZ;

COMMENT ON COLUMN public.event_registrations.payment_status IS
  'not_required: evento gratis o sin costo para este usuario. pending_review: subió comprobante, '
  'falta que un admin lo revise. verified/rejected: resultado de la revisión manual. '
  'Solo cambia vía submit_event_receipt() / review_event_payment() — el usuario NO puede setearlo directo.';


-- ================================================================
-- 4. BLINDAJE DE PRIVILEGIOS (mismo problema que users en v1.1 — sección 0)
--    El GRANT UPDATE de tabla completa dejaría que cualquier usuario se
--    auto-apruebe el pago (payment_status = 'verified') sin que nadie lo
--    revise. Restringimos el UPDATE directo a las columnas que el usuario
--    puede tocar por sí mismo; el resto solo vía función SECURITY DEFINER.
-- ================================================================
REVOKE UPDATE ON public.event_registrations FROM authenticated;
GRANT UPDATE (after_run) ON public.event_registrations TO authenticated;


-- ================================================================
-- 5. FUNCIONES — mismo patrón que submit_med_cert() / review_med_cert()
-- ================================================================

-- El usuario sube su comprobante y queda a la espera de revisión.
CREATE OR REPLACE FUNCTION public.submit_event_receipt(reg_id UUID, receipt_path TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.event_registrations
     SET receipt_url = receipt_path,
         receipt_uploaded_at = NOW(),
         payment_status = 'pending_review'
   WHERE id = reg_id
     AND user_id = (SELECT auth.uid());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Inscripción no encontrada o no te pertenece';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.submit_event_receipt IS
  'Llamada por el usuario autenticado al subir su comprobante de transferencia. '
  'Solo puede tocar su propia inscripción (reg_id debe ser suya).';

-- Un admin aprueba o rechaza el comprobante.
CREATE OR REPLACE FUNCTION public.review_event_payment(reg_id UUID, approve BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = (SELECT auth.uid()) AND u.is_admin) THEN
    RAISE EXCEPTION 'Solo un admin puede revisar comprobantes';
  END IF;

  UPDATE public.event_registrations
     SET payment_status = CASE WHEN approve THEN 'verified' ELSE 'rejected' END,
         payment_reviewed_by = (SELECT auth.uid()),
         payment_reviewed_at = NOW()
   WHERE id = reg_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Inscripción no encontrada';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.review_event_payment IS
  'Panel admin: aprueba o rechaza un comprobante de transferencia ya subido.';

GRANT EXECUTE ON FUNCTION public.submit_event_receipt(UUID, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_event_payment(UUID, BOOLEAN) TO authenticated; -- valida is_admin adentro


-- ================================================================
-- 6. STORAGE — bucket privado para comprobantes
--    Mismo patrón que 'medical-certs' (v1.1): carpeta por usuario,
--    lectura propia + admin, sin acceso público.
-- ================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('payment-receipts', 'payment-receipts', FALSE)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "receipts_insert_own" ON storage.objects;
CREATE POLICY "receipts_insert_own"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'payment-receipts'
    AND (storage.foldername(name))[1] = (select auth.uid())::text
  );

DROP POLICY IF EXISTS "receipts_select_own_or_admin" ON storage.objects;
CREATE POLICY "receipts_select_own_or_admin"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'payment-receipts'
    AND (
      (storage.foldername(name))[1] = (select auth.uid())::text
      OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = (select auth.uid()) AND u.is_admin)
    )
  );

-- No hay UPDATE/DELETE: un comprobante subido no se edita, se vuelve a subir
-- (nueva fila / nuevo archivo) si un admin lo rechaza.


-- ================================================================
-- 7. VERIFICACIÓN RÁPIDA (comentado — correr a mano si querés confirmar)
-- ================================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'events' AND column_name IN ('description','itinerary','has_after_run','included_in_running_pro');
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'event_registrations' AND column_name LIKE 'payment%' OR column_name LIKE 'receipt%';
-- SELECT id, public FROM storage.buckets WHERE id = 'payment-receipts';
