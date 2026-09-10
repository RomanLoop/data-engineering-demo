-- Singular test (research.md Decision 3,
-- specs/002-onboard-contoso-remaining-entities/): SCD1 models overwrite in
-- place, so every business key must have exactly one row at all times —
-- proves the `merge` strategy's `unique_key` is genuinely deduplicating,
-- not silently falling back to append. Passes when this returns zero rows.
-- Complements (doesn't replace) the contract-level `unique` test on each
-- model's business key — same "belt and suspenders" reasoning as the SCD2
-- gap/overlap tests alongside dbt's own uniqueness test.
--
-- Key components are concatenated into one `_key` string (see
-- assert_silver_contoso_composite_key_unique.sql for why — same
-- [NUM_COLUMNS_MISMATCH] fix, orders has a single-column key while
-- orderrows has a composite one).

{% set scd1_models = [
    {'model': 'silver_contoso__orders', 'keys': ['order_key']},
    {'model': 'silver_contoso__orderrows', 'keys': ['order_key', 'line_number']},
] %}

{% for m in scd1_models %}
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
