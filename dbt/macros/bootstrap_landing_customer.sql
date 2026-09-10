{% macro bootstrap_landing_customer() %}
{#-
    Stage-1 landing bootstrap (AGENT.md §11, plan.md Complexity Tracking) —
    replaces the earlier dbt-seed stopgap, which measured ~30+ minutes for
    104,990 rows via dbt-fabricspark's row-batched INSERT seed
    materialization (Livy round-trip overhead scales with row count, not
    just batch count — see specs/001-onboard-contoso-customers/tasks.md
    T020 notes). A native Spark bulk read+write of the CSV file (already
    uploaded to this lakehouse's OneLake Files area at
    Files/contoso/customer.csv via the ADLS Gen2 DFS API) does the same
    load as a single distributed Spark job instead of ~422 sequential SQL
    statements.

    Run via: dbt run-operation bootstrap_landing_customer

    Idempotent: CREATE OR REPLACE, safe to rerun. Column types match the
    dbt seed's former `+column_types` config (dbt_project.yml), so
    downstream models don't need to change based on how landing_customer
    got populated.

    Lands in the `landing` schema (created if missing) — the lakehouse is
    schema-enabled (2026-09-09, AGENT.md §7), matching the medallion
    layer's own name rather than the `dbo` default.
-#}

{% do run_query('create schema if not exists landing') %}

{% set create_view_sql %}
create or replace temporary view _customer_csv
using csv
options (path 'Files/contoso/customer.csv', header 'true', inferSchema 'false')
{% endset %}
{% do run_query(create_view_sql) %}
{{ log("Created temporary view over Files/contoso/customer.csv", info=true) }}

{% set ctas_sql %}
create or replace table landing.landing_customer
using delta
as
select
    cast(CustomerKey as int) as CustomerKey,
    cast(GeoAreaKey as int) as GeoAreaKey,
    cast(StartDT as date) as StartDT,
    cast(EndDT as date) as EndDT,
    Continent,
    Gender,
    Title,
    GivenName,
    MiddleInitial,
    Surname,
    StreetAddress,
    City,
    `State`,
    StateFull,
    ZipCode,
    Country,
    CountryFull,
    cast(Birthday as date) as Birthday,
    cast(Age as int) as Age,
    Occupation,
    Company,
    Vehicle,
    cast(Latitude as double) as Latitude,
    cast(Longitude as double) as Longitude
from _customer_csv
{% endset %}
{% do run_query(ctas_sql) %}
{{ log("Created landing_customer as a Delta table from the bulk CSV load", info=true) }}

{% set count_sql %}
select count(*) as row_count from landing.landing_customer
{% endset %}
{% set result = run_query(count_sql) %}
{{ log("landing_customer row count: " ~ result.columns['row_count'].values()[0], info=true) }}

{% endmacro %}
