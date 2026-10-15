-- ================================================================
--  Sprinters · Tandas de precio por evento (early / general)
--  PostgreSQL 15 / Supabase · 2026-10-13
--
--  REQUISITO: 2026-08-04_inscripcion_atomica_y_comprobantes.sql
--             (register_for_event con FOR UPDATE) y
--             2026-08-06_event_custom_tag.sql (última firma de
--             admin_create_event / admin_update_event).
--             Este script es ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR: pegar este archivo entero en el SQL Editor de Supabase y
--  correrlo. Sin este paso, guardar un evento desde Admin va a fallar:
--  admin_create_event/admin_update_event pasan a pedir tres parámetros
--  (p_early_price, p_early_capacity, p_early_until) que hoy no existen.
--
--  ----------------------------------------------------------------
--  PARA QUÉ
--
--  Evento del 17/11 con la bodega: entrada tipo boliche, con tanda early
--  más barata y después general. Hasta ahora un evento tenía un solo
--  `base_price`.
--
--  DECISIÓN CENTRAL: la tanda la decide el SERVIDOR, adentro de
--  register_for_event, bajo el mismo FOR UPDATE que ya bloquea la fila del
--  evento para contar el cupo.
--
--  No es un detalle de implementación. Si el precio lo calculara el
--  navegador, dos personas que entran a la vez cuando queda UN lugar early
--  verían las dos el precio early, y una de las dos transferiría de menos.
--  Calculándolo bajo el lock, la segunda queda en general aunque la
--  pantalla le hubiera mostrado early un segundo antes.
--
--  Por eso también se guarda el precio en la inscripción (price_locked):
--  el admin que revisa el comprobante necesita saber cuánto le correspondía
--  pagar a ESA persona, no cuánto sale el evento hoy.
--
--  MODELO DE SOCIOS: no se toca. member_price sigue como está y se sigue
--  resolviendo donde se resolvía. La tanda reemplaza a base_price, no al
--  descuento de socio.
-- ================================================================


-- ================================================================
-- 1. events — las tres columnas de la tanda early
--
--    early_price NULL  = evento de precio único (comportamiento de hoy).
--    Las otras dos definen CUÁNDO se termina la tanda; se puede usar una,
--    la otra, o las dos. Si están las dos, gana la que ocurra primero:
--
--      early_capacity 50 + early_until 2026-11-01
--      → general apenas se venden 50 entradas, o el 1/11, lo que pase antes.
-- ================================================================
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS early_price    NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS early_capacity INTEGER,
  ADD COLUMN IF NOT EXISTS early_until    TIMESTAMPTZ;

COMMENT ON COLUMN public.events.early_price IS
  'Precio de la tanda early. NULL = el evento tiene un solo precio (base_price).';
COMMENT ON COLUMN public.events.early_capacity IS
  'Cuántas inscripciones entran al precio early. Se compara contra sold_tickets, '
  'así que son las primeras N del evento. NULL = sin tope por cantidad.';
COMMENT ON COLUMN public.events.early_until IS
  'Hasta cuándo rige el precio early. NULL = sin tope por fecha.';

-- El cupo early no puede superar al total: sería prometer un precio para
-- lugares que no existen.
ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_early_capacity_check;
ALTER TABLE public.events
  ADD CONSTRAINT events_early_capacity_check CHECK (
    early_capacity IS NULL
    OR total_capacity IS NULL
    OR early_capacity <= total_capacity
  );

-- Un precio early más caro que el general no es una tanda, es un error de
-- carga. Se corta acá y no cuando alguien ya transfirió de más.
ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_early_price_check;
ALTER TABLE public.events
  ADD CONSTRAINT events_early_price_check CHECK (
    early_price IS NULL
    OR base_price IS NULL
    OR early_price <= base_price
  );


-- ================================================================
-- 2. event_registrations — qué precio le tocó a cada uno
--
--    Sin esto, el admin que revisa un comprobante de $12.000 no tiene forma
--    de saber si esa persona entró en early (y está bien) o si pagó de menos.
-- ================================================================
ALTER TABLE public.event_registrations
  ADD COLUMN IF NOT EXISTS price_locked NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS price_tier   TEXT;

COMMENT ON COLUMN public.event_registrations.price_locked IS
  'Precio que regía cuando esta persona se inscribió, fijado por '
  'register_for_event bajo el lock del evento. Es contra este número que se '
  'valida el comprobante, no contra el precio actual del evento.';
COMMENT ON COLUMN public.event_registrations.price_tier IS
  'Tanda que aplicó: early | general. NULL en inscripciones anteriores a '
  'esta migración (2026-10-13), que son todas de precio único.';

ALTER TABLE public.event_registrations
  DROP CONSTRAINT IF EXISTS event_registrations_price_tier_check;
ALTER TABLE public.event_registrations
  ADD CONSTRAINT event_registrations_price_tier_check CHECK (
    price_tier IS NULL OR price_tier IN ('early', 'general')
  );


-- ================================================================
-- 3. current_event_tier() — una sola definición de "qué tanda rige"
--
--    La usa register_for_event para cobrar y el front para mostrar. Tenerla
--    en un solo lugar evita que la pantalla diga una cosa y el servidor
--    cobre otra.
--
--    STABLE y no VOLATILE: dentro de una misma consulta devuelve siempre lo
--    mismo, que es lo que se quiere al calcularla sobre varias filas.
-- ================================================================
CREATE OR REPLACE FUNCTION public.current_event_tier(e public.events)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
           WHEN e.early_price IS NULL THEN 'general'
           WHEN e.early_until IS NOT NULL AND NOW() >= e.early_until THEN 'general'
           WHEN e.early_capacity IS NOT NULL
                AND COALESCE(e.sold_tickets, 0) >= e.early_capacity THEN 'general'
           ELSE 'early'
         END;
$$;

COMMENT ON FUNCTION public.current_event_tier IS
  'Qué tanda rige ahora para un evento: early o general. Fuente única de '
  'verdad, usada por register_for_event y por la vista pública.';


-- ================================================================
-- 4. register_for_event() — ahora fija precio y tanda
--
--    Cambia solo el paso ⑤: el resto queda igual que en la migración del
--    2026-08-04. Se redefine entera porque CREATE OR REPLACE lo exige.
-- ================================================================
CREATE OR REPLACE FUNCTION public.register_for_event(
  p_event_id  UUID,
  p_after_run BOOLEAN DEFAULT FALSE
)
RETURNS public.event_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event  public.events%ROWTYPE;
  v_user   UUID := (SELECT auth.uid());
  v_reg    public.event_registrations%ROWTYPE;
  v_tier   TEXT;
  v_price  NUMERIC(12,2);
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'NO_AUTENTICADO: Iniciá sesión para reservar tu lugar.';
  END IF;

  -- ① Bloqueamos la fila del evento hasta el final de la transacción
  SELECT * INTO v_event
    FROM public.events
   WHERE id = p_event_id
     AND deleted_at IS NULL
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EVENTO_NO_ENCONTRADO: Este evento no existe o fue dado de baja.';
  END IF;

  -- ② ¿Sigue publicado?
  IF NOT v_event.is_published THEN
    RAISE EXCEPTION 'EVENTO_NO_PUBLICADO: Este evento todavía no está abierto a inscripciones.';
  END IF;

  -- Si ya estaba inscripta, devolvemos su fila y no tocamos el contador.
  -- Tampoco se recalcula el precio: el suyo ya quedó fijado.
  SELECT * INTO v_reg
    FROM public.event_registrations
   WHERE event_id = p_event_id AND user_id = v_user;

  IF FOUND THEN
    RETURN v_reg;
  END IF;

  -- ③ Cierre de inscripción (sales_cutoff NULL = sin cierre)
  IF v_event.sales_cutoff IS NOT NULL AND NOW() >= v_event.sales_cutoff THEN
    RAISE EXCEPTION
      'INSCRIPCION_CERRADA: Las inscripciones para "%" cerraron el %.',
      v_event.title,
      TO_CHAR(v_event.sales_cutoff AT TIME ZONE 'America/Argentina/Mendoza', 'DD/MM/YYYY HH24:MI');
  END IF;

  -- ④ Cupo (total_capacity NULL = sin límite)
  IF v_event.total_capacity IS NOT NULL
     AND COALESCE(v_event.sold_tickets, 0) >= v_event.total_capacity THEN
    RAISE EXCEPTION 'EVENTO_AGOTADO: Se acabaron los lugares para "%".', v_event.title;
  END IF;

  -- ⑤ Tanda y precio, con v_event ya bloqueado.
  --    Acá está el punto del asunto: si dos personas entran a la vez con un
  --    solo lugar early disponible, la segunda espera el lock, relee
  --    sold_tickets ya incrementado y le toca general.
  v_tier  := public.current_event_tier(v_event);
  v_price := CASE WHEN v_tier = 'early' THEN v_event.early_price
                  ELSE v_event.base_price END;

  -- ⑥ Inserción + contador, misma transacción
  INSERT INTO public.event_registrations
    (event_id, user_id, after_run, price_locked, price_tier)
  VALUES
    (p_event_id, v_user, COALESCE(p_after_run, FALSE), v_price, v_tier)
  RETURNING * INTO v_reg;

  UPDATE public.events
     SET sold_tickets = COALESCE(sold_tickets, 0) + 1
   WHERE id = p_event_id;

  RETURN v_reg;
END;
$$;


-- ================================================================
-- 5. admin_create_event / admin_update_event con los campos nuevos
--
--    Firmas tomadas de 2026-08-06_event_custom_tag.sql, que fue la última
--    redefinición. Los parámetros nuevos van AL FINAL y con DEFAULT:
--    insertarlos en el medio rompería cualquier llamada posicional.
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
  p_early_price NUMERIC DEFAULT NULL,
  p_early_capacity INTEGER DEFAULT NULL,
  p_early_until TIMESTAMPTZ DEFAULT NULL
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
    custom_tag, early_price, early_capacity, early_until
  ) VALUES (
    p_title, p_event_date, p_branch, p_location_text, p_cover_image_url, p_base_price,
    p_total_capacity, p_sales_cutoff, p_description, COALESCE(p_itinerary, '[]'::jsonb), p_has_after_run,
    p_included_in_running_pro, p_is_published, p_organizer_id, p_partner_id,
    p_logistics_type, p_requires_form, p_after_run_price,
    COALESCE(p_after_run_payment, 'on_site'),
    NULLIF(TRIM(p_custom_tag), ''),
    p_early_price, p_early_capacity, p_early_until
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
  p_early_price NUMERIC DEFAULT NULL,
  p_early_capacity INTEGER DEFAULT NULL,
  p_early_until TIMESTAMPTZ DEFAULT NULL,
  p_clear_early BOOLEAN DEFAULT FALSE
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
    custom_tag               = CASE WHEN p_clear_custom_tag THEN NULL ELSE COALESCE(NULLIF(TRIM(p_custom_tag), ''), custom_tag) END,
    -- p_clear_early apaga la tanda entera de una: es un solo gesto en el
    -- Admin ("este evento tiene precio único") y no tres campos a vaciar.
    early_price              = CASE WHEN p_clear_early THEN NULL ELSE COALESCE(p_early_price, early_price) END,
    early_capacity           = CASE WHEN p_clear_early THEN NULL ELSE COALESCE(p_early_capacity, early_capacity) END,
    early_until              = CASE WHEN p_clear_early THEN NULL ELSE COALESCE(p_early_until, early_until) END
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento no encontrado';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_event(
  TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,after_run_payment_type,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,NUMERIC,BOOLEAN,after_run_payment_type,TEXT,BOOLEAN,NUMERIC,INTEGER,TIMESTAMPTZ,BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_event_tier(public.events) TO anon, authenticated;


-- ================================================================
-- 6. VERIFICACIÓN (comentado — correr a mano después de aplicar)
-- ================================================================
-- -- Columnas nuevas:
-- SELECT column_name, data_type FROM information_schema.columns
--  WHERE table_name = 'events' AND column_name LIKE 'early%';
-- SELECT column_name, data_type FROM information_schema.columns
--  WHERE table_name = 'event_registrations' AND column_name LIKE 'price%';
--
-- -- La tanda se calcula bien (sobre un evento real):
-- SELECT id, title, base_price, early_price, early_capacity, early_until,
--        sold_tickets, public.current_event_tier(e.*) AS tanda
--   FROM public.events e WHERE deleted_at IS NULL ORDER BY event_date DESC LIMIT 5;
--
-- -- Prueba de la tanda, con un evento de juguete:
-- --   1) Crear evento con base_price 20000, early_price 12000, early_capacity 2.
-- --   2) Inscribir 3 usuarios distintos.
-- --   3) SELECT price_tier, price_locked FROM event_registrations WHERE event_id = '<id>';
-- --      → esperado: early/12000, early/12000, general/20000
--
-- -- Los CHECK funcionan (las dos tienen que fallar):
-- -- UPDATE public.events SET early_price = base_price + 1 WHERE id = '<id>';
-- -- UPDATE public.events SET early_capacity = total_capacity + 1 WHERE id = '<id>';


-- ================================================================
-- 7. CÓMO REVERTIR
-- ================================================================
-- Volver a aplicar 2026-08-06_event_custom_tag.sql (restaura las firmas
-- viejas de admin_create_event/admin_update_event) y 2026-08-04 para
-- register_for_event. Después:
--   DROP FUNCTION IF EXISTS public.current_event_tier(public.events);
--   ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_early_capacity_check;
--   ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_early_price_check;
-- Las columnas se pueden dejar: son nullables y no molestan. Borrarlas solo
-- si se quiere limpiar, y teniendo en cuenta que price_locked es el único
-- registro de cuánto le correspondía pagar a cada inscripto.
