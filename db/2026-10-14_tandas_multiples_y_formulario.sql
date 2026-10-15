-- ================================================================
--  Sprinters · Tandas múltiples por evento + formulario de inscripción
--  PostgreSQL 15 / Supabase · 2026-10-14
--
--  REQUISITO: 2026-10-13_tandas_early_general.sql aplicada.
--             Este script es ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR: pegar entero en el SQL Editor de Supabase y correr.
--
--  ----------------------------------------------------------------
--  POR QUÉ, Y QUÉ PASA CON LA MIGRACIÓN DE AYER
--
--  Ayer se agregó una tanda early sobre base_price: dos precios por evento.
--  Alcanzaba para un evento con "early y general", que era el pedido.
--
--  El brief de Run & Wine (13/10) pide más que eso:
--    · TRES tandas de run — Early Bird, General, Last Call.
--    · Una entrada que NO es una tanda: "Solo After" no tiene run, entra
--      19:30 y no compite por el cupo del run. Es otro producto dentro del
--      mismo evento.
--    · Cupos ACUMULADOS: General no cierra a las 80 entradas propias, sino
--      "al llegar a 120 en total". Last Call, a 150 en total.
--
--  Dos columnas (early_price / early_capacity) no modelan nada de eso. Acá
--  se generaliza a una LISTA de tandas en JSONB. Ventaja concreta: agregar
--  o sacar una tanda deja de ser una migración.
--
--  Las columnas early_* de ayer NO se borran: los eventos que ya las usan
--  siguen funcionando igual. register_for_event elige el camino según si el
--  evento tiene ticket_tiers cargadas o no.
--
--  ----------------------------------------------------------------
--  FORMULARIO: nada que diseñar, ya estaba
--
--  events.form_schema (JSONB, [{key,label,type,required}]),
--  events.requires_form y event_registrations.form_data existen desde la
--  migración del 2026-06-25 y nunca se usaron: ningún front los lee.
--  Acá se los pone a trabajar — register_for_event pasa a recibir y guardar
--  las respuestas. El renderizado del formulario es trabajo de front.
-- ================================================================


-- ================================================================
-- 1. events.ticket_tiers — la lista de entradas del evento
--
--    Forma de cada elemento:
--      {
--        "id":        "early",                  -- único dentro del evento
--        "nombre":    "Early Bird",
--        "precio":    20000,
--        "tipo":      "run",                    -- run | after
--        "incluye":   "Run + degustación",
--        "cupo_hasta": 40,                      -- tope ACUMULADO de su tipo
--        "cierra":    "2026-11-02T23:59:59-03:00",
--        "abre_con":  null,                     -- id de la tanda anterior
--        "cerrada_manual": false                -- true = cerrarla antes de tiempo
--      }
--
--    cupo_hasta es acumulado y no propio: es lo que pide el brief ("al
--    llegar a 120 entradas en total"). Se cuenta sobre las inscripciones
--    del mismo `tipo`, así Solo After no consume cupo del run.
--
--    abre_con encadena las tandas: general abre cuando early deja de estar
--    disponible, sea por cupo o por fecha. null = abre con el evento.
-- ================================================================
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS ticket_tiers JSONB NOT NULL DEFAULT '[]'::jsonb;

-- landing_url: si el evento tiene su propia página, acá va su ruta. La
-- agenda y cualquier link al evento llevan ahí en vez de a Evento.html.
--
-- Por qué una columna y no un tipo de evento nuevo: lo único que cambia es
-- DÓNDE se muestra. La inscripción, el cupo, el comprobante y el panel son
-- los mismos. Un "tipo especial" habría duplicado esa lógica sin razón.
--
-- La landing se busca a sí misma con esta columna (where landing_url = su
-- propia ruta), así no hay ids hardcodeados en el HTML.
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS landing_url TEXT;

COMMENT ON COLUMN public.events.landing_url IS
  'Ruta de la landing propia del evento (ej: /runandwine). NULL = se usa '
  'Evento.html, que es el caso de casi todos.';

COMMENT ON COLUMN public.events.ticket_tiers IS
  'Entradas del evento: [{id,nombre,precio,tipo,incluye,cupo_hasta,cierra,abre_con,cerrada_manual}]. '
  'Lista vacía = evento de precio único o con la tanda early de la migración '
  'del 2026-10-13. cupo_hasta es el tope ACUMULADO de las entradas de ese tipo.';

-- Cada tanda tiene que tener id, precio y tipo; sin eso no se puede cobrar.
--
-- Va como TRIGGER y no como CHECK. El primer intento fue un CHECK con
-- NOT EXISTS (SELECT ... jsonb_array_elements(...)), y Postgres lo rechaza:
--   ERROR 0A000: cannot use subquery in check constraint
-- Un CHECK sólo admite expresiones escalares sobre la fila. Para recorrer un
-- array hace falta una subconsulta, así que la validación va en un trigger,
-- que además permite un mensaje de error que se entienda.
CREATE OR REPLACE FUNCTION public.validar_ticket_tiers()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_t   JSONB;
  v_ids TEXT[] := '{}';
BEGIN
  IF NEW.ticket_tiers IS NULL OR jsonb_typeof(NEW.ticket_tiers) <> 'array' THEN
    RAISE EXCEPTION 'ticket_tiers tiene que ser un array JSON (recibido: %)',
      COALESCE(jsonb_typeof(NEW.ticket_tiers), 'null');
  END IF;

  FOR v_t IN SELECT * FROM jsonb_array_elements(NEW.ticket_tiers)
  LOOP
    IF v_t->>'id' IS NULL OR TRIM(v_t->>'id') = '' THEN
      RAISE EXCEPTION 'Cada tanda necesita un id. Falta en: %', v_t;
    END IF;
    IF v_t->>'precio' IS NULL THEN
      RAISE EXCEPTION 'La tanda "%" no tiene precio.', v_t->>'id';
    END IF;
    IF v_t->>'tipo' NOT IN ('run', 'after') THEN
      RAISE EXCEPTION 'La tanda "%" tiene tipo "%", y sólo valen run o after.',
        v_t->>'id', COALESCE(v_t->>'tipo', '(vacío)');
    END IF;
    -- Dos tandas con el mismo id harían que price_tier sea ambiguo y que
    -- el conteo de cupo mezcle las dos.
    IF v_t->>'id' = ANY(v_ids) THEN
      RAISE EXCEPTION 'Hay dos tandas con el id "%".', v_t->>'id';
    END IF;
    v_ids := v_ids || (v_t->>'id');
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validar_ticket_tiers ON public.events;
CREATE TRIGGER trg_validar_ticket_tiers
  BEFORE INSERT OR UPDATE OF ticket_tiers ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.validar_ticket_tiers();

-- Por si quedó de un intento anterior que falló a mitad de camino.
ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_ticket_tiers_check;

-- ================================================================
-- 1bis. chk_social_event_requirements — se acota al caso que le dio origen
--
--  La restricción, de la migración del 2026-06-25, exige que TODO evento con
--  branch='social' tenga partner_id y logistics_type. Nació con el modelo de
--  split payment: el evento social era una comida en un café aliado y la
--  plata se repartía, así que hacía falta saber a quién liquidarle.
--
--  Ese modelo se desarmó el 2026-07-13 ("se saca Mercado Pago del flujo de
--  EVENTOS... en su lugar el usuario transfiere y sube el comprobante").
--  Desde entonces no hay reparto y partner_id quedó sin uso.
--
--  Verificado contra la base el 2026-10-15, antes de tocar nada:
--    · public.partners                     → 0 filas
--    · eventos con branch='social'         → 0 filas
--  O sea que la regla nunca se cumplió con datos reales. Run & Wine es el
--  primer evento social que se intenta crear, y choca contra ella.
--
--  Qué se conserva: sales_cutoff, base_price y total_capacity siguen siendo
--  obligatorios, porque son los que un evento pago necesita de verdad.
--  Qué se acota: partner_id y logistics_type pasan a pedirse SOLO cuando el
--  evento no vende por tandas propias. Un evento con ticket_tiers lo cobra
--  Sprinters directo, así que no hay local al que liquidarle.
--
--  Si algún día vuelve el split, el camino es al revés: cargar el partner y
--  dejar ticket_tiers vacío, y la restricción vuelve a exigirlo.
-- ================================================================
ALTER TABLE public.events DROP CONSTRAINT IF EXISTS chk_social_event_requirements;
ALTER TABLE public.events ADD CONSTRAINT chk_social_event_requirements CHECK (
  branch <> 'social'
  OR (
    sales_cutoff   IS NOT NULL AND
    base_price     IS NOT NULL AND
    total_capacity IS NOT NULL AND
    (
      -- Venta directa de Sprinters: no hay nada que repartir.
      jsonb_array_length(COALESCE(ticket_tiers, '[]'::jsonb)) > 0
      -- Modelo viejo con local: se le sigue exigiendo lo de antes.
      OR (partner_id IS NOT NULL AND logistics_type IS NOT NULL)
    )
  )
);


-- price_tier guardaba 'early'/'general'. Ahora guarda el id de la tanda, que
-- es libre, así que el CHECK viejo queda corto.

ALTER TABLE public.event_registrations
  DROP CONSTRAINT IF EXISTS event_registrations_price_tier_check;

COMMENT ON COLUMN public.event_registrations.price_tier IS
  'Id de la tanda que aplicó (events.ticket_tiers[].id). En eventos viejos, '
  'early o general. NULL en inscripciones anteriores al 2026-10-13.';


-- ================================================================
-- 2. tanda_vigente() — qué entrada se puede comprar ahora
--
--    Devuelve el elemento de ticket_tiers que está abierto para ese tipo,
--    o NULL si no hay ninguno (todo agotado o cerrado por fecha).
--
--    Una tanda está abierta si:
--      a) no venció su fecha de cierre, y
--      b) las inscripciones de su tipo no llegaron a cupo_hasta, y
--      c) la tanda de la que depende (abre_con) ya NO está abierta.
--
--    El conteo sale de event_registrations y no de un contador aparte: un
--    contador denormalizado se desincroniza en cuanto alguien cancela o un
--    admin rechaza un comprobante. Como quien llama tiene la fila del
--    evento bloqueada, contar acá es exacto.
-- ================================================================
CREATE OR REPLACE FUNCTION public.tanda_vigente(p_event_id UUID, p_tipo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tiers    JSONB;
  v_t        JSONB;
  v_vendidas INTEGER;
BEGIN
  SELECT ticket_tiers INTO v_tiers FROM public.events WHERE id = p_event_id;
  IF v_tiers IS NULL OR jsonb_array_length(v_tiers) = 0 THEN
    RETURN NULL;
  END IF;

  -- Inscripciones vivas de ese tipo. Las canceladas no ocupan cupo.
  SELECT COUNT(*) INTO v_vendidas
    FROM public.event_registrations r
    JOIN LATERAL jsonb_array_elements(v_tiers) AS tt ON tt->>'id' = r.price_tier
   WHERE r.event_id = p_event_id
     AND r.status <> 'cancelled'
     AND tt->>'tipo' = p_tipo;

  FOR v_t IN SELECT * FROM jsonb_array_elements(v_tiers)
  LOOP
    CONTINUE WHEN v_t->>'tipo' IS DISTINCT FROM p_tipo;

    -- ¿venció?
    CONTINUE WHEN v_t->>'cierra' IS NOT NULL
             AND NOW() >= (v_t->>'cierra')::timestamptz;

    -- ¿llegó al tope acumulado?
    CONTINUE WHEN v_t->>'cupo_hasta' IS NOT NULL
             AND v_vendidas >= (v_t->>'cupo_hasta')::integer;

    -- Cierre manual: la válvula de escape. El paso de una tanda a la
    -- siguiente es AUTOMÁTICO por cupo y por fecha — nadie tiene que estar
    -- despierto cuando se vende la entrada 40. Pero a veces hace falta
    -- cortar antes: un precio mal cargado, un acuerdo que cambió, o
    -- sencillamente querer forzar el salto a la tanda siguiente.
    --
    -- Es un cierre, no una habilitación: poner cerrada_manual en true
    -- adelanta el paso a la próxima tanda, no frena la venta. Para lo
    -- contrario —estirar una tanda que se agotó— se sube cupo_hasta.
    CONTINUE WHEN COALESCE((v_t->>'cerrada_manual')::boolean, FALSE);

    -- No hace falta mirar abre_con acá. Las tandas vienen ORDENADAS y los
    -- cupos son ACUMULADOS, así que la primera que pasa los dos filtros de
    -- arriba es, por construcción, la que corresponde:
    --   vendidas=10  → early (10 < 40)
    --   vendidas=40  → early no pasa el cupo → general (40 < 120)
    --   vendidas=120 → tampoco general → last call (120 < 150)
    --   vendidas=150 → ninguna → NULL, agotado
    -- abre_con queda en el JSON como dato para el front, que lo usa para
    -- mostrar "Próximamente" en las que todavía no arrancaron.
    RETURN v_t;
  END LOOP;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.tanda_vigente IS
  'Tanda abierta para ese tipo de entrada (run/after), o NULL si no hay. '
  'Fuente única: la usa register_for_event para cobrar y el front para mostrar.';

GRANT EXECUTE ON FUNCTION public.tanda_vigente(UUID, TEXT) TO anon, authenticated;


-- ================================================================
-- 3. register_for_event() — ahora con tanda elegida y formulario
--
--    Cambios respecto de la versión del 2026-10-13:
--      · p_tipo     → qué entrada quiere ('run' | 'after'). NULL = evento
--                     sin ticket_tiers, se comporta como antes.
--      · p_form_data→ respuestas del formulario, se guardan tal cual.
--
--    Los parámetros nuevos van al final y con DEFAULT, así las llamadas que
--    ya existen siguen andando sin tocarlas.
-- ================================================================
DROP FUNCTION IF EXISTS public.register_for_event(UUID, BOOLEAN);

CREATE OR REPLACE FUNCTION public.register_for_event(
  p_event_id  UUID,
  p_after_run BOOLEAN DEFAULT FALSE,
  p_tipo      TEXT    DEFAULT NULL,
  p_form_data JSONB   DEFAULT NULL
)
RETURNS public.event_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event   public.events%ROWTYPE;
  v_user    UUID := (SELECT auth.uid());
  v_reg     public.event_registrations%ROWTYPE;
  v_tier    JSONB;
  v_tier_id TEXT;
  v_price   NUMERIC(12,2);
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'NO_AUTENTICADO: Iniciá sesión para reservar tu lugar.';
  END IF;

  -- ① Bloqueamos la fila del evento hasta el final de la transacción
  SELECT * INTO v_event
    FROM public.events
   WHERE id = p_event_id AND deleted_at IS NULL
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EVENTO_NO_ENCONTRADO: Este evento no existe o fue dado de baja.';
  END IF;

  IF NOT v_event.is_published THEN
    RAISE EXCEPTION 'EVENTO_NO_PUBLICADO: Este evento todavía no está abierto a inscripciones.';
  END IF;

  -- Si ya estaba inscripta, devolvemos su fila. No se recalcula precio ni
  -- se pisa el formulario: lo suyo ya quedó fijado.
  SELECT * INTO v_reg
    FROM public.event_registrations
   WHERE event_id = p_event_id AND user_id = v_user;
  IF FOUND THEN
    RETURN v_reg;
  END IF;

  IF v_event.sales_cutoff IS NOT NULL AND NOW() >= v_event.sales_cutoff THEN
    RAISE EXCEPTION
      'INSCRIPCION_CERRADA: Las inscripciones para "%" cerraron el %.',
      v_event.title,
      TO_CHAR(v_event.sales_cutoff AT TIME ZONE 'America/Argentina/Mendoza', 'DD/MM/YYYY HH24:MI');
  END IF;

  IF v_event.total_capacity IS NOT NULL
     AND COALESCE(v_event.sold_tickets, 0) >= v_event.total_capacity THEN
    RAISE EXCEPTION 'EVENTO_AGOTADO: Se acabaron los lugares para "%".', v_event.title;
  END IF;

  -- ② Precio y tanda
  IF jsonb_array_length(v_event.ticket_tiers) > 0 THEN
    -- Evento con tandas. El tipo lo elige quien compra; la tanda la decide
    -- el servidor, con el evento ya bloqueado.
    IF p_tipo IS NULL THEN
      RAISE EXCEPTION 'TIPO_REQUERIDO: Este evento tiene varias entradas, hay que elegir una.';
    END IF;

    v_tier := public.tanda_vigente(p_event_id, p_tipo);
    IF v_tier IS NULL THEN
      RAISE EXCEPTION 'TANDA_CERRADA: No quedan entradas de ese tipo para "%".', v_event.title;
    END IF;

    v_tier_id := v_tier->>'id';
    v_price   := (v_tier->>'precio')::numeric;
  ELSE
    -- Camino viejo: tanda early sobre base_price (migración 2026-10-13).
    v_tier_id := public.current_event_tier(v_event);
    v_price   := CASE WHEN v_tier_id = 'early' THEN v_event.early_price
                      ELSE v_event.base_price END;
  END IF;

  -- ③ Inserción + contador, misma transacción
  INSERT INTO public.event_registrations
    (event_id, user_id, after_run, price_locked, price_tier, form_data)
  VALUES
    (p_event_id, v_user, COALESCE(p_after_run, FALSE), v_price, v_tier_id,
     COALESCE(p_form_data, '{}'::jsonb))
  RETURNING * INTO v_reg;

  UPDATE public.events
     SET sold_tickets = COALESCE(sold_tickets, 0) + 1
   WHERE id = p_event_id;

  RETURN v_reg;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_for_event(UUID, BOOLEAN, TEXT, JSONB) TO authenticated;


-- ================================================================
-- 3bis. estado_tandas() — las entradas con su estado, para mostrar
--
--    tanda_vigente() devuelve UNA tanda: la que se puede comprar. La landing
--    necesita las cuatro, cada una con su cartelito (Activa, Próximamente,
--    Agotada, Cerrada).
--
--    Podría calcularse en el navegador leyendo ticket_tiers, pero entonces
--    habría dos implementaciones de la misma regla y, tarde o temprano, la
--    pantalla diría una cosa y el servidor cobraría otra. Se calcula acá.
--
--    No devuelve cuántos lugares quedan: el brief pide explícitamente no
--    mostrarlo, y lo que no se manda no se puede filtrar por error.
-- ================================================================
CREATE OR REPLACE FUNCTION public.estado_tandas(p_event_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tiers    JSONB;
  v_t        JSONB;
  v_out      JSONB := '[]'::jsonb;
  v_estado   TEXT;
  v_vigente  JSONB;
  v_vendidas INTEGER;
  v_abierta  BOOLEAN;
BEGIN
  SELECT ticket_tiers INTO v_tiers FROM public.events WHERE id = p_event_id;
  IF v_tiers IS NULL THEN RETURN '[]'::jsonb; END IF;

  FOR v_t IN SELECT * FROM jsonb_array_elements(v_tiers)
  LOOP
    v_vigente := public.tanda_vigente(p_event_id, v_t->>'tipo');

    SELECT COUNT(*) INTO v_vendidas
      FROM public.event_registrations r
     WHERE r.event_id = p_event_id
       AND r.status <> 'cancelled'
       AND r.price_tier = v_t->>'id';

    -- ¿Esta tanda es la que se está vendiendo?
    IF v_vigente IS NOT NULL AND v_vigente->>'id' = v_t->>'id' THEN
      v_estado := 'activa';
    ELSE
      -- No es la vigente. Hay tres razones posibles, y el orden importa:
      -- primero lo que ya pasó, después lo que todavía no empezó.
      v_abierta := (v_t->>'cierra' IS NULL OR NOW() < (v_t->>'cierra')::timestamptz)
                   AND NOT COALESCE((v_t->>'cerrada_manual')::boolean, FALSE);
      IF NOT v_abierta THEN
        v_estado := 'cerrada';
      ELSIF v_vendidas > 0 THEN
        -- Vendió y ya no es la vigente: se le acabó el cupo.
        v_estado := 'agotada';
      ELSE
        v_estado := 'proximamente';
      END IF;
    END IF;

    v_out := v_out || jsonb_build_object(
      'id',      v_t->>'id',
      'nombre',  v_t->>'nombre',
      'precio',  (v_t->>'precio')::numeric,
      'tipo',    v_t->>'tipo',
      'incluye', v_t->>'incluye',
      'cierra',  v_t->>'cierra',
      'estado',  v_estado
    );
  END LOOP;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION public.estado_tandas IS
  'Las entradas del evento con su estado (activa/proximamente/agotada/cerrada), '
  'para pintar la landing. No expone cupos restantes a propósito.';

GRANT EXECUTE ON FUNCTION public.estado_tandas(UUID) TO anon, authenticated;


-- ================================================================
-- 4. VERIFICACIÓN (comentado — correr a mano después de aplicar)
-- ================================================================
-- SELECT column_name FROM information_schema.columns
--  WHERE table_name='events' AND column_name IN ('ticket_tiers','form_schema','requires_form');
--
-- -- Firma nueva de register_for_event:
-- SELECT pg_get_function_identity_arguments(p.oid)
--   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname='register_for_event';
--
-- -- Los eventos viejos no se tocaron (todos con lista vacía):
-- SELECT COUNT(*) FILTER (WHERE ticket_tiers = '[]') AS sin_tandas,
--        COUNT(*) FILTER (WHERE ticket_tiers <> '[]') AS con_tandas
--   FROM public.events WHERE deleted_at IS NULL;
--
-- -- Prueba de cupo acumulado sobre Run & Wine (ver sección 5):
-- --   1) Inscribir 40 usuarios de tipo 'run' → los 40 a $20.000 (early).
-- --   2) El 41 → $30.000 (general), sin tocar nada a mano.
-- --   3) Un usuario de tipo 'after' → $20.000 y NO consumió cupo del run.
-- -- SELECT price_tier, COUNT(*), MIN(price_locked), MAX(price_locked)
-- --   FROM public.event_registrations WHERE event_id='<id>' GROUP BY 1;


-- ================================================================
-- 5. SEMILLA — el evento Run & Wine × Lamadrid
--
--    ⚠️ REVISAR ANTES DE CORRER. Dos datos del brief están sin definir y
--    quedaron con valores provisorios, marcados con TODO:
--      · cierre de Early Bird — el brief dice "[fecha a definir]"
--      · cupo de Solo After   — el brief dice "[a definir]"
--
--    Los cupos 40 / 120 / 150 son los del brief, que además aclara que son
--    una propuesta a confirmar con Sprinters antes de publicar.
--
--    Se inserta sólo si no existe, así re-correr el script no duplica.
-- ================================================================
INSERT INTO public.events (
  title, event_date, branch, location_text, base_price, total_capacity,
  sales_cutoff, is_published, custom_tag, requires_form, form_schema, ticket_tiers,
  description, landing_url
)
SELECT
  'Run & Wine × Lamadrid',
  '2026-11-14T18:00:00-03:00'::timestamptz,
  'social'::branch_type,
  'Lamadrid Estate Wines, Las Compuertas',
  30000,                                   -- precio de referencia (General)
  180,                                     -- 150 de run + 30 de after
  '2026-11-13T23:59:59-03:00'::timestamptz,
  FALSE,                                   -- ← se publica el 20/10
  'Run & Wine',
  TRUE,
  $json$[
    {"key":"distancia","label":"¿Qué distancia vas a correr?","type":"select",
     "options":["4K friendly","6K intermedia","8K desafío"],"required":true,
     "solo_tipo":"run"},
    {"key":"emergencia_nombre","label":"Contacto de emergencia (nombre)","type":"text","required":true},
    {"key":"emergencia_tel","label":"Contacto de emergencia (teléfono)","type":"tel","required":true},
    {"key":"apto_fisico","label":"Declaro estar en condiciones físicas para participar","type":"check","required":true},
    {"key":"deslinde","label":"Acepto el deslinde de responsabilidad","type":"check","required":true},
    {"key":"uso_imagen","label":"Autorizo el uso de mi imagen en fotos y videos del evento","type":"check","required":true},
    {"key":"datos_lamadrid","label":"Acepto que Sprinters comparta mis datos con Lamadrid","type":"check","required":true},
    {"key":"mayor_18","label":"Confirmo que soy mayor de 18 años","type":"check","required":true}
  ]$json$::jsonb,
  $json$[
    {"id":"early","nombre":"Early Bird","precio":20000,"tipo":"run",
     "incluye":"Run + degustación","cupo_hasta":40,
     "cierra":"2026-11-02T23:59:59-03:00","abre_con":null},
    {"id":"general","nombre":"General","precio":30000,"tipo":"run",
     "incluye":"Run + degustación","cupo_hasta":120,
     "cierra":"2026-11-09T23:59:59-03:00","abre_con":"early"},
    {"id":"lastcall","nombre":"Last Call","precio":38000,"tipo":"run",
     "incluye":"Run + degustación","cupo_hasta":150,
     "cierra":"2026-11-13T23:59:59-03:00","abre_con":"general"},
    {"id":"soloafter","nombre":"Solo After","precio":20000,"tipo":"after",
     "incluye":"Acceso al after (desde las 19:30) + degustación","cupo_hasta":30,
     "cierra":"2026-11-13T23:59:59-03:00","abre_con":null}
  ]$json$::jsonb,
  E'No es una carrera. Es una tarde entera: correr entre viñedos, sunset con degustación de vinos Lamadrid, quedarse a comer y bailar.\n\nNinguna entrada incluye gastronomía: Los Bocheros se paga en el lugar según consumo.',
  '/runandwine'
WHERE NOT EXISTS (
  SELECT 1 FROM public.events WHERE title = 'Run & Wine × Lamadrid' AND deleted_at IS NULL
);

-- TODO(fecha): cuando se defina el cierre real de Early Bird:
--   UPDATE public.events
--      SET ticket_tiers = jsonb_set(ticket_tiers, '{0,cierra}', '"2026-11-0X..."')
--    WHERE title = 'Run & Wine × Lamadrid';
-- TODO(cupo): ídem con el cupo de Solo After, en '{3,cupo_hasta}'.


-- ================================================================
-- 6. CÓMO REVERTIR
-- ================================================================
-- DELETE FROM public.events WHERE title = 'Run & Wine × Lamadrid';
-- DROP FUNCTION IF EXISTS public.tanda_vigente(UUID, TEXT);
-- Restaurar la restricción original de eventos sociales:
--   ALTER TABLE public.events DROP CONSTRAINT IF EXISTS chk_social_event_requirements;
--   ALTER TABLE public.events ADD CONSTRAINT chk_social_event_requirements CHECK (
--     branch <> 'social' OR (partner_id IS NOT NULL AND logistics_type IS NOT NULL
--       AND sales_cutoff IS NOT NULL AND base_price IS NOT NULL AND total_capacity IS NOT NULL));
-- DROP TRIGGER IF EXISTS trg_validar_ticket_tiers ON public.events;
-- DROP FUNCTION IF EXISTS public.validar_ticket_tiers();
-- -- y volver a aplicar la sección 4 de 2026-10-13_tandas_early_general.sql
-- -- para restaurar register_for_event sin p_tipo/p_form_data.
