"""Renderiza con datos reales los fondos y gráficos de los cuatro modos de la interfaz.

Complementa scripts/render_ui_basemap.py (modo Explorar). Genera, en
.superdesign/tmp/modes/ (o la carpeta indicada):

  replay_1960.png        Replay detenido en mayo de 1960 (Valdivia).
  placa3d.png            Vista 3D de los sismos según su profundidad.
  placa_corte.png        Corte oeste-este de la placa entre 20° y 24° S.
  maule.png              Anatomía del Maule 2010: réplicas, elipse e intensidad ShakeMap.
  maule_omori.png        Curva de Omori de las réplicas del Maule.
  calama.png             Mi comuna: Calama, su ciudad y sus sismos por profundidad.

e imprime en JSON las cifras para los paneles (todas salen de la base).
Requiere el ShakeMap del Maule en data/raw/usgs_shakemap/<id>/mi.shp.

    "C:\\Program Files\\QGIS 3.44.13\\bin\\python-qgis-ltr.bat" scripts\\render_ui_modes.py [carpeta]
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import psycopg2  # noqa: E402
from matplotlib import patheffects  # noqa: E402
from matplotlib.collections import PatchCollection  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402
from matplotlib.patches import Ellipse, Polygon  # noqa: E402
from matplotlib.path import Path as MplPath  # noqa: E402
from osgeo import ogr  # noqa: E402

ogr.UseExceptions()

ROOT = Path(__file__).resolve().parents[1]
WORLD = Path(r"C:\Program Files\QGIS 3.44.13\apps\qgis-ltr\resources\data\world_map.gpkg")
MAULE_ID = "official20100227063411530_30"
MAULE_SHAKEMAP = ROOT / "data" / "raw" / "usgs_shakemap" / MAULE_ID / "mi.shp"

W, H = 1920, 1080
OCEAN, NEIGHBOUR, CHILE = "#030405", "#0b0d10", "#111419"
FG3 = (1, 1, 1, 0.45)

MW_STOPS = [(3.0, "#3b1c4a"), (4.0, "#8a2be2"), (5.0, "#c2185b"), (5.6, "#f4511e"),
            (6.5, "#ffa726"), (7.5, "#ffe082"), (8.5, "#fffde7"), (9.6, "#ffffff")]
MW_CMAP = LinearSegmentedColormap.from_list(
    "mw", [((m - 3.0) / 6.6, c) for m, c in MW_STOPS])
DEPTH_STOPS = [(0, "#7dd3fc"), (70, "#38bdf8"), (150, "#6366f1"), (300, "#a855f7"), (700, "#c084fc")]
DEPTH_CMAP = LinearSegmentedColormap.from_list(
    "depth", [(d / 700, c) for d, c in DEPTH_STOPS])
MMI_COLORS = {1: "#ffffff", 2: "#bfccff", 3: "#bfccff", 4: "#a0e6ff", 5: "#80ffff", 6: "#7aff93",
              7: "#ffff00", 8: "#ffc800", 9: "#ff9100", 10: "#ff0000"}
ROMAN = {4: "IV", 5: "V", 6: "VI", 7: "VII", 8: "VIII", 9: "IX"}


def env(name: str) -> str:
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip()
    raise KeyError(name)


def connect():
    return psycopg2.connect(host="127.0.0.1", port=int(env("POSTGRES_PORT")), dbname=env("POSTGRES_DB"),
                            user=env("POSTGRES_USER"), password=env("POSTGRES_PASSWORD"))


class View:
    """Proyección equirectangular de un rectángulo de 1920 x 1080 píxeles."""

    def __init__(self, lat_top: float, lat_bottom: float, center_lon: float):
        self.lat_top, self.lat_bottom = lat_top, lat_bottom
        self.ppy = H / (lat_top - lat_bottom)
        self.ppx = self.ppy * math.cos(math.radians((lat_top + lat_bottom) / 2))
        self.lon_left = center_lon - (W / 2) / self.ppx
        self.lon_right = center_lon + (W / 2) / self.ppx

    def px(self, lon, lat):
        return (np.asarray(lon) - self.lon_left) * self.ppx, (self.lat_top - np.asarray(lat)) * self.ppy

    def rings(self, geometry: dict):
        polys = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        out = []
        for poly in polys:
            coords = np.array(poly[0])
            x, y = self.px(coords[:, 0], coords[:, 1])
            out.append(np.column_stack([x, y]))
        return out


def new_figure():
    fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(H, 0)
    ax.set_facecolor(OCEAN)
    fig.patch.set_facecolor(OCEAN)
    ax.axis("off")
    return fig, ax


def draw_land(ax, view: View, cursor, region_tolerance=0.01, communes=False):
    source = ogr.Open(str(WORLD))
    layer = source.GetLayer(0)
    layer.SetSpatialFilterRect(view.lon_left - 5, view.lat_bottom - 5, view.lon_right + 5, view.lat_top + 5)
    patches = []
    for feature in layer:
        patches.extend(Polygon(r, closed=True)
                       for r in view.rings(json.loads(feature.GetGeometryRef().ExportToJson())))
    ax.add_collection(PatchCollection(patches, facecolor=NEIGHBOUR, edgecolor=(1, 1, 1, 0.08), linewidth=0.6))
    level = "commune" if communes else "region"
    cursor.execute("""
        SELECT ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom, %s)) FROM seismic.administrative_area
        WHERE level = %s AND geom && ST_MakeEnvelope(%s, %s, %s, %s, 4326)
    """, (region_tolerance, level, view.lon_left, view.lat_bottom, view.lon_right, view.lat_top))
    patches = []
    for (geojson,) in cursor.fetchall():
        patches.extend(Polygon(r, closed=True) for r in view.rings(json.loads(geojson)))
    ax.add_collection(PatchCollection(patches, facecolor=CHILE,
                                      edgecolor=(1, 1, 1, 0.10 if communes else 0.18), linewidth=0.6))


def label(ax, x, y, text, size=9, alpha=0.62, dot=True):
    if dot:
        ax.scatter([x], [y], s=6, c="white", alpha=0.6, linewidths=0, zorder=8)
    t = ax.text(x + 7, y + 3, text, color=(1, 1, 1, alpha), fontsize=size, family="sans-serif", zorder=8)
    t.set_path_effects([patheffects.withStroke(linewidth=3, foreground=OCEAN)])


def mw_radius(mw, scale=1.0):
    return (0.6 + (np.clip(mw, 3, 9.5) - 3) ** 2 * 0.18) * scale


def save(fig, path: Path, transparent=False):
    fig.savefig(path, dpi=100, facecolor="none" if transparent else OCEAN, transparent=transparent)
    plt.close(fig)


# ---------------------------------------------------------------------------
def render_replay(cursor, out: Path) -> dict:
    view = View(-14.5, -57.5, -71.0)
    fig, ax = new_figure()
    draw_land(ax, view, cursor)
    cursor.execute("""
        SELECT ST_X(geom), ST_Y(geom), coalesce(mw_homogenized, 3.0),
               extract(epoch FROM occurred_at) / 86400 / 365.25 + 1970
        FROM seismic.v_event_location_unique
        WHERE occurred_at >= '1906-01-01' AND occurred_at < '1960-06-01'
        ORDER BY coalesce(mw_homogenized, 3.0)
    """)
    ev = np.array(cursor.fetchall(), dtype=float)
    x, y = view.px(ev[:, 0], ev[:, 1])
    mw, year = ev[:, 2], ev[:, 3]
    colors = MW_CMAP((np.clip(mw, 3, 9.6) - 3) / 6.6)
    recent = year >= 1960.0
    colors[:, 3] = np.where(recent, 0.95, 0.12 + 0.38 * (year - 1906) / 54)
    ax.scatter(x, y, s=(mw_radius(mw) * np.where(recent, 1.6, 1.0)) ** 2, c=colors, linewidths=0, zorder=4)
    cursor.execute("""
        SELECT ST_X(geom), ST_Y(geom), mw_homogenized FROM seismic.v_event_location_unique
        WHERE occurred_at::date = '1960-05-22' ORDER BY mw_homogenized DESC NULLS LAST LIMIT 1
    """)
    vlon, vlat, vmw = cursor.fetchone()
    vx, vy = view.px(vlon, vlat)
    for radius, alpha in ((22, 0.55), (60, 0.30), (110, 0.16), (170, 0.07)):
        ax.add_patch(plt.Circle((vx, vy), radius, fill=False, edgecolor="#fffde7", linewidth=1.4,
                                alpha=alpha, zorder=6))
    ax.scatter([vx], [vy], s=420, c="#fffde7", alpha=0.25, linewidths=0, zorder=5)
    ax.scatter([vx], [vy], s=70, c="#ffffff", linewidths=0, zorder=7)
    for name, lon, lat in [("Arica", -70.31, -18.48), ("Antofagasta", -70.40, -23.65),
                           ("Valparaíso", -71.62, -33.05), ("Concepción", -73.05, -36.83),
                           ("Valdivia", -73.24, -39.81), ("Puerto Montt", -72.94, -41.47)]:
        cx, cy = view.px(lon, lat)
        label(ax, cx, cy, name)
    save(fig, out / "replay_1960.png")
    return {"eventos_hasta_mayo_1960": int(len(ev)), "eventos_1960": int(recent.sum()),
            "valdivia": {"x": round(float(vx)), "y": round(float(vy)), "mw": float(vmw)}}


# ---------------------------------------------------------------------------
def render_plate(cursor, out: Path, elev=18.0, azim=-200.0, rect=(-0.30, -0.45, 1.6, 1.9),
                 name="placa3d.png", section=True) -> dict:
    cursor.execute("""
        SELECT ST_X(geom), ST_Y(geom), depth_km, coalesce(mw_homogenized, 3.0)
        FROM seismic.v_event_location_unique
        WHERE depth_km IS NOT NULL AND depth_km > 0
          AND ST_Y(geom) BETWEEN -45 AND -17 AND ST_X(geom) BETWEEN -76.5 AND -63.5
          AND occurred_at >= '1960-01-01'
        ORDER BY depth_km
    """)
    ev = np.array(cursor.fetchall(), dtype=float)
    lon, lat, depth, mw = ev.T
    fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
    fig.patch.set_facecolor(OCEAN)
    ax = fig.add_axes(list(rect), projection="3d")
    ax.set_facecolor(OCEAN)
    ax.set_box_aspect((1.1, 3.1, 1.25))
    colors = DEPTH_CMAP(np.clip(depth, 0, 700) / 700)
    colors[:, 3] = np.where(mw < 4, 0.35, 0.8)
    ax.scatter(lon, lat, -depth, s=(mw_radius(mw, 1.5)) ** 2, c=colors, linewidths=0, depthshade=False)
    cursor.execute("""
        SELECT ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom, 0.05)) FROM seismic.administrative_area
        WHERE level = 'region' AND geom && ST_MakeEnvelope(-76.5, -45, -63.5, -17, 4326)
    """)
    for (geojson,) in cursor.fetchall():
        geometry = json.loads(geojson)
        polys = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        for poly in polys:
            ring = np.array(poly[0])
            keep = (ring[:, 1] >= -45) & (ring[:, 1] <= -17)
            if keep.sum() > 2:
                ax.plot(ring[keep, 0], ring[keep, 1], 0, color=(1, 1, 1, 0.35), linewidth=0.6)
    for d in (100, 200, 300, 400):
        ax.plot([-63.5, -63.5], [-45, -17], [-d, -d], color=(1, 1, 1, 0.12), linewidth=0.8)
        ax.text(-63.3, -45, -d, f"{d} km", color=(1, 1, 1, 0.5), fontsize=10, family="monospace")
    ax.set_xlim(-76.5, -63.5)
    ax.set_ylim(-45, -17)
    ax.set_zlim(-450, 0)
    ax.view_init(elev=elev, azim=azim)
    ax.set_axis_off()
    save(fig, out / name)
    if not section:
        return {}

    # Corte oeste-este entre 20° y 24° S.
    sel = (lat <= -20) & (lat >= -24)
    km = (lon[sel] + 72.0) * 111.32 * math.cos(math.radians(22))
    fig, cax = plt.subplots(figsize=(9, 4.4), dpi=100)
    fig.patch.set_alpha(0)
    cax.set_facecolor("none")
    c = DEPTH_CMAP(np.clip(depth[sel], 0, 700) / 700)
    c[:, 3] = 0.75
    cax.scatter(km, depth[sel], s=(mw_radius(mw[sel], 0.9)) ** 2, c=c, linewidths=0)
    cax.set_xlim(-20, 620)
    cax.set_ylim(480, -40)
    for spine in cax.spines.values():
        spine.set_visible(False)
    cax.tick_params(colors=(1, 1, 1, 0.45), labelsize=9, length=0)
    cax.grid(color=(1, 1, 1, 0.06), linewidth=0.6)
    cax.set_xlabel("Distancia desde la fosa (km)", color=(1, 1, 1, 0.45), fontsize=9)
    cax.set_ylabel("Profundidad (km)", color=(1, 1, 1, 0.45), fontsize=9)
    for name, place_lon in (("Fosa", -72.0), ("Costa", -70.3), ("Calama", -68.93), ("Andes", -67.5)):
        xk = (place_lon + 72.0) * 111.32 * math.cos(math.radians(22))
        cax.axvline(xk, color=(1, 1, 1, 0.12), linewidth=0.8, ymax=0.97)
        cax.text(xk + 4, -18, name, color=(1, 1, 1, 0.7), fontsize=9)
    fig.tight_layout()
    save(fig, out / "placa_corte.png", transparent=True)
    return {"eventos_3d": int(len(ev)), "eventos_corte_20_24S": int(sel.sum()),
            "profundidad_max_km": float(depth.max()),
            "eventos_mas_de_300km": int((depth > 300).sum())}


# ---------------------------------------------------------------------------
def render_maule(cursor, out: Path) -> dict:
    view = View(-31.6, -41.0, -72.85)
    fig, ax = new_figure()
    draw_land(ax, view, cursor)

    cursor.execute("""
        SELECT earthquake_event_id, occurred_at, ST_X(geom), ST_Y(geom), mw_homogenized, depth_km
        FROM seismic.v_event_location_unique
        WHERE occurred_at::date = '2010-02-27' ORDER BY mw_homogenized DESC NULLS LAST LIMIT 1
    """)
    main_id, main_t, mlon, mlat, mmw, mdepth = cursor.fetchone()
    radius_km = 10 ** (0.1238 * float(mmw) + 0.983)
    days = 10 ** (0.032 * float(mmw) + 2.7389)
    cursor.execute("""
        SELECT ST_X(e.geom), ST_Y(e.geom), coalesce(e.mw_homogenized, 3.0),
               extract(epoch FROM e.occurred_at - %s) / 86400
        FROM seismic.v_event_location_unique AS e
        WHERE e.occurred_at > %s AND e.occurred_at <= %s + make_interval(secs => %s)
          AND ST_DWithin(e.geom::geography, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s)
          AND coalesce(e.mw_homogenized, 3.0) <= %s
        ORDER BY coalesce(e.mw_homogenized, 3.0)
    """, (main_t, main_t, main_t, days * 86400, mlon, mlat, radius_km * 1000, mmw))
    af = np.array(cursor.fetchall(), dtype=float)
    cursor.execute("""
        SELECT ST_X(geom), ST_Y(geom) FROM seismic.v_event_location_unique
        WHERE ST_Y(geom) BETWEEN %s AND %s AND ST_X(geom) BETWEEN %s AND %s
          AND NOT (occurred_at > %s AND occurred_at <= %s + make_interval(secs => %s))
    """, (view.lat_bottom, view.lat_top, view.lon_left, view.lon_right, main_t, main_t, days * 86400))
    bg = np.array(cursor.fetchall(), dtype=float)

    # Intensidad ShakeMap (USGS): bandas MMI.
    source = ogr.Open(str(MAULE_SHAKEMAP))
    layer = source.GetLayer(0)
    bands = []
    for feature in layer:
        value = float(feature.GetField("PARAMVALUE"))
        geometry = json.loads(feature.GetGeometryRef().ExportToJson())
        bands.append((value, geometry))
    bands.sort(key=lambda b: b[0])
    # Los poligonos de mi.shp vienen anidados (cada valor contiene a los mayores).
    for value, geometry in bands:
        if abs(value - round(value)) > 1e-6 or not 5 <= value <= 8:
            continue
        color = MMI_COLORS[int(round(value))]
        rings = view.rings(geometry)
        ax.add_collection(PatchCollection([Polygon(r, closed=True) for r in rings],
                                          facecolor=color, alpha=0.045, edgecolor="none", zorder=2))
        ax.add_collection(PatchCollection([Polygon(r, closed=True) for r in rings], facecolor="none",
                                          edgecolor=color, alpha=0.75, linewidth=1.3, zorder=3))
    # Etiquetas MMI sobre el borde oeste-este de cada contorno entero, a la latitud del epicentro.
    for value, geometry in bands:
        if abs(value - round(value)) < 1e-6 and 5 <= value <= 8:
            ring = np.array((geometry["coordinates"][0][0] if geometry["type"] == "MultiPolygon"
                             else geometry["coordinates"][0]))
            near = ring[np.abs(ring[:, 1] - (mlat - 1.6)) < 0.12]
            pick = near[np.argmin(near[:, 0])] if len(near) else ring[np.argmin(ring[:, 0])]
            lx, ly = view.px(pick[0], pick[1])
            t = ax.text(lx - 8, ly, ROMAN[int(round(value))], color=MMI_COLORS[int(round(value))],
                        fontsize=12, family="monospace", ha="right", zorder=9)
            t.set_path_effects([patheffects.withStroke(linewidth=3, foreground=OCEAN)])

    # Población expuesta a MMI >= VI: manzanas cuyo punto interior cae en una banda >= 6.
    paths = []
    for value, geometry in bands:
        if value >= 6:
            polys = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
            paths.extend(MplPath(np.array(p[0])) for p in polys)
    cursor.execute("""
        SELECT ST_X(point), ST_Y(point), population FROM seismic.census_block
        WHERE population > 0 AND point && ST_MakeEnvelope(-76, -40, -69, -31, 4326)
    """)
    blocks = np.array(cursor.fetchall(), dtype=float)
    inside = np.zeros(len(blocks), dtype=bool)
    for path in paths:
        inside |= path.contains_points(blocks[:, :2])
    exposed = int(blocks[inside, 2].sum())

    # Sismos.
    bx, by = view.px(bg[:, 0], bg[:, 1])
    ax.scatter(bx, by, s=2.2, c=[(1, 1, 1, 0.10)], linewidths=0, zorder=4)
    ax_, ay_ = view.px(af[:, 0], af[:, 1])
    colors = MW_CMAP((np.clip(af[:, 2], 3, 9.6) - 3) / 6.6)
    colors[:, 3] = 0.9
    ax.scatter(ax_, ay_, s=(mw_radius(af[:, 2], 1.7)) ** 2, c=colors, linewidths=0, zorder=5)

    # Elipse de desviación estándar (1 sigma) de las réplicas, en km.
    kx = af[:, 0] * 111.32 * math.cos(math.radians(mlat))
    ky = af[:, 1] * 110.57
    cov = np.cov(np.vstack([kx, ky]))
    values, vectors = np.linalg.eigh(cov)
    order = values.argsort()[::-1]
    values, vectors = values[order], vectors[:, order]
    major_km, minor_km = 2 * math.sqrt(values[0]), 2 * math.sqrt(values[1])
    azimuth = (math.degrees(math.atan2(vectors[0, 0], vectors[1, 0])) + 360) % 180
    cx_lon = kx.mean() / (111.32 * math.cos(math.radians(mlat)))
    cy_lat = ky.mean() / 110.57
    ex, ey = view.px(cx_lon, cy_lat)
    ellipse = Ellipse((ex, ey), width=minor_km / 111.32 / math.cos(math.radians(mlat)) * view.ppx,
                      height=major_km / 110.57 * view.ppy, angle=azimuth if azimuth < 90 else azimuth - 180,
                      fill=False, edgecolor="white", linewidth=1.6, linestyle=(0, (6, 4)), zorder=7)
    ax.add_patch(ellipse)
    ax.scatter([ex], [ey], marker="+", s=120, c="white", linewidths=1.4, zorder=7)

    mx, my = view.px(mlon, mlat)
    for r, a in ((16, 1.0), (30, 0.35)):
        ax.add_patch(plt.Circle((mx, my), r, fill=False, edgecolor="white", linewidth=1.6 if a == 1 else 1,
                                alpha=a, zorder=8))
    ax.scatter([mx], [my], s=60, c="#fffde7", linewidths=0, zorder=8)
    # Ventana de Gardner-Knopoff (radio en km).
    ax.add_patch(Ellipse((mx, my), width=2 * radius_km / 111.32 / math.cos(math.radians(mlat)) * view.ppx,
                         height=2 * radius_km / 110.57 * view.ppy, fill=False,
                         edgecolor=(1, 1, 1, 0.22), linewidth=1, linestyle=(0, (2, 4)), zorder=6))
    for name, lon, lat in [("Valparaíso", -71.62, -33.05), ("Santiago", -70.65, -33.45),
                           ("Talca", -71.66, -35.43), ("Constitución", -72.41, -35.33),
                           ("Concepción", -73.05, -36.83), ("Chillán", -72.10, -36.61),
                           ("Los Ángeles", -72.35, -37.47), ("Temuco", -72.59, -38.74)]:
        cx, cy = view.px(lon, lat)
        label(ax, cx, cy, name)
    save(fig, out / "maule.png")

    # Curva de Omori: tasa de réplicas por día en intervalos logarítmicos.
    t = af[:, 3]
    edges = np.logspace(np.log10(0.01), np.log10(days), 22)
    counts, _ = np.histogram(t, bins=edges)
    widths = np.diff(edges)
    centers = np.sqrt(edges[:-1] * edges[1:])
    rate = counts / widths
    ok = counts > 0
    fit = (centers > 0.05) & ok
    slope, intercept = np.polyfit(np.log10(centers[fit]), np.log10(rate[fit]), 1)
    fig, oax = plt.subplots(figsize=(7.6, 3.2), dpi=100)
    fig.patch.set_alpha(0)
    oax.set_facecolor("none")
    oax.loglog(centers[ok], rate[ok], "o", color="#ffa726", markersize=5)
    xs = np.logspace(np.log10(0.05), np.log10(days), 50)
    oax.loglog(xs, 10 ** intercept * xs ** slope, color=(1, 1, 1, 0.6), linewidth=1.2, linestyle="--")
    for spine in oax.spines.values():
        spine.set_visible(False)
    oax.tick_params(colors=(1, 1, 1, 0.45), labelsize=8, length=0, which="both")
    oax.grid(color=(1, 1, 1, 0.06), linewidth=0.6, which="both")
    oax.set_xlabel("Días desde el terremoto", color=(1, 1, 1, 0.45), fontsize=8.5)
    oax.set_ylabel("Réplicas por día", color=(1, 1, 1, 0.45), fontsize=8.5)
    fig.tight_layout()
    save(fig, out / "maule_omori.png", transparent=True)

    first_day = int((t <= 1).sum())
    largest = af[np.argmax(af[:, 2])]
    return {"maule": {"x": round(float(mx)), "y": round(float(my)), "mw": float(mmw),
                      "profundidad_km": float(mdepth)},
            "ventana_gk": {"radio_km": round(radius_km), "dias": round(days)},
            "replicas": int(len(af)), "replicas_primer_dia": first_day,
            "mayor_replica_mw": float(largest[2]), "mayor_replica_dias": round(float(largest[3]), 1),
            "elipse": {"eje_mayor_km": round(major_km), "eje_menor_km": round(minor_km),
                       "azimut_grados": round(azimuth), "centro_px": [round(float(ex)), round(float(ey))]},
            "omori_p": round(-float(slope), 2),
            "poblacion_mmi6": exposed,
            "mmi_bandas": sorted({round(v, 1) for v, _ in bands})}


# ---------------------------------------------------------------------------
def render_calama(cursor, out: Path) -> dict:
    view = View(-20.75, -23.45, -68.55)
    fig, ax = new_figure()
    draw_land(ax, view, cursor, region_tolerance=0.002, communes=True)
    cursor.execute("""
        SELECT administrative_area_id, official_area_km2,
               ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom, 0.001))
        FROM seismic.administrative_area WHERE level = 'commune' AND name = 'Calama'
    """)
    commune_id, commune_km2, commune_geojson = cursor.fetchone()
    ax.add_collection(PatchCollection(
        [Polygon(r, closed=True) for r in view.rings(json.loads(commune_geojson))],
        facecolor=(1, 1, 1, 0.035), edgecolor=(1, 1, 1, 0.75), linewidth=1.4, zorder=3))
    cursor.execute("""
        SELECT name, population, area_km2, ST_AsGeoJSON(geom) FROM seismic.urban_area
        WHERE commune_area_id = %s ORDER BY population DESC
    """, (commune_id,))
    urban = cursor.fetchall()
    for name, population, area_km2, geojson in urban:
        ax.add_collection(PatchCollection(
            [Polygon(r, closed=True) for r in view.rings(json.loads(geojson))],
            facecolor=(1, 1, 1, 0.55), edgecolor="white", linewidth=1.0, zorder=6))
    cursor.execute("""
        SELECT ST_X(geom), ST_Y(geom), coalesce(mw_homogenized, 3.0), coalesce(depth_km, 0),
               commune_name = 'Calama' AND assignment_method = 'covers'
        FROM seismic.v_event_location_unique
        WHERE ST_Y(geom) BETWEEN %s AND %s AND ST_X(geom) BETWEEN %s AND %s
        ORDER BY coalesce(mw_homogenized, 3.0)
    """, (view.lat_bottom, view.lat_top, view.lon_left, view.lon_right))
    ev = np.array(cursor.fetchall(), dtype=float)
    x, y = view.px(ev[:, 0], ev[:, 1])
    inside = ev[:, 4] > 0
    out_c = np.zeros((len(ev), 4))
    out_c[:] = (1, 1, 1, 0.10)
    ax.scatter(x[~inside], y[~inside], s=(mw_radius(ev[~inside, 2], 1.4)) ** 2, c=out_c[~inside],
               linewidths=0, zorder=4)
    colors = DEPTH_CMAP(np.clip(ev[inside, 3], 0, 700) / 700)
    colors[:, 3] = np.where(ev[inside, 2] >= 5, 0.95, 0.6)
    ax.scatter(x[inside], y[inside], s=(mw_radius(ev[inside, 2], 1.9)) ** 2, c=colors,
               linewidths=0, zorder=5)
    cursor.execute("""
        SELECT ST_X(l.geom), ST_Y(l.geom), l.mw_homogenized, l.occurred_at::date, l.depth_km
        FROM seismic.v_event_location_unique AS l
        JOIN seismic.event_urban_area AS link
          ON link.earthquake_event_id = l.earthquake_event_id AND link.epicentral_distance_km = 0
        WHERE l.commune_name = 'Calama' AND l.mw_homogenized >= 5
    """)
    under_city = cursor.fetchall()
    for lon, lat, mw, day, depth in under_city:
        ux, uy = view.px(lon, lat)
        ax.add_patch(plt.Circle((ux, uy), 14, fill=False, edgecolor="white", linewidth=1.8, zorder=9))
        ax.add_patch(plt.Circle((ux, uy), 26, fill=False, edgecolor="white", linewidth=1, alpha=0.3, zorder=9))
    for name, lon, lat in [("Calama", -68.93, -22.46), ("Chuquicamata", -68.90, -22.31),
                           ("San Pedro de Atacama", -68.20, -22.91), ("Ollagüe", -68.26, -21.22),
                           ("Antofagasta", -70.40, -23.65), ("Sierra Gorda", -69.32, -22.89)]:
        cx, cy = view.px(lon, lat)
        if 0 <= cx <= W and 0 <= cy <= H:
            label(ax, cx, cy, name, size=10)
    save(fig, out / "calama.png")

    cursor.execute("""
        SELECT count(*) FILTER (WHERE mw_homogenized >= 5),
               count(*) FILTER (WHERE mw_homogenized >= 4),
               round(avg(depth_km) FILTER (WHERE mw_homogenized >= 5)),
               max(mw_homogenized)
        FROM seismic.v_event_location_unique
        WHERE commune_name = 'Calama' AND assignment_method = 'covers'
    """)
    mw5, mw4, depth5, mwmax = cursor.fetchone()
    cursor.execute("""
        SELECT occurred_at::date, mw_homogenized, depth_km FROM seismic.v_event_location_unique
        WHERE commune_name = 'Calama' AND assignment_method = 'covers' AND mw_homogenized IS NOT NULL
        ORDER BY mw_homogenized DESC LIMIT 1
    """)
    big_day, big_mw, big_depth = cursor.fetchone()
    cursor.execute("""
        SELECT (extract(year FROM occurred_at)::int / 10) * 10, count(*)
        FROM seismic.v_event_location_unique
        WHERE commune_name = 'Calama' AND assignment_method = 'covers' AND mw_homogenized >= 4
          AND occurred_at >= '1960-01-01'
        GROUP BY 1 ORDER BY 1
    """)
    decades = {int(d): int(n) for d, n in cursor.fetchall()}
    return {"comuna_km2": float(commune_km2),
            "zonas_urbanas": [{"nombre": n, "poblacion": int(p), "km2": float(a)} for n, p, a, _ in urban],
            "mw5_en_comuna": int(mw5), "mw4_en_comuna": int(mw4), "profundidad_media_mw5": float(depth5),
            "mayor_sismo": {"fecha": str(big_day), "mw": float(big_mw), "profundidad_km": float(big_depth)},
            "bajo_la_ciudad": [{"fecha": str(d), "mw": float(m),
                                "profundidad_km": None if p is None else float(p)}
                               for _, _, m, d, p in under_city],
            "mw4_por_decada": decades}


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    connection = connect()
    cursor = connection.cursor()
    stats = {"replay": render_replay(cursor, out), "placa": render_plate(cursor, out),
             "anatomia": render_maule(cursor, out), "calama": render_calama(cursor, out)}
    connection.close()
    (out / "stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(stats, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".superdesign" / "tmp" / "modes")
