# Guía para actualizar tu base al modelo v2

**Para:** Ignacio  
**Fecha:** 2026-11-07 (actualizada el 2026-11-22 con lo del Hito 2)  
**Punto de partida:** ya tienes funcionando lo de la primera entrega: el clúster local en el puerto 5433, el `.env` y los sismos del CSN y USGS cargados.

Esta guía explica cómo poner tu base al día con lo que hicimos entre el 6 y el 12 de noviembre, sin borrar lo que ya tienes. Son unos 20 minutos de ejecución, casi todo esperando.

---

## 1. Qué cambió desde la primera entrega

| Cambio | Qué agrega a la base | Documento |
|---|---|---|
| **DPA 2023** (SUBDERE / IDE Chile) | 16 regiones, 56 provincias y 345 comunas oficiales. Cada sismo queda asignado a una comuna, o al mar con su comuna más cercana. | [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md), sección 7 |
| **Magnitudes homogéneas** | La columna `mw_homogenized`: convierte `Ml`, `Mlv`, `mb`, etc. a Mw para comparar sismos entre sí. Es la que se usa para filtrar "Mw ≥ 5". | [MAGNITUDES.md](MAGNITUDES.md) |
| **Censo 2024** (tu parte) | 592 zonas urbanas y 216.341 manzanas con población. Para cada sismo, la zona urbana más cercana; para cada sismo Mw ≥ 5, la población a 25, 50 y 100 km. | [INE_CENSO2024.md](INE_CENSO2024.md) |
| **Tablas de análisis** (12-11) | Las 7 tablas de la entrega 3 (réplicas, emparejamiento CSN–USGS, intensidad). Solo `magnitude_estimate` tiene datos; las demás quedan vacías. | [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md), sección 5.3 |

El esquema pasó de 9 a 21 tablas (14 con datos y 7 de análisis), y `db/queries.sql` pasó de 10 a 15 consultas.

**Sobre tu script del INE:** lo integramos como `scripts/load_ine_manzanas_postgis.ps1`. La idea es la misma (usa el GDAL de QGIS para leer GeoParquet y `ogr2ogr` para cargarlo), pero ahora además pasa los datos de `ine_staging` a tablas del modelo y calcula la cercanía de los sismos. Las correcciones están en [INE_CENSO2024.md](INE_CENSO2024.md), sección 9.

---

## 2. Qué necesitas antes de empezar

- [ ] **Lo que ya tenías:** PostgreSQL 18 con PostGIS en `C:\Program Files\PostgreSQL\18\bin`, QGIS 3.44.13 y el `.env` con tu contraseña. No hay que cambiar nada de eso.
- [ ] **`shp2pgsql.exe`** en esa misma carpeta `bin`. Viene con PostGIS; revísalo con:
  ```powershell
  Test-Path 'C:\Program Files\PostgreSQL\18\bin\shp2pgsql.exe'
  ```
- [ ] **Unos 3 GB libres en disco:** zips (1,1 GB), archivos extraídos (0,5 GB) y crecimiento de la base (0,8 GB).
- [ ] **Los CSV de sismos** de la primera entrega en `data\processed\csn\` y `data\processed\usgs\`. Si los borraste, vuelve a correr los descargadores (paso 4).

---

## 3. Pasos

Todos los comandos se ejecutan en PowerShell, desde la carpeta del repositorio.

### Paso 1. Bajar el código nuevo

El modelo v2 ya está en `main` (pull request [#1](https://github.com/G6B0/Proyecto_Base_de_datos_espaciales/pull/1)). Lo del Hito 2 está en el pull request [#2](https://github.com/G6B0/Proyecto_Base_de_datos_espaciales/pull/2); mientras no esté fusionado, el código está en la rama `feature/hito2-modelo-completo`:

```powershell
git fetch origin
git checkout feature/hito2-modelo-completo
```

Cuando se fusione, basta con:

```powershell
git checkout main
git pull
```

### Paso 2. Iniciar la base y aplicar el esquema nuevo

```powershell
PowerShell -ExecutionPolicy Bypass -File .\scripts\start_local_postgis.ps1
```

Es el mismo script de siempre. Al iniciar aplica `db/schema.sql`, que crea las tablas y columnas nuevas **sin borrar tus sismos**: todo usa `IF NOT EXISTS`. Lo probé sobre una base con el esquema de la primera entrega y quedan las 21 tablas con los sismos intactos. Es normal que aparezcan muchos `NOTICE: ... already exists, skipping`.

### Paso 3. Conseguir los dos zips oficiales

No están en Git porque pesan mucho. Van en estas rutas exactas:

| Archivo | Ruta | Tamaño | Cómo obtenerlo |
|---|---|---|---|
| DPA 2023 | `data\raw\chile_boundaries\dpa_2023.zip` | 297 MB | Pídemelo (lo comparto por Drive) o descárgalo desde [IDE Chile](https://www.ide.cl/), sección División Político Administrativa 2023. |
| Censo 2024 | `data\raw\ine\Cartografia_censo2024_Pais.zip` | 758 MB | El comando de abajo. |

```powershell
New-Item -ItemType Directory -Force data\raw\ine, data\raw\chile_boundaries | Out-Null
curl.exe -L -o data\raw\ine\Cartografia_censo2024_Pais.zip "https://storage.googleapis.com/bktdescargascenso2024/Cartografia/GEOPARQUET/Cartografia_censo2024_Pais.zip"
```

No hace falta descomprimirlos: cada script extrae solo lo que necesita.

### Paso 4. Recargar los sismos para calcular el Mw homogéneo

**No te saltes este paso.** Tus sismos tienen `mw_homogenized` vacío, y sin esa columna el paso 6 no calcula población para ningún sismo.

Si quieres además traer los sismos más nuevos (opcional), corre antes los descargadores:

```powershell
.\scripts\run_csn_catalog_qgis.cmd
.\scripts\run_usgs_earthquakes_qgis.cmd
```

Después, siempre:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\scripts\load_catalogs_postgis.ps1
```

Recarga los CSV sin duplicar eventos, calcula el Mw homogéneo y llena `magnitude_estimate`. Tarda menos de un minuto. Como todavía no hay DPA ni censo, se salta esos dos cálculos.

### Paso 5. Cargar la DPA y asignar comunas

```powershell
PowerShell -ExecutionPolicy Bypass -File .\scripts\load_dpa_postgis.ps1
```

Tarda unos 2 minutos.

### Paso 6. Cargar el Censo 2024 y calcular la cercanía

```powershell
PowerShell -ExecutionPolicy Bypass -File .\scripts\load_ine_manzanas_postgis.ps1
```

Tarda unos 13 minutos:

- **Importación** (~1 min): extrae los dos `.parquet` del zip y los importa a `ine_staging` con `ogr2ogr`.
- **Paso al modelo** (~30 s): `db/load_census.sql` pasa los datos a `urban_area` y `census_block` y borra `ine_staging`.
- **Cercanía y población** (10–12 min): `db/assign_urban_exposure.sql` calcula la zona urbana más cercana a cada sismo y la población cerca de cada sismo Mw ≥ 5. En esta parte la pantalla se queda quieta varios minutos; es normal.

Si termina con `Listo. Cartografia del Censo 2024 cargada...`, salió todo bien.

### Paso 7. Verificar

Copia esto en un archivo `verificar.sql` (o pégalo en pgAdmin o en el administrador de bases de QGIS):

```sql
SELECT * FROM (
              SELECT 1 AS n, 'Regiones' AS control, count(*) AS valor FROM seismic.administrative_area WHERE level = 'region'
    UNION ALL SELECT 2, 'Provincias', count(*) FROM seismic.administrative_area WHERE level = 'province'
    UNION ALL SELECT 3, 'Comunas', count(*) FROM seismic.administrative_area WHERE level = 'commune'
    UNION ALL SELECT 4, 'Zonas urbanas', count(*) FROM seismic.urban_area
    UNION ALL SELECT 5, 'Manzanas', count(*) FROM seismic.census_block
    UNION ALL SELECT 6, 'Sismos', count(*) FROM seismic.earthquake_event
    UNION ALL SELECT 7, 'Sismos con Mw homogeneo', count(mw_homogenized) FROM seismic.earthquake_event
    UNION ALL SELECT 8, 'Sismos con comuna o mar', count(*) FROM seismic.event_administrative_area
    UNION ALL SELECT 9, 'Sismos con zona urbana mas cercana', count(*) FROM seismic.event_urban_area WHERE distance_rank = 1
    UNION ALL SELECT 10, 'Sismos Mw >= 5', count(*) FROM seismic.earthquake_event WHERE mw_homogenized >= 5
    UNION ALL SELECT 11, 'Sismos Mw >= 5 con poblacion', count(*) FROM seismic.event_population_exposure
) t ORDER BY n;
```

Con psql:

```powershell
$env:PGCLIENTENCODING = 'UTF8'
& 'C:\Program Files\PostgreSQL\18\bin\psql.exe' -h 127.0.0.1 -p 5433 -U sismos_app -d sismos_chile -f verificar.sql
```

Qué deberías ver:

| Control | En mi base (datos al 11-11) | Qué revisar en la tuya |
|---|---:|---|
| Regiones / provincias / comunas | 16 / 56 / 345 | Tiene que ser **igual**. |
| Zonas urbanas | 592 | **Igual.** |
| Manzanas | 216.341 | **Igual.** |
| Sismos | 59.534 | Puede variar según la fecha de tus CSV. |
| Sismos con Mw homogéneo | 45.835 (77 %) | Cerca del 77 % de tus sismos. Si es 0, no corriste el paso 4. |
| Sismos con comuna o mar | 59.534 | **Igual a tu número de sismos.** |
| Sismos con zona urbana más cercana | 59.534 | **Igual a tu número de sismos.** |
| Sismos Mw ≥ 5 / con población | 6.403 / 6.403 | **Los dos números iguales entre sí.** |

Si además quieres revisar `magnitude_estimate`, en mi base tiene 104.225 filas: `SELECT count(*) FROM seismic.magnitude_estimate;`. Las otras seis tablas de análisis tienen que estar vacías.

Después puedes correr las 15 consultas:

```powershell
& 'C:\Program Files\PostgreSQL\18\bin\psql.exe' -h 127.0.0.1 -p 5433 -U sismos_app -d sismos_chile -f db\queries.sql
```

Las consultas nuevas son la 11 a la 15 (zona urbana más cercana, población cercana, ciudades con más sismos, comuna versus ciudad y actividad de una comuna en el tiempo). Sus resultados están explicados en [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md), sección 8.

---

## 4. Capas nuevas en QGIS

La forma más rápida es abrir `qgis/sismos_chile_v2.qgs`: ya trae las capas, los estilos y los marcadores. QGIS te pedirá la contraseña de `.env` (el proyecto no la guarda).

Si prefieres armarlo a mano, la conexión es la misma de antes (127.0.0.1, puerto 5433, `sismos_chile`, `sismos_app`). Las capas que sirven ahora:

| Capa | Para qué |
|---|---|
| `seismic.v_event_location` | Sismos con su comuna, provincia y región. Simbolizar por `mw_homogenized`. |
| `seismic.administrative_area` | Límites. Filtrar por `level` = `region`, `province` o `commune`. |
| `seismic.urban_area` | Ciudades y pueblos, con `population`. |
| `seismic.census_block` | Manzanas (216 mil polígonos; conviene verlas con zoom). |

Todo mapa con la DPA debe llevar la leyenda: *"Autorizada su circulación por Resolución Nº 87 del 2023 de la Dirección Nacional de Fronteras y Límites del Estado"*.

---

## 5. Después de la primera vez

La DPA y el censo no se vuelven a cargar: son datos estáticos. Para actualizar sismos basta lo mismo de siempre:

```powershell
.\scripts\run_csn_catalog_qgis.cmd
PowerShell -ExecutionPolicy Bypass -File .\scripts\load_catalogs_postgis.ps1
```

`load_catalogs_postgis.ps1` ahora hace solo, en este orden:

1. Calcula el Mw homogéneo.
2. Llena `magnitude_estimate`.
3. Asigna la comuna.
4. Calcula la zona urbana y la población cercanas, **solo de los sismos nuevos**. Tarda segundos.

Antes de una entrega conviene repetir el paso 6 completo, porque el modo rápido no detecta sismos antiguos a los que la fuente les corrigió la ubicación.

---

## 6. Si algo falla

| Mensaje | Qué hacer |
|---|---|
| `La base no esta activa` | Corre el paso 2. |
| `No se encontro el zip de la DPA` / `...del INE` | Revisa el nombre y la ruta exacta del paso 3. |
| `No se encontro ...shp2pgsql.exe` | Falta PostGIS en esa instalación de PostgreSQL. Instálalo con Stack Builder. |
| `No encontre QGIS` | Agrega `-QgisRoot "C:\Program Files\QGIS 3.44.13"` al comando del paso 6. |
| `Esta instalacion de GDAL no soporta Parquet` | Se necesita QGIS 3.44 o superior. |
| `No hay comunas cargadas` o `codigos de comuna del INE no existen en la DPA` | Corre el paso 5 antes del 6. |
| `sismos Mw >= 5 quedaron sin poblacion calculada` | Vuelve a correr el paso 6. Si se repite, avísame con el mensaje completo. |
| PostgreSQL en otra carpeta | El script del censo acepta `-PgBin "ruta\a\bin"`. En los demás scripts hay que cambiar la ruta escrita al inicio, igual que en la primera entrega. |

Cada paso SQL corre en una transacción: si falla, ese paso se revierte entero. Todos los scripts se pueden volver a correr sin duplicar nada.

Si la base quedó en un estado raro y prefieres partir de cero, detén el clúster con `stop_local_postgis.ps1`, borra la carpeta `%LOCALAPPDATA%\SismosChilePostgres` y corre los pasos 2 a 6. Eso borra **solo** la base local del proyecto. Desde cero, todo toma unos 20 minutos.

---

## 7. Para leer después

- [README.md](../README.md): instalación completa desde cero.
- [MODELO_LOGICO_v2.md](MODELO_LOGICO_v2.md): modelo lógico con las 21 tablas, decisiones y calendario hasta la entrega final. El diagrama está en `docs/modelo_logico.drawio` (se abre en [app.diagrams.net](https://app.diagrams.net/)).
- [INE_CENSO2024.md](INE_CENSO2024.md): todo lo del censo (tu parte): datos, método de distancia, resultados y limitaciones.
- [MAGNITUDES.md](MAGNITUDES.md): por qué hay que homogeneizar magnitudes y cómo se validó la fórmula.
