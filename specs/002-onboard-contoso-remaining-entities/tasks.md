# Tasks: Onboard Remaining Contoso Entities

**Input**: Design documents from `specs/002-onboard-contoso-remaining-entities/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md (all present)

**Tests**: dbt tests/contracts are mandatory (constitution) — every model task below has a paired contract/`meta` task.

**Organization**: Grouped by medallion layer within each entity (P1–P6, matching spec.md priorities E1–E6), after a Setup + Foundational phase shared by all six.

**Post-`/speckit-analyze` remediation applied** (2026-09-09): FR-007 amended to state the type-casting requirement explicitly (finding U1); each entity's final validation step split into a plain idempotency rerun + a separate delta-load run (finding T1, matching `001`'s T020/T021/T022 granularity); a callout added to Phase 2 for the view-contract `constraints:`-vs-`tests:` gotcha (finding C1).

**Live-validation status** (2026-09-10): **all 86 tasks complete and validated against the live Fabric lakehouse.** Every one of the six entities was built initial-load → idempotency-rerun → delta-load through serving; a full-project `dbt build` (customers + all 6) passes 79/79; `customers` (`001`) was re-validated with a fresh delta after the shared-macro change below; `sqlfluff lint` is clean; and additive schema evolution (T085) was proven end-to-end on `date` — a synthetic new source column flowed bronze→silver→gold→serving via `ALTER TABLE … ADD COLUMNS` (no full-refresh), then was reverted. Real bugs found and fixed live along the way: a Fabric-runtime `SELECT * REPLACE` gap in `bootstrap_landing_table`; two `UNION ALL` arity bugs in the new singular tests; and — the significant one — a **SCD2 pre_hook design flaw distinct from `001`'s T022 findings** (dbt's config-extraction pass re-executes the whole model template in a stub context, poisoning any `this`/`model.meta`/adapter-dependent value fed into a `config()` argument). Fixed by redesigning `expire_scd2_current_rows` as an unconditional, self-referential `MERGE INTO` post-hook with hardcoded literal args — see `dbt/macros/apply_scd2.sql`'s "Bug 3" writeup (parts 1–3) and research.md Decision 8. Recurring Fabric `TooManyRequestsForCapacity` contention was worked around by cancelling lingering Livy sessions via the REST API (user-authorised) and, once, a user capacity bump.

## Format: `[ID] [P?] [Entity?] Description`

## Phase 1: Setup

- [X] T001 [P] Download `product.csv`, `store.csv`, `date.csv`, `currencyexchange.csv`, `orders.csv`, `orderrows.csv` from the `csv-1m.7z` release asset (already fetched once for research — see research.md Decision 1) into `data/contoso/`, alongside the existing `customer.csv`

No `dbt_project.yml`/sqlfluff config changes needed — the existing per-layer folder config (`models.data_engineering_demo.bronze/silver/gold/serving`) already applies generically to any source under those paths (verified against `dbt/dbt_project.yml`).

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL**: No entity work can begin until this phase is complete.

- [X] T002 [P] Extend `dbt/macros/apply_scd1.sql` with a reusable helper macro providing the `LEFT JOIN`-against-target + hash-comparison SQL snippet that computes `_loaded_at`/`_updated_at`/`_scd1_hash` (research.md Decision 2) — reused by both SCD1 entities (`orders`, `orderrows`) in Phases 7–8; `apply_scd1_update_columns()` itself stays unchanged
- [X] T003 [P] Create `dbt/macros/bootstrap_landing_table.sql` — generalized, parameterized landing bootstrap (`entity`, `csv_path`, `columns` args) replacing the per-entity-macro approach for these six entities (research.md Decision 5); `bootstrap_landing_customer.sql` stays untouched
- [X] T004 [P] Generalize `dbt/tests/assert_silver_contoso_customers_no_overlapping_validity.sql` and `..._no_gaps_in_validity.sql` to loop over `[silver_contoso__customers, silver_contoso__product, silver_contoso__store]` instead of hardcoding `customers` only (research.md Decision 4) — rename to `assert_silver_scd2_no_overlapping_validity.sql`/`assert_silver_scd2_no_gaps_in_validity.sql` if that reads more clearly once written
- [X] T005 [P] Create `dbt/tests/assert_silver_contoso_orders_orderrows_no_duplicate_current.sql` — new SCD1 correctness singular test (research.md Decision 3)
- [X] T006 [P] Create `dbt/tests/assert_silver_contoso_composite_key_unique.sql` — new hand-written singular test looping over `[{model: silver_contoso__currencyexchange, keys: [date, from_currency, to_currency]}, {model: silver_contoso__orderrows, keys: [order_key, line_number]}]` (no new package dependency, consistent with the project's existing hand-written-singular-test style — research.md notes `dbt_utils.unique_combination_of_columns` as an alternative, not required)
- [X] T007 Extend `dbt/models/bronze/contoso/_contoso__sources.yml` with six new `source()` entries: `landing_product`, `landing_store`, `landing_date`, `landing_currencyexchange`, `landing_orders`, `landing_orderrows` (all in the `contoso_landing` source, `landing` schema, matching `landing_customer`'s existing pattern)

**Reminder (analyze finding C1)**: dbt ignores `constraints:` on `view`-materialized models — `001` hit this and fixed it by using `tests:` (`not_null`/`unique`) instead. Every `_cleansed` view and both no-SCD silver views (`silver_contoso__date`, `silver_contoso__currencyexchange`) in this spec are views — use `tests:`, not `constraints:`, on all of them.

**Checkpoint**: Foundation ready — entity onboarding can now begin in priority order.

---

## Phase 3: Entity 1 - product (Priority: P1) 🎯 MVP for this spec

**Goal**: First SCD2 dimension besides `customers` — proves the pattern generalizes.

**Independent test**: `dbt build --select +serving_product` after bootstrap; `serving_product` = 2,517 rows.

### Bronze — product

- [X] T008 [P] [E1] Create `dbt/models/bronze/contoso/bronze_contoso__product.sql` (append-only, `dedup_before_insert`, mirrors `bronze_contoso__customers.sql`)
- [X] T009 [E1] Define contract + `meta` (business_key `[ProductKey]`, dedup_columns, `pii_columns: []`) in `bronze_contoso__product.yml`

### Silver — product

- [X] T010 [P] [E1] Create `dbt/models/silver/contoso/silver_contoso__product_cleansed.sql` (view, type casts/snake_case rename)
- [X] T011 [E1] Define contract + `meta` (business_key `[product_key]`) in `silver_contoso__product_cleansed.yml`
- [X] T012 [E1] Create `dbt/models/silver/contoso/silver_contoso__product.sql` (incremental, SCD2 via `apply_scd2`/`expire_scd2_current_rows`, mirrors `silver_contoso__customers.sql` exactly)
- [X] T013 [E1] Define contract + `meta` (business_key, `scd2_columns` = all 13 non-key columns, `scd1_columns: []`) in `silver_contoso__product.yml`

### Gold — product

- [X] T014 [E1] Create `dbt/models/gold/gold_product.sql` (current-version passthrough, no cross-entity joins)
- [X] T015 [E1] Define contract in `gold_product.yml`

### Serving & validation — product

- [X] T016 [E1] Create `dbt/models/serving/serving_product.sql` + `serving_product.yml`
- [X] T017 [E1] Create `scripts/simulate_delta_load/contoso_product.py` (new + updated product records, mirrors `contoso_customers.py`)
- [X] T018 [E1] Run initial load end-to-end against live Fabric (quickstart Scenario 1) — validate 2,517 rows, zero duplicate keys, all contracts/tests pass
- [X] T019 [E1] Rerun the initial load with no new data (SC-002) — validate identical row counts in every layer
- [X] T020 [E1] Run delta-load simulator + rebuild (SC-003) — validate exactly N new + M correctly SCD2-versioned rows, no gap/no overlap (via T004's generalized tests)

**Checkpoint**: `product` fully functional bronze→serving, live-validated.

---

## Phase 4: Entity 2 - store (Priority: P2)

**Goal**: Second SCD2 dimension, tiny row count (74) — confirms the pattern at the opposite volume extreme from `product`.

**Independent test**: `dbt build --select +serving_store`; `serving_store` = 74 rows.

### Bronze — store

- [X] T021 [P] [E2] Create `dbt/models/bronze/contoso/bronze_contoso__store.sql`
- [X] T022 [E2] Define contract + `meta` (business_key `[StoreKey]`, dedup_columns, `pii_columns: []`) in `bronze_contoso__store.yml`

### Silver — store

- [X] T023 [P] [E2] Create `dbt/models/silver/contoso/silver_contoso__store_cleansed.sql` (note nullable `close_date`/`status`)
- [X] T024 [E2] Define contract + `meta` (business_key `[store_key]`) in `silver_contoso__store_cleansed.yml`
- [X] T025 [E2] Create `dbt/models/silver/contoso/silver_contoso__store.sql` (SCD2)
- [X] T026 [E2] Define contract + `meta` (business_key, `scd2_columns` = all 10 non-key columns, `scd1_columns: []`) in `silver_contoso__store.yml`

### Gold — store

- [X] T027 [E2] Create `dbt/models/gold/gold_store.sql`
- [X] T028 [E2] Define contract in `gold_store.yml`

### Serving & validation — store

- [X] T029 [E2] Create `dbt/models/serving/serving_store.sql` + `serving_store.yml`
- [X] T030 [E2] Create `scripts/simulate_delta_load/contoso_store.py`
- [X] T031 [E2] Run initial load end-to-end — validate 74 rows, zero duplicate keys, all contracts/tests pass
- [X] T032 [E2] Rerun the initial load with no new data (SC-002) — validate identical row counts in every layer
- [X] T033 [E2] Run delta-load simulator + rebuild (SC-003) — validate SCD2 versioning correctness

**Checkpoint**: `product` and `store` both fully functional; T004's generalized SCD2 tests now genuinely exercise all three SCD2 models.

---

## Phase 5: Entity 3 - date (Priority: P3)

**Goal**: First static-reference entity — establishes the "no SCD at all" branch of the SCD assignment policy.

**Independent test**: `dbt build --select +serving_date`; `serving_date` = 4,018 rows.

### Bronze — date

- [X] T034 [P] [E3] Create `dbt/models/bronze/contoso/bronze_contoso__date.sql`
- [X] T035 [E3] Define contract + `meta` (business_key `[DateKey]`, dedup_columns, `pii_columns: []`) in `bronze_contoso__date.yml`

### Silver — date (single model, no `_cleansed` split, no SCD)

- [X] T036 [E3] Create `dbt/models/silver/contoso/silver_contoso__date.sql` (view, type casts/rename only — no `apply_scd1`/`apply_scd2` call; per FR-007, casting is this model's own job since there's no separate `_cleansed` model)
- [X] T037 [E3] Define contract + `meta` (business_key `[date_key]` only — `scd1_columns`/`scd2_columns` omitted entirely, not `[]`) in `silver_contoso__date.yml`

### Gold — date

- [X] T038 [E3] Create `dbt/models/gold/gold_date.sql`
- [X] T039 [E3] Define contract in `gold_date.yml`

### Serving & validation — date

- [X] T040 [E3] Create `dbt/models/serving/serving_date.sql` + `serving_date.yml`
- [X] T041 [E3] Create `scripts/simulate_delta_load/contoso_date.py` (e.g. appends future calendar months as "new")
- [X] T042 [E3] Run initial load end-to-end — validate 4,018 rows, zero duplicate keys, all contracts/tests pass
- [X] T043 [E3] Rerun the initial load with no new data (SC-002) — validate identical row counts in every layer
- [X] T044 [E3] Run delta-load simulator + rebuild (SC-005) — validate exactly N new rows in every layer, zero versioning side effects (no `_valid_from`/`_loaded_at` columns exist on this model at all)

**Checkpoint**: `date` proves the "no SCD" branch works end-to-end.

---

## Phase 6: Entity 4 - currencyexchange (Priority: P4)

**Goal**: Second static-reference entity, and the first entity with a composite business key.

**Independent test**: `dbt build --select +serving_currencyexchange`; `serving_currencyexchange` = 100,450 rows.

### Bronze — currencyexchange

- [X] T045 [P] [E4] Create `dbt/models/bronze/contoso/bronze_contoso__currencyexchange.sql` (composite business key handled entirely via `generate_hash`/`dedup_before_insert`, both already composite-key-safe — see research.md Decision 1's dedup_before_insert note)
- [X] T046 [E4] Define contract + `meta` (business_key `[Date, FromCurrency, ToCurrency]`, dedup_columns `[Exchange]`, `pii_columns: []`) in `bronze_contoso__currencyexchange.yml`

### Silver — currencyexchange (single model, no SCD)

- [X] T047 [E4] Create `dbt/models/silver/contoso/silver_contoso__currencyexchange.sql` (view, type casts/rename only, per FR-007)
- [X] T048 [E4] Define contract + `meta` (business_key `[date, from_currency, to_currency]` only) in `silver_contoso__currencyexchange.yml`, referencing T006's composite-key uniqueness test

### Gold — currencyexchange

- [X] T049 [E4] Create `dbt/models/gold/gold_currencyexchange.sql`
- [X] T050 [E4] Define contract in `gold_currencyexchange.yml`

### Serving & validation — currencyexchange

- [X] T051 [E4] Create `dbt/models/serving/serving_currencyexchange.sql` + `serving_currencyexchange.yml`
- [X] T052 [E4] Create `scripts/simulate_delta_load/contoso_currencyexchange.py`
- [X] T053 [E4] Run initial load end-to-end — validate 100,450 rows, zero duplicate composite keys, all contracts/tests pass (including T006)
- [X] T054 [E4] Rerun the initial load with no new data (SC-002) — validate identical row counts in every layer
- [X] T055 [E4] Run delta-load simulator + rebuild (SC-005) — validate idempotency with composite keys

**Checkpoint**: composite business keys proven end-to-end before the (larger, higher-stakes) fact entities.

---

## Phase 7: Entity 5 - orders (Priority: P5)

**Goal**: First fact entity, first real (non-stub) use of `apply_scd1`/T002's merge helper.

**Independent test**: `dbt build --select +serving_orders`; `serving_orders` = 980,666 rows.

### Bronze — orders

- [X] T056 [P] [E5] Create `dbt/models/bronze/contoso/bronze_contoso__orders.sql`
- [X] T057 [E5] Define contract + `meta` (business_key `[OrderKey]`, dedup_columns, `pii_columns: []`) in `bronze_contoso__orders.yml`

### Silver — orders

- [X] T058 [P] [E5] Create `dbt/models/silver/contoso/silver_contoso__orders_cleansed.sql`
- [X] T059 [E5] Define contract + `meta` (business_key `[order_key]`) in `silver_contoso__orders_cleansed.yml`
- [X] T060 [E5] Create `dbt/models/silver/contoso/silver_contoso__orders.sql` — **first real SCD1 model**: `incremental_strategy='merge'`, `unique_key: order_key`, `merge_update_columns` from `apply_scd1_update_columns()` + technical columns, using T002's helper macro for `_loaded_at`/`_updated_at`/`_scd1_hash` (research.md Decision 2)
- [X] T061 [E5] Define contract + `meta` (business_key, `scd1_columns` = all 5 non-key columns, `scd2_columns` omitted) in `silver_contoso__orders.yml`

### Gold — orders

- [X] T062 [E5] Create `dbt/models/gold/gold_orders.sql` (passthrough, FK-shaped `customer_key`/`store_key` unresolved, no join)
- [X] T063 [E5] Define contract in `gold_orders.yml`

### Serving & validation — orders

- [X] T064 [E5] Create `dbt/models/serving/serving_orders.sql` + `serving_orders.yml`
- [X] T065 [E5] Create `scripts/simulate_delta_load/contoso_orders.py`
- [X] T066 [E5] Run initial load end-to-end against live Fabric — validate 980,666 rows, zero duplicate keys, all contracts/tests pass; note build time (first entity past ~1M rows)
- [X] T067 [E5] Rerun the initial load with no new data (SC-002) — validate identical row counts AND that `_updated_at` is unchanged on every row (proves the merge is idempotent by value, not just by row count)
- [X] T068 [E5] Run delta-load simulator + rebuild (SC-004) — validate N+M new bronze rows but only N new silver rows, M rows overwritten in place with `_updated_at` bumped only where a tracked column actually changed (T005's test + a manual spot-check)

**Checkpoint**: SCD1 proven correct end-to-end on a real, live entity for the first time.

---

## Phase 8: Entity 6 - orderrows (Priority: P6)

**Goal**: Second fact entity, largest table in the project (2,349,091 rows), first composite-key SCD1 merge.

**Independent test**: `dbt build --select +serving_orderrows`; `serving_orderrows` = 2,349,091 rows.

### Bronze — orderrows

- [X] T069 [P] [E6] Create `dbt/models/bronze/contoso/bronze_contoso__orderrows.sql` (composite business key)
- [X] T070 [E6] Define contract + `meta` (business_key `[OrderKey, LineNumber]`, dedup_columns, `pii_columns: []`) in `bronze_contoso__orderrows.yml`

### Silver — orderrows

- [X] T071 [P] [E6] Create `dbt/models/silver/contoso/silver_contoso__orderrows_cleansed.sql`
- [X] T072 [E6] Define contract + `meta` (business_key `[order_key, line_number]`) in `silver_contoso__orderrows_cleansed.yml`, referencing T006's composite-key uniqueness test
- [X] T073 [E6] Create `dbt/models/silver/contoso/silver_contoso__orderrows.sql` — SCD1 with **composite** `unique_key: [order_key, line_number]` (first composite-key merge in the project — confirmed supported by dbt-fabricspark, research.md Decision 2/data-model.md note)
- [X] T074 [E6] Define contract + `meta` (business_key, `scd1_columns` = all 5 non-key columns, `scd2_columns` omitted) in `silver_contoso__orderrows.yml`

### Gold — orderrows

- [X] T075 [E6] Create `dbt/models/gold/gold_orderrows.sql` (passthrough, FK-shaped `product_key` unresolved, no join)
- [X] T076 [E6] Define contract in `gold_orderrows.yml`

### Serving & validation — orderrows

- [X] T077 [E6] Create `dbt/models/serving/serving_orderrows.sql` + `serving_orderrows.yml`
- [X] T078 [E6] Create `scripts/simulate_delta_load/contoso_orderrows.py`
- [X] T079 [E6] Run initial load end-to-end against live Fabric — validate 2,349,091 rows, zero duplicate composite keys, all contracts/tests pass; note build time (largest build in the project so far — first real check past ~2.3M rows for the bronze dedup-hash approach and the composite-key merge)
- [X] T080 [E6] Rerun the initial load with no new data (SC-002) — validate identical row counts AND unchanged `_updated_at` values
- [X] T081 [E6] Run delta-load simulator + rebuild (SC-004) — validate N+M new bronze rows, N new silver rows, M overwritten in place, composite key handled correctly throughout

**Checkpoint**: all six entities live-validated end-to-end; every branch of the SCD assignment policy (SCD2/SCD1/none) and both key shapes (single/composite) proven for real.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [X] T082 [P] Update AGENT.md/model doc blocks with anything discovered only during real implementation (living-doc convention, same as `001`)
- [X] T083 Run a full `dbt build` with no `--select` (all 7 entities: `customers` + these 6) — regression check that nothing in `001` broke (quickstart Scenario 6)
- [X] T084 Confirm no secrets were introduced (`git add -A --dry-run` + grep pass, same check as `001` T026)
- [X] T085 Validate additive schema evolution end-to-end on at least one of these six entities (add a synthetic new source column, re-bootstrap, rebuild, confirm `on_schema_change: append_new_columns` behavior without breaking that entity's serving view) — closes out the same open item `001`'s T027 left unfinished, this time proven for real
- [X] T086 [P] `sqlfluff lint` pass over every new model/macro/test file introduced by this spec

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup — BLOCKS all entity work (T002/T003 in particular block Phase 7/8; T004/T005/T006 block validation tasks in Phases 3/4/7/8/6)
- **Entities (Phases 3–8)**: all depend on Foundational; independently testable through gold/serving per entity; recommended order follows P1→P6 (also a sane FK-dependency-free rollout order — see spec.md's per-entity "Why this priority")
- **Polish (Phase 9)**: depends on all six entities being complete

### Entity Dependencies

No entity in this spec has a hard build dependency on another (no cross-entity gold joins in this change, per spec.md Assumptions) — `orders`/`orderrows` conceptually reference `store`/`product`/`customers` business keys but do not join to them, so P5/P6 do not technically block on P1/P2 completing first. The priority order is a recommended rollout sequence, not an enforced gate.

### Parallel Opportunities

- T002–T007 (Foundational) can all run in parallel — different files
- Once Foundational completes, all six entities' bronze models (T008, T021, T034, T045, T056, T069) can be built in parallel
- Within one entity, bronze → silver → gold → serving stays strictly sequential

---

## Implementation Strategy

### MVP First (product only, Phase 3)

1. Complete Phase 1 (Setup) + Phase 2 (Foundational)
2. Complete Phase 3 (`product`) — first non-`customers` SCD2 entity, proves the pattern generalizes
3. **STOP and VALIDATE** against live Fabric before continuing

### Incremental delivery

Phase 3 (`product`) → Phase 4 (`store`, second SCD2) → Phase 5 (`date`, first no-SCD) → Phase 6 (`currencyexchange`, first composite key) → Phase 7 (`orders`, first SCD1) → Phase 8 (`orderrows`, composite-key SCD1, largest volume) → Phase 9 (Polish). Each phase's checkpoint is a full live-validated increment; earlier entities are never revisited by later phases (no cross-entity joins to retrofit).

---

## Notes

- Every model/contract task pair MUST be validated against the **live Fabric workspace** before being marked done, same standard as `001` — no task in Phases 3–8 is complete on a local `dbt compile` alone.
- Commit after each entity phase (or more granularly), not only at the very end.
- `apply_scd2`'s single-business-key-column limitation (research.md Decision 6) is NOT exercised by `product`/`store` (both single-key) — no task here needs to fix it; it remains tracked for a future composite-key SCD2 entity.
