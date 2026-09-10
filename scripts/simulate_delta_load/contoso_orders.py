#!/usr/bin/env python3
"""Simulate a delta load for the Contoso `orders` entity (SCD1 fact).

Same Stage-1 stopgap pattern as contoso_customers.py (AGENT.md §4). Unlike
the SCD2 dimensions, an "updated" order here is expected to be
**overwritten in place** downstream (silver_contoso__orders, SCD1) — see
spec.md SC-004.

Usage:
    python scripts/simulate_delta_load/contoso_orders.py \\
        --new 500 --updated 200 \\
        [--csv data/contoso/orders.csv] [--seed 42]

    python scripts/upload_to_onelake.py \\
        --local data/contoso/orders.csv --remote Files/contoso/orders.csv
    dbt run-operation bootstrap_landing_table --args \\
        '{entity: orders, csv_path: Files/contoso/orders.csv, column_casts: {OrderKey: int, CustomerKey: int, StoreKey: int, OrderDate: date, DeliveryDate: date}}'
"""

from __future__ import annotations

import argparse
import csv
import datetime
import random
import sys
from pathlib import Path

FIELDNAMES = ["OrderKey", "CustomerKey", "StoreKey", "OrderDate", "DeliveryDate", "CurrencyCode"]

CURRENCIES = ["USD", "EUR", "GBP", "AUD", "CAD"]


def read_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_rows(csv_path: Path, rows: list[dict]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def make_new_row(order_key: int, rng: random.Random, sample_customer_keys: list[int], sample_store_keys: list[int]) -> dict:
    order_date = datetime.date(2026, rng.randint(1, 9), rng.randint(1, 28))
    delivery_date = order_date + datetime.timedelta(days=rng.randint(0, 7))
    return {
        "OrderKey": order_key,
        "CustomerKey": rng.choice(sample_customer_keys) if sample_customer_keys else rng.randint(1, 2000000),
        "StoreKey": rng.choice(sample_store_keys) if sample_store_keys else rng.randint(10, 500),
        "OrderDate": order_date.isoformat(),
        "DeliveryDate": delivery_date.isoformat(),
        "CurrencyCode": rng.choice(CURRENCIES),
    }


def mutate_row(row: dict, rng: random.Random) -> dict:
    """Change at least one non-key attribute — this becomes an SCD1 overwrite downstream."""
    row = dict(row)
    field = rng.choice(["DeliveryDate", "CurrencyCode"])
    if field == "DeliveryDate":
        base = datetime.date.fromisoformat(row["OrderDate"])
        row["DeliveryDate"] = (base + datetime.timedelta(days=rng.randint(0, 10))).isoformat()
    elif field == "CurrencyCode":
        row["CurrencyCode"] = rng.choice(CURRENCIES)
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", type=int, default=0, help="number of brand-new order rows to add")
    parser.add_argument("--updated", type=int, default=0, help="number of existing order rows to mutate")
    parser.add_argument("--csv", type=Path, default=Path("data/contoso/orders.csv"), help="local landing CSV to read and rewrite")
    parser.add_argument("--seed", type=int, default=None, help="random seed, for reproducible runs")
    args = parser.parse_args()

    if args.new < 0 or args.updated < 0:
        parser.error("--new and --updated must be >= 0")

    rng = random.Random(args.seed)

    if not args.csv.exists():
        parser.error(f"landing CSV not found: {args.csv}")

    rows = read_rows(args.csv)
    existing_keys = {int(r["OrderKey"]) for r in rows}
    by_index = {i: r for i, r in enumerate(rows)}
    sample_customer_keys = [int(r["CustomerKey"]) for r in rng.sample(rows, k=min(1000, len(rows)))]
    sample_store_keys = [int(r["StoreKey"]) for r in rng.sample(rows, k=min(1000, len(rows)))]

    updated_count = min(args.updated, len(rows))
    if args.updated > len(rows):
        print(f"warning: --updated {args.updated} exceeds {len(rows)} existing rows; mutating all of them", file=sys.stderr)
    for idx in rng.sample(range(len(rows)), k=updated_count):
        by_index[idx] = mutate_row(by_index[idx], rng)
    rows = [by_index[i] for i in range(len(rows))]

    next_key = max(existing_keys, default=0) + 1
    for i in range(args.new):
        rows.append(make_new_row(next_key + i, rng, sample_customer_keys, sample_store_keys))

    write_rows(args.csv, rows)
    print(f"OK: +{args.new} new, ~{updated_count} updated (some may have re-rolled the same value), "
          f"{len(rows)} total rows written to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
