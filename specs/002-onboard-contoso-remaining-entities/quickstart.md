# Quickstart: Onboard Remaining Contoso Entities

Validation guide for `specs/002-onboard-contoso-remaining-entities/`. Proves the bronze→serving slice works end-to-end for all six entities. See [data-model.md](data-model.md) for exact contract fields and [research.md](research.md) for source details.

## Prerequisites

- `data/contoso/{product,store,date,currencyexchange,orders,orderrows}.csv` populated (downloaded from the same `csv-1m.7z` release asset already used for `customers` — see research.md Decision 1).
- dbt project configured against `lh_contoso` (same lakehouse as `001`, no new Fabric objects needed).
- `bootstrap_landing_table` (generalized), `apply_scd1` (real implementation) macros in place per data-model.md; `apply_scd2`/`dedup_before_insert`/`generate_hash`/`generate_schema_name` reused unchanged from `001`.
- `profiles.yml` has `reuse_session: true` (AGENT.md §12 decision 8) — cold Spark session start only needed once across the whole scenario run below, not once per `dbt` invocation.

## Scenario 1: Initial load — dimensions (product, store)

```powershell
python scripts/upload_to_onelake.py --local data/contoso/product.csv --remote Files/contoso/product.csv
python scripts/upload_to_onelake.py --local data/contoso/store.csv --remote Files/contoso/store.csv
dbt run-operation bootstrap_landing_table --args '{entity: product, csv_path: Files/contoso/product.csv, columns: [{name: ProductKey, type: int}, {name: ProductCode}, {name: ProductName}, {name: Manufacturer}, {name: Brand}, {name: Color}, {name: WeightUnit}, {name: Weight, type: double}, {name: Cost, type: double}, {name: Price, type: double}, {name: CategoryKey, type: int}, {name: CategoryName}, {name: SubCategoryKey, type: int}, {name: SubCategoryName}]}'
dbt run-operation bootstrap_landing_table --args '{entity: store, csv_path: Files/contoso/store.csv, columns: [{name: StoreKey, type: int}, {name: StoreCode}, {name: GeoAreaKey, type: int}, {name: CountryCode}, {name: CountryName}, {name: State}, {name: OpenDate, type: date}, {name: CloseDate, type: date}, {name: Description}, {name: SquareMeters, type: double}, {name: Status}]}'
dbt build --select bronze_contoso__product+ silver_contoso__product_cleansed+ silver_contoso__product+ gold_product+ serving_product bronze_contoso__store+ silver_contoso__store_cleansed+ silver_contoso__store+ gold_store+ serving_store
```

**Expected outcome**: `serving_product` = 2,517 rows, `serving_store` = 74 rows, zero duplicate business keys in either bronze model, all `_is_current = true` rows in silver match the bronze key set, all contracts/tests pass.

## Scenario 2: Initial load — reference data (date, currencyexchange)

```powershell
python scripts/upload_to_onelake.py --local data/contoso/date.csv --remote Files/contoso/date.csv
python scripts/upload_to_onelake.py --local data/contoso/currencyexchange.csv --remote Files/contoso/currencyexchange.csv
dbt run-operation bootstrap_landing_table --args '{entity: date, csv_path: Files/contoso/date.csv, columns: [{name: Date, type: date}, {name: DateKey, type: int}, {name: Year, type: int}, {name: YearQuarter}, {name: YearQuarterNumber, type: int}, {name: Quarter, type: int}, {name: YearMonth}, {name: YearMonthShort}, {name: YearMonthNumber, type: int}, {name: Month}, {name: MonthShort}, {name: MonthNumber, type: int}, {name: DayofWeek}, {name: DayofWeekShort}, {name: DayofWeekNumber, type: int}, {name: WorkingDay, type: int}, {name: WorkingDayNumber, type: int}]}'
dbt run-operation bootstrap_landing_table --args '{entity: currencyexchange, csv_path: Files/contoso/currencyexchange.csv, columns: [{name: Date, type: date}, {name: FromCurrency}, {name: ToCurrency}, {name: Exchange, type: double}]}'
dbt build --select bronze_contoso__date+ silver_contoso__date+ gold_date+ serving_date bronze_contoso__currencyexchange+ silver_contoso__currencyexchange+ gold_currencyexchange+ serving_currencyexchange
```

**Expected outcome**: `serving_date` = 4,018 rows, `serving_currencyexchange` = 100,450 rows. No SCD1/SCD2 machinery invoked (silver models are plain views) — confirmed by checking neither model has `_valid_from`/`_is_current`/`_loaded_at`/`_updated_at` columns.

## Scenario 3: Initial load — facts (orders, orderrows)

```powershell
python scripts/upload_to_onelake.py --local data/contoso/orders.csv --remote Files/contoso/orders.csv
python scripts/upload_to_onelake.py --local data/contoso/orderrows.csv --remote Files/contoso/orderrows.csv
dbt run-operation bootstrap_landing_table --args '{entity: orders, csv_path: Files/contoso/orders.csv, columns: [{name: OrderKey, type: int}, {name: CustomerKey, type: int}, {name: StoreKey, type: int}, {name: OrderDate, type: date}, {name: DeliveryDate, type: date}, {name: CurrencyCode}]}'
dbt run-operation bootstrap_landing_table --args '{entity: orderrows, csv_path: Files/contoso/orderrows.csv, columns: [{name: OrderKey, type: int}, {name: LineNumber, type: int}, {name: ProductKey, type: int}, {name: Quantity, type: int}, {name: UnitPrice, type: double}, {name: NetPrice, type: double}, {name: UnitCost, type: double}]}'
dbt build --select bronze_contoso__orders+ silver_contoso__orders_cleansed+ silver_contoso__orders+ gold_orders+ serving_orders bronze_contoso__orderrows+ silver_contoso__orderrows_cleansed+ silver_contoso__orderrows+ gold_orderrows+ serving_orderrows
```

**Expected outcome**: `serving_orders` = 980,666 rows, `serving_orderrows` = 2,349,091 rows (largest build in the project so far — first check on whether the bronze dedup-hash approach holds up past ~2.3M rows). `silver_contoso__orders`/`silver_contoso__orderrows` row counts equal bronze's distinct-key counts (SCD1 = 1 row per business key, always).

## Scenario 4: Idempotency (rerun all six without new data)

```powershell
dbt build --select bronze_contoso__product+ bronze_contoso__store+ bronze_contoso__date+ bronze_contoso__currencyexchange+ bronze_contoso__orders+ bronze_contoso__orderrows+
```

**Expected outcome**: identical row counts in every layer for all six entities — no duplicates introduced by the rerun, and (for `orders`/`orderrows`) `_updated_at` unchanged on every row (proves the hash-comparison in Decision 2 correctly detected "nothing changed", not just "the merge is idempotent by row count").

## Scenario 5: Delta load — one representative per SCD kind

```powershell
python scripts/simulate_delta_load/contoso_product.py --new 20 --updated 10
python scripts/simulate_delta_load/contoso_orders.py --new 500 --updated 200
python scripts/simulate_delta_load/contoso_date.py --new 31   # e.g. append the next month
# ... re-upload + re-bootstrap + dbt build each, same pattern as Scenarios 1-3
```

**Expected outcome** (per spec.md SC-003/SC-004/SC-005):
- `product`: +20 new bronze rows, +10 SCD2-versioned rows in `silver_contoso__product` (old versions' `_is_current` flips false, `_valid_to` closes out — no gap/overlap, per the generalized tests from research.md Decision 4).
- `orders`: +700 new bronze rows (500 new + 200 updated, bronze is append-only regardless of SCD kind), but only +500 new rows in `silver_contoso__orders` — the 200 updated rows are overwritten in place (SCD1), row count in silver grows by exactly 500, not 700.
- `date`: +31 new rows in every layer, no versioning side effects.

## Scenario 6: Full-project regression (all 7 entities together)

```powershell
dbt build
```

**Expected outcome**: a single `dbt build` with no `--select` builds `customers` (`001`) alongside all six entities from this spec cleanly — proves the two specs' models coexist without contract/schema/macro conflicts (shared macros are backward-compatible, `bootstrap_landing_customer` untouched still works).
