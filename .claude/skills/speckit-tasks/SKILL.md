---
name: "speckit-tasks"
description: "Generate an actionable, dependency-ordered tasks.md for the feature based on available design artifacts."
argument-hint: "Optional task generation constraints"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "github-spec-kit"
  source: "templates/commands/tasks.md"
user-invocable: true
disable-model-invocation: false
---


## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before tasks generation)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_tasks` key
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing command invocations from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the following based on its `optional` flag:
  - **Optional hook** (`optional: true`):
    ```
    ## Extension Hooks

    **Optional Pre-Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```
  - **Mandatory hook** (`optional: false`):
    ```
    ## Extension Hooks

    **Automatic Pre-Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}

    Wait for the result of the hook command before proceeding to the Outline.
    ```
    After emitting the block above you MUST actually invoke the hook and wait for it to finish before continuing. Run it the same way you would run the command yourself in this agent/session (the invocation may differ from the literal `{command}` id shown above, e.g. a skills-mode agent runs it as `/skill:speckit-...` or `$speckit-...`). Emitting the block alone does not run the hook.
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently

## Outline

1. **Setup**: Run `.specify/scripts/powershell/setup-tasks.ps1 -Json` from repo root and parse FEATURE_DIR, TASKS_TEMPLATE_CONTENT, TASKS_TEMPLATE, and AVAILABLE_DOCS list. `FEATURE_DIR` and `TASKS_TEMPLATE` must be absolute paths when provided. `AVAILABLE_DOCS` is a list of document names/relative paths available under `FEATURE_DIR` (for example `research.md` or `contracts/`). For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

2. **Load design documents**: Read from FEATURE_DIR:
   - **Required**: plan.md (source system, dbt layers touched, Fabric objects, repo structure), spec.md (entities with priorities and their data contract)
   - **Optional**: data-model.md (entity/contract detail), research.md (decisions), quickstart.md (validation scenarios)
   - **IF EXISTS**: Load `.specify/memory/constitution.md` for project principles and governance constraints (idempotency, additive schema evolution, medallion boundaries, mandatory contracts)
   - Note: Not all changes have all documents. Generate tasks based on what's available.

3. **Execute task generation workflow**:
   - Load plan.md and extract source system, Meltano config, dbt layers/models touched, Fabric objects, repo structure
   - Load spec.md and extract entities with their priorities (P1, P2, P3, etc.), business keys, dedup/PII/SCD columns, and layer placement
   - If data-model.md exists: use it to fill in exact contract/`meta` fields per model
   - If research.md exists: extract decisions for setup tasks
   - Generate tasks organized by medallion layer within each entity (see Task Generation Rules below) — bronze → silver → gold → serving is strictly sequential per entity; different entities can proceed in parallel
   - Generate dependency graph showing entity completion order
   - Create parallel execution examples per entity
   - Validate task completeness (each entity has bronze/silver/gold/serving tasks plus a delta-load simulator validation task, and is independently testable end-to-end)

4. **Generate tasks.md**: Use TASKS_TEMPLATE_CONTENT (from the JSON output above) as the structure. For compatibility with older setup scripts that omit TASKS_TEMPLATE_CONTENT, read TASKS_TEMPLATE instead. Fill with:
   - Correct pipeline/dataset change name from plan.md
   - Phase 1: Setup tasks (Meltano/dbt project scaffolding)
   - Phase 2: Foundational tasks (shared macros/contract conventions blocking all entities)
   - Phase 3+: One phase per entity (in priority order from spec.md), each broken into bronze/silver/gold/serving sub-sections
   - Each phase includes: entity goal, independent test criteria, contract/`meta` tasks, implementation tasks, a delta-load simulator validation task
   - Final Phase: Polish & cross-cutting concerns (full `dbt build`, secrets check, schema-evolution validation)
   - All tasks must follow the strict checklist format (see Task Generation Rules below)
   - Clear file paths for each task, using the `<layer>_<source>__<entity>` naming convention
   - Dependencies section showing entity completion order
   - Parallel execution examples per entity
   - Implementation strategy section (MVP first = Entity 1 through serving, incremental delivery)

## Mandatory Post-Execution Hooks

**You MUST complete this section before reporting completion to the user.**

Check if `.specify/extensions.yml` exists in the project root.
- If it does not exist, or no hooks are registered under `hooks.after_tasks`, skip to the Completion Report.
- If it exists, read it and look for entries under the `hooks.after_tasks` key.
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue to the Completion Report.
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing command invocations from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the following based on its `optional` flag:
  - **Mandatory hook** (`optional: false`) — **You MUST emit `EXECUTE_COMMAND:` for each mandatory hook**:
    ```
    ## Extension Hooks

    **Automatic Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}
    ```
    After emitting the block above you MUST actually invoke the hook and wait for it to finish before continuing. Run it the same way you would run the command yourself in this agent/session (the invocation may differ from the literal `{command}` id shown above, e.g. a skills-mode agent runs it as `/skill:speckit-...` or `$speckit-...`). Emitting the block alone does not run the hook.
  - **Optional hook** (`optional: true`):
    ```
    ## Extension Hooks

    **Optional Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```

## Completion Report

Output path to generated tasks.md and summary:
- Total task count
- Task count per entity
- Parallel opportunities identified
- Independent test criteria for each entity
- Suggested MVP scope (typically just Entity 1, bronze through serving)
- Format validation: Confirm ALL tasks follow the checklist format (checkbox, ID, labels, file paths)

Context for task generation: $ARGUMENTS

The tasks.md should be immediately executable - each task must be specific enough that an LLM can complete it without additional context.

## Task Generation Rules

**CRITICAL**: Tasks MUST be organized by entity (bronze → silver → gold → serving) to enable independent implementation and testing of each entity's full pipeline slice.

**Contracts/tests are NOT optional**: this repo's constitution mandates dbt model contracts on every model — always generate the contract/`meta` task alongside the model task for that layer, and a delta-load simulator validation task per entity.

### Checklist Format (REQUIRED)

Every task MUST strictly follow this format:

```text
- [ ] [TaskID] [P?] [Entity?] Description with file path
```

**Format Components**:

1. **Checkbox**: ALWAYS start with `- [ ]` (markdown checkbox)
2. **Task ID**: Sequential number (T001, T002, T003...) in execution order
3. **[P] marker**: Include ONLY if task is parallelizable (different files, no dependencies on incomplete tasks)
4. **[Entity] label**: REQUIRED for entity phase tasks only
   - Format: [E1], [E2], [E3], etc. (maps to entities from spec.md)
   - Setup phase: NO entity label
   - Foundational phase: NO entity label
   - Entity phases: MUST have entity label
   - Polish phase: NO entity label
5. **Description**: Clear action with exact file path (following `<layer>_<source>__<entity>` naming)

**Examples**:

- ✅ CORRECT: `- [ ] T001 Add Meltano extractor config in meltano/extract/contoso/`
- ✅ CORRECT: `- [ ] T005 [P] Extend dedup_before_insert macro in dbt/macros/dedup_before_insert.sql`
- ✅ CORRECT: `- [ ] T012 [P] [E1] Create bronze_contoso__customers model in dbt/models/bronze/contoso/bronze_contoso__customers.sql`
- ✅ CORRECT: `- [ ] T014 [E1] Define contract + meta in bronze_contoso__customers.yml`
- ❌ WRONG: `- [ ] Create bronze model` (missing ID and Entity label)
- ❌ WRONG: `T001 [E1] Create model` (missing checkbox)
- ❌ WRONG: `- [ ] [E1] Create model` (missing Task ID)
- ❌ WRONG: `- [ ] T001 [E1] Create model` (missing file path)

### Task Organization

1. **From Entities (spec.md)** - PRIMARY ORGANIZATION:
   - Each entity (P1, P2, P3...) gets its own phase, subdivided bronze → silver → gold → serving
   - Map all related work to its entity:
     - Bronze model + contract/`meta` (business key, dedup columns, PII columns)
     - Silver model + contract/`meta` (business key, SCD1/SCD2 columns)
     - Gold model + contract (business logic, cross-entity joins where the spec calls for them)
     - Serving exposure (+ RLS if required)
     - Delta-load simulator validation task
   - Mark entity dependencies (most entities should be independently testable through gold; only deliberate cross-entity gold joins create a dependency)

2. **From the Data Model**:
   - Map each entity's business key/dedup/PII/SCD columns to the contract/`meta` task for the relevant layer
   - Shared macros needed by multiple entities → Foundational phase (Phase 2), not duplicated per entity

3. **From Setup/Infrastructure**:
   - Meltano/dbt project scaffolding → Setup phase (Phase 1)
   - Shared macros/contract conventions → Foundational phase (Phase 2)
   - Entity-specific setup → within that entity's phase

### Phase Structure

- **Phase 1**: Setup (Meltano/dbt project scaffolding)
- **Phase 2**: Foundational (blocking prerequisites - MUST complete before entity work)
- **Phase 3+**: Entities in priority order (P1, P2, P3...)
  - Within each entity: Bronze (model + contract) → Silver (model + contract) → Gold (model + contract) → Serving → delta-load simulator validation
  - Each phase should be a complete, independently testable increment through serving
- **Final Phase**: Polish & Cross-Cutting Concerns

## Done When

- [ ] tasks.md generated with all phases, task IDs, and file paths
- [ ] Extension hooks dispatched or skipped according to the rules in Mandatory Post-Execution Hooks above
- [ ] Completion reported to user with task count, entity breakdown, and MVP scope
