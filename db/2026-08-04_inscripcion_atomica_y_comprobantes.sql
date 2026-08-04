-- ================================================================
--  SPRINTERS OS · Migración v1.6 · Inscripción atómica + comprobantes
--  PostgreSQL 15 / Supabase · 2026-08-04
--
--  REQUISITO: 2026-08-04_plus_birthdate_afterrun.sql ya aplicada.
--  ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR:
--    python db/sb_mgmt.py migrate db/2026-08-04_inscripcion_atomica_y_comprobantes.sql
--
--  ALCANCE:
--    1. events.sold_tickets pasa a contarse de verdad. Hasta hoy solo lo
--       incrementaba book_ticket_safely() (flujo viejo de Mercado Pago sobre
--       la tabla tickets), mientras que el flujo real inserta en
--       event_registrations. Resultado: el cupo mostrado en la web siempre
--       decía el total y "agotado" no se disparaba nunca.
--    2. register_for_event(): inscripción atómica que valida cierre de
--       inscripción, cupo y publicación del lado del servidor.
--    3. submit_event_receipt() confirma el lugar al instante, igual que ya
--       hace submit_subscription_receipt() con las suscripciones.
--
--  DECISIÓN EXPLÍCITA (2026-08-04): NO se revoca el INSERT directo sobre
--  event_registrations. La RPC es el camino que usa la web y deja el cupo
--  bien contado, pero la puerta vieja queda abierta a pedido — el volumen
--  de eventos hoy no justifica el riesgo de cortar inscripciones si la
--  función falla. Para cerrarla más adelante alcanza con:
--      REVOKE INSERT ON public.event_registrations FROM authenticated;
-- ================================================================


-- ================================================================
-- 1. BACKFILL de sold_tickets
--    Las inscripciones que ya existen nunca se contaron. Antes de que la
--    RPC empiece a incrementar hay que partir del número real, si no el
--    contador arranca desfasado para siempre.
--    Criterio acordado: cuenta todo lo que no esté cancelado, haya pagado
--    o no — quien está anotado ocupa lugar.
-- ================================================================
UPDATE public.events e
   SET sold_tickets = COALESCE((
         SELECT COUNT(*)
           FROM public.event_registrations r
          WHERE r.event_id = e.id
            AND r.status <> 'cancelled'
       ), 0);


-- ================================================================
-- 2. event_registrations.auto_verified
--    Mismo criterio que subscriptions: marca las filas que se confirmaron
--    solas al subir el comprobante, sin que las mire un humano. Es el
--    gancho para el script de verificación (monto + alias) que va después.
-- ================================================================
ALTER TABLE public.event_registrations
  ADD COLUMN IF NOT EXISTS auto_verified BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.event_registrations.auto_verified IS
  'TRUE = se confirmó sola al subir el comprobante, sin revisión humana. '
  'Pendiente de auditar por el script de verificación de comprobantes.';


-- ================================================================
-- 3. register_for_event() — inscripción atómica
--
--    ① FOR UPDATE sobre el evento: si dos personas mandan el último lugar
--       en el mismo instante, una espera y la otra recibe EVENTO_AGOTADO.
--       Sin esto las dos leen "queda 1" y las dos entran.
--    ② Valida que el evento exista, esté publicado y no borrado.
--    ③ Valida sales_cutoff (hasta hoy solo se chequeaba en el navegador).
--    ④ Valida cupo si total_capacity no es NULL (NULL = sin límite).
--    ⑤ Inserta e incrementa sold_tickets en la misma transacción.
--
--    Si la persona ya estaba inscripta devuelve su inscripción existente
--    en vez de fallar: el usuario que recarga y vuelve a apretar no ve un
--    error, ve su lugar.
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

  -- ⑤ Inserción + contador, misma transacción
  INSERT INTO public.event_registrations (event_id, user_id, after_run)
  VALUES (p_event_id, v_user, COALESCE(p_after_run, FALSE))
  RETURNING * INTO v_reg;

  UPDATE public.events
     SET sold_tickets = COALESCE(sold_tickets, 0) + 1
   WHERE id = p_event_id;

  RETURN v_reg;
END;
$$;

COMMENT ON FUNCTION public.register_for_event IS
  'Inscripción atómica a un evento. Valida publicación, cierre y cupo con la fila '
  'del evento bloqueada (FOR UPDATE) y mantiene events.sold_tickets al día. '
  'Si la persona ya estaba inscripta devuelve su fila sin duplicar ni recontar.';

GRANT EXECUTE ON FUNCTION public.register_for_event(UUID, BOOLEAN) TO authenticated;


-- ================================================================
-- 4. cancel_own_registration() — liberar el lugar
--    Sin esto, una baja deja el cupo ocupado para siempre. Marca la
--    inscripción como cancelada y descuenta el contador en la misma
--    transacción (con piso en 0 por si el backfill quedó corto).
-- ================================================================
CREATE OR REPLACE FUNCTION public.cancel_own_registration(reg_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reg public.event_registrations%ROWTYPE;
BEGIN
  SELECT * INTO v_reg
    FROM public.event_registrations
   WHERE id = reg_id
     AND user_id = (SELECT auth.uid());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Inscripción no encontrada o no te pertenece';
  END IF;

  IF v_reg.status = 'cancelled' THEN
    RETURN;   -- idempotente: cancelar dos veces no descuenta dos lugares
  END IF;

  UPDATE public.event_registrations
     SET status = 'cancelled'
   WHERE id = reg_id;

  UPDATE public.events
     SET sold_tickets = GREATEST(COALESCE(sold_tickets, 0) - 1, 0)
   WHERE id = v_reg.event_id;
END;
$$;

COMMENT ON FUNCTION public.cancel_own_registration IS
  'Baja de un evento por parte del propio usuario. Libera el lugar en '
  'events.sold_tickets. Idempotente: cancelar una inscripción ya cancelada no hace nada.';

GRANT EXECUTE ON FUNCTION public.cancel_own_registration(UUID) TO authenticated;

-- El usuario necesita poder escribir status para su propia baja vía la función
-- de arriba; la función es SECURITY DEFINER así que no hace falta GRANT extra
-- sobre la columna. Se deja constancia de que NO se otorga UPDATE(status)
-- directo: cancelar sin pasar por la función dejaría el contador desfasado.


-- ================================================================
-- 5. submit_event_receipt() — confirma el lugar al instante
--
--    Decisión de producto (2026-08-04): igual que las suscripciones, el
--    comprobante confirma en el acto. Antes dejaba la inscripción en
--    'pending_review' esperando una revisión manual que no tenía pantalla
--    donde ocurrir, así que quedaban clavadas para siempre.
--    El archivo se guarda igual y auto_verified marca que falta auditarla.
-- ================================================================
CREATE OR REPLACE FUNCTION public.submit_event_receipt(reg_id UUID, receipt_path TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.event_registrations
     SET receipt_url         = receipt_path,
         receipt_uploaded_at = NOW(),
         payment_status      = 'verified',
         auto_verified       = TRUE
   WHERE id = reg_id
     AND user_id = (SELECT auth.uid());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Inscripción no encontrada o no te pertenece';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.submit_event_receipt IS
  'El usuario sube el comprobante y su lugar queda confirmado al instante '
  '(sin cola de revisión). auto_verified=TRUE para auditoría posterior.';

-- Rechazo por parte de un admin: además de marcar rejected, libera el lugar.
-- Antes solo cambiaba payment_status, así que un comprobante trucho seguía
-- ocupando cupo.
CREATE OR REPLACE FUNCTION public.review_event_payment(reg_id UUID, approve BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reg public.event_registrations%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = (SELECT auth.uid()) AND u.is_admin) THEN
    RAISE EXCEPTION 'Solo un admin puede revisar comprobantes';
  END IF;

  SELECT * INTO v_reg FROM public.event_registrations WHERE id = reg_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Inscripción no encontrada';
  END IF;

  UPDATE public.event_registrations
     SET payment_status      = CASE WHEN approve THEN 'verified' ELSE 'rejected' END,
         payment_reviewed_by = (SELECT auth.uid()),
         payment_reviewed_at = NOW(),
         auto_verified       = FALSE,
         status              = CASE WHEN approve THEN status ELSE 'cancelled'::registration_status_type END
   WHERE id = reg_id;

  -- Si se rechaza y todavía ocupaba lugar, lo devolvemos al cupo
  IF NOT approve AND v_reg.status <> 'cancelled' THEN
    UPDATE public.events
       SET sold_tickets = GREATEST(COALESCE(sold_tickets, 0) - 1, 0)
     WHERE id = v_reg.event_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.review_event_payment(UUID, BOOLEAN) TO authenticated;


-- ================================================================
-- 6. VERIFICACIÓN RÁPIDA (comentado — correr a mano si querés confirmar)
-- ================================================================
-- -- El contador tiene que coincidir con las inscripciones reales:
-- SELECT e.title, e.total_capacity, e.sold_tickets,
--        (SELECT COUNT(*) FROM public.event_registrations r
--          WHERE r.event_id = e.id AND r.status <> 'cancelled') AS reales
--   FROM public.events e WHERE e.deleted_at IS NULL ORDER BY e.event_date DESC;
--
-- SELECT column_name FROM information_schema.columns
--  WHERE table_name = 'event_registrations' AND column_name = 'auto_verified';
