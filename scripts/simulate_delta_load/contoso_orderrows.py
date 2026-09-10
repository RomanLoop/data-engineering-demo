#!/usr/bin/env python3
"""Simulate a delta load for the Contoso `orderrows` entity (SCD1 fact,
composite business key).

Same Stage-1 stopgap pattern as contoso_orders.py. New rows attach to
existing OrderKeys (as new line numbers) rather than inventing new
OrderKeys, since orderrows is a child of orders.

Usage:
    python scripts/simulate_delta_load/contoso_orderrows.py \\
        --new 500 --updated 200 \\
        [--csv data/contoso/orderrows.csv] [--seed 42]

    python scripts/upload_to_onelake.py \\
        --local data/contoso/orderrows.csv --remote Files/contoso/orderrows.csv
    dbt run-operation bootstrap_landing_table --args \\
        '{entity: orderrows, csv_path: Files/contoso/orderrows.csv, column_casts: {OrderKey: int, LineNumber: int, ProductKey: int, Quantity: int, UnitPrice: double, NetPrice: double, UnitCost: double}}'
"""

from __future__ import annotations

import argparse
import csv
import random
import sys
from pathlib import Path

FIELDNAMES = ["OrderKey", "LineNumber", "ProductKey", "Quantity", "UnitPrice", "NetPrice", "UnitCost"]


def read_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_rows(csv_path: Path, rows: list[dict]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def make_new_row(order_key: int, line_number: int, rng: random.Random, sample_product_keys: list[int]) -> dict:
    unit_price = round(rng.uniform(1, 500), 3)
    quantity = rng.randint(1, 10)
    return {
        "OrderKey": order_key,
        "LineNumber": line_number,
        "ProductKey": rng.choice(sample_product_keys) if sample_product_keys else rng.randint(1, 2500),
        "Quantity": quantity,
        "UnitPrice": unit_price,
        "NetPrice": round(unit_price * quantity * rng.uniform(0.9, 1.0), 3),
        "UnitCost": round(unit_price * rng.uniform(0.4, 0.7), 3),
    }


def mutate_row(row: dict, rng: random.Random) -> dict:
    """Change at least one non-key attribute — becomes an SCD1 overwrite downstream."""
    row = dict(row)
    field = rng.choice(["Quantity", "UnitPrice"])
    if field == "Quantity":
        row["Quantity"] = max(1, int(row["Quantity"]) + rng.choice([-1, 1, 2]))
    elif field == "UnitPrice":
        row["UnitPrice"] = round(float(row["UnitPrice"]) * rng.uniform(0.9, 1.1), 3)
    row["NetPrice"] = round(float(row["UnitPrice"]) * int(row["Quantity"]) * rng.uniform(0.9, 1.0), 3)
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", type=int, default=0, help="number of brand-new order-line rows to add (attached to existing OrderKeys as new LineNumbers)")
    parser.add_argument("--updated", type=int, default=0, help="number of existing order-line rows to mutate")
    parser.add_argument("--csv", type=Path, default=Path("data/contoso/orderrows.csv"), help="local landing CSV to read and rewrite")
    parser.add_argument("--seed", type=int, default=None, help="random seed, for reproducible runs")
    args = parser.parse_args()

    if args.new < 0 or args.updated < 0:
        parser.error("--new and --updated must be >= 0")

    rng = random.Random(args.seed)

    if not args.csv.exists():
        parser.error(f"landing CSV not found: {args.csv}")

    rows = read_rows(args.csv)
    existing_keys = {(int(r["OrderKey"]), int(r["LineNumber"])) for r in rows}
    max_line_by_order: dict[int, int] = {}
    for r in rows:
        ok = int(r["OrderKey"])
        max_line_by_order[ok] = max(max_line_by_order.get(ok, -1), int(r["LineNumber"]))
    order_keys = list(max_line_by_order)
    sample_product_keys = [int(r["ProductKey"]) for r in rng.sample(rows, k=min(1000, len(rows)))]

    by_index = {i: r for i, r in enumerate(rows)}
    updated_count = min(args.updated, len(rows))
    if args.updated > len(rows):
        print(f"warning: --updated {args.updated} exceeds {len(rows)} existing rows; mutating all of them", file=sys.stderr)
    for idx in rng.sample(range(len(rows)), k=updated_count):
        by_index[idx] = mutate_row(by_index[idx], rng)
    rows = [by_index[i] for i in range(len(rows))]

    for _ in range(args.new):
        order_key = rng.choice(order_keys)
        max_line_by_order[order_key] += 1
        new_row = make_new_row(order_key, max_line_by_order[order_key], rng, sample_product_keys)
        if (new_row["OrderKey"], new_row["LineNumber"]) in existing_keys:
            continue
        rows.append(new_row)
        existing_keys.add((new_row["OrderKey"], new_row["LineNumber"]))

    write_rows(args.csv, rows)
    print(f"OK: +{args.new} new, ~{updated_count} updated (some may have re-rolled the same value), "
          f"{len(rows)} total rows written to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
