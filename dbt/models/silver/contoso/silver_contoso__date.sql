{{ config(materialized='view') }}

{#- Static reference data (AGENT.md §6/§12, research.md Decision 1) — no
    `apply_scd1`/`apply_scd2` call, no _cleansed split (this IS the
    cleansed model, per FR-007). Type casts + snake_case rename, plus a
    plain "latest row per key" dedup: bronze is still an append-only log,
    so if a date record were ever genuinely corrected (a new bronze row
    with a different _dedup_hash), a raw passthrough would produce two
    rows per date_key here and break the not_null/unique contract test.
    No SCD1/SCD2 versioning (no _valid_from/_loaded_at bookkeeping) — just
    "keep the newest _ingested_at per key", which a plain view can express
    with a row_number() filter, no merge/incremental state needed. -#}

with _ranked as (

    select
        cast(`Date` as date) as `date`,
        DateKey as date_key,
        Year as year,
        YearQuarter as year_quarter,
        YearQuarterNumber as year_quarter_number,
        Quarter as quarter,
        YearMonth as year_month,
        YearMonthShort as year_month_short,
        YearMonthNumber as year_month_number,
        Month as month,
        MonthShort as month_short,
        MonthNumber as month_number,
        DayofWeek as day_of_week,
        DayofWeekShort as day_of_week_short,
        DayofWeekNumber as day_of_week_number,
        WorkingDay as working_day,
        WorkingDayNumber as working_day_number,
        _ingested_at,
        row_number() over (
            partition by DateKey order by _ingested_at desc
        ) as _row_num
    from {{ ref('bronze_contoso__date') }}

)

select
    `date`,
    date_key,
    year,
    year_quarter,
    year_quarter_number,
    quarter,
    year_month,
    year_month_short,
    year_month_number,
    month,
    month_short,
    month_number,
    day_of_week,
    day_of_week_short,
    day_of_week_number,
    working_day,
    working_day_number,
    _ingested_at
from _ranked
where _row_num = 1
