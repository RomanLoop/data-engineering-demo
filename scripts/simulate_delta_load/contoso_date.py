#!/usr/bin/env python3
"""Simulate a delta load for the Contoso `date` entity.

Static reference data (AGENT.md §6/§12) — the only realistic "delta" here
is appending future calendar dates (a genuine attribute correction on an
existing date is possible but not the common case); `--updated` is
supported for completeness/regression-testing the row_number()-based dedup
in silver_contoso__date.sql, not because real calendar corrections are
expected.

Usage:
    python scripts/simulate_delta_load/contoso_date.py \\
        --new 31 \\
        [--csv data/contoso/date.csv] [--seed 42]

    python scripts/upload_to_onelake.py \\
        --local data/contoso/date.csv --remote Files/contoso/date.csv
    dbt run-operation bootstrap_landing_table --args \\
        '{entity: date, csv_path: Files/contoso/date.csv, column_casts: {Date: date, DateKey: int, Year: int, YearQuarterNumber: int, Quarter: int, YearMonthNumber: int, MonthNumber: int, DayofWeekNumber: int, WorkingDay: int, WorkingDayNumber: int}}'
"""

from __future__ import annotations

import argparse
import calendar
import csv
import datetime
import random
from pathlib import Path

FIELDNAMES = [
    "Date", "DateKey", "Year", "YearQuarter", "YearQuarterNumber", "Quarter",
    "YearMonth", "YearMonthShort", "YearMonthNumber", "Month", "MonthShort",
    "MonthNumber", "DayofWeek", "DayofWeekShort", "DayofWeekNumber",
    "WorkingDay", "WorkingDayNumber",
]

MONTH_NAMES = [calendar.month_name[m] for m in range(1, 13)]
MONTH_SHORT = [calendar.month_abbr[m] for m in range(1, 13)]
DAY_NAMES = list(calendar.day_name)  # Monday..Sunday
DAY_SHORT = list(calendar.day_abbr)


def read_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_rows(csv_path: Path, rows: list[dict]) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def make_date_row(d: datetime.date) -> dict:
    year_month_num = year_quarter_num = d.year * 100
    quarter = (d.month - 1) // 3 + 1
    dow_number = d.isoweekday() % 7 + 1  # matches source sample (Fri=6)
    working_day = 0 if d.isoweekday() >= 6 else 1
    return {
        "Date": d.isoformat(),
        "DateKey": int(d.strftime("%Y%m%d")),
        "Year": d.year,
        "YearQuarter": f"Q{quarter}-{d.year}",
        "YearQuarterNumber": year_quarter_num + quarter,
        "Quarter": quarter,
        "YearMonth": f"{MONTH_NAMES[d.month - 1]} {d.year}",
        "YearMonthShort": f"{MONTH_SHORT[d.month - 1]} {d.year}",
        "YearMonthNumber": year_month_num + d.month,
        "Month": MONTH_NAMES[d.month - 1],
        "MonthShort": MONTH_SHORT[d.month - 1],
        "MonthNumber": d.month,
        "DayofWeek": DAY_NAMES[d.weekday()],
        "DayofWeekShort": DAY_SHORT[d.weekday()],
        "DayofWeekNumber": dow_number,
        "WorkingDay": working_day,
        "WorkingDayNumber": working_day,
    }


def mutate_row(row: dict, rng: random.Random) -> dict:
    """Flip WorkingDay as a synthetic 'correction' (regression-tests dedup)."""
    row = dict(row)
    row["WorkingDay"] = "1" if row.get("WorkingDay") == "0" else "0"
    row["WorkingDayNumber"] = row["WorkingDay"]
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", type=int, default=0, help="number of new future calendar dates to append")
    parser.add_argument("--updated", type=int, default=0, help="number of existing date rows to mutate (regression test only)")
    parser.add_argument("--csv", type=Path, default=Path("data/contoso/date.csv"), help="local landing CSV to read and rewrite")
    parser.add_argument("--seed", type=int, default=None, help="random seed, for reproducible runs")
    args = parser.parse_args()

    if args.new < 0 or args.updated < 0:
        parser.error("--new and --updated must be >= 0")

    rng = random.Random(args.seed)

    if not args.csv.exists():
        parser.error(f"landing CSV not found: {args.csv}")

    rows = read_rows(args.csv)
    existing_keys = {int(r["DateKey"]) for r in rows}
    by_index = {i: r for i, r in enumerate(rows)}

    updated_count = min(args.updated, len(rows))
    for idx in rng.sample(range(len(rows)), k=updated_count):
        by_index[idx] = mutate_row(by_index[idx], rng)
    rows = [by_index[i] for i in range(len(rows))]

    last_date = max(datetime.date.fromisoformat(r["Date"]) for r in rows)
    for i in range(1, args.new + 1):
        new_date = last_date + datetime.timedelta(days=i)
        if int(new_date.strftime("%Y%m%d")) in existing_keys:
            continue
        rows.append(make_date_row(new_date))

    write_rows(args.csv, rows)
    print(f"OK: +{args.new} new, ~{updated_count} updated, {len(rows)} total rows written to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
