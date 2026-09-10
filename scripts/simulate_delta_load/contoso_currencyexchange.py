#!/usr/bin/env python3
"""Simulate a delta load for the Contoso `currencyexchange` entity.

Static reference data (AGENT.md §6/§12) with a composite business key
(Date, FromCurrency, ToCurrency). The realistic "delta" is a new day's
rates for all currency pairs; `--updated` mutates existing rates in place
to regression-test silver_contoso__currencyexchange.sql's row_number()
dedup.

Usage:
    python scripts/simulate_delta_load/contoso_currencyexchange.py \\
        --new-date 2026-09-08 \\
        [--csv data/contoso/currencyexchange.csv] [--seed 42]

    python scripts/upload_to_onelake.py \\
        --local data/contoso/currencyexchange.csv --remote Files/contoso/currencyexchange.csv
    dbt run-operation bootstrap_landing_table --args \\
        '{entity: currencyexchange, csv_path: Files/contoso/currencyexchange.csv, column_casts: {Date: date, Exchange: double}}'
"""

from __future__ import annotations

import argparse
import csv
import datetime
import random
from pathlib import Path

FIELDNAMES = ["Date", "FromCurrency", "ToCurrency", "Exchange"]


def read_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_rows(csv_path: Path, rows: list[dict]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new-date", type=str, default=None, help="ISO date to append rates for (all currency pairs seen on the most recent existing date); defaults to the day after the latest date in the CSV")
    parser.add_argument("--updated", type=int, default=0, help="number of existing (date, pair) rows to mutate (regression test only)")
    parser.add_argument("--csv", type=Path, default=Path("data/contoso/currencyexchange.csv"), help="local landing CSV to read and rewrite")
    parser.add_argument("--seed", type=int, default=None, help="random seed, for reproducible runs")
    args = parser.parse_args()

    if args.updated < 0:
        parser.error("--updated must be >= 0")

    rng = random.Random(args.seed)

    if not args.csv.exists():
        parser.error(f"landing CSV not found: {args.csv}")

    rows = read_rows(args.csv)
    existing_keys = {(r["Date"], r["FromCurrency"], r["ToCurrency"]) for r in rows}
    by_index = {i: r for i, r in enumerate(rows)}

    updated_count = min(args.updated, len(rows))
    for idx in rng.sample(range(len(rows)), k=updated_count):
        row = dict(by_index[idx])
        row["Exchange"] = round(float(row["Exchange"]) * rng.uniform(0.98, 1.02), 5)
        by_index[idx] = row
    rows = [by_index[i] for i in range(len(rows))]

    latest_date = max(datetime.date.fromisoformat(r["Date"]) for r in rows)
    new_date = (
        datetime.date.fromisoformat(args.new_date)
        if args.new_date
        else latest_date + datetime.timedelta(days=1)
    )
    pairs_on_latest = {
        (r["FromCurrency"], r["ToCurrency"]) for r in rows if r["Date"] == latest_date.isoformat()
    }
    new_count = 0
    for from_ccy, to_ccy in pairs_on_latest:
        if (new_date.isoformat(), from_ccy, to_ccy) in existing_keys:
            continue
        base_rate = next(
            (r["Exchange"] for r in rows if r["Date"] == latest_date.isoformat()
             and r["FromCurrency"] == from_ccy and r["ToCurrency"] == to_ccy),
            "1.0",
        )
        rows.append({
            "Date": new_date.isoformat(),
            "FromCurrency": from_ccy,
            "ToCurrency": to_ccy,
            "Exchange": round(float(base_rate) * rng.uniform(0.98, 1.02), 5),
        })
        new_count += 1

    write_rows(args.csv, rows)
    print(f"OK: +{new_count} new (date {new_date.isoformat()}), ~{updated_count} updated, "
          f"{len(rows)} total rows written to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
