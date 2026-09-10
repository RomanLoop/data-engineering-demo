{{ config(materialized='table') }}

{#- Passthrough, no cross-entity joins yet. No surrogate key. -#}

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
    working_day_number

from {{ ref('silver_contoso__date') }}
