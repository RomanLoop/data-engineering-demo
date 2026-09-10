#!/usr/bin/env python3
"""Simulate a delta load for the Contoso `store` entity.

Same Stage-1 stopgap pattern as contoso_customers.py (AGENT.md §4).

Usage:
    python scripts/simulate_delta_load/contoso_store.py \\
        --new 2 --updated 5 \\
        [--csv data/contoso/store.csv] [--seed 42]

    python scripts/upload_to_onelake.py \\
        --local data/contoso/store.csv --remote Files/contoso/store.csv
    dbt run-operation bootstrap_landing_table --args \\
        '{entity: store, csv_path: Files/contoso/store.csv, column_casts: {StoreKey: int, GeoAreaKey: int, OpenDate: date, CloseDate: date, SquareMeters: double}}'

Behavior: appends `--new` brand-new stores with fresh StoreKey values,
mutates `--updated` randomly-chosen existing rows (e.g. sets a CloseDate,
changes Status/SquareMeters) so bronze's dedup-before-insert sees a real
difference.
"""

from __future__ import annotations

import argparse
import csv
import random
import sys
from pathlib import Path

FIELDNAMES = [
    "StoreKey", "StoreCode", "GeoAreaKey", "CountryCode", "CountryName",
    "State", "OpenDate", "CloseDate", "Description", "SquareMeters", "Status",
]

COUNTRIES = [
    ("AU", "Australia"), ("US", "United States"), ("GB", "United Kingdom"),
    ("CA", "Canada"), ("DE", "Germany"),
]
STATUSES = ["", "Closed", "Restructured"]


def read_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_rows(csv_path: Path, rows: list[dict]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def make_new_row(store_key: int, rng: random.Random) -> dict:
    country_code, country_name = rng.choice(COUNTRIES)
    return {
        "StoreKey": store_key,
        "StoreCode": str(store_key),
        "GeoAreaKey": rng.randint(1, 50),
        "CountryCode": country_code,
        "CountryName": country_name,
        "State": "Simulated State",
        "OpenDate": "2026-01-01",
        "CloseDate": "",
        "Description": f"Simulated Store {store_key}",
        "SquareMeters": round(rng.uniform(200, 3000), 0),
        "Status": "",
    }


def mutate_row(row: dict, rng: random.Random) -> dict:
    """Change at least one non-key attribute so the row is a genuine update."""
    row = dict(row)
    field = rng.choice(["Status", "SquareMeters", "CloseDate"])
    if field == "Status":
        row["Status"] = rng.choice(STATUSES)
    elif field == "SquareMeters":
        row["SquareMeters"] = round(float(row["SquareMeters"] or 500) * rng.uniform(0.8, 1.2), 0)
    elif field == "CloseDate":
        row["CloseDate"] = "2026-06-30"
        row["Status"] = "Closed"
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", type=int, default=0, help="number of brand-new store rows to add")
    parser.add_argument("--updated", type=int, default=0, help="number of existing store rows to mutate")
    parser.add_argument("--csv", type=Path, default=Path("data/contoso/store.csv"), help="local landing CSV to read and rewrite")
    parser.add_argument("--seed", type=int, default=None, help="random seed, for reproducible runs")
    args = parser.parse_args()

    if args.new < 0 or args.updated < 0:
        parser.error("--new and --updated must be >= 0")

    rng = random.Random(args.seed)

    if not args.csv.exists():
        parser.error(f"landing CSV not found: {args.csv}")

    rows = read_rows(args.csv)
    existing_keys = {int(r["StoreKey"]) for r in rows}
    by_index = {i: r for i, r in enumerate(rows)}

    updated_count = min(args.updated, len(rows))
    if args.updated > len(rows):
        print(f"warning: --updated {args.updated} exceeds {len(rows)} existing rows; mutating all of them", file=sys.stderr)
    for idx in rng.sample(range(len(rows)), k=updated_count):
        by_index[idx] = mutate_row(by_index[idx], rng)
    rows = [by_index[i] for i in range(len(rows))]

    next_key = max(existing_keys, default=0) + 1
    for i in range(args.new):
        rows.append(make_new_row(next_key + i, rng))

    write_rows(args.csv, rows)
    print(f"OK: +{args.new} new, ~{updated_count} updated, {len(rows)} total rows written to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
