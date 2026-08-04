-- ================================================================
--  SPRINTERS OS · Migración v1.5 · Cancelar suscripción pendiente (cambiar de plan)
--  PostgreSQL 15 / Supabase · 2026-07-28
--
--  REQUISITO: 2026-07-28_running_transfer_and_afterrun_price.sql ya aplicada.
--  ADITIVO e IDEMPOTENTE.
--
--  CÓMO APLICAR:
--    python db/sb_mgmt.py migrate db/2026-07-28_cancel_pending_subscription.sql
--
--  POR QUÉ:
--    Un usuario que crea una suscripción pendiente (eligió Core/Pro pero
--    todavía no subió comprobante, o se lo rechazaron) quedaba trabado:
--    no tiene GRANT DELETE/UPDATE sobre subscriptions, así que no podía
--    cambiar de plan ni cancelar el intento. Esta función se lo permite,
--    pero SOLO mientras no haya sido verificado por un admin (no se puede
--    "cancelar" una suscripción ya paga/activa desde acá).
-- ================================================================

CREATE OR REPLACE FUNCTION public.cancel_own_pending_subscription(sub_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.subscriptions
   WHERE id = sub_id
     AND user_id = (SELECT auth.uid())
     AND status <> 'active'
     AND payment_status <> 'verified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se pudo cancelar: la suscripción no existe, no te pertenece, o ya está activa/verificada.';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.cancel_own_pending_subscription IS
  'Permite al usuario borrar su propia suscripción todavía no verificada, para poder elegir otro plan. '
  'Bloqueado si status=active o payment_status=verified (ya la aprobó un admin).';

GRANT EXECUTE ON FUNCTION public.cancel_own_pending_subscription(UUID) TO authenticated;
