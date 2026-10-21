-- ================================================================
--  2026-10-21 · Exportar inscriptos de un evento
--
--  Qué resuelve: hoy no hay forma de ver desde la web quién se anotó a un
--  evento. Los datos existen (event_registrations + users) pero sólo se
--  llegan con SQL, y para el día del evento hace falta una lista imprimible
--  con nombre, teléfono, distancia y contacto de emergencia.
--
--  Esta función la consume el botón "Exportar inscriptos" del Admin, que
--  arma un CSV en el navegador. No hace falta Google Drive ni cuentas de
--  servicio: el CSV se abre en Sheets, Excel o lo que sea.
--
--  Por qué una RPC y no un SELECT desde el front: event_registrations tiene
--  RLS que deja ver sólo las filas propias (evreg_select_own). Un admin
--  consultando la tabla directamente vería únicamente SUS inscripciones.
--  SECURITY DEFINER + _require_admin() es el mismo patrón que ya usan
--  admin_list_users y admin_list_events.
--
--  CÓMO CORRERLO: pegar entero en el SQL Editor de Supabase. Es idempotente.
-- ================================================================


-- ────────────────────────────────────────────────────────────────
-- 1. LA FUNCIÓN
--
--    Devuelve una fila por inscripción, con los datos de la persona ya
--    resueltos (el front no puede hacer el JOIN: no ve public.users).
--
--    form_data va entero como JSONB en vez de abrir una columna por
--    respuesta: cada evento tiene su propio form_schema, así que las
--    columnas cambian de evento en evento. El Admin las despliega leyendo
--    las claves que encuentra.
-- ────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.admin_list_event_registrations(UUID);

CREATE OR REPLACE FUNCTION public.admin_list_event_registrations(
  p_event_id UUID
)
RETURNS TABLE (
  inscripta_el     TIMESTAMPTZ,
  nombre           TEXT,
  email            TEXT,
  telefono         TEXT,
  tanda            TEXT,
  precio           NUMERIC,
  estado_pago      TEXT,
  tiene_comprobante BOOLEAN,
  after_run        BOOLEAN,
  respuestas       JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._require_admin();

  -- El email NO está en public.users: vive en auth.users, igual que en
  -- admin_list_users. Por eso el JOIN es contra las dos tablas.
  -- Los LEFT JOIN son a propósito: si una cuenta se dio de baja, la
  -- inscripción tiene que seguir apareciendo en la lista del día del evento,
  -- aunque sea sin nombre.
  RETURN QUERY
  SELECT
    r.created_at,
    NULLIF(TRIM(COALESCE(u.first_name,'') || ' ' || COALESCE(u.last_name,'')), ''),
    au.email::TEXT,
    u.phone,
    r.price_tier,
    r.price_locked,
    r.payment_status::TEXT,
    r.receipt_url IS NOT NULL,
    COALESCE(r.after_run, FALSE),
    COALESCE(r.form_data, '{}'::jsonb)
  FROM public.event_registrations r
  LEFT JOIN public.users u  ON u.id  = r.user_id
  LEFT JOIN auth.users  au  ON au.id = r.user_id
  WHERE r.event_id = p_event_id
  ORDER BY r.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_event_registrations(UUID) TO authenticated;


-- ================================================================
--  VERIFICACIÓN
-- ================================================================
-- 1) La función existe y tiene el GRANT:
--
--    SELECT p.proname, p.prosecdef AS security_definer,
--           has_function_privilege('authenticated', p.oid, 'EXECUTE') AS puede_authenticated
--      FROM pg_proc p
--      JOIN pg_namespace n ON n.oid = p.pronamespace
--     WHERE n.nspname = 'public' AND p.proname = 'admin_list_event_registrations';
--
--    Esperado: security_definer = true, puede_authenticated = true.
--
-- 2) Probarla con el evento de Run & Wine (logueado como admin):
--
--    SELECT * FROM public.admin_list_event_registrations(
--      (SELECT id FROM public.events WHERE landing_url = '/runandwine')
--    );
--
--    Si todavía no hay inscriptos devuelve 0 filas, no error.
--
-- 3) Que un usuario NO admin reciba el error de permisos:
--    _require_admin() tira excepción, así que desde una cuenta común la
--    llamada falla. Eso es lo correcto.


-- ================================================================
--  CÓMO REVERTIR
-- ================================================================
-- DROP FUNCTION IF EXISTS public.admin_list_event_registrations(UUID);
--
-- No toca tablas ni datos: sólo agrega una función de lectura.
