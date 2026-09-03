-- ================================================================
--  Sprinters OS · Pádel y Trekking como pilares propios + precio socio
--  PostgreSQL 15 / Supabase · 2026-09-03
--
--  ADITIVO e IDEMPOTENTE. No borra ni reescribe datos existentes.
--
--  ALCANCE
--    1. branch_type gana dos valores: 'padel' y 'trekking'.
--       Hasta hoy el enum tenía solo 'social' y 'running', así que un
--       torneo de pádel se cargaba como running con la etiqueta cambiada
--       (custom_tag). Con el pilar propio la agenda de cada actividad se
--       puede filtrar de verdad y el front sabe qué bloques mostrar.
--    2. events.member_price: precio para socios con suscripción activa.
--       NULL = no hay descuento, todos pagan base_price (comportamiento
--       actual, así que las filas viejas no cambian).
--    3. admin_create_event / admin_update_event pasan a aceptar
--       p_member_price (y p_clear_member_price para vaciarlo).
--
--  CÓMO APLICAR
--    Pegar este archivo entero en el SQL Editor de Supabase y correrlo.
--
--    Si tira "unsafe use of new value of enum type": correr SOLO la
--    PARTE 1 (las dos líneas de ALTER TYPE), y después el resto en una
--    segunda pasada. Postgres no deja usar un valor de enum recién
--    agregado dentro de la misma transacción. Este archivo está escrito
--    para no necesitarlo (no menciona 'padel' ni 'trekking' como
--    literal en ninguna parte), pero queda dicho por si acaso.
--
--    SIN ESTE PASO, guardar un evento desde Admin va a fallar:
--    admin_create_event/admin_update_event pasan a pedir p_member_price
--    y esa firma todavía no existe en la base.
-- ================================================================


-- ================================================================
--  PARTE 1 · El enum de pilares
--
--  ADD VALUE IF NOT EXISTS hace esto idempotente: correr el archivo dos
--  veces no falla. El orden en que se agregan define el ORDER BY branch,
--  que hoy no se usa en ninguna consulta del front.
-- ================================================================
ALTER TYPE branch_type ADD VALUE IF NOT EXISTS 'padel';
ALTER TYPE branch_type ADD VALUE IF NOT EXISTS 'trekking';


-- ================================================================
--  PARTE 2 · Precio para socios
--
--  Por qué una columna nueva y no reusar included_in_running_pro: ese
--  switch es todo-o-nada (el Plus entra gratis) y solo mira un plan.
--  Acá hace falta un segundo precio, que puede ser cualquier monto —
--  incluido 0 — y que aplica a cualquier suscripción activa.
--
--  NULL y 0 significan cosas distintas y el front depende de eso:
--    NULL = no hay precio de socio, todos pagan base_price.
--    0    = los socios entran gratis.
--  Por eso el front chequea `member_price != null`, nunca truthiness.
-- ================================================================
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS member_price NUMERIC(12,2);

DO $$
BEGIN
  ALTER TABLE public.events
    ADD CONSTRAINT chk_member_price_nonneg
    CHECK (member_price IS NULL OR member_price >= 0);
EXCEPTION
  WHEN duplicate_object THEN NULL;   -- ya estaba: nada que hacer
END $$;

COMMENT ON COLUMN public.events.member_price IS
  'Precio del evento para quien tiene una suscripción activa (cualquier plan). '
  'NULL = sin descuento, todos pagan base_price. 0 = los socios entran gratis. '
  'No reemplaza a included_in_running_pro, que sigue siendo el "gratis para Plus".';


-- ================================================================
--  PARTE 3 · admin_create_event / admin_update_event
--
--  Se redefinen enteras porque en Postgres no se puede agregar un
--  parámetro a una función existente: hay que dropear la firma vieja
--  (los DROP de abajo son exactamente las firmas que dejó
--  2026-08-06_event_custom_tag.sql) y crear la nueva.
-- ================================================================
DROP FUNCTION IF EXISTS public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,after_run_payment_type,TEXT
);
DROP FUNCTION IF EXISTS public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN,after_run_payment_type,TEXT,BOOLEAN
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
  p_custom_tag TEXT DEFAULT NULL,
  p_member_price NUMERIC DEFAULT NULL
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
    custom_tag, member_price
  ) VALUES (
    p_title, p_event_date, p_branch, p_location_text, p_cover_image_url, p_base_price,
    p_total_capacity, p_sales_cutoff, p_description, COALESCE(p_itinerary, '[]'::jsonb), p_has_after_run,
    p_included_in_running_pro, p_is_published, p_organizer_id, p_partner_id,
    p_logistics_type, p_requires_form, p_after_run_price,
    COALESCE(p_after_run_payment, 'on_site'),
    NULLIF(TRIM(p_custom_tag), ''),
    p_member_price
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
  p_clear_custom_tag BOOLEAN DEFAULT FALSE,
  p_member_price NUMERIC DEFAULT NULL,
  p_clear_member_price BOOLEAN DEFAULT FALSE
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
    after_run_price          = CASE WHEN p_clear_after_run_price THEN NULL ELSE COALESCE(p_after_run_price, after_run_price) END,
    -- p_clear_custom_tag existe porque "vaciar el campo en el form" y "no
    -- tocar el campo" son dos cosas distintas: COALESCE solo no alcanza,
    -- si el admin borra la etiqueta para volver al fallback de branch,
    -- p_custom_tag llega NULL y COALESCE lo confundiría con "no cambiar nada".
    custom_tag               = CASE WHEN p_clear_custom_tag THEN NULL ELSE COALESCE(NULLIF(TRIM(p_custom_tag), ''), custom_tag) END,
    -- Mismo problema, y acá es más grave: member_price = 0 es un valor
    -- válido ("los socios entran gratis"). Vaciar el campo tiene que
    -- poder distinguirse de "no lo toqué", si no un evento con precio de
    -- socio nunca podría volver a no tenerlo.
    member_price             = CASE WHEN p_clear_member_price THEN NULL ELSE COALESCE(p_member_price, member_price) END
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento no encontrado';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,after_run_payment_type,TEXT,NUMERIC
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN,after_run_payment_type,TEXT,BOOLEAN,NUMERIC,BOOLEAN
) TO authenticated;


-- ================================================================
--  VERIFICACIÓN (correr a mano después de aplicar)
-- ================================================================
-- 1) El enum tiene los cuatro pilares:
-- SELECT enumlabel FROM pg_enum
--  WHERE enumtypid = 'branch_type'::regtype ORDER BY enumsortorder;
--    → social, running, padel, trekking
--
-- 2) La columna existe y las filas viejas quedaron en NULL (sin descuento):
-- SELECT count(*) AS total, count(member_price) AS con_precio_socio
--   FROM public.events WHERE deleted_at IS NULL;
--    → con_precio_socio = 0
--
-- 3) Las funciones quedaron con la firma nueva (21 y 25 parámetros):
-- SELECT proname, pronargs FROM pg_proc
--  WHERE proname IN ('admin_create_event','admin_update_event');
--    → admin_create_event 21 · admin_update_event 25
--
-- 4) Prueba de humo desde Admin: crear un evento con categoría Pádel,
--    precio general 8000 y precio socio 6000, guardarlo, y confirmar:
-- SELECT title, branch, base_price, member_price FROM public.events
--  ORDER BY created_at DESC LIMIT 1;
