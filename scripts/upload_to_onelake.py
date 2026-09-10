#!/usr/bin/env python3
"""Upload a local file to a Fabric Lakehouse's OneLake Files area.

Stage-1 bootstrap helper (AGENT.md §11, plan.md Complexity Tracking): lands
a CSV via the ADLS Gen2 DFS REST API (OneLake exposes the same API — see
research notes on onelake-apis-in-action), so a native Spark bulk read+write
(dbt/macros/bootstrap_landing_customer.sql) can load it as a single
distributed job instead of dbt seed's row-batched INSERT statements
(~30+ minutes for 105K rows; the OneLake upload + Spark bulk load pair
does the same load in well under a minute of actual data-movement time).

Auth: reuses the caller's `az login` session (AzureCliCredential) — same
identity the developer already uses for dbt (profiles.yml, authentication:
CLI). Requires the `azure-identity` package (`pip install azure-identity`).

Usage:
    python scripts/upload_to_onelake.py \\
        --local data/contoso/customer.csv \\
        --remote Files/contoso/customer.csv \\
        --workspace-id <FABRIC_WORKSPACE_ID> \\
        --lakehouse-id <FABRIC_LAKEHOUSE_ID> \\
        --dfs-endpoint <FABRIC_ONELAKE_DFS_ENDPOINT>

    # or, simplest — flags default to the matching env vars (see .env.example):
    python scripts/upload_to_onelake.py --local data/contoso/customer.csv --remote Files/contoso/customer.csv

Workspace/lakehouse IDs and the region-specific DFS endpoint default to the
FABRIC_WORKSPACE_ID / FABRIC_LAKEHOUSE_ID / FABRIC_ONELAKE_DFS_ENDPOINT env
vars (see .env.example) if the flags are omitted.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    print("Missing dependency: pip install requests", file=sys.stderr)
    raise

try:
    from azure.identity import AzureCliCredential
except ImportError:
    print("Missing dependency: pip install azure-identity", file=sys.stderr)
    raise

STORAGE_SCOPE = "https://storage.azure.com/.default"


def upload(local_path: Path, dfs_endpoint: str, workspace_id: str, lakehouse_id: str, remote_path: str) -> None:
    token = AzureCliCredential().get_token(STORAGE_SCOPE).token
    headers = {"Authorization": f"Bearer {token}"}

    file_url = f"{dfs_endpoint}/{workspace_id}/{lakehouse_id}/{remote_path}"
    filesize = local_path.stat().st_size

    print(f"Creating {file_url} ({filesize:,} bytes)...")
    resp = requests.put(f"{file_url}?resource=file", headers={**headers, "Content-Length": "0"})
    resp.raise_for_status()

    print("Uploading content...")
    with local_path.open("rb") as f:
        resp = requests.patch(
            f"{file_url}?action=append&position=0",
            headers={**headers, "Content-Type": "application/octet-stream"},
            data=f,
        )
    resp.raise_for_status()

    print("Flushing...")
    resp = requests.patch(
        f"{file_url}?action=flush&position={filesize}",
        headers={**headers, "Content-Length": "0"},
    )
    resp.raise_for_status()

    print(f"OK: {local_path} -> {remote_path} ({filesize:,} bytes)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--local", required=True, type=Path, help="local file to upload")
    parser.add_argument("--remote", required=True, help="destination path within the lakehouse, e.g. Files/contoso/customer.csv")
    parser.add_argument("--workspace-id", default=os.environ.get("FABRIC_WORKSPACE_ID"))
    parser.add_argument("--lakehouse-id", default=os.environ.get("FABRIC_LAKEHOUSE_ID"))
    parser.add_argument("--dfs-endpoint", default=os.environ.get("FABRIC_ONELAKE_DFS_ENDPOINT"))
    args = parser.parse_args()

    missing = [name for name, val in [
        ("--workspace-id/FABRIC_WORKSPACE_ID", args.workspace_id),
        ("--lakehouse-id/FABRIC_LAKEHOUSE_ID", args.lakehouse_id),
        ("--dfs-endpoint/FABRIC_ONELAKE_DFS_ENDPOINT", args.dfs_endpoint),
    ] if not val]
    if missing:
        parser.error(f"missing required values: {', '.join(missing)}")

    if not args.local.exists():
        parser.error(f"local file not found: {args.local}")

    upload(args.local, args.dfs_endpoint, args.workspace_id, args.lakehouse_id, args.remote)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
