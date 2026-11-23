"""Sismos: teselas vectoriales, ficha de un sismo y conteos.

Todo sale de seismic.v_event_location_unique: un registro por sismo (el del
CSN si existe; los de USGS solo cuando no tienen par en event_match).
"""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, HTTPException, Query, Response
from psycopg.rows import tuple_row

from ..db import fetch_all, fetch_one, pool

router = APIRouter()


def _filters(year_min: int | None, year_max: int | None, mw_min: float | None,
             depth_min: float | None, depth_max: float | None,
             source: str, region: str | None) -> tuple[str, dict]:
    """Arma el WHERE de los filtros de la interfaz con parámetros (nunca texto pegado)."""
    clauses, params = [], {}
    if year_min is not None:
        clauses.append("e.occurred_at >= make_date(%(year_min)s, 1, 1)")
        params["year_min"] = year_min
    if year_max is not None:
        clauses.append("e.occurred_at < make_date(%(year_max)s + 1, 1, 1)")
        params["year_max"] = year_max
    if mw_min is not None:
        clauses.append("e.mw_homogenized >= %(mw_min)s")
        params["mw_min"] = mw_min
    if depth_min is not None:
        clauses.append("e.depth_km >= %(depth_min)s")
        params["depth_min"] = depth_min
    if depth_max is not None:
        clauses.append("e.depth_km <= %(depth_max)s")
        params["depth_max"] = depth_max
    if source == "csn":
        clauses.append("e.source_code = 'csn'")
    elif source == "usgs":
        # Sismos que publica USGS: los suyos sin par y los del CSN que tienen copia en USGS.
        clauses.append("(e.source_code = 'usgs' OR e.also_in_usgs)")
    if region:
        clauses.append("e.region_code = %(region)s")
        params["region"] = region
    return (" AND " + " AND ".join(clauses)) if clauses else "", params


@router.get("/tiles/events/{z}/{x}/{y}.pbf")
def event_tiles(
    z: int, x: int, y: int,
    year_min: int | None = None, year_max: int | None = None,
    mw_min: float | None = None, depth_min: float | None = None, depth_max: float | None = None,
    source: Literal["ambas", "csn", "usgs"] = "ambas", region: str | None = None,
):
    """Tesela vectorial (MVT) de sismos generada por PostGIS con ST_AsMVT."""
    where, params = _filters(year_min, year_max, mw_min, depth_min, depth_max, source, region)
    params.update(z=z, x=x, y=y)
    sql = f"""
        WITH bounds AS (
            SELECT ST_TileEnvelope(%(z)s, %(x)s, %(y)s) AS merc,
                   ST_Transform(ST_TileEnvelope(%(z)s, %(x)s, %(y)s, margin => 0.02), 4326) AS geo
        ),
        tile AS (
            SELECT
                ST_AsMVTGeom(ST_Transform(e.geom, 3857), bounds.merc, 4096, 16, true) AS geom,
                e.earthquake_event_id AS id,
                e.mw_homogenized::float AS mw,
                e.depth_km::float AS depth,
                extract(year FROM e.occurred_at)::int AS year,
                e.source_code AS src
            FROM seismic.v_event_location_unique AS e, bounds
            WHERE e.geom && bounds.geo{where}
            ORDER BY e.mw_homogenized NULLS FIRST
        )
        SELECT ST_AsMVT(tile.*, 'events', 4096, 'geom', 'id') FROM tile
    """
    with pool.connection() as connection:
        with connection.cursor(row_factory=tuple_row) as cursor:
            data = cursor.execute(sql, params).fetchone()[0]
    return Response(content=bytes(data or b""), media_type="application/vnd.mapbox-vector-tile")


@router.get("/api/events/count")
def event_count(
    year_min: int | None = None, year_max: int | None = None,
    mw_min: float | None = None, depth_min: float | None = None, depth_max: float | None = None,
    source: Literal["ambas", "csn", "usgs"] = "ambas", region: str | None = None,
):
    where, params = _filters(year_min, year_max, mw_min, depth_min, depth_max, source, region)
    return fetch_one(f"SELECT count(*) AS events FROM seismic.v_event_location_unique AS e WHERE true{where}",
                     params)


@router.get("/api/events/largest")
def largest_on(date: str = Query(..., pattern=r"^\d{4}-\d{2}-\d{2}$")):
    """El sismo de mayor Mw de un día (para abrir la interfaz con el Maule seleccionado)."""
    row = fetch_one("""
        SELECT earthquake_event_id AS id FROM seismic.v_event_location_unique
        WHERE occurred_at >= %(d)s::date AND occurred_at < %(d)s::date + 1
        ORDER BY mw_homogenized DESC NULLS LAST LIMIT 1
    """, {"d": date})
    if not row:
        raise HTTPException(404, "No hay sismos ese día")
    return row


@router.get("/api/events/{event_id}")
def event_detail(event_id: int):
    """Ficha de un sismo: ubicación, magnitudes, comuna, ciudad cercana, población e impacto."""
    row = fetch_one("""
        SELECT
            e.earthquake_event_id AS id, e.source_code AS source, e.source_event_id,
            e.occurred_at, e.magnitude::float, e.magnitude_type, e.mw_homogenized::float AS mw,
            e.mw_method, e.depth_km::float AS depth_km,
            e.commune_name, e.region_name, e.assignment_method, e.distance_km::float AS commune_km,
            e.also_in_usgs, ST_X(e.geom) AS lon, ST_Y(e.geom) AS lat,
            x.population_25km, x.population_50km, x.population_100km,
            u.name AS urban_name, link.epicentral_distance_km::float AS urban_km,
            link.hypocentral_distance_km::float AS urban_hypo_km,
            impact.max_mmi::float, impact.max_cdi::float, impact.pager_alert, impact.has_shakemap,
            usgs.mw_homogenized::float AS usgs_mw, usgs.source_event_id AS usgs_event_id,
            role.role AS sequence_role
        FROM seismic.v_event_location_unique AS e
        LEFT JOIN seismic.event_population_exposure AS x USING (earthquake_event_id)
        LEFT JOIN seismic.event_urban_area AS link
               ON link.earthquake_event_id = e.earthquake_event_id AND link.distance_rank = 1
        LEFT JOIN seismic.urban_area AS u ON u.urban_area_id = link.urban_area_id
        LEFT JOIN seismic.event_match AS pair ON pair.csn_event_id = e.earthquake_event_id
        LEFT JOIN seismic.earthquake_event AS usgs ON usgs.earthquake_event_id = pair.usgs_event_id
        LEFT JOIN seismic.event_impact_summary AS impact
               ON impact.earthquake_event_id = coalesce(pair.usgs_event_id, e.earthquake_event_id)
        LEFT JOIN LATERAL (
            SELECT r.role FROM seismic.event_sequence_role AS r
            WHERE r.earthquake_event_id = e.earthquake_event_id
            ORDER BY r.declustering_run_id DESC LIMIT 1
        ) AS role ON true
        WHERE e.earthquake_event_id = %(id)s
    """, {"id": event_id})
    if not row:
        raise HTTPException(404, "Sismo no encontrado (o es el duplicado USGS de un sismo del CSN)")
    return row


@router.get("/api/stats/summary")
def summary():
    return fetch_one("""
        SELECT
            (SELECT count(*) FROM seismic.v_event_location_unique) AS unique_events,
            (SELECT count(*) FROM seismic.earthquake_event) AS records,
            (SELECT count(*) FROM seismic.event_match) AS pairs,
            (SELECT min(extract(year FROM occurred_at))::int FROM seismic.earthquake_event) AS first_year,
            (SELECT max(extract(year FROM occurred_at))::int FROM seismic.earthquake_event) AS last_year
    """)


@router.get("/api/stats/years")
def per_year(mw_min: float = 4.0, year_min: int = 1906):
    """Sismos únicos por año (histograma de la línea de tiempo)."""
    return fetch_all("""
        SELECT year, count(e.*) FILTER (WHERE e.mw_homogenized >= %(mw)s) AS events
        FROM generate_series(%(y0)s, extract(year FROM now())::int) AS year
        LEFT JOIN seismic.v_event_location_unique AS e
               ON e.occurred_at >= make_date(year, 1, 1) AND e.occurred_at < make_date(year + 1, 1, 1)
        GROUP BY year ORDER BY year
    """, {"mw": mw_min, "y0": year_min})
