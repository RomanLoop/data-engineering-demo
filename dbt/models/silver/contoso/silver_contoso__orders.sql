{{
  config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='order_key',
    on_schema_change='append_new_columns',
    partition_by=['order_year'],
    incremental_predicates=[
      'DBT_INTERNAL_DEST.order_year = DBT_INTERNAL_SOURCE.order_year'
    ]
  )
}}

{#- First real SCD1 model (research.md Decision 2,
    specs/002-onboard-contoso-remaining-entities/) — overwrite-in-place via
    dbt-fabricspark's native `merge` strategy (confirmed supported for
    delta file_format). -#}

{% set _business_key = model.meta.business_key | default([]) %}
{% set _scd1_columns = model.meta.scd1_columns | default([]) %}

{#- order_year is a pure function of order_date (already in scd1_columns), so
    it is NOT added to the hash — it is appended to the MERGE update set only.

    PERF (partition pruning): the `incremental_predicates` in the config block
    above ANDs `DBT_INTERNAL_DEST.order_year = DBT_INTERNAL_SOURCE.order_year`
    into the MERGE ON clause — the standard Delta idiom that lets the engine
    prune target files to just the order_year partitions present in this
    run's source. It has to be a *static* predicate: dbt's runtime
    `config()` is a no-op (RuntimeConfigObject.__call__ returns ""), so a
    year list computed with run_query() cannot be injected, and Fabric's
    Delta MERGE rejects any subquery in the ON clause
    ([DELTA_UNSUPPORTED_SUBQUERY]). Both were tried (2026-09-10).

    CAVEAT: correct only while an update never changes a row's order_year.
    The delta simulator only ever mutates DeliveryDate / CurrencyCode, never
    OrderDate, so this holds here. A real order_date correction that crosses
    a year boundary would leave the old-year row unmatched and insert the
    new-year row → duplicate order_key, caught loudly by
    unique_silver_contoso__orders_order_key (not silent). Fix if it ever
    happens: `dbt run --full-refresh --select silver_contoso__orders`. -#}
{{ config(merge_update_columns=apply_scd1_merge_update_columns() + ['order_year']) }}

{#- silver_contoso__orders_cleansed is a straight passthrough of bronze's
    full append-only history, so a business key can appear more than once
    (every genuine update adds a new bronze row). A MERGE statement errors
    ("multiple source rows matched") if its source has more than one row
    per unique_key, so we collapse to the single latest snapshot per
    order_key — which also gives correct "latest wins" semantics on a first
    load, an incremental run, or a full rebuild alike.

    PERF (P2): on an incremental run, filter out rows whose (key + hash)
    already exist in the target BEFORE the window and BEFORE the MERGE
    source. On a no-new-data rerun `_new_or_changed` is empty → the
    row_number() window runs over 0 rows, `__dbt_tmp` is empty, and the
    Delta MERGE is a no-op scan instead of rewriting every file for 2.3M
    unchanged rows (measured: silver_contoso__orderrows 63s → single
    digits). On a real delta only new/changed keys flow through, so the
    MERGE only rewrites files holding actually-changed rows. Correctness is
    unchanged: unchanged rows are skipped so their `_updated_at` stays put;
    new/changed rows version exactly as before. -#}
with _cleansed as (

    select
        *,
        {{ generate_hash(_scd1_columns) }} as _scd1_hash
    from {{ ref('silver_contoso__orders_cleansed') }}

),

{% if is_incremental() %}
_new_or_changed as (

    select _cleansed.*
    from _cleansed
    left anti join {{ this }} as _dbt_scd1_target
        on _cleansed.order_key = _dbt_scd1_target.order_key
       and _cleansed._scd1_hash = _dbt_scd1_target._scd1_hash

),
{% else %}
_new_or_changed as ( select * from _cleansed ),
{% endif %}

_latest as (

    select
        *,
        row_number() over (
            partition by order_key order by _ingested_at desc
        ) as _row_num
    from _new_or_changed

),

_incoming as (

    select *
    from _latest
    where _row_num = 1

)

select
    _incoming.order_key,
    _incoming.customer_key,
    _incoming.store_key,
    _incoming.order_date,
    _incoming.delivery_date,
    _incoming.currency_code,
    _incoming._ingested_at,
    _incoming._scd1_hash,
    {{ current_run_timestamp() }} as _loaded_at,
    {{ apply_scd1_updated_at_expr(is_incremental()) }} as _updated_at,
    _incoming.order_year
from _incoming
{% if is_incremental() %}
{{ apply_scd1_existing_join(this, _business_key) }}
{% endif %}
