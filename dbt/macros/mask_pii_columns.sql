{% macro mask_pii_columns(all_columns, pii_columns) %}
{#-
    PII masking (AGENT.md §6, constitution Principle VI). Renders a
    comma-separated select-list: columns listed in `pii_columns` are hashed
    when the active target is non-prod; every other column (and PII columns
    on `prod`) passes through unmasked.

    Use in a model's final SELECT in place of `select *`, passing the full
    column list and model.meta.pii_columns.

    Stage 1 (AGENT.md §8/§11) runs a single `prod`-only target, so this is
    currently a no-op — it must still be exercised/tested (spec NFR-002) so
    masking is proven correct before a real non-prod target exists, not
    retrofitted later under time pressure.
-#}
{%- set is_nonprod = target.name != 'prod' -%}
{%- for col in all_columns -%}
    {%- if is_nonprod and col in pii_columns -%}
    sha2(cast(`{{ col }}` as string), 256) as `{{ col }}`
    {%- else -%}
    `{{ col }}`
    {%- endif -%}
    {{ "," if not loop.last }}
{%- endfor -%}
{%- endmacro %}
