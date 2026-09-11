"""Shared dbt project/resource wiring for the orchestration code location.

Deliberately lives *outside* `defs/` (unlike tasks.md's original path) since
`load_from_defs_folder` walks `defs/` expecting each entry to be a Component
or a module exposing Dagster definitions — this is a plain importable helper,
not a definitions source, so it stays a sibling of `definitions.py` instead
(specs/003-dagster-orchestration research.md Decision 3/4).

The existing dbt project at the repo root's `dbt/` is referenced in place —
not moved or duplicated. `profiles_dir` is set explicitly rather than relying
on process cwd: `poe dbt` sets `DBT_PROFILES_DIR=.` with `cwd=dbt/`, but
Dagster's process does not share that cwd (research.md Decision 4).

`DbtProject.prepare_if_dev()` runs `dbt deps` + `dbt parse` only — no live
Fabric/Spark session required, verified live 2026-09-10/11 even while Fabric
was unreachable. Only *materializing* an asset needs a live session.
"""

from dagster_dbt import DbtCliResource, DbtProject

from orchestration.env import REPO_ROOT

DBT_PROJECT_DIR = REPO_ROOT / "dbt"

dbt_project = DbtProject(
    project_dir=DBT_PROJECT_DIR,
    profiles_dir=DBT_PROJECT_DIR,
    target="dev",
)
dbt_project.prepare_if_dev()

dbt_resource = DbtCliResource(project_dir=dbt_project)
