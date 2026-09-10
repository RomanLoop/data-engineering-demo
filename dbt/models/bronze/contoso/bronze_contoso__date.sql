{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='append_new_columns'
  )
}}

{% if flags.FULL_REFRESH %}
    {{ exceptions.raise_compiler_error("bronze_contoso__date is append-only — full-refresh is forbidden. Remove --full-refresh.") }}
{% endif %}

{% set _business_key = model.meta.business_key | default([]) %}
{% set _dedup_columns = model.meta.dedup_columns | default([]) %}

with _source as (

    select
        `Date`,
        DateKey,
        Year,
        YearQuarter,
        YearQuarterNumber,
        Quarter,
        YearMonth,
        YearMonthShort,
        YearMonthNumber,
        Month,
        MonthShort,
        MonthNumber,
        DayofWeek,
        DayofWeekShort,
        DayofWeekNumber,
        WorkingDay,
        WorkingDayNumber,
        current_timestamp() as _ingested_at,
        {{ generate_hash(_business_key + _dedup_columns) }} as _dedup_hash

    -- Stage-1 stopgap: bootstrap_landing_table stands in for Meltano.
    from {{ source('contoso_landing', 'landing_date') }}

)

select *
from _source
{% if is_incremental() %}
where {{ dedup_before_insert() }}
{% endif %}
