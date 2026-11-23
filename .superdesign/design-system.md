# Design system — "Sismos Chile · Observatorio"

Interfaz web local del proyecto *Sistema de base de datos espacial para el análisis de la sismicidad en Chile* (Bases de Datos Espaciales y Geográficas, entrega final). Se presenta en vivo con proyector el 11-12-2026, en un notebook (1920 × 1080). Todo el texto de la interfaz va en **español de Chile**.

Base de estilo: **Observe — "See the shape of the noise"** (biblioteca Superdesign), adaptada. Idea central: **la interfaz es monocroma y de vidrio; todo el color sale de los datos** (en Observe sale del video de fondo; aquí sale del mapa y de los sismos).

---

## 1. Producto

**Qué es:** un observatorio de la sismicidad de Chile. Un mapa oscuro a pantalla completa con 61.133 sismos únicos (catálogos del CSN y del USGS emparejados, 1513–2026), las comunas oficiales, 592 ciudades y la población del Censo 2024. Los datos vienen en vivo de PostgreSQL + PostGIS a través de una API.

**Para quién:** la profesora y el curso durante una demo de 5 minutos; después, cualquiera que quiera entender dónde tiembla en Chile, cerca de quién y con qué intensidad.

**Trabajos a resolver (JTBD):**
1. "Muéstrame 120 años de sismos de Chile de un vistazo" → **Replay**.
2. "Quiero ver por qué tiembla así" (la placa de Nazca hundiéndose) → **Placa 3D**.
3. "Cuéntame qué pasó en un gran terremoto" (réplicas, intensidad, gente expuesta) → **Anatomía de un terremoto**.
4. "¿Qué tan sísmico es mi lugar?" → **Mi comuna**.
5. "Déjame filtrar y consultar" → **Explorar** (modo por defecto).

**Arquitectura de pantallas:** una sola aplicación con un mapa permanente y cinco modos que cambian los paneles flotantes:

| Modo | Qué muestra |
|---|---|
| **Explorar** (por defecto) | Todos los sismos filtrables por fecha, Mw, profundidad, región y fuente; ficha del sismo seleccionado; contadores. |
| **Replay** | Animación 1906–2026: los sismos aparecen año a año, los grandes destellan; contador de año gigante; línea de tiempo con histograma y controles de reproducción y velocidad. |
| **Placa 3D** | Mapa inclinado en 3D; cada sismo a su profundidad (0–700 km), coloreado por profundidad; un corte transversal (perfil oeste–este) que muestra la placa hundiéndose. |
| **Anatomía de un terremoto** | Un terremoto elegido (Maule 2010, Illapel 2015, Iquique 2014, Valparaíso 1985): sus réplicas aparecen en el tiempo, su elipse de desviación estándar, los contornos de intensidad ShakeMap (MMI), la población expuesta a MMI ≥ VI y la curva de Omori. |
| **Mi comuna** | Búsqueda de comuna o ciudad: su historia sísmica, el mayor sismo, los sismos de los últimos 3 meses, la población, la zona urbana frente a la comuna y si está en una zona caliente (Gi\*). |

**Datos reales para usar en los diseños (no inventar otros):**
- 61.133 sismos únicos (90.352 registros: 59.345 CSN y 31.007 USGS; 29.219 pares emparejados).
- 345 comunas, 56 provincias, 16 regiones; 592 ciudades y pueblos; 216.341 manzanas; 16,2 millones de personas en manzanas.
- Maule 27-02-2010: Mw 8,8; epicentro frente a Cobquecura; profundidad 25 km; MMI máxima 8,2 (USGS); intensidad reportada 9,1; ~940 réplicas.
- Illapel 16-09-2015: Mw 8,3 (Canela). Iquique 01-04-2014: Mw 8,1 (Huara), réplica mayor Mw 7,7. Valparaíso 03-03-1985: Mw 8,0 (frente a Casablanca), réplica mayor Mw 7,4. Valdivia 22-05-1960: Mw 9,5 (el mayor registrado en el mundo).
- Calama: 15.545 km² de comuna y 37 km² de ciudad; 217 sismos Mw ≥ 5 en la comuna y solo 1 bajo la ciudad; 564 sismos en los últimos 3 meses (11-08 al 11-11-2026), profundidad media 119 km.
- Los Andes 15-12-1983: Mw 6,0; 2,0 millones de personas viven hoy a 50 km del epicentro.

---

## 2. Principios visuales

1. **Monocromo en la interfaz.** Negro, blanco y blanco con opacidad. Ningún color de acento en botones, bordes o texto de la interfaz.
2. **El color es dato.** Solo los sismos, los contornos de intensidad, las zonas calientes y los gráficos llevan color, siempre con su leyenda.
3. **Vidrio sobre el mapa.** Todos los paneles flotan sobre el mapa como "liquid glass"; nunca hay fondos sólidos que tapen el mapa.
4. **Una idea por modo.** Cada modo tiene un número o título protagonista en Instrument Serif (el año del replay, "Maule 2010", "Calama").
5. **Legible con proyector.** Texto de interfaz de 13 px como mínimo; números clave de 40 a 120 px; contraste alto.

---

## 3. Color

### 3.1 Interfaz (monocroma)

| Token | Valor | Uso |
|---|---|---|
| `--bg` | `#000000` | Fondo de la página y bajo el mapa. |
| `--map-land` | `#0b0d10` | Tierra en el mapa base. |
| `--map-ocean` | `#030405` | Océano (casi negro, más oscuro que la tierra). |
| `--map-borders` | `rgba(255,255,255,0.10)` | Límites regionales; comunas `rgba(255,255,255,0.05)`. |
| `--fg` | `#ffffff` | Texto principal. |
| `--fg-2` | `rgba(255,255,255,0.70)` | Texto secundario. |
| `--fg-3` | `rgba(255,255,255,0.45)` | Etiquetas, unidades, ejes. |
| `--line` | `rgba(255,255,255,0.10)` | Separadores dentro de paneles. |
| `--selected` | `#ffffff` | Selección: anillo blanco alrededor del sismo elegido. |

### 3.2 Datos (los únicos colores)

**Magnitud (Mw)** — rampa secuencial cálida, tipo "inferno", más grande y más brillante con la magnitud:

| Mw | Color |
|---|---|
| < 4 | `#3b1c4a` |
| 4 – 5 | `#8a2be2` → `#c2185b` |
| 5 – 6 | `#f4511e` |
| 6 – 7 | `#ffa726` |
| 7 – 8 | `#ffe082` |
| ≥ 8 | `#fffde7` con halo |

**Profundidad** — rampa fría (para Placa 3D y la leyenda alternativa): 0–70 km `#7dd3fc`, 70–150 km `#38bdf8`, 150–300 km `#6366f1`, > 300 km `#a855f7`.

**Intensidad MMI** — escala oficial de colores ShakeMap del USGS (no cambiarla): I `#ffffff`, II–III `#bfccff`, IV `#a0e6ff`, V `#80ffff`, VI `#7aff93`, VII `#ffff00`, VIII `#ffc800`, IX `#ff9100`, X+ `#ff0000`.

**Zonas calientes Gi\*** — divergente: fría 99 % `#2563eb`, 95 % `#60a5fa`, 90 % `#bfdbfe`, no significativa transparente, caliente 90 % `#fecaca`, 95 % `#f87171`, 99 % `#dc2626`.

---

## 4. Tipografía

| Rol | Fuente | Tamaño |
|---|---|---|
| Protagonista (año del replay, nombre del terremoto, comuna) | **Instrument Serif** (regular e itálica), Google Fonts | 64–160 px, `tracking-tight`, con aura de texto `text-shadow: 0 0 72px rgba(0,0,0,.42), 0 4px 28px rgba(0,0,0,.28)` |
| Interfaz (navegación, etiquetas, botones, texto) | **Inter** | 13–16 px; títulos de panel 13 px en mayúsculas con `letter-spacing: .08em` y `--fg-3` |
| Números y datos (Mw, fechas, coordenadas, conteos) | **JetBrains Mono** | 12–40 px, cifras tabulares |

Instrument Serif solo para el protagonista de cada modo; nunca en párrafos ni botones.

---

## 5. Superficies y componentes

### 5.1 Liquid glass (de Observe, sin cambios)

```css
.liquid-glass {
  background: rgba(0, 0, 0, 0.35);          /* más opaco que Observe: el mapa tiene detalle */
  background-blend-mode: luminosity;
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  box-shadow: inset 0 1px 1px rgba(255, 255, 255, 0.1);
  position: relative;
  overflow: hidden;
}
.liquid-glass::before {
  content: ''; position: absolute; inset: 0; border-radius: inherit; padding: 1.4px;
  background: linear-gradient(180deg, rgba(255,255,255,.45) 0%, rgba(255,255,255,.15) 20%,
    rgba(255,255,255,0) 40%, rgba(255,255,255,0) 60%, rgba(255,255,255,.15) 80%, rgba(255,255,255,.45) 100%);
  -webkit-mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
  -webkit-mask-composite: xor; mask-composite: exclude; pointer-events: none;
}
```

`.liquid-glass-circle` para los botones redondos (zoom, play, capas), igual que en Observe.

### 5.2 Formas

- Pastillas, botones, chips, buscador y barra de navegación: `rounded-full`.
- Paneles con contenido (ficha, filtros, gráficos): `rounded-3xl` (24 px), padding 20–24 px.
- Sin sombras de superficie: solo el brillo interior del vidrio y las auras de texto.

### 5.3 Componentes clave

- **Barra superior (pastilla de vidrio centrada):** logotipo (anillo de puntos que se vuelve arco, como Observe, con un punto central = epicentro) + "Sismos Chile" + selector de modos en pastillas (Explorar · Replay · Placa 3D · Anatomía · Mi comuna); a la derecha, el buscador de comuna o ciudad y un indicador "PostGIS en vivo" (punto blanco que pulsa).
- **Panel de filtros (izquierda):** rango de años (doble deslizador), Mw mínimo, profundidad, región (lista), fuente (CSN, USGS, ambas) y un contador grande en JetBrains Mono "61.133 sismos".
- **Ficha del sismo (derecha):** fecha y hora UTC, Mw homogéneo y magnitud publicada, profundidad, comuna y distancia, zona urbana más cercana, población a 25/50/100 km, papel en la secuencia (principal, réplica, independiente), intensidad MMI máxima con su color oficial, y "también publicado por USGS" cuando hay par.
- **Línea de tiempo (abajo):** histograma de sismos por año (barras finas blancas al 40 %), cursor, botones de vidrio redondos (play/pausa, velocidad 1×/10×/100×) y fecha actual.
- **Leyendas:** pequeñas y en vidrio, con la rampa de color correspondiente al modo.
- **Gráficos:** líneas y barras finas en blanco al 70 %; el dato destacado en el color de su escala; ejes en `--fg-3`.

---

## 6. Mapa

- Mapa base oscuro sin etiquetas excesivas (estilo "dark matter"): océano casi negro, tierra apenas más clara, límites regionales tenues, nombres de ciudades principales en `--fg-3`.
- Chile es una franja larga de norte a sur: en 16:9 el país va vertical en el centro, el Pacífico a la izquierda y los Andes y Argentina a la derecha. Los paneles flotan en los costados sin tapar la costa.
- Sismos como círculos con radio según Mw (de 1,5 a 18 px) y color según la rampa; los Mw ≥ 7 llevan halo suave. La densidad de la zona de subducción frente a la costa debe leerse como una banda luminosa.

---

## 7. Movimiento

- **Replay:** cada sismo nace con un destello (escala 0 → 1,6 → 1 y opacidad 1 → 0,6 en 600 ms); los Mw ≥ 7 emiten una onda circular que se expande y se desvanece en 2 s.
- **Anatomía:** las réplicas aparecen en orden temporal; los contornos MMI se dibujan desde afuera hacia adentro.
- **Placa 3D:** transición de cámara suave (inclinación 0° → 60°, 1,2 s, ease-in-out).
- Paneles: aparecen con un desvanecimiento de 200 ms; sin rebotes ni animaciones decorativas.
- El indicador "PostGIS en vivo" pulsa lento (2 s).

---

## 8. Requisitos del proyecto

- Escritorio 1920 × 1080; legible en proyector.
- Todo en español; números con formato chileno (punto de miles, coma decimal: 61.133; Mw 8,8).
- Citar las fuentes en un pie discreto: "Datos: CSN, USGS ComCat, DPA 2023 (SUBDERE/IDE Chile), Censo 2024 (INE)".
- Nunca hablar de "daño": se habla de intensidad y de población expuesta.
