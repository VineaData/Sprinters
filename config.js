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
    // Cambiado el 2026-10-21: la plata pasa a la cuenta de Alan.
    // Esto lo lee TODA página que cobre por transferencia, así que al tocarlo
    // cambia el alias en Run & Wine, Evento y Suscripción Running a la vez.
    alias:   'sprinters',
    titular: 'Alan Hamer (NaranjaX)'
  },

  // ── Contacto para cancelaciones y pago en efectivo (internacionales) ──
  CONTACT_PHONE: '+54 9 2615517128',

  // ── Términos y Condiciones de Participación ──────────────────────
  TERMS_URL: 'https://drive.google.com/file/d/1-mHoaNZmDMo-vwQluwJfKZpmYVRUz6RE/view',

  // ── Redes y comunidad ────────────────────────────────────────────
  // Desde el 2026-10-01 el cierre de la landing ya no pide mail: manda a la
  // comunidad de WhatsApp y al Instagram (ver doc de cambios de la reunión).
  //
  // TODO(link): WHATSAPP_COMUNIDAD tiene que ser el link de invitación del
  // grupo/comunidad (https://chat.whatsapp.com/XXXXXXXX), que lo saca un
  // admin desde WhatsApp → Invitar al grupo → Copiar enlace. Mientras tanto
  // queda el chat uno a uno con el número del club, que funciona pero no es
  // lo pedido.
  WHATSAPP_COMUNIDAD: 'https://wa.me/542619298844?text=' +
    encodeURIComponent('Hola! Quiero sumarme a la comunidad de Sprinters.'),
  INSTAGRAM_URL: 'https://instagram.com/sprintersmza',

  // ── Supabase (claves públicas: la protección real es RLS) ────────
  SUPABASE_URL: 'https://lzvsttrbofnktnilunwd.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_tXVIeheQvj9fnk_WFeyHYQ_StxuNmna'
};
