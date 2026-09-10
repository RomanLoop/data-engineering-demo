{{ config(materialized='view') }}

{#- View, not incremental: a pure cleansing pass over the full bronze
    history (type casts + snake_case rename), no state of its own to
    persist. Historization happens downstream in silver_contoso__customers. -#}

select
    CustomerKey as customer_key,
    GeoAreaKey as geo_area_key,
    cast(StartDT as date) as start_dt,
    cast(EndDT as date) as end_dt,
    Continent as continent,
    Gender as gender,
    Title as title,
    GivenName as given_name,
    MiddleInitial as middle_initial,
    Surname as surname,
    StreetAddress as street_address,
    City as city,
    State as `state`,  -- quoted defensively, see .sqlfluff
    StateFull as state_full,
    ZipCode as zip_code,
    Country as country,
    CountryFull as country_full,
    cast(Birthday as date) as birthday,
    cast(Age as int) as age,
    Occupation as occupation,
    Company as company,
    Vehicle as vehicle,
    cast(Latitude as double) as latitude,
    cast(Longitude as double) as longitude,
    _ingested_at

from {{ ref('bronze_contoso__customers') }}
