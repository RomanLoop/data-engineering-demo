# Implementation Plan: Onboard Remaining Contoso Entities

**Branch**: `002-onboard-contoso-remaining-entities` | **Date**: 2026-09-09 | **Spec**: [spec.md](spec.md)

**Input**: Pipeline specification from `specs/002-onboard-contoso-remaining-entities/spec.md`

## Summary

Onboard the six remaining SQLBI Contoso V2 tables end-to-end: `product`/`store` (master data, SCD2), `date`/`currencyexchange` (static reference, no SCD), `orders`/`orderrows` (facts, SCD1 — first real exercise of `apply_scd1`). Reuses the `001-onboard-contoso-customers` pattern and every existing shared macro unchanged (`dedup_before_insert`, `generate_hash`, `apply_scd2`, `generate_schema_name`), generalizes the landing-bootstrap macro (was hardcoded per-entity in `001`) into one parameterized macro instead of six near-duplicates, and gives `apply_scd1` its first real implementation (currently just a column-list stub).

## Technical Context

**Source system(s)**: SQLBI Contoso-Data-Generator-V2-Data, `ready-to-use-data` release, asset `csv-1m.7z` — `product.csv`, `store.csv`, `date.csv`, `currencyexchange.csv`, `orders.csv`, `orderrows.csv` (same archive already used for `customers`; all six confirmed by direct download+inspection 2026-09-09 — see research.md).

**Meltano extractor/loader**: **Blocked**, same finding as `001` (no Meltano→Fabric-OneLake-compatible target). Same Stage-1 stopgap: native Spark bulk load via OneLake, now via one generalized `bootstrap_landing_table` macro instead of six copy-pasted `bootstrap_landing_customer`-style macros.

**dbt layer(s) touched**: 6 entities × up to 4 models each (dimensions/facts get a `_cleansed` view + historization model; reference entities get one silver model):
- `bronze_contoso__product`, `bronze_contoso__store`, `bronze_contoso__date`, `bronze_contoso__currencyexchange`, `bronze_contoso__orders`, `bronze_contoso__orderrows`
- `silver_contoso__product_cleansed` → `silver_contoso__product` (SCD2)
- `silver_contoso__store_cleansed` → `silver_contoso__store` (SCD2)
- `silver_contoso__date` (no SCD, single view)
- `silver_contoso__currencyexchange` (no SCD, single view)
- `silver_contoso__orders_cleansed` → `silver_contoso__orders` (SCD1)
- `silver_contoso__orderrows_cleansed` → `silver_contoso__orderrows` (SCD1)
- `gold_product`, `gold_store`, `gold_date`, `gold_currencyexchange`, `gold_orders`, `gold_orderrows`
- `serving_product`, `serving_store`, `serving_date`, `serving_currencyexchange`, `serving_orders`, `serving_orderrows`

**Fabric objects**: same lakehouse `lh_contoso` (schema-enabled), same `landing`/`bronze`/`silver`/`gold`/`serving` schemas — no new Fabric objects needed.

**Orchestration**: manual/CLI-triggered (`scripts/upload_to_onelake.py` ×6 + `dbt run-operation bootstrap_landing_table --args '{...}'` ×6 then `dbt build`) — Dagster not yet integrated, per AGENT.md §10.

**Testing**: dbt contract enforcement + column tests on all 24 new models (not_null on business key at minimum, unique where the grain allows it); the two existing SCD2 gap/overlap singular tests, generalized to run against `product`/`store` too (currently hardcoded to `silver_contoso__customers` — see research.md Decision 4); a new SCD1 correctness singular test (no duplicate current rows per business key after an update — see research.md Decision 3); extended delta-load simulator exercising all six entities.

**Performance/volume**: `product` 2,517 · `store` 74 · `date` 4,018 · `currencyexchange` 100,450 · `orders` 980,666 · `orderrows` 2,349,091 rows. `orderrows` is ~22× the row count of `customers` — first real test of whether the bronze dedup-hash approach and the OneLake bulk-load path continue to perform at this scale (customers' initial load measured ~47s bronze / ~2-3 min full pipeline for ~105K rows; no fixed SLA yet, but this is the first volume check past six figures).

**Constraints**: same as `001` — silver MUST NOT join other models; bronze MUST remain append-only, no `full-refresh`; no surrogate keys; composite business keys (`currencyexchange`, `orderrows`) must be supported by every macro that takes `business_key` (already true — `dedup_before_insert`/`apply_scd2`/`generate_hash` all treat `business_key` as a list); `date`/`currencyexchange` silver models must not declare `scd1_columns`/`scd2_columns` at all (omitted, not empty list — signals "not SCD-managed" vs. `customers`' `scd1_columns: []` which signals "SCD-managed, currently empty").

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design. See `.specify/memory/constitution.md`.*

- **I. Idempotency**: ✅ Same `dedup_before_insert` macro, unchanged, reused for all 6 bronze models. SCD1 merge (new) is idempotent by construction (MERGE on business key). SC-002 tests rerun idempotency for all 6 entities.
- **II. Declarative**: ✅ Config-driven throughout; the one imperative piece (landing bootstrap) is *reduced* in this change — one generic macro instead of six hand-written duplicates, invoked with entity-specific args, not six bespoke scripts.
- **III. Additive schema evolution**: ✅ `on_schema_change: append_new_columns` on every incremental model, same as `001`.
- **IV. Medallion layering**: ✅ Landing → bronze (append-only) → silver (view or SCD1/SCD2, no cross-model joins) → gold (business logic, business-key-only, no cross-entity joins in this change — see Assumptions) → serving (view). No boundary blurred.
- **V. Model contracts mandatory**: ✅ All 24 new models get `contract: {enforced: true}` + full `meta` per FR-003/005/006/007. `date`/`currencyexchange` are the first models where `meta` intentionally omits both `scd1_columns` and `scd2_columns` — a new, documented case, not an oversight.
- **VI. Security & secrets**: ✅ No secrets involved (same public dataset, same `.env`-only credential handling); no PII columns on any of the six entities (FR-003), so `mask_pii_columns` is not invoked here (NFR-002) — it stays exercised via `customers`.
- **Additional Constraint — "Meltano-only ingestion"**: ⚠️ **EXCEPTION**, same tracked exception as `001`, extended to 6 more entities via the generalized bootstrap macro. See Complexity Tracking.

One tracked exception (inherited from `001`, generalized here). All six core principles otherwise hold. Re-checked after Phase 1 design below — still holds; no new violations introduced by the data-model/research decisions.

## Project Structure

### Documentation (this change)

```text
specs/002-onboard-contoso-remaining-entities/
├── plan.md              # This file
├── research.md           # Phase 0 output
├── data-model.md         # Phase 1 output — entity & contract detail
├── quickstart.md         # Phase 1 output — pipeline validation guide
└── tasks.md              # Phase 2 output (/speckit-tasks — not created by this command)
```

### Repository layout (this change)

```text
data/contoso/
├── product.csv                               # new — Stage-1 landing source
├── store.csv                                 # new
├── date.csv                                  # new
├── currencyexchange.csv                      # new
├── orders.csv                                # new
└── orderrows.csv                             # new

dbt/models/bronze/contoso/
├── _contoso__sources.yml                     # extended — 6 new source() entries
├── bronze_contoso__product.sql / .yml
├── bronze_contoso__store.sql / .yml
├── bronze_contoso__date.sql / .yml
├── bronze_contoso__currencyexchange.sql / .yml
├── bronze_contoso__orders.sql / .yml
└── bronze_contoso__orderrows.sql / .yml

dbt/models/silver/contoso/
├── silver_contoso__product_cleansed.sql / .yml
├── silver_contoso__product.sql / .yml                  # SCD2
├── silver_contoso__store_cleansed.sql / .yml
├── silver_contoso__store.sql / .yml                    # SCD2
├── silver_contoso__date.sql / .yml                     # no SCD, single model
├── silver_contoso__currencyexchange.sql / .yml         # no SCD, single model
├── silver_contoso__orders_cleansed.sql / .yml
├── silver_contoso__orders.sql / .yml                   # SCD1
├── silver_contoso__orderrows_cleansed.sql / .yml
└── silver_contoso__orderrows.sql / .yml                # SCD1

dbt/models/gold/
├── gold_product.sql / .yml
├── gold_store.sql / .yml
├── gold_date.sql / .yml
├── gold_currencyexchange.sql / .yml
├── gold_orders.sql / .yml
└── gold_orderrows.sql / .yml

dbt/models/serving/
├── serving_product.sql / .yml
├── serving_store.sql / .yml
├── serving_date.sql / .yml
├── serving_currencyexchange.sql / .yml
├── serving_orders.sql / .yml
└── serving_orderrows.sql / .yml

dbt/macros/
├── bootstrap_landing_table.sql               # new — generalized landing bootstrap (entity + column-cast list as args), replaces the per-entity pattern for these 6 (bootstrap_landing_customer left untouched)
├── apply_scd1.sql                             # rewritten — from column-list stub to a real merge-based implementation (see research.md Decision 2)
├── dedup_before_insert.sql                    # reused, unchanged
├── generate_hash.sql                          # reused, unchanged
├── apply_scd2.sql                             # reused, unchanged
└── generate_schema_name.sql                   # reused, unchanged

dbt/tests/
├── assert_silver_contoso_customers_no_overlapping_validity.sql   # generalized to product/store (see research.md Decision 4) — may become assert_silver_scd2_no_overlapping_validity.sql, parameterized
├── assert_silver_contoso_customers_no_gaps_in_validity.sql       # same generalization
└── assert_silver_contoso_orders_orderrows_no_duplicate_current.sql  # new — SCD1 correctness test

scripts/
├── simulate_delta_load/contoso_customers.py   # existing, unchanged
├── simulate_delta_load/contoso_product.py     # new
├── simulate_delta_load/contoso_store.py       # new
├── simulate_delta_load/contoso_date.py        # new
├── simulate_delta_load/contoso_currencyexchange.py  # new
├── simulate_delta_load/contoso_orders.py      # new
├── simulate_delta_load/contoso_orderrows.py   # new
└── upload_to_onelake.py                       # existing, unchanged (already generic — takes --local/--remote)
```

No `dagster/`, `meltano/` path yet (unchanged from `001`).

**Structure Decision**: Two deliberate deviations from a naive "copy the `001` pattern six times" approach, both justified in Complexity Tracking / research.md:
1. **Generalized landing bootstrap** (`bootstrap_landing_table`, parameterized) instead of six hand-written `bootstrap_landing_<entity>` macros — reduces the tracked Meltano exception's footprint from "one bespoke macro" to "one bespoke macro pattern," and per `001`'s own Removal condition, there's only one macro to delete once Meltano is unblocked, not seven.
2. **`apply_scd1` gets a real implementation in this change**, not a new entity-specific workaround — it was already planned/stubbed in `001` specifically for this moment (see the macro's own docstring).

Everything else (bronze dedup, silver-cleansed-view split for dimensions/facts, gold business-key passthrough, serving views, contract-per-model) is an exact repeat of the `001` pattern at entity scale.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|---------------------------------------|
| Landing populated via a native Spark bulk load (generalized `bootstrap_landing_table`) instead of Meltano, for 6 more entities (violates AGENT.md §4 / constitution "Meltano-only") | Same root cause as `001`: no Meltano→Fabric-OneLake-compatible target exists yet. Extending the already-tracked, already-justified `001` exception to 6 more entities via one generalized macro (rather than reopening the Meltano-vs-stopgap debate per entity) keeps this a single tracked item, not seven. | Waiting for the real Meltano path remains separate, tracked work (same as `001`). Writing six more one-off `bootstrap_landing_<entity>` macros (mirroring `001` exactly) was considered and rejected in favor of generalizing now — six near-duplicate 70-line macros is worse maintenance debt than one parameterized macro, and the removal condition below is simpler as a result. |

**Removal condition**: identical to `001` — once Meltano→Fabric ingestion exists, replace every `landing.landing_<entity>` table (populated by `bootstrap_landing_table`) with a real Meltano-populated landing table, update `_contoso__sources.yml`, and delete `bootstrap_landing_table` + the relevant `upload_to_onelake.py` invocations — no changes needed downstream of landing, for any of the 7 entities onboarded so far (customers + these 6).
