# 002 — every Linux release the fleet runs

**What and why. No technology.** Every decision about *how* lives in [plan.md](plan.md). If a
sentence here names a tool, it is a bug. Distribution releases are named: they are the targets,
not the means.

| | |
|---|---|
| Status | **draft** |
| Written | 2026-10-06 |
| Amends | [001](../001-linux-devops-tools/spec.md): N-02, FR-006, FR-007, SC-003, SC-014, A-01 and the last out-of-scope line |
| Source of truth for intent | **this file** |

---

## Overview

The environment refuses every machine that is not one of two related distributions. The host
automation the same operator runs against the fleet — configuration, hardening, updates and
cluster deployment — has meanwhile learned four Linux families and twelve releases, each proven
on real machines before it shipped. An operator who lands on any of those other machines gets a
refusal where they expected their workstation.

This feature makes the environment follow the operator onto **every Linux release the fleet
runs**, with the same one command, the same idempotency and the same proof — and makes that proof
a gate on every change, not a claim.

## Problem statement

| # | Failure | Evidence | Cost |
|---|---|---|---|
| P1 | **The fleet moved; the workstation did not.** | The host automation supports thirteen releases across five families; this environment refuses three of the four Linux families outright. | 001's scenario S3 ("follow me") fails on most machines the operator actually reaches. |
| P2 | **The test gate stopped meaning anything.** | Every container test of every supported release failed within half a minute for weeks, for a reason unrelated to the code (parallel test runs corrupting each other's storage). The newest release ran in a tier allowed to fail. | Red was normal, so red was ignored; "allowed to fail" proved nothing about the release it named. |
| P3 | **The non-Debian path was never exercised, and it is wrong.** | On a machine without the Debian package database, a release published as a distribution package falls back to placing the *package file itself* where the executable belongs. | A run that "succeeds" and leaves a binary that cannot execute — the worst kind of failure, because it is silent. |

## Supported releases

The single list this feature is about. Every row is a **gate**: a failure on any one fails the change.

| Family | Release |
|---|---|
| Debian | Debian 12, Debian 13 |
| Debian | Ubuntu 22.04, Ubuntu 24.04, Ubuntu 26.04 |
| RedHat | AlmaLinux 9, AlmaLinux 10 |
| RedHat | Rocky Linux 9, Rocky Linux 10 |
| RedHat | Fedora 43, Fedora 44 |
| SUSE | openSUSE Leap 16.0 |
| Arch | Arch Linux (rolling) |

Thirteen releases. The first twelve are exactly the Linux rows of the fleet's host automation.
**Ubuntu 22.04 stays** although that automation dropped it: this environment supports and gates it
today, and its upstream support runs until 2027-04. Removing a working target is not part of this
feature.

## Goals

| # | Goal |
|---|---|
| G-01 | **One command, every fleet release.** The default set installs on every release above with no per-release manual step. |
| G-02 | **Nothing moves for the existing families.** Debian and Ubuntu machines end up exactly as they do today. |
| G-03 | **Proof is a gate.** Every release is exercised on every change; there is no tier that is allowed to fail. |
| G-04 | **Proof on real machines.** A release candidate is proven on the lab's real machines before it is declared ready, and the machines are returned to their known-good state afterwards. |
| G-05 | **Almost every Linux machine.** A derivative or an unlisted release of a supported family is served with that family's behaviour and an honest "untested" notice, instead of being refused. |

## Non-goals

| # | Not a goal | Why |
|---|---|---|
| N-01 | Non-Linux systems | The environment's tools are published for Linux. The fleet's one non-Linux family has no workstation use. |
| N-02 | Entitlement-gated enterprise releases as *tested* targets | Their images need subscriptions. Their free rebuilds (AlmaLinux, Rocky Linux; openSUSE Leap) stand in, exactly as in the host automation. They still run under FR-003. |
| N-03 | Changing *what* the default set contains | This feature changes where it installs, not what. |
| N-04 | Upgrading the system | 001 N-03 stands: installing is a decision, upgrading is a different one. FR-012 is the one rolling-release consequence. |

## User scenarios

Each scenario states the independent test that proves it.

**S1 — A RedHat-family machine (P1).** *As an operator on an AlmaLinux, Rocky Linux or Fedora
machine, I need the same command to produce my workstation, so that the family of the machine in
front of me does not decide whether I have my tools.* → *Test:* on a fresh machine of each RedHat
release, run the default set; every capability is present or reported as skipped with a reason, a
second run changes nothing, and a preview changed nothing.

**S2 — The existing families see no change (P1).** *As an operator on Debian or Ubuntu, I need
this feature to be invisible, so that adopting it is free.* → *Test:* on each Debian-family release,
the fingerprint of installed packages, package sources and binary directories after the default
set is identical with and without this feature.

**S3 — Every change is proven on every release (P1).** *As the maintainer, I need every release
exercised automatically on every change, with no allowed-to-fail tier, so that green means the
environment works everywhere it claims to.* → *Test:* the change pipeline runs one test per
supported release, in parallel, and a failure planted in any single one fails the pipeline.

**S4 — A release candidate is proven on the lab (P1).** *As the maintainer, I need a candidate
proven on a real machine of every release before I call it ready, so that what the container test
cannot see (a real init system, real access control, real disks) is still covered.* → *Test:* for
each lab machine: restore its baseline, run the default set twice, record the evidence, restore
the baseline; the evidence shows a zero-change second run on every machine.

**S5 — SUSE and Arch (P2).** *As an operator on openSUSE Leap or Arch Linux, I need the same
environment.* → *Test:* as S1, on those releases — and on the rolling release, the system is never
left partially upgraded.

**S6 — A machine that is not on the list (P2).** *As an operator on a derivative (for example a
desktop spin of a supported release) or a release one version off the list, I need the environment
to work as for its family and to tell me it is untested; on a machine of an unknown family I need
a clear refusal.* → *Test:* with injected release identifications, a derivative of each family runs
with one "untested" notice, and an unknown family is refused before any change.

### Edge cases

- **A vendor publishes no package source for a family.** The capability uses the distribution's own
  package, or a verified release artifact, or skips with a reason (FR-009).
- **A package exists only in the family's standard add-on repository.** Enabling that repository is
  reported as a change; it is the same decision the environment already makes for the Debian
  family's add-on component (FR-010).
- **The same capability has a different package name, service name, administrator group, trust
  store or path on another family.** Resolved from declared data, never by the operator (FR-007).
- **Mandatory access control is enforcing.** Everything the environment installs works under it; it
  is never switched off (FR-011).
- **A rolling release whose package index is behind the archive.** Installing would require a full
  system upgrade; the environment says so and proceeds only under the existing upgrade opt-in
  (FR-012).
- **A capability that only means something on one family** (removing a predecessor's desktop
  packages; installing a browser's system libraries through a Debian-only helper). It declares its
  applicability and reports "not applicable" elsewhere (FR-014).
- **A release that needs a newer processor level** (the 10-series enterprise rebuilds). The test
  and lab machines provide it; a machine that lacks it is outside this feature.
- **Two test runs at once.** They must not influence each other (FR-018) — P2's cause.

## Functional requirements

### The supported set

- **FR-001** The environment must support every release in *Supported releases* as a first-class
  target: the default set installs with no per-release manual step. *(Amends 001 N-02, FR-006,
  SC-003, A-01.)*
- **FR-002** The supported set must be declared **once**, as data, and that one declaration must
  drive both the run-time gate and the automated test matrix, so the two cannot disagree.
- **FR-003** A machine whose family is supported but whose release is not listed — a newer or older
  release, an entitlement-gated enterprise release, or a derivative that declares itself a member
  of the family — must run with that family's behaviour and exactly one notice that it is untested.
  It must never be reported as tested.
- **FR-004** A machine whose family is not supported must be refused before any change, with a
  message listing the supported set. *(Keeps 001 FR-007.)*
- **FR-005** Family and release must be determined by observing the machine's own release
  identification, including derivative declarations — never by an operator hint. *(Keeps 001
  FR-005.)*

### Parity across families

- **FR-006** Every capability of the default set must be present on every supported release, or
  recorded as a skip naming its reason — no artifact for this family or architecture, or not
  applicable to this family. A skip must never be silent and never fail the run. *(Extends 001
  FR-008.)*
- **FR-007** Where a family names a package, service, group, path, trust store or package source
  differently, the difference must be resolved from declared data. Each capability keeps **one**
  description of what it installs; a family difference is data, not a second copy of the
  capability.
- **FR-008** On the Debian family the change must be behaviour-neutral: the same packages, files
  and package sources as before, and no existing gate may regress.
- **FR-009** A third-party package source must be added only in the family's native form, with its
  signing key verified as today (001 FR-017). Where the vendor publishes no source for a family, the
  capability must use the distribution's own package or a verified release artifact, or skip with a
  reason.
- **FR-010** Enabling a family's standard add-on repository because a capability needs it must be
  reported as a change, and must be the same class of decision as enabling the Debian family's
  add-on component today.
- **FR-011** Mandatory access control must stay enforcing, and everything installed must work under
  it. The environment must never disable or relax it.
- **FR-012** On a rolling release the environment must never leave the system partially upgraded.
  When an install cannot proceed without a full system upgrade, the run must say so and perform it
  only under the existing explicit upgrade opt-in; otherwise the capability is a skip with that
  reason.
- **FR-013** Guidance about elevation and trust — which group grants administrator rights, how to
  add the operator to it, how to refresh the certificate trust store — must name the mechanism that
  is correct for the machine's family.
- **FR-014** A capability that only applies to some families must declare that applicability, and
  be reported as "not applicable" on the others — never attempted and never failed.
- **FR-015** A tool published as a family-specific package must be installed through that family's
  package mechanism, or from a neutral archive of the same release. A package file must never be
  placed where an executable belongs. *(P3.)*

### Proof

- **FR-016** Every supported release must be exercised by automated tests on every change: a full
  install, a second install that changes nothing (001 SC-001) and a preview that changes nothing
  (001 SC-002).
- **FR-017** Every supported release is a gate. There is no allowed-to-fail tier: a release becomes
  supported by entering the gate, and a candidate release stays off the list until it can.
- **FR-018** Concurrent test runs must not influence each other's outcome.
- **FR-019** Before a version is declared ready, the release candidate must be proven on the lab's
  real machine for every supported release that has one: restore the machine's known-good baseline,
  run the default set twice, record the evidence, restore the baseline. A failure blocks the
  release. A release with no lab machine is proven by the automated tests alone, and the evidence
  says so.
- **FR-020** The evidence per machine must record the candidate revision, the first run's outcome
  and change count, the second run's change count, every skip with its reason, and the outcome of
  the final restore.
- **FR-021** Lab-specific identifiers — machine names, addresses, credentials, and the evidence log
  that carries them — exist only in the internal variant. The public variant receives the behaviour
  and the automated gate, never the lab material. *(Keeps 001 FR-027.)*
- **FR-022** The internal variant is the reference. The public variant receives this feature only
  after the internal gate (FR-016/017) and the lab proof (FR-019) have passed on the same revision.

## Success criteria

| # | Criterion |
|---|---|
| **SC-001** | On one revision, the automated matrix passes for **all 13 releases**: install, a second install with zero changes, and a preview with zero changes. 13 of 13, no allowed failure. |
| **SC-002** | On the release-candidate revision, the lab proof passes on **every lab machine of a supported release**: a zero-change second run on each, and each restored to its baseline afterwards. Evidence recorded per FR-020. |
| **SC-003** | For each of the five Debian-family releases, the installed-package, package-source and binary-directory fingerprint after the default set is **identical** before and after this feature. |
| **SC-004** | The release gate is proven offline, with injected release identifications, for every supported release (accepted), a derivative of each family (accepted, with exactly one "untested" notice) and an unsupported family (refused, nothing changed). |
| **SC-005** | On every non-Debian release, every capability that is not installed appears in the run summary as a skip with a reason. Silent no-ops: **zero**. |
| **SC-006** | The supported set is declared once. An automated check fails if a release appears in the run-time gate but not in the test matrix, or the reverse. |
| **SC-007** | The pipeline contains **no** allowed-to-fail job over a supported release. |
| **SC-008** | All matrix tests run concurrently and pass; re-running the same revision gives the same result. |
| **SC-009** | No release-artifact install leaves a package file in place of an executable: every installed executable runs and reports its pinned version on every release. |

## Assumptions

| # | Assumption | If it is wrong |
|---|---|---|
| A-01 | The lab has a real machine with a restorable known-good baseline for each supported release except Ubuntu 22.04. | FR-019 falls back to the automated proof for that release, and the evidence says so. |
| A-02 | Test containers are minimal and lack what a real machine has — an init system, real access control, real disks. | That gap is exactly what the lab proof (FR-019) covers. |
| A-03 | Upstream publishers ship artifacts for most families and both architectures, but not all. | FR-006 turns each gap into a recorded skip. |
| A-04 | A rolling release is a moving target; a proof is valid for the day it was taken. | The automated matrix re-proves it on every change. |
| A-05 | On the RedHat and SUSE families the operator's administrator rights come from the family's administrator group. | FR-013 names it; 001 FR-016 still degrades to skips without elevation. |
| A-06 | The fleet's host automation is the reference for the family list and for how family differences are expressed. | The list here is reconciled with it each time it changes. |

## Out of scope

- Non-Linux systems.
- Entitlement-gated enterprise releases as tested targets (they run untested under FR-003).
- Releases that are end of life upstream.
- Upgrading installed packages or the system, beyond FR-012's opt-in path.
- Changing which capabilities make up the default set.
