{{ config(materialized='table') }}

{#- Current-version products only. No cross-entity joins yet — business
    logic will grow here once a consumer need justifies resolving
    category_key/etc. against other entities. No surrogate key: business
    key passed through (constitution Principle V). -#}

select
    product_key,
    product_code,
    product_name,
    manufacturer,
    brand,
    color,
    weight_unit,
    weight,
    cost,
    price,
    category_key,
    category_name,
    sub_category_key,
    sub_category_name

from {{ ref('silver_contoso__product') }}
where _is_current = true
