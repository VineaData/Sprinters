# Informe pre-deploy · Sprinters Web

**Fecha:** 4 de agosto de 2026
**Estado de la base:** migración `2026-08-04_plus_birthdate_afterrun.sql` ya aplicada
**Alcance:** reglas de negocio, seguridad, UX y preparación para Vercel
**Modo:** informe. No se aplicó ningún cambio; cada punto tiene el arreglo propuesto para que decidas.

---

## Resumen

Encontré **4 bloqueantes**, **3 de severidad alta**, **4 medios** y **7 puntos de deploy**.

Los tres más importantes tienen un patrón en común: hay lógica de negocio escrita y funcionando en la base de datos que **ningún archivo del front llama**. El schema es más maduro que la interfaz. No es que falten reglas — es que quedaron huérfanas cuando el flujo migró de Mercado Pago a transferencia + comprobante.

Mi recomendación: **no publicar hasta resolver B1, B2 y B3.** Los tres se pueden romper con uso normal, no hace falta mala intención.

---

## BLOQUEANTES

### B1 · Todo el tráfico mobile crea cuentas que no existen

`Landing v2.html` redirige automáticamente cualquier viewport menor a 760px hacia `Landing-mobile.html`:

```js
var isMobile = window.matchMedia('(max-width: 760px)').matches;
if (force === 'mobile' || isMobile){ location.replace('Landing-mobile.html' + ...); }
```

`Landing-mobile.html` **no carga Supabase en ningún momento**. Su login y su signup escriben en `localStorage`:

```js
localStorage.setItem('spr_user', JSON.stringify({ email, name: fullName }));
```

La persona ve "cuenta creada", ve su nombre en el perfil, y no existe nada en la base. No recibe mail de confirmación, no puede reservar, y cuando entra desde una compu no tiene cuenta.

Para un club de running, la mayoría del tráfico es mobile. En la práctica, esto significa que casi nadie se está registrando de verdad.

**Decidido:** cablear `Landing-mobile.html` a Supabase (auth real, agenda dinámica, links a `Evento.html`).

**Alcance del trabajo:** es replicar el bloque de Supabase de `Landing v2.html` (~150 líneas: cliente, `loadAgenda`, `renderAuthNav`, captura de leads) y reemplazar las cuatro llamadas a `localStorage`. Además hay que traer los cambios de esta semana, que `Landing-mobile.html` nunca recibió: orden de secciones, Social en "Próximamente", Plus en lugar de Pro.

---

### B2 · El cupo de los eventos no se controla en ningún lado

`events.sold_tickets` se incrementa en un único lugar de todo el proyecto:

```sql
-- book_ticket_safely(), .claude/sprinters-schema.sql:621
UPDATE public.events SET sold_tickets = sold_tickets + 1 ...
```

Esa función pertenece al flujo viejo de Mercado Pago y opera sobre la tabla `tickets`. El flujo actual de `Evento.html` hace un INSERT directo en `event_registrations` y **nunca toca `sold_tickets`**:

```js
const { data, error } = await supa.from('event_registrations')
  .insert({ event_id: evId, user_id: session.user.id, after_run: afterRunOn })
```

Consecuencias, todas en producción hoy:

| Lo que dice la interfaz | Lo que pasa realmente |
|---|---|
| "Quedan 12 lugares" | Siempre muestra el cupo completo, sin importar cuántos se anotaron |
| "Se agotó el cupo" | No se dispara nunca |
| Cupo total: 45 | El cupo es infinito |

**Decidido:** RPC atómica `register_for_event()`.

**Qué haría:** una función `SECURITY DEFINER` con `SELECT ... FOR UPDATE` sobre el evento que valide cupo, `sales_cutoff` y estado de publicación antes de insertar, e incremente `sold_tickets` en la misma transacción — el mismo patrón que ya usa `book_ticket_safely()`. Después `REVOKE INSERT ON event_registrations FROM authenticated` para que la RPC sea el único camino, y cambiar el INSERT de `Evento.html` por la llamada.

Como el cupo real de hoy no está reflejado en `sold_tickets`, la migración tiene que hacer un backfill:

```sql
UPDATE public.events e
   SET sold_tickets = (SELECT COUNT(*) FROM public.event_registrations r
                        WHERE r.event_id = e.id AND r.status <> 'cancelled');
```

**Nota:** la doble inscripción **sí** está cubierta — existe `uq_one_registration_per_user_event UNIQUE (user_id, event_id)` y `Evento.html` maneja el error `23505` correctamente. Ese es el único de los cuatro controles que está blindado.

---

### B3 · No existe pantalla para revisar comprobantes

En la base están definidas, con `GRANT EXECUTE` y validación de `is_admin` adentro:

- `review_event_payment(reg_id, approve)`
- `review_subscription_payment(sub_id, approve)`

**Ningún archivo HTML las llama.** `Admin.html` tiene exactamente dos pestañas: Usuarios y Eventos.

Efectos concretos:

1. Una inscripción a un evento pago queda en `pending_review` **para siempre**. La persona ve "Lo revisamos en menos de 24 hs" y nadie puede revisarlo.
2. El mecanismo de auditoría que agregamos el lunes no tiene interfaz. Las suscripciones se auto-activan con `auto_verified = TRUE` justamente para que vos las revises después — pero no hay dónde.

**Propuesta:** una tercera pestaña "Pagos" en `Admin.html` con las filas de `event_registrations` y `subscriptions` que tengan comprobante, link firmado al archivo del bucket privado, y botones Aprobar / Rechazar. Filtro por defecto: `pending_review` + `auto_verified = TRUE`.

---

### B4 · El cierre de inscripción solo vive en el navegador

`sales_cutoff` se valida en JS (`Evento.html:336`). La RLS de `event_registrations` solo comprueba `auth.uid() = user_id`:

```sql
CREATE POLICY "evreg_insert_own" ON public.event_registrations
  FOR INSERT TO authenticated WITH CHECK ((select auth.uid()) = user_id);
```

Cualquiera con la consola abierta puede anotarse después del cierre. Se resuelve junto con B2, en la misma RPC.

---

## ALTO

### A1 · El apto médico no se pide nunca

El schema lo trata como requisito de los dos planes Running:

```json
"requires_med_cert": true
```

Y está toda la infraestructura: columnas `med_cert_url` / `med_cert_status` / `med_cert_expires_at`, bucket privado `medical-certs` con sus policies, y las funciones `submit_med_cert()` / `review_med_cert()`.

`grep -rn "med_cert" *.html` no devuelve **ni una** coincidencia.

Hoy se puede pagar Training Core o Plus y empezar a entrenar sin que nadie pida un apto físico. Esto es exposición legal, no una feature faltante — y el propio schema lo marca como dato de salud sensible bajo la Ley 25.326.

**Propuesta:** subida del apto en el perfil de `Cuenta.html`, badge de estado (pendiente / aprobado / vencido), y revisión desde la pestaña Pagos de B3. Si querés, se puede bloquear la reserva de eventos Running con el apto vencido.

---

### A2 · El comprobante de evento falla en silencio

```js
const { error: upErr } = await supa.storage.from('payment-receipts').upload(path, file, ...);
if (!upErr){
  const { error: rpcErr } = await supa.rpc('submit_event_receipt', ...);
  if (!rpcErr) existingReg.payment_status = 'pending_review';
}
```

Si el upload falla o el RPC falla, **no se avisa nada**. La inscripción ya se creó y queda con `payment_status = 'not_required'`. Para el admin es indistinguible de una inscripción a un evento gratis: no hay señal de que alguien pagó y el comprobante se perdió.

Compará con `Suscripcion Running.html`, que sí hace `alert()` en los dos casos de error. El de eventos quedó atrás.

---

### A3 · Una suscripción rechazada deja al usuario sin explicación

Cuando un admin rechaza un comprobante, la función que actualicé el lunes pone `status = 'cancelled'`. Pero `Suscripcion Running.html` busca así:

```js
.in('status', ['active', 'pending'])
```

La suscripción cancelada no entra en el filtro, `_mySub` queda `null`, y la persona ve la grilla de planes limpia, como si nunca hubiera pasado nada. Pagó, le rechazaron el comprobante y no se entera.

**Propuesta:** incluir `cancelled` en la consulta cuando `payment_status = 'rejected'` y mostrar el motivo con la opción de volver a subir.

---

## MEDIO

**M1 · El perfil casi no se puede editar.** `editProfileForm` solo tiene nombre, apellido y foto. Teléfono, contacto de emergencia y fecha de nacimiento no se pueden corregir desde la web — hay que pedirle a un admin. El contacto de emergencia es justo el dato que más importa que esté al día.

**M2 · El alias bancario está duplicado.** `sprintersine` / `Inés Bahamondes - NaranjaX` aparece hardcodeado en `Evento.html:186` y en `Suscripcion Running.html:165`. Si cambia y se actualiza uno solo, la gente transfiere a un alias viejo. Debería salir de una tabla de configuración o al menos de un archivo compartido.

**M3 · Un admin con suscripción pierde el badge de plan.** En `loadProfile()`, si `is_admin` es true se muestra "★ Admin" y no se consulta la suscripción. Un admin que además paga Plus no lo ve reflejado.

**M4 · `Landing-mobile.html` quedó atrás.** No recibió el reordenamiento de secciones, ni Social en "Próximamente", ni el cambio de Pro a Plus. Se resuelve dentro de B1.

---

## DEPLOY EN VERCEL

### Lo que ya está bien

- `.env` **no** está trackeado y `.gitignore` lo cubre correctamente.
- La clave de Supabase en el HTML es la publishable/anon — es pública por diseño. La protección real es la RLS, que está bien armada.
- `Admin.html` tiene `noindex,nofollow`.
- Las policies de Storage (`payment-receipts` privado, `medical-certs` privado, `event-images` público) están correctas.

### Lo que falta

**D1 · No hay `vercel.json`.** El sitio es estático puro, así que Vercel lo va a servir igual, pero sin rutas limpias ni headers.

**D2 · Los nombres de archivo tienen espacios.** Las URLs quedan así:

```
sprinters.vercel.app/Landing%20v2.html
sprinters.vercel.app/Suscripcion%20Running.html
```

Feo para compartir por WhatsApp y frágil: algunos clientes de mensajería cortan el link en el `%20`. Se arregla con rewrites en `vercel.json`, sin renombrar archivos ni romper los links internos:

```json
{
  "rewrites": [
    { "source": "/", "destination": "/Landing v2.html" },
    { "source": "/mobile", "destination": "/Landing-mobile.html" },
    { "source": "/cuenta", "destination": "/Cuenta.html" },
    { "source": "/evento", "destination": "/Evento.html" },
    { "source": "/running", "destination": "/Suscripcion Running.html" },
    { "source": "/social", "destination": "/Suscripcion Social.html" },
    { "source": "/admin", "destination": "/Admin.html" }
  ]
}
```

**D3 · `index.html` redirige con meta-refresh.** Con el rewrite de `/` del punto anterior, el archivo deja de hacer falta y la home carga directo, sin el salto.

**D4 · Faltan headers.** `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin` y cache larga para `/images/*` (hoy se re-descargan en cada visita; son 18 archivos y pesan).

**D5 · `db/` está en `.gitignore`.** Las migraciones no viajan al repo. Para el deploy da igual (el sitio es estático), pero significa que **todo el historial de tu base vive solo en tu máquina**. Si se te rompe el disco, no hay forma de reconstruir el schema. Yo lo sacaría del ignore — no contiene secretos, solo DDL.

**D6 · Supabase → Redirect URLs.** Cuando tengas el dominio de Vercel, hay que agregarlo en Authentication → URL Configuration. Si no, los mails de confirmación van a seguir apuntando a localhost y **nadie va a poder confirmar su cuenta**. Es el paso que más se olvida.

**D7 · Las Edge Functions se despliegan aparte.** `admin-create-user`, `create-subscription` y `mp-webhook` viven en Supabase, no en Vercel (`supabase functions deploy`).

### Pasos para publicar

```bash
git add -A
git commit -m "Plus, fecha de nacimiento, after-run y tipografía Inter"
git push origin master
```

Después, en vercel.com: **Add New → Project → importar `Emape-g/Sprinters`**. Framework preset: **Other**. Sin build command ni output directory — es estático. Deploy.

Terminado eso, el paso D6 en Supabase.

---

## Orden que propongo

| # | Qué | Por qué primero |
|---|---|---|
| 1 | B2 + B4 (RPC de inscripción) | Una sola migración cierra cupo, cutoff y publicación |
| 2 | B3 (pestaña Pagos) | Sin esto no podés cobrar ningún evento |
| 3 | B1 (mobile a Supabase) | El más grande, pero el que más usuarios desbloquea |
| 4 | D1–D4 (`vercel.json`) | Rápido, se puede hacer en paralelo |
| 5 | A2, A3 | Arreglos chicos y contenidos |
| 6 | A1 (apto médico) | Feature nueva, merece su propia tanda |
| 7 | M1–M3 | Cuando haya aire |

Los puntos 1, 2 y 4 son de una sesión. El 3 es el que lleva tiempo de verdad.
