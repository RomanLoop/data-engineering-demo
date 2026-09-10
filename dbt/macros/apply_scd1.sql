{% macro apply_scd1_update_columns() %}
{#-
    SCD1 ("overwrite in place", AGENT.md §6, constitution Principle V).

    Not exercised by the customers entity (its meta.scd1_columns is empty —
    customers is master data, fully SCD2, per spec.md/data-model.md). Built
    now so a future entity with a genuine SCD1/SCD2 mix doesn't need this
    retrofitted.

    Technical columns for a pure-SCD1 model (there is no dbt/data-warehousing
    convention as fixed as SCD2's _valid_from/_valid_to/_is_current triad,
    so this repo picks one and documents it here, per AGENT.md §6):
    _loaded_at (set once, on first insert — when this business key was
    first seen) and _updated_at (set on every run that actually changes a
    tracked column — when this row last changed; unlike bronze's
    _ingested_at, this must NOT bump on a merge that touched the row but
    changed nothing). Use generate_hash(scd1_columns) to detect an actual
    change before deciding whether to bump _updated_at: store it as
    _scd1_hash, and in the merge's UPDATE SET clause set _updated_at to
    current_run_timestamp() when the freshly computed hash differs from
    the stored _scd1_hash, else leave _updated_at unchanged.

    Usage — pure-SCD1 entity (no scd2_columns at all): rely on dbt's native
    merge incremental strategy directly (incremental_strategy='merge',
    unique_key set to the business key), passing this macro's return value
    as merge_update_columns — no macro call needed for the overwrite
    itself, just for the column list.

    Usage — mixed SCD1 + SCD2 entity: this macro returns the SCD1 column
    list for merge_update_columns on a MERGE that only ever touches the
    *current* row (scoped by an _is_current = true predicate in a custom
    merge pre_hook), while SCD2 columns are handled separately by
    apply_scd2 as expire + insert-new-version. Composing the two into one
    model's config is left to the entity that first needs it.
-#}
{{ return(model.meta.scd1_columns | default([])) }}
{% endmacro %}

{% macro apply_scd1_merge_update_columns() %}
{#-
    First real (non-stub) use: 002-onboard-contoso-remaining-entities
    (orders, orderrows). Returns the full column list for
    `merge_update_columns` — scd1_columns plus the technical columns that
    must be refreshed on every MATCHED row: `_ingested_at` (carries the
    latest bronze snapshot's ingestion time forward), `_scd1_hash` and
    `_updated_at` (see apply_scd1_updated_at_expr below).

    `_loaded_at` is deliberately NOT included here: dbt's `merge` only
    overwrites columns listed in `merge_update_columns` on an UPDATE, so
    excluding `_loaded_at` means the target's original first-seen value
    survives every subsequent merge untouched, for free — no self-join
    needed for that one column, unlike `_updated_at`.
-#}
{{ return((model.meta.scd1_columns | default([])) + ['_ingested_at', '_scd1_hash', '_updated_at']) }}
{% endmacro %}

{% macro apply_scd1_existing_join(target_relation, business_key) %}
{#-
    Pre-computes the "does this business key already exist, and with what
    hash/_updated_at" lookup a SCD1 model's SELECT needs to decide whether
    to bump `_updated_at` (see apply_scd1_updated_at_expr). Only valid
    `{% if is_incremental() %}` — on a first/full build `{{ target_relation
    }}` doesn't exist yet, so the caller must skip this join entirely (and
    use apply_scd1_updated_at_expr's `is_incremental=false` branch instead)
    exactly like apply_scd2's expire_scd2_current_rows is only ever called
    inside the same guard.

    Expects the incoming/source CTE to be aliased `_incoming` — a fixed
    convention for the two callers of this macro, not a parameter, to keep
    the join predicate readable.
-#}
{%- set business_key = business_key | default([]) -%}
left join {{ target_relation }} as _existing
    on {% for col in business_key %}_incoming.`{{ col }}` = _existing.`{{ col }}`{{ ' and ' if not loop.last }}{% endfor %}
{%- endmacro %}

{% macro apply_scd1_updated_at_expr(is_incremental, hash_column='_scd1_hash') %}
{#-
    `_updated_at` bumps to current_run_timestamp() only when the freshly
    computed hash actually differs from what's already stored for this
    business key (or the key is new) — a rerun with no real change leaves
    `_updated_at` untouched even though the MERGE still runs on every row
    (idempotent by value, not just by row count — see NFR-004). Requires
    apply_scd1_existing_join to have been used in the same query when
    is_incremental is true; on a first/full build there is no `_existing`
    to compare against, so every row is "new" by definition.
-#}
{%- if is_incremental %}
case
    when _existing.{{ hash_column }} is null or _existing.{{ hash_column }} != _incoming.{{ hash_column }}
    then {{ current_run_timestamp() }}
    else _existing._updated_at
end
{%- else %}
{{ current_run_timestamp() }}
{%- endif %}
{%- endmacro %}
