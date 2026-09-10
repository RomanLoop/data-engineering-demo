{{ config(materialized='table', partition_by=['order_year']) }}

{#- Passthrough. FK-shaped customer_key/store_key columns unresolved — no
    cross-entity join in this change (spec.md Assumptions). No surrogate
    key. Partitioned by order_year for consumer-side pruning; table
    materialization rebuilds every run so no manual step is needed here. -#}

select
    order_key,
    customer_key,
    store_key,
    order_date,
    delivery_date,
    currency_code,
    order_year

from {{ ref('silver_contoso__orders') }}
