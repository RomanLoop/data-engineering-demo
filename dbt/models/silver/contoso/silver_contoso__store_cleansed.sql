{{ config(materialized='view') }}

{#- View, not incremental: a pure cleansing pass over the full bronze
    history. Historization happens downstream in silver_contoso__store. -#}

select
    StoreKey as store_key,
    StoreCode as store_code,
    GeoAreaKey as geo_area_key,
    CountryCode as country_code,
    CountryName as country_name,
    State as `state`,  -- quoted defensively, see .sqlfluff
    cast(OpenDate as date) as open_date,
    cast(CloseDate as date) as close_date,
    Description as description,
    cast(SquareMeters as double) as square_meters,
    Status as status,
    _ingested_at

from {{ ref('bronze_contoso__store') }}
