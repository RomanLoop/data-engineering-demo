# [PROJECT_NAME] Constitution
<!-- Example: data-engineering-demo Constitution -->

## Core Principles

### [PRINCIPLE_1_NAME]
<!-- Example: I. Idempotency -->
[PRINCIPLE_1_DESCRIPTION]
<!-- Example: Every ingestion and transformation run can be repeated without creating duplicates; incremental models dedup before insert; full-refresh forbidden where append-only is required -->

### [PRINCIPLE_2_NAME]
<!-- Example: II. Additive schema evolution (NON-NEGOTIABLE) -->
[PRINCIPLE_2_DESCRIPTION]
<!-- Example: New source columns are appended, never silently dropped; column removal is a deliberate, separate change -->

### [PRINCIPLE_3_NAME]
<!-- Example: III. Medallion layering with strict boundaries -->
[PRINCIPLE_3_DESCRIPTION]
<!-- Example: Landing → Bronze (append-only, dedup-before-insert) → Silver (cleansing/enrichment, no cross-model joins) → Gold (business logic, cross-model joins) → Serving (RLS); a model must not skip or blur these boundaries -->

### [PRINCIPLE_4_NAME]
<!-- Example: IV. Model contracts are mandatory -->
[PRINCIPLE_4_DESCRIPTION]
<!-- Example: Every model enforces a dbt contract with full column descriptions, types, and tests; central config lives in meta (business key, dedup/PII/SCD columns); no surrogate keys -->

### [PRINCIPLE_5_NAME]
<!-- Example: V. Security & secrets -->
[PRINCIPLE_5_DESCRIPTION]
<!-- Example: No secrets committed to the repo or logged; least privilege for service principals; PII maskable in non-prod -->

## [SECTION_2_NAME]
<!-- Example: Tech Stack & Naming Constraints -->

[SECTION_2_CONTENT]
<!-- Example: Ingestion via Meltano only (no seeds for source data); dbt on the fabric-spark adapter; fixed layer-naming prefixes; out-of-scope stages explicitly listed -->

## [SECTION_3_NAME]
<!-- Example: Development Workflow -->

[SECTION_3_CONTENT]
<!-- Example: Spec → Plan → Tasks → Implement per dataset/pipeline change, organized by dataset/entity rather than by user story; dbt build + contract resolution must pass before done -->

## Governance
<!-- Example: Constitution supersedes ad-hoc practice; amendments require updating this file and AGENT.md together -->

[GOVERNANCE_RULES]
<!-- Example: All plans/reviews must verify compliance; complexity must be justified; see AGENT.md for full rationale and roadmap -->

**Version**: [CONSTITUTION_VERSION] | **Ratified**: [RATIFICATION_DATE] | **Last Amended**: [LAST_AMENDED_DATE]
<!-- Example: Version: 1.0.0 | Ratified: 2026-09-07 | Last Amended: 2026-09-07 -->
