# Data Model: Onboard Contoso Customers

Phase 1 output for `specs/001-onboard-contoso-customers/plan.md`. Defines the `customers` entity's contract shape per layer. All five models are **new**.

## Source columns (from `customer.csv`, confirmed in research.md Decision 2)

`CustomerKey, GeoAreaKey, StartDT, EndDT, Continent, Gender, Title, GivenName, MiddleInitial, Surname, StreetAddress, City, State, StateFull, ZipCode, Country, CountryFull, Birthday, Age, Occupation, Company, Vehicle, Latitude, Longitude`

Renamed to snake_case from silver onward per the dbt style guide (`CustomerKey` → `customer_key`, `GivenName` → `given_name`, etc.) — bronze keeps source column names as-is (bronze is a faithful append-only copy of the source, casing/renaming is a silver concern).

## Entity: customers

## Materialization strategy (resolved during `/speckit-analyze`, 2026-09-07)

| Model | Materialization | Why |
|---|---|---|
| `bronze_contoso__customers` | `incremental` (append, via `dedup_before_insert`) | Append-only per constitution; must accumulate across runs |
| `silver_contoso__customers_cleansed` | `view` | Pure transformation, no state to persist; **not** `ephemeral` — dbt cannot enforce contracts on ephemeral models, and every model here requires one |
| `silver_contoso__customers` | `incremental` (merge) | SCD2 history must persist and be updated (close out `_valid_to`) across runs — a `table` rebuild would destroy prior versions |
| `gold_customers` | `table` (or `view` — implementation detail, not contract-relevant) | Reads current-version silver only; no cross-run state to preserve at this entity count |
| `serving_customers` | `view` | Thin pass-through over gold |

### bronze_contoso__customers

**New model.** Append-only, incremental, `on_schema_change: append_new_columns`, `full-refresh` forbidden. **Stage-1 note**: sources from `source('contoso_landing', 'landing_customer')`, a table bulk-loaded by `dbt run-operation bootstrap_landing_customer` from `data/contoso/customer.csv` via OneLake (temporary landing stand-in — see plan.md Complexity Tracking) instead of a Meltano-populated landing table.

| Contract field | Value |
|---|---|
| `meta.business_key` | `[CustomerKey]` |
| `meta.dedup_columns` | `[GeoAreaKey, StartDT, EndDT, Continent, Gender, Title, GivenName, MiddleInitial, Surname, StreetAddress, City, State, StateFull, ZipCode, Country, CountryFull, Birthday, Age, Occupation, Company, Vehicle, Latitude, Longitude]` — i.e. all non-key columns; a row is only re-inserted if the business key + any of these differ from what's already in bronze |
| `meta.pii_columns` | `[GivenName, MiddleInitial, Surname, StreetAddress, City, ZipCode, Birthday, Company]` |
| Technical columns | `_ingested_at` (load timestamp) |
| Tests | `not_null` + `unique` on `CustomerKey` is **not** applied here — bronze is append-only and may legitimately hold multiple historical rows per business key over time (see silver for the current/history view); instead test `not_null` on `CustomerKey` and rely on the `dedup_before_insert` macro for uniqueness-per-load-batch |

### silver_contoso__customers_cleansed

**New model.** View. Type casts + snake_case rename only — no SCD, no joins to other models (none exist yet). Separated from historization so the cleansing logic stays independently testable/reusable, per the "one purpose per model" convention (mirrors the macro convention in AGENT.md §6).

| Contract field | Value |
|---|---|
| `meta.business_key` | `[customer_key]` |
| Type casts | `start_dt`/`end_dt` → date; `age` → integer; `latitude`/`longitude` → numeric/float; all others → string/varchar |
| Tests | `not_null` + `unique` on `customer_key` |

### silver_contoso__customers

**New model.** Incremental/merge. Applies SCD2 versioning on top of `silver_contoso__customers_cleansed`. No joins to other models.

Customers is classic master data (resolved during `/speckit-analyze`, 2026-09-07: was previously split SCD1/7-cols + SCD2/11-cols, leaving 5 columns — `start_dt`, `end_dt`, `gender`, `title`, `age` — unassigned to either bucket, an underspecification bug). **All** non-key columns now get full SCD2 history; there is no SCD1 split for this entity.

| Contract field | Value |
|---|---|
| `meta.business_key` | `[customer_key]` |
| `meta.scd1_columns` | `[]` — none for this entity (master data gets full history, not overwrite-in-place) |
| `meta.scd2_columns` | `[geo_area_key, start_dt, end_dt, continent, gender, title, given_name, middle_initial, surname, street_address, city, state, state_full, zip_code, country, country_full, birthday, age, occupation, company, vehicle, latitude, longitude]` — all 23 non-key columns; versioned with `_valid_from`/`_valid_to`/`_is_current` per the `apply_scd2` macro |
| Tests | `not_null` + `unique` on `customer_key` scoped to current-version rows (`_is_current = true`) |

Note (research.md Decision 3): `start_dt`/`end_dt` are plain source attributes tracked like any other SCD2 column — **not** used as our own SCD2 valid-from/valid-to mechanism; those remain separate, macro-generated technical columns (`_valid_from`, `_valid_to`).

### gold_customers

**New model.** Business logic on top of silver; relational, no surrogate key.

| Contract field | Value |
|---|---|
| `meta.business_key` | `[customer_key]` |
| Columns | Current-version (`_is_current = true`) rows from `silver_contoso__customers`, business-key passthrough; no cross-entity joins yet (no other gold entities exist) |
| Tests | `not_null` + `unique` on `customer_key` |

### serving_customers

**New model.** Plain view over gold; no RLS for this change (spec Assumptions).

| Contract field | Value |
|---|---|
| Columns | All of `gold_customers`, unfiltered |
| RLS | None (out of scope, see spec.md Assumptions) |

## Relationships

None yet — `customers` is the only entity onboarded so far. Future entities (e.g. `orders`, referencing `customer_key`) will introduce the first cross-entity gold-level join.
