-- ================================================================
--  SPRINTERS OS · Migración v1.3 · ABM (CRUD) admin para Usuarios y Eventos
--  PostgreSQL 15 / Supabase · 2026-07-13
--
--  REQUISITO: v1.0.0, v1.1.0 y v1.2 (2026-07-13_events_transfer_receipts.sql)
--             ya aplicadas. Este script es ADITIVO e IDEMPOTENTE
--             (usa CREATE OR REPLACE FUNCTION, se puede re-correr sin miedo).
--
--  CÓMO APLICAR:
--    A) python db/sb_mgmt.py migrate db/2026-07-13_admin_crud.sql
--    B) Supabase Dashboard → SQL Editor → New query → pegar completo → Run
--
--  POR QUÉ FUNCIONES Y NO POLICIES RLS ABIERTAS:
--    Hoy "users_select_own" / "users_update_own" solo dejan ver/editar la
--    PROPIA fila, y "events" no tiene ninguna policy de escritura para
--    'authenticated' (solo se podía tocar con la service_role key). Abrir
--    una policy "admin puede ver/editar todo" es una superficie de ataque
--    grande y difícil de auditar. En cambio, seguimos el mismo patrón que
--    ya usa el proyecto (submit_med_cert/review_med_cert,
--    submit_event_receipt/review_event_payment): funciones SECURITY DEFINER
--    que re-chequean is_admin puertas adentro, no tocan RLS, y son el único
--    camino para escribir. Todo lo demás sigue bloqueado como está.
-- ================================================================


-- ================================================================
-- 0. Helper interno — no se expone a los clientes (sin GRANT EXECUTE)
-- ================================================================
CREATE OR REPLACE FUNCTION public._require_admin()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = (SELECT auth.uid()) AND u.is_admin AND u.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Solo un admin puede hacer esto';
  END IF;
END;
$$;


-- ================================================================
-- 1. USUARIOS
-- ================================================================

-- Lista con búsqueda (mail/nombre/apellido/teléfono) + email desde auth.users
CREATE OR REPLACE FUNCTION public.admin_list_users(
  p_search TEXT DEFAULT NULL,
  p_include_inactive BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
  id UUID, email TEXT, first_name TEXT, last_name TEXT, phone TEXT,
  age SMALLINT, sex CHAR(1), origin TEXT, is_admin BOOLEAN,
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
  SELECT u.id, au.email::TEXT, u.first_name, u.last_name, u.phone, u.age, u.sex, u.origin,
         u.is_admin, u.social_events_attended, u.total_km, u.total_money_saved,
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

-- Update parcial: parámetros NULL = "no tocar esa columna"
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
  p_total_money_saved NUMERIC DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();

  IF p_user_id = (SELECT auth.uid()) AND p_is_admin IS FALSE THEN
    RAISE EXCEPTION 'No podés quitarte tu propio rol de admin';
  END IF;

  UPDATE public.users SET
    first_name             = COALESCE(p_first_name, first_name),
    last_name              = COALESCE(p_last_name, last_name),
    phone                  = COALESCE(p_phone, phone),
    age                    = COALESCE(p_age, age),
    sex                    = COALESCE(p_sex, sex),
    origin                 = COALESCE(p_origin, origin),
    emergency_contact      = COALESCE(p_emergency_contact, emergency_contact),
    how_heard              = COALESCE(p_how_heard, how_heard),
    is_admin               = COALESCE(p_is_admin, is_admin),
    social_events_attended = COALESCE(p_social_events_attended, social_events_attended),
    total_km               = COALESCE(p_total_km, total_km),
    total_money_saved      = COALESCE(p_total_money_saved, total_money_saved),
    updated_at             = NOW()
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuario no encontrado';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_soft_delete_user(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();
  IF p_user_id = (SELECT auth.uid()) THEN
    RAISE EXCEPTION 'No podés eliminar tu propia cuenta desde acá';
  END IF;
  UPDATE public.users SET deleted_at = NOW(), updated_at = NOW() WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_restore_user(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();
  UPDATE public.users SET deleted_at = NULL, updated_at = NOW() WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
END;
$$;


-- ================================================================
-- 2. EVENTOS
-- ================================================================

CREATE OR REPLACE FUNCTION public.admin_list_events(
  p_search TEXT DEFAULT NULL,
  p_include_inactive BOOLEAN DEFAULT FALSE
)
RETURNS SETOF public.events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();
  RETURN QUERY
  SELECT e.* FROM public.events e
   WHERE (p_include_inactive OR e.deleted_at IS NULL)
     AND (p_search IS NULL OR p_search = '' OR e.title ILIKE '%' || p_search || '%')
   ORDER BY e.event_date DESC;
END;
$$;

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
  p_requires_form BOOLEAN DEFAULT FALSE
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
    logistics_type, requires_form
  ) VALUES (
    p_title, p_event_date, p_branch, p_location_text, p_cover_image_url, p_base_price,
    p_total_capacity, p_sales_cutoff, p_description, COALESCE(p_itinerary, '[]'::jsonb), p_has_after_run,
    p_included_in_running_pro, p_is_published, p_organizer_id, p_partner_id,
    p_logistics_type, p_requires_form
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
  p_requires_form BOOLEAN DEFAULT NULL
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
    requires_form            = COALESCE(p_requires_form, requires_form)
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento no encontrado';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_soft_delete_event(p_event_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();
  UPDATE public.events SET deleted_at = NOW() WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Evento no encontrado'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_restore_event(p_event_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();
  UPDATE public.events SET deleted_at = NULL WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Evento no encontrado'; END IF;
END;
$$;


-- ================================================================
-- 3. LOOKUPS para los formularios (sin exponer datos sensibles)
-- ================================================================

-- organizers/programs ya tienen GRANT SELECT público (v1.1) — se listan directo.
-- partners NO tiene ninguna policy de lectura (mp_access_token es sensible),
-- así que exponemos una función admin-only que nunca devuelve el token.
CREATE OR REPLACE FUNCTION public.admin_list_partners()
RETURNS TABLE (id UUID, name TEXT, is_active BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();
  RETURN QUERY SELECT p.id, p.name, p.is_active FROM public.partners p ORDER BY p.name;
END;
$$;


-- ================================================================
-- 4. GRANTS — is_admin se revalida DENTRO de cada función
-- ================================================================
GRANT EXECUTE ON FUNCTION public.admin_list_users(TEXT, BOOLEAN)                          TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_user(UUID,TEXT,TEXT,TEXT,SMALLINT,CHAR,TEXT,TEXT,TEXT,BOOLEAN,INTEGER,NUMERIC,NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_soft_delete_user(UUID)                             TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_restore_user(UUID)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_events(TEXT, BOOLEAN)                         TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_event(TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_event(UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_soft_delete_event(UUID)                            TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_restore_event(UUID)                                TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_partners()                                    TO authenticated;
-- _require_admin() queda sin GRANT: es un helper interno, no se llama desde el cliente.


-- ================================================================
-- 5. VERIFICACIÓN RÁPIDA (comentado)
-- ================================================================
-- select * from public.admin_list_users();      -- solo funciona logueado como admin
-- select * from public.admin_list_events(null, true);
