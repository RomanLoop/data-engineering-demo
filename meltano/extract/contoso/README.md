# Contoso Meltano extraction — deferred

**Status: blocked, not yet implemented.** See `specs/001-onboard-contoso-customers/plan.md` (Technical Context / Complexity Tracking) and AGENT.md §11.

The only available Meltano Azure Blob target, `target-azureblobstorage`, authenticates via storage account key. Fabric OneLake only accepts Azure AD (service principal) authentication — no shared key/SAS. No compatible Meltano→Fabric target exists today.

**Recommended path once unblocked**: `tap-csv` → `target-azureblobstorage` into a plain Azure Storage Account (account-key auth works there), then a **Fabric OneLake Shortcut** references that container from `lh_contoso` without copying data.

Until then, `customers` (and any further Contoso entities) land via a temporary dbt seed — see `dbt/seeds/contoso/`.
