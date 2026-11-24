"""Secuencias sísmicas (modo Anatomía): réplicas, ventana, elipse y Omori.

Todo según la ejecución de referencia de Gardner-Knopoff (vista
seismic.v_event_role). La elipse y Omori salen de las vistas
seismic.v_sequence_ellipse y seismic.v_sequence_omori(_bins), que cubren
todas las secuencias y todas las ejecuciones.
"""

from __future__ import annotations

import json

from fastapi import APIRouter, HTTPException

from ..db import fetch_all, fetch_one

router = APIRouter()


def gk_window(mw: float) -> dict:
    """Ventana de Gardner y Knopoff (1974), igual que db/decluster_gardner_knopoff.sql."""
    radius_km = 10 ** (0.1238 * mw + 0.983)
    days = 10 ** (0.5409 * mw - 0.547) if mw < 6.5 else 10 ** (0.032 * mw + 2.7389)
    return {"radius_km": round(radius_km, 1), "days": round(days, 1), "foreshock_days": round(min(days, 30), 1)}


@router.get("/api/sequences/{event_id}")
def sequence(event_id: int):
    """La secuencia de un sismo (su principal, réplica o precursor)."""
    head = fetch_one("""
        SELECT seq.seismic_sequence_id AS sequence_id, seq.aftershock_count, seq.foreshock_count,
               seq.started_at, seq.ended_at,
               m.earthquake_event_id AS id, m.occurred_at, m.mw_homogenized::float AS mw,
               m.depth_km::float AS depth_km, ST_X(m.geom) AS lon, ST_Y(m.geom) AS lat,
               loc.commune_name, loc.region_name,
               impact.max_mmi::float, impact.max_cdi::float, impact.pager_alert, impact.has_shakemap
        FROM seismic.v_event_role AS me
        JOIN seismic.seismic_sequence AS seq ON seq.seismic_sequence_id = me.seismic_sequence_id
        JOIN seismic.earthquake_event AS m ON m.earthquake_event_id = seq.mainshock_event_id
        LEFT JOIN seismic.v_event_location AS loc ON loc.earthquake_event_id = m.earthquake_event_id
        LEFT JOIN seismic.event_match AS pair ON pair.csn_event_id = m.earthquake_event_id
        LEFT JOIN seismic.event_impact_summary AS impact
               ON impact.earthquake_event_id = coalesce(pair.usgs_event_id, m.earthquake_event_id)
        WHERE me.earthquake_event_id = %(id)s
    """, {"id": event_id})
    if not head:
        raise HTTPException(404, "El sismo no pertenece a una secuencia (es independiente o está fuera del análisis)")
    sid = head["sequence_id"]
    params = {"sid": sid, "main": head["id"]}

    members = fetch_all("""
        SELECT r.earthquake_event_id AS id, r.role, ST_X(e.geom) AS lon, ST_Y(e.geom) AS lat,
               e.mw_homogenized::float AS mw, e.depth_km::float AS depth_km,
               round((extract(epoch FROM r.time_from_mainshock) / 86400)::numeric, 4)::float AS days,
               r.distance_to_mainshock_km::float AS km
        FROM seismic.v_event_role AS r
        JOIN seismic.earthquake_event AS e USING (earthquake_event_id)
        WHERE r.seismic_sequence_id = %(sid)s
        ORDER BY e.mw_homogenized NULLS FIRST
    """, params)
    aftershocks = [m for m in members if m["role"] == "aftershock"]
    largest = max(aftershocks, key=lambda m: m["mw"] or 0, default=None)

    ellipse = fetch_one("""
        SELECT major_axis_km::float, minor_axis_km::float, axis_ratio::float, azimuth_deg::float,
               ST_X(center) AS lon, ST_Y(center) AS lat, ST_AsGeoJSON(geom, 5) AS geometry
        FROM seismic.v_sequence_ellipse WHERE seismic_sequence_id = %(sid)s
    """, params)
    if ellipse:
        ellipse["geometry"] = json.loads(ellipse["geometry"])

    omori = fetch_one("""
        SELECT omori_p::float AS p, r2::float, bins_used, log10_k::float
        FROM seismic.v_sequence_omori WHERE seismic_sequence_id = %(sid)s
    """, params)
    bins = fetch_all("""
        SELECT bin, aftershocks, from_days, to_days, center_days, per_day
        FROM seismic.v_sequence_omori_bins WHERE seismic_sequence_id = %(sid)s ORDER BY bin
    """, params)

    window = gk_window(head["mw"])
    window_geom = fetch_one("""
        SELECT ST_AsGeoJSON(ST_Buffer(ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326)::geography,
                                      %(m)s, 'quad_segs=32')::geometry, 5) AS g
    """, {"lon": head["lon"], "lat": head["lat"], "m": window["radius_km"] * 1000})["g"]
    window["geometry"] = json.loads(window_geom)

    # Sismos grandes del mismo período y zona que la ventana dejó fuera de la
    # secuencia (por ejemplo Pichilemu 2010 respecto del Maule).
    outside = fetch_all("""
        SELECT e.earthquake_event_id AS id, e.occurred_at, e.mw_homogenized::float AS mw,
               e.commune_name, r.role, ST_X(e.geom) AS lon, ST_Y(e.geom) AS lat,
               round((ST_Distance(e.geom::geography, m.geom::geography) / 1000)::numeric)::float AS km
        FROM seismic.earthquake_event AS m
        JOIN seismic.v_event_location_unique AS e
          ON e.occurred_at > m.occurred_at
         AND e.occurred_at <= m.occurred_at + %(days)s * interval '1 day'
         AND ST_DWithin(e.geom::geography, m.geom::geography, %(far)s)
        JOIN seismic.v_event_role AS r ON r.earthquake_event_id = e.earthquake_event_id
        WHERE m.earthquake_event_id = %(main)s
          AND e.mw_homogenized >= greatest(6.0, %(mw)s - 2)
          AND r.seismic_sequence_id IS DISTINCT FROM %(sid)s
        ORDER BY e.mw_homogenized DESC LIMIT 3
    """, {**params, "days": window["days"], "far": window["radius_km"] * 3000, "mw": head["mw"]})

    # La misma secuencia según ST-DBSCAN (la alternativa del paso 3).
    dbscan = fetch_one("""
        WITH run AS (
            SELECT declustering_run_id FROM seismic.declustering_run
            WHERE method = 'st_dbscan' AND catalog = 'unique' ORDER BY executed_at DESC LIMIT 1
        )
        SELECT seq.aftershock_count, seq.foreshock_count, x.major_axis_km::float, x.minor_axis_km::float
        FROM seismic.event_sequence_role AS r
        JOIN run USING (declustering_run_id)
        JOIN seismic.seismic_sequence AS seq ON seq.seismic_sequence_id = r.seismic_sequence_id
        LEFT JOIN seismic.v_sequence_ellipse AS x ON x.seismic_sequence_id = seq.seismic_sequence_id
        WHERE r.earthquake_event_id = %(main)s
    """, params)

    return {
        "sequence_id": sid,
        "mainshock": {k: head[k] for k in ("id", "occurred_at", "mw", "depth_km", "lon", "lat",
                                            "commune_name", "region_name")},
        "impact": {k: head[k] for k in ("max_mmi", "max_cdi", "pager_alert", "has_shakemap")},
        "counts": {
            "aftershocks": head["aftershock_count"],
            "foreshocks": head["foreshock_count"],
            "first_day": sum(1 for m in aftershocks if m["days"] <= 1),
            "largest_aftershock": None if not largest else
            {"id": largest["id"], "mw": largest["mw"], "days": largest["days"], "km": largest["km"]},
            "last_aftershock_days": max((m["days"] for m in aftershocks), default=0),
        },
        "window": window,
        "ellipse": ellipse,
        "omori": {"fit": omori, "bins": bins},
        "outside": outside,
        "st_dbscan": dbscan,
        "events": {
            "type": "FeatureCollection",
            "features": [{
                "type": "Feature", "id": m["id"],
                "geometry": {"type": "Point", "coordinates": [m["lon"], m["lat"]]},
                "properties": {"role": m["role"], "mw": m["mw"], "d": m["days"], "km": m["km"]},
            } for m in members],
        },
    }
