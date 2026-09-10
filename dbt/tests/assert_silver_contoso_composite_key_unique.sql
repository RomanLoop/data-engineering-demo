-- Singular test (research.md Decision 6/Foundational T006,
-- specs/002-onboard-contoso-remaining-entities/): every composite business
-- key in this spec must be unique in its silver model. Covers
-- `silver_contoso__currencyexchange` (no SCD, no other uniqueness check
-- exists for it) and `silver_contoso__orderrows` (SCD1 — redundant with
-- assert_silver_contoso_orders_orderrows_no_duplicate_current.sql, kept
-- here too as the standard "look here first" composite-key check, same
-- belt-and-suspenders reasoning as the SCD2 gap/overlap tests). No
-- `dbt_utils` dependency (project has none so far) — hand-written,
-- consistent with the existing singular-test style.
--
-- Key components are concatenated into one `_key` string (not one column
-- per component) so every branch of the UNION ALL below has the same
-- fixed column count regardless of how many columns make up each model's
-- composite key (live-validation finding, 2026-09-09: a naive per-column
-- `_key_1`/`_key_2`/`_key_3` layout fails with
-- `[NUM_COLUMNS_MISMATCH]` the moment two models' key arity differs).

{% set composite_key_models = [
    {'model': 'silver_contoso__currencyexchange', 'keys': ['date', 'from_currency', 'to_currency']},
    {'model': 'silver_contoso__orderrows', 'keys': ['order_key', 'line_number']},
] %}

{% for m in composite_key_models %}
    select
        '{{ m.model }}' as _model,
        concat_ws(
            '||',
            {% for k in m['keys'] %}
                cast({{ k }} as string){{ ", " if not loop.last }}
            {% endfor %}
        ) as _key,
        count(*) as _row_count
    from {{ ref(m.model) }}
    group by
        {% for k in m['keys'] %}
            {{ k }}{{ ", " if not loop.last }}
        {% endfor %}
    having count(*) > 1
    {{ "union all" if not loop.last }}
{% endfor %}
