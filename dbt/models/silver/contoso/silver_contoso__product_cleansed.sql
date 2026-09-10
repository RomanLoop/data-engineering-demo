{{ config(materialized='view') }}

{#- View, not incremental: a pure cleansing pass over the full bronze
    history (type casts + snake_case rename), no state of its own to
    persist. Historization happens downstream in silver_contoso__product. -#}

select
    ProductKey as product_key,
    ProductCode as product_code,
    ProductName as product_name,
    Manufacturer as manufacturer,
    Brand as brand,
    Color as color,
    WeightUnit as weight_unit,
    cast(Weight as double) as weight,
    cast(Cost as double) as cost,
    cast(Price as double) as price,
    CategoryKey as category_key,
    CategoryName as category_name,
    SubCategoryKey as sub_category_key,
    SubCategoryName as sub_category_name,
    _ingested_at

from {{ ref('bronze_contoso__product') }}
