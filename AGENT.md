# AGENT.md — data-engineering-demo

This document is the binding charter for this repo: goal, architecture, conventions, and working practices for humans **and** coding agents (Claude Code etc.) working here. Documentation language for this repo is **English, strictly** — even though communication with the user happens in German or English. It is updated continuously as decisions are made — see [§11 Decisions](#11-decisions-2026-09-07).

Last updated: 2026-09-07 · Status: **Open questions resolved (§11) — Stage 1 is being implemented on this basis.**

## 1. Purpose of this repo

End-to-end build of a modern data engineering stack on Microsoft Fabric, from ingestion to the semantic layer — as a reference implementation / demo project, built strictly to best practices, serving as a template for further data sources and use cases.

## 2. Tech stack

| Layer | Tool | Purpose |
|---|---|---|
| Ingestion (EL) | [Meltano](https://meltano.com) | Extraction from source systems, loading into the landing zone |
| Processing (T) | [dbt](https://docs.getdbt.com) with the `dbt-fabricspark` adapter | Transformation inside the lakehouse (medallion layers) |
| Storage | Microsoft Fabric Lakehouses; possibly a Fabric Warehouse for the serving layer | Persistence per layer |
| Orchestration | [Dagster](https://dagster.io) | Scheduling, Meltano → dbt dependencies, observability |
| Semantic layer | [Cube Core](https://cube.dev) | Consistent metrics/dimensions for BI tools |

Architecture and tooling decisions are proposals and will be revisited/improved as the project progresses — document change proposals here, not only in chat.

**Local dev environment (Python):** a project-local `.venv` — never install into the global/Store Python.

```powershell
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt   # exact reproduce: requirements.lock.txt
```

Run everything through **[poe](https://poethepoet.natn.io/)** (`pyproject.toml`), which loads the repo-root `.env` so `profiles.yml`'s `env_var('FABRIC_*')` resolves without sourcing it first — no need to activate `.venv`:

```powershell
poe dbt debug ; poe dbt build --select bronze_contoso__product+ ; poe lint
poe upload --local data/contoso/product.csv --remote Files/contoso/product.csv
```

`git config core.longpaths true` is set for this repo. The `.venv` path is shorter than a Store-Python site-packages path, so the deep `dbt-fabricspark` tree installs fine; if pip ever hits MAX_PATH, enable long paths in the registry (admin). The earlier `C:\dbtenv` short-path workaround venv is superseded and can be deleted.

## 3. Guiding principles

1. **Idempotency** — every run (ingestion and transformation alike) can be repeated any number of times without creating duplicates or inconsistent state.
2. **Declarative** — configuration over imperative code wherever possible (dbt models, Meltano configs, Dagster assets as declarative graphs).
3. **Robustness against schema changes** — additive strategy: new columns are appended automatically via `on_schema_change: append_new_columns`, so a schema change on the source stays **backward-compatible** for existing consumers. Removing columns is a deliberate, separate, later step (never an automatic drop).

## 4. Datasets & ingestion strategy

- **Dataset 1:** Contoso 1M (CSV files), sourced from [SQLBI Contoso-Data-Generator-V2-Data](https://github.com/sql-bi/Contoso-Data-Generator-V2-Data/releases), release asset `csv-1m.7z` (MIT-licensed, synthetic data — see §11).
- More datasets/sources will follow (Stage 2: Oracle, Kafka/Protobuf — see §10).
- **No loading via dbt seeds** (dbt seed's row-batched INSERT measured 30+ minutes for 105K rows via Livy — see `specs/001-onboard-contoso-customers/plan.md` Complexity Tracking). Meltano (`tap-csv` or similar) is the long-term ingestion path once a Fabric-compatible target exists (§11); the Stage-1 stopgap is a native Spark bulk load from a CSV uploaded to OneLake Files (`dbt run-operation bootstrap_landing_customer`), landing in the lakehouse's `landing` schema.
- **Initial load:** a one-time full import of all source files.
- **Delta simulation:** a script then continuously simulates delta loads (new records + updates to existing business keys) to keep exercising incremental processing and idempotency.

## 5. Lakehouse architecture (medallion)

| Layer | Characteristics | Details |
|---|---|---|
| **Landing** | Pure landing zone, **overwritten** on every load | 1:1 image of the source, no cleansing |
| **Bronze** | **Append-only**, incremental, `full-refresh` forbidden | `_ingested_at` (technical column). Dedup **before** insert: a record is only inserted if it (business key + configured dedup columns) does not already exist → idempotent incremental runs |
| **Silver** | Cleansing + enrichment, no cross-model joins | Datatype casting, renaming (if needed), additional columns derived from existing columns of the **same** table or lookups — **no** joins with other models |
| **Gold** | Business logic, cross-model joins allowed | Relational (not dimensional) model — see §6 |
| **Serving** | Consumable views/warehouse for BI & semantic layer | Row-level security (RLS) |

Technical columns consistently start with `_` (e.g. `_ingested_at`, `_loaded_at`, `_dbt_updated_at`).

## 6. dbt conventions

- Code strictly follows the official [dbt Labs style guide](https://github.com/dbt-labs/corp/blob/main/dbt_style_guide.md) and dbt best practices (project structure, materializations, testing). To be verified/documented at the start of implementation (research task, see §9).
- **No dimensional model in gold** — the goal is a clean **relational** model. Consumers build their own dimensional models (star schema etc.) on top. Consequence: **no surrogate keys**, business keys are passed through.
- **Model contracts are mandatory** (`contract: {enforced: true}`): table and column descriptions, data types, tests.
- **Central configuration via `meta`.** Each layer has its own model, so a model's `meta` only carries the keys relevant to *that* layer — no per-layer nesting:
  ```yaml
  # bronze model
  models:
    - name: bronze_contoso__customers
      description: "..."
      config:
        contract: {enforced: true}
      meta:
        business_key: [customer_id]
        dedup_columns: [customer_id, updated_at]
        pii_columns: [email, phone_number]   # to be anonymized in non-prod
      columns: [...]
  ```
  ```yaml
  # silver model
  models:
    - name: silver_contoso__customers
      description: "..."
      config:
        contract: {enforced: true}
      meta:
        business_key: [customer_id]
        scd1_columns: [email, phone_number]
        scd2_columns: [address, segment]
      columns: [...]
  ```
  Macros read these `meta` keys instead of duplicating logic (single source of truth).
- **Macros: modular, one purpose per macro.** Planned macros:
  - `dedup_before_insert` — bronze dedup based on business key + `meta.dedup_columns`, makes incremental bronze runs idempotent.
  - `mask_pii_columns` — masks/anonymizes columns from `meta.pii_columns` in non-prod environments. Currently (Stage 1, POC, see §8) there is only one environment (prod), so the macro is still built/tested but is a no-op on `prod` until a non-prod environment exists.
  - `apply_scd1` / `apply_scd2` — generic silver merge logic based on `meta.scd1_columns` / `meta.scd2_columns`.
  - `generate_contract_columns` (optional) — derives a contract YAML skeleton from `meta` (codegen helper, not a runtime macro).
- **SCD assignment policy** (decided 2026-09-09, applied from `002-onboard-contoso-remaining-entities` onward): which SCD treatment an entity's silver model gets is decided by what kind of entity it is, not case-by-case per column:
  - **Master data / dimensions** (e.g. `customers`, `products`, `stores`) → **SCD2**, all non-key columns, full versioned history (`_valid_from`/`_valid_to`/`_is_current`). This is what `silver_contoso__customers` already does.
  - **Facts / transactions** (e.g. `orders`, `orderrows`) → **SCD1**, overwrite-in-place with a `_loaded_at`/`_updated_at` technical-column pair (see `apply_scd1` docstring) — a fact row's own business event doesn't get re-versioned by us; if a source correction arrives, the row is updated, not historized.
  - **Static reference/calendar data** (e.g. `date`, `currencyexchange`) → **neither.** These are dedup'd on ingest into bronze like anything else, but silver is a plain cleansed view/table with no `apply_scd1`/`apply_scd2` call at all — "historizing" a calendar or a daily FX rate has no meaning, `meta.scd1_columns`/`meta.scd2_columns` are simply omitted (not set to `[]`, which would imply "SCD-managed, currently empty").

## 7. Naming conventions

- dbt: `snake_case` naming per the dbt style guide, **except** for layer prefixes: instead of the style guide's `stg_`/`int_` staging/intermediate convention, we deviate and use the medallion layer names directly as prefixes — `bronze_`, `silver_`, `gold_`, `serving_` — since these map 1:1 to our lakehouse layers (§5) and are more meaningful in this project than staging/intermediate.
- **Naming map**:

  | Object | Schema |
  |---|---|
  | Fabric lakehouse | `lh_<domain>` |
  | Fabric warehouse | `wh_<domain>` |
  | dbt schema per layer | `landing`, `bronze`, `silver`, `gold`, `serving` (via `generate_schema_name`) |
  | dbt model | `<layer>_<source>__<entity>`, e.g. `bronze_contoso__customers` |

  **Requires a schema-enabled Fabric Lakehouse** (Fabric preview feature, `creationPayload.enableSchemas: true` at lakehouse creation — a default lakehouse is single-schema and silently ignores dbt's `+schema:` config; briefly hit this the hard way on 2026-09-07 before recreating `lh_contoso` schema-enabled on 2026-09-09, see `specs/001-onboard-contoso-customers/plan.md` Complexity Tracking and `dbt/macros/generate_schema_name.sql`). Layer separation is carried by **both** the dbt schema and the `<layer>_<source>__<entity>` model-naming convention — redundant on purpose, so table names stay self-describing even when browsing across schemas.

## 8. Environment strategy, CI/CD & DevSecOps

- **Environments:** the target picture is eventually **one separate Fabric workspace per environment** (dev/test/prod). For Stage 1 (POC in nature) this is deliberately simplified: **one** Fabric workspace, building directly against "prod", dev/test neglected for now. Configuration (dbt targets, Meltano environments, CI/CD) is still built so a later split into multiple workspaces needs no redesign (workspace/connection parameters are never hardcoded, always via variables/targets).
- CI/CD starts **minimalistic** (GitHub Actions, since the repo lives on GitHub): linting (`sqlfluff`), `dbt compile`/`dbt build` on PRs, no complex multi-environment deploys in Stage 1 (follows from the environment strategy above).
- **Secrets management (Stage 1):** GitHub Actions secrets for CI, local `.env` files (protected by `.gitignore`, never committed). No Key Vault in Stage 1 — can be added later without code/configs ever referencing secrets directly (always via env-var indirection).
- **No secrets in the repo** — tenant ID, workspace ID, client secrets, connection strings, etc. must never end up in git, configs, or logs. Fabric parameters (tenant ID, workspace ID, etc.) are provided by the user separately, outside of chat/repo.
- Principle: least privilege for service principals.

## 9. Agentic development

- Frameworks: **superpowers** (skill/workflow collection for Claude Code) + **spec-kit** (GitHub Spec-Kit), but **kept lean and tailored to data engineering** — Spec-Kit is inherently heavy on software-engineering concerns; here it's trimmed down to what actually adds value for DE artifacts (dbt models, Meltano pipelines, Dagster assets).
- Research backlog before/during setup (document findings here or in subfolders):
  - dbt best practices & style guide (official, dbt Labs) — basis for §6/§7.
  - Official/community best practices for Meltano project structure.
  - Official/community best practices for Dagster project structure (assets, definitions).
  - Best practices for Microsoft Fabric lakehouses (layering, naming, `dbt-fabricspark` specifics).

## 10. Roadmap

**Stage 1 (current focus):**
1. ~~Clarify open questions (§11).~~ ✅ done.
2. ~~Set up agentic coding (superpowers + lean spec-kit for DE).~~ ✅ done — spec-kit installed via the `specify` CLI, then rewritten for data engineering (datasets/entities instead of user stories, dbt model contracts instead of API contracts, medallion repo layout instead of `src/models/services`); superpowers vendored as plain skill files since this environment has no `/plugin` marketplace access. See `.claude/skills/VENDORED.md`.
3. Minimal data engineering setup: dbt + Meltano first, against one Fabric workspace/prod (see §8). Dagster integration is deliberately deferred until the core pipeline (ingestion → bronze → silver → gold) runs cleanly.
4. Acquire the Contoso 1M dataset, ingest via the Meltano CSV extractor (not a seed).
5. Medallion layers (landing → bronze → silver → gold → serving) incl. model contracts, macros, delta-load simulator.
6. Minimal CI/CD pipeline.
7. Dagster integration (orchestrating Meltano → dbt), once steps 3–5 are stable.

**Stage 2 (later, not now):**
- New Meltano extractor tests: **Oracle** and **Kafka (Protobuf)**.
- For Kafka: architecturally new case — **lambda architecture**, streaming topics near-real-time into silver.
- Open research: publicly reachable Oracle test databases and public Kafka/Protobuf schema examples for testing.

## 11. Decisions (2026-09-07)

| # | Question | Decision |
|---|---|---|
| 1 | Orchestration — timing | **Later.** Stage 1 starts with Meltano + dbt without Dagster; Dagster is integrated once the core pipeline stands (see roadmap §10, item 7). |
| 2 | Fabric environment strategy | **Target picture:** separate workspaces per environment. **For now (POC):** one workspace, building directly on prod, dev/test neglected for now (see §8). |
| 3 | Naming map (§7) & gold/serving content (§5) | Proposal in this document **confirmed**, to be implemented as-is. |
| 4 | Macro list (§6) | Proposal (SCD1/SCD2, PII masking, dedup) **confirmed**. |
| 5 | Secrets management | **GitHub Actions secrets + local `.env`** (see §8), no Key Vault in Stage 1. |
| 6 | `meta` config shape (§6) | **Revised:** no nested `bronze:`/`silver:` keys — since each layer is its own model, a model's `meta` carries only the keys relevant to its own layer directly (`business_key` + `dedup_columns`/`pii_columns` on bronze models; `business_key` + `scd1_columns`/`scd2_columns` on silver models). |
| 7 | Layer naming prefixes (§7) | **Revised:** deviate from the dbt style guide's `stg_`/`int_` convention; use `bronze_`/`silver_`/`gold_`/`serving_` prefixes matching the medallion layers instead. |

## 12. Decisions (2026-09-09)

| # | Question | Decision |
|---|---|---|
| 8 | Livy/Spark session reuse (`profiles.yml`) | **Enabled** (`reuse_session: true`). Each cold Livy session start cost ~2-4 min during `001-onboard-contoso-customers`; reusing the session across separate `dbt` invocations removes that overhead for iterative local development. Session is left running (not deleted) between runs. **Caveat found during `002` (2026-09-10):** separate `dbt` invocations don't always reuse the existing session — they sometimes spawn a new one, so on a Fabric capacity that's already near its limit these accumulate and trigger `TooManyRequestsForCapacity` (HTTP 430). Recovery: cancel lingering `InProgress` Livy sessions via `POST .../items/<lakehouseId>/jobs/instances/<jobInstanceId>/cancel` (the `.../livySessions/<id>/cancel` path 404s), then retry. Revisit disabling `reuse_session` if this keeps recurring. |
| 8b | SCD2 expire step — pre_hook → post_hook `MERGE` (`dbt/macros/apply_scd2.sql`, 2026-09-10) | The SCD2 "close out the superseded row" step is a **`config(post_hook=...)`** running an unconditional, self-referential **`MERGE INTO`** with **hardcoded string-literal** schema/table/key args — *not* a pre_hook, and nothing `this`/`model.meta`/`is_incremental()`-derived feeds the `config()` call. Reason (full writeup: the macro's docstring "Bug 3" parts 1-3, and `002` research.md Decision 8): dbt re-runs the whole model template in a stub context to extract `config()` calls, so any adapter/manifest-dependent value fed into a `config()` argument silently resolves wrong there; Delta also rejects a self-referential correlated subquery in `UPDATE` but allows the equivalent `MERGE`. `customers` (`001`) was migrated to this design and re-validated with a live delta. |
| 9 | SCD assignment policy for onboarding remaining Contoso entities (§6) | **Master data/dimensions → SCD2** (already the pattern for `customers`); **facts/transactions → SCD1** (overwrite-in-place); **static reference/calendar data → neither** (plain cleansed table, no `apply_scd1`/`apply_scd2`). See §6. |
| 10 | Contoso fact structure — `sales.csv` (flat) vs. `orders.csv`+`orderrows.csv` (normalized) | **`orders` + `orderrows`.** Verified by direct inspection: `sales.csv` is `orders` ⋈ `orderrows` already flattened (identical key, identical row count) — onboarding all three would load the same facts twice in different shapes. The normalized pair also better mirrors a real OLTP source. |
| 11 | Contoso `date.csv`/`currencyexchange.csv` | Treated as **static reference data**, not master data — bronze dedup applies as normal, but silver has no SCD1/SCD2 versioning (see decision 9). |

**Resolved during implementation:**
- Contoso 1M data source (2026-09-07, via `/speckit-specify` clarification on `specs/001-onboard-contoso-customers/spec.md`): [SQLBI Contoso-Data-Generator-V2-Data](https://github.com/sql-bi/Contoso-Data-Generator-V2-Data/releases), release asset `csv-1m.7z` (MIT-licensed, synthetic data).

From here: autonomous implementation of Stage 1 per this document.
