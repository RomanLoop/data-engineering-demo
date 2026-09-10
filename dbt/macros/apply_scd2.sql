{#-
    SCD2 versioned history (AGENT.md §6, constitution Principle V).

    Design (revised 2026-09-09, three real bugs found across two rounds of
    live delta-load validation — 001's T022 and 002's T020 — see
    silver_contoso__customers.sql/silver_contoso__product.sql for the
    concrete usage):

    Bug 1 (001, T022) — pre_hook silently never ran: `is_incremental()` was
    being called (indirectly, via computing the pre_hook string) BEFORE the
    model's `config(materialized='incremental', ...)` had been rendered in
    the file, so it always evaluated false and the expire step was
    skipped — with zero error, just silently wrong.

    Bug 3 (002, T020, product) — chasing Bug 1's fix further: even with
    `is_incremental()` called in the correct position, `{{ config(pre_hook=
    _expire_sql) }}` — whether the WHOLE config() call was wrapped in `{%
    if is_incremental() %}`, or the call was unconditional with only the
    hook's *string value* computed via an is_incremental()-conditional
    `{% set %}` block — consistently resolved `is_incremental()` (and even
    `load_relation(this)`, a live/uncached adapter check) as False/None
    while computing that value, even though the SAME check later in the
    SAME model's main SQL body correctly evaluated True in the SAME run.
    Root cause: dbt evaluates `config()` argument values in a pass that
    doesn't have live adapter/catalog access — any adapter-dependent Jinja
    (is_incremental(), load_relation(), …) feeding into a config()
    argument's value is unreliable, full stop, regardless of exactly how
    or where it's invoked. This is the same *class* of gotcha as the
    `model.meta` stub-context issue found in 001 (a preliminary pass
    without full context silently produces a different answer than the
    real compile pass) but hits adapter calls, not `model.meta`.

    **Fix, part 1**: don't put the expire step in a pre_hook at all. Use a
    **post_hook**, and make it purely self-referential (operates only on
    the target table, comparing already-inserted rows against each other —
    no `source_relation`, no hash comparison, no `is_incremental()` check
    of any kind, called UNCONDITIONALLY). By the time a post_hook runs,
    dbt has already created/populated the target table via the model's own
    CREATE-TABLE-AS-SELECT or INSERT, on a first run exactly as much as an
    incremental one — so there is nothing to gate. On a genuine first run,
    every business key has exactly one row and the expire UPDATE's `EXISTS
    (... newer row ...)` predicate matches nothing: a correct, cheap
    no-op.

    **Fix, part 2** (found immediately after part 1, same investigation):
    the same "config()-argument pass lacks real context" problem turned
    out to be broader than just `is_incremental()`/`load_relation()` — it
    affects `{{ this }}` too. `expire_scd2_current_rows(this,
    _business_key)` used as a `config(post_hook=...)` argument resolved
    `{{ this }}`'s SCHEMA to the raw profile target (`dbo`) instead of the
    model's actual configured schema (`silver`, via `generate_schema_name`
    + dbt_project.yml's folder-level `+schema:`) — regardless of where in
    the file the `config()` call was positioned — and separately resolved
    `_business_key` (itself sourced from `model.meta.business_key`) back
    to `[]`, i.e. the exact `model.meta`-stub-context gotcha documented
    elsewhere in this project, just newly discovered to *also* poison
    config() arguments specifically, not only the main model body (where
    the existing `| default([])` guards were already enough). Root cause,
    now fully understood: dbt's config-extraction pass **re-executes the
    entire model template** in a stub context (no live adapter, no real
    manifest/`model.meta`, default/un-overridden schema resolution) purely
    to discover `config()` calls — and captures whatever those arguments
    evaluate to *in that stub pass*, never re-evaluating them against the
    real compile pass's context even though the call site is textually
    inside the body that DOES get properly re-rendered later. Nothing fed
    into a `config()` argument can safely depend on the adapter, the
    manifest, or `this`'s resolved schema — full stop.

    **Practical consequence**: `expire_scd2_current_rows` takes plain
    hardcoded string literals (schema, table name, business-key column),
    not `this`/`model.meta`-derived values — the one place in this
    project's macros where DRY loses to "must survive the stub pass."

    **Fix, part 3** (found immediately after part 2, live, same
    investigation): a plain self-referential `UPDATE ... WHERE EXISTS
    (SELECT ... FROM <same table> ...)` — a correlated subquery whose
    FROM is the table being updated — fails on Delta with
    `[DELTA_UNSUPPORTED_SUBQUERY]`. Delta's `UPDATE` supports subqueries
    against *other* tables (the original 001 pre_hook design, comparing
    target vs. a separate source_relation, never hit this), but not a
    self-join back onto the row being updated. Fixed by using `MERGE
    INTO` instead of `UPDATE` — Delta's MERGE fully supports a `USING`
    clause built from a self-join/aggregation over the same table.

    Bug 2 (001, T022) — assumed at most one pending snapshot per business
    key per run: true for the normal simulate-then-build workflow, false
    for a cold rebuild against a bronze table that already has accumulated
    history (every row would have looked "current" at once). Fixed by
    always windowing the unprocessed batch (LEAD/ROW_NUMBER by business
    key ordered by `_ingested_at`), whether that batch is "everything"
    (first run / rebuild) or "just the new snapshots since last run"
    (normal incremental run) — see the model for the exact window
    functions. Still true and unchanged by the pre_hook→post_hook switch.

    hash-based change detection (generate_hash.sql, still used for the
    *dedup* filter in the model's main body — unaffected by this change),
    `_valid_to` never NULL (a sentinel high timestamp instead), and
    touching (no gap, no overlap) version boundaries: the post-hook closes
    out a superseded row using the *earliest* newer row's `_valid_from`
    for that key, so it lines up exactly with what the model's own window
    function already assigned that row.

    Usage — a silver historization model — see silver_contoso__customers.sql
    for the concrete, working example: config `materialized='incremental'`
    first; unconditionally add a second `config(post_hook=...)` call using
    `expire_scd2_current_rows` (no `{% if %}` anywhere near it); in the
    model body, build a CTE that adds a `generate_hash(...)` column,
    filter to rows not yet present in the target via `dedup_before_insert`
    (hash_column set to that hash column's name, inside `{% if
    is_incremental() %}` — that check is fine, it's not feeding a
    config() argument), then window `_valid_from`/`_valid_to`/`_is_current`
    over the unprocessed batch by business key, and select the explicit
    contract column list.
-#}

{% macro expire_scd2_current_rows(schema, table_name, business_key_col) %}
{#-
    Post-hook UPDATE, called unconditionally (see design note above) —
    purely self-referential, no source_relation/hash comparison needed.
    Closes out any row that is still marked `_is_current = true` but has
    a strictly newer row (by `_valid_from`) for the same business key
    already present in the target (true immediately after this same run's
    INSERT has landed the new version(s)). `_valid_to` is set to the
    *earliest* such newer row's `_valid_from`, so it touches exactly the
    boundary the model's own window function assigned.

    `schema`/`table_name`/`business_key_col` are plain string literals,
    NOT `this`/`model.meta`-derived — see the design note above ("Fix,
    part 2") for why anything dynamic here silently resolves wrong. The
    database/lakehouse name (`lh_contoso`) is hardcoded too, for the same
    reason — acceptable given Stage 1's documented single-lakehouse
    constraint (AGENT.md §7/§8); revisit if that ever changes.
-#}
{%- set _relation = '`lh_contoso`.`' ~ schema ~ '`.' ~ table_name -%}
merge into {{ _relation }} as _target
using (
    select
        _current.`{{ business_key_col }}` as `{{ business_key_col }}`,
        _current._valid_from as _current_valid_from,
        min(_newer._valid_from) as _new_valid_to
    from {{ _relation }} as _current
    inner join {{ _relation }} as _newer
        on
            _newer.`{{ business_key_col }}` = _current.`{{ business_key_col }}`
            and _newer._valid_from > _current._valid_from
    where _current._is_current = true
    group by _current.`{{ business_key_col }}`, _current._valid_from
) as _expired
    on
        _target.`{{ business_key_col }}` = _expired.`{{ business_key_col }}`
        and _target._valid_from = _expired._current_valid_from
when matched then update set
    _is_current = false,
    _valid_to = _expired._new_valid_to
{%- endmacro %}
