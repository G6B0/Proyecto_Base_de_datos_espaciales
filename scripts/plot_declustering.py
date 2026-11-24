"""Gráficos de los resultados del declustering (réplicas) para el informe.

Lee las ejecuciones guardadas por db/decluster_gardner_knopoff.sql y
db/decluster_st_dbscan.sql y genera en docs/img/replicas/:

  01_acumulado.png      Sismos Mw >= 4 acumulados desde 1960: con y sin réplicas.
  02_ejecuciones.png    Papel de los sismos en cada ejecución (barras 100 %).
  03_bath.png           Ley de Båth: principal menos mayor réplica.
  04_grandes.png        Réplicas de los grandes terremotos según cada método.
  05_mapa.png           Chile con y sin réplicas.
  06_maule.png          Maule 2010: Gardner-Knopoff frente a ST-DBSCAN.

Paleta categórica de referencia (validada con la guía de visualización):
azul #2a78d6, naranjo #eb6834, aqua #1baf7a, amarillo #eda100.

    "C:\\Program Files\\QGIS 3.44.13\\bin\\python-qgis-ltr.bat" scripts\\plot_declustering.py
"""

from __future__ import annotations

import json
import math
from datetime import datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import psycopg2  # noqa: E402
from matplotlib.collections import PatchCollection  # noqa: E402
from matplotlib.patches import Ellipse, Polygon  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "img" / "replicas"

SURFACE, INK, INK_2, INK_3 = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984"
GRID = "#e6e5e1"
BLUE, ORANGE, AQUA, YELLOW = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK_2, "text.color": INK,
    "xtick.color": INK_2, "ytick.color": INK_2, "font.size": 10,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.titlesize": 13, "axes.titleweight": "bold", "axes.titlelocation": "left", "axes.titlepad": 26,
})

REF = """method = 'gardner_knopoff_1974' AND catalog = 'unique' AND minimum_magnitude = 4.0
         AND parameters ->> 'ventana_precursores_dias' = '30'"""


def env(name: str) -> str:
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip()
    raise KeyError(name)


def connect():
    return psycopg2.connect(host="127.0.0.1", port=int(env("POSTGRES_PORT")), dbname=env("POSTGRES_DB"),
                            user=env("POSTGRES_USER"), password=env("POSTGRES_PASSWORD"))


def run_id(cur, where: str) -> int:
    cur.execute(f"SELECT declustering_run_id FROM seismic.declustering_run WHERE {where} "
                "ORDER BY executed_at DESC LIMIT 1")
    return cur.fetchone()[0]


def thousands(v: float) -> str:
    return f"{v:,.0f}".replace(",", ".")


def decimal_comma(v: float, digits: int = 1) -> str:
    return f"{v:.{digits}f}".replace(".", ",")


def subtitle(ax, text: str):
    ax.text(0, 1.02, text, transform=ax.transAxes, color=INK_2, fontsize=9.5, va="bottom")


def save(fig, name: str):
    OUT.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT / name, dpi=150, bbox_inches="tight", pad_inches=0.25)
    plt.close(fig)
    print("ok", name)


# ---------------------------------------------------------------------------
def fig_cumulative(cur, ref: int):
    cur.execute("""
        SELECT e.occurred_at, r.role IN ('mainshock', 'independent')
        FROM seismic.event_sequence_role AS r
        JOIN seismic.earthquake_event AS e USING (earthquake_event_id)
        WHERE r.declustering_run_id = %s ORDER BY e.occurred_at
    """, (ref,))
    rows = cur.fetchall()
    t = np.array([r[0] for r in rows])
    kept = np.array([r[1] for r in rows])
    fig, ax = plt.subplots(figsize=(10, 5.2))
    ax.step(t, np.arange(1, len(t) + 1), where="post", color=BLUE, linewidth=2, label="Catálogo completo")
    tk = t[kept]
    ax.step(tk, np.arange(1, len(tk) + 1), where="post", color=ORANGE, linewidth=2, label="Sin réplicas ni precursores")
    ax.set_xlim(datetime(1960, 1, 1), t[-1])
    ax.set_ylim(0, len(t) * 1.06)
    ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: thousands(v)))
    ax.xaxis.set_major_locator(mdates.YearLocator(10))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))
    ax.grid(axis="x", visible=False)
    ax.set_ylabel("Sismos Mw ≥ 4 acumulados")
    ax.legend(loc="upper left", frameon=False)
    # Etiquetas directas al final de cada línea.
    ax.text(t[-1], len(t), f"  {thousands(len(t))}", color=INK, va="center", fontsize=9.5, clip_on=False)
    ax.text(t[-1], len(tk), f"  {thousands(len(tk))}", color=INK, va="center", fontsize=9.5, clip_on=False)
    # Saltos de los grandes terremotos en la curva completa.
    for day, name in (("1985-03-03", "Valparaíso 1985"), ("2010-02-27", "Maule 2010"),
                      ("2014-04-01", "Iquique 2014"), ("2015-09-16", "Illapel 2015")):
        d = np.datetime64(day)
        idx = np.searchsorted(t.astype("datetime64[D]"), d)
        ax.annotate(name, xy=(t[idx], idx), xytext=(-12, 28), textcoords="offset points", ha="right",
                    fontsize=8.5, color=INK_2, arrowprops=dict(arrowstyle="-", color=INK_3, linewidth=0.8))
    ax.set_title("Las réplicas hacen la sismicidad a saltos")
    subtitle(ax, "Gardner-Knopoff sobre el catálogo sin duplicados (CSN + USGS), Mw ≥ 4 desde 1960. "
                 "Sin réplicas, la curva se acerca a una tasa constante.")
    save(fig, "01_acumulado.png")


# ---------------------------------------------------------------------------
def fig_runs(cur):
    cur.execute("""
        SELECT run.declustering_run_id, run.method, run.catalog, coalesce(run.source_code, ''),
               run.parameters, role.role, count(*)
        FROM seismic.declustering_run AS run
        JOIN seismic.event_sequence_role AS role USING (declustering_run_id)
        GROUP BY 1, 2, 3, 4, 5, 6 ORDER BY 1
    """)
    runs: dict[int, dict] = {}
    for rid, method, catalog, source, params, role, n in cur.fetchall():
        if method == "st_dbscan":
            label = f"ST-DBSCAN · {params['eps_km']} km, {params['eps_dias']} días"
        else:
            fs = params.get("ventana_precursores_dias")
            window = "ventana simétrica" if float(fs) < 0 else f"precursores {fs} días"
            label = f"Gardner-Knopoff · {'solo USGS' if source == 'usgs' else 'sin duplicados'} · {window}"
        runs.setdefault(rid, {"label": label, "counts": {}})["counts"][role] = n
    roles = [("mainshock", "Principales", BLUE), ("independent", "Independientes", ORANGE),
             ("foreshock", "Precursores", AQUA), ("aftershock", "Réplicas", YELLOW)]
    items = list(runs.values())[::-1]
    fig, ax = plt.subplots(figsize=(10, 0.75 * len(items) + 1.6))
    for i, run in enumerate(items):
        total = sum(run["counts"].values())
        left = 0.0
        for key, name, color in roles:
            share = 100 * run["counts"].get(key, 0) / total
            ax.barh(i, share, left=left, color=color, edgecolor=SURFACE, linewidth=2, height=0.62,
                    label=name if i == 0 else None)
            if share >= 5:
                ax.text(left + share / 2, i, f"{share:.0f} %", ha="center", va="center", fontsize=9,
                        color="white" if color in (BLUE, ORANGE) else INK)
            left += share
    ax.set_yticks(range(len(items)), [f"{r['label']}\n{thousands(sum(r['counts'].values()))} sismos" for r in items],
                  fontsize=9)
    ax.set_xlim(0, 100)
    ax.set_xticks([0, 25, 50, 75, 100], ["0 %", "25 %", "50 %", "75 %", "100 %"])
    ax.grid(axis="y", visible=False)
    ax.spines["left"].set_visible(False)
    ax.tick_params(axis="y", length=0)
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=4, frameon=False, fontsize=9)
    ax.set_title("Cada método clasifica distinto", pad=34)
    save(fig, "02_ejecuciones.png")


# ---------------------------------------------------------------------------
def fig_bath(cur, ref: int):
    cur.execute("""
        SELECT main.mw_homogenized - s.largest_aftershock_magnitude
        FROM seismic.seismic_sequence AS s
        JOIN seismic.earthquake_event AS main ON main.earthquake_event_id = s.mainshock_event_id
        WHERE s.declustering_run_id = %s AND main.mw_homogenized >= 6.5
          AND s.largest_aftershock_magnitude IS NOT NULL
    """, (ref,))
    delta = np.array([float(r[0]) for r in cur.fetchall()])
    fig, ax = plt.subplots(figsize=(9, 4.6))
    bins = np.arange(0, max(3.2, delta.max() + 0.2), 0.2)
    ax.hist(delta, bins=bins, color=BLUE, edgecolor=SURFACE, linewidth=2)
    ax.axvline(1.2, color=INK, linestyle="--", linewidth=1.2)
    ax.text(1.17, ax.get_ylim()[1] * 0.97, "Ley de Båth: 1,2", color=INK, fontsize=9, va="top", ha="right",
            bbox=dict(facecolor=SURFACE, edgecolor="none", pad=1.5))
    median = float(np.median(delta))
    ax.axvline(median, color=ORANGE, linewidth=2)
    ax.text(median + 0.43, ax.get_ylim()[1] * 0.97,
            f"Mediana: {median:.2f}".replace(".", ","), color=INK, fontsize=9, va="top",
            bbox=dict(facecolor=SURFACE, edgecolor="none", pad=1.5))
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: decimal_comma(v)))
    ax.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))
    ax.set_xlabel("Mw del sismo principal − Mw de su mayor réplica")
    ax.set_ylabel("Secuencias")
    ax.grid(axis="x", visible=False)
    ax.set_title("La réplica mayor es ~1,2 unidades menor que el principal")
    subtitle(ax, f"{len(delta)} secuencias con principal Mw ≥ 6,5 (Gardner-Knopoff de referencia). "
                 f"Media {delta.mean():.2f}".replace(".", ",") + ".")
    save(fig, "03_bath.png")


# ---------------------------------------------------------------------------
def fig_big(cur, ref: int, dbscan: int):
    quakes = [("1960-05-22", "Valdivia 1960"), ("1985-03-03", "Valparaíso 1985"),
              ("1995-07-30", "Antofagasta 1995"), ("2010-02-27", "Maule 2010"),
              ("2014-04-01", "Iquique 2014"), ("2015-09-16", "Illapel 2015")]
    data = []
    for day, name in quakes:
        row = []
        for rid in (ref, dbscan):
            cur.execute("""
                SELECT s.aftershock_count FROM seismic.seismic_sequence AS s
                JOIN seismic.earthquake_event AS main ON main.earthquake_event_id = s.mainshock_event_id
                WHERE s.declustering_run_id = %s AND main.occurred_at::date = %s
                ORDER BY main.mw_homogenized DESC LIMIT 1
            """, (rid, day))
            got = cur.fetchone()
            row.append(got[0] if got else 0)
        data.append((name, *row))
    fig, ax = plt.subplots(figsize=(10, 4.8))
    y = np.arange(len(data))[::-1]
    h = 0.36
    gk = [d[1] for d in data]
    sd = [d[2] for d in data]
    ax.barh(y + h / 2, gk, height=h, color=BLUE, edgecolor=SURFACE, linewidth=2, label="Gardner-Knopoff")
    ax.barh(y - h / 2, sd, height=h, color=ORANGE, edgecolor=SURFACE, linewidth=2, label="ST-DBSCAN")
    for yi, a, b in zip(y, gk, sd):
        ax.text(a, yi + h / 2, f"  {thousands(a)}", va="center", fontsize=9, color=INK)
        ax.text(b, yi - h / 2, f"  {thousands(b)}", va="center", fontsize=9, color=INK)
    ax.set_yticks(y, [d[0] for d in data])
    ax.tick_params(axis="y", length=0)
    ax.spines["left"].set_visible(False)
    ax.grid(axis="y", visible=False)
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: thousands(v)))
    ax.set_xlabel("Réplicas")
    ax.set_xlim(0, max(gk + sd) * 1.15)
    ax.legend(loc="lower right", frameon=False)
    ax.set_title("ST-DBSCAN encadena más réplicas en los terremotos de ruptura larga")
    subtitle(ax, "Gardner-Knopoff usa un círculo que crece con Mw; ST-DBSCAN une sismos a 40 km y 10 días entre sí.")
    save(fig, "04_grandes.png")


# ---------------------------------------------------------------------------
def regions(cur, west, south, east, north, tol=0.02):
    cur.execute("""
        SELECT ST_AsGeoJSON(ST_Simplify(geom, %s, true)) FROM seismic.administrative_area
        WHERE level = 'region' AND geom && ST_MakeEnvelope(%s, %s, %s, %s, 4326)
    """, (tol, west, south, east, north))
    patches = []
    for (gj,) in cur.fetchall():
        g = json.loads(gj)
        for poly in (g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]):
            patches.append(Polygon(np.array(poly[0]), closed=True))
    return patches


def map_axes(ax, west, south, east, north):
    ax.set_xlim(west, east)
    ax.set_ylim(south, north)
    ax.set_aspect(1 / math.cos(math.radians((south + north) / 2)))
    ax.grid(False)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_xticks([])
    ax.set_yticks([])


def fig_map(cur, ref: int):
    cur.execute("""
        SELECT ST_X(e.geom), ST_Y(e.geom), e.mw_homogenized, r.role IN ('mainshock', 'independent')
        FROM seismic.event_sequence_role AS r JOIN seismic.earthquake_event AS e USING (earthquake_event_id)
        WHERE r.declustering_run_id = %s ORDER BY e.mw_homogenized
    """, (ref,))
    ev = np.array(cur.fetchall(), dtype=float)
    west, south, east, north = -80, -57, -62, -16
    land = regions(cur, west, south, east, north)
    fig, axes = plt.subplots(1, 2, figsize=(9, 10))
    size = 0.6 + (np.clip(ev[:, 2], 4, 9.5) - 4) ** 2 * 1.6
    for ax, title, mask in ((axes[0], "Catálogo completo", np.ones(len(ev), dtype=bool)),
                            (axes[1], "Sin réplicas ni precursores", ev[:, 3] > 0)):
        ax.add_collection(PatchCollection([Polygon(p.get_xy(), closed=True) for p in land],
                                          facecolor="#efeee9", edgecolor="#c9c8c2", linewidth=0.4))
        removed = mask & (ev[:, 3] == 0)
        kept = mask & (ev[:, 3] > 0)
        ax.scatter(ev[removed, 0], ev[removed, 1], s=size[removed], c=ORANGE, alpha=0.55, linewidths=0,
                   label="Réplica o precursor")
        ax.scatter(ev[kept, 0], ev[kept, 1], s=size[kept], c=BLUE, alpha=0.6, linewidths=0,
                   label="Principal o independiente")
        map_axes(ax, west, south, east, north)
        ax.set_title(f"{title}\n{thousands(mask.sum())} sismos", fontsize=11)
    axes[0].legend(loc="lower left", frameon=False, fontsize=8.5, markerscale=3)
    fig.suptitle("Chile con y sin réplicas (Mw ≥ 4 desde 1960)", x=0.06, ha="left", fontsize=13,
                 fontweight="bold")
    save(fig, "05_mapa.png")


def fig_maule(cur, ref: int, dbscan: int):
    def members(rid):
        cur.execute("""
            WITH main AS (
                SELECT s.seismic_sequence_id, e.earthquake_event_id, ST_X(e.geom) AS lon, ST_Y(e.geom) AS lat,
                       e.mw_homogenized AS mw
                FROM seismic.seismic_sequence AS s
                JOIN seismic.earthquake_event AS e ON e.earthquake_event_id = s.mainshock_event_id
                WHERE s.declustering_run_id = %s AND e.occurred_at::date = '2010-02-27'
                ORDER BY e.mw_homogenized DESC LIMIT 1
            )
            SELECT r.earthquake_event_id, ST_X(e.geom), ST_Y(e.geom), e.mw_homogenized, main.lon, main.lat, main.mw
            FROM main
            JOIN seismic.event_sequence_role AS r
              ON r.declustering_run_id = %s AND r.seismic_sequence_id = main.seismic_sequence_id
            JOIN seismic.earthquake_event AS e ON e.earthquake_event_id = r.earthquake_event_id
        """, (rid, rid))
        rows = cur.fetchall()
        return {r[0]: (r[1], r[2], float(r[3])) for r in rows}, rows[0][4:7]

    gk, (mlon, mlat, mmw) = members(ref)
    sd, _ = members(dbscan)
    both = set(gk) & set(sd)
    only_sd = set(sd) - set(gk)
    only_gk = set(gk) - set(sd)
    west, south, east, north = -76.5, -39.6, -69.5, -31.6
    fig, ax = plt.subplots(figsize=(8.2, 9))
    ax.add_collection(PatchCollection(regions(cur, west, south, east, north, 0.005),
                                      facecolor="#efeee9", edgecolor="#c9c8c2", linewidth=0.5))

    def plot(ids, src, color, label):
        pts = np.array([src[i] for i in ids], dtype=float)
        if len(pts):
            ax.scatter(pts[:, 0], pts[:, 1], s=4 + (np.clip(pts[:, 2], 4, 9) - 4) ** 2 * 6, c=color,
                       alpha=0.75, linewidths=0.6, edgecolors=SURFACE, label=f"{label} ({thousands(len(pts))})")
    plot(both, gk, BLUE, "En los dos métodos")
    plot(only_sd, sd, ORANGE, "Solo ST-DBSCAN")
    plot(only_gk, gk, AQUA, "Solo Gardner-Knopoff")
    radius_km = 10 ** (0.1238 * float(mmw) + 0.983)
    ax.add_patch(Ellipse((mlon, mlat), 2 * radius_km / (111.32 * math.cos(math.radians(mlat))),
                         2 * radius_km / 110.57, fill=False, edgecolor=INK, linestyle="--", linewidth=1.2))
    ax.text(mlon - radius_km / (111.32 * math.cos(math.radians(mlat))) - 0.1, mlat,
            f"Ventana de\nGardner-Knopoff\n{radius_km:.0f} km", ha="right", va="center", fontsize=8.5, color=INK_2)
    ax.scatter([mlon], [mlat], marker="*", s=420, c=INK, edgecolors=SURFACE, linewidths=1.2, zorder=5)
    ax.annotate("Maule 2010 · Mw 8,8", (mlon, mlat), xytext=(14, -16), textcoords="offset points",
                fontsize=9.5, fontweight="bold")
    for name, lon, lat in (("Pichilemu", -72.00, -34.39), ("Concepción", -73.05, -36.83),
                           ("Valparaíso", -71.62, -33.05), ("Santiago", -70.65, -33.45)):
        ax.scatter([lon], [lat], s=12, c=INK_2, zorder=4)
        ax.annotate(name, (lon, lat), xytext=(5, 4), textcoords="offset points", fontsize=8.5, color=INK_2)
    map_axes(ax, west, south, east, north)
    ax.legend(loc="lower left", frameon=False, fontsize=9, markerscale=1.5)
    ax.set_title("Maule 2010: el círculo frente a la cadena")
    subtitle(ax, "Réplicas según Gardner-Knopoff (círculo de radio fijo) y ST-DBSCAN (sismos encadenados).")
    save(fig, "06_maule.png")


def main():
    connection = connect()
    cur = connection.cursor()
    ref = run_id(cur, REF)
    dbscan = run_id(cur, "method = 'st_dbscan' AND catalog = 'unique'")
    fig_cumulative(cur, ref)
    fig_runs(cur)
    fig_bath(cur, ref)
    fig_big(cur, ref, dbscan)
    fig_map(cur, ref)
    fig_maule(cur, ref, dbscan)
    connection.close()


if __name__ == "__main__":
    main()
