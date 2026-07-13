---
Accionado:
tags:
  - sprinters
  - web
  - produccion
  - roadmap
---

# Sprinters Web — Estado del Proyecto y Roadmap a Producción

**Fecha de análisis:** 2026-06-07
**% de completitud estimado: 38%**

---

## Resumen ejecutivo

El sitio de Sprinters es visualmente sólido y de alto nivel de diseño. El frontend está casi terminado. Sin embargo, las funciones críticas para operar el club (cobro de planes, inscripción a eventos, panel de gestión, comunicaciones automáticas) son stubs o no existen. Un usuario hoy puede ver el sitio, crear cuenta y ver su perfil, pero no puede pagar, inscribirse a un evento de forma real, ni recibir ningún email transaccional.

---

## Arquitectura actual

| Capa | Tecnología | Estado |
|---|---|---|
| Frontend | HTML/CSS/JS vanilla + GSAP 3.12 + Lenis | ✅ Funcional |
| Auth | Supabase Auth | ✅ Funcional |
| DB | Supabase PostgreSQL | ⚠️ Parcial |
| Storage | Supabase Storage (bucket `avatars`) | ✅ Funcional |
| Pagos | — | ❌ No existe |
| Email transaccional | — | ❌ No existe |
| CMS / Admin | Stub en Cuenta.html | ❌ No funcional |

---

## Páginas del proyecto

| Archivo | Descripción | Estado |
|---|---|---|
| `index.html` | Redirect a Landing v2 | ✅ |
| `Landing v2.html` | Landing desktop completa | ✅ |
| `Landing-mobile.html` | Landing mobile completa | ✅ |
| `Suscripcion Running.html` | Planes Running Team | ⚠️ Sin acción real |
| `Suscripcion Social.html` | Planes Social Club | ⚠️ Sin pago real |
| `Cuenta.html` | Auth + perfil | ⚠️ Funcional pero incompleto |
| `subs.css` | Estilos compartidos subscripciones | ✅ |

---

## ✅ LO QUE ESTÁ HECHO

### Frontend / UI
- Landing desktop completa: Hero, Pilares, Agenda, Galería, Cómo funciona, Líderes, CTA, Footer
- Landing mobile completa con las mismas secciones, optimizada para 9:16
- Auto-redirección entre versión desktop y mobile (por viewport)
- Animaciones de scroll GSAP con efecto "flow art" (secciones que rotan al entrar)
- Reveal animations con IntersectionObserver (fade, slide, scale, blur)
- Marker highlight animado (efecto subrayado verde oscuro)
- Nav sticky con glassmorphism al hacer scroll
- Page index lateral (solo desktop, puntos con labels)
- Menu overlay en mobile (full-screen con cierre)
- Hero foto con zoom sutil al cargar

### Suscripciones (UI)
- Toggle mensual/anual con animación de pill deslizable
- Precio con cambio animado dígito a dígito
- Tarjetas de planes con hover elevado
- Plan "popular" destacado visualmente
- Plan "dark" para Founder's Circle (fondo negro)
- Responsive: colapsa a 1 columna en mobile

### Cuenta / Auth (Supabase real)
- Signup con form completo: mail, contraseña, teléfono (selector de país), nombre, apellido, edad, sexo, origen, cómo nos conociste, contacto de emergencia, foto (opcional)
- Login con email + password
- Logout
- Perfil: muestra nombre, stats (eventos, km, ahorro), info completa del usuario
- Editar perfil: nombre, apellido, foto (upload a Supabase Storage con cache-bust)
- Soft delete: el usuario puede eliminar su cuenta (guarda `deleted_at`, no borra el registro)
- Admin panel visible solo si `is_admin = true` en la tabla `users`
- Detección automática del plan activo desde tabla `subscriptions`
- Redirect por `?tab=signup|login|profile` y `?plan=runner` para flujo de plan
- Responsive completo hasta 380px

---

## ⚠️ LO QUE SE DEBE VERIFICAR (puede estar hecho o no)

### Backend Supabase
- [ ] **Tabla `users`** con columnas: `id`, `first_name`, `last_name`, `age`, `sex`, `origin`, `phone`, `how_heard`, `emergency_contact`, `avatar_url`, `is_admin`, `social_events_attended`, `total_km`, `total_money_saved`, `deleted_at`, `created_at`, `updated_at`
- [ ] **Tabla `subscriptions`** con columnas: `id`, `user_id`, `status`, `membership_plans_id`
- [ ] **Tabla `membership_plans`** con columna `name`
- [ ] **Trigger `handle_new_auth_user()`** que crea fila en `public.users` cuando se registra un usuario nuevo en `auth.users`
- [ ] **Bucket `avatars`** en Supabase Storage con políticas públicas de lectura y escritura autenticada
- [ ] **RLS (Row Level Security)** activado y configurado correctamente en la tabla `users`
- [ ] **Email confirmation** habilitado o deshabilitado en Supabase (afecta el flujo de signup)
- [ ] La anon key en `Cuenta.html` (`sb_publishable_...`) es la correcta para producción

### Consistencia entre versiones
- [ ] La versión mobile (`Landing-mobile.html`) usa **localStorage** para el account overlay (auth simulado con datos hardcodeados "Lucía Romero"). Verificar si se actualizó para usar Supabase o si sigue siendo un mockup
- [ ] El nav desktop tiene `<a href="Cuenta.html">Mi cuenta</a>` → va a la página real con Supabase. Confirmar que el flujo es intencional y no haya dos sistemas de auth en paralelo

### SEO y sharing
- [ ] ¿Existe `robots.txt`?
- [ ] ¿Existe `sitemap.xml`?
- [ ] ¿Tiene dominio propio configurado o está en localhost/Cloudflare Pages?

---

## ❌ LO QUE NO ESTÁ HECHO (para ir a producción)

### 🔴 Crítico — sin esto no puede operar

**1. Sistema de pagos**
No existe integración con ningún gateway de pago. Los botones "Sumarme al pass" / "Crear cuenta" en las páginas de planes no ejecutan ningún cobro. Opciones a integrar:
- Mercado Pago (recomendado para Argentina: Checkout Pro o Bricks)
- Stripe (si se apunta a turismo internacional)
El flujo debería ser: selección de plan → create checkout session → pago → webhook confirma → update `subscriptions` en DB

**2. Inscripción real a eventos**
Los eventos en la agenda son estáticos y decorativos. No hay:
- Tabla de `events` en Supabase con cupos, fechas, ubicación, estado
- Botón "Inscribirme" que reserve un cupo
- Verificación de disponibilidad de cupos
- Confirmación de inscripción al usuario (email o WhatsApp)
- Listado de inscriptos para los organizadores

**3. Panel de administración funcional**
El Admin Panel en `Cuenta.html` tiene 4 botones que muestran "próximamente". Falta:
- CRUD de eventos (crear, editar, cancelar, ver inscriptos)
- Gestión de planes y precios
- Listado de miembros con filtros
- Gestión de partners
- Exportar datos de inscriptos

**4. Password reset**
El link "¿Olvidaste tu contraseña?" va a `#`. Supabase tiene el flujo nativo (`supa.auth.resetPasswordForEmail()`), falta implementarlo. Sin esto cualquier usuario que olvide su contraseña no puede recuperar acceso.

---

### 🟠 Importante — degrada la experiencia

**5. Formulario CTA email (newsletter) no guarda nada**
En la sección de join de ambas landing pages, el formulario solo cambia el texto del botón a "✓ Listo" con un `onsubmit`. No guarda el email en ninguna base de datos ni servicio de email marketing.
Solución: insertar en tabla `newsletter_leads` de Supabase, o integrar con MailerLite/Brevo.

**6. Email transaccional ausente**
No hay emails automáticos para ninguno de estos eventos:
- Confirmación de registro en evento
- Bienvenida al crear cuenta
- Recordatorio 24hs antes de un evento
- Factura/recibo al pagar plan
Opciones: Resend, SendGrid, o el email built-in de Supabase para casos simples.

**7. Flujo de email confirmation roto a medias**
Cuando Supabase tiene email confirmation activo, el signup devuelve `session = null`. El código actual muestra "revisá tu mail" y redirige al login — correcto. **Pero** los datos extendidos del perfil (edad, sexo, origen, etc.) que se pasan en `options.data` al `signUp()` solo se guardan en `auth.users` metadata, y se supone que el trigger los pasa a `public.users`. Verificar que el trigger los procese correctamente, de lo contrario los campos quedarán vacíos.

**8. `Ver plan` en el perfil no hace nada**
El botón "Ver plan" en `Cuenta.html` no tiene acción. Debería llevar a la gestión de la suscripción activa: ver fecha de vencimiento, cambiar plan, cancelar.

**9. Inconsistencia mobile vs desktop auth**
`Landing-mobile.html` tiene un account overlay que simula auth con localStorage (los datos de "Lucía Romero" son hardcodeados). El desktop va a `Cuenta.html` con Supabase real. En mobile, un usuario real no puede ni crear cuenta ni iniciar sesión. Se debe reemplazar el overlay de mobile con un link a `Cuenta.html`, o adaptar el overlay para usar Supabase.

**10. Footer links placeholder**
Todos los links de "Encuentros" en el footer van a `#`. Si se hacen páginas o secciones para cada punto de encuentro, actualizar. Si no, eliminar esos links.

---

### 🟡 Mejoras recomendadas — para profesionalismo

**11. SEO básico**
Faltan en todas las páginas:
```html
<meta name="description" content="..." />
<meta property="og:title" content="Sprinters · Social Run Club" />
<meta property="og:image" content="..." />
<meta property="og:url" content="..." />
<meta name="twitter:card" content="summary_large_image" />
```
Sin esto, los compartidos en Instagram Stories, WhatsApp y Twitter no muestran previsualización.

**12. Favicon**
No hay `<link rel="icon">` definido en ninguna página. El navegador muestra un ícono genérico.

**13. Email en footer desktop obfuscado por Cloudflare**
En `Landing v2.html` el email del footer está protegido por el script de Cloudflare (`data-cfemail`), que requiere estar detrás de Cloudflare para decodificarse. Si el sitio no está en Cloudflare, el email aparece como `[email protected]`. La versión mobile tiene el email en claro en `mailto:` — usar el mismo enfoque en desktop.

**14. Subrecursos sin SRI (Subresource Integrity)**
GSAP y Lenis se cargan desde CDNs externos sin atributo `integrity`. Si la CDN es comprometida, puede inyectar JS malicioso. Agregar hashes SRI o descargar las librerías localmente.

**15. Métricas hardcodeadas**
La sección de métricas en la landing muestra números fijos (ej: cantidad de corredores, km acumulados). Eventualmente deberían venir de la DB para ser reales y actuales.

**16. Agenda hardcodeada con fechas pasadas**
Los eventos tienen fechas fijas (23 May, 30 May, 6 Jun, 20 Jun). Ya pasaron o están por pasar. Se deben actualizar manualmente en el HTML o, mejor, cargar desde una tabla `events` en Supabase.

**17. Sin legal (Términos y Privacidad)**
Los links "Términos" y "Política de Privacidad" en el signup van a `#`. Para operar legalmente y cumplir con datos personales (Argentina tiene Ley 25.326 de Protección de Datos Personales) es obligatorio tener estos documentos redactados y publicados.

**18. Sin WhatsApp o link de reserva real**
La sección "Cómo funciona" indica que la inscripción es vía Instagram o WhatsApp, pero no hay botones de link a ninguno de los dos en el sitio. Agregar CTA de WhatsApp (wa.me/...) o link al Instagram.

**19. Partners section con placeholders**
La sección de Partners tiene nombres genéricos en DM Serif Display como si fueran logos. No hay logos reales de las marcas aliadas (ON Running, Salomon, etc.).

**20. `delete confirm overlay` tiene CSS `display:none` duplicado**
```html
<div id="deleteConfirmOverlay" style="display:none; ... display:none; ...">
```
Tiene `display:none` declarado dos veces en el atributo style inline — es inofensivo pero es un bug de código que muestra que el overlay nunca fue abierto y testeado en el browser.

---

## Tabla de completitud por área

| Área | % completado | Notas |
|---|---|---|
| UI / Diseño visual | 90% | Falta favicon, OG tags, partners reales |
| Responsividad | 85% | Mobile overlay de cuenta usa localStorage en vez de Supabase real |
| Autenticación | 65% | Funciona, falta password reset y consistencia mobile |
| Base de datos | 50% | Schema básico existe, faltan tablas de events, leads, tickets |
| Pagos | 0% | No existe ninguna integración |
| Gestión de eventos | 10% | Solo UI hardcodeada, sin tabla ni inscripción real |
| Panel admin | 5% | Botones stub, nada funcional |
| Email / Notificaciones | 0% | No existe ningún email transaccional |
| SEO | 15% | Solo estructura básica, sin meta tags ni sitemap |
| Legal | 0% | Términos y Política de Privacidad no redactados |
| **Total ponderado** | **38%** | |

---

## Roadmap sugerido hacia producción

### Sprint 1 — Fundamentos (crítico)
- [ ] Verificar y completar schema Supabase (trigger, tablas, RLS)
- [ ] Implementar password reset (`resetPasswordForEmail`)

> **Decisión 2026-06-09:** Mobile queda fuera de alcance por ahora — primero la web desktop funcional, después se adapta a mobile. Newsletter eliminada del plan (no existe una newsletter hoy).

### Sprint 2 — Operación real
- [ ] Crear tabla `events` y cargar agenda desde DB
- [ ] Implementar inscripción a eventos (cupos, confirmación)
- [ ] Integrar Mercado Pago para cobro de planes
- [ ] Conectar botones de plan a checkout real

### Sprint 3 — Comunicaciones
- [ ] Email de bienvenida al registrarse
- [ ] Email de confirmación de inscripción a evento
- [ ] Recordatorio 24hs antes del evento
- [ ] Recibo/factura al pagar

### Sprint 4 — Admin y contenido
- [ ] Panel admin funcional: CRUD de eventos, listado de miembros
- [ ] "Ver plan" en perfil: gestión de suscripción activa
- [ ] Actualizar métricas desde DB

### Sprint 5 — Go-live
- [ ] Redactar y publicar Términos y Política de Privacidad
- [ ] Agregar meta tags SEO y OG en todas las páginas
- [ ] Agregar favicon
- [ ] Arreglar email footer desktop (sacar obfuscación Cloudflare)
- [ ] Agregar link WhatsApp para reservas
- [ ] Reemplazar partner placeholders con logos reales
- [ ] Agregar SRI a CDNs o mover a local
- [ ] `robots.txt` + `sitemap.xml`

---

## Deuda técnica detectada

1. **CSS duplicado entre archivos**: Los estilos del marker highlight, variables CSS root y estilos base están repetidos en `Landing v2.html`, `Landing-mobile.html` y `subs.css`. Considerar extraer a un `base.css` compartido.
2. **Todo el CSS inline en los HTML**: Todos los `<style>` están dentro del `<head>` de cada HTML. Hace el mantenimiento difícil; un cambio de color requiere tocar 5 archivos.
3. **`GSAP` importado desde CDN**: En producción real, recomendado bundlear con Vite/Rollup o al menos agregar SRI.
4. **Sin TypeScript ni bundler**: El proyecto no tiene ningún sistema de build. Para escalar, considerar migrar a Astro o Next.js con componentes reutilizables.
5. **Doble Observer en `Landing-mobile.html`**: El código crea un `IntersectionObserver` vacío (`.observe;` — sin llamar a `observe`) antes de crear el real. Es un dead-code bug que no rompe nada pero muestra falta de revisión.
