# Data Model: Onboard Remaining Contoso Entities

Phase 1 output for `specs/002-onboard-contoso-remaining-entities/plan.md`. Defines each entity's contract shape per layer. All 24 models (6 entities × up to 4 models) are **new**. Source columns confirmed in research.md Decision 1; renamed to snake_case from silver onward, same convention as `001`.

## Materialization strategy

| Model | Materialization | Why |
|---|---|---|
| `bronze_contoso__<entity>` (×6) | `incremental` (append, via `dedup_before_insert`) | Append-only per constitution — identical to `001`, regardless of the entity's SCD kind |
| `silver_contoso__product_cleansed` / `..._store_cleansed` | `view` | Pure transformation, no state — identical to `001`'s pattern |
| `silver_contoso__product` / `..._store` | `incremental` (SCD2, hand-rolled pre_hook + window functions via `apply_scd2`) | History must persist and be updated across runs — identical mechanism to `silver_contoso__customers` |
| `silver_contoso__date` / `..._currencyexchange` | `view` | Static reference data, no state to persist, no SCD — new case (see research.md Decision 1) |
| `silver_contoso__orders_cleansed` / `..._orderrows_cleansed` | `view` | Pure transformation, no state |
| `silver_contoso__orders` / `..._orderrows` | `incremental` (`merge`, native dbt strategy via `apply_scd1`) | Overwrite-in-place by business key — first real SCD1 usage, see research.md Decision 2 |
| `gold_<entity>` (×6) | `table` (implementation detail, not contract-relevant) | Reads current-version (dimensions) / all (facts, reference) silver only |
| `serving_<entity>` (×6) | `view` | Thin pass-through over gold |

## Entity: product (SCD2 master data)

### bronze_contoso__product

| Contract field | Value |
|---|---|
| `meta.business_key` | `[ProductKey]` |
| `meta.dedup_columns` | `[ProductCode, ProductName, Manufacturer, Brand, Color, WeightUnit, Weight, Cost, Price, CategoryKey, CategoryName, SubCategoryKey, SubCategoryName]` — all non-key columns |
| `meta.pii_columns` | `[]` |
| Technical columns | `_ingested_at` |
| Tests | `not_null` on `ProductKey`; no `unique` (append-only, may hold history) |

### silver_contoso__product_cleansed

| Contract field | Value |
|---|---|
| `meta.business_key` | `[product_key]` |
| Type casts | `product_key`/`category_key`/`sub_category_key` → int; `weight`/`cost`/`price` → numeric/float; rest → string |
| Tests | `not_null` + `unique` on `product_key` |

### silver_contoso__product (SCD2)

| Contract field | Value |
|---|---|
| `meta.business_key` | `[product_key]` |
| `meta.scd2_columns` | `[product_code, product_name, manufacturer, brand, color, weight_unit, weight, cost, price, category_key, category_name, sub_category_key, sub_category_name]` — all 13 non-key columns |
| `meta.scd1_columns` | not declared (all-SCD2 entity, same convention as `customers`' explicit `[]` — see note below) |
| Tests | `not_null` + `unique` on `product_key` scoped to `_is_current = true` |

**Note on `scd1_columns`**: `customers` declares `scd1_columns: []` explicitly (SCD-managed, zero SCD1 columns by choice). `product`/`store` follow the same convention for consistency with an established, live-validated entity — this differs from `date`/`currencyexchange`, which omit *both* keys entirely because they aren't SCD-managed at all (see research.md Decision 1 and AGENT.md §6/§12).

### gold_product / serving_product

Same shape as `001`'s `gold_customers`/`serving_customers`: business-key passthrough of current-version silver rows, no cross-entity joins, no RLS.

## Entity: store (SCD2 master data)

### bronze_contoso__store

| Contract field | Value |
|---|---|
| `meta.business_key` | `[StoreKey]` |
| `meta.dedup_columns` | `[StoreCode, GeoAreaKey, CountryCode, CountryName, State, OpenDate, CloseDate, Description, SquareMeters, Status]` |
| `meta.pii_columns` | `[]` |
| Technical columns | `_ingested_at` |
| Tests | `not_null` on `StoreKey`; no `unique` |

### silver_contoso__store_cleansed

| Contract field | Value |
|---|---|
| `meta.business_key` | `[store_key]` |
| Type casts | `store_key`/`geo_area_key` → int; `open_date`/`close_date` (nullable) → date; `square_meters` → numeric; rest → string |
| Tests | `not_null` + `unique` on `store_key` |

### silver_contoso__store (SCD2)

| Contract field | Value |
|---|---|
| `meta.business_key` | `[store_key]` |
| `meta.scd2_columns` | `[store_code, geo_area_key, country_code, country_name, state, open_date, close_date, description, square_meters, status]` — all 10 non-key columns |
| `meta.scd1_columns` | `[]` (same convention as `product`/`customers`) |
| Tests | `not_null` + `unique` on `store_key` scoped to `_is_current = true` |

### gold_store / serving_store

Same shape as `gold_product`/`serving_product`.

## Entity: date (static reference, no SCD)

### bronze_contoso__date

| Contract field | Value |
|---|---|
| `meta.business_key` | `[DateKey]` |
| `meta.dedup_columns` | all 15 non-key columns |
| `meta.pii_columns` | `[]` |
| Technical columns | `_ingested_at` |
| Tests | `not_null` on `DateKey`; no `unique` |

### silver_contoso__date (view, no SCD)

| Contract field | Value |
|---|---|
| `meta.business_key` | `[date_key]` |
| `meta.scd1_columns` / `meta.scd2_columns` | **omitted entirely** — not SCD-managed (research.md Decision 1) |
| Type casts | `date` → date; `date_key`/`year`/`year_quarter_number`/`quarter`/`year_month_number`/`month_number`/`day_of_week_number`/`working_day`/`working_day_number` → int; rest → string |
| Tests | `not_null` + `unique` on `date_key` |

### gold_date / serving_date

Same passthrough shape; no cross-entity joins even though every fact/dimension conceptually relates to `date_key` — deferred per spec.md Assumptions.

## Entity: currencyexchange (static reference, no SCD)

### bronze_contoso__currencyexchange

| Contract field | Value |
|---|---|
| `meta.business_key` | `[Date, FromCurrency, ToCurrency]` (composite) |
| `meta.dedup_columns` | `[Exchange]` |
| `meta.pii_columns` | `[]` |
| Technical columns | `_ingested_at` |
| Tests | `not_null` on each of `Date`, `FromCurrency`, `ToCurrency`; no `unique` |

### silver_contoso__currencyexchange (view, no SCD)

| Contract field | Value |
|---|---|
| `meta.business_key` | `[date, from_currency, to_currency]` |
| `meta.scd1_columns` / `meta.scd2_columns` | **omitted entirely** |
| Type casts | `date` → date; `exchange` → numeric/float; rest → string |
| Tests | `not_null` on each key column; `dbt_utils.unique_combination_of_columns` (or equivalent) on `[date, from_currency, to_currency]` |

### gold_currencyexchange / serving_currencyexchange

Same passthrough shape; composite key passed through as three plain columns, no surrogate key.

## Entity: orders (SCD1 fact)

### bronze_contoso__orders

| Contract field | Value |
|---|---|
| `meta.business_key` | `[OrderKey]` |
| `meta.dedup_columns` | `[CustomerKey, StoreKey, OrderDate, DeliveryDate, CurrencyCode]` |
| `meta.pii_columns` | `[]` |
| Technical columns | `_ingested_at` |
| Tests | `not_null` on `OrderKey`; no `unique` |

### silver_contoso__orders_cleansed

| Contract field | Value |
|---|---|
| `meta.business_key` | `[order_key]` |
| Type casts | `order_key`/`customer_key`/`store_key` → int; `order_date`/`delivery_date` (nullable) → date; `currency_code` → string |
| Tests | `not_null` + `unique` on `order_key` |

### silver_contoso__orders (SCD1)

| Contract field | Value |
|---|---|
| `meta.business_key` | `[order_key]` |
| `meta.scd1_columns` | `[customer_key, store_key, order_date, delivery_date, currency_code]` — all 5 non-key columns |
| `meta.scd2_columns` | not declared (pure-SCD1 entity) |
| Technical columns | `_loaded_at`, `_updated_at`, `_scd1_hash` (research.md Decision 2) |
| Tests | `not_null` + `unique` on `order_key` (every row is "current" by construction — SCD1 has no historical rows to exclude) |

### gold_orders / serving_orders

Business-key passthrough (`order_key`, plus the FK-shaped `customer_key`/`store_key` columns, unresolved — no cross-entity join in this change).

## Entity: orderrows (SCD1 fact)

### bronze_contoso__orderrows

| Contract field | Value |
|---|---|
| `meta.business_key` | `[OrderKey, LineNumber]` (composite) |
| `meta.dedup_columns` | `[ProductKey, Quantity, UnitPrice, NetPrice, UnitCost]` |
| `meta.pii_columns` | `[]` |
| Technical columns | `_ingested_at` |
| Tests | `not_null` on `OrderKey` and `LineNumber`; no `unique` |

### silver_contoso__orderrows_cleansed

| Contract field | Value |
|---|---|
| `meta.business_key` | `[order_key, line_number]` |
| Type casts | `order_key`/`line_number`/`product_key`/`quantity` → int; `unit_price`/`net_price`/`unit_cost` → numeric/float |
| Tests | `not_null` on both key columns; `dbt_utils.unique_combination_of_columns` on `[order_key, line_number]` |

### silver_contoso__orderrows (SCD1)

| Contract field | Value |
|---|---|
| `meta.business_key` | `[order_key, line_number]` |
| `meta.scd1_columns` | `[product_key, quantity, unit_price, net_price, unit_cost]` — all 5 non-key columns |
| `meta.scd2_columns` | not declared |
| Technical columns | `_loaded_at`, `_updated_at`, `_scd1_hash` |
| Tests | `not_null` on both key columns; `dbt_utils.unique_combination_of_columns` on `[order_key, line_number]` |

**Composite `unique_key` for `merge`**: dbt-fabricspark's native `merge` incremental strategy accepts a list for `unique_key`, so `orderrows` is the first model in this project to actually exercise a composite `unique_key` merge (research.md Decision 2) — unlike `apply_scd2`'s hand-rolled expire step, which does *not* support composite keys yet (research.md Decision 6, not exercised by this entity since it's SCD1).

### gold_orderrows / serving_orderrows

Business-key passthrough (`order_key`, `line_number`, plus the FK-shaped `product_key`, unresolved).

## Relationships

None enforced (no cross-entity gold joins in this change, per spec.md Assumptions). Conceptually: `orders.customer_key` → `customers.customer_key` (`001`); `orders.store_key` → `store.store_key`; `orderrows.order_key` → `orders.order_key`; `orderrows.product_key` → `product.product_key`. All four are candidates for the "first cross-entity gold-level join" flagged as deferred in both `001`'s and this spec's data-model — a future change once a concrete consumer need (e.g. a `gold_sales` relational view resolving all four) justifies it.
