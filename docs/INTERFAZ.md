# Interfaz: del diseño a la aplicación

**Fecha:** 2026-11-22
**Diseño:** proyecto "Sismos Chile · Observatorio" en Superdesign ([canvas](https://superdesign.dev/teams/f3a38209-a57f-4aa7-b872-ecf0d1493eb9/projects/562da62f-78e2-42c5-a41f-a573b77052ac)).
**Presentación:** 11-12-2026, en vivo en el computador de Gabriel, con la base local.

---

## 1. Qué hay en el repositorio

| Archivo | Qué es |
|---|---|
| `.superdesign/design-system.md` | Sistema de diseño: producto, los cinco modos, colores (la interfaz es monocroma; el color es dato), tipografías, componentes de vidrio y movimiento. Es la referencia para todo lo visual. |
| `docs/design/01_explorar.html` … `05_mi_comuna.html` | Las cinco pantallas aprobadas, exportadas de Superdesign. Se abren en el navegador. Los fondos son imágenes; en la aplicación se reemplazan por el mapa vivo (sección 3). |
| `scripts/render_ui_basemap.py` | Renderiza con datos de PostGIS el fondo de "Explorar" (60.846 sismos únicos coloreados por Mw). |
| `scripts/render_ui_modes.py` | Renderiza los fondos y gráficos de Replay, Placa 3D, Anatomía (incluye la población expuesta a MMI ≥ VI con el ShakeMap del Maule) y Mi comuna, e imprime sus cifras. |

Los dos scripts se ejecutan con el Python de QGIS y dejan las imágenes en `.superdesign/tmp/` (fuera de Git). Sirven para regenerar el diseño y para las figuras del informe.

---

## 2. Arquitectura

```text
Navegador (http://127.0.0.1:8000)
  app/web/                HTML + CSS del diseño, JavaScript por modo
    MapLibre GL JS        mapa 2D: tierra, comunas, sismos, contornos
    deck.gl               capa 3D de la Placa (sismos a su profundidad)
        │  fetch JSON / teselas vectoriales
        ▼
  app/api/  (FastAPI)     consultas SQL parametrizadas → GeoJSON / MVT / JSON
        │  psycopg
        ▼
  PostgreSQL 18 + PostGIS (127.0.0.1:5433, la misma base del proyecto)
```

- **Un solo comando para la demo:** FastAPI sirve la API **y** los archivos de `app/web/`, así que basta `uvicorn` y abrir el navegador.
- **Funciona sin internet:** no usamos mapas de terceros. La tierra, las regiones y las comunas salen de nuestra base (y los países vecinos, del mapa mundial que trae QGIS, exportado una vez a `app/web/data/`). Las librerías JavaScript se guardan en `app/web/vendor/` en vez de cargarlas desde un CDN. Así el laboratorio no depende de la red.
- **Sin paso de compilación:** HTML, CSS y JavaScript simples (módulos ES). Tailwind se reemplaza por un CSS propio con los tokens del sistema de diseño, para no depender de su CDN.

---

## 3. Cómo se pasa cada parte del diseño

### 3.1 Lo que se copia casi igual

La "cáscara" de las cinco pantallas es HTML y CSS que ya funciona: barra superior con los modos, paneles de vidrio (`.liquid-glass`), tipografías, leyendas, línea de tiempo. Se copia de `docs/design/` a `app/web/index.html` y `app/web/css/observatorio.css`, y los números escritos a mano se cambian por elementos que llena el JavaScript con lo que devuelve la API.

### 3.2 Lo que se reemplaza por datos vivos

| En el diseño (imagen fija) | En la aplicación | Endpoint de la API |
|---|---|---|
| Fondo con los sismos coloreados por Mw | Capa `circle` de MapLibre con estilo según el dato: radio y color interpolados por `mw` con la misma rampa del sistema de diseño | `GET /tiles/events/{z}/{x}/{y}.pbf` (teselas vectoriales con `ST_AsMVT`, filtros por año, Mw, profundidad, región y fuente) |
| Tierra, regiones y comunas | Capas `fill` y `line` de MapLibre | `GET /api/areas?level=region` (GeoJSON simplificado) |
| Ficha del sismo seleccionado | Clic en un sismo → panel lleno con la ficha | `GET /api/events/{id}`: `v_event_location_unique`, zona urbana más cercana, población a 25/50/100 km, papel en la secuencia, impacto USGS |
| Histograma de la línea de tiempo | Barras generadas con los conteos reales | `GET /api/stats/years?mw_min=4` |
| **Replay** | Animación con `requestAnimationFrame`: el filtro de tiempo avanza y la opacidad depende de la edad del sismo; los Mw ≥ 7 disparan una onda | Los mismos sismos, con su fecha |
| **Placa 3D** | `ScatterplotLayer` de deck.gl con posición `[lon, lat, −profundidad]` sobre MapLibre inclinado | `GET /api/events/depth` |
| Corte de la placa | Gráfico dibujado en un `<canvas>` | `GET /api/profile?lat_min=-24&lat_max=-20` |
| **Anatomía**: réplicas, elipse y Omori | Réplicas como capa; la elipse se calcula en SQL con la covarianza de las coordenadas; Omori con conteos en intervalos logarítmicos | `GET /api/sequences/{event_id}` (necesita el paso 3 del plan: réplicas) |
| **Anatomía**: contornos MMI y población expuesta | Capas `line`/`fill` con los colores oficiales del USGS | `GET /api/shakemap/{event_id}` (parte de Ignacio, pasos 6 y 7) |
| **Mi comuna** | Buscador → zoom a la comuna, su contorno, su ciudad y sus sismos coloreados por profundidad | `GET /api/search?q=calama`, `GET /api/communes/{codigo}` (versión con parámetros de las consultas 3, 14 y 15) |
| Zonas calientes Gi\* | Capa de hexágonos activable | `GET /api/hotspots` (parte de Ignacio, paso 8) |

**Por qué teselas vectoriales para los sismos:** mandar los 61.133 sismos como GeoJSON pesa varios MB en cada filtro. Con `ST_AsMVT` PostGIS entrega solo lo que se ve en cada nivel de zoom, ya recortado y comprimido. Además es un buen ejemplo para el informe de cómo la base espacial sirve directamente a la interfaz.

---

## 4. Estructura de carpetas

```text
app/
  api/
    main.py               FastAPI: monta la API y sirve app/web/
    db.py                 conexión (lee .env, igual que los scripts)
    routes/
      events.py           sismos, ficha, teselas, histograma        (Gabriel)
      areas.py            regiones, comunas, búsqueda               (Gabriel)
      sequences.py        réplicas, elipse, Omori                   (Gabriel)
      intensity.py        ShakeMap, población expuesta, Gi*        (Ignacio)
  web/
    index.html            la cáscara del diseño
    css/observatorio.css  tokens y componentes del sistema de diseño
    js/
      map.js              MapLibre: estilo propio sin internet      (Gabriel)
      modes/explorar.js, replay.js, placa3d.js, anatomia.js, micomuna.js  (Gabriel)
      intensity.js        contornos MMI y capa Gi*                  (Ignacio)
    vendor/               maplibre-gl, deck.gl (copias locales)
    data/                 países vecinos (GeoJSON exportado una vez)
  requirements.txt        fastapi, uvicorn, psycopg[binary]
```

Para correrla (con la base encendida):

```powershell
PowerShell -ExecutionPolicy Bypass -File .\app\run.ps1
```

La primera vez crea `app\.venv` e instala `app\requirements.txt`; después abre http://127.0.0.1:8000.

---

## 5. Orden de construcción

Cada paso deja algo que se ve en el navegador:

1. **Esqueleto** (hecho el 22-11): FastAPI sirviendo `index.html` con la cáscara del diseño; mapa con tierra y regiones desde la base; los sismos por teselas vectoriales con la rampa de colores. Ya se ve "Explorar".
2. **Explorar completo** (hecho el 22-11; faltan "Ocultar réplicas" y Gi\*, que esperan sus datos): filtros conectados, ficha del sismo al hacer clic, histograma real.
3. **Replay** (2–3 dic): animación 1906–2026.
4. **Anatomía** (3–4 dic): cuando las tablas de réplicas tengan datos; los contornos MMI cuando Ignacio cargue `shakemap_contour`.
5. **Placa 3D y Mi comuna** (4–5 dic).
6. **Ensayo de la demo** (6–9 dic): sin internet, en el computador de la presentación, con capturas de respaldo.

Si un estado nuevo de la interfaz necesita diseño (por ejemplo, el panel de comparación de métodos de réplicas), se diseña primero en el mismo proyecto de Superdesign y se exporta a `docs/design/`.
