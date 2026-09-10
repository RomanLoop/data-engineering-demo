-- Singular test (user feedback, T020 review; generalized to all SCD2
-- models in 002-onboard-contoso-remaining-entities, research.md Decision
-- 4): no two versions of the same business key, in the same SCD2 model,
-- may have overlapping [_valid_from, _valid_to) ranges. Passes when this
-- returns zero rows.
--
-- Boundaries are half-open and meant to touch exactly (see
-- dbt/macros/apply_scd2.sql) — a._valid_to equal to b._valid_from is NOT
-- an overlap, only a._valid_to > b._valid_from (a genuinely later start
-- inside a's still-open range) is.
--
-- Hardcoded list of (model, business-key column) pairs rather than
-- auto-discovery via graph.nodes — deliberately simple for a handful of
-- SCD2 models, see research.md Decision 4 for the alternatives considered.

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

)

select
    a._model,
    a._business_key,
    a._valid_from as a_valid_from,
    a._valid_to as a_valid_to,
    b._valid_from as b_valid_from,
    b._valid_to as b_valid_to
from ranges as a
inner join ranges as b
    on
        a._model = b._model
        and a._business_key = b._business_key
        and a._valid_from < b._valid_from
        and a._valid_to > b._valid_from
