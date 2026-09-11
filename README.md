# data-engineering-demo

End-to-end modern data engineering stack on Microsoft Fabric (Meltano/CSV → dbt-fabricspark medallion lakehouse → Dagster orchestration). See [AGENT.md](AGENT.md) for the full architecture, conventions, and decision log.

## Local setup

```powershell
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt   # exact reproduce: requirements.lock.txt
.venv\Scripts\pip install -e ./orchestration --no-deps   # one-time, for the Dagster project
```

Everything runs through [poe](https://poethepoet.natn.io/) (`pyproject.toml`), which loads the repo-root `.env`:

```powershell
poe dbt build --select bronze_contoso__product+
poe lint
poe dagster dev
```

## Running the pipeline via Dagster

`orchestration/` (specs/003-dagster-orchestration) wraps the pipeline in a single Dagster asset graph:

```powershell
poe dagster dev
```

Opens the Dagster UI with:

- **33 dbt-model assets** (bronze → silver → gold → serving), one per model, dbt tests as asset checks.
- **7 `landing_<entity>` assets** (CSV upload to OneLake + landing bootstrap), wired upstream of the matching bronze model.
- **`delta_simulation`**, upstream of every landing asset — mutates the local CSVs via `scripts/simulate_delta_load/*` with a small delta.

Materializing the full graph runs the whole chain — simulate → upload → land → bronze → … → serving — in one run.

**`delta_load_schedule`** (cron `0 */6 * * *`) runs `delta_simulation` → the full chain on a schedule, to continuously exercise incremental processing and idempotency. **It is stopped by default** — this project has repeatedly hit Fabric capacity limits (`TooManyRequestsForCapacity`, AGENT.md §12) from ordinary interactive use, so an unattended schedule is an explicit opt-in:

```powershell
poe dagster schedule start delta_load_schedule   # from orchestration/
```

Requires `az login` (same Azure CLI session dbt already uses) for anything that actually runs against Fabric — the asset graph itself loads and can be inspected without one.
