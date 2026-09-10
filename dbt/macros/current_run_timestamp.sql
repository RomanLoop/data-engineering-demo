{% macro current_run_timestamp() %}
{#-
    A single timestamp literal, fixed at the start of this dbt invocation
    (`run_started_at`, a dbt Jinja global), rendered identically wherever
    called within the same run.

    Used instead of a runtime `current_timestamp()` for SCD2 boundaries
    (apply_scd2.sql): the pre-hook that closes out a superseded row and the
    main SELECT that opens the replacement row are separate SQL statements,
    so two independent `current_timestamp()` calls would differ by
    milliseconds — leaving a technical gap/overlap between consecutive
    versions. A shared compile-time literal makes the boundaries touch
    exactly (`_valid_to` of the old version == `_valid_from` of the new
    one), which is what `dbt/tests/assert_*_no_gaps_in_validity.sql` and
    `..._no_overlapping_validity.sql` check for.
-#}
timestamp '{{ run_started_at.strftime("%Y-%m-%d %H:%M:%S.%f") }}'
{%- endmacro %}
