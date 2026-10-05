# Playbook — problemas de web y cómo se resolvieron

Referencia técnica reutilizable. Cada entrada tiene **síntoma → causa raíz →
solución → cómo detectarlo antes**. La mayoría no son específicos de Sprinters:
aplican a cualquier sitio estático con HTML/CSS/JS que hable con un backend.

Escrito a partir de la sesión del 2026-08-05 sobre el sitio de Sprinters
(HTML plano + Supabase + Vercel, sin build step).

Índice:

1. [Logo y assets](#1-logo-y-assets)
2. [Tipografías](#2-tipografías)
3. [CSS y layout](#3-css-y-layout)
4. [Responsive / mobile](#4-responsive--mobile)
5. [Formato de fechas, precios y texto](#5-formato-de-fechas-precios-y-texto)
6. [Backend, RPC y migraciones](#6-backend-rpc-y-migraciones)
7. [Deploy, caché y git](#7-deploy-caché-y-git)
8. [Método de trabajo](#8-método-de-trabajo)

---

## 1. Logo y assets

### 1.1 El logo no aparece al abrir el HTML con doble clic

**Síntoma.** El logo se ve en el servidor de desarrollo pero desaparece al
abrir el archivo directamente en Chrome (`file:///...`).

**Causa raíz.** Se estaba usando `mask-image` apuntando a un PNG/SVG externo.
Chrome aplica chequeos de origen a las máscaras CSS y bajo el protocolo
`file://` cada archivo es un origen opaco distinto, así que la máscara nunca
carga y el elemento queda transparente.

**Solución.** Sprite SVG inline al principio del `<body>`, referenciado con
`<use>`:

```html
<!-- Una sola vez por página, al principio del body -->
<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false">
  <defs>
    <symbol id="sl-wordmark" viewBox="0 0 1105.3 146.98">
      <path d="…"/>
    </symbol>
  </defs>
</svg>

<!-- Donde haga falta el logo -->
<svg class="brand-logo brand-logo--wordmark" role="img" aria-label="Sprinters">
  <use href="#sl-wordmark"></use>
</svg>
```

```css
.brand-logo{
  display:block;
  fill:currentColor;   /* clave: el color lo hereda del contenedor */
  height:auto;
}
/* El ancho sale del alto vía aspect-ratio con los valores exactos del viewBox.
   Nunca fijar alto y ancho a mano: el logo se deforma. */
.brand-logo--wordmark{height:22px;aspect-ratio:1105.3/146.98}
```

**Por qué esta opción y no otra:**

| Técnica | Hereda `currentColor` | Anda con `file://` | Veredicto |
|---|---|---|---|
| `<img src="logo.svg">` | ❌ | ✅ | Sirve si el logo es de un solo color fijo |
| `mask-image` externa | ✅ | ❌ | Se rompe sin servidor |
| `background-image` | ❌ | ✅ | Mismo límite que `<img>` |
| **Sprite SVG inline + `<use>`** | ✅ | ✅ | **La que se usó** |

**Cómo detectarlo antes.** Probar siempre el sitio abriendo el HTML con doble
clic, no solo con Live Server. Es gratis y detecta toda una familia de bugs de
origen (máscaras, fuentes, fetch, módulos ES).

**Regla derivada.** Si el logo tiene que cambiar de color según el fondo
(blanco sobre el hero, verde sobre el nav claro), tiene que ser SVG inline con
`fill:currentColor`. Cualquier otra técnica obliga a mantener dos archivos.

---

### 1.2 Logo deformado al cambiarle el tamaño

**Causa.** Fijar `width` y `height` a mano en cada uso.

**Solución.** Fijar solo el alto y derivar el ancho con `aspect-ratio` tomado
del `viewBox` real del SVG:

```css
.brand-logo--wordmark{height:22px;aspect-ratio:1105.3/146.98}
.brand-logo--lockup  {height:64px;aspect-ratio:1106.89/378.36}

@media (max-width:640px){ .brand-logo--wordmark{height:18px} }
@media (max-width:400px){ .brand-logo--wordmark{height:16px} }
```

Un solo número por breakpoint y es imposible deformarlo.

---

## 2. Tipografías

### 2.1 Cambié la fuente y no se ve el cambio

**Síntoma.** Se reemplaza la familia tipográfica en todos los archivos y el
sitio se sigue viendo igual.

**Causas posibles, en orden de probabilidad:**

1. **No se deployó.** Los cambios están en local, sin commit o sin push.
2. **Caché del navegador.** El CSS viejo sigue cacheado. `Ctrl+Shift+R`.
3. **Quedó un archivo sin migrar.** Es el más traicionero: se reemplaza en los
   `.html` y se olvida el `.css` externo — o al revés.
4. **Las dos fuentes se parecen.** Inter y Poppins son ambas geométricas
   humanistas; a 11px con `letter-spacing` abierto casi no se distinguen.

**Cómo diagnosticarlo, en este orden:**

```bash
# 1) ¿Está commiteado y pusheado?
git status --short
git log --oneline -1
git show origin/master:"index.html" | grep -c "NuevaFuente"

# 2) ¿Quedó algún archivo sin migrar?
grep -rn "FuenteVieja" --include="*.html" --include="*.css" .

# 3) ¿Cuántas ocurrencias hay por archivo? (detecta el que quedó en cero)
for f in *.html *.css; do echo "$f: $(grep -c 'NuevaFuente' "$f")"; done
```

**Regla derivada.** Un reemplazo global de tipografía no se hace archivo por
archivo a ojo. Se hace con script y se verifica con un `grep` que tiene que dar
**cero** ocurrencias de la fuente vieja:

```bash
# Reemplazo + verificación en un solo paso
python3 - << 'PY'
import re, glob
for path in glob.glob("*.html") + glob.glob("*.css"):
    s = open(path, encoding="utf-8").read()
    s = s.replace("'Inter'", "'Poppins'")
    s = re.sub(r"\\'Inter\\'", r"\\'Poppins\\'", s)   # dentro de strings JS
    open(path, "w", encoding="utf-8").write(s)
PY
grep -rln "Inter" --include="*.html" --include="*.css" .   # debe dar vacío
```

Ojo con el `re.sub` de comillas escapadas: si la fuente aparece dentro de un
string de JavaScript (`const S = "font-family:\'Inter\'"`), el `replace` simple
no la agarra.

**Falso positivo frecuente.** `grep "Inter"` matchea `IntersectionObserver`.
Buscar `'Inter'` con comillas o `font-family` en la misma línea.

---

### 2.2 La fuente del manual de marca no se puede usar

**Síntoma.** El brand book viene en PDF con las fuentes embebidas, pero son
versiones *Trial* o *Personal Use*.

**Qué hay que entender.** Una fuente embebida en un PDF no es una licencia de
uso. Los tres escenarios típicos:

| Situación | Qué se puede hacer |
|---|---|
| Fuente comercial (ej. Transforma, Fontfabric) | Comprar licencia **webfont** — se cobra por pageviews/mes, con opción anual o perpetua. Es una licencia distinta de la de escritorio. |
| Fuente "free for personal use" (ej. Harper) | Gratis solo si el sitio no genera ingresos. Si cobra suscripciones, entradas o vende algo, es uso comercial y hay que escribirle al autor. |
| Fuente libre (OFL / Apache) | Uso libre, también comercial. Google Fonts entra acá. |

**"Personal use" no significa "es mi proyecto personal".** Significa que el
proyecto no genera ingresos. Un sitio con pasarela de pago es comercial aunque
lo maneje una sola persona.

**Solución práctica: buscar el sustituto libre comparando letras, no de memoria.**
El método que funcionó:

1. Sacar un espécimen real de la fuente del PDF (una captura de un párrafo).
2. Listar los rasgos estructurales que le dan el carácter: `a` de uno o dos
   pisos, `g` de uno o dos pisos, `G` con o sin barra transversal, altura de x,
   proporción ancha/angosta, monolineal o con contraste.
3. Descartar candidatas por esos rasgos antes de mirar el conjunto. Ejemplo
   real: Transforma tiene `a` de un solo piso — eso descartó de una a Figtree,
   Hanken Grotesk, DM Sans, Plus Jakarta, Lexend, Sora y Onest, que la tienen
   de dos pisos.
4. Comparar las finalistas **con párrafos completos del texto real del sitio**,
   no con "Handgloves" ni el alfabeto.

**Documentar la decisión.** Conviene dejar el razonamiento escrito (acá quedó
en `sprinters-style.json` → `typography.families[]`) con: fuente original,
rasgos de las letras, sustituta elegida, por qué, en qué se diferencia, y las
rechazadas con el motivo. Sin eso, dentro de seis meses nadie se acuerda por
qué se eligió esa y se vuelve a discutir de cero.

---

### 2.3 Poner una fuente display sin romper la legibilidad

**Síntoma.** Se aplica la tipografía de titulares del manual a todo el sitio y
el texto se vuelve ilegible.

**Causa.** Las display están hechas para dos o tres palabras grandes. Tienen un
solo peso, contraformas chicas y espaciado pensado para 60px, no para 13px.

**Solución.** Aplicarla **solo a los titulares**, con Inter (o la sans de
texto) siempre como fallback:

```css
@font-face{
  font-family:'Harper';
  src:url('images/fonts/harper-bold.woff2') format('woff2');
  font-weight:700;
  font-style:normal;
  font-display:swap;    /* el titular se ve en la sans y "salta" al cargar */
}

/* Solo h1/h2 de hero y de sección */
.display-brand{
  font-family:'Harper','Inter',sans-serif !important;
  font-weight:700 !important;
  letter-spacing:0 !important;
}
```

**Tres detalles que se pasan por alto:**

**a) Convertir a WOFF2.** Un OTF pesa 10× más que su WOFF2. Acá: 333 KB → 35 KB.

```bash
pip install fonttools brotli --break-system-packages
python3 -c "
from fontTools.ttLib import TTFont
f = TTFont('fuente.otf'); f.flavor='woff2'; f.save('fuente.woff2')
"
```

**b) Verificar cobertura de glifos antes de aplicarla.** Muchas display no
traen acentos ni signos de puntuación tipográficos:

```python
from fontTools.ttLib import TTFont
cmap = TTFont('fuente.otf').getBestCmap()
faltan = [c for c in 'áéíóúüñÁÉÍÓÚÑ¿¡—·«»' if ord(c) not in cmap]
print('glifos:', len(cmap), '· faltan:', faltan or 'ninguno')
```

En este caso faltaban `—` (guion largo) y `·` (punto medio), los dos usados en
títulos del sitio. **Por eso el fallback a Inter en el stack no es decorativo:**
esos dos caracteres caen a Inter y el resto se mantiene en Harper. Si el stack
fuera `font-family:'Harper'` a secas, caerían a la fuente por defecto del
sistema y el salto se notaría mucho más.

**c) Anular el `letter-spacing` negativo.** Los títulos suelen venir con
`letter-spacing:-0.02em` porque las sans light lo piden. Una display pesada con
tracking negativo cierra las contraformas y se empasta. Poner `0`.

**Regla derivada.** Si el logotipo ya está vectorizado en SVG, la fuente display
casi no aporta: el logo se ve idéntico al manual sin tenerla instalada. Antes de
comprar una licencia, verificar en qué elementos concretos se vería.

---

### 2.4 Una fuente trial que renderiza "Personal Use Only" en pantalla

**Síntoma.** Un titular aparece con un cartel verde que dice "Personal Use Only"
en lugar de parte del texto. En este caso, el título "8/08 — Sprinters x Margha"
mostraba el sello donde iba "8/08" y el resto se veía bien.

**Causa raíz.** Las versiones *trial* / *personal use* suelen venir mutiladas a
propósito: el autor reemplaza el contorno de ciertos glifos por una imagen con
el aviso de licencia. Lo más común es que ataquen los **dígitos**, porque casi
ningún texto de prueba los usa y casi todo diseño real sí.

**Cómo confirmarlo antes de aplicar la fuente.** Un glifo normal tiene entre 1 y
3 contornos. El sello tiene decenas, y todos los glifos afectados comparten el
mismo ancho:

```python
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen

f = TTFont('fuente.otf')
cmap, gs = f.getBestCmap(), f.getGlyphSet()

for ch in "0123456789ABCabc":
    gn = cmap.get(ord(ch))
    if not gn:
        print(f"{ch!r}: SIN GLIFO"); continue
    rp = RecordingPen(); gs[gn].draw(rp)
    contornos = sum(1 for op, _ in rp.value if op == 'moveTo')
    aviso = "  <-- SOSPECHOSO" if contornos > 20 else ""
    print(f"{ch!r}: {contornos} contornos, ancho {round(gs[gn].width)}{aviso}")
```

Salida real del caso: los diez dígitos con **115 contornos** y ancho idéntico
(1109); las letras, entre 1 y 3. Diagnóstico inmediato.

**Solución.** No hay ninguna del lado del código: es una protección deliberada
del autor y evadirla no es una opción. Las salidas son comprar la licencia
comercial (viene el archivo completo) o no usar la fuente.

**Regla derivada — el chequeo que hay que hacer siempre.** Antes de aplicar
cualquier fuente que no venga de Google Fonts o de una compra:

1. Mirar el **nombre del archivo**. Si dice "Trial", "Demo" o "Personal Use", ya
   está avisando. Acá el archivo se llamaba literalmente
   `Harper-Bold Personal Use.otf`.
2. Leer el `readme.txt` del zip. Suele estar el alcance de la licencia y el mail
   del autor.
3. Correr el chequeo de contornos de arriba sobre dígitos y acentos.
4. Probar con **texto real del sitio**, no con "Handgloves" ni con lorem ipsum.
   El sello apareció recién con un título que empezaba con una fecha.

El paso 4 es el que más se saltea: la fuente se veía perfecta en el preview
porque el preview no tenía números.

---

## 3. CSS y layout

### 3.1 `clamp()` con el máximo por debajo del mínimo

**Síntoma.** Un padding o font-size que nunca crece, siempre queda en el valor
más chico, y a simple vista la regla parece correcta.

**Causa.**

```css
padding:clamp(20px,5vw,0);   /* ← el max (0) es menor que el min (20px) */
```

`clamp(min, preferido, max)` resuelve como `max(min, min(preferido, max))`. Si
`max < min`, **gana `min` siempre** y el valor queda congelado. No tira error ni
aparece tachado en DevTools: es CSS válido.

**Solución.** `clamp(20px,5vw,32px)`.

**Cómo detectarlo.** Buscar todos los `clamp` del proyecto y revisar que el
tercer valor sea mayor que el primero:

```bash
grep -rnoE "clamp\([^)]*\)" --include="*.css" --include="*.html" . | sort -u
```

Vale la pena hacerlo una vez por proyecto: es un bug silencioso.

---

### 3.2 Alinear columnas que tienen distinta cantidad de texto

**Síntoma.** Dos precios que deberían estar a la misma altura aparecen
desfasados, porque uno tiene una línea de texto extra debajo.

**Causa.**

```css
.price-breakdown{display:flex;align-items:flex-end}
```

`flex-end` ancla los ítems **por abajo**. Si un ítem tiene tres líneas y el
otro dos, el de dos queda empujado hacia abajo y los números —que están arriba—
quedan desalineados.

**Solución.** `align-items:flex-start`: los dos ítems arrancan a la misma
altura sin importar cuánto texto tengan debajo.

**Regla derivada.** Elegir el `align-items` según **qué elemento tiene que
quedar alineado**, no según cómo se ve con el contenido de prueba:

- ¿Se alinea lo de arriba (títulos, números grandes)? → `flex-start`
- ¿Se alinea lo de abajo (botones al pie de tarjetas)? → `flex-end`
- ¿Se alinean las líneas de base del texto? → `baseline`
- ¿Todos del mismo alto? → `stretch`

Siempre probar con ítems de distinto largo. Con contenido parejo, los cuatro se
ven igual y el bug aparece recién en producción.

---

### 3.3 Centrar una grilla cuando hay menos elementos que columnas

**Síntoma.** Una grilla de 4 columnas con un solo elemento deja la tarjeta
pegada a la izquierda y un hueco enorme a la derecha.

**Causa.** `grid-template-columns:repeat(4,1fr)` siempre crea 4 pistas. Con un
elemento, las otras 3 quedan vacías pero ocupan lugar.

**Intento que no sirve.** `justify-content:center` a secas centra el conjunto de
pistas, pero como las pistas de `1fr` ya ocupan todo el ancho, no cambia nada.

**Solución.** Ajustar la cantidad de columnas por JS al total real, con un ancho
calculado para que la tarjeta **no cambie de tamaño** según cuántas haya:

```js
const n = items.length;
if (n < 4){
  // calc(25% - 12px) reproduce el ancho de una columna de repeat(4,1fr)
  // con gap:16px → cada columna mide 25% menos 3/4 del gap (12px).
  grid.style.gridTemplateColumns = `repeat(${n}, minmax(0, calc(25% - 12px)))`;
  grid.style.justifyContent = 'center';
} else {
  // Reset: sin esto, una recarga con más elementos conserva el estilo viejo
  grid.style.gridTemplateColumns = '';
  grid.style.justifyContent = '';
}
```

**De dónde sale `25% - 12px`.** En una grilla de N columnas hay N-1 gaps. Con 4
columnas y `gap:16px`, cada columna mide `(100% - 3×16px)/4` = `25% - 12px`.
Fórmula general para C columnas: `calc(100%/C - gap×(C-1)/C)`.

**Los dos errores clásicos acá:**

1. **Olvidar el reset.** Si se setean estilos inline en una función que corre
   más de una vez (recarga, filtro, paginado), hay que limpiarlos al principio
   o quedan pegados del render anterior.
2. **Usar `1fr` en vez de un ancho fijo.** Con `repeat(1, 1fr)` la única tarjeta
   se estira a todo el ancho. `minmax(0, calc(...))` la mantiene del tamaño que
   tendría en la grilla completa.

**`minmax(0, …)` no es opcional.** Sin eso, el contenido que no entra (un título
largo, una imagen) desborda la columna en vez de encogerse.

---

### 3.4 Una maqueta que se ve "genérica" y no como la marca

**Síntoma.** El sitio usa los colores correctos en los textos pero se siente
blanco y negro, sin identidad.

**Causa raíz.** Casi siempre: los elementos **interactivos** quedaron en el
negro de la maqueta original. En este caso todo lo interactivo usaba
`--ink: #1B1B1B`:

```css
.tabs-pill{background:var(--ink)}                      /* píldora de tabs */
.field-input:focus{border-color:var(--ink)}            /* foco */
.pill-opt.checked{border-color:var(--ink)}             /* opción elegida */
.btn-primary{background:var(--ink)}                    /* CTA */
.legal a{color:var(--ink);border-bottom:1px solid var(--ink)}
```

El ojo lee la identidad de una interfaz en **lo que reacciona**: el foco, lo
seleccionado, el botón. Si eso es negro, el sitio es negro por más que el
título sea verde.

**Solución. Repartir los roles, no reemplazar colores uno por uno:**

| Rol | Qué agarra | Color |
|---|---|---|
| Estructura | Bordes, foco, links, opción elegida, eyebrows, píldoras activas | Principal de marca (Bosque `#024939`) |
| CTA de conversión | El botón que cierra la acción | Acento (Terracota `#fd521b`) |
| Texto | Cuerpo, labels | Neutro oscuro (Asfáltico `#1B1B1B`) |
| Superficie grande | Fondo de página | Crema `#faf8ec`, nunca blanco puro |
| Superficie elevada | Campos, tarjetas | Blanco, para despegarse del crema |

**Detalle que hace más de lo que parece:** los grises de las líneas. Pasar de
`rgba(10,10,10,.10)` (negro) a `rgba(2,73,57,.14)` (marca) hace que los bordes
se sientan parte de la paleta y no un gris de sistema. Es sutil pero se nota.

**Implementación.** Si la página define sus propias variables, tocar la capa de
variables y no las reglas:

```css
:root{
  --bg:var(--crema);                 /* era #ffffff */
  --line:rgba(2,73,57,.14);          /* era rgba(10,10,10,.10) */
  --field-bg:#ffffff;                /* invertido: el campo es lo claro */
  --field-border:rgba(2,73,57,.16);
  --marker:var(--bosque);
}
```

Después sí, revisar una por una las reglas que usaban el neutro como fondo o
borde y pasarlas al color de marca.

**Verificar contraste, siempre.** Cambiar la paleta puede romper accesibilidad
sin que se note:

```python
def lum(h):
    h = h.lstrip('#'); r,g,b = [int(h[i:i+2],16)/255 for i in (0,2,4)]
    f = lambda c: c/12.92 if c <= .03928 else ((c+.055)/1.055)**2.4
    return .2126*f(r) + .7152*f(g) + .0722*f(b)

def ratio(a, b):
    la, lb = lum(a), lum(b)
    return round((max(la,lb) + .05) / (min(la,lb) + .05), 2)

print(ratio('#1B1B1B', '#fd521b'))   # CTA: 5.25 → pasa AA
```

Umbrales WCAG AA: **4.5:1** texto normal, **3:1** texto grande (≥24px o ≥19px
bold) y componentes de interfaz.

Ojo con Terracota `#fd521b`: con texto blanco da 3.1:1 (no pasa AA para texto
normal), con Asfáltico da 5.25:1. Por eso el CTA lleva texto oscuro, no blanco.

---

## 4. Responsive / mobile

### 4.1 Texto del nav que se parte en varias líneas

**Síntoma.** En mobile, "Mi cuenta" aparece como `MI` / `CUENTA` en dos
renglones, pegado al logo.

**Causa.** Un `<nav>` con `display:flex` y `justify-content:space-between`: al
achicarse la pantalla, los ítems se comprimen hasta que el texto se parte. El
`gap` no protege porque `space-between` reparte el sobrante, y cuando no hay
sobrante deja los elementos pegados.

**Solución — tres reglas juntas, ninguna alcanza sola:**

```css
nav .link{
  white-space:nowrap;   /* 1. el texto nunca se parte */
  flex-shrink:0;        /* 2. el ítem no se comprime */
}
.brand-mark{flex-shrink:0}

@media (max-width:640px){
  nav{gap:24px !important}     /* 3. piso real de separación */
}
```

**El error de criterio.** En el breakpoint móvil se había *bajado* el gap de
24px a 10px "para ganar espacio". Es al revés: con `space-between`, el gap es lo
único que garantiza separación cuando el espacio libre se agota. Bajarlo es
justamente lo que deja los elementos pegados.

**Si aun así no entra**, acortar el texto en vez de dejar que se parta:

```html
<a class="back"><span class="arrow">←</span> Volver<span class="rest"> a la agenda</span></a>
```

```css
@media (max-width:640px){
  .back span{display:none}   /* queda solo "Volver" */
}
```

**Cómo detectarlo.** Probar a 320px de ancho (el mínimo realista), no a 375px.
Y probarlo con el texto más largo posible: en este caso el nav cambia según haya
sesión iniciada, y el estado logueado —con el nombre del usuario— era el que
rompía.

---

### 4.2 Foto vertical que empuja el contenido fuera de pantalla

**Causa.** Un `aspect-ratio:4/5` que funciona en desktop se vuelve altísimo
cuando la columna pasa a ancho completo en mobile.

**Solución.** Cambiar la proporción por breakpoint, no el tamaño:

```css
@media (max-width:900px){ .hero-img{aspect-ratio:16/11} }
@media (max-width:560px){ .card-media{aspect-ratio:16/10} }
```

**Regla derivada.** Un `aspect-ratio` pensado para una columna angosta casi
nunca sirve cuando esa columna pasa a ocupar todo el ancho. Revisar cada
`aspect-ratio` al apilar un layout de 2 columnas a 1.

---

### 4.3 Alto del viewport en mobile

`100vh` en mobile incluye la barra del navegador, así que el hero queda cortado.

```css
#hero{min-height:100vh}
#hero{min-height:100svh}   /* small viewport height: el alto real visible */
```

Dejar los dos: el segundo pisa al primero en navegadores que lo soportan y los
viejos se quedan con `vh`.

---

## 5. Formato de fechas, precios y texto

### 5.1 `es-AR` devuelve hora en formato 12h

**Síntoma.** Se muestra `06:39 p. m. hs` — con "p. m." y el sufijo "hs"
duplicando la información.

**Causa.** `Intl.DateTimeFormat('es-AR')` usa 12 horas por defecto, aunque en
Argentina se escriba en 24. El template agregaba " hs" asumiendo 24h.

**Solución.**

```js
const fmtTime = iso => new Intl.DateTimeFormat('es-AR', {
  hour:'2-digit', minute:'2-digit', hour12:false
}).format(new Date(iso));
// → "18:39", y el " hs" del template ahora sí tiene sentido
```

**Regla derivada.** Nunca asumir el formato por defecto de un locale. Si el
template agrega un sufijo (`hs`, `%`, `$`), forzar explícitamente la opción de
`Intl` que lo hace consistente. Y probar con una hora **de la tarde**: a las
09:15 el bug no se ve.

---

### 5.2 Los saltos de párrafo se pierden

**Síntoma.** Un texto cargado desde el admin con párrafos separados aparece todo
junto en un solo bloque.

**Causa.** El texto se inyectaba en un `<p>` con `textContent`. HTML colapsa los
saltos de línea; un `\n` en el medio de un párrafo es un espacio.

**Solución.** Cambiar el contenedor de `<p>` a `<div>` (un `<p>` no puede
contener otros `<p>`) y partir el texto en párrafos reales:

```js
function renderDescription(text){
  const el = document.getElementById('evDesc');
  const raw = String(text || '').replace(/\r\n?/g, '\n').trim();
  if (!raw){ el.style.display = 'none'; return; }
  el.style.display = '';
  const paragraphs = raw.split(/\n+/).map(p => p.trim()).filter(Boolean);
  el.innerHTML = paragraphs.map(p => `<p>${esc(p)}</p>`).join('');
}
```

```css
.desc p{margin:0 0 14px}
.desc p:last-child{margin-bottom:0}
```

**Los cuatro detalles que importan:**

1. `.replace(/\r\n?/g,'\n')` — normaliza saltos de Windows (`\r\n`) y Mac
   clásico (`\r`). Sin esto, un texto pegado desde Word no se parte.
2. `split(/\n+/)` con `+` — colapsa líneas en blanco múltiples en un solo corte.
3. `.filter(Boolean)` — descarta párrafos vacíos.
4. **`esc()` sobre cada párrafo.** Se está usando `innerHTML` con texto que
   viene de la base: sin escapar, es un XSS.

**Alternativa sin `innerHTML`:** `white-space:pre-line` en CSS respeta los `\n`
sin tocar el JS. Sirve si no hace falta control del margen entre párrafos.

---

### 5.3 Escapar antes de `innerHTML` — siempre

Cualquier dato que venga de la base o del usuario y se inyecte con `innerHTML`
tiene que pasar por un escape:

```js
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({
  '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
}[c]));

grid.innerHTML = items.map(i => `<div class="card">${esc(i.title)}</div>`).join('');
```

`String(s ?? '')` maneja `null` y `undefined` sin imprimir "null" en pantalla.

**Cuándo no hace falta:** con `textContent` o `.value`, que no interpretan HTML.

---

## 6. Backend, RPC y migraciones

### 6.1 Agregar un campo editable sin tocar un ENUM existente

**Situación.** Hay una columna `branch` de tipo ENUM (`'running'`, `'social'`)
que además de mostrarse en pantalla controla lógica: imágenes por defecto,
filtros, tablas relacionadas (planes, programas, organizadores). El pedido era
poder mostrar "Trekking" en un evento puntual.

**Por qué no se agrandó el ENUM.** `ALTER TYPE ... ADD VALUE` impacta en todas
las tablas que usan ese tipo y en toda la lógica que hace `WHERE branch = ...`.
Un valor nuevo puede romper constraints, defaults y consultas que asumen dos
casos. Riesgo alto para un cambio que era solo de presentación.

**Solución. Columna nueva, nullable, solo para mostrar:**

```sql
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS custom_tag TEXT;

COMMENT ON COLUMN public.events.custom_tag IS
  'Etiqueta que se muestra en la card y en el detalle (ej. "Trekking"). '
  'Si es NULL/vacío, el front usa el nombre de la categoría (branch).';
```

Y en el front, fallback en cadena:

```js
const tag = ev.custom_tag || TAG_LABEL[ev.branch] || ev.branch;
```

**Regla derivada.** Antes de tocar un ENUM, preguntarse si el pedido es de
**presentación** o de **comportamiento**. Si es solo lo que se ve, una columna
de texto opcional con fallback resuelve sin tocar nada de lo existente.

---

### 6.2 Distinguir "no cambió" de "lo vaciaron a propósito"

**Problema.** Una función de update que usa `COALESCE` no puede diferenciar
"este campo no se envió" de "el usuario lo borró y quiere que quede vacío":

```sql
custom_tag = COALESCE(p_custom_tag, custom_tag)
-- si p_custom_tag llega NULL porque el admin vació el campo,
-- COALESCE lo interpreta como "no cambiar" y el valor viejo sobrevive
```

**Solución. Un flag explícito de limpieza por cada campo opcional:**

```sql
CREATE OR REPLACE FUNCTION public.admin_update_event(
  …,
  p_custom_tag       TEXT    DEFAULT NULL,
  p_clear_custom_tag BOOLEAN DEFAULT FALSE
) …
UPDATE public.events SET
  custom_tag = CASE
                 WHEN p_clear_custom_tag THEN NULL
                 ELSE COALESCE(NULLIF(TRIM(p_custom_tag), ''), custom_tag)
               END
WHERE id = p_event_id;
```

Del lado del cliente:

```js
const tagVal = document.getElementById('e-tag').value.trim();
await supa.rpc('admin_update_event', {
  p_event_id: id,
  p_custom_tag: tagVal || null,
  p_clear_custom_tag: !tagVal,   // vacío = lo borró a propósito
});
```

`NULLIF(TRIM(x), '')` normaliza: un campo con espacios queda como NULL, no como
un string en blanco que después rompe el `||` del front.

**Alternativa.** Recibir un `JSONB` con solo las claves que cambiaron. Más
elegante pero pierde el tipado de los parámetros; con pocos campos opcionales el
flag es más simple de leer.

---

### 6.3 Guardar falla después de agregar un parámetro a un RPC

**Síntoma.** Se agrega un campo al formulario y **todo** el guardado empieza a
fallar — incluso los campos que no se tocaron. En este caso el usuario reportó
dos síntomas distintos ("no puedo editar la etiqueta" y "quedó la foto vieja")
que eran **el mismo bug**.

**Causa raíz.** El front pasa a mandar un parámetro nuevo (`p_custom_tag`) que
la función en la base todavía no tiene, porque la migración no se corrió.
PostgreSQL resuelve funciones por firma completa: si no existe una con esos
parámetros, la llamada falla entera. No falla "la parte nueva": falla todo.

**Solución.** Correr la migración. Pero el aprendizaje real es de proceso:

**Regla derivada.** Cuando el front y la base cambian juntos y la migración se
aplica a mano, **el cambio de front es una bomba de tiempo hasta que la
migración corre**. Mitigaciones, de menor a mayor esfuerzo:

1. **Dejarlo escrito en el archivo de migración**, arriba de todo y en
   mayúsculas — el que la corre lo ve sí o sí:

   ```sql
   -- CÓMO APLICAR: pegar este archivo entero en el SQL Editor de Supabase y
   -- correrlo. Sin este paso, guardar un evento desde Admin no va a funcionar:
   -- admin_create_event/admin_update_event pasan a pedir un parámetro
   -- (p_custom_tag) que hoy no existe en la base.
   ```

2. **Que el parámetro sea opcional** (`DEFAULT NULL`) y mandarlo desde el front
   solo si existe. Más código, pero el front nunca rompe.

3. **Deployar la migración antes que el front.** Es la regla general: la base
   va primero, el front después.

**Cómo diagnosticarlo rápido.** Si "todo el guardado se rompió" justo después
de agregar un campo, el orden de sospecha es: (1) migración sin correr,
(2) firma del `DROP FUNCTION` que no coincide, (3) `GRANT` sin actualizar.

---

### 6.4 Redefinir una función de Postgres que cambió de firma

**Problema.** `CREATE OR REPLACE FUNCTION` **no** reemplaza una función si
cambió la lista de parámetros: crea una sobrecarga nueva. Quedan dos versiones y
las llamadas se vuelven ambiguas.

**Solución. `DROP` explícito con la firma vieja, completa:**

```sql
DROP FUNCTION IF EXISTS public.admin_update_event(
  UUID,TEXT,TIMESTAMPTZ,branch_type,TEXT,TEXT,NUMERIC,INTEGER,TIMESTAMPTZ,
  TEXT,JSONB,BOOLEAN,BOOLEAN,BOOLEAN,UUID,UUID,logistics_type,BOOLEAN,
  NUMERIC,BOOLEAN,after_run_payment_type
);

CREATE OR REPLACE FUNCTION public.admin_update_event(…nueva firma…) …;

-- Los GRANT también van por firma: hay que rehacerlos con la nueva
GRANT EXECUTE ON FUNCTION public.admin_update_event(
  UUID,TEXT,…,after_run_payment_type,TEXT,BOOLEAN
) TO authenticated;
```

**Los tres detalles:**

1. La firma del `DROP` tiene que coincidir **exactamente** con la que está en la
   base. Sacarla del archivo de migración anterior, no escribirla de memoria.
2. Los parámetros nuevos van **al final** y con `DEFAULT`. Insertarlos en el
   medio rompe cualquier llamada posicional.
3. Los `GRANT` se pierden al hacer `DROP`. Hay que volver a darlos.

**Consulta para ver la firma real:**

```sql
SELECT p.proname, pg_get_function_identity_arguments(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'admin_update_event';
```

---

### 6.5 Funciones que sobreviven a columnas nuevas

Si una función devuelve `SETOF tabla` y hace `SELECT t.*`, **no hay que tocarla**
al agregar una columna: la expone automáticamente.

```sql
CREATE OR REPLACE FUNCTION public.admin_list_events(…)
RETURNS SETOF public.events        -- ← el tipo es la tabla entera
…
  RETURN QUERY SELECT e.* FROM public.events e WHERE …;
```

En cambio, si devuelve `TABLE(col1 …, col2 …)` con columnas enumeradas, hay que
redefinirla en cada cambio.

**Regla derivada.** Para funciones de listado internas, `RETURNS SETOF tabla`
ahorra mantenimiento. Para APIs públicas conviene lo contrario: enumerar las
columnas evita filtrar campos nuevos sin querer.

**Lo mismo del lado del cliente:**

```js
.select('*')                                  // toma columnas nuevas solo
.select('id,title,event_date,custom_tag')     // hay que agregarla a mano
```

Si se usa lista explícita de columnas (mejor para el peso de la respuesta), hay
que acordarse de sumar la columna nueva. Fue exactamente el paso que había que
hacer en la home y no en el detalle, porque una usaba lista y la otra `*`.

---

## 7. Deploy, caché y git

### 7.1 "Lo cambié y no se ve" — árbol de diagnóstico

Antes de tocar código, descartar en este orden:

```bash
# 1) ¿Está commiteado?
git status --short

# 2) ¿Está pusheado? (comparar local vs remoto)
git log --oneline -1
git log --oneline origin/master -1

# 3) ¿El remoto tiene el cambio adentro?
git show origin/master:"archivo.html" | grep -c "loQueCambie"

# 4) ¿El deploy terminó? (mirar el panel del hosting)

# 5) Caché del navegador → Ctrl+Shift+R
```

**Error propio a evitar:** dar por sentado que algo no está pusheado sin
verificarlo. En esta sesión afirmé que el cambio no había llegado a producción
cuando en realidad sí; el usuario perdió tiempo mirando donde no era. **Verificar
contra el repositorio antes de afirmar el estado del deploy** — son dos comandos.

---

### 7.2 Cachear assets sin cachear HTML

```json
{
  "headers": [
    {
      "source": "/images/(.*)",
      "headers": [{ "key": "Cache-Control", "value": "public, max-age=31536000, immutable" }]
    },
    {
      "source": "/(.*).html",
      "headers": [{ "key": "Cache-Control", "value": "public, max-age=0, must-revalidate" }]
    }
  ]
}
```

Imágenes y fuentes cacheadas para siempre (`immutable`), HTML nunca. Así un
deploy se ve al instante pero los assets no se rebajan en cada visita. Si un
asset cambia, se le cambia el nombre.

---

### 7.3 Auditar el `.gitignore` antes de un commit grande

```bash
# Qué se subiría realmente, incluyendo lo ignorado
git status --porcelain=v1 --ignored | sort

# Confirmar que un archivo puntual está ignorado y por qué regla
git check-ignore -v .env "notas internas.md"

# Archivos ya trackeados que hoy matchean un patrón de ignore
git ls-files | grep -iE "\.env|secreto|INFORME"
```

**Lo que se pasa por alto.** Agregar un patrón al `.gitignore` **no saca del
repo lo que ya estaba trackeado**. `.gitignore` solo afecta a archivos sin
trackear. Para sacarlos:

```bash
git rm --cached "archivo.md"    # lo saca del repo, lo deja en disco
```

Y si tenía algo sensible, ya está en el historial: sacarlo del commit actual no
alcanza.

**Checklist de lo que casi siempre hay que ignorar:** `.env` y variantes,
`node_modules/`, entornos virtuales, carpetas de config de IA/agentes
(`.claude/`, `.agents/`), notas y planes internos, y archivos fuente pesados que
no se publican (el OTF original cuando lo que se sirve es el WOFF2).

---

## 8. Método de trabajo

Cosas que no son bugs pero que hicieron la diferencia.

### 8.1 Verificar el JS de páginas sin build step

Sin bundler no hay nada que avise de un error de sintaxis hasta que el navegador
falla en runtime. Extraer el `<script>` y pasarlo por `node --check`:

```bash
for f in *.html; do
  python3 - "$f" << 'PY'
import sys, re
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
sc = re.findall(r'<script>(.*?)</script>', s, re.S)
open('/tmp/check.js','w').write(sc[-1] if sc else '')
PY
  node --check /tmp/check.js >/dev/null 2>&1 && echo "$f OK" || echo "$f ERROR"
done
```

Toma segundos y agarra comas de más, llaves sin cerrar y template literals mal
terminados antes de deployar.

### 8.2 Probar la lógica sin navegador

Para lógica pura (cálculo de precios, formato, decisiones de layout), extraer la
función a un `.mjs` y correrla con casos borde:

```js
// test-grid.mjs
function computeGrid(n){
  return n < 4
    ? { cols:`repeat(${n}, minmax(0, calc(25% - 12px)))`, justify:'center' }
    : { cols:'', justify:'' };
}
for (const n of [0,1,2,3,4,5]) console.log(n, JSON.stringify(computeGrid(n)));
```

Más rápido que abrir el navegador y deja el caso borde documentado.

### 8.3 Verificar el diff, no el archivo

Después de un cambio masivo hecho por script, confirmar que **solo** cambió lo
que se quería:

```bash
# Muestra las líneas modificadas que NO contienen lo esperado.
# Si devuelve vacío, el cambio fue quirúrgico.
git diff -U0 | grep "^[+-]" | grep -v "^[+-][+-]" | grep -vi "Inter\|Poppins"
```

Esto detecta el caso peligroso: un `replace` que además tocó algo que no debía.

### 8.4 Comentar el porqué, no el qué

Los comentarios que sirvieron son los que explican una decisión no obvia:

```css
/* align-items:flex-end anclaba los dos items por abajo: como "After run" tiene
   una tercera línea que "Run" no tiene, su número quedaba más arriba. Con
   flex-start los dos arrancan a la misma altura sin importar el texto debajo. */
```

```sql
-- p_clear_custom_tag existe porque "vaciar el campo" y "no tocar el campo" son
-- dos cosas distintas: COALESCE solo no alcanza.
```

Sin ese comentario, el próximo que pase "corrige" el `flex-start` a `flex-end`
porque le parece más prolijo, y el bug vuelve.

### 8.5 Antes de tocar algo compartido, medir el alcance

Antes de agrandar el ENUM, la pregunta fue: ¿quién más usa esto?

```bash
grep -rn "branch" db/*.sql | grep -iE "type|enum|check|constraint"
```

Cuatro tablas dependían del tipo. Eso cambió la solución de "agrandar el ENUM"
a "columna nueva de presentación" — menos elegante en el papel, pero sin riesgo
sobre lógica que no se estaba pidiendo tocar.

---

## Apéndice — checklist rápido

Antes de dar por cerrado un cambio de front:

- [ ] `node --check` sobre el JS de cada página tocada
- [ ] `git diff -U0` filtrado: ¿cambió solo lo que se quería?
- [ ] Abrir con doble clic (`file://`), no solo con servidor
- [ ] Probar a 320px de ancho, no solo a 375px
- [ ] Probar los dos estados de sesión (logueado y sin loguear)
- [ ] Probar con el contenido más largo posible, no con el de ejemplo
- [ ] Si hubo cambio de colores: verificar contraste de los pares nuevos
- [ ] Si hubo cambio de tipografía: `grep` de la vieja tiene que dar cero
- [ ] Si el front manda un parámetro nuevo a la base: ¿corrió la migración?
- [ ] `git status --porcelain --ignored`: ¿se cuela algo que no debería?
