# Quickstart: Onboard Contoso Customers

Validation guide for `specs/001-onboard-contoso-customers/`. Proves the bronze→serving slice works end-to-end. See [data-model.md](data-model.md) for exact contract fields and [research.md](research.md) for source details. All four scenarios below have been run for real against the live Fabric lakehouse (2026-09-09) — see tasks.md T020–T023.

## Prerequisites

- `data/contoso/customer.csv` populated with a local copy of `customer.csv` (downloaded from the `csv-1m.7z` release asset — see research.md Decision 1 for the URL). **Stage-1 stopgap** standing in for Meltano (see plan.md Complexity Tracking) — swap for `meltano/extract/contoso/` + `meltano run` once the Fabric ingestion path is unblocked.
- dbt project configured against the `lh_contoso` Fabric lakehouse — schema-enabled (`creationPayload.enableSchemas: true`, AGENT.md §7), CLI (`az login`) auth (dev credentials never committed — AGENT.md §8; see `.env.example` for the required keys).
- The four macros (`dedup_before_insert`, `mask_pii_columns`, `apply_scd1`, `apply_scd2`) implemented per data-model.md, plus `generate_hash` and `generate_schema_name`.

## Scenario 1: Initial load

```powershell
python scripts/upload_to_onelake.py --local data/contoso/customer.csv --remote Files/contoso/customer.csv
dbt run-operation bootstrap_landing_customer          # bulk-loads customer.csv as the Stage-1 landing stand-in (landing.landing_customer)
dbt build --select bronze_contoso__customers+ silver_contoso__customers_cleansed+ silver_contoso__customers+ gold_customers+ serving_customers
```

**Expected outcome**:
- `bronze.bronze_contoso__customers` has 104,990 rows, one per `CustomerKey`, zero duplicates.
- `silver.silver_contoso__customers_cleansed` has 104,990 rows (1:1 with bronze at this point — no history yet).
- `silver.silver_contoso__customers` has 104,990 current-version rows (`_is_current = true`), same business key set.
- `gold.gold_customers` and `serving.serving_customers` both resolve with 104,990 rows.
- All dbt tests and contract checks pass with zero failures (spec SC-001, SC-004, SC-005).

## Scenario 2: Idempotency (rerun without new data)

```powershell
dbt build --select bronze_contoso__customers+ silver_contoso__customers_cleansed+ silver_contoso__customers+ gold_customers+ serving_customers
```

**Expected outcome**: identical row counts in every layer as Scenario 1 — no duplicates introduced by the rerun (spec SC-002).

## Scenario 3: Delta load (new + updated customers)

```powershell
python scripts/simulate_delta_load/contoso_customers.py --new 500 --updated 200
python scripts/upload_to_onelake.py --local data/contoso/customer.csv --remote Files/contoso/customer.csv
dbt run-operation bootstrap_landing_customer
dbt build --select bronze_contoso__customers+ silver_contoso__customers_cleansed+ silver_contoso__customers+ gold_customers+ serving_customers
```

**Expected outcome**:
- Bronze gains exactly 500 + 200 = 700 new rows: 500 for brand-new `CustomerKey`s, plus one new row per "updated" record whose dedup hash actually changed (see data-model.md `meta.dedup_columns`).
- `silver_contoso__customers` historizes exactly the 200 updated keys' prior versions (`_is_current` flipped to `false`, `_valid_to` closed out to the new version's `_valid_from` — no gap, no overlap, per the two singular tests) and adds 700 new rows, netting to 105,490 current rows.
- `gold_customers`/`serving_customers` row counts grow by exactly 500 to 105,490 (spec SC-003).

## Scenario 4: PII masking macro sanity check (non-prod, currently a no-op)

Run `mask_pii_columns` against `bronze_contoso__customers` with a non-prod target flag set (even though Stage 1 has no real non-prod environment yet, per AGENT.md §8/§11) and confirm it compiles and is a documented no-op on `prod` — this proves the macro is exercised and ready for when a non-prod environment exists (spec NFR-002).
