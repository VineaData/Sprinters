/* ================================================================
 *  Sprinters · Lógica de inscripción a eventos
 *
 *  Qué hace: preparar el comprobante (validar y comprimir), reservar el
 *  lugar y subir el archivo. Nada de DOM — cada página pone su markup y su
 *  diseño, pero el cobro vive en un solo lugar.
 *
 *  Por qué existe: la compra pasó a estar en dos pantallas distintas, la
 *  página de evento y la landing de Run & Wine. Copiar la lógica en las dos
 *  garantizaba que algún día divergieran: se arregla un borde en una y la
 *  otra sigue cobrando mal. Esto es el mínimo compartido.
 *
 *  Se carga con una etiqueta script apuntando a inscripcion.js, antes del
 *  script de la página, y expone window.SprintersInscripcion.
 *
 *  (El cierre de esa etiqueta NO se escribe literal en este comentario:
 *   si alguien inlinea este archivo dentro de un <script>, el parser de
 *   HTML cerraría el bloque ahí y volcaría el resto como texto.)
 * ================================================================ */
(function (global) {
  'use strict';

  /* ── Comprobantes: tamaño y compresión ─────────────────────────
     Antes el tope era 5 MB y se rechazaba el archivo de una. Una foto de
     cualquier celular actual pasa ese límite sin esfuerzo, así que el que
     sacaba la foto del comprobante no podía anotarse.

     En vez de subir el techo y listo, las imágenes se reducen en el
     navegador antes de subirlas: una foto de 12 MB viaja como ~500 KB. Es
     mejor para quien sube (con datos móviles la diferencia es enorme) y
     para el Storage. Un comprobante se mira, no se imprime: 2000px de lado
     largo sobran.

     Los PDF no se tocan — no se pueden recomprimir sin una librería — así
     que ahí sí hay un tope duro, pero holgado. */
  const MAX_INPUT_MB  = 25;    // lo que se acepta del disco antes de procesar
  const MAX_UPLOAD_MB = 15;    // lo que se permite subir ya procesado
  const MAX_EDGE_PX   = 2000;  // lado largo al que se reduce una imagen
  const JPEG_QUALITY  = 0.85;
  const MB = 1024 * 1024;

  const fmtBytes = n => n >= MB
    ? (n / MB).toFixed(1).replace('.', ',') + ' MB'
    : Math.max(1, Math.round(n / 1024)) + ' KB';

  const PISTA = `JPG, PNG o PDF · hasta ${MAX_INPUT_MB} MB`;

  function comprimirImagen(file){
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => {
        try {
          const escala = Math.min(1, MAX_EDGE_PX / Math.max(img.width, img.height));
          const w = Math.max(1, Math.round(img.width  * escala));
          const h = Math.max(1, Math.round(img.height * escala));
          const canvas = document.createElement('canvas');
          canvas.width = w; canvas.height = h;
          const ctx = canvas.getContext('2d');
          // Fondo blanco: un PNG con transparencia pasado a JPEG queda negro.
          ctx.fillStyle = '#ffffff';
          ctx.fillRect(0, 0, w, h);
          ctx.drawImage(img, 0, 0, w, h);
          canvas.toBlob(blob => {
            URL.revokeObjectURL(url);
            if (!blob) return reject(new Error('toBlob devolvió null'));
            const nombre = (file.name || 'comprobante').replace(/\.[^.]+$/, '') + '.jpg';
            resolve(new File([blob], nombre, { type: 'image/jpeg', lastModified: Date.now() }));
          }, 'image/jpeg', JPEG_QUALITY);
        } catch (err){ URL.revokeObjectURL(url); reject(err); }
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('No se pudo decodificar la imagen')); };
      img.src = url;
    });
  }

  /* Devuelve { file, error, original }. Nunca tira: quien llama muestra el
     error y corta. */
  async function prepararComprobante(file){
    if (!file) return { error: 'No elegiste ningún archivo.' };

    if (file.size > MAX_INPUT_MB * MB){
      return { error: `El archivo pesa ${fmtBytes(file.size)} y el máximo es ${MAX_INPUT_MB} MB.` };
    }

    // PDF (o cualquier cosa que no sea imagen): va tal cual, con tope duro.
    if (!/^image\//i.test(file.type || '')){
      if (file.size > MAX_UPLOAD_MB * MB){
        return { error: `El PDF pesa ${fmtBytes(file.size)} y el máximo es ${MAX_UPLOAD_MB} MB. Probá sacarle una foto.` };
      }
      return { file };
    }

    try {
      const comprimida = await comprimirImagen(file);
      // Si comprimir no achicó nada (ya era chica, o es un PNG de pantalla),
      // nos quedamos con el original: no tiene sentido recodificar de más.
      const mejor = (comprimida && comprimida.size < file.size) ? comprimida : file;
      if (mejor.size > MAX_UPLOAD_MB * MB){
        return { error: `Incluso reducida la imagen pesa ${fmtBytes(mejor.size)}. Probá con una captura en vez de la foto.` };
      }
      return { file: mejor, original: file.size };
    } catch (err){
      // Si el canvas falla (un HEIC que el navegador no decodifica, memoria),
      // se intenta subir el original mientras entre en el tope duro.
      if (file.size <= MAX_UPLOAD_MB * MB) return { file };
      return { error: 'No pudimos procesar esa imagen. Probá con una captura de pantalla o un PDF.' };
    }
  }

  /* ── Errores de register_for_event ─────────────────────────────
     La función SQL los emite con prefijo CODIGO: justamente para poder
     distinguirlos y no mostrar el mensaje crudo de Postgres. */
  function mensajeDeError(raw){
    const m = String(raw || '');
    if (m.includes('EVENTO_AGOTADO'))       return 'Se agotaron los lugares mientras completabas el formulario. Escribinos y vemos si podemos hacerte un lugar.';
    if (m.includes('INSCRIPCION_CERRADA'))  return 'Las inscripciones para este evento ya cerraron.';
    if (m.includes('EVENTO_NO_PUBLICADO'))  return 'Este evento todavía no está abierto a inscripciones.';
    if (m.includes('EVENTO_NO_ENCONTRADO')) return 'No encontramos este evento. Puede que lo hayan dado de baja.';
    if (m.includes('NO_AUTENTICADO'))       return 'Se cerró tu sesión. Volvé a iniciar sesión y probá de nuevo.';
    if (m.includes('TANDA_CERRADA'))        return 'Se agotó esa tanda mientras completabas el formulario. Recargá la página para ver el precio actual.';
    if (m.includes('TIPO_REQUERIDO'))       return 'Faltó elegir el tipo de entrada. Elegí una de las tarjetas de arriba.';
    return 'No pudimos reservar tu lugar: ' + m;
  }

  /* ── Reservar ──────────────────────────────────────────────────
     register_for_event bloquea la fila del evento, valida cierre, cupo y
     publicación, decide la tanda y fija el precio, todo en la misma
     transacción. Si ya estabas inscripta devuelve tu fila en vez de fallar. */
  async function reservar(supa, { eventId, tipo = null, formData = null, afterRun = false }){
    const { data, error } = await supa.rpc('register_for_event', {
      p_event_id:  eventId,
      p_after_run: !!afterRun,
      p_tipo:      tipo || null,
      p_form_data: formData || null
    });
    if (error) return { error: mensajeDeError(error.message), crudo: error.message };
    return { registro: Array.isArray(data) ? data[0] : data };
  }

  /* ── Subir el comprobante ──────────────────────────────────────
     Sube al bucket privado y después confirma con la RPC. El orden importa:
     si se confirmara primero, un fallo de subida dejaría la inscripción
     apuntando a un archivo que no existe. */
  async function subirComprobante(supa, { userId, registroId, file }){
    const ext  = (file.name.split('.').pop() || 'jpg').toLowerCase();
    const path = `${userId}/${registroId}-${Date.now()}.${ext}`;

    const { error: errSubida } = await supa.storage
      .from('payment-receipts')
      .upload(path, file, { upsert: true, contentType: file.type });
    if (errSubida) return { error: 'No pudimos subir el comprobante: ' + errSubida.message };

    const { error: errRpc } = await supa.rpc('submit_event_receipt', {
      reg_id: registroId, receipt_path: path
    });
    if (errRpc) return { error: 'Subimos el archivo pero no pudimos confirmarlo: ' + errRpc.message, path };

    return { path };
  }

  /* ── Eliminar el comprobante ───────────────────────────────────
     Primero la RPC: si falla, el archivo sigue donde estaba y la fila queda
     consistente. El borrado del archivo es best-effort — si queda huérfano
     no pasa nada, el bucket es privado y la fila ya no lo referencia. */
  async function eliminarComprobante(supa, { registroId, path }){
    const { error } = await supa.rpc('delete_event_receipt', { reg_id: registroId });
    if (error) return { error: 'No pudimos eliminarlo: ' + error.message };
    if (path){
      const { error: errBorrado } = await supa.storage.from('payment-receipts').remove([path]);
      if (errBorrado) console.warn('Comprobante desvinculado, pero el archivo quedó en Storage:', errBorrado.message);
    }
    return {};
  }

  global.SprintersInscripcion = {
    prepararComprobante, fmtBytes, PISTA,
    reservar, subirComprobante, eliminarComprobante, mensajeDeError,
    limites: { MAX_INPUT_MB, MAX_UPLOAD_MB }
  };
})(window);
