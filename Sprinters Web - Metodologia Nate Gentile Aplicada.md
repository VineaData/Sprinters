---
Accionado: pendiente
tags: [sprinters, metodologia, workflow, ia, productividad]
---

# Sprinters Web — Metodología Nate Gentile Aplicada

Cruce entre el workflow de Nate Gentile (Human First, AI Powered) y el estado actual de Sprinters Web (38% completo). Cada metodología traducida en acciones concretas para el proyecto.

Ver fuente: [[Nate Gentile - Como Construi una Empresa Potenciada por IA sin Perder lo Humano]]
Ver estado actual: [[Sprinters Web - Estado y Roadmap a Produccion]]

---

## El problema de raíz (antes de aplicar cualquier metodología)

Nate tardó 10 años en documentar su flujo de trabajo antes de automatizarlo. Sprinters Web tiene el problema inverso: **se construyó el frontend primero sin tener el flujo del negocio documentado.** Resultado: un sitio visualmente sólido (90% UI) pero sin la operación detrás (0% pagos, 0% emails, 5% admin).

La metodología de Nate dice: **primero procedimentar, después construir.** Sprinters necesita exactamente eso antes de continuar con código.

---

## Metodología 1 — Procedimentar el flujo antes de escribir código

### Qué hizo Nate
Documentó cada paso de la producción de un video (idea → requisitos → investigación → guion → grabación → edición → revisión → publicación) antes de automatizar cualquier parte. La IA sigue sus procedimientos, no los inventa.

### Aplicación a Sprinters Web

Antes de construir el sistema de pagos, la inscripción a eventos o el panel admin, hay que mapear exactamente cómo funciona el club hoy. Escribirlo como procedimiento en el 2B:

**Flujo de un nuevo socio (hoy, sin sistema):**
```
1. Ve el sitio → le interesa un plan
2. Lo contactan por Instagram o WhatsApp
3. ¿Cómo paga? ¿Transferencia? ¿Efectivo?
4. ¿Cómo se le da acceso? ¿Un mensaje manual?
5. ¿Cómo sabe qué eventos hay? ¿Instagram?
6. ¿Cómo se inscribe a un evento? ¿Otro mensaje?
7. ¿Cómo se le recuerda el evento? ¿Manual?
8. ¿Cómo renueva su plan? ¿Lo contactan?
```

**El código debe digitalizar ese flujo real, no inventar uno nuevo.** Si hoy el pago es por transferencia bancaria, el sistema debería soportar eso primero — no forzar Mercado Pago si aún no hay volumen que lo justifique.

**Acción concreta:**
- [ ] Documentar el flujo completo de un socio (onboarding → pago → evento → renovación) en un .md en el 2B antes de escribir una sola línea más de código

---

## Metodología 2 — Analizar costos antes de elegir herramientas

### Qué hizo Nate
Lo primero que hizo fue auditar todos los gastos de la empresa uno por uno. Resultado: eliminó Slack, Notion, Miro y Jira por alternativas open source gratuitas.

### Aplicación a Sprinters Web

Antes de elegir el servicio de email transaccional (Resend, SendGrid, Brevo), el gateway de pagos (Mercado Pago, Stripe) y el servicio de newsletter (MailerLite), hacer el análisis de costos vs volumen esperado:

| Servicio | Opción A | Opción B | Costo mensual estimado |
|---|---|---|---|
| Email transaccional | Resend (100 emails/día gratis) | Supabase built-in (básico) | $0 hasta escalar |
| Pagos | Mercado Pago (comisión ~%) | Stripe (no disponible en AR fácilmente) | Por transacción |
| Newsletter | MailerLite (gratis hasta 1k subs) | Brevo (gratis hasta 300/día) | $0 hasta escalar |
| Hosting | Cloudflare Pages (gratis) | — | $0 |

**Regla de Nate aplicada:** Empezar con el tier gratuito de cada herramienta. No pagar nada hasta tener 50+ socios activos que justifiquen el costo.

**Acción concreta:**
- [ ] Definir el stack de servicios con su costo real antes de integrar cualquier cosa

---

## Metodología 3 — Human First: definir la línea que no se cruza

### Qué hizo Nate
Definió con precisión lo que hace el humano (creatividad, criterio editorial, ideas "de olla") y lo que hace la IA (operativa, repetitivo, lo que "no apetece hacer"). La línea es inamovible.

### Aplicación a Sprinters Web

**Humano (Nico + equipo Sprinters):**
- Decidir qué eventos crear, dónde, cuándo y con qué cupos
- Fijar los precios de los planes
- Escribir el contenido editorial del sitio (landing, about, secciones)
- Gestionar la comunidad y las relaciones con los socios
- Tomar decisiones de negocio (¿lanzamos Social Club este mes?)

**IA (herramienta de soporte):**
- Redactar el copy de los emails transaccionales (bienvenida, confirmación, recordatorio)
- Generar descripciones de eventos a partir de datos básicos (nombre, fecha, lugar, distancia)
- Revisar código antes de hacer push (detectar bugs, inconsistencias)
- Analizar datos de uso para detectar patrones (qué evento tuvo más conversión, qué plan se abandona más)
- Generar el borrador de los Términos y Política de Privacidad (que luego revisa un humano)

**La línea que no se cruza en Sprinters:**
El tono del club, la personalidad de la marca y la selección de eventos los decide el humano siempre. La IA no propone eventos ni define precios — ejecuta lo que el humano decide.

---

## Metodología 4 — Orion = el Panel Admin funcional es tu sistema operativo

### Qué hizo Nate
Construyó Orion como el sistema operativo central del canal: todos los videos, tareas, calendario, ventas, inventario y comunicaciones en un solo lugar. No usa Notion + Trello + Slack + Excel — usa Orion.

### Aplicación a Sprinters Web

El Panel Admin de `Cuenta.html` (actualmente 4 botones con "próximamente") **es el Orion de Sprinters.** El error del roadmap actual es tenerlo en Sprint 4. Debería ser la columna vertebral desde Sprint 2.

**El Admin Panel debería ser una sola pantalla que muestre:**

```
ORION DE SPRINTERS
├── Eventos
│   ├── Lista de eventos activos / pasados
│   ├── Inscriptos por evento (con nombre y contacto)
│   └── Crear / editar / cancelar evento
├── Socios
│   ├── Lista de miembros activos / vencidos / eliminados
│   ├── Plan activo de cada uno
│   └── Buscar por nombre / plan / estado
├── Planes y Pagos
│   ├── Revenue del mes
│   ├── Renovaciones próximas a vencer
│   └── Historial de pagos
└── Comunicaciones
    ├── Enviar email a segmento (todos, plan X, evento Y)
    └── Historial de emails enviados
```

**No construir cada módulo por separado — construir el contenedor primero.** Igual que Nate empezó Orion como una app para benchmarks y fue creciendo, el admin de Sprinters puede empezar mostrando solo la lista de socios y crecer.

**Acción concreta:**
- [ ] Redefinir el Sprint 4 (admin) para que sea Sprint 2 — el admin es la infraestructura, no el final

---

## Metodología 5 — Janus = un agente que conoce el estado del club

### Qué hizo Nate
Janus (DeepSeek V4) tiene acceso a todo Orion y puede responder en lenguaje natural: "¿cómo fue la semana?", "¿hay algún vídeo en riesgo?", "¿cuánto cerramos en ventas?".

### Aplicación a Sprinters Web (fase futura)

Cuando el admin panel esté construido y la DB tenga datos reales, el siguiente nivel es un agente conectado a Supabase que pueda responder:
- "¿Cuántos socios activos tenemos esta semana?"
- "¿Qué evento tiene más inscriptos?"
- "¿Cuánto revenue entra este mes?"
- "¿Qué socios tienen el plan por vencer en los próximos 7 días?"

Esto no es magia — es una API sobre la DB de Supabase + un LLM con ese contexto. Con el schema correcto, se puede construir en horas.

**Esto solo es posible si primero existe el schema bien diseñado.** Por eso procedimentar el flujo (Metodología 1) y construir el admin (Metodología 4) son los prerequisitos.

---

## Metodología 6 — Fama = automatizar el follow-up de socios

### Qué hizo Nate
Fama se encarga de contactar al equipo, preguntar por el progreso y actualizar las tarjetas sin que Nate tenga que estar encima de nadie.

### Aplicación a Sprinters Web

Los emails transaccionales (Sprint 3 del roadmap) **son tu Fama.** En vez de que alguien del equipo recuerde manualmente avisar a cada socio, el sistema lo hace:

| Trigger | Email automático |
|---|---|
| Socio se registra | Bienvenida + próximos eventos |
| Socio paga plan | Confirmación + acceso activado |
| Socio se inscribe a evento | Confirmación + detalles del evento |
| 24h antes del evento | Recordatorio con lugar y hora |
| Plan por vencer en 7 días | Email de renovación |
| Plan vencido | Email de reactivación |

**La clave de Nate:** los emails tienen procedimientos muy estrictos. No son improviados — están escritos de antemano y la IA los sigue. Igual aquí: escribir el copy de cada email antes de implementar el sistema.

---

## Metodología 7 — Software a medida > herramientas genéricas

### Qué hizo Nate
Construyó su propio generador de gráficas, su propia app de mapas mentales, su propio gestor de inventario. Cada herramienta encaja exactamente con su flujo.

### Aplicación a Sprinters Web

El admin panel no debería ser un Airtable ni un Notion. Tiene que ser una página dentro del propio sitio, construida sobre Supabase, que entienda exactamente el modelo de negocio de Sprinters:
- Sabe lo que es un "plan Runner" vs un "plan Social"
- Sabe que los eventos tienen cupos y que los socios se inscriben
- Muestra los KPIs que importan para un run club (km acumulados, asistencia, retención)

Esto ya está parcialmente construido en `Cuenta.html`. El trabajo es extender lo que existe, no reemplazarlo con una herramienta externa.

**El stack vanilla HTML/CSS/JS + Supabase es la decisión correcta** precisamente por esta razón: es software a medida, sin overhead de frameworks, que puede crecer con el proyecto.

---

## Resumen: el orden correcto según la metodología Nate Gentile

El roadmap original es técnicamente correcto pero el orden no sigue la lógica de Nate. Revisado:

| Paso | Qué hacer | Por qué primero |
|---|---|---|
| **0 (antes de código)** | Documentar el flujo completo del socio en el 2B | Sin procedimiento no hay qué automatizar |
| **1** | Auditar costos de servicios (email, pagos, hosting) | Elegir herramientas según costo real, no por moda |
| **2** | Construir el contenedor del admin panel (estructura vacía) | Es el Orion — todo lo demás cuelga de acá |
| **3** | Implementar pagos + inscripción a eventos | Operación real: sin esto no hay negocio |
| **4** | Automatizar emails transaccionales (el Fama) | El follow-up automático libera tiempo humano |
| **5** | Conectar agente IA al admin (el Janus) | Solo posible con datos reales en la DB |
| **6** | SEO, legal, polish | Go-live con todo en orden |

---

## Próximos pasos accionables

- [ ] Documentar el flujo actual del socio (cómo funciona el club HOY, sin sistema) — 1 .md en el 2B
- [ ] Auditar costos: Resend vs Supabase email, Mercado Pago comisiones, hosting actual
- [ ] Redefinir el Sprint 4 (admin) como Sprint 2 en el roadmap
- [ ] Escribir el copy de los 6 emails transaccionales antes de implementar el sistema
- [ ] Definir los KPIs del club que el admin debe mostrar en pantalla
