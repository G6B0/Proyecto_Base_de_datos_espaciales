"""Download the data needed to validate the provisional CSN Ml/Mlv -> Mw formula.

See docs/MAGNITUDES.md (sections 8 and 10). Two independent checks:

1. CSN daily pages from the year BEFORE 2025-06-24. In that period the same
   earthquake appears in the daily pages (with its Ml) and in the historical
   catalogue (with MWconv), so the formula can be tested against CSN's own Mw.
2. USGS events from 2025-06-24 onwards. Mlv only exists from 2026 and has no
   historical counterpart, so it is compared against USGS magnitudes instead.

This script only downloads and writes CSV files under
data/diagnostics/magnitude_validation/. It does not modify the processed
catalogue used by the loader. The matching and statistics are done in SQL by
db/validate_ml_conversion.sql.
"""

from __future__ import annotations

import argparse
import csv
import sys
import time
from datetime import date, timedelta
from pathlib import Path
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parent))

import download_csn_catalog as csn  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "data" / "diagnostics" / "magnitude_validation"
USGS_QUERY_URL = "https://earthquake.usgs.gov/fdsnws/event/1/query"
BBOX = (-76.0, -56.0, -66.0, -17.0)  # west, south, east, north (same as downloader)


def download_csn_daily(start: date, end: date, delay: float) -> Path:
    output = OUTPUT_DIR / f"csn_daily_{start:%Y%m%d}_{end:%Y%m%d}.csv"
    days = list(csn.iter_days(start, end))
    rows: list[dict[str, object]] = []
    missing = 0
    for index, day in enumerate(days, start=1):
        html, downloaded = csn.get_daily_page(day, refresh=False)
        if downloaded and delay:
            time.sleep(delay)
        if html is None:
            missing += 1
            continue
        for feature in csn.parse_daily_page(html, csn.daily_page_url(day)):
            properties = feature["properties"]
            longitude, latitude = feature["geometry"]["coordinates"]
            rows.append(
                {
                    "report_id": properties["source_catalog_id"],
                    "occurred_at_utc": properties["occurred_at_utc"],
                    "longitude": longitude,
                    "latitude": latitude,
                    "depth_km": properties["depth_km"],
                    "magnitude": properties["magnitude"],
                    "magnitude_type": properties["magnitude_type"],
                }
            )
        if index % 30 == 0 or index == len(days):
            print(f"CSN pages {index}/{len(days)}; events {len(rows)}", flush=True)

    with output.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=[
                "report_id", "occurred_at_utc", "longitude", "latitude",
                "depth_km", "magnitude", "magnitude_type",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)
    print(f"CSN daily events: {len(rows)} (missing pages: {missing}) -> {output}")
    return output


def download_usgs(start: date, end: date, min_magnitude: float) -> Path:
    output = OUTPUT_DIR / f"usgs_m{min_magnitude:g}_{start:%Y%m%d}_{end:%Y%m%d}.csv"
    west, south, east, north = BBOX
    parameters = {
        "format": "csv",
        "starttime": start.isoformat(),
        "endtime": (end + timedelta(days=1)).isoformat(),
        "minlatitude": south,
        "maxlatitude": north,
        "minlongitude": west,
        "maxlongitude": east,
        "minmagnitude": min_magnitude,
        "eventtype": "earthquake",
        "orderby": "time-asc",
    }
    payload, _ = csn.request_bytes(f"{USGS_QUERY_URL}?{urlencode(parameters)}")
    output.write_bytes(payload)
    events = max(payload.decode("utf-8").count("\n") - 1, 0)
    print(f"USGS events: {events} -> {output}")
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--csn-start", type=date.fromisoformat, default=date(2024, 6, 24))
    parser.add_argument("--csn-end", type=date.fromisoformat, default=date(2025, 6, 23))
    parser.add_argument("--usgs-start", type=date.fromisoformat, default=date(2025, 6, 24))
    parser.add_argument("--usgs-end", type=date.fromisoformat, default=date(2026, 9, 22))
    parser.add_argument("--usgs-min-magnitude", type=float, default=3.5)
    parser.add_argument("--request-delay", type=float, default=0.5)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    download_usgs(args.usgs_start, args.usgs_end, args.usgs_min_magnitude)
    download_csn_daily(args.csn_start, args.csn_end, args.request_delay)


if __name__ == "__main__":
    main()
