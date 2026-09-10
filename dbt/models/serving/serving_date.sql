{{ config(materialized='view') }}

select *
from {{ ref('gold_date') }}
