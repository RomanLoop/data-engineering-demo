import orchestration.env  # noqa: E402,F401 — load .env before anything touches dbt/Fabric

from dagster import Definitions, definitions

from orchestration.dbt_assets import dbt_models
from orchestration.landing_assets import landing_assets
from orchestration.resources import dbt_resource
from orchestration.schedules import delta_load_job, delta_load_schedule, delta_simulation


@definitions
def defs() -> Definitions:
    return Definitions(
        assets=[dbt_models, delta_simulation, *landing_assets],
        jobs=[delta_load_job],
        schedules=[delta_load_schedule],
        resources={"dbt": dbt_resource},
    )
