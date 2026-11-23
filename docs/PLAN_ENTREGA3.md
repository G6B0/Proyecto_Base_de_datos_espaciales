# Plan de la entrega 3 (entrega final)

**Equipo:** Gabriel Huerta, Ignacio Barría
**Fecha del plan:** 2026-11-22 (actualizado el mismo día con los análisis y la interfaz)
**Entrega final:** informe el 10-12-2026 y presentación en el laboratorio del 11-12-2026 (Control 3: 30-11-2026)

Este plan reparte el trabajo de la entrega 3 entre los dos. Gabriel lleva el camino crítico (catálogo USGS, emparejamiento, réplicas, la interfaz y la integración del informe). Ignacio lleva bloques completos y casi independientes: intensidad ShakeMap, población expuesta, zonas calientes (Gi\*), su módulo de la interfaz y los mapas finales. Lo que se prometió en la presentación del Hito 2 está en [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md), sección 11.

---

## 1. Qué pide el informe final y cómo lo cubrimos

| Sección del informe | Criterio de la rúbrica | Cómo lo cubrimos | Quién |
|---|---|---|---|
| 1. Introducción y requerimientos | Se pide (descuenta si falta) | Problema, preguntas y requerimientos del sistema | Gabriel |
| 2. Modelo lógico y sistema | Modelo de datos (2 pts) | Las 21 tablas implementadas y llenas, más las vistas | Gabriel |
| 3. Fuentes y carga | Datos (1,5 pts) | CSN, USGS completo (31.007 sismos), DPA, Censo 2024 y ShakeMap | Gabriel (sismos) e Ignacio (ShakeMap) |
| 4. Algoritmos | Consultas y procesamiento (1 pt) | Emparejamiento CSN–USGS, Gardner-Knopoff, ST-DBSCAN, Gi\* en SQL | Ambos |
| 5. Análisis | Análisis espacial (0,5 pts) | Test de Knox, elipses de las secuencias, zonas calientes Gi\*, población expuesta a MMI ≥ VI | Ambos |
| 6. Interfaz | Interfaz (1 pt) | Aplicación web local conectada a PostGIS, en el computador de Gabriel | Gabriel (núcleo) e Ignacio (módulo de intensidad) |

Los análisis salen de la materia del curso (*Methods of Spatial Data Analysis*): exploración (KDE, elipse de desviación estándar), patrones locales (Getis-Ord Gi\*) y espacio-tiempo (test de Knox, ST-DBSCAN). Los modelos de regresión espacial, el kriging y las trayectorias no aplican a este problema y quedan fuera.

---

## 2. Qué tenemos que responder

| Pregunta | Cómo | Quién |
|---|---|---|
| ¿Cuántos sismos hay sin contar dos veces el mismo? | `event_match` y la vista `v_event_location_unique` | Gabriel (**hecho**) |
| ¿Este sismo es réplica? ¿Cuántas réplicas tuvo cada terremoto? | Gardner-Knopoff y ST-DBSCAN → `declustering_run`, `seismic_sequence`, `event_sequence_role` | Gabriel |
| ¿Los sismos se agrupan en espacio y tiempo? ¿El declustering lo elimina? | Test de Knox con permutaciones, antes y después del declustering | Gabriel |
| ¿Qué forma tiene cada secuencia de réplicas? | Elipse de desviación estándar de cada secuencia | Gabriel |
| ¿Dónde están las zonas calientes de sismicidad? | Getis-Ord Gi\* en una grilla de hexágonos, con el catálogo sin réplicas | Ignacio |
| ¿Cuánto se sacudió el suelo? | `event_impact_summary` (**hecho**) y `shakemap_contour` | Ignacio (contornos) |
| ¿Cuántas personas quedaron expuestas a intensidad VI o más? | `shakemap_contour` + `census_block` | Ignacio |

---

## 3. Orden y dependencias

```text
1. USGS completo (hecho) ──> 2. event_match + Mlv (hecho) ──> 3. Réplicas: GK + ST-DBSCAN ──> 4. Knox y elipses ─────┐
                         │                                                    │                                     │
                         │                                                    └──> 8. Gi* sobre el catálogo sin      │
                         │                                                         réplicas (Ignacio)               ├──> 10. Informe y
                         └──> 6. Contornos ShakeMap ──> 7. Población MMI >= VI (Ignacio) ──────────────────────────┤        presentación
5. Descargador ShakeMap (Ignacio) ──┘                                                                               │
                                     9. Interfaz: núcleo (Gabriel) ──> módulo de intensidad (Ignacio) ─────────────┘
```

- Los pasos 3 (Gabriel) y 5 (Ignacio) empiezan ya, en paralelo.
- Gi\* (paso 8) usa el catálogo **sin réplicas**, así que espera a que Gabriel publique la primera ejecución de Gardner-Knopoff (meta: 26-11). Mientras tanto Ignacio puede programarlo con el catálogo completo.
- La interfaz empieza cuando las tablas de réplicas tengan datos; el módulo de Ignacio, cuando exista el esqueleto de la aplicación (meta: 1-12).

---

## 4. Calendario

| Fechas | Gabriel | Ignacio |
|---|---|---|
| 23–26 nov | 3. Gardner-Knopoff final sobre USGS M ≥ 4 (ventana de precursores corregida) y ST-DBSCAN como alternativa. | 5. Descargador de ShakeMap; actualizar su base con el USGS completo (sección 6.0). |
| 27–30 nov | 4. Test de Knox, elipses de las secuencias, Omori y Båth. Esqueleto de la interfaz. Crear la tabla de Gi\*. | 6. Carga de contornos. 8. Gi\* en hexágonos (primera versión). **Control 3 el 30-11.** |
| 1–5 dic | 9. Interfaz: mapa, filtros, ficha de cada sismo, réplicas y animación. | 7. Población expuesta a MMI ≥ VI. 8. Gi\* final. 9. Módulo de intensidad de la interfaz. |
| 6–9 dic | 10. Informe: integración y secciones 1, 2, 4 y 6. Ensayo de la demo. | 10. Mapas QGIS finales; secciones de ShakeMap, exposición y Gi\*; diapositivas de su parte. |
| **10 dic** | **Entrega del informe** | |
| **11 dic** | **Presentación con la interfaz en vivo** (computador de Gabriel) | Presenta intensidad, exposición y zonas calientes |

---

## 5. Tareas de Gabriel

### 5.1 USGS completo e impacto (paso 1) — hecho

31.007 sismos USGS (M ≥ 4 desde 1904 más la muestra reciente); `event_impact_summary` con 5.321 sismos (1.165 con ShakeMap, 4.594 DYFI, 384 PAGER). PR #5.

### 5.2 Emparejamiento y calibración de Mlv (paso 2) — hecho

29.219 pares CSN–USGS (60 s y 100 km, voraz uno a uno); vista `v_event_location_unique` con 61.133 sismos únicos; `Mlv` calibrada (−0,09); consultas 16 a 19. PR #6.

### 5.3 Réplicas (paso 3)

- **Gardner-Knopoff** en SQL (`db/decluster_gardner_knopoff.sql`) sobre USGS M ≥ 4 (decisión D9), con la ventana de precursores corregida. El borrador probado sobre el CSN está en la sección 4.6 del modelo lógico.
- **ST-DBSCAN** (`db/decluster_st_dbscan.sql`) como alternativa: agrupa por densidad en espacio y tiempo. Cada método queda como una ejecución en `declustering_run`, y se comparan.
- **Listo cuando:** dos ejecuciones guardadas y una consulta que compara cuántas réplicas encuentra cada método en los grandes terremotos.

### 5.4 Análisis de las secuencias (paso 4)

- **Test de Knox** (`analysis/knox_test.py`): cuenta los pares de sismos cercanos en espacio **y** tiempo, y lo compara con 999 permutaciones de los tiempos. Antes del declustering la interacción debe ser fuerte; después, mucho menor. Es la validación del paso 3.
- **Elipse de desviación estándar** de cada secuencia: su orientación y alargamiento muestran la ruptura (el Maule debería salir alargado de norte a sur) y la limitación de la ventana circular de Gardner-Knopoff.
- **Omori y Båth** en los grandes terremotos.
- **Tabla para Gi\*:** crear en `db/schema.sql`, antes del 27-11, la tabla donde Ignacio guarda el resultado (sección 6.4).

### 5.5 Interfaz (paso 9, núcleo)

Aplicación web **local**, conectada en vivo a PostGIS; se presenta en el computador de Gabriel.

- **Backend:** FastAPI en `app/api/`. Devuelve GeoJSON desde PostGIS (`ST_AsGeoJSON`) con filtros.
- **Frontend:** MapLibre GL JS en `app/web/`, sin paso de compilación (HTML y JavaScript simples).
- **Funciones:** mapa de sismos sin duplicados; filtros por fecha, Mw, región y fuente; ficha de cada sismo (comuna, zona urbana más cercana, población a 25/50/100 km, rol en la secuencia, intensidad); secuencias de réplicas con su elipse; animación en el tiempo.
- **Listo cuando:** se puede hacer la demo completa en 5 minutos sin tocar QGIS ni psql.

### 5.6 Informe (paso 10)

Integra el informe final a partir del del Hito 2 y escribe las secciones 1, 2, 4 y 6.

---

## 6. Tareas de Ignacio

Archivos que te tocan (nadie más los edita): `scripts/download_usgs_shakemaps.py`, `db/load_shakemaps.sql`, el script de PowerShell que los orqueste, `db/hotspots_gi.sql`, `app/api/routes/intensity.py`, `app/web/js/intensity.js` y las consultas **20 a 24** de `db/queries.sql`. **No toques `db/schema.sql`**: si te falta algo, avísale a Gabriel.

### 6.0 Poner tu base al día (antes del paso 6)

Tu base no tiene el catálogo USGS completo, y los contornos se unen a esos sismos. Desde `main`:

```powershell
git checkout main
git pull
PowerShell -ExecutionPolicy Bypass -File .\scripts\start_local_postgis.ps1
.\scripts\run_usgs_earthquakes_qgis.cmd --start 1900-01-01 --min-magnitude 4
PowerShell -ExecutionPolicy Bypass -File .\scripts\load_catalogs_postgis.ps1
```

El descargador tarda un par de minutos y la carga unos 13 (calcula la cercanía de 31.000 sismos nuevos). Alternativa: pedirle a Gabriel el respaldo y seguir el atajo de [GUIA_ACTUALIZACION_v2.md](GUIA_ACTUALIZACION_v2.md).

### 6.1 Descargador de ShakeMap (paso 5)

**Qué sismos:** los que tienen ShakeMap en el rectángulo de Chile. La API los filtra directamente:

```text
https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&starttime=1900-01-01&minlongitude=-76&minlatitude=-56&maxlongitude=-66&maxlatitude=-17&minmagnitude=4&eventtype=earthquake&producttype=shakemap
```

Al 22-11-2026 son **1.165**. Cada sismo trae en `properties.detail` la URL de su ficha. También están en la base: `SELECT detail_url FROM seismic.event_impact_summary WHERE has_shakemap`.

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

### 6.2 Carga en `shakemap_contour` (paso 6)

Igual que el censo: `ogr2ogr` a un esquema temporal (`shakemap_staging`) y luego un SQL que pasa al modelo en una transacción.

- `earthquake_event_id`: se busca por `source_code = 'usgs'` y `source_event_id` = id del sismo.
- `metric = 'mmi'`, `contour_value = PARAMVALUE`, `geom` como MultiPolygon en EPSG:4326 (`ST_Multi`, `ST_MakeValid`).
- La tabla tiene UNIQUE (`earthquake_event_id`, `metric`, `contour_value`, `shakemap_version`): recargar no debe duplicar.
- Registra la carga en `ingestion_run`, como hacen los demás cargadores.

**Listo cuando:** `shakemap_contour` tiene los contornos de los 1.165 sismos y Maule 2010 se ve bien en QGIS sobre los límites regionales.

### 6.3 Población expuesta a MMI ≥ VI (paso 7)

El borrador de la consulta está en [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md), sección 5.3.4. La idea es sumar la población de las manzanas cuyo punto interior (`census_block.point`) cae dentro de los polígonos con `contour_value >= 6`.

- Revisa primero si los polígonos de `mi.shp` son **bandas** (solo entre un valor y el siguiente) o **anidados** (cada uno contiene a los de mayor intensidad). Cambia la consulta: con bandas hay que unir todas las de valor ≥ 6, y con anidados basta el de 6.
- Compara el resultado con los anillos de 25, 50 y 100 km que ya tenemos (`event_population_exposure`): es el análisis central de tu parte. La materia lo dice así: muchos eventos no es lo mismo que mucha población en riesgo.
- Escribe la consulta como **consulta 20** en `db/queries.sql`.

### 6.4 Zonas calientes con Getis-Ord Gi\* (paso 8)

Diapositivas 34 a 44 de la materia. Responde **dónde se concentra la sismicidad más de lo esperable**.

- **Unidad espacial:** una grilla de hexágonos (`ST_HexagonGrid`, por ejemplo de 25 km de lado) sobre Chile y su costa. Créala en un sistema proyectado en metros (por ejemplo EPSG:32719, UTM 19S, el mismo del mapa del proyecto QGIS) y transfórmala a 4326 para cruzarla con los sismos; en 4326 el tamaño estaría en grados. No usamos comunas porque sus tamaños son muy distintos (problema de la unidad de área modificable, MAUP: diapositiva 8).
- **Variable:** cantidad de sismos Mw ≥ 4 por hexágono, del catálogo **sin réplicas** (sismos `mainshock` e `independent` de la ejecución de Gardner-Knopoff que publique Gabriel). Mientras no exista, prueba con `v_event_location_unique`.
- **Vecindad:** hexágonos a una distancia fija (por ejemplo, los que se tocan más el propio, que es lo que define Gi\* con asterisco).
- **Cálculo en SQL:** la fórmula de Gi\* (puntaje z) se puede escribir con sumas sobre los vecinos. Clasifica cada hexágono en zona caliente o fría con 90, 95 o 99 % de confianza.
- **Cuidado:** al probar cientos de hexágonos a la vez aparecen falsos positivos (diapositiva 40). Menciona la corrección (Bonferroni o FDR) en el informe.
- Guarda el resultado en la tabla que crea Gabriel antes del 27-11; mientras tanto, usa una tabla temporal. Escribe una consulta de resumen como **consulta 21**.
- **Para el informe:** compara la versión con todo el catálogo y la versión sin réplicas. Las réplicas inflan las zonas calientes alrededor de los grandes terremotos.

### 6.5 Módulo de intensidad de la interfaz (paso 9)

Cuando Gabriel publique el esqueleto (meta: 1-12):

- **Backend** (`app/api/routes/intensity.py`): un endpoint que devuelve los contornos de un sismo y su población expuesta a MMI ≥ VI, y otro con los hexágonos de Gi\*.
- **Frontend** (`app/web/js/intensity.js`): al elegir un sismo con ShakeMap, dibujar sus contornos coloreados por MMI y mostrar la población expuesta; una capa activable con las zonas calientes.

### 6.6 Mapas, informe y presentación (paso 10)

- Mapas QGIS finales (contornos de intensidad, población expuesta, zonas calientes), exportados como imágenes para el informe.
- Secciones del informe: carga de ShakeMap (en "Fuentes y carga"), población expuesta y Gi\* (en "Análisis").
- Las diapositivas de su parte y presentarla el 11-12.

---

## 7. Cómo trabajamos

- **Una rama por tarea** y un pull request a `main`. Nadie trabaja directo en `main`.
- **Esquema:** solo Gabriel toca `db/schema.sql`. Si te falta una columna o una tabla, avisa.
- **Consultas en `db/queries.sql`:** Gabriel usa de la 16 a la 19 (hechas) y de la 25 a la 29; Ignacio de la 20 a la 24.
- **Interfaz:** Gabriel crea la estructura de `app/`; Ignacio solo edita sus dos archivos (sección 6.5).
- **Base de datos:** cada uno tiene la suya local. Si se necesita, Gabriel comparte un respaldo (`pg_dump`) por Drive. No usamos Supabase: la base pesa más de 1 GB y el plan gratis permite 500 MB por organización.
- **Datos descargados y respaldos:** nunca a Git (ya están en `.gitignore`).
- **Demo del 11-12:** en el computador de Gabriel, con la base y la interfaz locales. Llevar también capturas de pantalla por si algo falla.

---

## 8. Estado

| Paso | Responsable | Estado |
|---|---|---|
| 1. USGS completo + `event_impact_summary` | Gabriel | **Hecho** (22-11): 31.007 sismos USGS; 5.321 resúmenes de impacto (1.165 con ShakeMap) |
| 2. `event_match` + `Mlv` | Gabriel | **Hecho** (22-11): 29.219 pares; 61.133 sismos únicos; `Mlv` calibrada (−0,09); consultas 16 a 19 |
| 3. Réplicas: Gardner-Knopoff y ST-DBSCAN | Gabriel | Pendiente (borrador probado sobre el CSN) |
| 4. Test de Knox, elipses, Omori y Båth | Gabriel | Pendiente |
| 5. Descargador de ShakeMap | Ignacio | Pendiente |
| 6. Carga de contornos | Ignacio | Pendiente |
| 7. Población expuesta a MMI ≥ VI | Ignacio | Pendiente |
| 8. Zonas calientes Gi\* | Ignacio | Pendiente |
| 9. Interfaz (núcleo / módulo de intensidad) | Gabriel / Ignacio | Pendiente |
| 10. Informe y presentación | Ambos | Pendiente |
