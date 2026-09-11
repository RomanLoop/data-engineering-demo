"""dbt project as Dagster assets — classic `@dbt_assets`, not Components.

Decision 8 fallback (specs/003-dagster-orchestration/research.md): the
Components-based `DbtProjectComponent` reliably failed on every reload after
the first with a Windows `PermissionError` while rebuilding its
`.local_defs_state` cache (`StateBackedComponent`'s delete-then-recreate
pattern colliding with a file lock in this repo's synced folder — reproduced
2026-09-11, not a one-off flake: works once right after a manual delete of
the state dir, fails on the very next reload). `@dbt_assets` reads the
manifest directly with no nested state-staging directory, sidestepping the
whole class of bug.

One asset per dbt model (bronze/silver/gold/serving), manifest-derived
(FR-002) — the dbt project itself is untouched. Every dbt test surfaces as a
Dagster asset check (`enable_asset_checks=True`, FR-003).
"""

from collections.abc import Iterator

from dagster import AssetExecutionContext
from dagster_dbt import (
    DagsterDbtTranslator,
    DagsterDbtTranslatorSettings,
    DbtCliResource,
    dbt_assets,
)

from orchestration.resources import dbt_project

_translator = DagsterDbtTranslator(
    settings=DagsterDbtTranslatorSettings(enable_asset_checks=True)
)


@dbt_assets(
    manifest=dbt_project.manifest_path,
    dagster_dbt_translator=_translator,
)
def dbt_models(context: AssetExecutionContext, dbt: DbtCliResource) -> Iterator:
    yield from dbt.cli(["build"], context=context).stream()
