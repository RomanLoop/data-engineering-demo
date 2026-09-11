# Quickstart: validating the Dagster orchestration layer

Prerequisites: `.venv` has `dagster`/`dagster-dbt`/`dagster-webserver` installed (task in
`tasks.md`), `az login` is active, `.env` has the existing `FABRIC_*` vars, and the dbt project
already builds standalone via `poe dbt build` (i.e. this is additive orchestration over a working
pipeline, not a first-time pipeline setup — see `001`/`002` quickstarts for that).

## Scenario 1 — Code location loads with no live Fabric session (Capability 1)

```powershell
poe dagster dev
```

**Expected outcome**: the webserver starts, the asset graph shows one asset per dbt model grouped
by layer (bronze/silver/gold/serving) with lineage matching `dbt ls --select ... --output json` /
the manifest, and there are zero code-location load errors — even if Fabric capacity is currently
exhausted (research.md Decision 4: manifest prep is `dbt parse` only, no warehouse round-trip).
This directly validates SC-002 and SC-006.

## Scenario 2 — Materialize the dbt-only graph (Capability 1)

From the Dagster UI (or `dagster asset materialize --select '*'` scoped to the dbt asset group),
materialize every dbt-model asset with the landing tables already populated from prior manual
runs.

**Expected outcome**: identical result to `poe dbt build` — same models run in the same dependency
order, every dbt test appears as a passed asset check (SC-003), row counts match the last known
good state (customers 105,495 / product 2,545 / store 76 / date 4,033 / currencyexchange 100,475 /
orders 980,966 / orderrows 2,349,591).

## Scenario 3 — Full chain from a clean landing schema (Capability 2)

Drop or ignore the existing `landing` schema state, then materialize the whole graph from the
`landing_*` assets down (all 7 entities).

**Expected outcome**: each `landing_<entity>` asset uploads its CSV and lands it (row count in
asset metadata matches the CSV), then bronze → silver → gold → serving build in dependency order
in one Dagster run, ending at the same serving row counts as Scenario 2. Confirms FR-006/FR-007/
FR-009 and SC-001.

## Scenario 4 — Idempotent rerun (NFR-001)

Immediately re-materialize the full graph from Scenario 3 with no source changes.

**Expected outcome**: every layer's row count is identical to Scenario 3 — bronze dedup and the
SCD1 anti-join / SCD2 hash comparison produce zero net new rows, matching the existing
`dbt build` idempotency behavior this project already validated in `001`/`002`. Confirms SC-004.

## Scenario 5 — Delta-load job, manually triggered (Capability 3)

```powershell
# from the Dagster UI: Jobs -> delta_load_job -> Launch Run
# or:
poe dagster job execute -j delta_load_job
```

**Expected outcome**: the simulators mutate the CSVs (small N new / M updated per entity), the job
re-materializes landing → ... → serving, bronze grows by exactly N rows per entity, SCD2 silver
(dimensions) adds correctly-versioned rows for the M updates, SCD1 silver (facts) overwrites in
place — matching `002`'s acceptance criteria. Running the same job again immediately with no new
simulation changes nothing (SC-005).

## Scenario 6 — Schedule stays off until explicitly enabled (FR-011)

```powershell
poe dagster schedule list
```

**Expected outcome**: `delta_load_schedule` is listed with status `STOPPED`. Enabling it (via the
UI or `dagster schedule start delta_load_schedule`) and waiting for one tick (or using
`dagster schedule test`) reproduces Scenario 5's outcome without manual intervention.

## Scenario 7 — Secrets scan (NFR-003)

```powershell
Select-String -Path orchestration\**\*.py,orchestration\**\*.yaml -Pattern 'workspace|lakehouse|tenant|secret|password' -CaseSensitive:$false
```

**Expected outcome**: any matches are variable *names* referencing `.env`/`os.environ`, never
literal IDs, keys, or connection strings (constitution VI). Cross-check against
`scripts/upload_to_onelake.py`'s existing pattern for what "clean" looks like.
