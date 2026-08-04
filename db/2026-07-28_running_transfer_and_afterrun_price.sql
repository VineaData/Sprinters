-- ================================================================
--  SPRINTERS OS · Migración v1.3 · Transferencia para Running + precio After-Run
--  PostgreSQL 15 / Supabase · 2026-07-28
--
--  REQUISITO: v1.0.0, v1.1.0 y v1.2 (2026-07-13_events_transfer_receipts.sql)
--             ya aplicadas (esta última crea el ENUM payment_review_status_type
--             y el bucket privado 'payment-receipts' que reutilizamos acá).
--             Este script es ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR:
--    python db/sb_mgmt.py migrate db/2026-07-28_running_transfer_and_afterrun_price.sql
--
--  ALCANCE:
--    1) Se saca Mercado Pago del flujo de Running Team. Alta y renovación de
--       Training Core / Training Pro pasan a ser por transferencia +
--       comprobante, revisado a mano — mismo criterio que ya se aplicó a
--       eventos (Social sigue en pausa, no se toca acá).
--    2) Se agrega un precio opcional de "after run" a events, separado del
--       base_price, para que la vista de evento pueda mostrar los dos montos
--       y el total cuando el usuario elige quedarse al after run.
-- ================================================================


-- ================================================================
-- 1. SUBSCRIPTIONS — comprobante de transferencia (mismo patrón que
--    event_registrations en la migración v1.2)
-- ================================================================
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS receipt_url          TEXT,                                              -- bucket privado 'payment-receipts' (compartido con eventos)
  ADD COLUMN IF NOT EXISTS receipt_uploaded_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS payment_status       payment_review_status_type NOT NULL DEFAULT 'not_required',
  ADD COLUMN IF NOT EXISTS payment_reviewed_by  UUID                        REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS payment_reviewed_at  TIMESTAMPTZ;

COMMENT ON COLUMN public.subscriptions.payment_status IS
  'not_required: fila recién creada, todavía no subió comprobante. pending_review: subió comprobante, '
  'falta que un admin lo revise. verified: admin aprobó → dispara status=active + current_period_end. '
  'rejected: admin rechazó, puede volver a subir. Solo cambia vía submit_subscription_receipt() / '
  'review_subscription_payment() — el usuario NO puede setearlo directo.';


-- ================================================================
-- 2. FUNCIONES — mismo patrón que submit_event_receipt() / review_event_payment()
-- ================================================================

-- El usuario sube su comprobante de transferencia para su suscripción.
CREATE OR REPLACE FUNCTION public.submit_subscription_receipt(sub_id UUID, receipt_path TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.subscriptions
     SET receipt_url = receipt_path,
         receipt_uploaded_at = NOW(),
         payment_status = 'pending_review'
   WHERE id = sub_id
     AND user_id = (SELECT auth.uid());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Suscripción no encontrada o no te pertenece';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.submit_subscription_receipt IS
  'Llamada por el usuario autenticado al subir su comprobante de transferencia para Running. '
  'Solo puede tocar su propia suscripción (sub_id debe ser suya).';

-- Un admin aprueba o rechaza el comprobante. Si aprueba, activa la suscripción
-- y arranca el ciclo de 30 días (mismo criterio que el webhook de MP hacía antes).
CREATE OR REPLACE FUNCTION public.review_subscription_payment(sub_id UUID, approve BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = (SELECT auth.uid()) AND u.is_admin) THEN
    RAISE EXCEPTION 'Solo un admin puede revisar comprobantes';
  END IF;

  UPDATE public.subscriptions
     SET payment_status      = CASE WHEN approve THEN 'verified' ELSE 'rejected' END,
         payment_reviewed_by = (SELECT auth.uid()),
         payment_reviewed_at = NOW(),
         status              = CASE WHEN approve THEN 'active'::subscription_status_type ELSE status END,
         current_period_end  = CASE WHEN approve THEN NOW() + INTERVAL '30 days' ELSE current_period_end END
   WHERE id = sub_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Suscripción no encontrada';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.review_subscription_payment IS
  'Panel admin: aprueba o rechaza un comprobante de transferencia de Running. Aprobar activa el plan.';

GRANT EXECUTE ON FUNCTION public.submit_subscription_receipt(UUID, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_subscription_payment(UUID, BOOLEAN)  TO authenticated; -- valida is_admin adentro

-- Nota: no hace falta GRANT UPDATE de columnas en subscriptions para 'authenticated'
-- (hoy no tiene ninguno — ver v1.0, sección GRANTS). Las dos funciones de arriba
-- corren SECURITY DEFINER y son el único camino de escritura post-INSERT.


-- ================================================================
-- 3. EVENTS — precio opcional de after-run, separado del precio base
-- ================================================================
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS after_run_price NUMERIC(12,2) CHECK (after_run_price IS NULL OR after_run_price >= 0);

COMMENT ON COLUMN public.events.after_run_price IS
  'Precio adicional del after-run (café/consumo), separado de base_price. '
  'Solo aplica si has_after_run = TRUE. La vista de evento muestra ambos montos y el total.';


-- ================================================================
-- 4. admin_create_event / admin_update_event — sumar p_after_run_price
--    (parámetro nuevo al final con DEFAULT NULL: mismo patrón ya usado en
--    2026-07-13_admin_crud.sql para agregar p_organizer_id/p_partner_id/etc.)
-- ================================================================
CREATE OR REPLACE FUNCTION public.admin_create_event(
  p_title TEXT,
  p_event_date TIMESTAMPTZ,
  p_branch branch_type DEFAULT 'running',
  p_location_text TEXT DEFAULT NULL,
  p_cover_image_url TEXT DEFAULT NULL,
  p_base_price NUMERIC DEFAULT NULL,
  p_total_capacity INTEGER DEFAULT NULL,
  p_sales_cutoff TIMESTAMPTZ DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_itinerary JSONB DEFAULT '[]',
  p_has_after_run BOOLEAN DEFAULT FALSE,
  p_included_in_running_pro BOOLEAN DEFAULT FALSE,
  p_is_published BOOLEAN DEFAULT TRUE,
  p_organizer_id UUID DEFAULT NULL,
  p_partner_id UUID DEFAULT NULL,
  p_logistics_type logistics_type DEFAULT NULL,
  p_requires_form BOOLEAN DEFAULT FALSE,
  p_after_run_price NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  PERFORM public._require_admin();

  INSERT INTO public.events (
    title, event_date, branch, location_text, cover_image_url, base_price,
    total_capacity, sales_cutoff, description, itinerary, has_after_run,
    included_in_running_pro, is_published, organizer_id, partner_id,
    logistics_type, requires_form, after_run_price
  ) VALUES (
    p_title, p_event_date, p_branch, p_location_text, p_cover_image_url, p_base_price,
    p_total_capacity, p_sales_cutoff, p_description, COALESCE(p_itinerary, '[]'::jsonb), p_has_after_run,
    p_included_in_running_pro, p_is_published, p_organizer_id, p_partner_id,
    p_logistics_type, p_requires_form, p_after_run_price
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_event(
  p_event_id UUID,
  p_title TEXT DEFAULT NULL,
  p_event_date TIMESTAMPTZ DEFAULT NULL,
  p_branch branch_type DEFAULT NULL,
  p_location_text TEXT DEFAULT NULL,
  p_cover_image_url TEXT DEFAULT NULL,
  p_base_price NUMERIC DEFAULT NULL,
  p_total_capacity INTEGER DEFAULT NULL,
  p_sales_cutoff TIMESTAMPTZ DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_itinerary JSONB DEFAULT NULL,
  p_has_after_run BOOLEAN DEFAULT NULL,
  p_included_in_running_pro BOOLEAN DEFAULT NULL,
  p_is_published BOOLEAN DEFAULT NULL,
  p_organizer_id UUID DEFAULT NULL,
  p_partner_id UUID DEFAULT NULL,
  p_logistics_type logistics_type DEFAULT NULL,
  p_requires_form BOOLEAN DEFAULT NULL,
  p_after_run_price NUMERIC DEFAULT NULL,
  p_clear_after_run_price BOOLEAN DEFAULT FALSE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();

  UPDATE public.events SET
    title                    = COALESCE(p_title, title),
    event_date               = COALESCE(p_event_date, event_date),
    branch                   = COALESCE(p_branch, branch),
    location_text            = COALESCE(p_location_text, location_text),
    cover_image_url          = COALESCE(p_cover_image_url, cover_image_url),
    base_price               = COALESCE(p_base_price, base_price),
    total_capacity           = COALESCE(p_total_capacity, total_capacity),
    sales_cutoff             = COALESCE(p_sales_cutoff, sales_cutoff),
    description              = COALESCE(p_description, description),
    itinerary                = COALESCE(p_itinerary, itinerary),
    has_after_run            = COALESCE(p_has_after_run, has_after_run),
    included_in_running_pro  = COALESCE(p_included_in_running_pro, included_in_running_pro),
    is_published             = COALESCE(p_is_published, is_published),
    organizer_id             = COALESCE(p_organizer_id, organizer_id),
    partner_id               = COALESCE(p_partner_id, partner_id),
    logistics_type           = COALESCE(p_logistics_type, logistics_type),
    requires_form            = COALESCE(p_requires_form, requires_form),
    after_run_price          = CASE WHEN p_clear_after_run_price THEN NULL ELSE COALESCE(p_after_run_price, after_run_price) END
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento no encontrado';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN
) TO authenticated;


-- ================================================================
-- 5. STORAGE — bucket público para imágenes de evento (subida desde Admin.html)
-- ================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('event-images', 'event-images', TRUE)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "event_images_public_read" ON storage.objects;
CREATE POLICY "event_images_public_read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'event-images');

DROP POLICY IF EXISTS "event_images_admin_write" ON storage.objects;
CREATE POLICY "event_images_admin_write"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'event-images'
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = (select auth.uid()) AND u.is_admin)
  );

DROP POLICY IF EXISTS "event_images_admin_update" ON storage.objects;
CREATE POLICY "event_images_admin_update"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'event-images'
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = (select auth.uid()) AND u.is_admin)
  );


-- ================================================================
-- 6. VERIFICACIÓN RÁPIDA (comentado — correr a mano si querés confirmar)
-- ================================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'subscriptions' AND column_name LIKE 'payment%' OR column_name LIKE 'receipt%';
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'events' AND column_name = 'after_run_price';
-- SELECT id, public FROM storage.buckets WHERE id = 'event-images';
