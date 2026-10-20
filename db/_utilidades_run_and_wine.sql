-- ================================================================
--  Run & Wine · UTILIDADES PARA PROBAR
--
--  ⚠️ ESTO NO ES UNA MIGRACIÓN. No hay que correrlo entero: son bloques
--  sueltos para usar durante las pruebas. Copiá y pegá el que necesites.
--
--  Por qué existe: el evento se siembra con is_published = FALSE para que
--  no aparezca público antes del lanzamiento del 20/10. Pero sin publicar
--  no se puede probar nada, porque:
--    · la agenda de la home filtra is_published = true
--    · register_for_event corta con EVENTO_NO_PUBLICADO
--
--  El ciclo de prueba es: publicar → probar → limpiar → despublicar.
-- ================================================================


-- ────────────────────────────────────────────────────────────────
-- 1. VER EL ESTADO ACTUAL
--    Empezar siempre por acá: dice si el evento existe, si está publicado
--    y cuántas inscripciones tiene.
-- ────────────────────────────────────────────────────────────────
SELECT id, title, is_published, sold_tickets, total_capacity,
       landing_url, jsonb_array_length(ticket_tiers) AS tandas,
       jsonb_array_length(form_schema) AS campos_form
  FROM public.events
 WHERE landing_url = '/runandwine' AND deleted_at IS NULL;

-- Qué tanda está vigente ahora mismo, para cada tipo de entrada:
SELECT 'run'   AS tipo, public.tanda_vigente(id, 'run')   AS vigente FROM public.events WHERE landing_url = '/runandwine'
UNION ALL
SELECT 'after', public.tanda_vigente(id, 'after')          FROM public.events WHERE landing_url = '/runandwine';

-- Las cuatro entradas con su estado, igual que lo ve la landing:
SELECT jsonb_pretty(public.estado_tandas(id))
  FROM public.events WHERE landing_url = '/runandwine';


-- ────────────────────────────────────────────────────────────────
-- 2. PUBLICAR (para poder probar)
--
--    OJO: desde que corrés esto, el evento aparece en la agenda de la home
--    y cualquiera que entre al sitio lo ve. Si falta para el lanzamiento,
--    acordate de despublicarlo cuando termines (bloque 4).
-- ────────────────────────────────────────────────────────────────
UPDATE public.events
   SET is_published = TRUE
 WHERE landing_url = '/runandwine';


-- ────────────────────────────────────────────────────────────────
-- 3. LIMPIAR LAS INSCRIPCIONES DE PRUEBA
--
--    Importante hacerlo antes del lanzamiento: cada compra de prueba
--    incrementa sold_tickets y consume cupo de la tanda early. Si quedan
--    tres pruebas adentro, las primeras 37 personas pagan early en vez
--    de las primeras 40.
--
--    Borra las inscripciones Y devuelve el contador a su valor real.
-- ────────────────────────────────────────────────────────────────
WITH ev AS (
  SELECT id FROM public.events WHERE landing_url = '/runandwine' AND deleted_at IS NULL
), borradas AS (
  DELETE FROM public.event_registrations
   WHERE event_id = (SELECT id FROM ev)
  RETURNING 1
)
UPDATE public.events
   SET sold_tickets = 0
 WHERE id = (SELECT id FROM ev);

-- Si sólo querés borrar TU inscripción y dejar las demás:
-- DELETE FROM public.event_registrations
--  WHERE event_id = (SELECT id FROM public.events WHERE landing_url = '/runandwine')
--    AND user_id  = (SELECT id FROM public.users WHERE email = 'tu@mail.com');
-- UPDATE public.events SET sold_tickets = GREATEST(sold_tickets - 1, 0)
--  WHERE landing_url = '/runandwine';


-- ────────────────────────────────────────────────────────────────
-- 4. DESPUBLICAR (volver al estado de pre-lanzamiento)
-- ────────────────────────────────────────────────────────────────
UPDATE public.events
   SET is_published = FALSE
 WHERE landing_url = '/runandwine';


-- ────────────────────────────────────────────────────────────────
-- 5. VER QUIÉN SE ANOTÓ Y QUÉ RESPONDIÓ
--    Es lo que hay que mirar después de una compra de prueba para
--    confirmar que el precio quedó bien fijado y el formulario se guardó.
-- ────────────────────────────────────────────────────────────────
SELECT r.created_at,
       u.email,
       r.price_tier                AS tanda,
       r.price_locked              AS precio_fijado,
       r.payment_status            AS pago,
       r.receipt_url IS NOT NULL   AS tiene_comprobante,
       jsonb_pretty(r.form_data)   AS formulario
  FROM public.event_registrations r
  JOIN public.events e ON e.id = r.event_id
  LEFT JOIN public.users u ON u.id = r.user_id
 WHERE e.landing_url = '/runandwine'
 ORDER BY r.created_at DESC;


-- ────────────────────────────────────────────────────────────────
-- 6. PROBAR EL SALTO DE TANDA SIN VENDER 40 ENTRADAS
--
--    Bajar el cupo de Early a 1 hace que la segunda inscripción ya pase a
--    General. Es la forma rápida de verificar que el escalón funciona.
--    Acordate de dejarlo en 40 antes del lanzamiento.
-- ────────────────────────────────────────────────────────────────
-- UPDATE public.events
--    SET ticket_tiers = jsonb_set(ticket_tiers, '{0,cupo_hasta}', '1')
--  WHERE landing_url = '/runandwine';

-- Volver a dejarlo como el brief:
-- UPDATE public.events
--    SET ticket_tiers = jsonb_set(ticket_tiers, '{0,cupo_hasta}', '40')
--  WHERE landing_url = '/runandwine';


-- ────────────────────────────────────────────────────────────────
-- 7. CORREGIR abre_con DE SOLO AFTER  (correr una sola vez)
--
--    El evento se creó con Solo After sin dependencia, así que salía a la
--    venta desde el primer día. El brief dice que se habilita recién al
--    cerrar Early Bird. La migración ya quedó corregida para los eventos
--    nuevos; esto arregla el que ya existe.
--
--    Verificar después con el bloque 1: Solo After tiene que figurar
--    "proximamente" mientras Early Bird siga activa.
-- ────────────────────────────────────────────────────────────────
UPDATE public.events
   SET ticket_tiers = jsonb_set(ticket_tiers, '{3,abre_con}', '"early"')
 WHERE landing_url = '/runandwine'
   AND ticket_tiers->3->>'id' = 'soloafter';

-- Confirmar que quedó bien:
-- SELECT ticket_tiers->3->>'id'       AS tanda,
--        ticket_tiers->3->>'abre_con' AS abre_con
--   FROM public.events WHERE landing_url = '/runandwine';


-- ────────────────────────────────────────────────────────────────
-- 8. CAMBIAR LA FOTO DE LA TARJETA DE LA AGENDA  (correr una sola vez)
--
--    La tarjeta de la home saca su imagen de events.cover_image_url. Si está
--    en NULL usa una por defecto según la rama, que es lo que venía pasando.
--
--    La ruta es relativa al sitio, no una URL de Storage: el archivo viaja en
--    el repo. Funciona igual desde "/" que desde "/Landing v2.html" porque en
--    los dos casos resuelve contra la raíz del dominio.
--
--    OJO: el archivo tiene que estar publicado ANTES de correr esto, o la
--    tarjeta queda con la imagen rota. Pushear primero, después el UPDATE.
-- ────────────────────────────────────────────────────────────────
UPDATE public.events
   SET cover_image_url = 'images/rw/agenda-card.jpg'
 WHERE landing_url = '/runandwine'
   AND deleted_at IS NULL;

-- Confirmar:
-- SELECT title, cover_image_url FROM public.events WHERE landing_url = '/runandwine';

-- Para volver a la foto por defecto:
-- UPDATE public.events SET cover_image_url = NULL WHERE landing_url = '/runandwine';
