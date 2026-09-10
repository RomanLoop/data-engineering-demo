{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns'
  )
}}

{#- Bronze is append-only, dedup-before-insert (constitution Principle I/IV).
    full-refresh is forbidden — fail loudly rather than silently allow it,
    since a full-refresh would destroy append-only history. -#}
{% if flags.FULL_REFRESH %}
    {{ exceptions.raise_compiler_error("bronze_contoso__product is append-only — full-refresh is forbidden (AGENT.md §5 / constitution Principle I). Remove --full-refresh.") }}
{% endif %}

{#- model.meta.* resolves to Undefined during dbt's preliminary static-parse
    pass — `| default([])` keeps that pass from hard-failing on
    `Undefined + Undefined`; see bronze_contoso__customers.sql for the full
    writeup of this gotcha. -#}
{% set _business_key = model.meta.business_key | default([]) %}
{% set _dedup_columns = model.meta.dedup_columns | default([]) %}

with _source as (

    select
        ProductKey,
        ProductCode,
        ProductName,
        Manufacturer,
        Brand,
        Color,
        WeightUnit,
        Weight,
        Cost,
        Price,
        CategoryKey,
        CategoryName,
        SubCategoryKey,
        SubCategoryName,
        current_timestamp() as _ingested_at,
        {{ generate_hash(_business_key + _dedup_columns) }} as _dedup_hash

    -- Stage-1 stopgap: a native Spark bulk load (bootstrap_landing_table
    -- macro) stands in for the Meltano-populated landing zone (plan.md
    -- Complexity Tracking). Run `dbt run-operation bootstrap_landing_table
    -- --args '{entity: product, ...}'` before building this model.
    from {{ source('contoso_landing', 'landing_product') }}

)

select *
from _source
{% if is_incremental() %}
where {{ dedup_before_insert() }}
{% endif %}
