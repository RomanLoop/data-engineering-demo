# Implementation Plan: Dagster orchestration of the Contoso Stage-1 pipeline

**Branch**: `003-dagster-orchestration` | **Date**: 2026-09-11 | **Spec**: [spec.md](./spec.md)

**Input**: Pipeline specification from `specs/003-dagster-orchestration/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Wrap the existing, already-working Contoso Stage-1 pipeline (CSV upload → landing bootstrap → dbt build bronze→serving) in Dagster, per roadmap item 7 (AGENT.md §10). No dbt model, contract, macro, or medallion-boundary changes — this is orchestration only. Technical approach (research.md): scaffold `orchestration/` with the current `create-dagster`/`dg` Components layout (skipping its `uv` default — this repo standardized on pip + a single `.venv` this session); represent the dbt project as assets via `dagster_dbt.DbtProjectComponent` pointed in place at the existing `dbt/`; add one plain-Python asset per `landing_<entity>` (upload + bootstrap), wired to the matching dbt bronze source via the documented `meta.dagster.asset_key` source metadata; add a plain-Python job + a **stopped-by-default** schedule that runs the delta-load simulators and re-materializes the chain, to continuously exercise incremental/idempotency behavior.

## Technical Context

**Source system(s)**: Contoso 1M CSV export (unchanged — `001`/`002`). No new source.

**Meltano extractor/loader**: still blocked (AGENT.md §11) — out of scope for this change. The landing-bootstrap Stage-1 stand-in is what Dagster orchestrates.

**dbt layer(s) touched**: none modified. All 33 existing bronze/silver/gold/serving models are *represented* as Dagster assets (read-only, manifest-derived); the only dbt-adjacent file edits are additive `meta.dagster.asset_key` entries in the existing `sources.yml` for `contoso_landing`.

**Fabric objects**: none new. Same `lh_contoso` lakehouse, same `landing`/`bronze`/`silver`/`gold`/`serving` schemas.

**Orchestration**: this change *is* the Dagster integration — previously "manual/CLI-triggered" per AGENT.md §10, now a Dagster asset graph (`orchestration/`) with a local `dagster dev` and one stopped-by-default schedule.

**Testing**: no new dbt tests. Existing dbt tests surface as Dagster asset checks (`enable_asset_checks=True`). New: a quickstart-driven manual validation pass (`quickstart.md`) proving the orchestrated path matches the manual path bit-for-bit (row counts, idempotency, delta-load behavior) — no new automated test framework introduced in Stage 1 (matches AGENT.md §8's minimalist CI-first posture; CI wiring for Dagster is a separate, later roadmap concern).

**Performance/volume**: unchanged data volumes (SC figures in spec.md). New operational concern: the schedule must not add Fabric-capacity pressure beyond what interactive use already causes — addressed by defaulting it to `STOPPED` and a conservative cadence (research.md Decision 7).

**Constraints**: bronze stays append-only — Dagster must never issue `--full-refresh` against a bronze asset (FR-008); silver must still receive no cross-model joins (untouched, Dagster doesn't touch model SQL); no secrets in `orchestration/` code, config, or logs (constitution VI); single project `.venv`, pip-installed, no new global installs and no new package manager (research.md Decision 1).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design. See `.specify/memory/constitution.md`.*

- **I. Idempotency** — preserved. Dagster invokes the same dbt models/macros with the same configs; no new dedup/merge logic is introduced. Quickstart Scenarios 4 and 5 explicitly re-validate idempotency through the orchestrated path.
- **II. Declarative over imperative** — the asset graph itself is declarative (Component YAML + manifest-derived assets); the two genuinely imperative steps that already existed (CSV upload, delta simulation) stay as explicit Python, not hidden inside a declarative wrapper that would misrepresent them (research.md Decision 5).
- **III. Additive schema evolution** — untouched; Dagster adds no schema-change handling of its own. The only "schema" edit is the additive `meta.dagster.asset_key` on existing dbt sources.
- **IV. Medallion layering with strict boundaries** — untouched. Dagster sequences existing layer boundaries; it does not blur landing/bronze/silver/gold/serving semantics or add cross-layer logic.
- **V. Model contracts mandatory** — untouched; no models added/changed. Dagster surfaces existing contract-backed tests as asset checks (adds visibility, doesn't relax anything).
- **VI. Security & secrets** — no new secret types. Fabric workspace/lakehouse IDs and Azure CLI auth are reused exactly as `scripts/upload_to_onelake.py` and `dbt/profiles.yml` already consume them; `.env` stays gitignored; quickstart Scenario 7 is a repeatable secrets-scan check.

**Result**: PASS, no violations. Complexity Tracking below is empty.

**Post-Phase-1 re-check**: `data-model.md` and `quickstart.md` introduce no new dbt models, schema changes, or secret-handling paths beyond what's stated above — the gate re-check after design is a PASS with no changes to this section.

## Project Structure

### Documentation (this change)

```text
specs/003-dagster-orchestration/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command) — Dagster asset inventory
├── quickstart.md         # Phase 1 output (/speckit-plan command) — orchestration validation guide
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Repository layout (this change)

```text
orchestration/                          # NEW — create-dagster/dg scaffold
├── pyproject.toml                      # dg/Components project metadata (NOT the poe pyproject)
├── src/orchestration/
│   ├── env.py                          # loads repo-root .env at import time (must run first)
│   ├── resources.py                    # DbtProject/DbtCliResource, pointed at ../../dbt in place
│   ├── dbt_assets.py                   # @dbt_assets — one asset per dbt model (see research.md
│   │                                    # Decision 8: classic API, not DbtProjectComponent —
│   │                                    # the Components version hit a reproducible Windows
│   │                                    # PermissionError rebuilding its state cache)
│   ├── landing_assets.py               # one @asset per landing_<entity> (Capability 2)
│   ├── schedules.py                    # delta_load_job + delta_load_schedule, stopped by default
│   │                                    # (Capability 3)
│   ├── definitions.py                  # hand-assembled Definitions(assets=[...], jobs=[...],
│   │                                    # schedules=[...], resources={...}) — no defs/
│   │                                    # auto-discovery anywhere in this project (Decision 8
│   │                                    # made the dbt piece classic, so everything else follows
│   │                                    # the same explicit-import pattern for consistency)
│   └── defs/                           # empty — kept for possible future Component use
└── tests/                              # scaffold default; smoke tests for the code location

dbt/models/*/**/*.yml                   # ADDITIVE ONLY — meta.dagster.asset_key on
                                         # contoso_landing source tables in the relevant
                                         # sources.yml (no model/contract changes)

pyproject.toml                          # root — existing [tool.poe] gains a `dagster` task
requirements.txt / requirements.lock.txt  # + dagster, dagster-dbt, dagster-webserver, dg tooling

AGENT.md                                # §10 roadmap item 7 marked done; new §12 decision entry
README.md / repo docs                   # how to run `poe dagster dev`
```

**Structure Decision**: matches the spec's explicit ask (new top-level `orchestration/`, `dg`/Components scaffold) and research.md Decisions 1–3. No changes to `dbt/models/`, `dbt/macros/`, or `scripts/` beyond the additive `sources.yml` metadata — everything else in those directories is reused as-is.

## Complexity Tracking

*(No Constitution Check violations — this section intentionally left empty.)*
