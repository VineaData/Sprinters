-- ================================================================
--  SPRINTERS OS · Migración v1.5 · Plus + Fecha de nacimiento + After-run
--  PostgreSQL 15 / Supabase · 2026-08-04
--
--  REQUISITO: todas las migraciones anteriores de db/ aplicadas
--             (última: 2026-07-28_receipt_required_constraint.sql).
--  ADITIVO e IDEMPOTENTE: se puede re-ejecutar sin romper datos.
--
--  CÓMO APLICAR:
--    python db/sb_mgmt.py migrate db/2026-08-04_plus_birthdate_afterrun.sql
--
--  ALCANCE:
--    1. Plan "Training Pro" → "Training Plus" (nombre comercial real).
--    2. admin_list_users devuelve emergency_contact / how_heard / birth_date
--       (hoy el panel de admin tiene los campos en el modal pero llegan vacíos
--       porque la función nunca los seleccionó).
--    3. admin_update_user acepta p_birth_date.
--    4. birth_date pasa a ser la fuente de verdad de la edad: un trigger
--       recalcula users.age en cada INSERT/UPDATE. La columna age queda
--       como cache derivada (no se pide más en ningún formulario).
--    5. submit_subscription_receipt ACTIVA la suscripción al instante
--       (sin revisión previa). El comprobante se guarda igual y el admin
--       puede revocar después con review_subscription_payment(false).
--    6. events.after_run_payment: quién cobra el after-run
--       ('on_site' = paga cada uno en el lugar / 'organizer' = lo cobramos
--       nosotros junto con la inscripción).
-- ================================================================


-- ================================================================
-- 1. PLAN: Training Pro → Training Plus
--    Solo cambia el nombre visible y el badge. price/benefits intactos.
--    Las suscripciones existentes apuntan por plan_id, así que no se rompen.
-- ================================================================
UPDATE public.membership_plans
   SET name          = 'Training Plus',
       benefits_json = jsonb_set(benefits_json, '{badge}', '"plus"')
 WHERE name = 'Training Pro'
   AND NOT EXISTS (SELECT 1 FROM public.membership_plans WHERE name = 'Training Plus');

COMMENT ON TABLE public.membership_plans IS
  'Planes de membresía. Running: Training Core / Training Plus. '
  '(Training Plus se llamó "Training Pro" hasta 2026-08-04; las columnas '
  'events.included_in_running_pro y benefits_json.grants_social_pro conservan '
  'el nombre viejo para no romper código existente.)';


-- ================================================================
-- 2. USERS · birth_date como fuente de verdad de la edad
--    birth_date ya existe desde v1.1 (schema_v1.1_running_social).
--    Acá: (a) trigger que deriva age, (b) backfill de los que ya cargaron
--    birth_date, (c) GRANT para que el usuario pueda editar birth_date
--    pero NO age (age deja de ser editable por el usuario: la calcula la base).
-- ================================================================

CREATE OR REPLACE FUNCTION public.sync_age_from_birth_date()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.birth_date IS NOT NULL THEN
    NEW.age := GREATEST(14, LEAST(99,
      EXTRACT(YEAR FROM AGE(CURRENT_DATE, NEW.birth_date))::SMALLINT
    ));
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_age_from_birth_date IS
  'Deriva users.age de users.birth_date. birth_date es la fuente de verdad; '
  'age queda como cache para queries/segmentaciones existentes. '
  'Se clampea a 14..99 para no violar el CHECK de la columna.';

DROP TRIGGER IF EXISTS trg_sync_age_from_birth_date ON public.users;
CREATE TRIGGER trg_sync_age_from_birth_date
  BEFORE INSERT OR UPDATE OF birth_date ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_age_from_birth_date();

-- Backfill: quien ya tenía birth_date cargado queda con age consistente.
UPDATE public.users
   SET birth_date = birth_date
 WHERE birth_date IS NOT NULL;

-- El usuario puede editar su fecha de nacimiento; age ya no (la calcula el trigger).
GRANT UPDATE (birth_date) ON public.users TO authenticated;


-- ================================================================
-- 3. handle_new_auth_user · tomar birth_date del metadata del signup
--    El formulario de Cuenta.html pasa a mandar birth_date en vez de age.
--    Mantenemos el fallback a 'age' por si queda algún cliente viejo cacheado.
--    (El trigger de la sección 2 recalcula age a partir de birth_date, así que
--     v_age acá es solo para el caso "vino age y no birth_date".)
-- ================================================================
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_birth DATE;
  v_age   SMALLINT;
BEGIN
  BEGIN
    v_birth := NULLIF(trim(NEW.raw_user_meta_data->>'birth_date'), '')::DATE;
  EXCEPTION WHEN others THEN
    v_birth := NULL;
  END;

  BEGIN
    v_age := NULLIF(trim(NEW.raw_user_meta_data->>'age'), '')::SMALLINT;
  EXCEPTION WHEN others THEN
    v_age := NULL;
  END;

  IF v_birth IS NOT NULL THEN
    v_age := GREATEST(14, LEAST(99, EXTRACT(YEAR FROM AGE(CURRENT_DATE, v_birth))::SMALLINT));
  END IF;

  INSERT INTO public.users (
    id, first_name, last_name, birth_date, age, sex, origin,
    emergency_contact, phone, how_heard
  ) VALUES (
    NEW.id,
    COALESCE(NULLIF(trim(NEW.raw_user_meta_data->>'first_name'), ''), ''),
    COALESCE(NULLIF(trim(NEW.raw_user_meta_data->>'last_name'),  ''), ''),
    v_birth,
    v_age,
    NULLIF(trim(NEW.raw_user_meta_data->>'sex'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'origin'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'emergency_contact'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'phone'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'how_heard'), '')
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_auth_user IS
  'Crea la fila en public.users al confirmarse el signup. Desde 2026-08-04 lee '
  'birth_date del metadata (fuente de verdad) y deriva age; mantiene fallback a age.';


-- ================================================================
-- 4. admin_list_users · devolver los campos que el modal ya pedía
--    Antes: el modal de Admin.html tenía inputs de "Contacto de emergencia"
--    y "Cómo nos conoció" pero la función no los seleccionaba, así que
--    siempre aparecían vacíos y al guardar se pisaban con NULL.
--    Cambia el RETURNS TABLE → hay que dropear la firma vieja primero.
-- ================================================================
DROP FUNCTION IF EXISTS public.admin_list_users(TEXT, BOOLEAN);

CREATE OR REPLACE FUNCTION public.admin_list_users(
  p_search TEXT DEFAULT NULL,
  p_include_inactive BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
  id UUID, email TEXT, first_name TEXT, last_name TEXT, phone TEXT,
  age SMALLINT, birth_date DATE, sex CHAR(1), origin TEXT,
  emergency_contact TEXT, how_heard TEXT, is_admin BOOLEAN,
  social_events_attended INTEGER, total_km NUMERIC, total_money_saved NUMERIC,
  created_at TIMESTAMPTZ, deleted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();
  RETURN QUERY
  SELECT u.id, au.email::TEXT, u.first_name, u.last_name, u.phone,
         u.age, u.birth_date, u.sex, u.origin,
         u.emergency_contact, u.how_heard, u.is_admin,
         u.social_events_attended, u.total_km, u.total_money_saved,
         u.created_at, u.deleted_at
    FROM public.users u
    JOIN auth.users au ON au.id = u.id
   WHERE (p_include_inactive OR u.deleted_at IS NULL)
     AND (
       p_search IS NULL OR p_search = '' OR
       au.email ILIKE '%' || p_search || '%' OR
       u.first_name ILIKE '%' || p_search || '%' OR
       u.last_name ILIKE '%' || p_search || '%' OR
       u.phone ILIKE '%' || p_search || '%'
     )
   ORDER BY u.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_users(TEXT, BOOLEAN) TO authenticated;


-- ================================================================
-- 5. admin_update_user · aceptar p_birth_date
--    Firma nueva (param al final) → drop de la vieja para no dejar overload
--    ambiguo cuando PostgREST resuelve por nombre de parámetro.
-- ================================================================
DROP FUNCTION IF EXISTS public.admin_update_user(
  UUID, TEXT, TEXT, TEXT, SMALLINT, CHAR, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, NUMERIC, NUMERIC
);

CREATE OR REPLACE FUNCTION public.admin_update_user(
  p_user_id UUID,
  p_first_name TEXT DEFAULT NULL,
  p_last_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_age SMALLINT DEFAULT NULL,
  p_sex CHAR(1) DEFAULT NULL,
  p_origin TEXT DEFAULT NULL,
  p_emergency_contact TEXT DEFAULT NULL,
  p_how_heard TEXT DEFAULT NULL,
  p_is_admin BOOLEAN DEFAULT NULL,
  p_social_events_attended INTEGER DEFAULT NULL,
  p_total_km NUMERIC DEFAULT NULL,
  p_total_money_saved NUMERIC DEFAULT NULL,
  p_birth_date DATE DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();

  UPDATE public.users SET
    first_name             = COALESCE(p_first_name, first_name),
    last_name              = COALESCE(p_last_name, last_name),
    phone                  = COALESCE(p_phone, phone),
    birth_date             = COALESCE(p_birth_date, birth_date),
    -- age solo se respeta si NO hay birth_date (el trigger la pisa si lo hay)
    age                    = COALESCE(p_age, age),
    sex                    = COALESCE(p_sex, sex),
    origin                 = COALESCE(p_origin, origin),
    emergency_contact      = COALESCE(p_emergency_contact, emergency_contact),
    how_heard              = COALESCE(p_how_heard, how_heard),
    is_admin               = COALESCE(p_is_admin, is_admin),
    social_events_attended = COALESCE(p_social_events_attended, social_events_attended),
    total_km               = COALESCE(p_total_km, total_km),
    total_money_saved      = COALESCE(p_total_money_saved, total_money_saved)
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuario no encontrado';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_user(
  UUID,TEXT,TEXT,TEXT,SMALLINT,CHAR,TEXT,TEXT,TEXT,BOOLEAN,INTEGER,NUMERIC,NUMERIC,DATE
) TO authenticated;


-- ================================================================
-- 6. SUSCRIPCIONES · activación inmediata al subir el comprobante
--
--    Decisión de producto (2026-08-04): el usuario no espera revisión.
--    Sube el comprobante y el plan queda activo en el acto.
--    Seguimos guardando receipt_url + receipt_uploaded_at, y marcamos
--    auto_verified = TRUE para que el admin sepa que nadie lo miró.
--    Si el comprobante era trucho, review_subscription_payment(sub, FALSE)
--    lo rechaza y la suscripción vuelve a quedar sin activar.
-- ================================================================
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS auto_verified BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.subscriptions.auto_verified IS
  'TRUE = se activó sola al subir el comprobante, sin revisión humana. '
  'El admin puede auditar estas filas y revocarlas con review_subscription_payment(id, FALSE).';

CREATE OR REPLACE FUNCTION public.submit_subscription_receipt(sub_id UUID, receipt_path TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.subscriptions
     SET receipt_url         = receipt_path,
         receipt_uploaded_at = NOW(),
         payment_status      = 'verified',
         auto_verified       = TRUE,
         status              = 'active'::subscription_status_type,
         current_period_end  = GREATEST(COALESCE(current_period_end, NOW()), NOW()) + INTERVAL '30 days'
   WHERE id = sub_id
     AND user_id = (SELECT auth.uid());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Suscripción no encontrada o no te pertenece';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.submit_subscription_receipt IS
  'El usuario sube su comprobante y la suscripción queda ACTIVA al instante '
  '(sin cola de revisión). Marca auto_verified=TRUE para auditoría posterior.';

-- Rechazo por parte del admin: además de marcar rejected, desactiva la
-- suscripción que se había auto-activado (antes solo tocaba status al aprobar).
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
         auto_verified       = FALSE,   -- ya la miró un humano
         status              = CASE WHEN approve
                                    THEN 'active'::subscription_status_type
                                    ELSE 'cancelled'::subscription_status_type END,
         current_period_end  = CASE WHEN approve
                                    THEN NOW() + INTERVAL '30 days'
                                    ELSE current_period_end END
   WHERE id = sub_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Suscripción no encontrada';
  END IF;
END;
$$;


-- ================================================================
-- 7. EVENTOS · quién cobra el after-run
--    'on_site'   → cada uno paga en el bar/café al momento (no se cobra acá)
--    'organizer' → lo cobramos nosotros junto con la inscripción
-- ================================================================
DO $$ BEGIN
  CREATE TYPE after_run_payment_type AS ENUM ('on_site', 'organizer');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS after_run_payment after_run_payment_type NOT NULL DEFAULT 'on_site';

COMMENT ON COLUMN public.events.after_run_payment IS
  'Quién cobra el after-run. on_site = paga cada uno en el lugar (after_run_price es '
  'referencia informativa y NO se suma al total de la inscripción). '
  'organizer = lo cobramos nosotros y after_run_price se suma al total a transferir.';

-- ── admin_create_event / admin_update_event con el parámetro nuevo ──
DROP FUNCTION IF EXISTS public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC
);
DROP FUNCTION IF EXISTS public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN
);

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
  p_after_run_price NUMERIC DEFAULT NULL,
  p_after_run_payment after_run_payment_type DEFAULT 'on_site'
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
    logistics_type, requires_form, after_run_price, after_run_payment
  ) VALUES (
    p_title, p_event_date, p_branch, p_location_text, p_cover_image_url, p_base_price,
    p_total_capacity, p_sales_cutoff, p_description, COALESCE(p_itinerary, '[]'::jsonb), p_has_after_run,
    p_included_in_running_pro, p_is_published, p_organizer_id, p_partner_id,
    p_logistics_type, p_requires_form, p_after_run_price,
    COALESCE(p_after_run_payment, 'on_site')
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
  p_clear_after_run_price BOOLEAN DEFAULT FALSE,
  p_after_run_payment after_run_payment_type DEFAULT NULL
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
    after_run_payment        = COALESCE(p_after_run_payment, after_run_payment),
    after_run_price          = CASE WHEN p_clear_after_run_price THEN NULL ELSE COALESCE(p_after_run_price, after_run_price) END
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento no encontrado';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,after_run_payment_type
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN,after_run_payment_type
) TO authenticated;


-- ================================================================
-- 8. VERIFICACIÓN RÁPIDA (comentado — correr a mano si querés confirmar)
-- ================================================================
-- SELECT name, benefits_json->>'badge' FROM public.membership_plans WHERE branch = 'running';
-- SELECT id, birth_date, age FROM public.users WHERE birth_date IS NOT NULL LIMIT 5;
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'events' AND column_name = 'after_run_payment';
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'subscriptions' AND column_name = 'auto_verified';
-- SELECT * FROM public.admin_list_users() LIMIT 1;   -- logueado como admin
