"""Download and normalize USGS ComCat earthquakes for continental Chile.

The script keeps the original GeoJSON response for provenance and creates a
two-dimensional GeoJSON plus CSV for QGIS/PostGIS. Depth is stored as an
attribute because USGS encodes it as the third GeoJSON coordinate.
"""

from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw" / "usgs"
PROCESSED_DIR = ROOT / "data" / "processed" / "usgs"
API_BASE = "https://earthquake.usgs.gov/fdsnws/event/1"
API_LIMIT = 20_000
DEFAULT_BBOX = (-76.0, -56.0, -66.0, -17.0)  # west, south, east, north
USER_AGENT = "chile-spatial-earthquake-project/1.0"


def parse_datetime(value: str) -> datetime:
    """Parse an ISO date or timestamp and return an aware UTC datetime."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso_utc(value: datetime) -> str:
    """Format a datetime in the UTC representation accepted by USGS."""
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def timestamp_ms_to_iso(value: int | float | None) -> str | None:
    if value is None:
        return None
    return iso_utc(datetime.fromtimestamp(value / 1000, tz=timezone.utc))


def request_text(path: str, parameters: dict[str, Any]) -> tuple[str, str]:
    url = f"{API_BASE}/{path}?{urlencode(parameters)}"
    request = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=60) as response:
            return response.read().decode("utf-8"), url
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"USGS returned HTTP {error.code}: {detail}") from error
    except URLError as error:
        raise RuntimeError(f"Could not connect to USGS: {error.reason}") from error


def base_parameters(
    start: datetime,
    end: datetime,
    bbox: tuple[float, float, float, float],
    min_magnitude: float,
    review_status: str,
) -> dict[str, Any]:
    west, south, east, north = bbox
    parameters: dict[str, Any] = {
        "starttime": iso_utc(start),
        "endtime": iso_utc(end),
        "minlongitude": west,
        "minlatitude": south,
        "maxlongitude": east,
        "maxlatitude": north,
        "minmagnitude": min_magnitude,
        "eventtype": "earthquake",
    }
    if review_status != "all":
        parameters["reviewstatus"] = review_status
    return parameters


def fetch_interval(
    start: datetime,
    end: datetime,
    bbox: tuple[float, float, float, float],
    min_magnitude: float,
    review_status: str,
    request_log: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    parameters = base_parameters(start, end, bbox, min_magnitude, review_status)
    count_text, count_url = request_text("count", parameters)
    count = int(count_text.strip())
    request_log.append({"kind": "count", "url": count_url, "events": count})

    if count >= API_LIMIT:
        if end - start <= timedelta(seconds=1):
            raise RuntimeError(
                "More than 20,000 events share a one-second interval; "
                "increase the minimum magnitude or narrow the bounding box."
            )
        midpoint = start + (end - start) / 2
        return fetch_interval(
            start,
            midpoint,
            bbox,
            min_magnitude,
            review_status,
            request_log,
        ) + fetch_interval(
            midpoint,
            end,
            bbox,
            min_magnitude,
            review_status,
            request_log,
        )

    query_parameters = {
        **parameters,
        "format": "geojson",
        "orderby": "time-asc",
        "limit": API_LIMIT,
    }
    payload_text, query_url = request_text("query", query_parameters)
    payload = json.loads(payload_text)
    features = payload.get("features", [])
    request_log.append({"kind": "query", "url": query_url, "events": len(features)})
    return features


def normalize_feature(feature: dict[str, Any]) -> dict[str, Any]:
    event_id = str(feature["id"])
    properties = feature.get("properties") or {}
    geometry = feature.get("geometry") or {}
    coordinates = geometry.get("coordinates") or []
    if len(coordinates) < 2:
        raise ValueError(f"Event {event_id} has no usable coordinates")

    longitude = float(coordinates[0])
    latitude = float(coordinates[1])
    depth_km = float(coordinates[2]) if len(coordinates) > 2 else None

    normalized_properties = {
        "source": "USGS ComCat",
        "source_event_id": event_id,
        "occurred_at_utc": timestamp_ms_to_iso(properties.get("time")),
        "updated_at_utc": timestamp_ms_to_iso(properties.get("updated")),
        "magnitude": properties.get("mag"),
        "magnitude_type": properties.get("magType"),
        "depth_km": depth_km,
        "place": properties.get("place"),
        "review_status": properties.get("status"),
        "tsunami": bool(properties.get("tsunami", 0)),
        "significance": properties.get("sig"),
        "felt_reports": properties.get("felt"),
        "station_count": properties.get("nst"),
        "azimuthal_gap_deg": properties.get("gap"),
        "min_distance_deg": properties.get("dmin"),
        "rms_seconds": properties.get("rms"),
        "horizontal_error_km": properties.get("horizontalError"),
        "depth_error_km": properties.get("depthError"),
        "magnitude_error": properties.get("magError"),
        "network": properties.get("net"),
        "location_source": properties.get("locationSource"),
        "magnitude_source": properties.get("magSource"),
        "event_type": properties.get("type"),
        "source_url": properties.get("url"),
    }
    return {
        "type": "Feature",
        "id": event_id,
        "geometry": {"type": "Point", "coordinates": [longitude, latitude]},
        "properties": normalized_properties,
    }


def write_outputs(
    features: list[dict[str, Any]],
    raw_features: list[dict[str, Any]],
    output_stem: str,
    metadata: dict[str, Any],
) -> tuple[Path, Path, Path, Path]:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

    raw_path = RAW_DIR / f"{output_stem}_raw.geojson"
    geojson_path = PROCESSED_DIR / f"{output_stem}.geojson"
    csv_path = PROCESSED_DIR / f"{output_stem}.csv"
    metadata_path = PROCESSED_DIR / f"{output_stem}_metadata.json"

    raw_collection = {
        "type": "FeatureCollection",
        "metadata": metadata,
        "features": raw_features,
    }
    raw_path.write_text(
        json.dumps(raw_collection, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    collection = {
        "type": "FeatureCollection",
        "name": output_stem,
        "crs": {"type": "name", "properties": {"name": "urn:ogc:def:crs:OGC:1.3:CRS84"}},
        "features": features,
    }
    geojson_path.write_text(
        json.dumps(collection, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    fieldnames = ["longitude", "latitude", *features[0]["properties"].keys()] if features else [
        "longitude",
        "latitude",
        "source",
        "source_event_id",
        "occurred_at_utc",
        "updated_at_utc",
        "magnitude",
        "magnitude_type",
        "depth_km",
        "place",
        "review_status",
    ]
    with csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        for feature in features:
            longitude, latitude = feature["geometry"]["coordinates"]
            writer.writerow(
                {"longitude": longitude, "latitude": latitude, **feature["properties"]}
            )

    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return raw_path, geojson_path, csv_path, metadata_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download USGS earthquakes for continental Chile."
    )
    parser.add_argument("--start", help="UTC start date or ISO timestamp")
    parser.add_argument("--end", help="UTC end date or ISO timestamp")
    parser.add_argument("--min-magnitude", type=float, default=2.5)
    parser.add_argument(
        "--bbox",
        nargs=4,
        type=float,
        metavar=("WEST", "SOUTH", "EAST", "NORTH"),
        default=DEFAULT_BBOX,
    )
    parser.add_argument(
        "--review-status",
        choices=("all", "automatic", "reviewed"),
        default="all",
    )
    parser.add_argument("--output-stem", help="Optional output filename stem")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    end = parse_datetime(args.end) if args.end else datetime.now(timezone.utc)
    start = parse_datetime(args.start) if args.start else end - timedelta(days=30)
    if start >= end:
        raise ValueError("--start must be earlier than --end")

    bbox = tuple(args.bbox)
    west, south, east, north = bbox
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise ValueError("Invalid bounding box; expected WEST SOUTH EAST NORTH")

    request_log: list[dict[str, Any]] = []
    raw_features = fetch_interval(
        start,
        end,
        bbox,
        args.min_magnitude,
        args.review_status,
        request_log,
    )

    # Adjacent inclusive intervals can return the boundary event twice. Keep the
    # newest USGS revision for each stable event identifier.
    by_id: dict[str, dict[str, Any]] = {}
    for feature in raw_features:
        event_id = str(feature["id"])
        previous = by_id.get(event_id)
        current_updated = (feature.get("properties") or {}).get("updated") or 0
        previous_updated = ((previous or {}).get("properties") or {}).get("updated") or 0
        if previous is None or current_updated >= previous_updated:
            by_id[event_id] = feature

    deduplicated_raw = sorted(
        by_id.values(),
        key=lambda feature: (feature.get("properties") or {}).get("time") or 0,
    )
    normalized = [normalize_feature(feature) for feature in deduplicated_raw]

    date_token_start = start.strftime("%Y%m%d")
    date_token_end = end.strftime("%Y%m%d")
    output_stem = args.output_stem or (
        f"usgs_earthquakes_chile_m{args.min_magnitude:g}_{date_token_start}_{date_token_end}"
    )
    metadata = {
        "title": "USGS earthquakes in the continental Chile bounding box",
        "source": "USGS ANSS Comprehensive Earthquake Catalog (ComCat)",
        "api_documentation": "https://earthquake.usgs.gov/fdsnws/event/1/",
        "retrieved_at_utc": iso_utc(datetime.now(timezone.utc)),
        "start_utc": iso_utc(start),
        "end_utc": iso_utc(end),
        "minimum_magnitude": args.min_magnitude,
        "review_status": args.review_status,
        "bounding_box_west_south_east_north": list(bbox),
        "spatial_reference": "OGC:CRS84 / EPSG:4326 coordinate values",
        "event_count": len(normalized),
        "request_log": request_log,
        "notes": [
            "The bounding box includes oceanic and neighboring-country events.",
            "Recent events may be preliminary and can be revised or deleted.",
            "Processed geometry is 2D; depth is stored separately in depth_km.",
            "Magnitude values preserve the original USGS magnitude type.",
        ],
    }

    paths = write_outputs(normalized, deduplicated_raw, output_stem, metadata)
    print(json.dumps(metadata, ensure_ascii=False, indent=2))
    for label, path in zip(("Raw", "GeoJSON", "CSV", "Metadata"), paths):
        print(f"{label}: {path}")


if __name__ == "__main__":
    main()
