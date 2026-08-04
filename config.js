/* ================================================================
 *  Sprinters · Configuración compartida del front
 *
 *  Datos que aparecen en más de una página. Antes estaban duplicados en
 *  Evento.html y Suscripcion Running.html: si cambiaba el alias y se
 *  actualizaba uno solo, la gente transfería a un alias viejo.
 *
 *  EDITAR ACÁ y se actualiza en todos lados.
 *
 *  Nota: esto es configuración pública (aparece igual en el HTML servido).
 *  No poner acá nada secreto — las claves privadas van en Edge Functions.
 * ================================================================ */
window.SPRINTERS = {

  // ── Datos de transferencia del club ──────────────────────────────
  BANK: {
    alias:   'sprintersine',
    titular: 'Inés Bahamondes - NaranjaX'
  },

  // ── Contacto para cancelaciones y pago en efectivo (internacionales) ──
  CONTACT_PHONE: '+54 9 2615517128',

  // ── Términos y Condiciones de Participación ──────────────────────
  TERMS_URL: 'https://drive.google.com/file/d/1-mHoaNZmDMo-vwQluwJfKZpmYVRUz6RE/view',

  // ── Supabase (claves públicas: la protección real es RLS) ────────
  SUPABASE_URL: 'https://lzvsttrbofnktnilunwd.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_tXVIeheQvj9fnk_WFeyHYQ_StxuNmna'
};
