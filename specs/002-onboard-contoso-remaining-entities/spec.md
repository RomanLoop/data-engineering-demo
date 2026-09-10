# Pipeline Specification: Onboard Remaining Contoso Entities

**Branch**: `002-onboard-contoso-remaining-entities`

**Created**: 2026-09-09

**Status**: Draft

**Input**: User description: "Onboard remaining Contoso entities end-to-end following the customers reference pattern: dimensions product and store (SCD2 master data), facts orders and orderrows (SCD1), and static reference data date and currencyexchange (no SCD, plain cleansed silver). Same Meltano-blocked Stage-1 stopgap (native Spark bulk load via OneLake) as customers, same bronze dedup-before-insert, same medallion layering and model contracts."

## Overview

Onboard the six remaining tables of the SQLBI Contoso V2 sample dataset — `product`, `store` (master data), `date`, `currencyexchange` (static reference data), and `orders`, `orderrows` (transactional facts) — end-to-end through the same bronze → silver → gold → serving pipeline established by `001-onboard-contoso-customers`. This is the first time the reference pattern is applied to more than one entity at once, and the first time it is applied to non-master-data entities: it exercises the SCD assignment policy decided in AGENT.md §6/§12 (dimensions → SCD2, facts → SCD1, static reference data → no SCD) and is the first real (non-docstring-only) use of the `apply_scd1` macro.

## Source & Ingestion

- **Source system**: [SQLBI Contoso-Data-Generator-V2-Data](https://github.com/sql-bi/Contoso-Data-Generator-V2-Data/releases), the same `csv-1m.7z` release asset already used for `customers` — `product.csv`, `store.csv`, `date.csv`, `currencyexchange.csv`, `orders.csv`, `orderrows.csv`. Confirmed by downloading and inspecting the archive directly (2026-09-09): every file's declared business key is unique with zero nulls (verified via sort/uniq on each key column), so each is a flat current-state (or, for `orders`/`orderrows`, an append-only event) snapshot, not a change-history export.
- **`sales.csv` explicitly excluded**: verified by direct inspection that `sales.csv` is `orders.csv` joined to `orderrows.csv`, already flattened (identical `OrderKey`+`LineNumber` key set, identical row count, matching values on shared columns). Onboarding it alongside `orders`/`orderrows` would load the same facts twice in two different shapes; `orders`+`orderrows` (the normalized structure) was chosen instead as it better mirrors a real OLTP source (AGENT.md §12, decision 10).
- **Extraction method**: Meltano `tap-csv` remains the target long-term method and remains **blocked** for the same reason recorded in `001-onboard-contoso-customers` (no Meltano→Fabric-OneLake-compatible target exists yet — storage-account-key vs. Azure AD auth mismatch). **Stage-1 stopgap** (same tracked, temporary exception as `001`): each CSV is uploaded to the lakehouse's OneLake Files area and bulk-loaded as a Delta table by a native Spark job, standing in for the landing zone, until the Meltano→Fabric path exists.
- **Load pattern**: one-time initial full load per entity, then repeated delta loads via an extended delta-load simulator (new + updated records per entity).
- **Expected volume & frequency**: `product` 2,517 rows; `store` 74 rows; `date` 4,018 rows; `currencyexchange` 100,450 rows; `orders` 980,666 rows; `orderrows` 2,349,091 rows (all row counts confirmed by direct inspection of the downloaded CSVs, 2026-09-09). Delta loads run on-demand via the simulator, not yet on a fixed schedule (Dagster not yet integrated, per AGENT.md §10).
- **Landing format**: CSV, UTF-8, overwritten on every load per entity (landing is a pure landing zone, no history kept there — AGENT.md §5), same as `customers`.

## Entities & Data Contract

<!--
  Priority order also doubles as a sensible build order: product/store have no
  foreign-key dependencies on entities in this spec; orders references
  customer_key (001) and store_key (this spec); orderrows references
  order_key and product_key (both this spec). No gold-level joins are
  required to satisfy this spec's scope (see Layer Placement, Assumptions) —
  the ordering is about a sane rollout sequence, not a hard dependency gate.
-->

### Entity 1 - product (Priority: P1)

**Business key**: `ProductKey`.

**Why this priority**: Small (2,517 rows), no foreign-key dependencies on other entities in this spec, classic master data — good first exercise of the SCD2 pattern on a second entity after `customers`.

**Grain**: One row per product. Confirmed via direct inspection: `ProductKey` unique across all 2,517 rows, zero nulls.

**Key columns**: `ProductKey`, `ProductCode`, `ProductName`, `Manufacturer`, `Brand`, `Color`, `WeightUnit`, `Weight`, `Cost`, `Price`, `CategoryKey`, `CategoryName`, `SubCategoryKey`, `SubCategoryName`.

**PII columns**: none.

**Independent test**: Can be extracted and built through bronze → silver → gold → serving, and validated independently of any other entity by running the initial load and querying `serving_product` for a known sample of records.

**Acceptance scenarios**:

1. **Given** a fresh initial load of `product.csv`, **When** the pipeline runs, **Then** `serving_product` contains one row per source product record, with zero duplicate business keys in bronze.
2. **Given** a delta load simulating N new products and M updated products, **When** the pipeline reruns, **Then** bronze gains exactly N new rows (plus one new row per updated record whose dedup columns changed) and `silver_contoso__product` reflects the M updates as new SCD2-versioned rows.

---

### Entity 2 - store (Priority: P2)

**Business key**: `StoreKey`.

**Why this priority**: Tiny (74 rows), no foreign-key dependencies on other entities in this spec, second master-data entity — confirms the SCD2 pattern generalizes past `customers`/`product` at very different row-count scales.

**Grain**: One row per store. Confirmed via direct inspection: `StoreKey` unique across all 74 rows, zero nulls.

**Key columns**: `StoreKey`, `StoreCode`, `GeoAreaKey`, `CountryCode`, `CountryName`, `State`, `OpenDate`, `CloseDate`, `Description`, `SquareMeters`, `Status`.

**PII columns**: none.

**Independent test**: Can be extracted and built through bronze → silver → gold → serving, and validated independently of any other entity by running the initial load and querying `serving_store` for the full (small) record set.

**Acceptance scenarios**:

1. **Given** a fresh initial load of `store.csv`, **When** the pipeline runs, **Then** `serving_store` contains one row per source store record (74), with zero duplicate business keys in bronze.
2. **Given** a delta load simulating N new stores and M updated stores (e.g. a `CloseDate` being set), **When** the pipeline reruns, **Then** bronze gains exactly N new rows (plus one new row per updated record whose dedup columns changed) and `silver_contoso__store` reflects the M updates as new SCD2-versioned rows.

---

### Entity 3 - date (Priority: P3)

**Business key**: `DateKey`.

**Why this priority**: Static calendar reference data, no foreign-key dependencies — establishes the "static reference, no SCD" branch of the SCD assignment policy (AGENT.md §6/§12) before the more complex fact entities.

**Grain**: One row per calendar date. Confirmed via direct inspection: `DateKey` unique across all 4,018 rows, zero nulls.

**Key columns**: `Date`, `DateKey`, `Year`, `YearQuarter`, `YearQuarterNumber`, `Quarter`, `YearMonth`, `YearMonthShort`, `YearMonthNumber`, `Month`, `MonthShort`, `MonthNumber`, `DayofWeek`, `DayofWeekShort`, `DayofWeekNumber`, `WorkingDay`, `WorkingDayNumber`.

**PII columns**: none.

**Independent test**: Can be extracted and built through bronze → silver → gold → serving, and validated independently of any other entity by running the initial load and confirming `serving_date` covers the full calendar range with no gaps.

**Acceptance scenarios**:

1. **Given** a fresh initial load of `date.csv`, **When** the pipeline runs, **Then** `serving_date` contains one row per source calendar date (4,018), with zero duplicate business keys in bronze.
2. **Given** a rerun of the same static file (no source changes expected in practice), **When** the pipeline reruns, **Then** row counts are identical in every layer (idempotency proof) — no SCD2/SCD1 versioning applies, since `date` carries no `meta.scd1_columns`/`scd2_columns` (AGENT.md §6/§12, decision 9).

---

### Entity 4 - currencyexchange (Priority: P4)

**Business key**: `Date` + `FromCurrency` + `ToCurrency` (composite — no single-column natural key; a given currency pair's exchange rate is recorded once per date).

**Why this priority**: Static reference/rate data like `date`, but the last of the no-FK-dependency entities and the first entity in this spec with a composite (non-surrogate) business key — worth validating the pattern generalizes to composite keys before the fact entities (which also use composite keys).

**Grain**: One row per (date, currency pair). Confirmed via direct inspection: the (`Date`, `FromCurrency`, `ToCurrency`) triple is unique across all 100,450 rows, zero nulls.

**Key columns**: `Date`, `FromCurrency`, `ToCurrency`, `Exchange`.

**PII columns**: none.

**Independent test**: Can be extracted and built through bronze → silver → gold → serving, and validated independently of any other entity by running the initial load and spot-checking a known (date, currency pair) rate in `serving_currencyexchange`.

**Acceptance scenarios**:

1. **Given** a fresh initial load of `currencyexchange.csv`, **When** the pipeline runs, **Then** `serving_currencyexchange` contains one row per source (date, currency pair) record (100,450), with zero duplicate composite business keys in bronze.
2. **Given** a delta load simulating N new (date, currency pair) rate records, **When** the pipeline reruns, **Then** bronze gains exactly N new rows and every other layer's row count grows by exactly N — no SCD versioning applies (AGENT.md §6/§12, decision 9).

---

### Entity 5 - orders (Priority: P5)

**Business key**: `OrderKey`.

**Why this priority**: First fact/transactional entity in this spec — depends on `customer_key` (onboarded in `001`) and `store_key` (this spec, P2) existing as referenceable business keys, though no physical join/FK constraint is enforced (relational-not-dimensional model, AGENT.md §6). First real exercise of the `apply_scd1` macro (previously built but never exercised against real data in `001`, since `customers` has `meta.scd1_columns: []`).

**Grain**: One row per order (order header). Confirmed via direct inspection: `OrderKey` unique across all 980,666 rows, zero nulls.

**Key columns**: `OrderKey`, `CustomerKey`, `StoreKey`, `OrderDate`, `DeliveryDate`, `CurrencyCode`.

**PII columns**: none (foreign-key references to a customer are not themselves PII values — the PII lives on the `customers` entity).

**Independent test**: Can be extracted and built through bronze → silver → gold → serving, and validated independently of any other entity by running the initial load and querying `serving_orders` for a known sample of order headers.

**Acceptance scenarios**:

1. **Given** a fresh initial load of `orders.csv`, **When** the pipeline runs, **Then** `serving_orders` contains one row per source order record (980,666), with zero duplicate business keys in bronze.
2. **Given** a delta load simulating N new orders and M updated orders (e.g. a `DeliveryDate` correction), **When** the pipeline reruns, **Then** bronze gains exactly N + M new rows (facts are append-only in bronze like every other entity) and `silver_contoso__orders` reflects the M updates as **overwritten** rows (SCD1: same business key, `_updated_at` refreshed, no new version), not new versioned rows.

---

### Entity 6 - orderrows (Priority: P6)

**Business key**: `OrderKey` + `LineNumber` (composite).

**Why this priority**: Second fact entity, depends on `order_key` (this spec, P5) and `product_key` (this spec, P1) existing as referenceable business keys (no physical FK enforced, same rationale as `orders`). Largest entity in this spec (2,349,091 rows) — last, so the smaller/simpler entities are proven first.

**Grain**: One row per order line. Confirmed via direct inspection: the (`OrderKey`, `LineNumber`) pair is unique across all 2,349,091 rows, zero nulls.

**Key columns**: `OrderKey`, `LineNumber`, `ProductKey`, `Quantity`, `UnitPrice`, `NetPrice`, `UnitCost`.

**PII columns**: none.

**Independent test**: Can be extracted and built through bronze → silver → gold → serving, and validated independently of any other entity by running the initial load and querying `serving_orderrows` for a known sample of order lines.

**Acceptance scenarios**:

1. **Given** a fresh initial load of `orderrows.csv`, **When** the pipeline runs, **Then** `serving_orderrows` contains one row per source order-line record (2,349,091), with zero duplicate composite business keys in bronze.
2. **Given** a delta load simulating N new order lines and M updated order lines (e.g. a `Quantity`/`NetPrice` correction), **When** the pipeline reruns, **Then** bronze gains exactly N + M new rows and `silver_contoso__orderrows` reflects the M updates as **overwritten** rows (SCD1), not new versioned rows.

---

## Layer Placement & Transformations

- **Bronze** (`bronze_contoso__<entity>`, one per entity): append-only insert of new/changed records; dedup-before-insert on business key + dedup columns (reuses the existing `dedup_before_insert` macro, unchanged); `_ingested_at` technical column; `full-refresh` forbidden. Uniform across all six entities regardless of their silver SCD treatment — bronze's job (faithful, deduplicated append log) doesn't change based on what silver does with it.
- **Silver**, split by entity kind (per AGENT.md §6/§12 SCD assignment policy):
  - `product`, `store` (dimensions): `silver_<entity>_cleansed` (view, type casts/renaming) → `silver_contoso__<entity>` (incremental, **SCD2** via `apply_scd2` on all non-key columns), mirroring `silver_contoso__customers`/`silver_contoso__customers_cleansed` exactly.
  - `date`, `currencyexchange` (static reference): `silver_contoso__<entity>` only (view, type casts/renaming) — **no SCD2/SCD1 versioning**, no `apply_scd1`/`apply_scd2` call, `meta.scd1_columns`/`meta.scd2_columns` omitted entirely from the contract (not set to `[]`).
  - `orders`, `orderrows` (facts): `silver_<entity>_cleansed` (view, type casts/renaming) → `silver_contoso__<entity>` (incremental, **SCD1** via `apply_scd1` — overwrite-in-place per business key with `_loaded_at`/`_updated_at` technical columns, no `_valid_from`/`_valid_to`/`_is_current`).
  - No cross-model joins in any silver model, for any entity (unchanged constitution rule).
- **Gold** (`gold_<entity>`, one per entity): business logic on top of that entity's own silver model only; business keys (including foreign-key-shaped columns like `customer_key`/`store_key`/`order_key`/`product_key`) passed through as plain columns, no surrogate keys, **no cross-entity joins in this spec** (see Assumptions — deferred until a concrete consumer need requires resolving FKs, consistent with how `001` deferred it).
- **Serving** (`serving_<entity>`, one per entity): a consumable view over each entity's gold model; no row-level security required yet (same as `001`).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST land each of the six source CSVs into its own landing table, overwriting it on every run. **Stage-1 stopgap** (same mechanism as `001`): a native Spark bulk load via OneLake, standing in for Meltano until the Fabric-compatible ingestion path exists.
- **FR-002**: Each bronze model MUST append a record only when its business key + configured dedup columns are not already present in bronze (idempotent, dedup-before-insert, reusing the existing macro unchanged), and MUST NOT support `full-refresh`.
- **FR-003**: Every bronze model MUST enforce a dbt contract with `meta.business_key` and `meta.dedup_columns` populated (`meta.pii_columns: []` for all six — none of these entities carry PII), plus a `_ingested_at` technical column.
- **FR-004**: Every `silver_..._cleansed` model (dimensions and facts) MUST cast column types and rename columns to snake_case per the dbt style guide, and MUST NOT join to any other model.
- **FR-005**: The `product` and `store` silver historization models MUST enforce a dbt contract with `meta.business_key` and `meta.scd2_columns` populated (all non-key columns — both are master data, no SCD1 split), applying SCD2 on any change, matching `silver_contoso__customers`'s pattern exactly.
- **FR-006**: The `orders` and `orderrows` silver historization models MUST enforce a dbt contract with `meta.business_key` and `meta.scd1_columns` populated (all non-key columns — no SCD2 split), applying SCD1 (overwrite-in-place with a `_loaded_at`/`_updated_at` technical-column pair) on any change.
- **FR-007**: The `date` and `currencyexchange` silver models MUST cast column types and rename columns to snake_case per the dbt style guide (same casting/renaming obligation as FR-004's `_cleansed` models, just without a separate `_cleansed` model to hold it — see Layer Placement), and MUST enforce a dbt contract with `meta.business_key` populated while explicitly NOT declaring `meta.scd1_columns` or `meta.scd2_columns` — no versioning macro is invoked for these two entities.
- **FR-008**: Each gold model MUST expose its entity using the business key only (no surrogate key added, including for the composite keys on `currencyexchange` and `orderrows`).
- **FR-009**: The serving layer MUST expose one `serving_<entity>` view per entity, built on that entity's gold model.
- **FR-010**: New columns appearing in any of the six source CSVs MUST be appended automatically (`on_schema_change: append_new_columns`) without breaking that entity's serving view for existing consumers.
- **FR-011**: The delta-load simulator (`scripts/simulate_delta_load/`) MUST be extended to generate new + updated records for all six entities (mirroring the existing `contoso_customers.py` pattern), so FR-002/FR-005/FR-006 are exercisable per entity.

### Data Quality & Non-Functional Requirements

- **NFR-001**: Reruns MUST be idempotent for every entity — rerunning the initial load twice produces identical row counts in bronze, silver, gold, and serving.
- **NFR-002**: PII masking is not applicable to any of the six entities in this spec (no PII columns) — `mask_pii_columns` is not invoked here; it remains exercised/tested via `customers` (`001`).
- **NFR-003**: The extended delta-load simulator MUST be able to generate both new and updated records for each entity, to validate FR-002/FR-005/FR-006 per entity.
- **NFR-004**: The `orders`/`orderrows` SCD1 overwrite-in-place behavior (FR-006) MUST be provably correct on first real use — a delta load with updated records MUST result in the affected `silver_contoso__orders`/`silver_contoso__orderrows` rows being overwritten (same row count as before the delta, only `_updated_at`/attribute values changed), not duplicated.

### Edge Cases

- A dimension record (`product`/`store`) with a known business key arrives with a **different** value in a tracked SCD2 column → new row in bronze, and the silver historization model versions it as a new SCD2 row (prior version's `_valid_to` closed out) — same behavior as `customers`.
- A fact record (`orders`/`orderrows`) with a known business key arrives with a **different** value in a tracked SCD1 column → new row in bronze (append-only, per FR-002), but the silver historization model **overwrites** the existing row in place (SCD1) rather than versioning it.
- A static reference record (`date`/`currencyexchange`) is re-loaded unchanged → deduped out at bronze (FR-002), no-op at silver (no SCD machinery to trigger either way).
- `orders`/`orderrows` reference a `customer_key`/`store_key`/`product_key` that does not (yet) exist in the corresponding dimension's silver/gold model → **out of scope for this spec**: no referential-integrity test/constraint is introduced (consistent with the "relational, not dimensional, no surrogate keys" model — FK resolution is a consumer concern, not enforced by this pipeline); see Assumptions.
- The source introduces a **new column** on any of the six entities → appended automatically per additive schema evolution (FR-010); does not fail existing consumers.
- The source **removes or renames** a column → out of scope, handled as a deliberate, separate change (same as `001`).
- **Duplicate business keys within the same load batch** (including composite keys on `currencyexchange`/`orderrows`) → only the first occurrence per business key is inserted into bronze in a given run.
- **Null or malformed business key** (including any component of a composite key) → the run MUST fail loudly for that record rather than silently dropping or guessing (same convention as `001`).

## Success Criteria *(mandatory)*

- **SC-001**: Initial load lands 100% of source rows for all six entities in their respective bronze models, with zero duplicate (business key + dedup columns) combinations.
- **SC-002**: Rerunning the initial load twice produces identical row counts in bronze, silver, gold, and serving for every entity (idempotency proof).
- **SC-003**: A delta-load simulator run against `product`/`store` with N new + M updated records results in exactly N new bronze rows and M correctly SCD2-versioned rows in the respective silver historization model.
- **SC-004**: A delta-load simulator run against `orders`/`orderrows` with N new + M updated records results in exactly N + M new bronze rows, but exactly N new rows (not N+M) in the respective silver historization model, with the M updated rows overwritten in place (SCD1) — same total current-row count as before plus N, never plus N+M.
- **SC-005**: A delta-load simulator run against `date`/`currencyexchange` with N new records results in exactly N new rows in bronze and every downstream layer, with zero versioning side effects.
- **SC-006**: All contracted columns on every bronze, silver, and gold model introduced by this spec pass their dbt tests and contract resolution with zero failures.
- **SC-007**: All six `serving_<entity>` views resolve and return the expected row count end-to-end, proving the full bronze→serving slice works for each entity.

## Assumptions

- **Meltano→Fabric ingestion remains blocked** for the same reason recorded in `001-onboard-contoso-customers` — this spec reuses the same Stage-1 native-Spark-bulk-load stopgap, extended to six more source files. Whether the landing bootstrap macro is generalized into one parameterized macro or kept as one macro per entity is a plan.md-level implementation decision, not a spec-level constraint.
- **No cross-entity gold joins in this spec**, even though `orders` references `customer_key`/`store_key` and `orderrows` references `order_key`/`product_key` — consistent with how `001` deferred this ("future entities... will introduce the first cross-entity gold-level join"). This spec is that "future" for landing the referenced entities, but not yet for joining them; a consumer-driven join is a separate, later change.
- **`sales.csv` is deliberately excluded** (see Source & Ingestion) — not a scope gap, a considered exclusion to avoid loading the same facts twice in two shapes.
- **No delta/change-data-capture sample exists upstream** for any of these six sources either (same finding as `001` Decision 4) — the delta-load simulator must synthesize new/updated records itself per entity.
- **No row-level security** is required yet for any of the six new serving views (same single-workspace/no-consumer-roles assumption as `001`).
- **This spec covers only these six entities.** `sales.csv` (deliberately excluded) and any entity outside the `csv-1m.7z` release (e.g. from a future non-Contoso source) remain out of scope.
- **Reuses existing macros unchanged**: `dedup_before_insert`, `generate_hash`, `apply_scd2`, `generate_schema_name` are all reused as-is from `001`. `apply_scd1` is reused from `001` but receives its first real (non-empty `meta.scd1_columns`) exercise in this spec.
- Data is synthetic (SQLBI generator output), so no real customer/business PII is ever at risk — consistent with `001`.
