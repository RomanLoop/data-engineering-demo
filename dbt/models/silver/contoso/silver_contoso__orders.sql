{{
  config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='order_key',
    on_schema_change='append_new_columns'
  )
}}

{#- First real SCD1 model (research.md Decision 2,
    specs/002-onboard-contoso-remaining-entities/) — overwrite-in-place via
    dbt-fabricspark's native `merge` strategy (confirmed supported for
    delta file_format). -#}

{% set _business_key = model.meta.business_key | default([]) %}
{% set _scd1_columns = model.meta.scd1_columns | default([]) %}

{{ config(merge_update_columns=apply_scd1_merge_update_columns()) }}

{#- silver_contoso__orders_cleansed is a straight passthrough of bronze's
    full append-only history, so a business key can appear more than once
    (every genuine update adds a new bronze row). A MERGE statement errors
    ("multiple source rows matched") if its source has more than one row
    per unique_key, so _incoming must first collapse to the single latest
    snapshot per order_key — this also gives correct "latest wins"
    semantics on a first load, an incremental run, or a full rebuild alike,
    with no separate is_incremental()-gated filtering step needed (unlike
    apply_scd2's dedup_before_insert, which only needs to run on
    incremental runs). -#}
with _latest as (

    select
        *,
        row_number() over (
            partition by order_key order by _ingested_at desc
        ) as _row_num
    from {{ ref('silver_contoso__orders_cleansed') }}

),

_incoming as (

    select
        *,
        {{ generate_hash(_scd1_columns) }} as _scd1_hash
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
    {{ apply_scd1_updated_at_expr(is_incremental()) }} as _updated_at
from _incoming
{% if is_incremental() %}
{{ apply_scd1_existing_join(this, _business_key) }}
{% endif %}
