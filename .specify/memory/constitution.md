# data-engineering-demo Constitution

**Authoritative source**: [AGENT.md](../../AGENT.md) at the repo root. This file is the enforceable gate-checklist spec-kit (`/speckit-plan`) checks new work against; AGENT.md carries the full rationale, tech stack, and roadmap. If the two ever disagree, update both in the same change — never let them drift.

## Core Principles

### I. Idempotency
Every run — ingestion (Meltano) and transformation (dbt) alike — MUST be repeatable any number of times without creating duplicate rows or inconsistent state. Bronze incremental models MUST dedup on business key + configured dedup columns before insert. `full-refresh` on bronze models is forbidden.

### II. Declarative over imperative
Pipeline behavior is expressed as configuration wherever possible: dbt models/config, Meltano `meltano.yml`, Dagster assets as a declarative graph. Avoid one-off imperative scripts for anything that recurs.

### III. Additive schema evolution (NON-NEGOTIABLE)
Schema changes on a source MUST stay backward-compatible for existing consumers: new columns are appended (`on_schema_change: append_new_columns`), never silently dropped. Removing a column is a deliberate, separate, later change — never automatic.

### IV. Medallion layering with strict boundaries
Landing (overwritten every load, no cleansing) → Bronze (append-only, incremental, `_ingested_at`, dedup-before-insert) → Silver (cleansing/type-casting/renaming/enrichment from the *same* table or lookups only — no cross-model joins) → Gold (business logic, cross-model joins allowed, relational not dimensional) → Serving (views/warehouse with row-level security). A model must not skip or blur these boundaries.

### V. Model contracts are mandatory
Every dbt model enforces `contract: {enforced: true}` with full column descriptions, data types, and tests. Central per-layer configuration lives in the model's `meta` block (business key, dedup columns, PII columns on bronze; business key, SCD1/SCD2 columns on silver) — see AGENT.md §6. No surrogate keys: business keys are passed through untouched (the goal is a clean relational model, not a dimensional one).

### VI. Security & secrets (NON-NEGOTIABLE)
No secrets (tenant IDs, workspace IDs, client secrets, connection strings) ever committed to the repo, logged, or hardcoded. Local `.env` (gitignored) and GitHub Actions secrets only, per AGENT.md §8. Least privilege for every service principal. PII columns (per `meta.pii_columns`) must be maskable in non-prod, even while Stage 1 runs everything against a single (prod) workspace.

## Additional Constraints

- Tech stack, naming conventions, and layer-naming prefixes (`bronze_`/`silver_`/`gold_`/`serving_`, deliberately deviating from the dbt style guide's `stg_`/`int_`) are fixed by AGENT.md §2/§7 and are not re-litigated per feature.
- No dbt seeds for source data — ingestion is exclusively via Meltano.
- Stage 2 scope (Oracle, Kafka/Protobuf, lambda streaming to silver) is explicitly out of scope until Stage 1 is stable (AGENT.md §10).

## Development Workflow

- Spec → Plan → Tasks → Implement, scoped per dataset/pipeline change (see `.specify/templates/`), organized by dataset/entity rather than by "user story" — each dataset's full bronze→silver→gold→serving slice is the independently testable increment.
- `dbt build` (compile + run + test) must pass, and model contracts must resolve, before a change is considered done.

## Governance

This constitution supersedes ad-hoc practice for anything it covers. Amendments require updating this file and the corresponding section of AGENT.md in the same change, with the version/date bumped below.

**Version**: 1.0.0 | **Ratified**: 2026-09-07 | **Last Amended**: 2026-09-07
