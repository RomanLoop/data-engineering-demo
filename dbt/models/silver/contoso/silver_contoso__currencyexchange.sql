{{ config(materialized='view') }}

{#- Static reference data (AGENT.md §6/§12) — no `apply_scd1`/`apply_scd2`
    call, no _cleansed split (this IS the cleansed model, per FR-007).
    Same "latest row per composite key" dedup as silver_contoso__date, for
    the same reason (bronze is append-only; a corrected rate would
    otherwise produce two rows per (date, from_currency, to_currency)
    here). -#}

with _ranked as (

    select
        cast(`Date` as date) as `date`,
        FromCurrency as from_currency,
        ToCurrency as to_currency,
        cast(Exchange as double) as exchange,
        _ingested_at,
        row_number() over (
            partition by `Date`, FromCurrency, ToCurrency
            order by _ingested_at desc
        ) as _row_num
    from {{ ref('bronze_contoso__currencyexchange') }}

)

select
    `date`,
    from_currency,
    to_currency,
    exchange,
    _ingested_at
from _ranked
where _row_num = 1
