{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns',
    partition_by=['order_year']
  )
}}

{#- PERF (partitioning, 2026-09-10): partitioned by order_year =
    year(OrderDate). partition_by only takes effect at CREATE, and a
    partition column cannot be added by ALTER, so switching an existing
    table over needs a one-time DROP TABLE + plain rebuild (this model is
    append-only, so --full-refresh is forbidden and would raise below).
    orderrows is deliberately NOT partitioned — it has no date column and
    a cross-entity join to get one would break the medallion boundary
    (AGENT.md §12 decision 12). -#}

{% if flags.FULL_REFRESH %}
    {{ exceptions.raise_compiler_error("bronze_contoso__orders is append-only — full-refresh is forbidden. Remove --full-refresh.") }}
{% endif %}

{% set _business_key = model.meta.business_key | default([]) %}
{% set _dedup_columns = model.meta.dedup_columns | default([]) %}

with _source as (

    select
        OrderKey,
        CustomerKey,
        StoreKey,
        OrderDate,
        DeliveryDate,
        CurrencyCode,
        current_timestamp() as _ingested_at,
        {{ generate_hash(_business_key + _dedup_columns) }} as _dedup_hash,
        -- Derived partition key. Kept last: Delta places the partition
        -- column last physically, so the contract column order must match.
        year(OrderDate) as order_year

    -- Stage-1 stopgap: bootstrap_landing_table stands in for Meltano.
    from {{ source('contoso_landing', 'landing_orders') }}

)

select *
from _source
{% if is_incremental() %}
where {{ dedup_before_insert() }}
{% endif %}
