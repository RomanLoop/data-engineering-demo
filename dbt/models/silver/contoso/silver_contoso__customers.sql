{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns'
  )
}}

{#- model.meta.* resolves to Undefined during dbt's preliminary static-parse
    pass (a stub context used to detect macro/ref calls before the real
    manifest is built) — `| default([])` keeps that pass from hard-failing
    on `Undefined + Undefined`; the real compile pass always has the real
    lists from silver_contoso__customers.yml. -#}
{% set _business_key = model.meta.business_key | default([]) %}
{% set _scd2_columns = model.meta.scd2_columns | default([]) %}
{% set _business_key_col = _business_key[0] if _business_key
    else '_business_key' %}

{#- post_hook, called UNCONDITIONALLY, purely self-referential, hardcoded
    literal arguments (not `this`/`model.meta`). Original (001) design
    used a pre_hook gated by is_incremental() (Bug 1, then Bug 3 — both
    incident writeups in apply_scd2.sql); superseded 2026-09-09 after Bug 3
    proved dbt's config-extraction pass re-executes the whole template in
    a stub context, poisoning ANY `this`/`model.meta`/adapter-dependent
    value fed into a config() argument, not just is_incremental(). -#}
{{ config(post_hook=expire_scd2_current_rows(
    'silver', 'silver_contoso__customers', 'customer_key'
)) }}

{#- SCD2 historization on top of the cleansed view — see
    dbt/macros/apply_scd2.sql for the full design note. Customers is master
    data (spec.md), so every non-key column is meta.scd2_columns; there is
    no meta.scd1_columns split for this entity. -#}

with _cleansed as (

    select
        *,
        {{ generate_hash(_business_key + _scd2_columns) }} as _scd_hash
    from {{ ref('silver_contoso__customers_cleansed') }}

),

_unprocessed as (

    -- Snapshots not yet historized. Reuses dedup_before_insert against the
    -- *full* target table (not just the current row) because _cleansed is
    -- a passthrough of bronze's entire append-only history, not just rows
    -- since the last silver run.
    select _cleansed.*
    from _cleansed
    {% if is_incremental() %}
    where {{ dedup_before_insert(hash_column='_scd_hash', source_alias='_cleansed') }}
    {% endif %}

),

_versioned as (

    -- Windowed by business key regardless of whether _unprocessed is "all
    -- of bronze" (first run / a rebuild against an already-historized
    -- bronze table) or "just what changed since last run" (normal
    -- incremental run) — both cases can legitimately contain more than
    -- one snapshot per key, and this assigns each key's snapshots
    -- non-overlapping, gap-free [_valid_from, _valid_to) ranges either way.
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
    customer_key,
    geo_area_key,
    start_dt,
    end_dt,
    continent,
    gender,
    title,
    given_name,
    middle_initial,
    surname,
    street_address,
    city,
    `state`,
    state_full,
    zip_code,
    country,
    country_full,
    birthday,
    age,
    occupation,
    company,
    vehicle,
    latitude,
    longitude,
    _ingested_at,
    _scd_hash,
    _valid_from,
    _valid_to,
    _is_current
from _versioned
