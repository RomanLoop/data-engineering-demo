{{
  config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='order_key',
    on_schema_change='append_new_columns',
    partition_by=['order_year']
  )
}}

{#- First real SCD1 model (research.md Decision 2,
    specs/002-onboard-contoso-remaining-entities/) — overwrite-in-place via
    dbt-fabricspark's native `merge` strategy (confirmed supported for
    delta file_format). -#}

{% set _business_key = model.meta.business_key | default([]) %}
{% set _scd1_columns = model.meta.scd1_columns | default([]) %}

{#- order_year is a pure function of order_date (already in scd1_columns), so
    it is NOT added to the hash — it is appended to the MERGE update set only,
    so a corrected order_date that crosses a year boundary also moves the row
    to its new partition. -#}
{{ config(merge_update_columns=apply_scd1_merge_update_columns() + ['order_year']) }}

{#- PERF (partition pruning, 2026-09-10): restrict the SCD1 MERGE to just the
    order_year partitions this run can touch. The predicate is ANDed into the
    MERGE ON clause, so it MUST be a *superset* of every partition holding a
    row that could match an incoming key, or an excluded real match would be
    re-inserted as a duplicate. That superset is:
      (years of cleansed rows arriving since the last merge)
        ∪ (existing target years for those same order_keys)
    the second set covering an order_date correction across a year boundary.
    Baked as a literal `in (...)` list (no subquery — Delta MERGE ON rejects
    correlated subqueries). No new data → probe returns nothing → `in (-1)`
    → zero partitions scanned (P2 already makes the source empty too).

    Guards:
      - `execute` — the parse-time config-extraction pass is a no-op
        (run_query returns None there).
      - `flags.WHICH in ('run', 'build')` — only an actual materialization
        needs the predicate; don't fire a warehouse query on every
        `compile` / `docs generate` / sqlfluff templater pass.
      - `order_year` present on the target — until the one-time partition
        rebuild has happened the column doesn't exist yet; skip the probe
        (plain full MERGE) rather than crash on an unresolved column. -#}
{%- set _year_predicate = none -%}
{%- set _target_has_order_year = false -%}
{%- if execute and is_incremental() and flags.WHICH in ('run', 'build') -%}
    {%- set _target_cols = adapter.get_columns_in_relation(this) | map(attribute='name') | map('lower') | list -%}
    {%- set _target_has_order_year = 'order_year' in _target_cols -%}
{%- endif -%}
{%- if _target_has_order_year -%}
    {%- set _touched_years_query -%}
        with _wm as (
            select coalesce(max(_ingested_at), timestamp '1900-01-01') as wm
            from {{ this }}
        ),
        _incoming_keys as (
            select order_key, order_year
            from {{ ref('silver_contoso__orders_cleansed') }}
            where _ingested_at > (select wm from _wm)
        )
        select distinct oy
        from (
            select order_year as oy from _incoming_keys
            union
            select t.order_year as oy
            from {{ this }} as t
            where t.order_key in (select order_key from _incoming_keys)
        ) as _years
        where oy is not null
    {%- endset -%}
    {%- set _result = run_query(_touched_years_query) -%}
    {%- if _result is not none -%}
        {%- set _years = _result.columns[0].values() | list -%}
        {%- set _year_predicate = 'DBT_INTERNAL_DEST.order_year in ('
            ~ (_years | join(', ') if _years else '-1') ~ ')' -%}
    {%- endif -%}
{%- endif -%}
{%- if _year_predicate is not none -%}
{{ config(incremental_predicates=[_year_predicate]) }}
{%- endif -%}

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
