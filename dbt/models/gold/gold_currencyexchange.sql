{{ config(materialized='table') }}

{#- Passthrough, no cross-entity joins yet. No surrogate key — composite
    business key passed through as three plain columns. -#}

select
    `date`,
    from_currency,
    to_currency,
    exchange

from {{ ref('silver_contoso__currencyexchange') }}
