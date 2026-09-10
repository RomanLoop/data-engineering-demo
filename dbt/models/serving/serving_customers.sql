{{ config(materialized='view') }}

{#- Thin pass-through view over gold. No RLS for this change — no consumer
    roles defined yet in Stage 1's single-workspace setup (spec.md
    Assumptions; AGENT.md §5/§11). -#}

select *
from {{ ref('gold_customers') }}
