# Phase 1 Data Model: Dagster asset inventory

This feature introduces no new dbt models, columns, or contracts — "entities" here are the
**Dagster assets** the orchestration layer defines, and their "contract" is the asset key +
metadata + check shape each one commits to. Grouped by the spec's three capabilities.

## Capability 1 — dbt-model assets (one per dbt model, Component-derived)

Not hand-listed: `dagster_dbt.DbtProjectComponent` derives one asset per dbt model from the
manifest (33 models at time of writing, per dbt's own parse output 2026-09-10 — 7 bronze + 12
silver [5 cleansed views + 5 SCD1/SCD2 historized models for customers/product/store/orders/
orderrows + 2 plain models for date/currencyexchange, which have no separate cleansed view] + 7
gold + 7 serving; exact count tracks the manifest, not this document).

| Aspect | Shape |
|---|---|
| Asset key | Derived from the dbt model name (default translation: `<model_name>`, e.g. `bronze_contoso__orders`) — no custom key remapping planned. |
| Group | `group_name` set per layer via translation (`bronze`, `silver`, `gold`, `serving`) so the Dagster UI groups match the medallion layers. |
| Dependencies | Inferred from `ref()`/`source()` in the dbt manifest — automatic, not hand-maintained. |
| Checks | Every dbt data test → one Dagster `AssetCheckResult` (via `DagsterDbtTranslatorSettings(enable_asset_checks=True)` — research.md Decision 4/see dagster-dbt docs). |
| Metadata | Whatever `dagster-dbt` emits by default (row counts where the adapter supports it, compiled SQL, timing) — no custom metadata added in this change. |
| Materialization | Runs the underlying dbt model exactly as `dbt build` would — no `--full-refresh`, no behavior change (FR-008, FR-015). |

## Capability 2 — Landing assets (one per Contoso entity, plain Python)

| Field | Value |
|---|---|
| Asset key | `landing_<entity>` (`landing_customers`, `landing_product`, `landing_store`, `landing_orders`, `landing_orderrows`, `landing_date`, `landing_currencyexchange`) |
| Materialization | 1. Upload `data/contoso/<entity>.csv` → `Files/contoso/<entity>.csv` (reuses `scripts/upload_to_onelake.py`'s upload logic). 2. `dbt run-operation bootstrap_landing_table` for that entity via the shared `DbtCliResource` (reuses the existing macro/args unchanged). |
| Metadata emitted | `entity` (string), `csv_path` (local + remote), `landed_row_count` (int, from the macro's existing `log(...)` row-count query) — satisfies FR-009. |
| Downstream link | Each entity's dbt bronze source (`contoso_landing.landing_<entity>` in `sources.yml`) gets `meta.dagster.asset_key: ["landing_<entity>"]` added — an additive edit to existing source metadata, connecting `landing_<entity>` → `bronze_contoso__<entity>` (FR-007, research.md Decision 5). |
| Idempotency | Matches the existing macro: `CREATE OR REPLACE TABLE` — rerunning a landing asset with the same CSV is a no-op change to the landed data (NFR-001). |

## Capability 3 — Delta-load job & schedule (plain Python)

| Field | Value |
|---|---|
| Job | `delta_load_job` — selects and re-materializes: (1) run each `scripts/simulate_delta_load/<entity>.py` that exists (mutates the local CSV), (2) the full `landing_*` → dbt-model asset selection, in dependency order. |
| Schedule | `delta_load_schedule` — `cron_schedule` from config (default `"0 */6 * * *"`), `default_status=DefaultScheduleStatus.STOPPED` (FR-011, NFR-005, research.md Decisions 6–7). |
| Config surface | Per-entity `--new`/`--updated` counts and the cron cadence are schedule/job config, not hardcoded — changing the delta volume or cadence needs no code edit. |
| Idempotency | Running the job twice with no new simulation in between changes nothing in any layer (SC-005's third clause) — this falls out of the existing bronze dedup + SCD1/SCD2 behavior; the job adds no new dedup logic of its own. |

## Cross-cutting: configuration & secrets

| Setting | Source | Notes |
|---|---|---|
| Fabric workspace/lakehouse IDs, OneLake DFS endpoint | repo-root `.env` (existing `FABRIC_*` vars) | Read the same way `scripts/upload_to_onelake.py` already reads them — no new env vars unless a genuine gap appears during implementation. |
| dbt target/profile | `dbt/profiles.yml`, `target: dev` | Unchanged; `profiles_dir` passed explicitly to the dbt resource (research.md Decision 4). |
| Azure auth | `az login` (Azure CLI), same session dbt already uses | No new credential type introduced (FR-004, constitution VI). |

No PII, SCD, dedup, or business-key semantics change — those all live in the dbt layer untouched.
