{{ config(materialized='view') }}

{#- Thin pass-through view over gold. No RLS for this change. -#}

select *
from {{ ref('gold_product') }}
