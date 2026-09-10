{{ config(materialized='view') }}

select
    OrderKey as order_key,
    LineNumber as line_number,
    ProductKey as product_key,
    cast(Quantity as int) as quantity,
    cast(UnitPrice as double) as unit_price,
    cast(NetPrice as double) as net_price,
    cast(UnitCost as double) as unit_cost,
    _ingested_at

from {{ ref('bronze_contoso__orderrows') }}
