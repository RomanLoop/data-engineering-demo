{{
  config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key=['order_key', 'line_number'],
    on_schema_change='append_new_columns'
  )
}}

{#- SCD1, composite unique_key — first composite-key merge in the project
    (confirmed supported by dbt-fabricspark's merge strategy; see
    silver_contoso__orders.sql for the non-composite version of this same
    pattern and its detailed comments). -#}

{% set _business_key = model.meta.business_key | default([]) %}
{% set _scd1_columns = model.meta.scd1_columns | default([]) %}

{{ config(merge_update_columns=apply_scd1_merge_update_columns()) }}

with _latest as (

    select
        *,
        row_number() over (
            partition by order_key, line_number order by _ingested_at desc
        ) as _row_num
    from {{ ref('silver_contoso__orderrows_cleansed') }}

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
    _incoming.line_number,
    _incoming.product_key,
    _incoming.quantity,
    _incoming.unit_price,
    _incoming.net_price,
    _incoming.unit_cost,
    _incoming._ingested_at,
    _incoming._scd1_hash,
    {{ current_run_timestamp() }} as _loaded_at,
    {{ apply_scd1_updated_at_expr(is_incremental()) }} as _updated_at
from _incoming
{% if is_incremental() %}
{{ apply_scd1_existing_join(this, _business_key) }}
{% endif %}
