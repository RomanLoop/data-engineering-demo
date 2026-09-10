#!/usr/bin/env python3
"""Simulate a delta load for the Contoso `customers` entity.

Stage-1 stopgap (AGENT.md §4, plan.md Complexity Tracking): there is no
vendor-provided change-data-capture sample for this source (research.md
Decision 4), so this script synthesizes new + updated customer rows itself
and rewrites the local CSV that stands in for the landing zone.

Usage:
    python scripts/simulate_delta_load/contoso_customers.py \\
        --new 500 --updated 200 \\
        [--csv data/contoso/customer.csv] [--seed 42]

    # then re-land the mutated file (native Spark bulk load, not dbt seed
    # — see dbt/macros/bootstrap_landing_customer.sql for why):
    python scripts/upload_to_onelake.py \\
        --local data/contoso/customer.csv --remote Files/contoso/customer.csv
    dbt run-operation bootstrap_landing_customer

Behavior:
    - Reads the existing CSV.
    - Appends `--new` brand-new customer rows with fresh, unused CustomerKey
      values.
    - Mutates `--updated` randomly-chosen existing rows in place (changes at
      least one attribute column, so bronze's dedup-before-insert sees a
      real difference on the next `dbt build`).
    - Writes the full result back to the same file by default (it
      represents the full current landing snapshot, not a diff — bronze's
      own dedup-before-insert macro is what turns this into an append-only
      history).
"""

from __future__ import annotations

import argparse
import csv
import random
import sys
from pathlib import Path

FIELDNAMES = [
    "CustomerKey", "GeoAreaKey", "StartDT", "EndDT", "Continent", "Gender",
    "Title", "GivenName", "MiddleInitial", "Surname", "StreetAddress",
    "City", "State", "StateFull", "ZipCode", "Country", "CountryFull",
    "Birthday", "Age", "Occupation", "Company", "Vehicle", "Latitude",
    "Longitude",
]

FIRST_NAMES = ["Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Sam", "Jamie"]
SURNAMES = ["Nguyen", "Smith", "Garcia", "Müller", "Kowalski", "Dubois", "Rossi", "Tanaka"]
TITLES = ["Mr.", "Ms.", "Mx.", "Dr."]
GENDERS = ["male", "female"]
OCCUPATIONS = ["Data Engineer", "Retail Manager", "Nurse", "Electrician", "Teacher", "Accountant"]
COMPANIES = ["Northwind Traders", "Fabrikam", "Contoso Retail", "Adventure Works", "Tailwind Traders"]
VEHICLES = ["2021 Toyota Corolla", "2019 Ford Focus", "2023 Tesla Model 3", "2018 Honda Civic"]
CITIES = [
    ("Springfield", "IL", "Illinois", "62701", "US", "United States", "North America"),
    ("Richmond", "VIC", "Victoria", "3121", "AU", "Australia", "Australia"),
    ("Leeds", "ENG", "England", "LS1", "GB", "United Kingdom", "Europe"),
    ("Kingston", "ON", "Ontario", "K7L", "CA", "Canada", "North America"),
]


def read_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_rows(csv_path: Path, rows: list[dict]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def make_new_row(customer_key: int, rng: random.Random) -> dict:
    city, state, state_full, zip_code, country, country_full, continent = rng.choice(CITIES)
    birth_year = rng.randint(1950, 2005)
    return {
        "CustomerKey": customer_key,
        "GeoAreaKey": rng.randint(1, 50),
        "StartDT": f"{birth_year + 25}-01-01",
        "EndDT": f"{birth_year + 69}-12-31",
        "Continent": continent,
        "Gender": rng.choice(GENDERS),
        "Title": rng.choice(TITLES),
        "GivenName": rng.choice(FIRST_NAMES),
        "MiddleInitial": rng.choice("ABCDEFGHIJ"),
        "Surname": rng.choice(SURNAMES),
        "StreetAddress": f"{rng.randint(1, 999)} Simulated St",
        "City": city,
        "State": state,
        "StateFull": state_full,
        "ZipCode": zip_code,
        "Country": country,
        "CountryFull": country_full,
        "Birthday": f"{birth_year}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}",
        "Age": 2026 - birth_year,
        "Occupation": rng.choice(OCCUPATIONS),
        "Company": rng.choice(COMPANIES),
        "Vehicle": rng.choice(VEHICLES),
        "Latitude": round(rng.uniform(-60, 60), 6),
        "Longitude": round(rng.uniform(-180, 180), 6),
    }


def mutate_row(row: dict, rng: random.Random) -> dict:
    """Change at least one non-key attribute so the row is a genuine update."""
    row = dict(row)
    field = rng.choice(["Occupation", "Company", "City", "Vehicle"])
    if field == "Occupation":
        row["Occupation"] = rng.choice(OCCUPATIONS)
    elif field == "Company":
        row["Company"] = rng.choice(COMPANIES)
    elif field == "City":
        city, state, state_full, zip_code, country, country_full, continent = rng.choice(CITIES)
        row.update(City=city, State=state, StateFull=state_full, ZipCode=zip_code,
                    Country=country, CountryFull=country_full, Continent=continent)
    elif field == "Vehicle":
        row["Vehicle"] = rng.choice(VEHICLES)
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", type=int, default=0, help="number of brand-new customer rows to add")
    parser.add_argument("--updated", type=int, default=0, help="number of existing customer rows to mutate")
    parser.add_argument("--csv", type=Path, default=Path("data/contoso/customer.csv"), help="local landing CSV to read and rewrite")
    parser.add_argument("--seed", type=int, default=None, help="random seed, for reproducible runs")
    args = parser.parse_args()

    if args.new < 0 or args.updated < 0:
        parser.error("--new and --updated must be >= 0")

    rng = random.Random(args.seed)

    if not args.csv.exists():
        parser.error(f"landing CSV not found: {args.csv}")

    rows = read_rows(args.csv)
    existing_keys = {int(r["CustomerKey"]) for r in rows}
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
    print(f"OK: +{args.new} new, ~{updated_count} updated (some may have re-rolled the same value), "
          f"{len(rows)} total rows written to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
