# Datos de sismos

## Fuente inicial

Los eventos se descargan desde el servicio FDSN Event de USGS ComCat:

`https://earthquake.usgs.gov/fdsnws/event/1/`

El rectangulo predeterminado (`-76, -56, -66, -17`) cubre Chile continental,
pero tambien contiene oceano y sectores de paises vecinos. Esa seleccion es
intencional: permite conservar sismos costeros relevantes y posteriormente
clasificarlos mediante consultas espaciales.

La segunda fuente es el Centro Sismologico Nacional. El proceso combina su CSV
historico, que actualmente termina el 2025-06-23, con las paginas diarias
oficiales desde el 2025-06-24. Los insumos originales se conservan bajo
`data/raw/csn`.

La carga verificada el 2026-09-22 contiene 57.488 eventos del CSN y llega hasta
el 2026-09-22 14:40:50 UTC. Las paginas recientes pueden ser revisadas por la
fuente, por lo que el descargador actualiza nuevamente los ultimos siete dias.

## Generar una muestra

```powershell
scripts\run_usgs_earthquakes_qgis.cmd --start 2026-01-01 --end 2026-08-30
```

Descargar y normalizar el catalogo CSN completo:

```powershell
scripts\run_csn_catalog_qgis.cmd
```

En la primera ejecucion se descargan las paginas diarias desde el 2025-06-24.
Las ejecuciones siguientes reutilizan la cache. Se puede especificar un rango:

```powershell
scripts\run_csn_catalog_qgis.cmd --recent-start 2025-06-24 --recent-end 2026-09-22
```

Parametros principales de USGS:

| Parametro | Valor inicial | Descripcion |
| --- | --- | --- |
| `--start` | hace 30 dias | Inicio UTC, fecha o timestamp ISO 8601 |
| `--end` | instante actual | Fin UTC, fecha o timestamp ISO 8601 |
| `--min-magnitude` | `2.5` | Magnitud minima solicitada |
| `--bbox` | `-76 -56 -66 -17` | Oeste, sur, este y norte |
| `--review-status` | `all` | `all`, `automatic` o `reviewed` |

Parametros principales del CSN:

| Parametro | Valor inicial | Descripcion |
| --- | --- | --- |
| `--recent-start` | `2025-06-24` | Primer dia del catalogo diario |
| `--recent-end` | dia UTC actual | Ultimo dia que se consultara |
| `--refresh-days` | `7` | Dias finales que se vuelven a descargar |
| `--request-delay` | `0.2` | Pausa entre solicitudes nuevas |

## Productos

| Directorio | Producto | Funcion |
| --- | --- | --- |
| `data/raw/usgs` | `*_raw.geojson` | Respuesta original para trazabilidad |
| `data/processed/usgs` | `*.geojson` | Puntos 2D para QGIS/PostGIS |
| `data/processed/usgs` | `*.csv` | Tabla plana para carga o revision |
| `data/processed/usgs` | `*_metadata.json` | Consulta, fecha de descarga y validaciones |
| `data/raw/csn` | `*_raw.csv` | Catalogo CSN original para trazabilidad |
| `data/raw/csn/daily` | `AAAA/MM/AAAAMMDD.html` | Paginas diarias oficiales y cache local |
| `data/processed/csn` | `*.geojson`, `*.csv` y metadatos | Catalogo CSN combinado |

## Diccionario principal

| Campo | Descripcion |
| --- | --- |
| `source_event_id` | Identificador estable dentro de la fuente; los eventos diarios CSN usan su numero de informe |
| `source_catalog_id` | Identificador original, cuando la fuente lo entrega |
| `occurred_at_utc` | Instante de ocurrencia en UTC |
| `updated_at_utc` | Ultima revision conocida en la fuente |
| `magnitude` | Valor de magnitud publicado |
| `magnitude_type` | Escala o metodo de magnitud; no debe descartarse |
| `reported_magnitude` | Magnitud original del CSN antes de la conversion |
| `reported_magnitude_type` | Tipo de la magnitud original del CSN |
| `depth_km` | Profundidad hipocentral en kilometros |
| `place` | Referencia geografica publicada, cuando esta disponible |
| `source_url` | Enlace al informe original del evento |
| `review_status` | Estado `automatic` o `reviewed` |
| `horizontal_error_km` | Incertidumbre horizontal, cuando esta disponible |
| `depth_error_km` | Incertidumbre de profundidad, cuando esta disponible |
| `geometry` | Epicentro Point en longitud/latitud WGS 84 |

## Abrir en QGIS

1. Abrir **Capa > Anadir capa > Anadir capa vectorial**.
2. Seleccionar el GeoJSON de `data/processed/usgs`.
3. Usar `magnitude` para simbolos graduados y `depth_km` para el color.
4. Activar la dimension temporal con `occurred_at_utc` como instante unico.
5. Anadir la capa oficial de regiones para comprobar la relacion espacial.

## Calidad y actualizaciones

- Los eventos recientes pueden cambiar de magnitud, profundidad o posicion.
- Una actualizacion debe hacer `UPSERT` por `(source_code, source_event_id)`.
- Las paginas diarias CSN quedan en cache y los ultimos siete dias se refrescan
  para recoger revisiones.
- La geometria procesada es 2D; la profundidad se conserva como atributo.
- Las magnitudes solo son comparables si se considera tambien
  `magnitude_type`.
- La cobertura de sismos pequenos varia con la red instrumental y el periodo.
- La muestra USGS de agosto de 2026 devolvio magnitudes desde 4,0 aunque el
  filtro solicitado era 2,5; una red global no reemplaza el detalle de la red
  local para eventos pequenos.
- El componente historico CSN contiene 293 eventos sin profundidad y 15 con profundidad
  negativa. Se conservan como datos de origen y deben tratarse explicitamente
  en los analisis que utilicen profundidad.
