"""Download and normalize historical and recent CSN earthquake catalogues.

The historical CSV provides long-term coverage but currently stops in June
2025. Recent events are published in one official HTML page per UTC day. This
script combines both products, keeps the raw inputs for provenance and writes a
single CSV/GeoJSON pair consumed by the PostGIS loader.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import time
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterator
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw" / "csn"
RAW_DAILY_DIR = RAW_DIR / "daily"
PROCESSED_DIR = ROOT / "data" / "processed" / "csn"
CATALOG_URL = "https://owl.csn.uchile.cl/catalogo_csn.csv"
DAILY_URL_TEMPLATE = (
    "https://www.sismologia.cl/sismicidad/catalogo/"
    "{year:04d}/{month:02d}/{token}.html"
)
REPORT_BASE_URL = "https://www.sismologia.cl"
TERMS_URL = "https://sismologia.cl/accesos/uso-de-datos.html"
OUTPUT_STEM = "csn_earthquake_catalog"
USER_AGENT = "chile-spatial-earthquake-project/1.1 (academic use)"
DEFAULT_RECENT_START = date(2025, 6, 24)
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
CSN_PROPERTY_FIELDS = [
    "source",
    "source_event_id",
    "source_catalog_id",
    "occurred_at_utc",
    "updated_at_utc",
    "magnitude",
    "magnitude_type",
    "reported_magnitude",
    "reported_magnitude_type",
    "magnitude_error",
    "magnitude_agency",
    "depth_km",
    "author",
    "place",
    "review_status",
    "event_type",
    "source_url",
]


class DailyCatalogueParser(HTMLParser):
    """Extract event rows from the official CSN daily catalogue table."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.in_catalogue_table = False
        self.table_depth = 0
        self.in_row = False
        self.in_cell = False
        self.current_cell: list[str] = []
        self.current_cells: list[str] = []
        self.current_href: str | None = None
        self.current_row_href: str | None = None
        self.rows: list[tuple[list[str], str | None]] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        attributes = dict(attrs)
        if tag == "table":
            classes = set((attributes.get("class") or "").split())
            if not self.in_catalogue_table and {"sismologia", "detalle"} <= classes:
                self.in_catalogue_table = True
                self.table_depth = 1
                return
            if self.in_catalogue_table:
                self.table_depth += 1
        if not self.in_catalogue_table:
            return
        if tag == "tr":
            self.in_row = True
            self.current_cells = []
            self.current_row_href = None
        elif tag == "td" and self.in_row:
            self.in_cell = True
            self.current_cell = []
            self.current_href = None
        elif tag == "a" and self.in_cell:
            self.current_href = attributes.get("href")
        elif tag == "br" and self.in_cell:
            self.current_cell.append(" ")

    def handle_data(self, data: str) -> None:
        if self.in_catalogue_table and self.in_cell:
            self.current_cell.append(data)

    def handle_endtag(self, tag: str) -> None:
        if not self.in_catalogue_table:
            return
        if tag == "td" and self.in_cell:
            value = " ".join("".join(self.current_cell).split())
            self.current_cells.append(value)
            if self.current_href and self.current_row_href is None:
                self.current_row_href = self.current_href
            self.in_cell = False
        elif tag == "tr" and self.in_row:
            if len(self.current_cells) == 5:
                self.rows.append((self.current_cells, self.current_row_href))
            self.in_row = False
        elif tag == "table":
            self.table_depth -= 1
            if self.table_depth == 0:
                self.in_catalogue_table = False


def optional_float(value: str | None) -> float | None:
    if value is None or value.strip() == "":
        return None
    return float(value)


def utc_text(value: str) -> str:
    parsed = datetime.fromisoformat(value.strip().replace(" ", "T"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def stable_historical_event_id(row: dict[str, str]) -> str:
    """Create a deterministic key because id_ori is not always unique."""
    identity = "|".join(
        row.get(field, "")
        for field in ("id_ori", "datetime", "lon", "lat", "depth", "mag", "author")
    )
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]
    return f"csn-{digest}"


def normalize_historical_row(row: dict[str, str]) -> dict[str, Any]:
    longitude = float(row["lon"])
    latitude = float(row["lat"])
    validate_coordinates(longitude, latitude, row.get("id_ori"))

    converted_magnitude = optional_float(row.get("MWconv"))
    reported_magnitude = optional_float(row.get("mag"))
    preferred_magnitude = (
        converted_magnitude if converted_magnitude is not None else reported_magnitude
    )
    preferred_type = "MWconv" if converted_magnitude is not None else row.get("mag_type")
    properties = {
        "source": "CSN historical catalogue",
        "source_event_id": stable_historical_event_id(row),
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
        "place": None,
        "review_status": "historical_catalogue",
        "event_type": "earthquake",
        "source_url": None,
    }
    return point_feature(longitude, latitude, properties)


def validate_coordinates(
    longitude: float, latitude: float, identifier: str | None
) -> None:
    if not (-180 <= longitude <= 180 and -90 <= latitude <= 90):
        raise ValueError(f"Invalid coordinates in CSN event {identifier}")


def point_feature(
    longitude: float, latitude: float, properties: dict[str, Any]
) -> dict[str, Any]:
    return {
        "type": "Feature",
        "id": properties["source_event_id"],
        "geometry": {"type": "Point", "coordinates": [longitude, latitude]},
        "properties": properties,
    }


def request_bytes(url: str, timeout: int = 120) -> tuple[bytes, dict[str, str]]:
    request = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=timeout) as response:
            headers = {key.lower(): value for key, value in response.headers.items()}
            return response.read(), headers
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"CSN returned HTTP {error.code} for {url}: {detail}") from error
    except URLError as error:
        raise RuntimeError(f"Could not connect to CSN at {url}: {error.reason}") from error


def download_historical_catalogue() -> tuple[bytes, dict[str, str]]:
    return request_bytes(CATALOG_URL)


def parse_historical_catalogue(
    payload: bytes,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
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
        feature = normalize_historical_row(row)
        event_id = feature["properties"]["source_event_id"]
        if event_id in normalized_by_id:
            exact_duplicates += 1
        normalized_by_id[event_id] = feature
    return list(normalized_by_id.values()), {
        "source_rows": source_rows,
        "exact_duplicates_removed": exact_duplicates,
    }


def iter_days(start: date, end: date) -> Iterator[date]:
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def daily_page_url(day: date) -> str:
    return DAILY_URL_TEMPLATE.format(
        year=day.year,
        month=day.month,
        token=day.strftime("%Y%m%d"),
    )


def daily_cache_path(day: date) -> Path:
    return (
        RAW_DAILY_DIR
        / f"{day.year:04d}"
        / f"{day.month:02d}"
        / f"{day.strftime('%Y%m%d')}.html"
    )


def get_daily_page(day: date, refresh: bool) -> tuple[str | None, bool]:
    cache_path = daily_cache_path(day)
    if cache_path.exists() and not refresh:
        return cache_path.read_text(encoding="utf-8"), False

    url = daily_page_url(day)
    try:
        payload, _ = request_bytes(url, timeout=60)
    except RuntimeError as error:
        if "HTTP 404" in str(error):
            return None, True
        raise
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_bytes(payload)
    return payload.decode("utf-8"), True


def parse_daily_page(html: str, page_url: str) -> list[dict[str, Any]]:
    parser = DailyCatalogueParser()
    parser.feed(html)
    features: list[dict[str, Any]] = []
    for cells, href in parser.rows:
        if href is None:
            raise RuntimeError(f"CSN daily row has no report link in {page_url}")
        report_match = re.search(r"/(\d+)\.html$", href)
        if not report_match:
            raise RuntimeError(f"Unexpected CSN report link {href!r} in {page_url}")
        report_id = report_match.group(1)

        local_and_place, occurred_at, coordinates, depth, magnitude = cells
        local_match = re.match(
            r"^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s*(.*)$",
            local_and_place,
        )
        place = local_match.group(1).strip() if local_match else local_and_place

        coordinate_values = re.findall(r"-?\d+(?:\.\d+)?", coordinates)
        if len(coordinate_values) != 2:
            raise RuntimeError(
                f"Unexpected CSN coordinates {coordinates!r} in {page_url}"
            )
        latitude, longitude = map(float, coordinate_values)
        validate_coordinates(longitude, latitude, report_id)

        depth_match = re.search(r"-?\d+(?:\.\d+)?", depth)
        magnitude_match = re.match(
            r"^(-?\d+(?:\.\d+)?)\s*([^\s]+)?$", magnitude.strip()
        )
        if depth_match is None or magnitude_match is None:
            raise RuntimeError(
                f"Unexpected CSN depth or magnitude in report {report_id}"
            )
        depth_km = float(depth_match.group())
        magnitude_value = float(magnitude_match.group(1))
        magnitude_type = magnitude_match.group(2)
        report_url = urljoin(REPORT_BASE_URL, href)
        properties = {
            "source": "CSN daily catalogue",
            "source_event_id": f"csn-report-{report_id}",
            "source_catalog_id": report_id,
            "occurred_at_utc": utc_text(occurred_at),
            "updated_at_utc": None,
            "magnitude": magnitude_value,
            "magnitude_type": magnitude_type,
            "reported_magnitude": magnitude_value,
            "reported_magnitude_type": magnitude_type,
            "magnitude_error": None,
            "magnitude_agency": "CSN",
            "depth_km": depth_km,
            "author": "CSN",
            "place": place or None,
            "review_status": "published",
            "event_type": "earthquake",
            "source_url": report_url,
        }
        features.append(point_feature(longitude, latitude, properties))
    return features


def feature_signature(feature: dict[str, Any]) -> tuple[str, float, float]:
    longitude, latitude = feature["geometry"]["coordinates"]
    return (
        feature["properties"]["occurred_at_utc"],
        round(float(longitude), 2),
        round(float(latitude), 2),
    )


def merge_features(
    historical: list[dict[str, Any]], recent: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], int]:
    merged_by_id = {
        feature["properties"]["source_event_id"]: feature for feature in historical
    }
    historical_signatures = {feature_signature(feature) for feature in historical}
    overlap_count = 0
    for feature in recent:
        if feature_signature(feature) in historical_signatures:
            overlap_count += 1
            continue
        merged_by_id[feature["properties"]["source_event_id"]] = feature
    return sorted(
        merged_by_id.values(),
        key=lambda feature: feature["properties"]["occurred_at_utc"],
    ), overlap_count


def write_outputs(
    features: list[dict[str, Any]], metadata: dict[str, Any]
) -> tuple[Path, Path, Path]:
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    geojson_path = PROCESSED_DIR / f"{OUTPUT_STEM}.geojson"
    csv_path = PROCESSED_DIR / f"{OUTPUT_STEM}.csv"
    metadata_path = PROCESSED_DIR / f"{OUTPUT_STEM}_metadata.json"

    collection = {
        "type": "FeatureCollection",
        "name": OUTPUT_STEM,
        "crs": {
            "type": "name",
            "properties": {"name": "urn:ogc:def:crs:OGC:1.3:CRS84"},
        },
        "features": features,
    }
    geojson_path.write_text(
        json.dumps(collection, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    fieldnames = ["longitude", "latitude", *CSN_PROPERTY_FIELDS]
    with csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        for feature in features:
            longitude, latitude = feature["geometry"]["coordinates"]
            writer.writerow(
                {
                    "longitude": longitude,
                    "latitude": latitude,
                    **feature["properties"],
                }
            )

    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return geojson_path, csv_path, metadata_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download and combine historical and daily CSN earthquakes."
    )
    parser.add_argument(
        "--recent-start",
        type=date.fromisoformat,
        default=DEFAULT_RECENT_START,
        help="First UTC daily catalogue date (default: 2025-06-24)",
    )
    parser.add_argument(
        "--recent-end",
        type=date.fromisoformat,
        default=datetime.now(timezone.utc).date(),
        help="Last UTC daily catalogue date (default: today)",
    )
    parser.add_argument(
        "--refresh-days",
        type=int,
        default=7,
        help="Redownload this many final days to capture revisions (default: 7)",
    )
    parser.add_argument(
        "--request-delay",
        type=float,
        default=0.2,
        help="Seconds between new daily-page requests (default: 0.2)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.recent_start > args.recent_end:
        raise ValueError("--recent-start must not be later than --recent-end")
    if args.refresh_days < 0 or args.request_delay < 0:
        raise ValueError("--refresh-days and --request-delay must be non-negative")

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    payload, response_headers = download_historical_catalogue()
    raw_path = RAW_DIR / f"{OUTPUT_STEM}_raw.csv"
    raw_path.write_bytes(payload)
    historical, historical_stats = parse_historical_catalogue(payload)
    if not historical:
        raise RuntimeError("The CSN historical catalogue did not contain any events")

    recent_features: list[dict[str, Any]] = []
    missing_pages: list[str] = []
    downloaded_pages = 0
    cached_pages = 0
    days = list(iter_days(args.recent_start, args.recent_end))
    refresh_from = args.recent_end - timedelta(days=max(args.refresh_days - 1, 0))
    for index, day in enumerate(days, start=1):
        refresh = args.refresh_days > 0 and day >= refresh_from
        html, downloaded = get_daily_page(day, refresh=refresh)
        if downloaded:
            downloaded_pages += 1
            if index < len(days) and args.request_delay:
                time.sleep(args.request_delay)
        else:
            cached_pages += 1
        if html is None:
            missing_pages.append(day.isoformat())
            continue
        recent_features.extend(parse_daily_page(html, daily_page_url(day)))
        if index % 25 == 0 or index == len(days):
            print(
                f"CSN daily pages: {index}/{len(days)}; "
                f"events parsed: {len(recent_features)}",
                flush=True,
            )

    features, overlap_count = merge_features(historical, recent_features)
    if not features:
        raise RuntimeError("The combined CSN catalogue did not contain any events")

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
        "title": "Combined historical and daily earthquake catalogue of CSN Chile",
        "source": "Centro Sismologico Nacional de la Universidad de Chile",
        "historical_catalog_url": CATALOG_URL,
        "daily_catalogue_url_template": DAILY_URL_TEMPLATE,
        "terms_url": TERMS_URL,
        "retrieved_at_utc": datetime.now(timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "spatial_reference": "OGC:CRS84 / EPSG:4326 coordinate values",
        "historical_source_rows": historical_stats["source_rows"],
        "historical_event_count": len(historical),
        "historical_exact_duplicates_removed": historical_stats[
            "exact_duplicates_removed"
        ],
        "daily_start_utc": args.recent_start.isoformat(),
        "daily_end_utc": args.recent_end.isoformat(),
        "daily_page_count": len(days),
        "daily_pages_downloaded": downloaded_pages,
        "daily_pages_from_cache": cached_pages,
        "daily_missing_pages": missing_pages,
        "daily_event_count": len(recent_features),
        "cross_catalogue_overlaps_removed": overlap_count,
        "event_count": len(features),
        "earliest_event_utc": features[0]["properties"]["occurred_at_utc"],
        "latest_event_utc": features[-1]["properties"]["occurred_at_utc"],
        "minimum_magnitude": min(magnitudes),
        "maximum_magnitude": max(magnitudes),
        "minimum_depth_km": min(depths),
        "maximum_depth_km": max(depths),
        "events_without_depth": len(features) - len(depths),
        "historical_http_last_modified": response_headers.get("last-modified"),
        "historical_http_etag": response_headers.get("etag"),
        "notes": [
            "Historical CSV times and daily-page UTC columns are interpreted as UTC.",
            "Historical MWconv is retained as preferred magnitude with the original value.",
            "Recent events retain the magnitude value and type published on the CSN page.",
            "Daily report IDs are used as stable source identifiers.",
            "Recent pages can be revised; the final configured days are refreshed each run.",
            "Academic use requires citing the Centro Sismologico Nacional de la Universidad de Chile.",
        ],
    }
    paths = write_outputs(features, metadata)

    print(json.dumps(metadata, ensure_ascii=False, indent=2))
    print(f"Historical raw CSV: {raw_path}")
    print(f"Daily raw HTML: {RAW_DAILY_DIR}")
    for label, path in zip(("GeoJSON", "CSV", "Metadata"), paths):
        print(f"{label}: {path}")


if __name__ == "__main__":
    main()
