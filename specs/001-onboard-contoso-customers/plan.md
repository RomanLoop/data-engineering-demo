# Implementation Plan: Onboard Contoso Customers

**Branch**: `001-onboard-contoso-customers` | **Date**: 2026-09-07 | **Spec**: [spec.md](spec.md)

**Input**: Pipeline specification from `specs/001-onboard-contoso-customers/spec.md`

## Summary

Onboard the `customers` entity from the SQLBI Contoso V2 sample dataset (`csv-1m.7z` → `customer.csv`, 104,990 rows, business key `CustomerKey`) end-to-end: landing (native Spark bulk load via OneLake, Stage-1 stopgap for the blocked Meltano→Fabric path) → bronze (append-only, dedup-before-insert) → silver-cleansed (type casts/renaming, view) → silver-historized (SCD2 on all columns — customers is master data) → gold (business logic, no surrogate keys) → serving (plain view, no RLS yet). This is the first entity onboarded, so it also establishes the shared macros (`dedup_before_insert`, `mask_pii_columns`, `apply_scd1`, `apply_scd2`) and the dbt project scaffolding that later entities and sources will reuse.

## Technical Context

**Source system(s)**: SQLBI Contoso-Data-Generator-V2-Data, release `ready-to-use-data`, asset `csv-1m.7z`, file `customer.csv` (MIT-licensed, synthetic data; see research.md Decision 1–2).

**Meltano extractor/loader**: **Blocked for Stage 1** (research finding during `/speckit-analyze`, 2026-09-07): the only available Meltano Azure Blob target, `target-azureblobstorage`, authenticates via storage account key; Fabric OneLake accepts Azure AD auth only (service principal), no shared-key/SAS. No compatible Meltano→Fabric target exists today. **Recommended long-term path** (not built in this change): land via `target-azureblobstorage` into a plain Azure Storage Account (account-key auth works there), then reference it from `lh_contoso` via a **Fabric OneLake Shortcut** (no data copy, officially supported pattern for exactly this case). **Stage-1 stopgap**: `data/contoso/customer.csv`, bulk-loaded into `landing.landing_customer` via OneLake + a native Spark job, stands in for the landing zone (see Constitution Check exception below).

**dbt layer(s) touched**: five models, single entity (silver split into cleansing + historization — see Constitution Check/Complexity Tracking for why):
- `bronze_contoso__customers`
- `silver_contoso__customers_cleansed` (new — cleansing only, no SCD)
- `silver_contoso__customers` (historization — SCD2 on top of the cleansed view)
- `gold_customers`
- `serving_customers`

**Fabric objects**: lakehouse `lh_contoso`, schema-enabled (recreated 2026-09-09 with `creationPayload.enableSchemas: true`, after first discovering the default lakehouse type silently ignores dbt's `+schema:` config — AGENT.md §7), with real `landing`/`bronze`/`silver`/`gold`/`serving` schemas. No warehouse needed yet (serving is a lakehouse view, not exposed via Fabric Warehouse at this stage).

**Orchestration**: manual/CLI-triggered (`scripts/upload_to_onelake.py` + `dbt run-operation bootstrap_landing_customer` then `dbt build --select ...`; `meltano run ...` once unblocked) — Dagster not yet integrated, per AGENT.md §10 roadmap item 7.

**Testing**: dbt contract enforcement + column tests (not_null/unique on business key at minimum) on all five models; delta-load simulator run exercising both "new customers" and "updated customers" scenarios (per spec NFR-003); rerun-twice idempotency check on the initial load (per spec SC-002).

**Performance/volume**: 104,990 rows, single flat CSV (23.8 MB) — no performance concerns at this scale; no fixed run-time budget defined yet (Stage 1 has no SLA).

**Constraints**: silver MUST NOT join other models (no other entities exist yet, so this is moot for now but stays true going forward); bronze MUST remain append-only, no `full-refresh`; no surrogate keys anywhere; `CustomerKey` passed through as-is (renamed `customer_key` in silver/gold per snake_case); the cleansing model MUST be a `view` (not `ephemeral`) since dbt cannot enforce contracts on ephemeral models, and every model here requires one.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design. See `.specify/memory/constitution.md`.*

- **I. Idempotency**: ✅ Planned — bronze dedup-before-insert on `customer_key` + dedup columns (macro `dedup_before_insert`); SC-002 explicitly tests rerun idempotency.
- **II. Declarative**: ✅ dbt models/config + a small, config-driven bulk-load macro; no bespoke imperative ingestion scripts beyond the (separately-specified) delta-load simulator, which is itself reusable and declarative-config-driven per AGENT.md §4.
- **III. Additive schema evolution**: ✅ `on_schema_change: append_new_columns` on incremental models; FR-008 makes this an explicit requirement.
- **IV. Medallion layering**: ✅ Landing (seed, overwritten) → bronze (append-only) → silver-cleansed (view, no cross-model joins) → silver-historized (SCD2) → gold (business logic, business-key-only) → serving (view). No boundary blurred.
- **V. Model contracts mandatory**: ✅ All five models get `contract: {enforced: true}` + full `meta` (business_key/dedup_columns/pii_columns on bronze; business_key on the cleansed view; business_key/scd2_columns on the historized model — no scd1_columns for this entity) per FR-003/FR-005.
- **VI. Security & secrets**: ✅ No secrets involved (public, unauthenticated dataset download; Fabric tenant/workspace IDs kept in local `.env`, never committed — see `.env.example`); PII columns tagged and covered by `mask_pii_columns` even though it's a no-op in Stage 1's single-workspace setup (NFR-002).
- **Additional Constraint — "Meltano-only ingestion"**: ⚠️ **EXCEPTION** — see Complexity Tracking below. Justified, temporary, tracked.

One tracked exception (seed stopgap) — see Complexity Tracking. All six core principles otherwise hold.

## Project Structure

### Documentation (this change)

```text
specs/001-onboard-contoso-customers/
├── plan.md              # This file
├── research.md           # Phase 0 output
├── data-model.md         # Phase 1 output — entity & contract detail
├── quickstart.md         # Phase 1 output — pipeline validation guide
└── tasks.md              # Phase 2 output (/speckit-tasks — not created by this command)
```

### Repository layout (this change)

```text
meltano/                                      # DEFERRED this change — see Complexity Tracking
└── extract/contoso/                          # tap-csv config for customer.csv, once a Fabric-compatible target exists

data/contoso/
└── customer.csv                              # Stage-1 stopgap landing source, local copy (temporary — see Complexity Tracking)

dbt/models/bronze/contoso/
└── _contoso__sources.yml                     # source('contoso_landing', 'landing_customer') — the bulk-loaded landing table

dbt/models/
├── bronze/contoso/
│   ├── bronze_contoso__customers.sql
│   └── bronze_contoso__customers.yml         # contract + meta (business_key, dedup_columns, pii_columns)
├── silver/contoso/
│   ├── silver_contoso__customers_cleansed.sql    # view — type casts/renaming only
│   ├── silver_contoso__customers_cleansed.yml    # contract + meta (business_key)
│   ├── silver_contoso__customers.sql             # incremental, window-function SCD2 on all non-key columns
│   └── silver_contoso__customers.yml             # contract + meta (business_key, scd2_columns)
├── gold/
│   ├── gold_customers.sql
│   └── gold_customers.yml
└── serving/
    ├── serving_customers.sql
    └── serving_customers.yml

dbt/macros/
├── dedup_before_insert.sql                   # new — hash-based dedup, reused by bronze + silver historization
├── generate_hash.sql                          # new — deterministic hash over a column list
├── mask_pii_columns.sql                       # new
├── apply_scd1.sql                              # new — not used by customers, but built now for future SCD1 entities
├── apply_scd2.sql                              # new — expire_scd2_current_rows pre-hook
├── generate_schema_name.sql                    # new — real per-layer schemas instead of dbt's `<target>_<custom>` default
└── bootstrap_landing_customer.sql              # new — native Spark bulk load of the landing CSV (Stage-1 stopgap)

scripts/
├── simulate_delta_load/contoso_customers.py   # generates new + updated customer records for delta-load testing
└── upload_to_onelake.py                       # uploads a local file to the lakehouse's OneLake Files area
```

No `dagster/` path yet (orchestration not introduced, per AGENT.md §10).

**Structure Decision**: Deviates from the override template's single-silver-model default by splitting silver into a cleansing view + a historization model (see Complexity Tracking — not a constitution violation, just a structural addition), and by substituting a native Spark bulk load for Meltano in Stage 1 (a tracked, temporary exception, see Complexity Tracking). This is the first entity, so all four macros are created rather than reused; every subsequent entity/source is expected to reuse them without modification unless a genuinely new dedup/PII/SCD shape appears.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|---------------------------------------|
| Landing populated via a native Spark bulk load (OneLake upload + `dbt run-operation bootstrap_landing_customer`) instead of Meltano (violates AGENT.md §4 / constitution Additional Constraints: "Meltano-only") | Meltano→Fabric ingestion is blocked: the only Meltano Azure Blob target (`target-azureblobstorage`) needs a storage account key, but Fabric OneLake only accepts Azure AD auth — no compatible target exists today. `dbt seed` (the originally planned stopgap) was tried first and measured 30+ minutes for 105K rows before killing its own Livy session — not viable either. Blocking the entire first entity on an unrelated infrastructure gap would stall Stage 1 for no data-modeling reason. | Waiting until the Azure Storage Account + Fabric OneLake Shortcut (or an AAD-capable target) is built was rejected for *this* change — it's real but separate work, tracked in spec.md Assumptions, not in this change's tasks.md. `dbt seed` was rejected after being measured as impractically slow for this row count. The bulk-load bootstrap is explicitly temporary: bronze/silver/gold/serving are unaffected by the landing mechanism (they only care that a `source()`-registered landing relation exists), so swapping it for Meltano later is a small, isolated change. |

**Removal condition**: once the Meltano→Fabric ingestion path exists (new spec), replace `landing.landing_customer` (populated by `bootstrap_landing_customer`) with the real Meltano-populated landing table, update the `contoso_landing` source definition, and delete the bootstrap macro + `scripts/upload_to_onelake.py` — no changes needed downstream of landing.
