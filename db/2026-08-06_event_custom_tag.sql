-- ================================================================
--  Sprinters · Etiqueta editable por evento (custom_tag)
--
--  Hasta ahora la etiqueta que se ve en la card del evento y en el
--  eyebrow de la página de detalle salía únicamente de `branch`
--  (Running / Social) — dos valores fijos. El pedido fue poder poner
--  otra cosa puntual por evento, por ejemplo "Trekking", sin que eso
--  cambie de qué pilar es el evento (branch sigue mandando en las
--  imágenes por defecto, el filtro de agenda, etc.).
--
--  custom_tag es un texto libre, opcional. Si está vacío, el front
--  sigue mostrando el nombre de la categoría como hasta ahora
--  (Landing v2 renderEvent, Evento.html render): fallback
--  `event.custom_tag || (Running/Social según branch)`.
--
--  CÓMO APLICAR: pegar este archivo entero en el SQL Editor de Supabase
--  y correrlo. Sin este paso, guardar un evento desde Admin no va a
--  funcionar — admin_create_event/admin_update_event pasan a pedir un
--  parámetro (p_custom_tag) que hoy no existe en la base.
-- ================================================================

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS custom_tag TEXT;

COMMENT ON COLUMN public.events.custom_tag IS
  'Etiqueta que se muestra en la card de agenda y en el eyebrow del evento '
  '(ej. "Trekking"). Si es NULL/vacío, el front usa el nombre de la '
  'categoría (branch: Running/Social) como venía siendo.';

-- ── admin_create_event / admin_update_event con el parámetro nuevo ──
-- Firma actual (la última redefinición fue en 2026-08-04_plus_birthdate_afterrun.sql):
DROP FUNCTION IF EXISTS public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,after_run_payment_type
);
DROP FUNCTION IF EXISTS public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN,after_run_payment_type
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
  p_after_run_payment after_run_payment_type DEFAULT 'on_site',
  p_custom_tag TEXT DEFAULT NULL
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
    logistics_type, requires_form, after_run_price, after_run_payment,
    custom_tag
  ) VALUES (
    p_title, p_event_date, p_branch, p_location_text, p_cover_image_url, p_base_price,
    p_total_capacity, p_sales_cutoff, p_description, COALESCE(p_itinerary, '[]'::jsonb), p_has_after_run,
    p_included_in_running_pro, p_is_published, p_organizer_id, p_partner_id,
    p_logistics_type, p_requires_form, p_after_run_price,
    COALESCE(p_after_run_payment, 'on_site'),
    NULLIF(TRIM(p_custom_tag), '')
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
  p_after_run_payment after_run_payment_type DEFAULT NULL,
  p_custom_tag TEXT DEFAULT NULL,
  p_clear_custom_tag BOOLEAN DEFAULT FALSE
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
    sales_cutoff              = COALESCE(p_sales_cutoff, sales_cutoff),
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
    after_run_price          = CASE WHEN p_clear_after_run_price THEN NULL ELSE COALESCE(p_after_run_price, after_run_price) END,
    -- p_clear_custom_tag existe porque "vaciar el campo en el form" y "no
    -- tocar el campo" son dos cosas distintas: COALESCE solo no alcanza,
    -- si el admin borra la etiqueta para volver al fallback de branch,
    -- p_custom_tag llega NULL y COALESCE lo confundiría con "no cambiar nada".
    custom_tag                = CASE WHEN p_clear_custom_tag THEN NULL ELSE COALESCE(NULLIF(TRIM(p_custom_tag), ''), custom_tag) END
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento no encontrado';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,after_run_payment_type,TEXT
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN,after_run_payment_type,TEXT,BOOLEAN
) TO authenticated;

-- ================================================================
-- VERIFICACIÓN RÁPIDA (comentado — correr a mano si querés confirmar)
-- ================================================================
-- SELECT id, title, branch, custom_tag FROM public.events ORDER BY event_date DESC LIMIT 5;
