# Pipeline Specification: [DATASET / PIPELINE CHANGE NAME]

**Branch**: `[###-short-name]`

**Created**: [DATE]

**Status**: Draft

**Input**: User description: "$ARGUMENTS"

## Overview

[One paragraph: what dataset or pipeline capability is being added or changed, and why — business/analytics value, not implementation.]

## Source & Ingestion

- **Source system**: [e.g., Contoso 1M CSV export, Oracle HR schema, Kafka topic `orders.v1`]
- **Extraction method**: [Meltano extractor, e.g. `tap-csv`; NEEDS CLARIFICATION if not yet chosen]
- **Load pattern**: [Initial full load / incremental delta load / both — reference the delta-load simulator if relevant]
- **Expected volume & frequency**: [row counts, file sizes, load cadence]
- **Landing format**: [file format, encoding, schema stability expectations]

## Entities & Data Contract

<!--
  IMPORTANT: Entities should be PRIORITIZED by delivery order (P1, P2, P3...).
  Each entity's full slice (bronze → silver → gold → serving) must be INDEPENDENTLY
  TESTABLE and DEPLOYABLE — landing one entity end-to-end is a viable increment,
  even before later-priority entities are onboarded.
-->

### Entity 1 - [Name, e.g. "customers"] (Priority: P1)

**Business key**: [column(s) that uniquely identify a record]

**Why this priority**: [value of onboarding this entity first]

**Grain**: [one row per ...]

**Key columns** (high level, not full DDL): [column: type — short description, ...]

**PII columns**: [columns requiring anonymization in non-prod, or "none"]

**Independent test**: [e.g., "Can be fully ingested and built through gold independently of other entities, and validated by querying N known records"]

**Acceptance scenarios**:

1. **Given** a fresh initial load, **When** the pipeline runs, **Then** [expected row count / shape in each layer touched]
2. **Given** a delta load with new and updated records, **When** the pipeline reruns, **Then** [expected upsert/append behavior per layer]

---

### Entity 2 - [Name] (Priority: P2)

[Same structure as Entity 1]

---

[Add more entities as needed, each with an assigned priority]

## Layer Placement & Transformations

- **Bronze**: dedup strategy (business key + dedup columns), any source quirks affecting append-only ingestion
- **Silver**: type casting, renaming, enrichment from existing columns/lookups (no cross-model joins — flag anything that seems to need one, it belongs in gold)
- **Gold**: business logic, cross-entity joins, relational (not dimensional) modeling
- **Serving**: consumers, exposure needs, row-level security requirements (or "none for this change")

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST [specific capability, e.g., "append new bronze records only when the business key + dedup columns are not already present"]
- **FR-002**: The pipeline MUST [e.g., "cast [column] from string to date in silver"]
- **FR-003**: The model MUST [e.g., "enforce a dbt contract with tests on [business key]"]

*Example of marking unclear requirements:*

- **FR-004**: The pipeline MUST handle late-arriving records for [NEEDS CLARIFICATION: no watermark/ordering strategy specified]

### Data Quality & Non-Functional Requirements

- **NFR-001**: Reruns MUST be idempotent — no duplicate rows in bronze after repeated runs on the same source data
- **NFR-002**: New source columns MUST NOT break existing consumers (additive schema evolution)
- **NFR-003**: [freshness/SLA requirement, if any]
- **NFR-004**: [PII handling requirement in non-prod, if applicable]

### Edge Cases

- What happens when a record with a known business key arrives with a **different** value in a non-dedup column (i.e., a genuine update)?
- What happens when the source introduces a **new column**?
- What happens when the source **removes or renames** a column?
- What happens with **duplicate business keys within the same load batch**?
- What happens with **null/malformed values** in the business key?

## Success Criteria *(mandatory)*

<!-- Measurable and verifiable. Data-quality/freshness/volume metrics belong here — they are the point, not an "implementation detail" to avoid. -->

- **SC-001**: [e.g., "Initial load completes with 100% of source rows present in bronze"]
- **SC-002**: [e.g., "Rerunning the initial load produces zero duplicate business keys in bronze"]
- **SC-003**: [e.g., "A simulated delta load with N new + M updated records results in exactly N new bronze rows and M correctly-versioned silver rows"]
- **SC-004**: [e.g., "All gold columns for this entity resolve a dbt contract with zero test failures"]

## Assumptions

- [Assumption about source stability, e.g., "source schema is append-only stable between loads unless stated otherwise"]
- [Assumption about scope boundaries, e.g., "cross-entity gold joins are out of scope until both entities exist in silver"]
- [Dependency on existing pipeline components, e.g., "reuses the existing `dedup_before_insert` macro"]
