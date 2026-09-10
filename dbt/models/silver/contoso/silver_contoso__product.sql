{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns'
  )
}}

{#- model.meta.* resolves to Undefined during dbt's preliminary static-parse
    pass — `| default([])` guards it, see bronze_contoso__customers.sql. -#}
{% set _business_key = model.meta.business_key | default([]) %}
{% set _scd2_columns = model.meta.scd2_columns | default([]) %}
{% set _business_key_col = _business_key[0] if _business_key
    else '_business_key' %}

{#- SCD2 historization on top of the cleansed view. Product is master data
    (spec.md), so every non-key column is meta.scd2_columns; there is no
    meta.scd1_columns split for this entity. -#}

with _cleansed as (

    select
        *,
        {{ generate_hash(_business_key + _scd2_columns) }} as _scd_hash
    from {{ ref('silver_contoso__product_cleansed') }}

),

_unprocessed as (

    select _cleansed.*
    from _cleansed
    {% if is_incremental() %}
    where {{ dedup_before_insert(hash_column='_scd_hash', source_alias='_cleansed') }}
    {% endif %}

),

_versioned as (

    select
        *,
        _ingested_at as _valid_from,
        lead(_ingested_at, 1, timestamp '9999-12-31 23:59:59') over (
            partition by {{ _business_key_col }} order by _ingested_at
        ) as _valid_to,
        row_number() over (
            partition by {{ _business_key_col }} order by _ingested_at desc
        ) = 1 as _is_current
    from _unprocessed

)

select
    product_key,
    product_code,
    product_name,
    manufacturer,
    brand,
    color,
    weight_unit,
    weight,
    cost,
    price,
    category_key,
    category_name,
    sub_category_key,
    sub_category_name,
    _ingested_at,
    _scd_hash,
    _valid_from,
    _valid_to,
    _is_current
from _versioned

{#- post_hook, called UNCONDITIONALLY, purely self-referential, hardcoded
    literal arguments (not `this`/`model.meta`) — see dbt/macros/
    apply_scd2.sql's incident writeup ("Fix, part 2") for why. -#}
{{ config(post_hook=expire_scd2_current_rows(
    'silver', 'silver_contoso__product', 'product_key'
)) }}
