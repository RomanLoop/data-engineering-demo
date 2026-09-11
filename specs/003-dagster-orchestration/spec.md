# Pipeline Specification: Dagster orchestration of the Contoso Stage-1 pipeline

**Branch**: `003-dagster-orchestration`

**Created**: 2026-09-10

**Status**: Draft

**Input**: User description: "Orchestrate the Contoso Stage-1 pipeline end-to-end with Dagster: OneLake CSV upload → landing bootstrap (per entity) → dbt build (bronze→silver→gold→serving), as a single asset graph. Use the modern dg / dagster-components project scaffold (create-dagster) in a new top-level orchestration/ package. Integrate the dbt project via dagster-dbt (manifest-driven, one Dagster asset per dbt model, reusing dbt/profiles.yml and the existing CLI auth + .env). Model each landing_<entity> table as a Dagster asset (materialized by uploading data/contoso/<entity>.csv to OneLake Files then calling the bootstrap_landing_table macro) so the dbt bronze sources depend on it. Add a Dagster schedule that periodically runs the delta-load simulator (scripts/simulate_delta_load/*) → upload → re-land → dbt build, to continuously exercise incremental processing and idempotency (AGENT.md §4). Stage 1: local `dagster dev`, one Fabric workspace (prod), no Dagster+ / deployment. Add dagster, dagster-dbt, dagster-webserver and the dg tooling to the project .venv (pinned in requirements.txt + requirements.lock.txt), runnable via poe. Keep it lean and DE-tailored per AGENT.md §9. This is roadmap item 7 (AGENT.md §10); Meltano is still blocked so the landing bootstrap remains the Stage-1 ingestion stand-in."

## Overview

Today the Contoso pipeline runs as a hand-sequenced set of commands: `python scripts/upload_to_onelake.py …`, then `dbt run-operation bootstrap_landing_table …` per entity, then `dbt build --select …`, and `python scripts/simulate_delta_load/…` when exercising incremental behaviour. Nothing records what ran, in what order, whether it succeeded, or how fresh each layer is.

This change introduces **Dagster** as the orchestration layer (roadmap item 7, AGENT.md §10) so the whole Stage-1 flow — **CSV upload → landing bootstrap → dbt build (bronze → silver → gold → serving)** — is one declarative asset graph that can be run, observed, and scheduled from a single place. It also puts the delta-load simulation on a schedule so incremental-processing and idempotency behaviour is exercised continuously rather than only by hand.

No data contracts, model logic, or medallion boundaries change. The dbt project, the landing bootstrap macro, the OneLake upload helper, and the delta-load simulators are all reused as-is; Dagster wraps and sequences them.

**Business/analytics value**: one operational surface for the pipeline (lineage, run history, freshness, failure alerting), reproducible end-to-end runs, and a standing regression signal that incremental loads stay correct and idempotent.

## Source & Ingestion

- **Source system**: Contoso 1M CSV export (unchanged — see `specs/001-onboard-contoso-customers` / `002-onboard-contoso-remaining-entities`). Seven entities: `customers`, `product`, `store`, `orders`, `orderrows`, `date`, `currencyexchange`.
- **Extraction method**: unchanged Stage-1 stand-in — `scripts/upload_to_onelake.py` (OneLake Files upload via the ADLS Gen2 DFS API, `AzureCliCredential`) followed by the `bootstrap_landing_table` dbt macro (native Spark bulk CSV → Delta). Meltano remains blocked (AGENT.md §11); this spec does not unblock or replace it.
- **Load pattern**: both — a one-time initial full load of all seven entities, then repeated delta loads produced by `scripts/simulate_delta_load/*` (new + updated rows appended/rewritten into the same CSVs).
- **Expected volume & frequency**: same as the existing pipeline (serving row counts ≈ customers 105,495 / product 2,545 / store 76 / date 4,033 / currencyexchange 100,475 / orders 980,966 / orderrows 2,349,591). Orchestrated runs are developer-initiated during Stage 1; the delta-load schedule runs on a low, capacity-safe cadence.
- **Landing format**: unchanged — UTF-8 CSV with header, uploaded to `Files/contoso/<entity>.csv`, bulk-loaded into the `landing` schema as Delta.

## Orchestrated Capabilities & Behaviour

<!--
  This change is orchestration infrastructure, not a data-entity onboarding.
  The independently testable / deliverable units are ORCHESTRATION CAPABILITIES,
  prioritised P1..P3. Each is a viable increment on its own.
-->

### Capability 1 - dbt project as a Dagster asset graph (Priority: P1) 🎯 MVP

**What it delivers**: the existing dbt project loaded into Dagster via `dagster-dbt`, manifest-driven, **one Dagster asset per dbt model** across bronze/silver/gold/serving, with dbt tests surfaced as Dagster **asset checks**. Dagster reuses `dbt/profiles.yml` (target `dev`), the existing Azure CLI auth, and the repo-root `.env`. `dagster dev` renders the full lineage graph; materialising it is equivalent to `dbt build`.

**Why this priority**: this is the smallest slice that delivers the core value — a single observable surface with lineage, run history, and per-model success/failure — and everything else builds on it. It is usable even if landing and scheduling are still manual.

**Independent test**: launch `dagster dev`; the asset graph shows every dbt model with correct upstream/downstream edges. Materialising all assets runs the same models `dbt build` would, and all asset checks (= dbt tests) pass. Selecting a subset (e.g. `serving_orders` and its upstreams) materialises exactly that subgraph.

**Acceptance scenarios**:

1. **Given** a valid `dbt/` project and a working `az login` session, **When** `dagster dev` is started, **Then** the UI lists one asset per dbt model (33 models at time of writing) grouped by layer, with lineage matching `dbt ls`/the manifest, and zero code-location load errors.
2. **Given** the asset graph, **When** all assets are materialised from the UI, **Then** the run succeeds, every model is built, and every dbt test appears as a passed asset check.
3. **Given** one model's SQL is broken, **When** its asset is materialised, **Then** that asset run fails with the dbt error surfaced in the Dagster run logs and downstream assets are not materialised.

---

### Capability 2 - Landing + OneLake-upload assets (full chain) (Priority: P2)

**What it delivers**: each `landing_<entity>` table modelled as a Dagster asset whose materialisation (a) uploads `data/contoso/<entity>.csv` to `Files/contoso/<entity>.csv` in OneLake and (b) runs `bootstrap_landing_table` for that entity. The dbt bronze sources (`source('contoso_landing', 'landing_<entity>')`) are wired as downstream of these assets, so the graph is connected top to bottom: **upload/land → bronze → silver → gold → serving**.

**Why this priority**: turns the graph from "dbt only" into the full end-to-end chain the feature is about, so a single materialise-from-the-top produces a complete refresh with no manual `run-operation`/upload steps.

**Independent test**: materialise a single `landing_orders` asset → the CSV is present in OneLake and `landing.landing_orders` is rebuilt with the expected row count. Materialise the whole graph from the landing assets down on a clean lakehouse → all seven entities land and build through serving with the expected serving row counts.

**Acceptance scenarios**:

1. **Given** local `data/contoso/*.csv` files and OneLake access, **When** the `landing_<entity>` assets are materialised, **Then** each CSV is uploaded and each `landing.landing_<entity>` Delta table is (re)created with row count equal to the source CSV, and Dagster records the row count as asset metadata.
2. **Given** the landing assets exist, **When** the full graph is materialised, **Then** landing → bronze → … → serving all run in dependency order in one Dagster run, and serving row counts match the pipeline's known-good figures.
3. **Given** a landing asset materialised twice on the same CSV, **When** bronze is rebuilt after each, **Then** bronze row counts are identical (idempotent — landing is overwrite, bronze dedups).
4. **Given** the `orders` bronze model is append-only, **When** landing/bronze assets are materialised, **Then** no `--full-refresh` is issued against any bronze model.

---

### Capability 3 - Scheduled delta-load exercise (Priority: P3)

**What it delivers**: a Dagster job + schedule that, on a cadence, runs the delta-load simulators (`scripts/simulate_delta_load/*` — new + updated rows into the CSVs) and then re-materialises the upload → land → build chain, so incremental processing and idempotency (AGENT.md §4, constitution I) are exercised without anyone running commands by hand. Freshness is visible per asset.

**Why this priority**: valuable as a standing regression signal, but strictly additive — the pipeline is fully usable via Capabilities 1–2 without it. Depends on both.

**Independent test**: trigger the delta-load job manually (or let the schedule fire once); confirm the simulators added N new / mutated M rows, the chain re-materialised, bronze grew by exactly N per entity, silver reflects the M updates with correct SCD1/SCD2 behaviour, and an immediately following re-run of the same job changes nothing (idempotent).

**Acceptance scenarios**:

1. **Given** the schedule is enabled, **When** it fires, **Then** a run executes: simulators → upload → land → `dbt build`, and the run succeeds with per-asset freshness updated.
2. **Given** a delta tick that generated N new + M updated rows for an entity, **When** the chain re-materialises, **Then** that entity's bronze row count increases by exactly N, SCD2 silver adds correctly-versioned rows for the M updates (dimensions), and SCD1 silver overwrites in place (facts) — matching the existing `002` acceptance criteria.
3. **Given** the delta-load job has just run, **When** it is run again immediately with no new simulation, **Then** no layer's row count changes (idempotent rerun).
4. **Given** the schedule, **When** it is left in its default state, **Then** it is **stopped by default** (opt-in) and its cadence is a single configurable value, so it never hammers Fabric capacity unattended.

---

## Layer Placement & Transformations

Unchanged. Dagster does not add, remove, or modify any dbt model, macro, contract, or `meta` block. The medallion boundaries (constitution IV) are untouched: landing overwrite → bronze append-only/dedup → silver same-table only → gold joins → serving. Dagster only *sequences* the existing steps and records their results.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The orchestration project MUST live in a new top-level `orchestration/` package scaffolded with the current Dagster project tooling (`create-dagster` / `dg`, dagster-components layout), separate from `dbt/` and `scripts/`.
- **FR-002**: The dbt project MUST be represented as Dagster assets via `dagster-dbt`, one asset per dbt model, derived from the dbt manifest (not hand-listed), covering bronze, silver, gold, and serving models.
- **FR-003**: dbt data tests MUST surface in Dagster as asset checks attached to the corresponding model assets.
- **FR-004**: Dagster MUST invoke dbt through the existing `dbt/profiles.yml` (target `dev`) and the existing Azure CLI authentication — no duplicate profile, no new credential type, no secrets added (constitution VI).
- **FR-005**: Configuration that varies by environment (Fabric workspace ID, lakehouse ID, lakehouse name, OneLake DFS endpoint) MUST be read from the repo-root `.env` / environment, never hardcoded in `orchestration/` (constitution VI, AGENT.md §8).
- **FR-006**: Each `landing_<entity>` table MUST be a Dagster asset whose materialisation uploads `data/contoso/<entity>.csv` to OneLake Files and then runs `bootstrap_landing_table` for that entity, reusing `scripts/upload_to_onelake.py` and the existing macro.
- **FR-007**: The dbt bronze source assets MUST be wired downstream of the matching `landing_<entity>` assets so the end-to-end graph (upload/land → bronze → silver → gold → serving) is connected with correct lineage.
- **FR-008**: Materialising the full graph MUST run the steps in dependency order in a single Dagster run and MUST NOT issue `--full-refresh` against any bronze model (constitution I; append-only bronze).
- **FR-009**: Landing assets MUST record the landed row count (and the entity name) as Dagster asset metadata for each materialisation.
- **FR-010**: A Dagster job MUST exist that runs the delta-load simulators for all entities that have a `scripts/simulate_delta_load/*` script, then re-materialises the upload → land → build chain.
- **FR-011**: A Dagster schedule MUST target that job on a single configurable cadence, and MUST be **stopped by default** (opt-in), so it does not run against Fabric unattended without an explicit choice.
- **FR-012**: All new tooling (`dagster`, `dagster-dbt`, `dagster-webserver`, the `dg`/`create-dagster` tooling) MUST be added to `requirements.txt` (pinned) and `requirements.lock.txt` (full freeze), installed only into the project `.venv` (never global — AGENT.md §2).
- **FR-013**: A `poe` task MUST launch the Dagster dev UI (e.g. `poe dagster dev`) with the repo-root `.env` loaded, consistent with the existing `poe dbt` pattern (`pyproject.toml`).
- **FR-014**: The Dagster code location MUST load cleanly (`dagster dev` with zero load errors, `dagster definitions validate` green) with the dbt manifest built/prepared as needed on startup.
- **FR-015**: Running the pipeline via Dagster MUST produce the same data result as the equivalent manual `upload → run-operation → dbt build` sequence (no behavioural drift).
- **FR-016**: AGENT.md (§10 roadmap item 7, and a §12 decision entry) and the repo `README`/docs MUST be updated to describe the Dagster layer and how to run it.

### Data Quality & Non-Functional Requirements

- **NFR-001**: Idempotency (constitution I) MUST hold through the orchestrated path — materialising the full graph twice on unchanged source produces identical row counts in every layer.
- **NFR-002**: The orchestration layer MUST NOT weaken additive schema evolution (constitution III) — it adds no schema handling of its own; dbt's `on_schema_change: append_new_columns` still governs.
- **NFR-003**: No secrets in `orchestration/` code or Dagster run logs; `.env` stays gitignored; a scan of the new code/config for workspace/lakehouse/tenant IDs and keys comes back clean (constitution VI).
- **NFR-004**: Stage-1 footprint only — local `dagster dev`; no Dagster+, no containerised/remote deployment, no new always-on services. The schedule is opt-in (FR-011).
- **NFR-005**: The delta-load schedule's cadence MUST be conservative enough by default to stay within Fabric capacity limits (the pipeline has repeatedly hit `TooManyRequestsForCapacity` — AGENT.md §12 decision 8).
- **NFR-006**: Adding/reordering dbt models later MUST NOT require editing `orchestration/` — the asset graph is manifest-derived (FR-002).

### Edge Cases

- **Stale dbt manifest**: models changed since the manifest was built. → The code location prepares/rebuilds the manifest on startup (dev) so the asset graph reflects current SQL; a documented command regenerates it in CI-like contexts.
- **`az login` expired / missing**: dbt or the OneLake upload cannot authenticate. → The affected asset run fails loudly with the auth error in the Dagster logs; no partial/silent success.
- **Partial failure mid-chain** (e.g. `landing_orders` ok, `landing_store` fails). → Dagster marks the failed asset and its downstream as not materialised; already-landed entities keep their new materialisation; a retry re-runs only what's stale/failed.
- **Fabric capacity 430 during a scheduled run**. → The run fails; the schedule does not pile up concurrent runs (single-flight); next tick retries. Documented alongside the existing 430 recovery note.
- **`orders` partitioning rebuild** (the one-time `DROP TABLE` + rebuild from `002`/decision 12) is explicitly **out of scope** for Dagster — it stays a manual operation; the landing/bronze assets never trigger it.
- **Simulator changes a business key or writes a malformed row**. → Bronze dedup / contract tests (asset checks) fail the run, surfacing it — Dagster does not mask it.
- **Concurrency**: two full-graph runs launched at once. → Dagster run-concurrency limits (and the dbt resource) serialise dbt invocations so two `dbt build`s don't collide on the same Livy session.

## Success Criteria *(mandatory)*

- **SC-001**: From a single action in the Dagster UI (or one `dagster job` CLI call), the entire pipeline runs **upload → land → bronze → silver → gold → serving** for all seven entities and completes successfully, with lineage and per-asset run status visible.
- **SC-002**: The Dagster asset graph contains exactly one asset per dbt model (33 at time of writing) plus one asset per landing entity (7), with lineage identical to the dbt manifest's DAG; no models are missing or duplicated.
- **SC-003**: Every dbt test runs as a Dagster asset check, and a full materialisation reports the same pass/fail set as `dbt build` (currently 46 dbt tests passing — 79 total `dbt build` node results across 33 models + 46 tests).
- **SC-004**: Materialising the full graph twice against unchanged source yields identical row counts in every layer (idempotent) — verifiable from Dagster asset metadata.
- **SC-005**: A scheduled (or manually triggered) delta-load run with N new + M updated rows per entity results in exactly N new bronze rows per entity, correctly-versioned SCD2 silver rows for dimensions, in-place SCD1 overwrites for facts, and an immediate rerun changes nothing.
- **SC-006**: `dagster dev` starts with zero code-location load errors and `dagster definitions validate` passes; `poe dagster dev` works without manually sourcing `.env`.
- **SC-007**: A grep of `orchestration/` and Dagster run logs for tenant/workspace/lakehouse IDs, client secrets, and connection strings returns nothing (constitution VI); `requirements.lock.txt` reflects the new deps and `.venv` is the only install target.
- **SC-008**: Adding a new dbt model and rebuilding the manifest makes a corresponding Dagster asset appear with no edit to `orchestration/` code.

## Assumptions

- **Reuses the existing dbt project and Fabric setup unchanged** — `dbt/profiles.yml` (target `dev`), Azure CLI auth (`az login`), schema-enabled `lh_contoso`, the `landing`/`bronze`/`silver`/`gold`/`serving` schemas. Dagster adds no new Fabric objects.
- **`dagster-dbt` parses the dbt manifest**; the manifest is (re)built on `dagster dev` startup in development. dbt itself is invoked via a `DbtCliResource`-style wrapper pointing at `dbt/`.
- **Landing/upload assets are "external"** — they write directly to Fabric/OneLake; Dagster is not an IO manager for the data, it tracks materialisation events + metadata only. Same for the dbt assets (dbt owns the tables).
- **Delta-load schedule**: defined but **stopped by default**; a single configurable cadence (a conservative default such as every 6 hours); when it runs it simulates a small delta (low `--new`/`--updated`) for every entity that has a simulator script. Cadence and per-entity counts are config, not code.
- **The delta-load simulators keep rewriting the gitignored `data/contoso/*.csv`** in place (as they do today); Dagster runs them as a subprocess or via their `main()`.
- **Scope is orchestration only** — no changes to model SQL, contracts, `meta`, macros, or medallion boundaries; no Meltano work (still blocked); no CI wiring of Dagster (minimal CI is roadmap item 6, separate); the `orders` partition rebuild stays a manual op.
- **Local, single-workspace Stage 1** — one Fabric workspace treated as prod (AGENT.md §8); no Dagster+, no remote/containerised deployment, no always-on daemon beyond a developer's `dagster dev`.
- **`orchestration/` layout** follows current Dagster project conventions (`dg`/dagster-components) rather than the older `@repository` style, per AGENT.md §9 "strictly best practices".
- **Python/tooling**: new deps install into the existing project `.venv` via `pip` + `requirements.txt` (matching the repo's current workflow); exact versions are pinned during planning/implementation.
