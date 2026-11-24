# Forma y decaimiento de las secuencias: elipses y ley de Omori

**Fecha:** 2026-11-24 · **Vistas:** `seismic.v_sequence_ellipse`, `seismic.v_sequence_omori_bins`, `seismic.v_sequence_omori` (en `db/schema.sql`) · **Consultas:** 28 y 29 de `db/queries.sql` · **Interfaz:** modo Anatomía (`GET /api/sequences/{id}`)

## Para qué

Completar el paso 4 del plan con dos análisis de las secuencias que entrega el declustering (paso 3):

1. **Elipse de desviación estándar** de las réplicas: su orientación y alargamiento muestran por dónde se extendió la ruptura, y dejan ver la limitación de la ventana **circular** de Gardner-Knopoff.
2. **Ley de Omori:** la tasa de réplicas decae como n(t) ∝ t^−p. El exponente p resume qué tan rápido se "apaga" la secuencia.

Las dos se calculan **en SQL, para todas las secuencias de todas las ejecuciones** (2.051 elipses y 476 ajustes de Omori), no solo para el Maule.

## Método

**Elipse** (secuencias con 5 réplicas o más):

1. Coordenadas de las réplicas en km con la latitud media de la secuencia: x = lon · 111,32 · cos(lat), y = lat · 110,57.
2. Matriz de covarianza 2×2 con los agregados `var_samp` y `covar_samp` de PostgreSQL.
3. Valores propios en forma cerrada: λ = (sxx + syy)/2 ± √(((sxx − syy)/2)² + sxy²). Ejes = 2√λ (elipse de 1 σ, informada por sus diámetros). Ángulo del eje mayor = ½ · atan2(2sxy, sxx − syy), convertido a azimut desde el norte.
4. El polígono se arma con 64 puntos (`ST_MakePolygon`), así la elipse se puede ver en QGIS y en la interfaz.

**Omori** (secuencias con 20 réplicas o más):

1. Tiempo de cada réplica desde el principal, en días, desde 0,01 días (14 minutos): antes el catálogo pierde réplicas tapadas por el terremoto.
2. 20 intervalos logarítmicos hasta la última réplica (`width_bucket` sobre log t); tasa = réplicas / ancho del intervalo.
3. p = −pendiente de la recta log(tasa) vs log(t) desde 0,05 días (`regr_slope`), con 5 intervalos o más. Es la forma simple de la ley (sin el tiempo c de la ley de Omori modificada).

## Resultados (ejecución de referencia: Gardner-Knopoff, sin duplicados, Mw ≥ 4)

| Terremoto | Réplicas | Elipse (km) | Orientación | p | R² |
|---|---:|---|---|---:|---:|
| Maule 2010, Mw 8,8 | 942 | 117 × 71 | N18°E | 0,84 | 0,98 |
| Illapel 2015, Mw 8,3 | 822 | 102 × 49 | N17°E | 0,94 | 0,99 |
| Iquique 2014, Mw 8,1 | 463 | 61 × 53 | N11°O | 0,96 | 0,99 |
| Valparaíso 1985, Mw 8,0 | 306 | 91 × 47 | N16°E | 0,77 | 0,96 |
| Antofagasta 1995, Mw 8,0 | 141 | 78 × 59 | N5°E | 0,99 | 0,94 |

Con ST-DBSCAN, la secuencia del Maule tiene 1.975 réplicas y una elipse de **330 × 91 km**, también a N18°E.

En los 18 terremotos Mw ≥ 7,5 desde 1960 con ajuste, p va de 0,76 a 1,06 (mediana 0,94). En todas las secuencias con ajuste, la mediana es 0,72 (consulta 29).

## Lectura

1. **Las réplicas dibujan la ruptura de subducción.** Los grandes terremotos interplaca tienen el eje mayor casi paralelo a la costa (entre N11°O y N18°E): la ruptura se extiende a lo largo de la fosa, no hacia el interior. El alargamiento es claro en el Maule, Illapel y Valparaíso (eje menor de 0,5 a 0,6 veces el mayor); Iquique 2014 sale casi circular (61 × 53 km), así que su orientación pesa poco. Hay excepciones: la réplica Mw 7,7 de Iquique del 03-04-2014 quedó como secuencia propia y sale casi este-oeste (85°).
2. **La ventana circular recorta la ruptura.** Con Gardner-Knopoff, el eje mayor del Maule mide 117 km; con ST-DBSCAN, que encadena réplicas vecinas sin un círculo fijo, mide 330 km, más cerca de los ~500 km de la ruptura real. La ventana de 118 km de radio deja fuera las réplicas de los extremos norte y sur. Es la misma conclusión del test de Knox, vista desde la geometría: cada método se equivoca hacia un lado.
3. **p algo menor que el valor típico.** En la literatura p suele estar entre 0,9 y 1,5. Nuestros grandes terremotos dan 0,76–1,06 y el conjunto de secuencias da 0,72. Hay dos causas que aplanan la curva: el catálogo pierde réplicas en las primeras horas (incompletitud tras un gran sismo) y las ventanas largas de Gardner-Knopoff (hasta 2,9 años) suman sismicidad de fondo al final. Las secuencias chicas, con pocas réplicas y R² medio 0,78, son menos confiables; por eso el informe debería usar los grandes terremotos.

## Conclusión para el informe

La elipse y Omori confirman que las secuencias que entrega el declustering son físicamente coherentes: alineadas con la fosa y con un decaimiento de tipo Omori (R² ≥ 0,94 en los grandes terremotos). También dejan a la vista el costo de la ventana circular de Gardner-Knopoff: recorta las rupturas largas, como el Maule. En la interfaz, el modo Anatomía muestra todo esto para cualquier secuencia: réplicas reproducibles en el tiempo, ventana, elipse y curva de Omori.
