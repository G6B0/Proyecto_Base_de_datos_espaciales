"""Renderiza el mapa base del diseño de la interfaz con los datos reales.

Imagen de 1920 x 1080 en el estilo del sistema de diseño
(.superdesign/design-system.md): océano casi negro, Chile al centro, los
países vecinos (mapa mundial que trae QGIS) y los sismos únicos de
seismic.v_event_location_unique coloreados y escalados por Mw homogéneo.

Sirve de fondo para los diseños de Superdesign, para que muestren lo que
verá la aplicación final. Se ejecuta con el Python de QGIS:

    "C:\\Program Files\\QGIS 3.44.13\\bin\\python-qgis-ltr.bat" scripts\\render_ui_basemap.py salida.png

Imprime la posición en píxeles de los grandes terremotos (para ubicar
anillos de selección en el diseño). La contraseña se lee de .env y no se
imprime.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import patheffects  # noqa: E402
import numpy as np  # noqa: E402
import psycopg2  # noqa: E402
from matplotlib.collections import PatchCollection  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402
from matplotlib.patches import Polygon  # noqa: E402
from osgeo import ogr  # noqa: E402

ogr.UseExceptions()

ROOT = Path(__file__).resolve().parents[1]
WORLD = Path(r"C:\Program Files\QGIS 3.44.13\apps\qgis-ltr\resources\data\world_map.gpkg")

WIDTH, HEIGHT = 1920, 1080
LAT_TOP, LAT_BOTTOM = -14.5, -57.5
CENTER_LON = -71.0
COS = math.cos(math.radians(-36.0))  # proyección equirectangular centrada en Chile
PX_PER_DEG_Y = HEIGHT / (LAT_TOP - LAT_BOTTOM)
PX_PER_DEG_X = PX_PER_DEG_Y * COS
LON_LEFT = CENTER_LON - (WIDTH / 2) / PX_PER_DEG_X
LON_RIGHT = CENTER_LON + (WIDTH / 2) / PX_PER_DEG_X

OCEAN = "#030405"
NEIGHBOUR_LAND = "#0b0d10"
CHILE_LAND = "#111419"

# Rampa de magnitud del sistema de diseño (Mw -> color).
MW_STOPS = [(3.0, "#3b1c4a"), (4.0, "#8a2be2"), (5.0, "#c2185b"), (5.6, "#f4511e"),
            (6.5, "#ffa726"), (7.5, "#ffe082"), (8.5, "#fffde7"), (9.6, "#ffffff")]
MW_MIN, MW_MAX = MW_STOPS[0][0], MW_STOPS[-1][0]
CMAP = LinearSegmentedColormap.from_list(
    "mw", [((mw - MW_MIN) / (MW_MAX - MW_MIN), color) for mw, color in MW_STOPS]
)

CITIES = [("Arica", -70.31, -18.48), ("Antofagasta", -70.40, -23.65), ("Calama", -68.93, -22.46),
          ("La Serena", -71.25, -29.90), ("Valparaíso", -71.62, -33.05), ("Santiago", -70.65, -33.45),
          ("Concepción", -73.05, -36.83), ("Puerto Montt", -72.94, -41.47),
          ("Punta Arenas", -70.91, -53.16)]

FAMOUS = [("valdivia_1960", "1960-05-22", 9.4), ("maule_2010", "2010-02-27", 8.7),
          ("illapel_2015", "2015-09-16", 8.2), ("iquique_2014", "2014-04-01", 8.0),
          ("valparaiso_1985", "1985-03-03", 7.9)]


def to_px(lon, lat):
    x = (np.asarray(lon) - LON_LEFT) * PX_PER_DEG_X
    y = (LAT_TOP - np.asarray(lat)) * PX_PER_DEG_Y
    return x, y


def env(name: str) -> str:
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip()
    raise KeyError(name)


def polygons_from_geojson(geometry: dict):
    rings = []
    polys = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
    for poly in polys:
        for ring in poly[:1]:  # solo el anillo exterior; los huecos no se notan a esta escala
            coords = np.array(ring)
            x, y = to_px(coords[:, 0], coords[:, 1])
            rings.append(np.column_stack([x, y]))
    return rings


def main(output: Path) -> None:
    connection = psycopg2.connect(
        host="127.0.0.1", port=int(env("POSTGRES_PORT")), dbname=env("POSTGRES_DB"),
        user=env("POSTGRES_USER"), password=env("POSTGRES_PASSWORD"),
    )
    cursor = connection.cursor()
    cursor.execute("""
        SELECT name, ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom, 0.01))
        FROM seismic.administrative_area WHERE level = 'region'
    """)
    regions = [(name, json.loads(geojson)) for name, geojson in cursor.fetchall()]
    cursor.execute("""
        SELECT ST_X(geom), ST_Y(geom), coalesce(mw_homogenized, 3.0)
        FROM seismic.v_event_location_unique
        WHERE ST_Y(geom) BETWEEN %s AND %s AND ST_X(geom) BETWEEN %s AND %s
        ORDER BY coalesce(mw_homogenized, 3.0)
    """, (LAT_BOTTOM, LAT_TOP, LON_LEFT, LON_RIGHT))
    events = np.array(cursor.fetchall(), dtype=float)
    famous_px = {}
    for key, day, min_mw in FAMOUS:
        cursor.execute("""
            SELECT ST_X(geom), ST_Y(geom), mw_homogenized FROM seismic.v_event_location_unique
            WHERE occurred_at::date = %s AND mw_homogenized >= %s
            ORDER BY mw_homogenized DESC LIMIT 1
        """, (day, min_mw))
        row = cursor.fetchone()
        if row:
            x, y = to_px(row[0], row[1])
            famous_px[key] = {"x": round(float(x)), "y": round(float(y)), "mw": float(row[2])}
    connection.close()

    figure = plt.figure(figsize=(WIDTH / 100, HEIGHT / 100), dpi=100)
    axes = figure.add_axes([0, 0, 1, 1])
    axes.set_xlim(0, WIDTH)
    axes.set_ylim(HEIGHT, 0)
    axes.set_facecolor(OCEAN)
    figure.patch.set_facecolor(OCEAN)
    axes.axis("off")

    # Países vecinos (mapa mundial de QGIS).
    source = ogr.Open(str(WORLD))
    layer = source.GetLayer(0)
    layer.SetSpatialFilterRect(LON_LEFT - 5, LAT_BOTTOM - 5, LON_RIGHT + 5, LAT_TOP + 5)
    neighbours = []
    for feature in layer:
        geometry = json.loads(feature.GetGeometryRef().ExportToJson())
        neighbours.extend(Polygon(r, closed=True) for r in polygons_from_geojson(geometry))
    axes.add_collection(PatchCollection(neighbours, facecolor=NEIGHBOUR_LAND,
                                        edgecolor=(1, 1, 1, 0.08), linewidth=0.6))

    # Chile por regiones.
    chile = []
    for _, geometry in regions:
        chile.extend(Polygon(r, closed=True) for r in polygons_from_geojson(geometry))
    axes.add_collection(PatchCollection(chile, facecolor=CHILE_LAND,
                                        edgecolor=(1, 1, 1, 0.18), linewidth=0.6))

    # Sismos: halo para los grandes, punto para todos.
    x, y = to_px(events[:, 0], events[:, 1])
    mw = np.clip(events[:, 2], MW_MIN, MW_MAX)
    colors = CMAP((mw - MW_MIN) / (MW_MAX - MW_MIN))
    radius = 0.6 + (np.clip(mw, 3, 9.5) - 3) ** 2 * 0.18   # píxeles: Mw 5 = 1,3; Mw 8 = 5,1
    big = mw >= 7.5
    axes.scatter(x[big], y[big], s=(radius[big] * 4.5) ** 2, c=colors[big], alpha=0.08,
                 linewidths=0, zorder=3)
    axes.scatter(x[big], y[big], s=(radius[big] * 2.2) ** 2, c=colors[big], alpha=0.16,
                 linewidths=0, zorder=3)
    alpha = np.where(mw < 4, 0.25, np.where(mw < 5, 0.45, np.where(mw < 6, 0.7, 0.92)))
    colors[:, 3] = alpha
    axes.scatter(x, y, s=(radius * 1.15) ** 2, c=colors, linewidths=0, zorder=4)

    # Ciudades.
    for name, lon, lat in CITIES:
        cx, cy = to_px(lon, lat)
        axes.scatter([cx], [cy], s=6, c="white", alpha=0.55, linewidths=0, zorder=5)
        label = axes.text(cx + 7, cy + 3, name, color=(1, 1, 1, 0.62), fontsize=9,
                          family="sans-serif", zorder=6)
        label.set_path_effects([patheffects.withStroke(linewidth=3, foreground=OCEAN)])

    output.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output, dpi=100, facecolor=OCEAN)
    print(json.dumps({"output": str(output), "events": int(len(events)),
                      "famous_px": famous_px,
                      "chile_x_range_px": [round(float(v)) for v in to_px([-76, -66], [-30, -30])[0]]},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".superdesign" / "tmp" / "basemap.png")
