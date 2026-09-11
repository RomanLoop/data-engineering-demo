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

- [x] T001 Determine the latest mutually-compatible `dagster` / `dagster-dbt` / `dagster-webserver` versions (research.md Decision 9). **Found a hard blocker**: every published `dagster-dbt` caps `dbt-core<1.12`; this project ran `dbt-core==1.12.3`. Resolved per research.md Decision 10 (user chose to downgrade `dbt-core` to `1.11.15`). Final pins: `dagster==1.13.21`, `dagster-webserver==1.13.21`, `dagster-dbt==0.29.21`, `dagster-dg-cli==1.13.21`, `create-dagster==1.13.21`.
- [x] T002 Added the pinned versions to `requirements.txt` and installed into `.venv` via `pip install -r requirements.txt`.
- [x] T003 Regenerated `requirements.lock.txt`.
- [x] T004 Scaffolded `orchestration/` with `create-dagster project orchestration` (`PYTHONUTF8=1` needed to work around a Rich/legacy-Windows-console crash; declined the `uv sync` prompt). Layout confirmed: `orchestration/pyproject.toml` (`[tool.dg]`), `src/orchestration/{__init__.py, definitions.py, defs/__init__.py}`, `tests/__init__.py`.
- [x] T005 [P] Added `[tool.poe.tasks.dagster]` to the root `pyproject.toml` (`cmd = "dagster"`, `cwd = "orchestration"`) — `.env` already loads repo-wide via the existing `envfile = ".env"`.
- [x] T006 [P] Added `orchestration/.dg/` to the root `.gitignore`'s existing `# --- Dagster ---` section (which already had `.dagster_home/`/`storage/` from earlier setup); `orchestration/.gitignore` (scaffold-generated) already covers `__pycache__/`/`.env`/`.venv` inside `orchestration/`.

**Checkpoint**: ✅ `orchestration/` scaffolded; nothing installed outside `.venv`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: shared resources and dbt-source wiring every capability depends on.

**⚠️ CRITICAL**: No capability work can begin until this phase is complete.

- [x] T007 Defined the shared dbt resource in **`orchestration/src/orchestration/resources.py`** (deviation from the planned `defs/resources.py` path — `load_from_defs_folder` expects everything under `defs/` to be a Component or a definitions-producing module, not a plain helper, so it lives as a sibling of `definitions.py` instead; noted in the file's docstring). `DbtProject(project_dir=<repo>/dbt, profiles_dir=<repo>/dbt, target="dev")` + `DbtCliResource(project_dir=dbt_project)`. Verified live: `prepare_if_dev()` runs `dbt deps` + `dbt parse` and produces `dbt/target/manifest.json` with no live Fabric connection.
- [x] T008 Added a `load_dotenv(REPO_ROOT / ".env", override=False)` call at the top of `resources.py`, before `prepare_if_dev()` — `python-dotenv==1.2.3` pinned explicitly in `requirements.txt` (was already a transitive dep, now direct since it's imported directly).
- [x] T009 Added `meta.dagster.asset_key: ["landing_<entity>"]` to all 7 tables in `dbt/models/bronze/contoso/_contoso__sources.yml`. **Naming correction**: the customers source table is `landing_customer` (singular — the original `001` naming), not `landing_customers`; used the real name, and the matching Dagster asset in Capability 2 will be `landing_customer` too.
- [x] T010 `dbt parse --no-partial-parse` — clean under `dbt-core==1.11.15` with the new source metadata.

**Checkpoint**: shared resource config exists; all 7 landing sources carry the asset-key metadata; dbt still parses cleanly outside Dagster.

---

## Phase 3: Capability 1 - dbt project as a Dagster asset graph (Priority: P1) 🎯 MVP

**Goal**: the existing dbt project, fully represented as Dagster assets with lineage and dbt tests as asset checks — usable standalone even before landing/scheduling exist.

**Independent test**: `dagster dev` shows one asset per dbt model with correct lineage and loads with zero code-location errors, including when Fabric is unreachable (quickstart Scenario 1); materializing the graph matches `poe dbt build` (quickstart Scenario 2).

- [x] T011 [C1] Scaffolded the dbt component (`dg scaffold defs dagster_dbt.DbtProjectComponent dbt_ingest --project-path ../dbt`) and configured `defs.yaml` (`project.project_dir`/`profiles_dir`/`target`, `translation_settings.enable_asset_checks`). **Later removed** — see T015.
- [x] T012 [C1] Configured (then superseded by T015's fallback — see below).
- [x] T013 [C1] Verified via `dg check defs` / `dg list defs` (equivalent to `dagster dev` loading): zero code-location load errors, **exactly 33 dbt-model assets** (7 bronze + 12 silver + 7 gold + 7 serving — matches data-model.md), dbt tests present as asset checks. Confirmed stable across 3 consecutive reloads. Done entirely **without** `az login`/a live Fabric session — only `dbt parse` runs at load time (research.md Decision 4), proving the code location is inspectable even during a Fabric outage.
- [ ] T014 [C1] **Blocked** — materializing needs a live Fabric session (`dbt build` actually executing against Spark). The Azure CLI refresh token is expired (conditional-access sign-in-frequency, 24h max lifetime) and needs an interactive `az login` this session cannot perform. Deferred until the user re-authenticates.
- [x] T015 [C1] **Decision checkpoint — fallback taken.** `DbtProjectComponent` hit a real, reproducible (not transient) Windows `PermissionError [WinError 5]` rebuilding its `.local_defs_state` cache on every reload after the first (see research.md Decision 8 "Outcome" for the full sequence, including a separate long-path issue found and fixed along the way). Replaced with classic `@dbt_assets` (`orchestration/src/orchestration/dbt_assets.py`) + a hand-assembled `Definitions` (`orchestration/src/orchestration/definitions.py`) — no component, no `defs/` auto-discovery for the dbt piece. Recorded in research.md Decision 8 and AGENT.md §12.

**Structure note**: the final Capability 1 layout differs from plan.md's original sketch (`defs/dbt_ingest/defs.yaml`) — it's now `orchestration/src/orchestration/{env.py, resources.py, dbt_assets.py, definitions.py}`, no Components/`defs/` folder content. `defs/` is currently empty (kept for potential future Component use, e.g. if `dagster-dbt` fixes the caching issue or the environment moves out of a synced folder).

**Checkpoint**: Capability 1 is independently useful — the whole dbt project is observable, runnable, and testable from Dagster.

---

## Phase 4: Capability 2 - Landing + OneLake-upload assets, full chain (Priority: P2)

**Goal**: turn the graph into the complete `upload → land → bronze → … → serving` chain by adding one asset per landing entity.

**Independent test**: materializing one `landing_<entity>` asset lands that entity correctly (quickstart Scenario 3, single-asset part); materializing the whole graph from a clean landing state reproduces known-good serving row counts and stays idempotent on rerun (quickstart Scenarios 3–4).

- [ ] T016 [P] [C2] Create **`orchestration/src/orchestration/landing_assets.py`** (path corrected from the original `defs/landing/landing_assets.py` — no `defs/` auto-discovery in this project, see T015/plan.md) with a shared helper (upload via the logic in `scripts/upload_to_onelake.py` + `dbt run-operation bootstrap_landing_table` via the T007 `dbt_resource`) parameterized by entity.
- [ ] T017 [P] [C2] Define the `landing_customer` asset (asset key `landing_customer`, **singular** — matches the real dbt source table name, T009's naming correction) using the T016 helper with `customer`'s known columns; emit `entity`, `csv_path`, `landed_row_count` metadata (FR-009).
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

- [ ] T029 [C3] Create **`orchestration/src/orchestration/schedules.py`** (path corrected — see T016) with `delta_load_job`: run each existing `scripts/simulate_delta_load/<entity>.py` that has one (small, configurable `--new`/`--updated` counts), then select and re-materialize the `landing_*` → dbt-asset graph (`define_asset_job` over that selection).
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
