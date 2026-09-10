{% docs contoso_meta_convention %}

Every model in this repo carries a `meta` block with only the keys relevant to its own medallion layer (AGENT.md §6, constitution Principle V, decision #6 in AGENT.md §11):

| Layer | `meta` keys |
|---|---|
| bronze | `business_key`, `dedup_columns`, `pii_columns` |
| silver (cleansing) | `business_key` |
| silver (historization) | `business_key`, `scd1_columns`, `scd2_columns` |
| gold / serving | `business_key` |

`business_key` and `dedup_columns`/`scd1_columns`/`scd2_columns` are lists of column names, always naming columns in the same model's own casing (source PascalCase on bronze, snake_case from silver onward). Macros (`dedup_before_insert`, `mask_pii_columns`, `apply_scd1`, `apply_scd2`) read these lists via `model.meta.*` inside the model's own SQL — the column lists are declared exactly once, in the model's `.yml`, never duplicated in SQL.

**Change detection is hash-based**, not per-column comparison (revised 2026-09-07): `generate_hash(columns)` computes a `sha2(256)` over a column list; bronze stores it as `_dedup_hash` (over `business_key + dedup_columns`), silver historization stores it as `_scd_hash` (over `business_key + scd2_columns`). `dedup_before_insert()` then compares the single hash column instead of every tracked column individually.

**Technical column conventions**:

| Situation | Columns |
|---|---|
| Bronze (every model) | `_ingested_at`, `_dedup_hash` |
| Silver SCD2 (historization models) | `_scd_hash`, `_valid_from`, `_valid_to` (never null — sentinel `9999-12-31 23:59:59` while current, not NULL), `_is_current` |
| Silver SCD1 (not yet used by any entity) | `_loaded_at` (first-seen), `_updated_at` (last actual change — see `apply_scd1.sql`) |

{% enddocs %}
