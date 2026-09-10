{{ config(materialized='table') }}

{#- Passthrough. FK-shaped product_key column unresolved — no cross-entity
    join in this change. No surrogate key — composite business key passed
    through as two plain columns. -#}

select
    order_key,
    line_number,
    product_key,
    quantity,
    unit_price,
    net_price,
    unit_cost

from {{ ref('silver_contoso__orderrows') }}
