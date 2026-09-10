{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns'
  )
}}

{#- Bronze is append-only, dedup-before-insert (constitution Principle I/IV).
    full-refresh is forbidden (FR-002) — fail loudly rather than silently
    allow it, since a full-refresh would destroy append-only history. -#}
{% if flags.FULL_REFRESH %}
    {{ exceptions.raise_compiler_error("bronze_contoso__customers is append-only — full-refresh is forbidden (AGENT.md §5 / constitution Principle I). Remove --full-refresh.") }}
{% endif %}

{#- model.meta.* resolves to Undefined during dbt's preliminary static-parse
    pass (a stub context used to detect macro/ref calls before the real
    manifest is built) — `| default([])` keeps that pass from hard-failing
    on `Undefined + Undefined`; the real compile pass always has the real
    lists from bronze_contoso__customers.yml. -#}
{% set _business_key = model.meta.business_key | default([]) %}
{% set _dedup_columns = model.meta.dedup_columns | default([]) %}

with _source as (

    select
        CustomerKey,
        GeoAreaKey,
        StartDT,
        EndDT,
        Continent,
        Gender,
        Title,
        GivenName,
        MiddleInitial,
        Surname,
        StreetAddress,
        City,
        `State`,  -- quoted defensively, see .sqlfluff
        StateFull,
        ZipCode,
        Country,
        CountryFull,
        Birthday,
        Age,
        Occupation,
        Company,
        Vehicle,
        Latitude,
        Longitude,
        current_timestamp() as _ingested_at,
        {{ generate_hash(_business_key + _dedup_columns) }} as _dedup_hash

    -- Stage-1 stopgap: a native Spark bulk load (bootstrap_landing_customer
    -- macro) stands in for the Meltano-populated landing zone (plan.md
    -- Complexity Tracking; AGENT.md §11). Run
    -- `dbt run-operation bootstrap_landing_customer` before building this
    -- model.
    from {{ source('contoso_landing', 'landing_customer') }}

)

select *
from _source
{% if is_incremental() %}
where {{ dedup_before_insert() }}
{% endif %}
