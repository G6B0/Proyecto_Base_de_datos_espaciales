"""Regiones y comunas como GeoJSON simplificado (son estáticas: se guardan en memoria)."""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from fastapi import APIRouter, Response

from ..db import fetch_all, fetch_one

router = APIRouter()

TOLERANCE = {"region": 0.01, "province": 0.008, "commune": 0.004}


@lru_cache(maxsize=4)
def _areas_geojson(level: str) -> str:
    row = fetch_one("""
        SELECT json_build_object(
            'type', 'FeatureCollection',
            'features', coalesce(json_agg(json_build_object(
                'type', 'Feature',
                'id', a.administrative_area_id,
                'properties', json_build_object('code', a.official_code, 'name', a.name,
                                                'area_km2', round(a.official_area_km2)),
                -- ST_Simplify (Douglas-Peucker) tarda 0,2 s; ST_SimplifyPreserveTopology
                -- sobre los 6 millones de vértices 1:50.000 superaba los 30 s.
                'geometry', ST_AsGeoJSON(ST_Simplify(a.geom, %(tol)s, true), 4)::json
            )), '[]'::json)
        )::text AS geojson
        FROM seismic.administrative_area AS a
        WHERE a.level = %(level)s
    """, {"level": level, "tol": TOLERANCE[level]})
    return row["geojson"]


@lru_cache(maxsize=1)
def _regions() -> list[dict]:
    return fetch_all("""
        SELECT official_code AS code, name,
               round(ST_XMin(geom)::numeric, 3)::float AS west, round(ST_YMin(geom)::numeric, 3)::float AS south,
               round(ST_XMax(geom)::numeric, 3)::float AS east, round(ST_YMax(geom)::numeric, 3)::float AS north
        FROM seismic.administrative_area
        WHERE level = 'region'
        ORDER BY ST_Y(ST_PointOnSurface(geom)) DESC
    """)


@router.get("/api/regions")
def regions():
    """Las 16 regiones de norte a sur, con su rectángulo para hacer zoom."""
    return _regions()


@router.get("/api/areas")
def areas(level: Literal["region", "province", "commune"] = "region"):
    return Response(content=_areas_geojson(level), media_type="application/geo+json")
