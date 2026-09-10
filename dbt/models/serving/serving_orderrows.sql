{{ config(materialized='view') }}

select *
from {{ ref('gold_orderrows') }}
