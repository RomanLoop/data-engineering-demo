{{ config(materialized='table') }}

{#- Current-version customers only. No cross-entity joins yet (customers is
    the only entity onboarded) — business logic will grow here as more
    entities/joins are added. No surrogate key: business key passed through
    (constitution Principle V — relational, not dimensional). -#}

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
    longitude

from {{ ref('silver_contoso__customers') }}
where _is_current = true
