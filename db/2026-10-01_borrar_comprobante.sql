-- ================================================================
--  Sprinters · Eliminar / reemplazar el comprobante de un evento
--  PostgreSQL 15 / Supabase · 2026-10-01
--
--  REQUISITO: 2026-07-13_events_transfer_receipts.sql (crea el bucket
--             'payment-receipts' y las políticas de INSERT/SELECT) y
--             2026-08-04_inscripcion_atomica_y_comprobantes.sql
--             (submit_event_receipt, auto_verified).
--             Este script es ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR:
--    A) python db/sb_mgmt.py migrate db/2026-10-01_borrar_comprobante.sql
--    B) Supabase Dashboard → SQL Editor → New query → pegar completo → Run
--    Verificación al final del archivo (comentada).
--
--  ⚠️ SIN ESTE SCRIPT el botón "Eliminar" de Evento.html devuelve
--     "Could not find the function public.delete_event_receipt". El botón
--     "Cambiar" sí anda sin esto, porque reusa submit_event_receipt.
--
--  ----------------------------------------------------------------
--  POR QUÉ ESTO REVIERTE UNA DECISIÓN ANTERIOR
--
--  La migración del 2026-07-13 dejó escrito, en el bloque de políticas
--  del bucket:
--
--      -- No hay UPDATE/DELETE: un comprobante subido no se edita, se
--      -- vuelve a subir (nueva fila / nuevo archivo) si un admin lo rechaza.
--
--  El criterio era que un comprobante es evidencia de pago y no se borra.
--  Sigue siendo válido para el admin, pero dejaba sin salida al caso real:
--  la persona sube el archivo equivocado (la captura de otra transferencia,
--  una foto movida) y no tiene forma de corregirlo salvo escribir al club.
--
--  Lo que se habilita acá es acotado y no abre el agujero de auditoría:
--    · Solo el dueño de la inscripción puede borrar SU comprobante.
--    · Borrar NO deja el lugar confirmado sin respaldo: payment_status
--      vuelve a 'not_required', así que la inscripción figura impaga y
--      el admin la ve como tal.
--    · La inscripción NO se cancela y sold_tickets NO se toca: la persona
--      sigue anotada, solo le falta volver a subir el comprobante.
--    · Un admin sigue sin poder borrar comprobantes ajenos desde la web.
--
--  Si en algún momento hace falta trazabilidad de los borrados, el lugar
--  es una tabla de auditoría aparte (quién borró qué y cuándo), no
--  bloquear de nuevo la acción.
-- ================================================================


-- ================================================================
-- 1. Política de DELETE en el bucket 'payment-receipts'
--    Mismo patrón que receipts_insert_own: la primera carpeta del path
--    es el uid del dueño, así que solo puede borrar lo suyo.
--    Los admin NO entran acá a propósito (solo tienen SELECT).
-- ================================================================
DROP POLICY IF EXISTS "receipts_delete_own" ON storage.objects;
CREATE POLICY "receipts_delete_own"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'payment-receipts'
    AND (storage.foldername(name))[1] = (select auth.uid())::text
  );


-- ================================================================
-- 2. delete_event_receipt() — desvincula el comprobante de la inscripción
--
--    Solo toca la fila. El archivo en Storage lo borra el cliente con
--    storage.remove() usando la política de arriba, y es best-effort:
--    si queda huérfano no pasa nada grave (bucket privado, sin URL
--    pública, y la fila ya no lo referencia).
--
--    Orden en el cliente: primero esta RPC, después el remove(). Al revés
--    dejaría la fila apuntando a un archivo inexistente si la RPC falla.
-- ================================================================
CREATE OR REPLACE FUNCTION public.delete_event_receipt(reg_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.event_registrations
     SET receipt_url         = NULL,
         receipt_uploaded_at = NULL,
         payment_status      = 'not_required',
         auto_verified       = FALSE,
         -- Se limpia la revisión previa: si un admin la había aprobado,
         -- esa aprobación era sobre un archivo que ya no está.
         payment_reviewed_by = NULL,
         payment_reviewed_at = NULL
   WHERE id = reg_id
     AND user_id = (SELECT auth.uid())
     -- No se permite borrar después de que el evento pasó: a esa altura
     -- el comprobante es el único respaldo de que la persona pagó.
     AND EXISTS (
       SELECT 1 FROM public.events e
        WHERE e.id = event_registrations.event_id
          AND e.event_date > NOW()
     );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No encontramos esa inscripción, no te pertenece, o el evento ya pasó';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.delete_event_receipt IS
  'El usuario elimina su propio comprobante antes de que el evento ocurra. '
  'La inscripción sigue viva y el cupo no se libera, pero payment_status '
  'vuelve a not_required para que figure impaga hasta que suba otro.';

GRANT EXECUTE ON FUNCTION public.delete_event_receipt(UUID) TO authenticated;


-- ================================================================
-- 3. Tope de tamaño explícito en el bucket
--
--    El bucket se creó sin file_size_limit, así que hereda el global del
--    proyecto. Se fija en 15 MB para que coincida con el tope duro del
--    front (RECEIPT_MAX_UPLOAD_MB en Evento.html).
--
--    OJO: el front comprime las imágenes antes de subir (máx. 2000px de
--    lado, JPEG 0.85), así que en la práctica lo que llega acá son
--    archivos de cientos de KB. Los 15 MB son para los PDF, que no se
--    pueden recomprimir en el navegador.
--
--    Si se cambia este número, cambiar también RECEIPT_MAX_UPLOAD_MB.
-- ================================================================
UPDATE storage.buckets
   SET file_size_limit = 15728640          -- 15 MB en bytes
 WHERE id = 'payment-receipts';


-- ================================================================
-- 4. VERIFICACIÓN (comentado — correr a mano después de aplicar)
-- ================================================================
-- -- La función existe y tiene el grant:
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'delete_event_receipt';
--
-- SELECT has_function_privilege('authenticated', 'public.delete_event_receipt(uuid)', 'EXECUTE');
--
-- -- Las tres políticas del bucket (insert / select / delete):
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname = 'storage' AND tablename = 'objects'
--    AND policyname LIKE 'receipts_%'
--  ORDER BY policyname;
--
-- -- El tope quedó seteado:
-- SELECT id, public, file_size_limit FROM storage.buckets WHERE id = 'payment-receipts';
--
-- -- Prueba funcional (con un usuario real, NO con service_role):
-- --   1) Anotarse a un evento pago y subir un comprobante.
-- --   2) SELECT receipt_url, payment_status FROM event_registrations WHERE id = '<reg>';
-- --      → receipt_url con path, payment_status = 'verified'
-- --   3) Apretar Eliminar en la web.
-- --   4) Repetir el SELECT → receipt_url NULL, payment_status = 'not_required'
-- --   5) SELECT sold_tickets FROM events WHERE id = '<evento>'; → NO cambió


-- ================================================================
-- 5. CÓMO REVERTIR
-- ================================================================
-- DROP POLICY IF EXISTS "receipts_delete_own" ON storage.objects;
-- DROP FUNCTION IF EXISTS public.delete_event_receipt(UUID);
-- UPDATE storage.buckets SET file_size_limit = NULL WHERE id = 'payment-receipts';
-- -- Y en Evento.html: sacar el botón #receiptDelete de receiptCurrentHtml().
