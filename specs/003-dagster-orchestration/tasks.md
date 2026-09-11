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
- [x] T014 [C1] **Verified live** (2026-09-11, after `az login`): `dagster asset materialize --select bronze/bronze_contoso__store` correctly translated the Dagster selection into `dbt build --select data_engineering_demo.bronze.contoso.bronze_contoso__store`, ran against real Fabric (72s incl. a cold Livy start), `RUN_SUCCESS`. A second materialization of `bronze_contoso__orders` immediately after landing (see T025/T026) succeeded in 76s reading freshly-landed data, and a third immediate rerun with no new data completed as a true no-op in 58s — proving both correctness and idempotency through the orchestrated path (SC-003, matches `poe dbt build`'s behavior).
- [x] T015 [C1] **Decision checkpoint — fallback taken.** `DbtProjectComponent` hit a real, reproducible (not transient) Windows `PermissionError [WinError 5]` rebuilding its `.local_defs_state` cache on every reload after the first (see research.md Decision 8 "Outcome" for the full sequence, including a separate long-path issue found and fixed along the way). Replaced with classic `@dbt_assets` (`orchestration/src/orchestration/dbt_assets.py`) + a hand-assembled `Definitions` (`orchestration/src/orchestration/definitions.py`) — no component, no `defs/` auto-discovery for the dbt piece. Recorded in research.md Decision 8 and AGENT.md §12.

**Structure note**: the final Capability 1 layout differs from plan.md's original sketch (`defs/dbt_ingest/defs.yaml`) — it's now `orchestration/src/orchestration/{env.py, resources.py, dbt_assets.py, definitions.py}`, no Components/`defs/` folder content. `defs/` is currently empty (kept for potential future Component use, e.g. if `dagster-dbt` fixes the caching issue or the environment moves out of a synced folder).

**Checkpoint**: Capability 1 is independently useful — the whole dbt project is observable, runnable, and testable from Dagster.

---

## Phase 4: Capability 2 - Landing + OneLake-upload assets, full chain (Priority: P2)

**Goal**: turn the graph into the complete `upload → land → bronze → … → serving` chain by adding one asset per landing entity.

**Independent test**: materializing one `landing_<entity>` asset lands that entity correctly (quickstart Scenario 3, single-asset part); materializing the whole graph from a clean landing state reproduces known-good serving row counts and stays idempotent on rerun (quickstart Scenarios 3–4).

- [x] T016 [P] [C2] Created **`orchestration/src/orchestration/landing_assets.py`** (path corrected — no `defs/` auto-discovery, see T015/plan.md). Shared `_make_landing_asset(config)` factory: uploads via `scripts/upload_to_onelake.py`'s `upload()` (loaded by file path — `scripts/` isn't a package) then runs the matching dbt bootstrap macro via the T007 `dbt_resource`.
- [x] T017 [P] [C2] `landing_customer` asset — **singular**, matches the real dbt source table (T009). Uses the dedicated no-arg `bootstrap_landing_customer` macro (the one asymmetric entity — predates the generalized macro), not `bootstrap_landing_table`. Emits `entity`/`csv_path` always, `landed_row_count` best-effort (a `dbt show --output json` probe, untested live — Fabric unreachable; wrapped so a parse miss omits the field rather than failing the asset).
- [x] T018 [P] [C2] `landing_product` asset — columns mirror `002`'s quickstart.md `bootstrap_landing_table` args.
- [x] T019 [P] [C2] `landing_store` asset — same pattern.
- [x] T020 [P] [C2] `landing_orders` asset — same pattern.
- [x] T021 [P] [C2] `landing_orderrows` asset — same pattern.
- [x] T022 [P] [C2] `landing_date` asset — same pattern.
- [x] T023 [P] [C2] `landing_currencyexchange` asset — same pattern.
- [x] T024 [C2] Verified via the definitions object directly (`asset_graph.get(key).parent_keys`) — equivalent to inspecting `dagster dev`'s lineage graph. **Confirmed**: every `bronze_contoso__<entity>` asset resolves exactly one upstream — its matching `landing_<entity>` — including `bronze_contoso__customers ← landing_customer` (the plural/singular naming asymmetry resolves correctly). No dangling or duplicated keys. Zero live Fabric connection needed for this check.
- [x] T025 [C2] **Verified live**: materializing `landing_orders` alone uploaded `orders.csv` (47.6 MB) to OneLake and ran `bootstrap_landing_table`, `landing_orders row count: 980981` — `RUN_SUCCESS`. Found and fixed two real bugs along the way (not environment/capacity issues — genuine code defects): (1) `contoso_currencyexchange.py`'s simulator CLI is `--new-date`, not `--new` — argparse's prefix-matching silently resolved a passed `--new 5` into `--new-date 5`, crashing on `date.fromisoformat("5")`; `schedules.py`'s `delta_simulation` now special-cases it. (2) `dbt_resource.cli([...], context=context)` is only valid *inside* a `@dbt_assets`-generated asset (it looks up manifest metadata for the currently-executing asset) — `landing_assets.py`'s plain `@asset`s were passing `context` and crashing with `DagsterInvariantViolationError`; removed (`run-operation` has no notion of asset selection anyway, so unscoped is correct here).
- [x] T026 [C2] **Verified live** for the `orders` vertical slice: `dagster asset materialize --select "landing_orders+"` ran `landing_orders` → `bronze_contoso__orders` in one Dagster run, `RUN_SUCCESS` (the freshly-landed 980,981 rows correctly dedup'd against existing bronze). Note: Dagster's bare `+` selects one level downstream, not the full transitive closure, so silver/gold/serving weren't included in this specific invocation — those layers were separately and extensively live-validated (outside Dagster) earlier this session and in `001`/`002`; the untested part here is specifically "does Dagster's own scheduling trigger them," which the full-graph attempts below speak to. **Also proved a real, reproducible Fabric capacity constraint**: two attempts at materializing the *entire* 41-asset graph in one run (`delta_load_job`, 8 sequential `dbt` CLI subprocess invocations) both hit `TooManyRequestsForCapacity` (HTTP 430) from session churn — `reuse_session: true` doesn't reliably hold across that many rapid sequential invocations, matching AGENT.md §12 decision 8's caveat exactly. Recovered via the documented Livy-session-cancel pattern each time. Practical implication for real use: prefer scoped/incremental materializations (by entity or layer) over one giant all-at-once run on this capacity tier — noted in AGENT.md §12 decision 13.
- [x] T027 [C2] Verified statically: `grep -rn "full.refresh" orchestration/src/` — clean, `--full-refresh` never appears anywhere in the orchestration code (FR-008).
- [x] T028 [C2] **Verified live**: immediately re-materializing `bronze_contoso__orders` with no new landing data since the prior materialization completed successfully as a true no-op (58s, `RUN_SUCCESS`, no duplicate/changed rows) — idempotency holds through the orchestrated path (NFR-001).

**Checkpoint**: the full upload→land→bronze→…→serving chain runs as one Dagster graph, and reruns stay idempotent.

---

## Phase 5: Capability 3 - Scheduled delta-load exercise (Priority: P3)

**Goal**: a standing, opt-in regression signal that exercises incremental processing and idempotency without manual commands.

**Independent test**: manually triggering the job reproduces the existing delta-load acceptance criteria from `002` (quickstart Scenario 5); the schedule is stopped by default and, once enabled, one tick reproduces the same result (quickstart Scenario 6).

- [x] T029 [C3] Created **`orchestration/src/orchestration/schedules.py`**. Implemented as a `delta_simulation` asset (runs all 7 `scripts/simulate_delta_load/*.py` with small `--new`/`--updated` counts) that every `landing_<entity>` asset declares as an extra dependency — so `delta_load_job = define_asset_job("delta_load_job", selection=AssetSelection.all())` naturally runs simulate → land → bronze → … → serving in dependency order, in one job, with no bolted-on op ahead of the asset graph. Verified: all 7 `landing_*` assets show `delta_simulation` as a parent; total asset count 41 (33 dbt + 7 landing + 1 delta_simulation).
- [x] T030 [C3] Added `delta_load_schedule` (`name="delta_load_schedule"` set explicitly — Dagster would otherwise auto-name it `delta_load_job_schedule`), `cron_schedule="0 */6 * * *"`, `default_status=DefaultScheduleStatus.STOPPED`. Verified via direct inspection: listed as `STOPPED`.
- [~] T031 [C3] **Partially verified live, full job not yet achieved end-to-end.** `delta_simulation` itself succeeded fully (all 7 simulators, incl. the currencyexchange fix) inside a `delta_load_job` run; `landing_customer`/`landing_product`/`landing_store` then also materialized successfully in sequence within that same run. The run consistently failed a few entities later (`landing_currencyexchange` once, `landing_date` twice) with `TooManyRequestsForCapacity` (HTTP 430) — 8 sequential `dbt` CLI subprocess invocations in one job is enough that `reuse_session: true` doesn't reliably hold (AGENT.md §12 decision 8's known caveat, now reproduced concretely under Capability 3's load). Recovered via the documented Livy-session-cancel pattern each time (3 more stray `InProgress` sessions cleaned up afterward). Given the demonstrated capacity fragility and that every individual mechanism in the chain is separately proven live (T014, T025, T026, T028), further repeated full-job attempts were judged not worth the added Fabric capacity risk today — noted as a real, practical limitation rather than pushed through.
- [ ] T032 [C3] Not run — depends on T031 completing a full run first.
- [x] T033 [C3] Schedule status/naming verified structurally (T030): listed as `STOPPED`, named `delta_load_schedule`. The "one tick reproduces T031" live check not run, same reason as T032.

**Checkpoint**: continuous delta-load regression signal exists and is opt-in, not automatically hammering Fabric.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: documentation, secrets hygiene, and a final regression pass across the whole feature.

- [x] T034 [P] Added `AGENT.md` §12 decision 13 summarizing the integration so far (dbt-core downgrade, Components→classic fallback, 33+7+1=41 assets, blockers). **Not** marking §10 roadmap item 7 done yet — Capabilities 2/3 are unverified live (T025-T028, T031-T033 all blocked on `az login`); will update once those pass.
- [x] T035 [P] Updated the root `README.md` (was a one-line stub) with setup steps + a "Running the pipeline via Dagster" section (`poe dagster dev`, what the graph contains, the schedule and how to enable it).
- [x] T036 Ran the secrets scan across `orchestration/` (grep for workspace/lakehouse/tenant/secret literals) — clean, only a gitignored `.pyc` cache file matched (NFR-003, constitution VI).
- [x] T037 Confirmed `requirements.txt`/`requirements.lock.txt` reflect the final dependency set (incl. the `pip install -e ./orchestration --no-deps` one-time step, documented in `requirements.txt`) and that only `.venv` has them: `dagster` is not importable from the Store/global Python (`ModuleNotFoundError`), confirming no global install (AGENT.md §2).
- [~] T038 Not run as a fresh full `poe dbt build` (33 models + 46 tests would be another significant Fabric capacity draw, and today's capacity was already under real strain — see T031). Indirect evidence stands in for it: `orchestration/` never edits any file under `dbt/`, and every Dagster-triggered invocation today (`dbt build --select ...`, `dbt run-operation bootstrap_landing_table/_customer`) used the literal same `dbt/profiles.yml`/`target: dev`/project files `poe dbt` uses, succeeding identically — `dbt build --select bronze_contoso__store` and `...__orders` both passed clean. Worth a full run for final sign-off once capacity is calmer, but not re-run here.

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
