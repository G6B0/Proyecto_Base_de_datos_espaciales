"""Download and normalize the public historical earthquake catalogue of CSN.

The catalogue exposes an original magnitude and a converted MWconv value. Both
are retained; the converted value is used as the preferred magnitude for
comparative analysis inside this project.
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw" / "csn"
PROCESSED_DIR = ROOT / "data" / "processed" / "csn"
CATALOG_URL = "https://owl.csn.uchile.cl/catalogo_csn.csv"
OUTPUT_STEM = "csn_earthquake_catalog"
USER_AGENT = "chile-spatial-earthquake-project/1.0"
REQUIRED_FIELDS = {
    "datetime",
    "lon",
    "lat",
    "depth",
    "mag",
    "mag_error",
    "mag_type",
    "mag_agency",
    "author",
    "id_ori",
    "MWconv",
}


def optional_float(value: str | None) -> float | None:
    if value is None or value.strip() == "":
        return None
    return float(value)


def utc_text(value: str) -> str:
    parsed = datetime.fromisoformat(value.strip().replace(" ", "T"))
    return parsed.isoformat(timespec="seconds") + "Z"


def stable_event_id(row: dict[str, str]) -> str:
    """Create a deterministic key because id_ori is not always unique."""
    identity = "|".join(
        row.get(field, "")
        for field in ("id_ori", "datetime", "lon", "lat", "depth", "mag", "author")
    )
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]
    return f"csn-{digest}"


def normalize_row(row: dict[str, str]) -> dict[str, Any]:
    longitude = float(row["lon"])
    latitude = float(row["lat"])
    if not (-180 <= longitude <= 180 and -90 <= latitude <= 90):
        raise ValueError(f"Invalid coordinates in CSN row {row.get('id_ori')}")

    converted_magnitude = optional_float(row.get("MWconv"))
    reported_magnitude = optional_float(row.get("mag"))
    preferred_magnitude = (
        converted_magnitude if converted_magnitude is not None else reported_magnitude
    )
    preferred_type = "MWconv" if converted_magnitude is not None else row.get("mag_type")
    properties = {
        "source": "CSN Chile",
        "source_event_id": stable_event_id(row),
        "source_catalog_id": row.get("id_ori") or None,
        "occurred_at_utc": utc_text(row["datetime"]),
        "updated_at_utc": None,
        "magnitude": preferred_magnitude,
        "magnitude_type": preferred_type,
        "reported_magnitude": reported_magnitude,
        "reported_magnitude_type": row.get("mag_type") or None,
        "magnitude_error": optional_float(row.get("mag_error")),
        "magnitude_agency": row.get("mag_agency") or None,
        "depth_km": optional_float(row.get("depth")),
        "author": row.get("author") or None,
        "review_status": "catalogue",
        "event_type": "earthquake",
    }
    return {
        "type": "Feature",
        "id": properties["source_event_id"],
        "geometry": {"type": "Point", "coordinates": [longitude, latitude]},
        "properties": properties,
    }


def download_catalog() -> tuple[bytes, dict[str, str]]:
    request = Request(CATALOG_URL, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=120) as response:
            headers = {key.lower(): value for key, value in response.headers.items()}
            return response.read(), headers
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"CSN returned HTTP {error.code}: {detail}") from error
    except URLError as error:
        raise RuntimeError(f"Could not connect to CSN: {error.reason}") from error


def main() -> None:
    payload, response_headers = download_catalog()
    text = payload.decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(text))
    fields = set(reader.fieldnames or [])
    missing = REQUIRED_FIELDS - fields
    if missing:
        raise RuntimeError(f"CSN catalogue is missing required fields: {sorted(missing)}")

    normalized_by_id: dict[str, dict[str, Any]] = {}
    source_rows = 0
    exact_duplicates = 0
    for row in reader:
        source_rows += 1
        feature = normalize_row(row)
        event_id = feature["properties"]["source_event_id"]
        if event_id in normalized_by_id:
            exact_duplicates += 1
        normalized_by_id[event_id] = feature

    features = sorted(
        normalized_by_id.values(),
        key=lambda feature: feature["properties"]["occurred_at_utc"],
    )
    if not features:
        raise RuntimeError("The CSN catalogue did not contain any valid events")

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    raw_path = RAW_DIR / f"{OUTPUT_STEM}_raw.csv"
    geojson_path = PROCESSED_DIR / f"{OUTPUT_STEM}.geojson"
    csv_path = PROCESSED_DIR / f"{OUTPUT_STEM}.csv"
    metadata_path = PROCESSED_DIR / f"{OUTPUT_STEM}_metadata.json"
    raw_path.write_bytes(payload)

    collection = {
        "type": "FeatureCollection",
        "name": OUTPUT_STEM,
        "crs": {"type": "name", "properties": {"name": "urn:ogc:def:crs:OGC:1.3:CRS84"}},
        "features": features,
    }
    geojson_path.write_text(
        json.dumps(collection, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    fieldnames = ["longitude", "latitude", *features[0]["properties"].keys()]
    with csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        for feature in features:
            longitude, latitude = feature["geometry"]["coordinates"]
            writer.writerow(
                {"longitude": longitude, "latitude": latitude, **feature["properties"]}
            )

    magnitudes = [
        feature["properties"]["magnitude"]
        for feature in features
        if feature["properties"]["magnitude"] is not None
    ]
    depths = [
        feature["properties"]["depth_km"]
        for feature in features
        if feature["properties"]["depth_km"] is not None
    ]
    metadata = {
        "title": "Historical earthquake catalogue of the Chilean National Seismological Centre",
        "source": "Centro Sismologico Nacional de la Universidad de Chile",
        "catalog_url": CATALOG_URL,
        "visualizer_url": "https://owl.csn.uchile.cl/visualizador_csn.html",
        "terms_url": "https://sismologia.cl/accesos/uso-de-datos.html",
        "retrieved_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "spatial_reference": "OGC:CRS84 / EPSG:4326 coordinate values",
        "source_rows": source_rows,
        "event_count": len(features),
        "exact_duplicates_removed": exact_duplicates,
        "earliest_event_utc": features[0]["properties"]["occurred_at_utc"],
        "latest_event_utc": features[-1]["properties"]["occurred_at_utc"],
        "minimum_magnitude": min(magnitudes),
        "maximum_magnitude": max(magnitudes),
        "minimum_depth_km": min(depths),
        "maximum_depth_km": max(depths),
        "events_without_depth": len(features) - len(depths),
        "http_last_modified": response_headers.get("last-modified"),
        "http_etag": response_headers.get("etag"),
        "notes": [
            "Catalogue times are interpreted as UTC, as stated by the CSN visualizer.",
            "MWconv is used as preferred magnitude while the reported value and type are retained.",
            "source_event_id is a deterministic fingerprint because id_ori is not always unique.",
            "Academic use requires citing the Centro Sismologico Nacional de la Universidad de Chile.",
        ],
    }
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print(json.dumps(metadata, ensure_ascii=False, indent=2))
    print(f"Raw: {raw_path}")
    print(f"GeoJSON: {geojson_path}")
    print(f"CSV: {csv_path}")
    print(f"Metadata: {metadata_path}")


if __name__ == "__main__":
    main()
