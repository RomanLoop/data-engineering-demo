-- Singular test (user feedback, T020 review; generalized to all SCD2
-- models in 002-onboard-contoso-remaining-entities, research.md Decision
-- 4): consecutive versions of the same business key, in the same SCD2
-- model, must have no gap between them — the earlier version's _valid_to
-- must equal the next version's _valid_from exactly. Passes when this
-- returns zero rows.
--
-- Relies on the pre-hook (expire_scd2_current_rows,
-- dbt/macros/apply_scd2.sql) closing out a superseded row with the
-- *earliest* incoming _ingested_at for that key, matching exactly what the
-- model's own window function assigns as the new row's _valid_from.

{% set scd2_models = [
    {'model': 'silver_contoso__customers', 'key': 'customer_key'},
    {'model': 'silver_contoso__product', 'key': 'product_key'},
    {'model': 'silver_contoso__store', 'key': 'store_key'},
] %}

with ranges as (

    {% for m in scd2_models %}
        select
            '{{ m.model }}' as _model,
            {{ m.key }} as _business_key,
            _valid_from,
            _valid_to
        from {{ ref(m.model) }}
                {{ "union all" if not loop.last }}
    {% endfor %}

),

ordered as (

    select
        _model,
        _business_key,
        _valid_from,
        _valid_to,
        lead(_valid_from) over (
            partition by _model, _business_key order by _valid_from
        ) as next_valid_from
    from ranges

)

select *
from ordered
where
    next_valid_from is not null
    and _valid_to != next_valid_from
