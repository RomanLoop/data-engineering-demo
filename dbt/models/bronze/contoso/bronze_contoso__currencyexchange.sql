{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns'
  )
}}

{% if flags.FULL_REFRESH %}
    {{ exceptions.raise_compiler_error("bronze_contoso__currencyexchange is append-only — full-refresh is forbidden. Remove --full-refresh.") }}
{% endif %}

{#- Composite business key ([Date, FromCurrency, ToCurrency]) — handled
    entirely via generate_hash/dedup_before_insert, both already
    composite-key-safe (they just hash/compare a column list, no
    single-column assumption unlike apply_scd2's expire step — research.md
    Decision 6). -#}
{% set _business_key = model.meta.business_key | default([]) %}
{% set _dedup_columns = model.meta.dedup_columns | default([]) %}

with _source as (

    select
        `Date`,
        FromCurrency,
        ToCurrency,
        Exchange,
        current_timestamp() as _ingested_at,
        {{ generate_hash(_business_key + _dedup_columns) }} as _dedup_hash

    -- Stage-1 stopgap: bootstrap_landing_table stands in for Meltano.
    from {{ source('contoso_landing', 'landing_currencyexchange') }}

)

select *
from _source
{% if is_incremental() %}
where {{ dedup_before_insert() }}
{% endif %}
