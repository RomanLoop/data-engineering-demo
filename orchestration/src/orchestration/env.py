"""Loads the repo-root `.env` as an import-time side effect.

Must be imported *before* anything that touches the dbt project — including
Dagster's own `load_from_defs_folder`, which processes `defs/dbt_ingest/
defs.yaml` (a DbtProjectComponent) and runs `dbt parse` internally, needing
FABRIC_* (dbt/profiles.yml's env_var() calls) already set. `definitions.py`
imports this module first, before calling `load_from_defs_folder`, so the env
is loaded regardless of which component/asset module happens to run first.

Safety net for `dagster dev` launched outside `poe` (which loads `.env` itself
via poethepoet's `envfile` setting) — no new secrets, same repo-root `.env`
every other entry point already reads. `override=False` so a real shell env
(e.g. CI secrets) always wins over the local `.env` file.
"""

from pathlib import Path

from dotenv import load_dotenv

REPO_ROOT = Path(__file__).parents[3]

load_dotenv(REPO_ROOT / ".env", override=False)
