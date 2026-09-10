{{ config(materialized='table') }}

{#- Current-version stores only. No cross-entity joins yet. No surrogate
    key: business key passed through. -#}

select
    store_key,
    store_code,
    geo_area_key,
    country_code,
    country_name,
    `state`,
    open_date,
    close_date,
    description,
    square_meters,
    status

from {{ ref('silver_contoso__store') }}
where _is_current = true
