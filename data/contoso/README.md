# `data/contoso/` — Stage-1 landing source CSVs

These CSVs are the **Stage-1 stopgap landing source** for the Contoso
pipeline (they stand in for a Meltano-populated landing zone until the
Meltano→Fabric ingestion path exists — see
`specs/001-onboard-contoso-customers/plan.md` and
`specs/002-onboard-contoso-remaining-entities/plan.md` Complexity Tracking).

They are **not committed to git** (`.gitignore`) — `orderrows.csv` alone is
~86 MB, and every file is byte-identical to a public release asset, so
they're treated as a reproducible download rather than repo content.

## How to get them

Download `csv-1m.7z` from the SQLBI Contoso-Data-Generator-V2-Data
"ready-to-use-data" release and extract all eight `*.csv` files here:

```
https://github.com/sql-bi/Contoso-Data-Generator-V2-Data/releases/download/ready-to-use-data/csv-1m.7z
```

```bash
# needs a 7z extractor (7-Zip, p7zip, or Python's py7zr)
curl -sL -o csv-1m.7z \
  https://github.com/sql-bi/Contoso-Data-Generator-V2-Data/releases/download/ready-to-use-data/csv-1m.7z
7z x csv-1m.7z -o.        # -> customer.csv, product.csv, store.csv, date.csv,
                          #    currencyexchange.csv, orders.csv, orderrows.csv, sales.csv
```

Expected contents (confirmed by direct inspection — see each spec's
`research.md` Decision 1):

| File | Business key | Rows |
|---|---|---|
| `customer.csv` | `CustomerKey` | 104,990 |
| `product.csv` | `ProductKey` | 2,517 |
| `store.csv` | `StoreKey` | 74 |
| `date.csv` | `DateKey` | 4,018 |
| `currencyexchange.csv` | `Date`+`FromCurrency`+`ToCurrency` | 100,450 |
| `orders.csv` | `OrderKey` | 980,666 |
| `orderrows.csv` | `OrderKey`+`LineNumber` | 2,349,091 |
| `sales.csv` | *(not onboarded — `orders` ⋈ `orderrows` flattened; see `002` research.md Decision 1)* | 2,349,091 |

License: MIT, synthetic/fake data (SQLBI Contoso Data Generator output).

## What consumes them

`scripts/upload_to_onelake.py` uploads a file here to the lakehouse's
OneLake Files area, then `dbt run-operation bootstrap_landing_table`
(`bootstrap_landing_customer` for `customers`) bulk-loads it into
`landing.landing_<entity>`. The delta-load simulators
(`scripts/simulate_delta_load/contoso_<entity>.py`) mutate these files
in place to synthesise new/updated records.
