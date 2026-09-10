---

description: "Task list for onboarding the Contoso customers entity"
---

# Tasks: Onboard Contoso Customers

**Input**: Design documents from `specs/001-onboard-contoso-customers/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md)

**Tests**: dbt tests/contracts are NOT optional in this repo (constitution — model contracts are mandatory). Every model task below is paired with its contract/`meta` task.

**Organization**: Single entity (`customers`, P1) — no Entity 2 in this change. Silver is split into two models (cleansing view + SCD2 historization) per the `/speckit-analyze` remediation (2026-09-07). Landing uses a **temporary native Spark bulk load from OneLake** instead of Meltano (originally planned as a dbt seed — see the "changed mechanism" note below) — see plan.md Complexity Tracking; Meltano/Fabric ingestion is deferred, tracked in spec.md Assumptions, not tasked here.

**Status (2026-09-09)**: 26/27 tasks complete. T020–T022 and T025 all validated for real against the live Fabric lakehouse (`lh_contoso`, recreated schema-enabled 2026-09-09 — see AGENT.md §7 and plan.md Complexity Tracking), CLI/user auth. Landing mechanism changed from the planned dbt seed (measured 30+ min for 105K rows, then a dead Livy session) to a native Spark bulk load via OneLake — see `dbt/macros/bootstrap_landing_customer.sql` and `scripts/upload_to_onelake.py`. Two real SCD2 bugs found and fixed during T022 (see apply_scd2.sql). Only T023 (PII masking sanity check) and T027 (schema-evolution end-to-end) remain.

## Format: `[ID] [P?] [Entity?] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[E1]**: Tagged on all customers-entity tasks; omitted on Setup/Foundational/Polish tasks
- Column lists are not repeated in every task — see [data-model.md](data-model.md) for the exact `meta` field values

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Repo/pipeline scaffolding needed before any entity work

- [X] T001 Add `data/contoso/customer.csv` (downloaded from `csv-1m.7z`, see research.md Decision 1) as the Stage-1 landing stand-in. **Changed mechanism** (2026-09-09): originally a dbt seed, replaced with a native Spark bulk load (`scripts/upload_to_onelake.py` + `dbt run-operation bootstrap_landing_customer`) after `dbt seed` measured 30+ minutes for 105K rows and then killed its own Livy session — see plan.md Complexity Tracking. **Temporary regardless of mechanism** — Meltano `tap-csv` is deferred until a Fabric-compatible target exists
- [X] T002 [P] Configure dbt project settings in `dbt_project.yml`: default `on_schema_change: append_new_columns`, per-layer materializations **and per-layer schemas** (`+schema: bronze`/`silver`/`gold`/`serving`, via `dbt/macros/generate_schema_name.sql`) — requires a schema-enabled Fabric Lakehouse (`lh_contoso` recreated with `creationPayload.enableSchemas: true` on 2026-09-09, after first discovering the default/non-schema-enabled lakehouse silently ignores `+schema:` — AGENT.md §7)
- [X] T003 [P] Configure `sqlfluff` linting (`.sqlfluff`, sparksql dialect via dbt templater) — verified locally: `sqlfluff lint dbt/models/` is clean

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared macros that MUST exist before the customers entity can be built — this is the *first* entity, so all four macros are created here, not merely extended

**⚠️ CRITICAL**: No entity work can begin until this phase is complete

- [X] T004 [P] Create `dedup_before_insert` macro in `dbt/macros/dedup_before_insert.sql` — inserts into an incremental (bronze) model only when the business key + configured dedup columns don't already exist, per `meta.business_key`/`meta.dedup_columns`. Also reused by T013 (see note there)
- [X] T005 [P] Create `mask_pii_columns` macro in `dbt/macros/mask_pii_columns.sql` — masks columns listed in `meta.pii_columns` when the active target is non-prod (no-op on `prod`, per constitution/AGENT.md §8)
- [X] T006 [P] Create `apply_scd1` macro in `dbt/macros/apply_scd1.sql` — returns `meta.scd1_columns` for a future entity's `merge_update_columns` config (not used by customers — see data-model.md)
- [X] T007 [P] Create `apply_scd2` macro in `dbt/macros/apply_scd2.sql` — `expire_scd2_current_rows` pre-hook that closes out superseded current rows; the new-current-row logic itself lives in the model (T013), reusing `dedup_before_insert`
- [X] T008 Document the shared `meta` contract convention (business_key, dedup_columns, pii_columns, scd1_columns, scd2_columns) referenced by every model below, e.g. as a dbt docs block in `dbt/models/bronze/contoso/_contoso__docs.md`

**Checkpoint**: Foundation ready — customers entity work can now begin

---

## Phase 3: Entity 1 - customers (Priority: P1) 🎯 MVP

**Goal**: Land, dedup, cleanse, historize, and expose the Contoso `customers` entity end-to-end, establishing the reference pattern for every later entity/source.

**Independent test**: `dbt build --select +serving_customers` succeeds with contracts/tests passing, and `quickstart.md` Scenarios 1–4 all produce their expected outcomes.

### Bronze — Entity 1

- [X] T009 [E1] Create `bronze_contoso__customers` model in `dbt/models/bronze/contoso/bronze_contoso__customers.sql` — incremental, append-only, sources from the `customer` seed (Stage-1 stopgap), calls `dedup_before_insert`, adds `_ingested_at`, `full-refresh` disabled (guarded via `flags.FULL_REFRESH` — compiler error, not just a config hint)
- [X] T010 [E1] Define contract + `meta` in `dbt/models/bronze/contoso/bronze_contoso__customers.yml` per data-model.md (`business_key: [CustomerKey]`, `dedup_columns`: all other source columns, `pii_columns` as listed); `not_null` test on `CustomerKey`

### Silver (cleansing) — Entity 1

- [X] T011 [E1] Create `silver_contoso__customers_cleansed` model in `dbt/models/silver/contoso/silver_contoso__customers_cleansed.sql` — **view** (not ephemeral — contracts can't be enforced on ephemeral models), snake_case rename, type casts (dates, `age` as integer, `latitude`/`longitude` as numeric), no joins to other models
- [X] T012 [E1] Define contract + `meta` in `dbt/models/silver/contoso/silver_contoso__customers_cleansed.yml` (`business_key: [customer_key]`); `not_null` on `customer_key` (as a `tests:` entry, not a `constraints:` block — views don't support DDL-level constraints, found via local `dbt parse`)

### Silver (historization) — Entity 1

- [X] T013 [E1] Create `silver_contoso__customers` model in `dbt/models/silver/contoso/silver_contoso__customers.sql` — incremental, reads from `silver_contoso__customers_cleansed`, `expire_scd2_current_rows` pre-hook + window-function-based new-current-row selection on **all** non-key columns (customers is master data — no SCD1 split, per data-model.md). **Design correction during implementation**: reuses `dedup_before_insert` against the *full* target table (not a simpler "diff vs. current row" check) — the cleansing view passes through bronze's entire append-only history every run, so a current-row-only diff would re-insert already-historized old snapshots as new; see the comment in `apply_scd2.sql`
- [X] T014 [E1] Define contract + `meta` in `dbt/models/silver/contoso/silver_contoso__customers.yml` (`business_key: [customer_key]`, `scd1_columns: []`, `scd2_columns`: all 23 non-key columns per data-model.md); `not_null` + `unique` (scoped `where: _is_current = true`) on `customer_key`

### Gold — Entity 1

- [X] T015 [E1] Create `gold_customers` model in `dbt/models/gold/gold_customers.sql` — current-version (`_is_current = true`) rows from `silver_contoso__customers`, business-key passthrough (no surrogate key), no cross-entity joins yet
- [X] T016 [E1] Define contract in `dbt/models/gold/gold_customers.yml`; `not_null` + `unique` on `customer_key`

### Serving & validation — Entity 1

- [X] T017 [E1] Create `serving_customers` view in `dbt/models/serving/serving_customers.sql` (plain view over `gold_customers`, no RLS — see spec.md Assumptions)
- [X] T018 [E1] Define contract/description in `dbt/models/serving/serving_customers.yml` (constraints→tests fix, same reason as T012)
- [X] T019 [E1] Build the delta-load simulator in `scripts/simulate_delta_load/contoso_customers.py`: generates N new + M updated customer records by sampling/perturbing `customer.csv` and rewriting the seed file (research.md Decision 4 — no vendor change-feed exists to replay). **Verified locally**: ran against a scratch copy of the seed (`--new 5 --updated 3 --seed 42`) — correct row count, unique keys, header intact
- [X] T020 [E1] Run initial load end-to-end and validate against quickstart.md Scenario 1 (spec SC-001). **Done for real** (2026-09-09) against the live Fabric workspace/lakehouse, CLI (user) auth: 104,990 rows landed and flowed through bronze → silver_cleansed → silver_historized (104,990 current) → gold → serving with zero loss/duplication; all 8 dbt tests (contracts, uniqueness, the two new SCD2 gap/overlap tests) passed. **Mechanism changed from the original plan**: `dbt seed` measured 46+ minutes then died (Livy session killed) for 104,990 rows — replaced with a native Spark bulk load (`dbt run-operation bootstrap_landing_customer`, reading a CSV uploaded to OneLake Files via `scripts/upload_to_onelake.py`) — 35s of actual data movement. `bronze_contoso__customers` now sources from `source('contoso_landing', 'landing_customer')`, not a dbt seed. See plan.md Complexity Tracking and data-model.md for the updated design.
- [X] T021 [E1] Rerun the initial load a second time and validate idempotency per quickstart.md Scenario 2 (spec SC-002, NFR-001). **Done for real** (2026-09-09): rerun `dbt build --select +serving_customers` against unchanged landing data — identical 104,990 rows in every layer, bronze distinct keys == total rows (zero duplicates introduced), all 13 checks (5 models + 8 tests) passed again.
- [X] T022 [E1] Run the delta-load simulator + pipeline and validate per quickstart.md Scenario 3 (spec SC-003, NFR-003). **Done for real** (2026-09-09, `--new 500 --updated 200 --seed 99`): bronze gained exactly 700 new rows (500 new keys + 200 changed-hash snapshots for updated keys), silver correctly historized exactly 200 prior versions (`_is_current=false`, closed-out `_valid_to`) and created 700 new current-eligible rows, netting 105,490 current rows (104,990 + 500). **Two real bugs found and fixed along the way** — see plan.md Complexity Tracking / apply_scd2.sql: (1) `is_incremental()` was called before `config(materialized=...)` had rendered, so the pre-hook silently never ran; (2) the original "at most one pending version per key per run" assumption broke on top of accumulated bronze history — replaced with a window-function (LEAD/ROW_NUMBER) design that handles any number of pending versions per key correctly.
- [ ] T023 [E1] **BLOCKED — same as T020.** Run the `mask_pii_columns` sanity check per quickstart.md Scenario 4 — compiles and is a documented no-op on `prod` (spec NFR-002)

**Checkpoint**: customers entity is fully functional bronze→serving and independently testable; all of spec.md's Success Criteria (SC-001..SC-005) are demonstrated

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Repo-wide hygiene after the first entity lands — no other entities exist yet, so this is scoped to what customers touched

- [X] T024 [P] Update model descriptions/docs so `dbt docs generate` renders cleanly for all five customers models — descriptions written on every model/column; `dbt parse` confirms the `{{ doc(...) }}` reference resolves. Full `dbt docs generate` (catalog.json) needs a live connection — not run
- [X] T025 [E1] Re-run full `dbt build` + `dbt test` across bronze/silver(×2)/gold/serving for contoso customers with zero failures. **Done for real, twice**: once against the original (non-schema-enabled) `lh_contoso`, and again after recreating `lh_contoso` schema-enabled (2026-09-09, `creationPayload.enableSchemas: true` — needed for AGENT.md §7's per-layer schema design to actually take effect; models now resolve to real `bronze`/`silver`/`gold`/`serving` schemas, not just name-prefixed tables in one schema). 13/13 (5 models + 8 tests) PASS both times.
- [X] T026 Confirm no secrets were introduced — grep `dbt_project.yml`/`profiles.yml` and the repo for the real Fabric tenant/workspace GUIDs found only `.env` (confirmed untracked by `git status`); `profiles.yml` uses `env_var()` exclusively, no literal secrets. **Re-checked 2026-09-09** after the lakehouse recreation: found and fixed one real workspace/lakehouse ID that had leaked into `scripts/upload_to_onelake.py`'s docstring example (replaced with placeholders / the env-var-defaulting invocation).
- [ ] T027 [E1] **BLOCKED — same as T020.** Validate schema-evolution behavior end-to-end: add a synthetic new column to the local `customer.csv`/seed, rerun the pipeline, and confirm it's appended (`on_schema_change: append_new_columns`) without breaking `serving_customers` (spec FR-008)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion — BLOCKS all entity work
- **Entity 1 (Phase 3)**: Depends on Foundational phase completion; bronze → silver-cleansed → silver-historized → gold → serving is strictly sequential (medallion boundaries are not parallelizable)
- **Polish (Phase 4)**: Depends on Entity 1 completion

### Parallel Opportunities

- T002 and T003 (Setup) can run in parallel with each other, after T001
- T004–T007 (all four macros) can run in parallel with each other
- T024 (docs) can run in parallel with T025–T027
- No parallelism within Entity 1's bronze→silver-cleansed→silver-historized→gold→serving chain (T009–T018) — each model selects from the previous one, so it is strictly sequential, matching Phase Dependencies above

---

## Implementation Strategy

### MVP First (and only, for this change)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (macros) — CRITICAL, blocks everything else
3. Complete Phase 3: customers, bronze → serving
4. **STOP and VALIDATE**: run all four quickstart.md scenarios
5. Complete Phase 4: Polish
6. Ship — this becomes the reference pattern for the next entity's spec (and for unblocking Meltano→Fabric ingestion, tracked separately)

---

## Notes

- [P] tasks touch different files with no dependencies on incomplete tasks
- [E1] labels every customers-entity task for traceability back to spec.md
- Verify idempotency (T021) and delta-load correctness (T022) before considering this entity done — these are the two hardest-to-retrofit properties per the constitution
- Commit after each task or logical group
- Avoid: vague tasks, same-file conflicts, skipping the contract/`meta` task for any model
- The dbt-seed landing stand-in (T001) is a tracked, temporary exception (plan.md Complexity Tracking) — do not let it quietly become permanent; the removal condition is documented there
