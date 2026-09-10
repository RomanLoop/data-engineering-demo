# Research: Onboard Contoso Customers

Phase 0 output for `specs/001-onboard-contoso-customers/plan.md`. Resolves the spec's remaining unknowns by downloading and inspecting the actual source file (not just public documentation).

## Decision 1: Exact source asset

- **Decision**: `csv-1m.7z` from the [Contoso-Data-Generator-V2-Data "Ready to use data" release](https://github.com/sql-bi/Contoso-Data-Generator-V2-Data/releases/tag/ready-to-use-data), specifically `customer.csv` inside it.
- **Rationale**: MIT-licensed, synthetic data (no real-PII exposure), a single flat CSV per entity — matches "am einfachsten als CSV files" from AGENT.md, and is a stable, versioned GitHub release asset (reproducible download).
- **Alternatives considered**: `bak-ContosoV2-1M.7z` (SQL Server backup — wrong format for a CSV-first Meltano ingestion), `parquet-1m.7z`/`delta-1m.7z` (see Decision 3 — considered and rejected for this entity's initial load), running the generator tool ourselves (more control, unnecessary setup cost for a fixed reference dataset).
- **Correction vs. the spec's placeholder name**: the spec initially guessed `csv-ContosoV2-1M.7z`; the real asset name is `csv-1m.7z` (lowercase, no `ContosoV2` in the CSV asset names — that prefix is only used on the `.bak` assets). Spec updated accordingly.

## Decision 2: `customer.csv` schema and grain

- **Decision**: Confirmed by downloading `csv-1m.7z` and extracting only `customer.csv` (23.8 MB uncompressed). Header:
  `CustomerKey,GeoAreaKey,StartDT,EndDT,Continent,Gender,Title,GivenName,MiddleInitial,Surname,StreetAddress,City,State,StateFull,ZipCode,Country,CountryFull,Birthday,Age,Occupation,Company,Vehicle,Latitude,Longitude`
  104,990 data rows. `CustomerKey` is unique across all rows with zero nulls/blanks (verified via `sort | uniq` and an empty-field scan) — confirms it as the business key and confirms one-row-per-customer grain.
- **Rationale**: Direct inspection beats trusting search-engine summaries of third-party docs (which the plan's predecessor spec step flagged as unconfirmed).
- **Alternatives considered**: Trusting the publicly-documented column list without verification — rejected, since getting the business key or PII list wrong would break the model contract later.

## Decision 3: `StartDT`/`EndDT` are not source-side SCD2 history

- **Decision**: Treat `StartDT`/`EndDT` as ordinary (if PII-adjacent) attribute columns, not as a validity-range mechanism our own SCD logic should special-case or pass through.
- **Rationale**: Since `CustomerKey` is unique (no repeated keys with different `StartDT`/`EndDT` ranges), the file is a flat current-state snapshot — there is no source-side history to reconcile with our own bronze/silver SCD1/SCD2 logic. Our own dedup-before-insert (bronze) and SCD1/SCD2 (silver) macros remain the sole source of truth for change tracking, exactly as the constitution assumes.
- **Alternatives considered**: Mapping `StartDT`/`EndDT` onto our SCD2 valid-from/valid-to columns — rejected; conflating a source attribute with our own change-tracking mechanism would be a modeling bug waiting to happen; keep them as plain attribute columns.

## Decision 4: Delta-load simulator has no vendor-provided change feed to reuse

- **Decision**: The release's `delta-1m.7z` asset is **not** a change-data-capture sample — it is the same snapshot in **Delta Lake table format** (Parquet + `_delta_log/`), one of the release's several output *formats* (CSV/Parquet/Delta/bak/pbix), unrelated to "new/updated records since last load".
- **Rationale**: Verified by listing the archive contents (`customer/`, `customer/_delta_log/`, etc. — standard Delta Lake layout, not a diff/CDC file).
- **Implication**: AGENT.md §4's delta-load simulator must synthesize its own new/updated customer records (e.g., reserve a slice of `customer.csv` as "not yet loaded" for the initial load and drip it in as "new", plus mutate a sample of already-loaded rows for "updated") — this is a task for the simulator's own spec/implementation, not something resolved by picking a different upstream asset.
- **Alternatives considered**: Using `delta-1m.7z` directly as the delta source — rejected, it doesn't represent change events.

## Open item carried forward (not blocking this entity)

- Exact PII classification of borderline columns (`Occupation`, `Vehicle`, `Age`, `GeoAreaKey`-derived geography) beyond the ones already listed in spec.md is a judgment call, not a technical unknown — left as configured in `meta.pii_columns` (name/address/birthday/company fields); revisit if a real (non-synthetic) source is onboarded later and stricter classification is warranted.
