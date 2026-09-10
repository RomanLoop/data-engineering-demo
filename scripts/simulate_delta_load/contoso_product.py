#!/usr/bin/env python3
"""Simulate a delta load for the Contoso `product` entity.

Same Stage-1 stopgap pattern as contoso_customers.py (AGENT.md §4): no
vendor-provided change-data-capture sample exists, so this script
synthesizes new + updated product rows itself and rewrites the local CSV
that stands in for the landing zone.

Usage:
    python scripts/simulate_delta_load/contoso_product.py \\
        --new 20 --updated 10 \\
        [--csv data/contoso/product.csv] [--seed 42]

    python scripts/upload_to_onelake.py \\
        --local data/contoso/product.csv --remote Files/contoso/product.csv
    dbt run-operation bootstrap_landing_table --args \\
        '{entity: product, csv_path: Files/contoso/product.csv, column_casts: {ProductKey: int, Weight: double, Cost: double, Price: double, CategoryKey: int, SubCategoryKey: int}}'

Behavior: same as contoso_customers.py — appends `--new` brand-new rows
with fresh ProductKey values, mutates `--updated` randomly-chosen existing
rows in place (changes at least one attribute so bronze's
dedup-before-insert sees a real difference), rewrites the full CSV.
"""

from __future__ import annotations

import argparse
import csv
import random
import sys
from pathlib import Path

FIELDNAMES = [
    "ProductKey", "ProductCode", "ProductName", "Manufacturer", "Brand",
    "Color", "WeightUnit", "Weight", "Cost", "Price", "CategoryKey",
    "CategoryName", "SubCategoryKey", "SubCategoryName",
]

MANUFACTURERS = ["Contoso", "Fabrikam", "Northwind", "Adventure Works", "Tailwind"]
BRANDS = ["Contoso Basic", "Contoso Pro", "Fabrikam Elite", "Northwind Value"]
COLORS = ["Black", "White", "Silver", "Blue", "Red", "Green"]
CATEGORIES = [
    (1, "Computers", 10, "Laptops"),
    (1, "Computers", 11, "Desktops"),
    (2, "Audio", 20, "Headphones"),
    (2, "Audio", 21, "Speakers"),
    (3, "Cameras", 30, "Digital Cameras"),
]


def read_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_rows(csv_path: Path, rows: list[dict]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def make_new_row(product_key: int, rng: random.Random) -> dict:
    category_key, category_name, sub_category_key, sub_category_name = rng.choice(CATEGORIES)
    cost = round(rng.uniform(5, 800), 2)
    return {
        "ProductKey": product_key,
        "ProductCode": f"SIM-{product_key:06d}",
        "ProductName": f"Simulated Product {product_key}",
        "Manufacturer": rng.choice(MANUFACTURERS),
        "Brand": rng.choice(BRANDS),
        "Color": rng.choice(COLORS),
        "WeightUnit": "kg",
        "Weight": round(rng.uniform(0.1, 15), 3),
        "Cost": cost,
        "Price": round(cost * rng.uniform(1.2, 2.5), 2),
        "CategoryKey": category_key,
        "CategoryName": category_name,
        "SubCategoryKey": sub_category_key,
        "SubCategoryName": sub_category_name,
    }


def mutate_row(row: dict, rng: random.Random) -> dict:
    """Change at least one non-key attribute so the row is a genuine update."""
    row = dict(row)
    field = rng.choice(["Price", "Cost", "Color", "Brand"])
    if field == "Price":
        row["Price"] = round(float(row["Price"]) * rng.uniform(0.85, 1.15), 2)
    elif field == "Cost":
        row["Cost"] = round(float(row["Cost"]) * rng.uniform(0.85, 1.15), 2)
    elif field == "Color":
        row["Color"] = rng.choice(COLORS)
    elif field == "Brand":
        row["Brand"] = rng.choice(BRANDS)
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", type=int, default=0, help="number of brand-new product rows to add")
    parser.add_argument("--updated", type=int, default=0, help="number of existing product rows to mutate")
    parser.add_argument("--csv", type=Path, default=Path("data/contoso/product.csv"), help="local landing CSV to read and rewrite")
    parser.add_argument("--seed", type=int, default=None, help="random seed, for reproducible runs")
    args = parser.parse_args()

    if args.new < 0 or args.updated < 0:
        parser.error("--new and --updated must be >= 0")

    rng = random.Random(args.seed)

    if not args.csv.exists():
        parser.error(f"landing CSV not found: {args.csv}")

    rows = read_rows(args.csv)
    existing_keys = {int(r["ProductKey"]) for r in rows}
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
