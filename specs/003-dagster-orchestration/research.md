# Phase 0 Research: Dagster orchestration

All decisions below were checked against Dagster's current docs (fetched 2026-09-11 — this area moves fast enough that pre-training knowledge is not trusted on its own) and against this repo's live, already-validated behaviour from `001`/`002` and the `2026-09-10` partitioning work.

## Decision 1 — Scaffold with `create-dagster` / `dg`, but skip `uv`

**Decision**: Scaffold `orchestration/` with `create-dagster project orchestration` (the modern `dg`/Components layout: `src/orchestration/{definitions.py, defs/}`, `pyproject.toml`), but decline the tool's `--uv-sync` prompt and never introduce `uv` into this repo.

**Rationale**: `create-dagster`'s default flow assumes `uv` (it prompts to run `uv sync` and expects a `uv.lock`). This repo made a deliberate, recent, explicit choice (this session) to standardize on a single project-local `.venv` installed via `pip install -r requirements.txt`, with `requirements.lock.txt` as the full-freeze reproduce — adding `uv` as a second package manager for one subdirectory would fragment that and contradicts AGENT.md §2 ("Local dev environment (Python)"). The scaffold's directory/`pyproject.toml` *shape* is what's valuable (current best practice, Components-ready); its dependency-management opinion is not required to get that shape.

**Alternatives considered**: Adopt `uv` repo-wide — rejected, out of scope and unrequested churn on a decision the user already made this session. Hand-roll the directory layout instead of running the scaffold — rejected, no reason to diverge from the tool's own structure when only one flag needs skipping.

## Decision 2 — Two `pyproject.toml` files, not one

**Decision**: `orchestration/pyproject.toml` (created by the scaffold) stays Dagster/`dg`-owned. The existing root `pyproject.toml` keeps its `poe` tasks and gains one more (`poe dagster`) that runs `dagster` with `cwd = "orchestration"`, mirroring the existing `poe dbt` (`cwd = "dbt"`) pattern.

**Rationale**: `dg` expects its own `pyproject.toml` at the project root it manages (with `[tool.dg]` / entry-point metadata) — merging that into the repo's root `pyproject.toml` (which already serves `poe`'s unrelated `[tool.poe]` config) would fight the tool. Two config files, one per concern, matches how `dbt/` (dbt-owned `dbt_project.yml`) already sits next to the root `pyproject.toml` (poe-owned).

## Decision 3 — dbt integration via `dagster_dbt.DbtProjectComponent`, pointed at the existing `dbt/`

**Decision**: Use the Components-based dbt integration (`dg scaffold defs dagster_dbt.DbtProjectComponent --project-path ../dbt`, configured in `orchestration/src/orchestration/defs/dbt_ingest/defs.yaml` with `project: '{{ context.project_root }}/../dbt'`) rather than hand-writing `@dbt_assets`. The existing `dbt/` project is referenced in place — not moved, not duplicated.

**Rationale**: `DbtProjectComponent` is Dagster's current recommended path for representing a dbt project as assets (manifest-driven, one asset per model, dependencies inferred automatically) — hand-written `@dbt_assets` is the older/lower-level API the docs now point away from for new projects. Pointing at `dbt/` in place avoids a repo reorg and keeps `poe dbt ...` working unchanged for direct CLI use.

**Alternatives considered**: Classic `@dbt_assets` decorator + manual `Definitions` — kept as the documented fallback (Decision 8) if Components friction blocks progress, since it's strictly more code for the same result today.

## Decision 4 — `profiles_dir` set explicitly; manifest prep needs no live Fabric session

**Decision**: Configure the dbt resource with `profiles_dir` pointed explicitly at `dbt/` (not relying on cwd). Manifest preparation uses `DbtProject.prepare_if_dev()`, which runs `dbt deps` + `dbt parse` only.

**Rationale**: `poe dbt` currently sets `DBT_PROFILES_DIR=.` with `cwd=dbt/` — Dagster's process won't automatically share that cwd, so `profiles_dir` must be passed explicitly to avoid a "could not find profiles.yml" failure. `prepare_if_dev()` running only `dbt parse` (not `compile`/`run`) matters concretely for this project: `dbt compile`/`run` require a live Fabric Livy session for any model whose body calls `is_incremental()`/`run_query` outside the parse-time stub context (this repo hit multi-minute hangs when Fabric capacity was exhausted, 2026-09-10), while `dbt parse --no-partial-parse` completed in ~3 seconds with **no** Fabric session at all (verified live, same day). So the Dagster code location can load (`dagster dev` starts, the asset graph renders) even when Fabric is unreachable — only *materializing* an asset needs a live session, matching today's manual workflow.

## Decision 5 — Landing assets are plain Python `@dg.asset`s, wired to dbt sources via `meta.dagster.asset_key`

**Decision**: Each `landing_<entity>` is a plain Python asset (not a Component) that (a) calls `scripts/upload_to_onelake.py`'s upload logic and (b) invokes `dbt run-operation bootstrap_landing_table` via the same `DbtCliResource` the dbt component uses. The dbt source table each bronze model reads from gets a `meta.dagster.asset_key: ["landing_<entity>"]` entry added to its `sources.yml`, which is the mechanism Dagster reads to link a dbt `source()` reference to an external upstream asset.

**Rationale**: the upload + bootstrap steps are imperative Python/SQL-operation calls with no dbt model behind them — they don't fit the dbt-model-per-asset shape the Component provides, so a plain asset is the right level of abstraction (Components are for structured, repeated integrations; one-off Python steps stay as Python, matching constitution II's "avoid one-off imperative scripts for anything that recurs" read the other way — this genuinely doesn't recur *as a dbt model*). `meta.dagster.asset_key` is the documented, additive way to connect them: it's a new key under each source table's existing `meta` block, not a new source or a schema change.

**Alternatives considered**: A synthetic dbt model wrapping the bootstrap macro so it's "just another dbt asset" — rejected, it would materialize the macro's `run_query` side effects (uploading a file, creating a landing table) as if they were a SQL transformation, which is misleading and harder to reason about than a Python asset doing exactly what it says.

## Decision 6 — Delta-load job/schedule as plain Python defs, not a Component

**Decision**: The delta-load job (simulate → upload → land → build) and its schedule are defined as ordinary Dagster Python (`ScheduleDefinition`/`@dg.schedule` + `define_asset_job` in `orchestration/src/orchestration/defs/schedules.py`), not a Component.

**Rationale**: as of this research, Dagster's Components catalog doesn't expose a first-class "schedule" component — schedules remain a core Python API (`ScheduleDefinition`, `@dg.schedule`, `build_schedule_from_partitioned_job`) that composes with Component-defined assets via `define_asset_job`'s asset selection. This is still the current, documented mechanism inside a `dg`-scaffolded project; it composes fine with Component-defined assets since jobs select by asset key, not by how the asset was defined.

## Decision 7 — Schedule is defined `STOPPED` by default, single configurable cadence

**Decision**: `ScheduleDefinition(..., cron_schedule=<config value, default "0 */6 * * *">, default_status=DefaultScheduleStatus.STOPPED)`.

**Rationale**: directly satisfies spec FR-011/NFR-005 and the repeated, real `TooManyRequestsForCapacity` (HTTP 430) incidents this project has already hit from ordinary interactive use (AGENT.md §12 decision 8). An unattended schedule hitting the same shared Fabric capacity is a real risk; starting stopped makes enabling it a deliberate, visible choice, and a 6-hour default cadence keeps even the enabled state light.

## Decision 8 — Fallback if Components friction blocks progress

**Decision**: If implementation hits an undocumented gap in `DbtProjectComponent` wiring (e.g., the `meta.dagster.asset_key` translation not resolving as documented, or `dg`'s entry-point/workspace wiring not loading cleanly), fall back to a single classic `dagster.Definitions` object using `@dbt_assets` directly against the loaded manifest, plus the same plain-Python landing/schedule assets. Document the fallback decision here (and in AGENT.md §12) if taken, with the specific error that forced it.

**Rationale**: this project's own history (SCD2 post_hook redesign, `SELECT * REPLACE` rejection, the `incremental_predicates` runtime-config dead end) shows that Fabric/dbt-adapter specifics regularly diverge from generic docs; the same caution applies to a tool (`dg`/Components) that is itself still evolving. A same-outcome, lower-abstraction fallback avoids a stalled feature.

## Decision 9 — Version pinning deferred to implementation time

**Decision**: `research.md`/`plan.md` do not hardcode `dagster`/`dagster-dbt`/`dagster-webserver` version numbers. `tasks.md` includes a task to check the latest mutually-compatible versions at implementation time and pin them in `requirements.txt` + freeze into `requirements.lock.txt`, per the existing convention.

**Rationale**: a version pin decided during research would likely be stale by implementation time in a fast-moving library; the repo's existing convention (exact pins + a full lockfile) already handles reproducibility once the real versions are known. (This deferral is exactly what surfaced Decision 10 below — checking at implementation time rather than assuming compatibility.)

## Decision 10 — Downgrade `dbt-core` to `1.11.15` (blocker found during implementation, 2026-09-11)

**Decision**: Pin `dbt-core==1.11.15` (down from `1.12.3`), keep `dbt-fabricspark==1.13.4` unchanged, pin `dagster-dbt==0.29.21`.

**What happened**: T001 checked PyPI directly rather than assuming compatibility. Every published `dagster-dbt` release — checked back through the `0.27.x` series to the latest `0.29.21` (released alongside `dagster==1.13.21`) — pins `dbt-core<1.12`. None support `dbt-core>=1.12`. This is not a `dbt-fabricspark` constraint (it only needs `dbt-core>=1.8.0`) or a Components-vs-classic-`@dbt_assets` API choice (both live in the same `dagster-dbt` package with the same ceiling) — it's a hard upstream gap. Surfaced to the user as a blocking decision (three options: downgrade dbt-core, drop `dagster-dbt` for coarser hand-rolled assets, or defer Capability 1 entirely); the user chose to downgrade.

**Rationale for `1.11.15` specifically**: the latest 1.11.x release, satisfying `dagster-dbt`'s `<1.12` ceiling, `dbt-fabricspark`'s `>=1.8.0` floor, and `sqlfluff-templater-dbt`'s `>=1.4.1` floor.

**Risk accepted**: this project's dbt project was built and had several real bugs found and fixed against `dbt-core==1.12.3`'s exact behavior this session (the `RuntimeConfigObject.__call__` runtime-`config()` no-op discovery, the SCD2 post-hook `MERGE` redesign, partition-column contract ordering). Downgrading could reintroduce different adapter-version quirks. Mitigated by a full re-validation pass immediately after the downgrade — `dbt parse`, `dbt compile`, a full `dbt build` (all 33 models + 46 tests, expected to be a no-op idempotent rerun since no source data changed), and a spot-check of the two riskiest areas (the SCD2 `expire_scd2_current_rows` post-hook `MERGE`, and the SCD1 `orders` static `incremental_predicates` MERGE) — before trusting the new pin. Results recorded in this decision once complete.

**Alternatives considered**: dropping `dagster-dbt` for hand-rolled coarse-grained assets (rejected by the user — would weaken FR-002/SC-002's per-model lineage, the core value of Capability 1); deferring Capability 1 until `dagster-dbt` supports 1.12 (rejected — no published timeline, and Capabilities 2/3 depending on a permanently-partial Capability 1 was judged worse than a validated downgrade).
