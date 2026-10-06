# Specification quality checklist — 002 multi-distro support

Gate before [plan.md](../plan.md). Every item must hold; a failed item stops planning.

## Content quality

- [X] No implementation detail: no package manager, repository format, script, file path or CI
      product is named. Distribution releases are named because they are the targets.
- [X] Written for the operator and the maintainer: every requirement says what must be true, not
      how it is made true.
- [X] Every mandatory section is present: overview, problem, goals, non-goals, scenarios, edge
      cases, requirements, success criteria, assumptions, out of scope.
- [X] Public-safe: no lab machine name, address, credential or internal host appears (FR-021).

## Requirement completeness

- [X] No `[NEEDS CLARIFICATION]` marker remains. The four open decisions were settled with the
      operator on 2026-10-06: the release set (the twelve fleet releases plus Ubuntu 22.04), every
      release a hard gate, container matrix plus lab proof, and per-job test isolation.
- [X] Every requirement is testable: each FR maps to an SC or to a scenario's independent test.
- [X] Success criteria are measurable (counts, zero-diff fingerprints, 13 of 13) and
      technology-agnostic.
- [X] Scope is bounded: supported set, non-goals and out-of-scope list agree with each other.
- [X] Edge cases cover every family difference the host automation recorded: vendor sources,
      add-on repositories, naming, access control, rolling release, family-only capabilities,
      processor level, concurrent tests.
- [X] Dependencies and assumptions are stated (lab machines, minimal containers, upstream artifact
      gaps, the host automation as reference).

## Amendments to 001

- [X] Each amended 001 item is named in the header: N-02, FR-006, FR-007, SC-003, SC-014, A-01 and
      the last out-of-scope line. 001 is updated to point here when this feature ships.

## Traceability

| Requirement | Proven by |
|---|---|
| FR-001, FR-006, FR-016 | SC-001, S1, S5 |
| FR-002 | SC-006 |
| FR-003, FR-004, FR-005 | SC-004, S6 |
| FR-007, FR-009, FR-010, FR-013 | SC-001, SC-005 |
| FR-008 | SC-003, S2 |
| FR-011 | SC-002 (enforcing machines in the lab) |
| FR-012 | S5, SC-001 (rolling release row) |
| FR-014 | SC-005 |
| FR-015 | SC-009 |
| FR-017 | SC-007, S3 |
| FR-018 | SC-008 |
| FR-019, FR-020 | SC-002, S4 |
| FR-021, FR-022 | the public-variant port, reviewed against 001 FR-027 |
