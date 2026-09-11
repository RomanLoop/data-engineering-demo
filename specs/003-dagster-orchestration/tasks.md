# Tasks: Dagster orchestration of the Contoso Stage-1 pipeline

**Input**: Design documents from `specs/003-dagster-orchestration/` (plan.md, research.md, data-model.md, quickstart.md)

**Prerequisites**: plan.md (required), spec.md (required for capability priorities), research.md, data-model.md

**Tests**: no dbt model/contract changes in this feature, so no new dbt tests are required — the
existing 79 dbt tests are reused as-is and must keep passing (surfaced as Dagster asset checks).
Each capability's validation step below is the equivalent gate for orchestration work.

**Organization**: this feature is orchestration infrastructure, not data-entity onboarding, so
tasks are grouped by **Dagster capability** (matching spec.md's P1/P2/P3) instead of by medallion
layer. `[C1]`/`[C2]`/`[C3]` labels map to spec.md's Capability 1/2/3.

## Format: `[ID] [P?] [C?] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[C1/C2/C3]**: Which capability this task belongs to — omitted for shared/foundational/polish tasks
- Exact file paths use the project structure from plan.md (`orchestration/src/orchestration/defs/...`)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: get a `dg`-scaffolded Dagster project into the repo, dependencies installed, runnable via `poe` — before any asset is written.

- [ ] T001 Determine the latest mutually-compatible `dagster` / `dagster-dbt` / `dagster-webserver` versions that support the installed `dbt-core==1.12.3` (research.md Decision 9); record the chosen versions in this file's Notes.
- [ ] T002 Add the pinned versions to `requirements.txt` (new `# --- orchestration (Dagster) ---` section, matching the file's existing style) and install into the project `.venv` via `pip install -r requirements.txt` — no global install (AGENT.md §2).
- [ ] T003 Regenerate `requirements.lock.txt` (`pip freeze`) to capture the new dependency tree.
- [ ] T004 Scaffold `orchestration/` with `create-dagster project orchestration`, declining/skipping the `--uv-sync` step — this repo uses pip + one `.venv`, not `uv` (research.md Decision 1). Confirm the generated layout: `orchestration/pyproject.toml`, `orchestration/src/orchestration/{definitions.py, defs/}`.
- [ ] T005 [P] Add a `dagster` task to the **root** `pyproject.toml` `[tool.poe.tasks]` (`cmd = "dagster"`, `cwd = "orchestration"`, `env` loaded from the repo-root `.env` via the existing `envfile = ".env"` setting) — mirrors the existing `poe dbt` task (research.md Decision 2: two separate `pyproject.toml` files, not merged).
- [ ] T006 [P] Add Dagster's local artifacts to `.gitignore` (e.g. `orchestration/.dg/`, `**/__pycache__/`, any `$DAGSTER_HOME`-style local storage the scaffold creates) so `dagster dev` state never gets committed.

**Checkpoint**: `poe dagster --version` (or equivalent) runs from repo root; `orchestration/` exists with the scaffolded layout; nothing installed outside `.venv`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: shared resources and dbt-source wiring every capability depends on.

**⚠️ CRITICAL**: No capability work can begin until this phase is complete.

- [ ] T007 Define the shared dbt resource in `orchestration/src/orchestration/defs/resources.py` (or component config) with `project_dir`/`profiles_dir` pointed explicitly at the existing `dbt/` (relative path from `orchestration/`, e.g. `{{ context.project_root }}/../dbt`), `target: dev` — do not rely on process cwd (research.md Decision 4).
- [ ] T008 Add a `.env` load at `orchestration/src/orchestration/definitions.py` import time (e.g. `python-dotenv` pointed at the repo-root `.env`) as a safety net for when `dagster dev` is launched outside `poe` — no new secrets file, same `.env` the rest of the repo already uses.
- [ ] T009 Locate every `contoso_landing` source-table declaration (the `sources.yml` file(s) under `dbt/models/bronze/contoso/`) and add `meta.dagster.asset_key: ["landing_<entity>"]` for all 7 entities (`customers`, `product`, `store`, `orders`, `orderrows`, `date`, `currencyexchange`) — additive metadata only, no source/schema change (data-model.md Capability 2, research.md Decision 5).
- [ ] T010 `dbt parse --no-partial-parse` (from `dbt/`, as today) to confirm the `sources.yml` edits are valid YAML/Jinja and don't break dbt parsing — this must stay warehouse-independent (research.md Decision 4).

**Checkpoint**: shared resource config exists; all 7 landing sources carry the asset-key metadata; dbt still parses cleanly outside Dagster.

---

## Phase 3: Capability 1 - dbt project as a Dagster asset graph (Priority: P1) 🎯 MVP

**Goal**: the existing dbt project, fully represented as Dagster assets with lineage and dbt tests as asset checks — usable standalone even before landing/scheduling exist.

**Independent test**: `dagster dev` shows one asset per dbt model with correct lineage and loads with zero code-location errors, including when Fabric is unreachable (quickstart Scenario 1); materializing the graph matches `poe dbt build` (quickstart Scenario 2).

- [ ] T011 [C1] Scaffold the dbt component: `dg scaffold defs dagster_dbt.DbtProjectComponent --project-path ../../dbt` from `orchestration/`, creating `orchestration/src/orchestration/defs/dbt_ingest/defs.yaml`.
- [ ] T012 [C1] Configure `defs.yaml`: `project` path to `dbt/`, `profiles_dir`/`target` from T007's resource, per-layer `translation.group_name` (`bronze`/`silver`/`gold`/`serving`) so the UI groups match the medallion layers, and `DagsterDbtTranslatorSettings(enable_asset_checks=True)` so dbt tests surface as asset checks (FR-003) — add a small `template_vars.py` if the YAML config alone can't express the translator settings.
- [ ] T013 [C1] Run `poe dagster dev` and verify: zero code-location load errors, all 33 dbt models present as assets grouped by layer, lineage matches `dbt ls`/the manifest (quickstart Scenario 1) — do this **without** an active Fabric session first, to confirm manifest prep (`dbt parse`) doesn't need one (research.md Decision 4).
- [ ] T014 [C1] With `az login` active, materialize the full dbt-asset selection from the UI (landing tables already populated from prior manual `poe dbt`/`run-operation` use); confirm it matches `poe dbt build` — same models run, all dbt tests pass as asset checks (quickstart Scenario 2, SC-003).
- [ ] T015 [C1] **Decision checkpoint**: if T011–T014 hit an undocumented `DbtProjectComponent`/`dg` gap that blocks progress, apply the Decision 8 fallback (classic `dagster.Definitions` + `@dbt_assets` in `orchestration/src/orchestration/definitions.py`) and record the specific error + the fallback choice in `research.md` and AGENT.md §12. Otherwise, mark not-applicable.

**Checkpoint**: Capability 1 is independently useful — the whole dbt project is observable, runnable, and testable from Dagster.

---

## Phase 4: Capability 2 - Landing + OneLake-upload assets, full chain (Priority: P2)

**Goal**: turn the graph into the complete `upload → land → bronze → … → serving` chain by adding one asset per landing entity.

**Independent test**: materializing one `landing_<entity>` asset lands that entity correctly (quickstart Scenario 3, single-asset part); materializing the whole graph from a clean landing state reproduces known-good serving row counts and stays idempotent on rerun (quickstart Scenarios 3–4).

- [ ] T016 [P] [C2] Create `orchestration/src/orchestration/defs/landing/landing_assets.py` with a shared helper (upload via the logic in `scripts/upload_to_onelake.py` + `dbt run-operation bootstrap_landing_table` via the T007 dbt resource) parameterized by entity.
- [ ] T017 [P] [C2] Define the `landing_customers` asset (asset key `landing_customers`) using the T016 helper with `customers`' known columns; emit `entity`, `csv_path`, `landed_row_count` metadata (FR-009).
- [ ] T018 [P] [C2] Define the `landing_product` asset.
- [ ] T019 [P] [C2] Define the `landing_store` asset.
- [ ] T020 [P] [C2] Define the `landing_orders` asset.
- [ ] T021 [P] [C2] Define the `landing_orderrows` asset.
- [ ] T022 [P] [C2] Define the `landing_date` asset.
- [ ] T023 [P] [C2] Define the `landing_currencyexchange` asset.
- [ ] T024 [C2] Restart `dagster dev` and confirm each `bronze_contoso__<entity>` asset now shows the matching `landing_<entity>` asset as its sole upstream dependency (T009's `meta.dagster.asset_key` resolving correctly) — no dangling or duplicated asset keys.
- [ ] T025 [C2] Materialize `landing_orders` alone; confirm the CSV lands in OneLake, `landing.landing_orders` is rebuilt, and the row-count metadata matches the source CSV (quickstart Scenario 3, single-asset part).
- [ ] T026 [C2] Materialize the full graph from the `landing_*` assets down; confirm all seven entities build through serving with the known-good row counts (customers 105,495 / product 2,545 / store 76 / date 4,033 / currencyexchange 100,475 / orders 980,966 / orderrows 2,349,591) — quickstart Scenario 3, full-chain part; SC-001.
- [ ] T027 [C2] Inspect the dbt invocations/logs from T026 and confirm no `--full-refresh` flag was ever issued against `bronze_contoso__orders` / `bronze_contoso__orderrows` (FR-008; these models raise a compiler error if it is).
- [ ] T028 [C2] Immediately re-materialize the full graph with no source changes; confirm every layer's row count is unchanged (idempotent — quickstart Scenario 4, NFR-001).

**Checkpoint**: the full upload→land→bronze→…→serving chain runs as one Dagster graph, and reruns stay idempotent.

---

## Phase 5: Capability 3 - Scheduled delta-load exercise (Priority: P3)

**Goal**: a standing, opt-in regression signal that exercises incremental processing and idempotency without manual commands.

**Independent test**: manually triggering the job reproduces the existing delta-load acceptance criteria from `002` (quickstart Scenario 5); the schedule is stopped by default and, once enabled, one tick reproduces the same result (quickstart Scenario 6).

- [ ] T029 [C3] Create `orchestration/src/orchestration/defs/schedules.py` with `delta_load_job`: run each existing `scripts/simulate_delta_load/<entity>.py` that has one (small, configurable `--new`/`--updated` counts), then select and re-materialize the `landing_*` → dbt-asset graph (`define_asset_job` over that selection).
- [ ] T030 [C3] Add `delta_load_schedule` targeting `delta_load_job`: `cron_schedule` read from config (default `"0 */6 * * *"`), `default_status=DefaultScheduleStatus.STOPPED` (FR-011, NFR-005, research.md Decisions 6–7).
- [ ] T031 [C3] Trigger `delta_load_job` manually; verify per entity: bronze grows by exactly N rows, SCD2 silver (dimensions: customers/product/store) adds correctly-versioned rows for the M updates, SCD1 silver (facts: orders/orderrows) overwrites in place — matching `002`'s acceptance criteria (quickstart Scenario 5, SC-005).
- [ ] T032 [C3] Re-run `delta_load_job` immediately with no new simulation; confirm no row-count changes in any layer (idempotent).
- [ ] T033 [C3] Confirm `delta_load_schedule` lists as `STOPPED` by default (`poe dagster schedule list` or the UI); enable it and confirm one tick (or `dagster schedule test`) reproduces T031's outcome (quickstart Scenario 6).

**Checkpoint**: continuous delta-load regression signal exists and is opt-in, not automatically hammering Fabric.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: documentation, secrets hygiene, and a final regression pass across the whole feature.

- [ ] T034 [P] Update `AGENT.md` §10 (mark roadmap item 7 done) and add a §12 decision entry summarizing the Dagster integration: `dg`/Components + pip (not `uv`), `DbtProjectComponent` pointed at `dbt/` in place, `meta.dagster.asset_key` wiring, schedule stopped-by-default, and the Decision 8 fallback outcome (taken or not).
- [ ] T035 [P] Update the root `README.md` (currently a stub) with a short "how to run the pipeline via Dagster" section (`poe dagster dev`, where the schedule lives, how to enable it).
- [ ] T036 Run the secrets scan from quickstart Scenario 7 across `orchestration/` (grep for workspace/lakehouse/tenant/secret literals) — confirm clean (NFR-003, constitution VI).
- [ ] T037 Confirm `requirements.txt` + `requirements.lock.txt` reflect the final dependency set and that only the project `.venv` has them installed (`pip list` sanity check against a clean shell — AGENT.md §2).
- [ ] T038 Run `poe dbt build` directly (bypassing Dagster) and confirm it still passes unchanged (79/79 total node results — 33 models + 46 tests) — proves the orchestration layer didn't alter dbt project behavior (FR-015).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — can start immediately.
- **Foundational (Phase 2)**: depends on Setup — BLOCKS all capability work.
- **Capabilities (Phase 3+)**: all depend on Foundational completion.
  - Capability 1 (P1) has no dependency on Capabilities 2/3 and is the MVP.
  - Capability 2 (P2) depends on Capability 1 existing (it extends the same graph) and on T009's source-metadata wiring (Foundational).
  - Capability 3 (P3) depends on Capability 2 (it re-materializes the full chain Capability 2 builds).
- **Polish (Phase 6)**: depends on all three capabilities being complete.

### Capability Dependencies

- **Capability 1 (P1)**: buildable and demoable alone once Foundational is done.
- **Capability 2 (P2)**: needs Capability 1's asset graph to attach landing assets upstream of; needs T009 (source `meta.dagster.asset_key`) from Foundational.
- **Capability 3 (P3)**: needs Capability 2's full chain to have something to re-materialize on a schedule.

### Parallel Opportunities

- T005/T006 (Setup) can run in parallel with each other once T004 completes.
- T017–T023 (the seven landing assets) are independent files/functions and can be written in parallel once T016's shared helper exists.
- T034/T035 (Polish docs) can run in parallel with T036–T038.

---

## Implementation Strategy

### MVP First (Capability 1 only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (blocks everything).
3. Complete Phase 3: Capability 1 — dbt project as Dagster assets.
4. **STOP and VALIDATE**: `dagster dev` loads cleanly, materializing matches `dbt build`.
5. Ship/demo if ready — this alone already delivers lineage + run history + per-model observability, with landing/upload still manual.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. Add Capability 1 → validate independently → ship (MVP!).
3. Add Capability 2 → validate independently (full chain, idempotent) → ship.
4. Add Capability 3 → validate independently (scheduled delta loop, opt-in) → ship.
5. Polish.

---

## Notes

- **[P]** tasks touch different files with no dependency between them.
- **[C1/C2/C3]** maps a task to spec.md's Capability 1/2/3 for traceability.
- No dbt model, contract, or macro files change in this feature except the additive
  `meta.dagster.asset_key` source-metadata edit (T009) — everything else in `dbt/` is reused as-is.
- Commit after each phase checkpoint, not after every individual task.
- T001's chosen versions: _fill in during implementation_ (deliberately left open — research.md Decision 9).
