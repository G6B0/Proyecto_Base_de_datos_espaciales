"""Test de Knox: ¿los sismos están cerca en espacio Y tiempo más de lo esperable?

Diapositiva 95 de la materia (Spatio-Temporal & Event-Based Spatial).
Valida el declustering (docs/PLAN_ENTREGA3.md, paso 4): si quitar réplicas
funciona, la interacción espacio-tiempo debe caer fuerte.

Método:
  1. Para cada par de sismos a delta km o menos (distancia sobre la esfera),
     se mira si además están a tau días o menos. X = cantidad de esos pares.
  2. Hipótesis nula (sin interacción): se barajan las fechas entre los
     epicentros (permutación). Conserva dónde ocurren los sismos y cuántos
     hay cada año; rompe la relación entre lugar y momento.
  3. Con N permutaciones: esperado = media de X simulado, razón = X / esperado,
     p_mayor = (1 + nº de simulaciones >= X) / (N + 1)  (más pares que el azar)
     p_menor = (1 + nº de simulaciones <= X) / (N + 1)  (menos pares que el azar).

Cuidado al leer el catálogo sin réplicas de Gardner-Knopoff: sus ventanas
(30 km y 41 días para Mw 4, más para Mw mayores) son más grandes que varias
de las del test, así que vacían esas vecindades por construcción y la razón
puede quedar en 0. Eso no prueba nada por sí solo; lo informativo es que la
interacción no reaparece a escalas que el método no fuerza.

Catálogos (sismos Mw >= 4 desde 1960, sin duplicados CSN-USGS):
  completo, sin réplicas según Gardner-Knopoff (ejecución de referencia,
  vista v_event_role) y sin réplicas según ST-DBSCAN.

Escribe docs/analisis/knox.json y docs/img/replicas/07_knox.png.

    "C:\\Program Files\\QGIS 3.44.13\\bin\\python-qgis-ltr.bat" scripts\\knox_test.py [--permutations 999]
"""

from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import psycopg2  # noqa: E402
from scipy.spatial import cKDTree  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
EARTH_KM = 6371.0088
DELTAS_KM = (10, 25, 50)
TAUS_DAYS = (1, 10, 100)
SEED = 20261123

SURFACE, INK, INK_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
COLORS = {"completo": "#2a78d6", "gardner_knopoff": "#eb6834", "st_dbscan": "#1baf7a"}
LABELS = {"completo": "Catálogo completo", "gardner_knopoff": "Sin réplicas (Gardner-Knopoff)",
          "st_dbscan": "Sin réplicas (ST-DBSCAN)"}


def env(name: str) -> str:
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip()
    raise KeyError(name)


def load(cur):
    """Sismos de la ejecución de referencia con su papel en GK y en ST-DBSCAN."""
    cur.execute("""
        WITH dbscan AS (
            SELECT declustering_run_id FROM seismic.declustering_run
            WHERE method = 'st_dbscan' AND catalog = 'unique'
            ORDER BY executed_at DESC LIMIT 1
        )
        SELECT ST_X(e.geom), ST_Y(e.geom), extract(epoch FROM e.occurred_at) / 86400.0,
               gk.role IN ('mainshock', 'independent'),
               sd.role IN ('mainshock', 'independent')
        FROM seismic.v_event_role AS gk
        JOIN seismic.earthquake_event AS e USING (earthquake_event_id)
        JOIN seismic.event_sequence_role AS sd
          ON sd.earthquake_event_id = gk.earthquake_event_id
         AND sd.declustering_run_id = (SELECT declustering_run_id FROM dbscan)
    """)
    data = np.array(cur.fetchall(), dtype=float)
    return {"lon": data[:, 0], "lat": data[:, 1], "t": data[:, 2],
            "gardner_knopoff": data[:, 3] > 0, "st_dbscan": data[:, 4] > 0}


def chord(km: float) -> float:
    return 2 * EARTH_KM * np.sin(km / (2 * EARTH_KM))


def knox(lon, lat, t, permutations: int, rng) -> list[dict]:
    lam, phi = np.radians(lon), np.radians(lat)
    xyz = EARTH_KM * np.column_stack([np.cos(phi) * np.cos(lam), np.cos(phi) * np.sin(lam), np.sin(phi)])
    tree = cKDTree(xyz)
    pairs = tree.query_pairs(chord(max(DELTAS_KM)), output_type="ndarray").astype(np.int32)
    dist = np.linalg.norm(xyz[pairs[:, 0]] - xyz[pairs[:, 1]], axis=1)
    order = np.argsort(dist)
    i, j, dist = pairs[order, 0], pairs[order, 1], dist[order]
    del pairs, order
    # Los pares a delta km o menos son un prefijo del arreglo ordenado.
    ends = {d: int(np.searchsorted(dist, chord(d), side="right")) for d in DELTAS_KM}

    def counts(times) -> np.ndarray:
        dt = np.abs(times[i] - times[j])
        return np.array([[np.count_nonzero(dt[:ends[d]] <= tau) for tau in TAUS_DAYS] for d in DELTAS_KM])

    observed = counts(t)
    simulated = np.empty((permutations, len(DELTAS_KM), len(TAUS_DAYS)), dtype=np.int64)
    for k in range(permutations):
        simulated[k] = counts(rng.permutation(t))
    expected = simulated.mean(axis=0)
    p_greater = (1 + (simulated >= observed).sum(axis=0)) / (permutations + 1)
    p_less = (1 + (simulated <= observed).sum(axis=0)) / (permutations + 1)
    results = []
    for a, d in enumerate(DELTAS_KM):
        for b, tau in enumerate(TAUS_DAYS):
            results.append({
                "delta_km": d, "tau_dias": tau, "pares_espaciales": ends[d],
                "observado": int(observed[a, b]), "esperado": round(float(expected[a, b]), 1),
                "razon": round(float(observed[a, b] / expected[a, b]), 2) if expected[a, b] else None,
                "exceso": int(round(observed[a, b] - expected[a, b])),
                "p_mayor": round(float(p_greater[a, b]), 4),
                "p_menor": round(float(p_less[a, b]), 4),
            })
    return results


def figure(all_results: dict, permutations: int, out: Path):
    plt.rcParams.update({"figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
                         "axes.edgecolor": GRID, "axes.labelcolor": INK_2, "xtick.color": INK_2,
                         "ytick.color": INK_2, "font.size": 10, "axes.spines.top": False,
                         "axes.spines.right": False})
    fig, axes = plt.subplots(1, len(TAUS_DAYS), figsize=(12, 4.8), sharey=True)
    catalogs = list(all_results)
    width = 0.26
    for ax, tau in zip(axes, TAUS_DAYS):
        x = np.arange(len(DELTAS_KM))
        for k, name in enumerate(catalogs):
            rows = [r for r in all_results[name]["resultados"] if r["tau_dias"] == tau]
            ratios = [r["razon"] for r in rows]
            shown = [max(v, 0.05) for v in ratios]  # la escala log no admite 0
            bars = ax.bar(x + (k - 1) * width, shown, width=width, color=COLORS[name], edgecolor=SURFACE,
                          linewidth=2, label=LABELS[name])
            for bar, value, height in zip(bars, ratios, shown):
                ax.text(bar.get_x() + bar.get_width() / 2, height * 1.08, f"{value:.1f}".replace(".", ","),
                        ha="center", va="bottom", fontsize=8, color=INK)
        ax.axhline(1, color=INK, linewidth=1, linestyle="--")
        ax.set_yscale("log")
        ax.set_ylim(0.04, 60)
        ax.set_xticks(x, [f"{d} km" for d in DELTAS_KM])
        ax.set_title(f"τ = {tau} {'día' if tau == 1 else 'días'}", loc="left", fontsize=11, fontweight="bold")
        ax.set_axisbelow(True)
        ax.grid(axis="y", color=GRID, linewidth=0.8, which="major")
        ax.grid(axis="x", visible=False)
    axes[0].set_ylabel("Pares observados / esperados (escala log)")
    axes[0].yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}".replace(".", ",")))
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, 0.925), ncol=3, frameon=False)
    fig.suptitle("Test de Knox: Gardner-Knopoff elimina la interacción espacio-tiempo; ST-DBSCAN deja una parte",
                 x=0.06, ha="left", y=1.075, fontsize=13, fontweight="bold")
    fig.text(0.06, 0.965, f"Sismos Mw ≥ 4 desde 1960. Esperado: media de {permutations} permutaciones de las fechas. "
                          "1 = sin interacción; sobre 1, agrupamiento; bajo 1, menos pares que el azar.",
             fontsize=9, color=INK_2)
    fig.tight_layout(rect=(0, 0, 1, 0.86))
    fig.savefig(out, dpi=150, bbox_inches="tight", pad_inches=0.25)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--permutations", type=int, default=999)
    parser.add_argument("--solo-grafico", action="store_true",
                        help="redibuja 07_knox.png desde docs/analisis/knox.json sin recalcular")
    args = parser.parse_args()
    if args.solo_grafico:
        saved = json.loads((ROOT / "docs" / "analisis" / "knox.json").read_text(encoding="utf-8"))
        figure(saved["catalogos"], saved["permutaciones"], ROOT / "docs" / "img" / "replicas" / "07_knox.png")
        print("ok grafico")
        return
    connection = psycopg2.connect(host="127.0.0.1", port=int(env("POSTGRES_PORT")), dbname=env("POSTGRES_DB"),
                                  user=env("POSTGRES_USER"), password=env("POSTGRES_PASSWORD"))
    data = load(connection.cursor())
    connection.close()
    rng = np.random.default_rng(SEED)
    masks = {"completo": np.ones(len(data["t"]), dtype=bool),
             "gardner_knopoff": data["gardner_knopoff"], "st_dbscan": data["st_dbscan"]}
    all_results = {}
    for name, mask in masks.items():
        started = time.time()
        results = knox(data["lon"][mask], data["lat"][mask], data["t"][mask], args.permutations, rng)
        all_results[name] = {"sismos": int(mask.sum()), "segundos": round(time.time() - started, 1),
                             "resultados": results}
        print(name, int(mask.sum()), "sismos", f"{time.time() - started:.0f} s")
        for r in results:
            print("  ", r)
    out_json = ROOT / "docs" / "analisis" / "knox.json"
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps({
        "metodo": "Test de Knox con permutación de fechas (Monte Carlo)",
        "permutaciones": args.permutations, "semilla": SEED,
        "catalogo": "v_event_role: Mw >= 4 desde 1960, sin duplicados CSN-USGS",
        "calculado": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "catalogos": all_results,
    }, ensure_ascii=False, indent=1), encoding="utf-8")
    out_png = ROOT / "docs" / "img" / "replicas" / "07_knox.png"
    figure(all_results, args.permutations, out_png)
    print("ok", out_json, out_png)


if __name__ == "__main__":
    main()
