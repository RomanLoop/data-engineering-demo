{{ config(materialized='table') }}

{#- Passthrough. FK-shaped customer_key/store_key columns unresolved — no
    cross-entity join in this change (spec.md Assumptions). No surrogate
    key. -#}

select
    order_key,
    customer_key,
    store_key,
    order_date,
    delivery_date,
    currency_code

from {{ ref('silver_contoso__orders') }}
