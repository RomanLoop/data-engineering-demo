{% macro generate_hash(columns, alias=none) %}
{#-
    Deterministic hash over a column list (AGENT.md §6). Used to make
    dedup (bronze) and change-detection (silver SCD2) comparisons cheap: a
    stored hash column is compared with equality instead of comparing every
    tracked column individually on every row.

    alias: optional table alias to qualify each column reference with —
    needed when the expression is used in a correlated subquery (see
    apply_scd2.sql's expire_scd2_current_rows) rather than a plain select
    over the CTE that owns the columns. Omit it (the default) when the
    columns are already in scope unqualified.

    Each column is coalesced to a sentinel string before hashing so that a
    real NULL and the literal never collide, and cast to string so the hash
    is stable across the mixed types in a wide business-attribute list.
-#}
{%- set prefix = (alias ~ '.') if alias else '' -%}
sha2(concat_ws('||', {% for col in columns %}coalesce(cast({{ prefix }}`{{ col }}` as string), '␀'){{ ", " if not loop.last }}{% endfor %}), 256)
{%- endmacro %}
