import orchestration.env  # noqa: E402,F401 — load .env before anything touches dbt/Fabric

from dagster import Definitions, definitions

from orchestration.dbt_assets import dbt_models
from orchestration.resources import dbt_resource


@definitions
def defs() -> Definitions:
    return Definitions(
        assets=[dbt_models],
        resources={"dbt": dbt_resource},
    )
