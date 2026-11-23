# Plan de la entrega 3 (entrega final)

**Equipo:** Gabriel Huerta, Ignacio Barría
**Fecha del plan:** 2026-11-22
**Entrega final:** informe el 10-12-2026 y presentación en el laboratorio del 11-12-2026 (Control 3: 30-11-2026)

Este plan reparte el trabajo de la entrega 3 entre los dos. Gabriel lleva el camino crítico (catálogo USGS, emparejamiento y réplicas) e Ignacio un bloque casi independiente (intensidad ShakeMap, población expuesta y mapas finales). Lo que se prometió en la presentación del Hito 2 está en [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md), sección 11.

---

## 1. Qué tenemos que responder

| Pregunta | Tablas que la responden | Quién |
|---|---|---|
| ¿Cuántos sismos hay sin contar dos veces el mismo? | `event_match` | Gabriel |
| ¿Este sismo es réplica? ¿Cuántas réplicas tuvo cada terremoto? | `declustering_run`, `seismic_sequence`, `event_sequence_role` | Gabriel |
| ¿Cuánto se sacudió el suelo? | `event_impact_summary`, `shakemap_contour` | Gabriel (resumen) e Ignacio (contornos) |
| ¿Cuántas personas quedaron expuestas a intensidad VI o más? | `shakemap_contour` + `census_block` | Ignacio |

Las siete tablas ya existen en la base (Hito 2). No hay que cambiar el esquema; solo llenarlas.

---

## 2. Orden y dependencias

```text
1. USGS completo M>=4 + event_impact_summary  (Gabriel)  ──┬──> 2. event_match + calibrar Mlv (Gabriel) ──> 3. Réplicas (Gabriel)
                                                           │
                                                           └──> 5. Cargar contornos en shakemap_contour (Ignacio) ──> 6. Población expuesta (Ignacio)
4. Descargador de ShakeMap (Ignacio)  ──────────────────────────┘
                                                                                     7. Mapas QGIS, informe y presentación (ambos)
```

- **El paso 1 va primero:** el emparejamiento, las réplicas y los contornos necesitan los sismos USGS en `earthquake_event`. Hoy solo hay una muestra de 189.
- **El paso 4 puede empezar ya**, en paralelo, porque consulta la API del USGS directamente y no necesita la base.

---

## 3. Calendario

| Fechas | Gabriel | Ignacio |
|---|---|---|
| 22–25 nov | 1. Descargador y carga del USGS completo; `event_impact_summary`. Respaldo de la base para Ignacio. | 4. Prototipo del descargador de ShakeMap con Maule 2010 e Illapel 2015. |
| 25–28 nov | 2. `event_match`; calibrar `Mlv` con los pares. | 4–5. Descarga de los 1.165 ShakeMap; carga en `shakemap_contour`. |
| 28 nov – 2 dic | 3. Gardner-Knopoff sobre USGS M ≥ 4; Omori y Båth. | 6. Población expuesta a MMI ≥ VI; primeros mapas QGIS. |
| 3–10 dic | 7. Informe final (entrega el 10-12) e integración. | 7. Mapas finales, sus secciones del informe y la presentación (11-12). |

---

## 4. Tareas de Gabriel

### 4.1 USGS completo e impacto (paso 1)

- Extender `scripts/download_usgs_earthquakes.py` para guardar `mmi`, `cdi`, `alert`, `types` y `detail` de cada sismo. Vienen en la respuesta normal de la API; no hace falta pedir sismo por sismo.
- Descargar los sismos M ≥ 4 desde 1900 en el rectángulo de Chile: **30.998** al 22-11-2026.
- Cargarlos con `load_catalogs_postgis.ps1` y llenar `event_impact_summary`: intensidad máxima (MMI), intensidad reportada (CDI), alerta PAGER y qué productos existen.
- Generar un respaldo de la base (`pg_dump`) para que Ignacio lo restaure sin recargar todo.

**Listo cuando:** la base tiene los ~31.000 sismos USGS, `event_impact_summary` marca 1.165 con ShakeMap, y el respaldo está en Drive.

**Ojo:** desde este paso, las consultas que mezclan fuentes cuentan dos veces los sismos que publican el CSN y el USGS. Lo corrige el paso 2.

### 4.2 Emparejamiento CSN–USGS y calibración de Mlv (paso 2)

- Llenar `event_match`: dos registros son el mismo sismo si están a menos de 60 s y 100 km, con un puntaje de 0 a 1.
- Con los pares `Mlv` (CSN) y `mww`/`mwr` (USGS), ajustar una fórmula propia para `Mlv` y guardarla con un `UPDATE` en `magnitude_conversion`.
- Agregar consultas que cuenten sin duplicados (consultas 16 a 19).

### 4.3 Réplicas (paso 3)

- Gardner-Knopoff en SQL sobre USGS M ≥ 4 (decisión D9). Hay un borrador probado sobre el CSN (sección 4.6 del modelo lógico).
- Corregir la ventana de precursores (hoy es simétrica y salen demasiados) y guardar cada variante como una ejecución en `declustering_run`.
- Analizar la ley de Omori (decaimiento de las réplicas) y la ley de Båth (réplica mayor ≈ principal − 1,2) en los grandes terremotos.

---

## 5. Tareas de Ignacio

Archivos nuevos que te tocan (nadie más los edita): `scripts/download_usgs_shakemaps.py`, `db/load_shakemaps.sql`, el script de PowerShell que los orqueste y las consultas desde la 20 en adelante. **No hace falta tocar `db/schema.sql`**: la tabla `shakemap_contour` ya existe.

### 5.1 Descargador de ShakeMap (paso 4)

**Qué sismos:** los que tienen ShakeMap en el rectángulo de Chile. La API los filtra directamente:

```text
https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&starttime=1900-01-01&minlongitude=-76&minlatitude=-56&maxlongitude=-66&maxlatitude=-17&minmagnitude=4&eventtype=earthquake&producttype=shakemap
```

Al 22-11-2026 son **1.165**. Cada sismo trae en `properties.detail` la URL de su ficha.

**Qué archivo bajar de cada ficha:** en la ficha, `properties.products.shakemap[0]` es el ShakeMap preferido; `contents` lista sus archivos. Lo revisamos con Maule 2010 (`official20100227063411530_30`):

| Archivo | Qué trae | ¿Sirve? |
|---|---|---|
| `download/cont_mmi.json` | **Líneas** de contorno (MultiLineString) cada 0,5 de MMI | No directamente: la tabla guarda polígonos. |
| `download/shape.zip` → `mi.shp` | **Polígonos** de intensidad, con el valor en el campo `PARAMVALUE` | **Sí.** Es lo que va a `shakemap_contour` con `metric = 'mmi'`. |
| `download/info.json` | Versión y metadatos del ShakeMap | Para `shakemap_version`. |

Cuidados:
- `shape.zip` pesa 21 MB en Maule (trae también PGA, PGV y aceleraciones espectrales). Mide cuánto suman los 1.165 antes de bajarlos todos. Si es demasiado, la alternativa es cerrar las líneas de `cont_mmi.json` en polígonos con `ST_Polygonize`.
- Guarda lo descargado en `data/raw/usgs_shakemap/<id_del_sismo>/` (ya está fuera de Git). Si el archivo ya existe, no lo vuelvas a bajar.
- Usa una pausa corta entre pedidos y el mismo `User-Agent` que `download_usgs_earthquakes.py`.
- Al revisar con `ogrinfo` puede aparecer un error de PROJ porque toma el `proj.db` de PostgreSQL. Es el mismo problema que resolvió tu script del censo: usa el GDAL de QGIS con su propio `PROJ_LIB`.

**Listo cuando:** hay una carpeta por sismo con su `mi.shp` (o sus líneas) y un CSV de control con id, versión, tamaño y fecha de descarga.

### 5.2 Carga en `shakemap_contour` (paso 5)

Igual que el censo: `ogr2ogr` a un esquema temporal (`shakemap_staging`) y luego un SQL que pasa al modelo en una transacción.

- `earthquake_event_id`: se busca por `source_code = 'usgs'` y `source_event_id` = id del sismo. Necesita que Gabriel haya cargado el USGS completo (paso 1) o el respaldo de la base.
- `metric = 'mmi'`, `contour_value = PARAMVALUE`, `geom` como MultiPolygon en EPSG:4326 (`ST_Multi`, `ST_MakeValid`).
- La tabla tiene UNIQUE (`earthquake_event_id`, `metric`, `contour_value`, `shakemap_version`): recargar no debe duplicar.
- Registra la carga en `ingestion_run`, como hacen los demás cargadores.

**Listo cuando:** `shakemap_contour` tiene los contornos de los 1.165 sismos y Maule 2010 se ve bien en QGIS sobre los límites regionales.

### 5.3 Población expuesta a MMI ≥ VI (paso 6)

El borrador de la consulta está en [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md), sección 5.3.4. La idea es sumar la población de las manzanas cuyo punto interior (`census_block.point`) cae dentro de los polígonos con `contour_value >= 6`.

- Revisa primero si los polígonos de `mi.shp` son **bandas** (solo entre un valor y el siguiente) o **anidados** (cada uno contiene a los de mayor intensidad). Cambia la consulta: con bandas hay que unir todas las de valor ≥ 6, y con anidados basta el de 6.
- Compara el resultado con los anillos de 25, 50 y 100 km que ya tenemos (`event_population_exposure`): es el análisis central de tu parte.
- Escribe la consulta como **consulta 20** en `db/queries.sql`.

### 5.4 Mapas QGIS y presentación (paso 7)

- Agrega al proyecto `qgis/sismos_chile_v2.qgs` (o a uno nuevo `qgis/sismos_chile_final.qgs`) las capas de contornos de intensidad, secuencias de réplicas y población expuesta.
- Exporta los mapas como imágenes para el informe y la presentación (no llevaremos computador).

---

## 6. Cómo trabajamos

- **Una rama por tarea** y un pull request a `main`. Nadie trabaja directo en `main`.
- **Esquema:** solo Gabriel toca `db/schema.sql`. Si te falta una columna, avisa.
- **Consultas:** Gabriel usa de la 16 a la 19 e Ignacio desde la 20, para no chocar en `db/queries.sql`.
- **Base de datos:** cada uno tiene la suya local. Después del paso 1, Gabriel comparte un respaldo (`pg_dump`) por Drive y se restaura con `pg_restore`. No usamos Supabase: la base ya pesa 937 MB y el plan gratis permite 500 MB por organización.
- **Datos descargados:** nunca a Git (ya están en `.gitignore`).

---

## 7. Estado

| Paso | Estado |
|---|---|
| 1. USGS completo + `event_impact_summary` | **Hecho** (22-11): 31.007 sismos USGS; 5.321 resúmenes de impacto (1.165 con ShakeMap) |
| 2. `event_match` + `Mlv` | **Hecho** (22-11): 29.219 pares; vista `v_event_location_unique` (61.133 sismos únicos); `Mlv` calibrada (−0,09); consultas 16 a 19 |
| 3. Réplicas | Pendiente (borrador probado sobre el CSN) |
| 4. Descargador de ShakeMap | Pendiente (Ignacio) |
| 5. Carga de contornos | Pendiente |
| 6. Población expuesta | Pendiente |
| 7. Mapas, informe y presentación | Pendiente |
