# 001 — devops-env-config

**What and why. No technology.** Every decision about *how* — architecture, interfaces,
mechanisms, tooling — lives in [plan.md](plan.md). If a sentence here names a tool, it is a bug.

| | |
|---|---|
| Status | **implemented** (the repository is the derived artifact of this spec) |
| Written | 2026-09-10 |
| Supersedes | the ad-hoc provisioning scripts of the predecessor repository |
| Source of truth for intent | **this file**. For behaviour: the code, mapped in [plan.md](plan.md) |

---

## Overview

One command turns a fresh machine into the DevOps workstation this repository describes, and
keeps describing it. The machine may be a virtualised Linux distro on a Windows host, a
hypervisor guest, a cloud instance or a container; it is reached over a terminal and has no
screen. Running the command a second time is a no-op.

The unit of value is not the tool list. It is **the tool list being true** — that what an
operator actually ends up with is what the repository says, on every machine, after every run.

## Problem statement

The predecessor was a set of scripts that provisioned one specific machine once. Three failures
made it unusable as a description of that machine, and a fourth made it unusable on any other.

| # | Failure | Evidence at the time of the rework | Cost |
|---|---|---|---|
| P1 | **Ad-hoc installs were never captured.** Tools acquired by hand after the last script edit existed only on the machine. | 13 cluster plugins installed, 9 in the scripts. 19 language-toolchain binaries installed, 7 in the scripts. 15 alternate-package-manager leaves, 0 in the scripts. 24 system packages installed by hand, 0 in the scripts. The entire cluster-client plugin/hotkey/theme layer: **hand-made, zero of it in the repository.** | The repository could not rebuild the machine it described. A lost machine was a week of archaeology. |
| P2 | **Single platform, hardcoded.** The scripts assumed one distribution, one release codename, one host integration. | A repository-repair script hardcoded one release codename and would have rewritten a sibling distribution's package sources to point at the wrong archive. | The environment could not follow the operator onto a server, a guest or a build agent. |
| P3 | **Re-running damaged the machine.** The scripts appended, overwrote and purged unconditionally. | An in-place edit of the shell profile replaced a symlink with a regular file, silently detaching it from the repository that owned it and leaving it 43 lines adrift. Duplicate profile lines accumulated per run. A cache measured in gigabytes was deleted on every run. A recursive ownership change ran across the whole home directory. | Nobody dared re-run it, so drift compounded — which is P1 again. |
| P4 | **The workstation gained a screen it did not need, and lost the login it did.** A graphical layer was built from source for a machine with nothing to draw on, while the flows that genuinely need a browser had no path at all. | A compositor compiled from an abandoned fork; a 449 MB browser that cannot run on half the target machines. Meanwhile the clipboard helpers on the reference machine were **already broken** — all four resolved to nothing. | Hundreds of megabytes and minutes of build time for nothing, and interactive identity-provider logins that could not be completed from the machine at all. |

P1–P3 compound: because a re-run was dangerous, drift was never reconciled; because drift was
never reconciled, the repository stopped being trusted; because it was not trusted, the next
tool was installed by hand.

## Goals

| # | Goal |
|---|---|
| G-01 | The repository is a **complete and current** description of the workstation. Anything installed is described; anything described is installed or explicitly excluded with a reason. |
| G-02 | **One description, many machines.** The same command produces the same environment on either supported distribution, on physical, virtual, virtualised-under-Windows and containerised hosts. |
| G-03 | **Re-running is boring.** A second run changes nothing, and a first run never destroys work the operator did not create. |
| G-04 | **Terminal-only, and still able to log in.** No graphical environment is installed, and every browser-based identity flow the operator needs still completes from the machine. |
| G-05 | **Publishable.** The repository can be public without leaking anything about the environment it is used to operate. |
| G-06 | **Diagnosable.** The operator can ask the machine what is wrong and get an answer with the remedy attached. |

## Non-goals

| # | Not a goal | Why |
|---|---|---|
| N-01 | Configuration management for a fleet | This provisions the operator's own machine. Fleet hosts are described elsewhere. |
| N-02 | Supporting distribution families beyond the two named | An unsupported machine must be refused clearly, not half-served. |
| N-03 | Keeping installed tools up to date over time | Installing is a decision; upgrading is a different one, and self-updating tools must be left alone. |
| N-04 | Being the operator's dotfiles | Personal shell configuration stays the operator's, in their own files, and must survive every run untouched. |
| N-05 | A graphical desktop, in any optional form | G-04. Removed, not made optional. |

## User scenarios

Each scenario states the independent test that proves it.

**S1 — Rebuild.** *As an operator, I need one command on a fresh machine to produce the
workstation the repository describes, so that losing a machine costs an hour instead of a week.*
→ *Test:* on a machine with nothing but the base system, run the command; every capability listed
in the documentation is present or reported as skipped with a reason.

**S2 — Reconcile.** *As an operator, I need to run the installer on a machine I have been using
for months and have it change only what is genuinely missing, so that I can keep the description
true without fear.* → *Test:* run on the reference machine; the run reports what it would change,
touches nothing the operator authored, and a second run reports no change at all.

**S3 — Follow me.** *As an operator, I need the same environment on a server I only reach over a
terminal, so that a remote session is not a downgrade.* → *Test:* the same command on the other
supported distribution, with no screen and no host integration, completes and skips only what
genuinely does not apply.

**S4 — Log in from nowhere.** *As an operator, I need to complete an identity-provider login for
my cluster from a machine with no browser and no display, so that terminal-only is not a
capability cliff.* → *Test:* from a headless session, authenticate against the identity provider
and read back the identity the cluster resolved.

**S5 — Capture.** *As an operator, I need the plugin, shortcut and theme layer of my cluster
client to be part of the repository, so that it is not re-invented on the next machine.*
→ *Test:* a fresh machine has the identical plugin, shortcut, alias and theme set, and no
shortcut is bound twice.

**S6 — Preview.** *As an operator, I need to see exactly what a run would do before it does it,
so that I can run it on a machine I care about.* → *Test:* the preview enumerates every mutation
and the machine is byte-identical afterwards.

**S7 — Diagnose.** *As an operator, I need the machine audited and the findings actionable, so
that "something is off" becomes a list.* → *Test:* the audit reports pass/warn/fail per check
with the remedy for each, and changes nothing unless repair is requested.

**S8 — Leave.** *As an operator, I need to remove what this installed without collateral damage,
so that adopting it is reversible.* → *Test:* the removal drops every file the tool owns, keeps
and reports every file the operator edited, and removes nothing it did not install.

**S9 — Publish.** *As an operator, I need to keep this repository public, so that it can be
shared and reviewed.* → *Test:* an automated gate finds nothing identifying a real environment,
and the gate itself is proven to still fire.

## Functional requirements

### Capture and description

- **FR-001** Every tool present on the reference machine at the time of the rework must be either
  installed by the environment or listed as excluded with a stated reason. No third state.
- **FR-002** The cluster client's plugin, shortcut, alias and theme layer must be shipped and
  installed by the environment, not created by hand on each machine.
- **FR-003** Every version the environment pins must be declared in exactly one place, and every
  declared version must name the unit responsible for installing it.
- **FR-004** The documentation must state, per tool, which unit installs it and where it comes
  from.

### Portability

- **FR-005** The environment must determine the distribution, release, host platform and
  processor architecture at run time. The operator must never have to declare them.
- **FR-006** Where the two supported distributions genuinely differ, the environment must resolve
  the difference itself; no per-distribution manual step may be required.
- **FR-007** On a machine outside the supported family, the environment must refuse with a message
  naming the reason and must change nothing.
- **FR-008** A capability with no artifact for the current platform or architecture must be
  recorded as a skip with a reason. It must never fail the run and must never silently install
  nothing.
- **FR-009** Host-integration behaviour must activate only when the host really provides it,
  determined by observation rather than by an environment hint that can be absent.

### Idempotency and safety

- **FR-010** A second run must change nothing on disk: no file written, no backup taken, no
  package installed.
- **FR-011** A preview mode must enumerate every mutation the run would make and perform none of
  them.
- **FR-012** The environment must never remove or overwrite a package, file or setting the
  operator installed or authored. A conflict must be reported with the command that resolves it,
  and left to the operator.
- **FR-013** Shell integration must be a single delimited region in one file, added once and
  removable in one step. Content must live in separate files that can be replaced wholesale.
- **FR-014** A configuration file intended for the operator's own values must be created once from
  a template and never overwritten, with permissions restricting it to its owner.
- **FR-015** A privileged or hard-to-reverse step must require its own explicit opt-in. A blanket
  "answer yes to prompts" must not imply any of them.
- **FR-016** Elevation must be requested only when a step that needs it actually runs. A machine
  where elevation is unavailable must still complete, recording those steps as skips with an
  actionable message.
- **FR-017** Every artifact fetched from the network must be integrity-verified against a
  published digest, or carry a recorded, human-readable exception.
- **FR-018** Removal must delete every file the environment owns unmodified, keep and report every
  file the operator has since edited, and remove nothing it did not install.

### Composition

- **FR-019** Capabilities must be grouped into named selectable sets, with one default set.
- **FR-020** Every capability must be individually runnable, in any subset, and in any combination
  of inclusion and exclusion — including on its own, to refresh just that layer.
- **FR-021** A capability must not assume another capability has run in the same session.

### Terminal-only operation and interactive logins

- **FR-022** No default set may install a graphical environment, compositor or graphical browser.
- **FR-023** Every browser-based identity flow the operator depends on — cluster authentication
  above all, plus the cloud, forge, delivery and secret-management providers — must be completable
  from a machine with no browser and no display.
- **FR-024** The mechanism that presents a login URL must: emit nothing on the channel its caller
  parses for structured data; never seize the terminal; and always report success to its caller,
  because callers treat failure as "no browser" and abandon the flow.
- **FR-025** The environment must offer copy and paste that work with no graphical clipboard,
  including over a remote terminal session, as executables usable from any context rather than
  only from an interactive shell.
- **FR-026** Where the machine *does* have a way to reach a browser, the mechanism must use it,
  choosing at the moment of use rather than at session start — the same configuration is used from
  sessions with different capabilities.

### Publishability

- **FR-027** No value identifying a real environment — host, domain, address range, realm, client
  identifier, cluster, context, credential or certificate payload — may appear anywhere in the
  repository, including comments, examples, tests and documentation. Reserved documentation values
  and placeholders only.
- **FR-028** The gate enforcing FR-027 must match on the *shape* of such a value, never on a list
  of the real ones — a list naming what must not leak is itself the leak.
- **FR-029** The gate must prove itself against planted synthetic violations, so that a rule which
  has stopped firing is detected.
- **FR-030** Real values must live only in operator-local files outside the repository, created by
  FR-014.
- **FR-031** Any capability that reaches an internal system must take its address from the
  operator's environment and skip silently when it is unset.

### Operation

- **FR-032** An audit must report pass/warn/fail per check with the remedy for each, and must
  change nothing unless repair is explicitly requested.
- **FR-033** A machine provisioned by the predecessor must be reportable: what it left behind,
  what is now redundant, and what to do about it — changing nothing until asked.
- **FR-034** Every run must end with what changed, what was skipped and why, and the exact next
  steps.
- **FR-035** The set of capabilities, their membership of each named set, and their applicability
  conditions must be printable in a form another program can consume.

## Success criteria

Measurable, and every one of them is checked by automation unless stated otherwise.

| # | Criterion |
|---|---|
| **SC-001** | A second run leaves the machine byte-identical: a fingerprint of installed packages, shell configuration, package sources and both binary directories is unchanged. |
| **SC-002** | A preview run leaves that same fingerprint unchanged, measured *before* the preview and again after. |
| **SC-003** | The environment installs on **both supported distributions**, across four supported releases, with **no per-distribution manual step**. |
| **SC-004** | Loading the shell configuration twice in one session produces no duplicated entry in the executable search path. |
| **SC-005** | Every tool in the pre-rework machine inventory resolves to either an installing unit or an exclusion entry with a reason. Unexplained entries: **zero**. |
| **SC-006** | The cluster-client layer ships **57 plugins, 10 shortcuts, 64 aliases and 4 themes**, with no shortcut bound twice, no shortcut colliding with one the client itself defines, and no shortcut that depends on the operator's keyboard layout. |
| **SC-007** | On a machine with no display, the login mechanism selects its print path, writes nothing to the channel its caller parses, and reports success — *including inside a terminal multiplexer that advertises a display which does not exist*. |
| **SC-008** | A full identity-provider login for a cluster completes from a headless remote session using only one documented port forward, and the resulting identity is readable back from the cluster. |
| **SC-009** | The publishability gate reports no finding on the repository, and every one of its rules is proven to still fire against a planted synthetic violation. |
| **SC-010** | No version is pinned anywhere outside the single declaration file, and every pin there names its owning unit. |
| **SC-011** | No elevation is requested before the first step that needs it; on a machine with no elevation path the run completes successfully with those steps recorded as skips. |
| **SC-012** | Removal leaves no file the environment owns and deletes no file the operator edited; both counts are reported. |
| **SC-013** | Starting an interactive shell costs under 0.20 s on the reference machine, against a 0.57 s baseline before the rework. |
| **SC-014** | On an unsupported distribution the run exits with a message naming the reason and the machine fingerprint is unchanged. |
| **SC-015** | Every artifact fetched from the network is either digest-verified or carries a recorded exception; a run with an unverifiable artifact and no recorded exception fails. |

## Assumptions

| # | Assumption | If it is wrong |
|---|---|---|
| A-01 | The machine runs one of the two supported distribution families and has network access to public package archives and release hosts. | FR-007 refuses it. |
| A-02 | The operator has an elevation path, or is the superuser. | FR-016 degrades to skips rather than failing. |
| A-03 | The processor architecture is the primary one the environment is tested on; a secondary architecture is best-effort. | FR-008 records skips where an upstream publishes no artifact. |
| A-04 | The operator's own shell configuration may already be managed by another repository, possibly through a symlink. | FR-012/FR-013 must write through it, never replace it. This is not hypothetical: it is exactly what P3 destroyed. |
| A-05 | A tool that manages its own updates should be installed and then left alone. | N-03. |
| A-06 | Where the machine is virtualised under a host operating system, that host's browser is the operator's real browser — it holds the sessions, the password manager and the hardware authenticator. | FR-026 prefers it over anything installed locally. |
| A-07 | The identity provider enforces proof-key exchange on public clients. | Constrains which grant types can be used at all; see plan.md. |

## Out of scope

- Provisioning anything other than the operator's own workstation.
- Upgrading packages already installed, other than by explicit request.
- Any graphical layer, in any form, including an optional one.
- Managing the operator's cluster credential files or merging them.
- Managing the external repositories that own the operator's editor, multiplexer and prompt
  configuration; the environment may place them and must never edit them.
- Distribution families outside the two supported ones.
