{% macro generate_schema_name(custom_schema_name, node) -%}
{#-
    Overrides dbt's default (which concatenates as
    `<target.schema>_<custom_schema_name>`, e.g. `dbo_bronze`). AGENT.md §7
    wants exact layer-named schemas — `bronze`, `silver`, `gold`,
    `serving` — matching the naming map, not a `dbo_`-prefixed variant.
    Requires the lakehouse to be schema-enabled (dbt_project.yml's
    per-layer `+schema:` configs; profiles.yml's `schema: dbo` default is
    only used when a model doesn't set a custom schema, e.g. the
    `contoso_landing` source or any future model outside bronze/silver/
    gold/serving).
-#}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
