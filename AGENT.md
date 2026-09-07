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

## 3. Guiding principles

1. **Idempotency** — every run (ingestion and transformation alike) can be repeated any number of times without creating duplicates or inconsistent state.
2. **Declarative** — configuration over imperative code wherever possible (dbt models, Meltano configs, Dagster assets as declarative graphs).
3. **Robustness against schema changes** — additive strategy: new columns are appended automatically via `on_schema_change: append_new_columns`, so a schema change on the source stays **backward-compatible** for existing consumers. Removing columns is a deliberate, separate, later step (never an automatic drop).

## 4. Datasets & ingestion strategy

- **Dataset 1:** Contoso 1M (CSV files). The exact source/URL for a reproducible download is still to be determined (see §11).
- More datasets/sources will follow (Stage 2: Oracle, Kafka/Protobuf — see §10).
- **No loading via dbt seeds.** Ingestion runs exclusively through Meltano (`tap-csv` or similar for Stage 1), landing in the lakehouse's landing zone.
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

## 7. Naming conventions

- dbt: `snake_case` naming per the dbt style guide, **except** for layer prefixes: instead of the style guide's `stg_`/`int_` staging/intermediate convention, we deviate and use the medallion layer names directly as prefixes — `bronze_`, `silver_`, `gold_`, `serving_` — since these map 1:1 to our lakehouse layers (§5) and are more meaningful in this project than staging/intermediate.
- **Naming map**:

  | Object | Schema |
  |---|---|
  | Fabric lakehouse | `lh_<domain>` |
  | Fabric warehouse | `wh_<domain>` |
  | dbt schema per layer | `bronze`, `silver`, `gold`, `serving` (via `generate_schema_name`) |
  | dbt model | `<layer>_<source>__<entity>`, e.g. `bronze_contoso__customers` |

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

**Still open (independent of starting Stage 1, to be resolved during implementation):**
- Contoso 1M data source: exact, reproducible download source (URL/license).

From here: autonomous implementation of Stage 1 per this document.
