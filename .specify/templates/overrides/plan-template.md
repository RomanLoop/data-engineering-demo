# Implementation Plan: [DATASET / PIPELINE CHANGE]

**Branch**: `[###-short-name]` | **Date**: [DATE] | **Spec**: [link]

**Input**: Pipeline specification from `/specs/[###-short-name]/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

[Extract from spec: primary source/entities being onboarded + technical approach from research]

## Technical Context

<!--
  ACTION REQUIRED: Replace the content in this section with the technical details
  for this change. The structure here is advisory; delete anything not applicable.
-->

**Source system(s)**: [e.g., Contoso 1M CSV export, Oracle schema `HR`, Kafka topic]

**Meltano extractor/loader**: [e.g., `tap-csv` → `target-fabric-lakehouse`, or NEEDS CLARIFICATION]

**dbt layer(s) touched**: [bronze / silver / gold / serving — list model names using the `<layer>_<source>__<entity>` convention]

**Fabric objects**: [lakehouse(s)/warehouse(s) touched, e.g. `lh_contoso`]

**Orchestration**: [Dagster asset(s)/schedule if already integrated at this point in the roadmap, or "manual/CLI-triggered — Dagster not yet integrated" per AGENT.md §10]

**Testing**: [dbt tests + contract enforcement to add; delta-load simulator scenarios to exercise]

**Performance/volume**: [expected row counts, run-time budget, or NEEDS CLARIFICATION]

**Constraints**: [e.g., "silver must not join other models", "bronze must remain append-only", or NEEDS CLARIFICATION]

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design. See `.specify/memory/constitution.md`.*

[Explicitly confirm: idempotency preserved, additive schema evolution respected, medallion layer boundaries not blurred, model contracts + meta config planned, no secrets introduced. Note any violation and its justification in Complexity Tracking below.]

## Project Structure

### Documentation (this change)

```text
specs/[###-short-name]/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command) — entities & contracts
├── quickstart.md        # Phase 1 output (/speckit-plan command) — pipeline validation guide
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Repository layout (this change)

<!--
  ACTION REQUIRED: List only the concrete paths this change actually touches,
  following the repo's real layout (adjust as the repo grows):
-->

```text
meltano/
└── extract/[source]/           # Meltano tap config for this source

dbt/models/
├── bronze/[source]/            # bronze_<source>__<entity>.sql + .yml (contract, meta)
├── silver/[source]/            # silver_<source>__<entity>.sql + .yml
├── gold/                       # gold_<entity>.sql + .yml (cross-entity joins allowed here)
└── serving/                    # serving views, RLS

dbt/macros/                     # only if a new/changed macro is needed for this entity

dagster/                        # only if orchestration has been introduced per roadmap

scripts/simulate_delta_load/    # only if this change needs new simulator scenarios
```

**Structure Decision**: [confirm the above matches this change, or document deviations]

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|---------------------------------------|
| [e.g., silver joins another model] | [current need] | [why staying within-table was insufficient] |
