{% macro dedup_before_insert(hash_column='_dedup_hash', source_alias='_source') %}
{#-
    Bronze dedup-before-insert filter (AGENT.md §6, constitution Principle
    I) — and reused by silver's SCD2 "unprocessed snapshot" filter
    (apply_scd2.sql) with hash_column set to '_scd_hash'.

    Compares a single stored hash column (see generate_hash.sql) rather
    than every business_key/dedup_columns value individually — cheaper,
    and sidesteps needing to know the column list at the call site.

    Use inside an incremental model's final SELECT, guarded by
    is_incremental(), against a source CTE aliased to source_alias
    (default '_source') that already computed the hash column via
    generate_hash(...) — see bronze_contoso__customers.sql for the
    concrete, working example.
-#}
not exists (
    select 1
    from {{ this }} as _existing
    where _existing.{{ hash_column }} = {{ source_alias }}.{{ hash_column }}
)
{%- endmacro %}
