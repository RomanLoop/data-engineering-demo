"""Delta-load job + schedule (Capability 3, specs/003-dagster-orchestration).

`delta_simulation` is an asset with no deps that mutates all 7 entities'
local CSVs via scripts/simulate_delta_load/*, one small delta each. Every
`landing_<entity>` asset (landing_assets.py) declares it as an extra
dependency, so a single `delta_load_job` materializing the whole graph runs:
simulate -> upload/land -> bronze -> ... -> serving in one Dagster run --
the "simulate -> upload -> re-land -> dbt build" loop AGENT.md §4 calls for,
expressed as ordinary asset dependencies rather than a bolted-on op ahead of
the asset graph.

The schedule is stopped by default (FR-011, NFR-005) -- this project has
repeatedly hit Fabric capacity limits (TooManyRequestsForCapacity, AGENT.md
§12 decision 8) from ordinary interactive use; an unattended schedule needs
to be an explicit, visible opt-in, not a default.
"""

import subprocess
import sys

from dagster import (
    AssetExecutionContext,
    AssetSelection,
    DefaultScheduleStatus,
    ScheduleDefinition,
    asset,
    define_asset_job,
)

from orchestration.env import REPO_ROOT

# entity -> simulator script filename. A few don't match the entity name --
# e.g. the "customer" landing table/asset but contoso_customers.py simulator
# (each script defaults --csv to the matching data/contoso/<entity>.csv).
SIMULATOR_SCRIPTS = {
    "customer": "contoso_customers.py",
    "product": "contoso_product.py",
    "store": "contoso_store.py",
    "date": "contoso_date.py",
    "currencyexchange": "contoso_currencyexchange.py",
    "orders": "contoso_orders.py",
    "orderrows": "contoso_orderrows.py",
}

# Small, conservative per-tick volumes (data-model.md Capability 3).
DEFAULT_NEW = 5
DEFAULT_UPDATED = 5

# Conservative cadence -- see module docstring on this project's Fabric
# capacity history.
DEFAULT_CRON_SCHEDULE = "0 */6 * * *"


@asset(group_name="landing")
def delta_simulation(context: AssetExecutionContext) -> None:
    for entity, script in SIMULATOR_SCRIPTS.items():
        script_path = REPO_ROOT / "scripts" / "simulate_delta_load" / script
        # currencyexchange's simulator has a different CLI (--new-date, not
        # --new -- rates are appended per-date, not per-row) -- found live
        # 2026-09-11: argparse's prefix matching silently resolved a passed
        # `--new 5` to `--new-date 5`, which then failed trying to parse "5"
        # as an ISO date. Every other simulator shares the --new/--updated
        # interface.
        if entity == "currencyexchange":
            args = ["--updated", str(DEFAULT_UPDATED)]
        else:
            args = ["--new", str(DEFAULT_NEW), "--updated", str(DEFAULT_UPDATED)]
        result = subprocess.run(
            [sys.executable, str(script_path), *args],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        context.log.info(f"{entity} ({script}): {(result.stdout or result.stderr).strip()}")
        result.check_returncode()


delta_load_job = define_asset_job(
    name="delta_load_job",
    selection=AssetSelection.all(),
)

delta_load_schedule = ScheduleDefinition(
    name="delta_load_schedule",
    job=delta_load_job,
    cron_schedule=DEFAULT_CRON_SCHEDULE,
    default_status=DefaultScheduleStatus.STOPPED,
)
