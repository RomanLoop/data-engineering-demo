{{ config(materialized='view') }}

{#- View, not incremental: a pure cleansing pass over the full bronze
    history. SCD1 overwrite-in-place happens downstream in
    silver_contoso__orders. -#}

select
    OrderKey as order_key,
    CustomerKey as customer_key,
    StoreKey as store_key,
    cast(OrderDate as date) as order_date,
    cast(DeliveryDate as date) as delivery_date,
    CurrencyCode as currency_code,
    _ingested_at,
    -- Partition key, carried through from bronze unchanged (year(OrderDate)).
    -- Kept last to match the partitioned downstream models' contract order.
    order_year

from {{ ref('bronze_contoso__orders') }}
