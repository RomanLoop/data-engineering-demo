{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns'
  )
}}

{% if flags.FULL_REFRESH %}
    {{ exceptions.raise_compiler_error("bronze_contoso__store is append-only — full-refresh is forbidden (AGENT.md §5 / constitution Principle I). Remove --full-refresh.") }}
{% endif %}

{% set _business_key = model.meta.business_key | default([]) %}
{% set _dedup_columns = model.meta.dedup_columns | default([]) %}

with _source as (

    select
        StoreKey,
        StoreCode,
        GeoAreaKey,
        CountryCode,
        CountryName,
        `State`,
        OpenDate,
        CloseDate,
        Description,
        SquareMeters,
        Status,
        current_timestamp() as _ingested_at,
        {{ generate_hash(_business_key + _dedup_columns) }} as _dedup_hash

    -- Stage-1 stopgap: bootstrap_landing_table stands in for Meltano. Run
    -- `dbt run-operation bootstrap_landing_table --args '{entity: store,
    -- ...}'` before building this model.
    from {{ source('contoso_landing', 'landing_store') }}

)

select *
from _source
{% if is_incremental() %}
where {{ dedup_before_insert() }}
{% endif %}
