---

description: "Task list template for a dataset/pipeline change"
---

# Tasks: [DATASET / PIPELINE CHANGE]

**Input**: Design documents from `/specs/[###-short-name]/`

**Prerequisites**: plan.md (required), spec.md (required for entities), research.md, data-model.md

**Tests**: dbt tests/contracts are NOT optional in this repo (constitution — model contracts are mandatory). Task lists always include the contract/test tasks for touched models.

**Organization**: Tasks are grouped by medallion layer, with entity-specific work further tagged by entity so each entity's full bronze→silver→gold→serving slice can be delivered and validated independently.

## Format: `[ID] [P?] [Entity?] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Entity]**: Which entity this task belongs to (e.g., E1, E2 — matches spec.md priorities), omitted for shared/foundational tasks
- Include exact file paths in descriptions, using the `<layer>_<source>__<entity>` naming convention

<!--
  ============================================================================
  IMPORTANT: The tasks below are SAMPLE TASKS for illustration purposes only.

  The /speckit-tasks command MUST replace these with actual tasks based on:
  - Entities from spec.md (with their priorities P1, P2, P3...)
  - Source/ingestion requirements from plan.md
  - Layer placement & transformations from spec.md
  - Contract/meta config implied by each entity's business key, dedup, PII, SCD columns

  DO NOT keep these sample tasks in the generated tasks.md file.
  ============================================================================
-->

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Repo/pipeline scaffolding needed before any entity can be onboarded

- [ ] T001 Add/update Meltano extractor config for the source in `meltano/extract/[source]/`
- [ ] T002 [P] Configure dbt project settings for touched layers (schemas, `on_schema_change: append_new_columns`)
- [ ] T003 [P] Configure linting (`sqlfluff`) for new model paths

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared macros/contracts config that MUST exist before ANY entity's layer work can be implemented

**⚠️ CRITICAL**: No entity work can begin until this phase is complete

- [ ] T004 [P] Add/extend `dedup_before_insert` macro if this source needs new dedup semantics
- [ ] T005 [P] Add/extend `mask_pii_columns` macro if this source introduces new PII columns
- [ ] T006 [P] Add/extend `apply_scd1`/`apply_scd2` macros if this source needs new SCD semantics
- [ ] T007 Define shared `meta` conventions for this source (business key, dedup, PII, SCD columns) referenced by all entity models below

**Checkpoint**: Foundation ready - entity onboarding can now begin in parallel

---

## Phase 3: Entity 1 - [Name] (Priority: P1) 🎯 MVP

**Goal**: [Brief description of what onboarding this entity delivers]

**Independent test**: [How to verify this entity's full slice works on its own — e.g. `dbt build --select +gold_[entity]`]

### Bronze — Entity 1

- [ ] T008 [P] [E1] Create `bronze_[source]__[entity]` model in `dbt/models/bronze/[source]/bronze_[source]__[entity].sql` (append-only, dedup-before-insert)
- [ ] T009 [E1] Define contract + `meta` (business_key, dedup_columns, pii_columns) in `bronze_[source]__[entity].yml`

### Silver — Entity 1

- [ ] T010 [E1] Create `silver_[source]__[entity]` model in `dbt/models/silver/[source]/silver_[source]__[entity].sql` (type casting, renaming, enrichment — no cross-model joins)
- [ ] T011 [E1] Define contract + `meta` (business_key, scd1_columns, scd2_columns) in `silver_[source]__[entity].yml`

### Gold — Entity 1

- [ ] T012 [E1] Create `gold_[entity]` model in `dbt/models/gold/gold_[entity].sql` (business logic; cross-entity joins only once those entities exist)
- [ ] T013 [E1] Define contract in `gold_[entity].yml`

### Serving & validation — Entity 1

- [ ] T014 [E1] Expose `serving_[entity]` view (+ RLS if required by spec)
- [ ] T015 [E1] Run initial load end-to-end and validate against spec Acceptance Scenarios
- [ ] T016 [E1] Run delta-load simulator against Entity 1 and validate idempotency (no duplicate bronze rows) + correct SCD behavior in silver

**Checkpoint**: Entity 1 is fully functional bronze→serving and testable independently

---

## Phase 4: Entity 2 - [Name] (Priority: P2)

**Goal**: [Brief description]

**Independent test**: [...]

### Bronze / Silver / Gold / Serving — Entity 2

[Same task structure as Entity 1: T0xx per layer]

- [ ] T0xx [E2] Integrate with Entity 1 in gold (cross-entity join), if the spec calls for it

**Checkpoint**: Entities 1 AND 2 both work independently, and any gold-level join between them is validated

---

[Add more entity phases as needed, following the same pattern]

---

## Phase N: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple entities

- [ ] TXXX [P] Documentation updates (AGENT.md, model descriptions)
- [ ] TXXX Re-run full `dbt build` + `dbt test` across all touched layers
- [ ] TXXX Confirm no secrets were introduced (grep configs/logs)
- [ ] TXXX Validate schema-evolution behavior end-to-end (simulate a new source column)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all entity work
- **Entities (Phase 3+)**: All depend on Foundational phase completion
  - Entities can proceed in parallel (if staffed) or sequentially in priority order (P1 → P2 → P3)
  - Within an entity: bronze → silver → gold → serving is strictly sequential (medallion boundaries)
- **Polish (Final Phase)**: Depends on all desired entities being complete

### Entity Dependencies

- **Entity 1 (P1)**: Can start after Foundational (Phase 2) - no dependency on other entities
- **Entity 2 (P2)**: Can start after Foundational (Phase 2) - independently testable through gold; only its cross-entity gold join (if any) depends on Entity 1

### Within Each Entity

- Bronze before silver before gold before serving (medallion boundaries are not parallelizable)
- Contract + `meta` definition accompanies the model it describes, not a separate later pass
- Delta-load simulator run + idempotency check before the entity is considered done

### Parallel Opportunities

- All Setup and Foundational tasks marked [P] can run in parallel
- Once Foundational completes, different entities' bronze models can be built in parallel
- Bronze/silver/gold models for *different* entities marked [P] can run in parallel; layers *within* one entity cannot

---

## Implementation Strategy

### MVP First (Entity 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all entities)
3. Complete Phase 3: Entity 1, bronze → serving
4. **STOP and VALIDATE**: run initial load + delta-load simulator against Entity 1 only
5. Ship/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → foundation ready
2. Add Entity 1 → validate independently → ship (MVP!)
3. Add Entity 2 → validate independently (+ any gold join to Entity 1) → ship
4. Each entity adds value without breaking previously-shipped entities (additive schema evolution)

---

## Notes

- [P] tasks = different files, no dependencies
- [Entity] label maps task to a specific entity for traceability
- Each entity should be independently completable and testable through serving
- Verify idempotency (rerun bronze twice, confirm no duplicates) before marking an entity done
- Commit after each task or logical group
- Avoid: vague tasks, same-file conflicts, cross-entity dependencies that break independence — except deliberate gold-level joins
