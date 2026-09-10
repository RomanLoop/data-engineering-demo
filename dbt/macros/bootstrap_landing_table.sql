{% macro bootstrap_landing_table(entity, csv_path, columns) %}
{#-
    Generalized landing bootstrap (research.md Decision 5,
    specs/002-onboard-contoso-remaining-entities/) — replaces the
    per-entity-macro pattern (bootstrap_landing_customer.sql, left
    untouched, still used for `customers`) with one macro parameterized by
    entity name, CSV path (relative to this lakehouse's OneLake Files
    area), and a full ordered column list.

    `columns`: list of {name: <SourceColumnName>[, type: <target_type>]}.
    Omit `type` for a column that should pass through as whatever type
    Spark's CSV reader inferred (string, for header/inferSchema='false'
    reads) — same "explicit casts only where the source type actually
    needs coercing" convention bootstrap_landing_customer established.

    Originally tried Spark SQL's `SELECT * REPLACE (...)` (supported on
    Databricks Runtime and some Spark 3.4+ builds) to avoid needing the
    full column list — confirmed NOT supported on this Fabric Spark
    runtime during live validation (2026-09-09, T018:
    `[PARSE_SYNTAX_ERROR] Syntax error at or near '('`), so this macro
    enumerates every column explicitly, matching
    bootstrap_landing_customer's original style.

    Run via, e.g.:
    dbt run-operation bootstrap_landing_table --args
      '{entity: product, csv_path: Files/contoso/product.csv,
        columns: [{name: ProductKey, type: int}, {name: ProductCode},
        {name: ProductName}, ...]}'

    Idempotent: CREATE OR REPLACE, safe to rerun. Lands in the `landing`
    schema (created if missing), matching bootstrap_landing_customer.
-#}

{% do run_query('create schema if not exists landing') %}

{% set temp_view = '_' ~ entity ~ '_csv' %}

{% set create_view_sql %}
create or replace temporary view {{ temp_view }}
using csv
options (path '{{ csv_path }}', header 'true', inferSchema 'false')
{% endset %}
{% do run_query(create_view_sql) %}
{{ log("Created temporary view over " ~ csv_path, info=true) }}

{% set select_list %}
{%- for col in columns -%}
{%- if col.type -%}
cast(`{{ col.name }}` as {{ col.type }}) as `{{ col.name }}`
{%- else -%}
`{{ col.name }}`
{%- endif -%}
{{ ", " if not loop.last }}
{%- endfor -%}
{% endset %}

{% set ctas_sql %}
create or replace table landing.landing_{{ entity }}
using delta
as
select {{ select_list }}
from {{ temp_view }}
{% endset %}
{% do run_query(ctas_sql) %}
{{ log("Created landing_" ~ entity ~ " as a Delta table from the bulk CSV load", info=true) }}

{% set count_sql %}
select count(*) as row_count from landing.landing_{{ entity }}
{% endset %}
{% set result = run_query(count_sql) %}
{{ log("landing_" ~ entity ~ " row count: " ~ result.columns['row_count'].values()[0], info=true) }}

{% endmacro %}
