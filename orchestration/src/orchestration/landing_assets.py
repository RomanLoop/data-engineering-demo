"""Landing assets — one per Contoso entity (Capability 2,
specs/003-dagster-orchestration).

Each asset's materialization: upload `data/contoso/<csv_name>.csv` to OneLake
Files (reusing scripts/upload_to_onelake.py's upload() function directly —
loaded by path since scripts/ isn't a package), then run the matching dbt
landing-bootstrap macro. Wired to the corresponding bronze source via
`meta.dagster.asset_key` in dbt/models/bronze/contoso/_contoso__sources.yml
(research.md Decision 5), so bronze_contoso__<entity> shows landing_<entity>
as its upstream dependency automatically.

`customer` is the one asymmetric case: it predates the generalized
`bootstrap_landing_table` macro (001) and still uses the dedicated
`bootstrap_landing_customer` macro, which takes no args.

Column lists mirror the `dbt run-operation bootstrap_landing_table` examples
in specs/002-onboard-contoso-remaining-entities/quickstart.md — kept here as
the executable source of truth for Dagster-triggered runs; update both if
either source's schema changes.
"""

import importlib.util
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

from dagster import AssetExecutionContext, MaterializeResult, asset

from orchestration.env import REPO_ROOT
from orchestration.resources import dbt_project, dbt_resource

DATA_DIR = REPO_ROOT / "data" / "contoso"


def _load_module_from_path(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_upload = _load_module_from_path(
    "upload_to_onelake", REPO_ROOT / "scripts" / "upload_to_onelake.py"
).upload


@dataclass(frozen=True)
class LandingEntity:
    entity: str  # bootstrap_landing_table's `entity` arg; also the schema-table suffix
    csv_name: str  # data/contoso/<csv_name>.csv
    columns: list[dict[str, str]] = field(default_factory=list)  # empty => customer's own macro


LANDING_ENTITIES = [
    LandingEntity(entity="customer", csv_name="customer", columns=[]),  # bootstrap_landing_customer
    LandingEntity(
        entity="product",
        csv_name="product",
        columns=[
            {"name": "ProductKey", "type": "int"},
            {"name": "ProductCode"},
            {"name": "ProductName"},
            {"name": "Manufacturer"},
            {"name": "Brand"},
            {"name": "Color"},
            {"name": "WeightUnit"},
            {"name": "Weight", "type": "double"},
            {"name": "Cost", "type": "double"},
            {"name": "Price", "type": "double"},
            {"name": "CategoryKey", "type": "int"},
            {"name": "CategoryName"},
            {"name": "SubCategoryKey", "type": "int"},
            {"name": "SubCategoryName"},
        ],
    ),
    LandingEntity(
        entity="store",
        csv_name="store",
        columns=[
            {"name": "StoreKey", "type": "int"},
            {"name": "StoreCode"},
            {"name": "GeoAreaKey", "type": "int"},
            {"name": "CountryCode"},
            {"name": "CountryName"},
            {"name": "State"},
            {"name": "OpenDate", "type": "date"},
            {"name": "CloseDate", "type": "date"},
            {"name": "Description"},
            {"name": "SquareMeters", "type": "double"},
            {"name": "Status"},
        ],
    ),
    LandingEntity(
        entity="date",
        csv_name="date",
        columns=[
            {"name": "Date", "type": "date"},
            {"name": "DateKey", "type": "int"},
            {"name": "Year", "type": "int"},
            {"name": "YearQuarter"},
            {"name": "YearQuarterNumber", "type": "int"},
            {"name": "Quarter", "type": "int"},
            {"name": "YearMonth"},
            {"name": "YearMonthShort"},
            {"name": "YearMonthNumber", "type": "int"},
            {"name": "Month"},
            {"name": "MonthShort"},
            {"name": "MonthNumber", "type": "int"},
            {"name": "DayofWeek"},
            {"name": "DayofWeekShort"},
            {"name": "DayofWeekNumber", "type": "int"},
            {"name": "WorkingDay", "type": "int"},
            {"name": "WorkingDayNumber", "type": "int"},
        ],
    ),
    LandingEntity(
        entity="currencyexchange",
        csv_name="currencyexchange",
        columns=[
            {"name": "Date", "type": "date"},
            {"name": "FromCurrency"},
            {"name": "ToCurrency"},
            {"name": "Exchange", "type": "double"},
        ],
    ),
    LandingEntity(
        entity="orders",
        csv_name="orders",
        columns=[
            {"name": "OrderKey", "type": "int"},
            {"name": "CustomerKey", "type": "int"},
            {"name": "StoreKey", "type": "int"},
            {"name": "OrderDate", "type": "date"},
            {"name": "DeliveryDate", "type": "date"},
            {"name": "CurrencyCode"},
        ],
    ),
    LandingEntity(
        entity="orderrows",
        csv_name="orderrows",
        columns=[
            {"name": "OrderKey", "type": "int"},
            {"name": "LineNumber", "type": "int"},
            {"name": "ProductKey", "type": "int"},
            {"name": "Quantity", "type": "int"},
            {"name": "UnitPrice", "type": "double"},
            {"name": "NetPrice", "type": "double"},
            {"name": "UnitCost", "type": "double"},
        ],
    ),
]


def _landed_row_count(entity: str) -> int | None:
    """Best-effort row count via `dbt show --output json`; None if unparseable
    rather than failing the asset over an observability nicety (untested live
    as of 2026-09-11 — Fabric was unreachable; verify once it's back)."""
    try:
        result = subprocess.run(
            [
                "dbt",
                "show",
                "--inline",
                f"select count(*) as n from landing.landing_{entity}",
                "--output",
                "json",
                "--limit",
                "1",
                "--quiet",
                "--project-dir",
                str(dbt_project.project_dir),
                "--profiles-dir",
                str(dbt_project.profiles_dir),
                "--target",
                dbt_project.target or "dev",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        payload = json.loads(result.stdout)
        return int(payload["show"][0]["n"])
    except Exception:
        return None


def _make_landing_asset(config: LandingEntity):
    asset_key = f"landing_{config.entity}"
    csv_path = DATA_DIR / f"{config.csv_name}.csv"
    remote_path = f"Files/contoso/{config.csv_name}.csv"

    @asset(key=asset_key, group_name="landing", deps=["delta_simulation"])
    def _landing_asset(context: AssetExecutionContext) -> MaterializeResult:
        import os

        _upload(
            local_path=csv_path,
            dfs_endpoint=os.environ["FABRIC_ONELAKE_DFS_ENDPOINT"],
            workspace_id=os.environ["FABRIC_WORKSPACE_ID"],
            lakehouse_id=os.environ["FABRIC_LAKEHOUSE_ID"],
            remote_path=remote_path,
        )

        if config.columns:
            args = {"entity": config.entity, "csv_path": remote_path, "columns": config.columns}
            dbt_resource.cli(
                ["run-operation", "bootstrap_landing_table", "--args", json.dumps(args)],
                context=context,
            ).wait()
        else:
            dbt_resource.cli(["run-operation", "bootstrap_landing_customer"], context=context).wait()

        row_count = _landed_row_count(config.entity)
        metadata = {"entity": config.entity, "csv_path": remote_path}
        if row_count is not None:
            metadata["landed_row_count"] = row_count
        return MaterializeResult(metadata=metadata)

    return _landing_asset


landing_assets = [_make_landing_asset(c) for c in LANDING_ENTITIES]
