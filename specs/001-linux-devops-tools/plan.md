# 001 — linux-devops-tools: implementation plan

**How.** Every technical decision behind [spec.md](spec.md). Where the build diverged from the
original design, this plan records **what shipped**, not what was proposed.

**Source of truth:** the code. `versions.env` owns every pin, `profiles/*.list` own set
membership, the `# meta:` header of each `modules/NN-*.sh` owns its gates, and the header of
[`bin/devenv`](../../bin/devenv) owns the module contract. This file explains *why* they are
shaped that way. Verified against the checkout on **2026-09-10**.

---

## Summary

A single bootstrapper clones the repository and hands off to one runner. The runner resolves a
**plan** — an ordered list of **modules** — from a **profile**, then executes each module as a
child process. Modules are numbered, independent, individually runnable, and gated on facts
detected at run time. All shared behaviour lives in a sourced shell library whose single most
important function is the mutation gate that makes preview mode honest.

| | |
|---|---|
| Implementation language | POSIX-ish `bash`, no runtime dependency beyond `curl`/`wget`, `git`, `tar` and coreutils |
| Runner | `bin/devenv` (996 lines) — argument parsing, plan resolution, module execution, summary |
| Bootstrapper | `install.sh` (474 lines) — the only URL that is a public contract |
| Library | `lib/*.sh`, 12 files, ~4 550 lines, sourced through `lib/common.sh` only |
| Units | `modules/NN-name.sh`, 28 modules, ~7 800 lines |
| Shipped data | `config/` — shell fragments, cluster-client layer, browser/SSO shims, templates |
| Tests | policy + privacy gates, unit tests, a four-image container matrix |

## Constraints from the environment

These are not preferences. Each one killed a design option.

| # | Constraint | Consequence |
|---|---|---|
| E1 | **No runtime dependency beyond a shell and a fetcher.** A minimal install of the second distribution has no key-management tooling, no structured-data CLI and no interpreter beyond the system one. | Signing keys are stored **armored, never converted** — which removes the key tool from the dependency set entirely. The cluster-layer validator is written in `bash`+`awk`, not the interpreter the design assumed. |
| E2 | **The public curl-to-shell URL is a contract.** People have it in notes. | `install.sh` stays small and self-contained, sources nothing, and forwards every unknown argument to the runner. Sub-scripts are never piped again. |
| E3 | **The shell profile may be a symlink into another repository's worktree.** It is, on the reference machine. | Every writer resolves and writes *through* a symlink. In-place stream editing under `$HOME` is banned and grepped for — it is what severed that symlink and caused 43 lines of drift. |
| E4 | **The host-integration hint is unreliable.** The variable everyone tests for is unset in the reference machine's own shell; it exists only under one launcher. | Platform detection reads the filesystem, never the environment. |
| E5 | **Host executables may be unreachable by name even while host integration works.** Verified: four host commands unresolvable, integration enabled. | Host calls resolve an absolute path at run time, deriving the mount prefix from the host-integration configuration rather than assuming the conventional one. |
| E6 | **A terminal browser is the system default browser.** The generic open-a-URL chain ends at it, and it seizes the terminal. | The URL opener never delegates into that chain and shadows those names on the user's own path. |
| E7 | **The multiplexer configuration advertises a display unconditionally.** It comes from an external repository this one must not edit. | The graphical-session probe must not trust the display variable alone. A snippet is shipped and the fix documented upstream; the file is never edited. |
| E8 | **Package removal is off the table.** Conflicting packages on the reference machine were installed deliberately by the operator. | `pkg_remove`/`pkg_purge` are **report-only**. Conflicts print the command; the operator runs it. |
| E9 | **The repository is public and the operator's estate is not.** | A structural gate, self-tested, that names no real value. |
| E10 | **Two archives that disagree.** One vendor publishes no build for the newer release of the second distribution; another answers `200` with an empty index for three suites. | Suites are *resolved*, per vendor, with vendor-specific fallback logic — not driven from a shared table. |

## Architecture

```
curl … | bash ─▶ install.sh ──┬─ refuses root, refuses a non-checkout target
   (public URL)               ├─ clone/fast-forward → $DEVENV_HOME  (tarball fallback, no git)
                              ├─ reattaches stdin to the tty
                              └─ exec bin/devenv "$@"
                                        │
                    ┌───────────────────┴───────────────────┐
                    ▼                                       ▼
             lib/common.sh                            lib/registry.sh
     (sources all 12 lib files, loads          module_list → module_resolve → resolve_plan
      versions.env, installs traps)                        │
                    │                                      ▼
        ┌───────────┴───────────┐              run_module: child process, exported env
        ▼                       ▼                      0 ok · 78 skip · * fail
    lib/run.sh              lib/fs.sh                        │
  THE MUTATION GATE     every filesystem write               ▼
  run · run_sudo        write_if_changed · write_managed   summary_print
  confirm_dangerous     ensure_block_in_file · manifest
```

**Everything mutating passes through one of two places** — `run`/`run_sudo` in `lib/run.sh`, or a
writer in `lib/fs.sh` that consults the same gate. That single fact is what makes `--dry-run` a
true no-op and makes the container test's before/after fingerprint an honest assertion.

## Key decisions

| # | Decision | Alternative rejected | Why |
|---|---|---|---|
| D1 | **Clone once, then execute locally.** | Curl-pipe each sub-script; or fetch each shipped file over HTTP on demand. | One fetch instead of 30+. A ref makes an install reproducible. Shipped data (57 plugin definitions, 4 themes, 10 shell fragments) lives on disk instead of inside heredocs, and sub-scripts get a real stdin so prompts work. The public URL is unchanged. |
| D2 | **Modules are child processes with a comment header, run in filename order.** | A dependency graph; or sourced functions in one process. | No graph to get wrong and no module can corrupt the runner's state. The header is parsed with one `sed` over the first 40 lines — the file is never sourced to learn about it, so `list` is safe on a broken module. A module must never assume another ran. |
| D3 | **Exit `78` means "precondition missing".** | Returning success on a skip; or failing the run. | A skip is a first-class outcome with a reason in the summary. Wrong distribution, wrong architecture, missing prerequisite, or no elevation available — all skips, never failures. |
| D4 | **One delimited region in the shell profile; content in numbered drop-in files.** | Appending lines; a single monolithic environment file. | Appending is what produced duplicate lines every run. Drop-ins can be replaced wholesale, pruned per module and diffed. `90-local.sh` is created empty once and never touched again — the operator's escape hatch. |
| D5 | **Package sources are deb822 with armored keys, written only on change.** | Legacy one-line sources; converting keys to binary form. | Armored keys have been accepted since long before every supported release, which removes the key tool from the dependency set (E1). Content-compare before write is what makes the second run silent. |
| D6 | **Suites are resolved per vendor, in code.** | A declarative table of vendor → suite. | Three vendors need genuinely different logic: one steps down its own published list, one uses a verified allowlist because empty indexes answer `200`, one maps a release to a *sibling distribution's* codename for library-ABI reasons. A half-expressive table would be worse than five small functions. |
| D7 | **Every Python CLI gets its own isolated environment from one tool.** | User-level installs; a second installer; disabling the interpreter's external-management marker. | Removing that marker is not durable — it is owned by a system package and a routine upgrade restored it on the reference machine one day later, leaving a stray file behind. The chosen tool brings its own interpreter, so the older distribution's version stops mattering. |
| D8 | **The node version manager is kept, relocated and lazy-loaded.** | Replace it with a general-purpose version manager. | The measured 0.20 s per-shell cost that motivated replacement is removed by a six-line lazy shim. The replacement is in no archive and would have been a third version manager on the default path. |
| D9 | **Completions are generated once at install time into a cache, loaded on first use.** | Nine `source <(… completion)` lines at shell start. | Measured 0.23 s per interactive shell. The cache is regenerated only when it is missing, empty or older than the resolved binary. Tools with no completion subcommand are excluded rather than caching failure output. |
| D10 | **The cluster-client layer is copied and tracked in a manifest.** | Symlinking it out of the checkout. | The checkout can be replaced wholesale by an update, which would dangle every symlink; and an operator edit through a symlink dirties this repository. The manifest additionally distinguishes "ours, unmodified" (overwrite freely) from "hand-edited" (back up and warn). |
| D11 | **The client's own settings file is merged, not created-if-absent.** | Create-if-absent with a `.new` sidecar. | The client rewrites that file itself on exit and it already existed on the reference machine, so create-if-absent would have meant the settings never landed. Aliases and shortcuts merge missing top-level keys; nothing the operator wrote is replaced. |
| D12 | **Plugins are installed one at a time after a single index update.** | One batch call. | The batch path returns non-zero if any single plugin fails, which under strict mode kills the run for one transient upstream error. Per-plugin is still idempotent, and failures are collected and warned while the module still succeeds. |
| D13 | **Keep both members of two tool pairs that look like duplicates.** | Deduplicate to one of each. | They are different programs: one execs into a node agent (which six shipped plugins call), the other reports status. Removing either breaks the shipped layer on day one. The audit warns on version skew instead. |
| D14 | **One URL opener, reached three ways, choosing its backend at the moment of use.** | Exporting a browser variable and stopping there. | The highest-priority consumers — cluster authentication and the secret-manager CLI — **ignore** that variable entirely and exec the generic opener names directly. So the opener is also installed under four generic names ahead of the system ones. Resolving the backend at call time (not at shell start) costs nothing per shell and stays correct when one configuration is used from sessions with different capabilities. |
| D15 | **The desktop layer is deleted, not made optional.** | An opt-in desktop module. | A compositor has nothing to draw on; a graphical browser cannot run on half the target machines and, where it can, it is strictly worse than the host's browser, which holds the real sessions and hardware authenticator. The browser-automation dependency set is *not* desktop residue and moved to its own explicit module. |
| D16 | **Conflicting packages are reported, never removed.** | Purge before install, as the vendor instructions say. | E8. The operator installed them deliberately. Removal needs its own opt-in and still only ever happens by the operator's hand. |
| D17 | **The publishability gate is structural and self-testing.** | A denylist of the estate's real values. | A denylist naming the secrets is itself the leak, in a public file. Matching on shape means the gate works unchanged in a fork and is proven by planting synthetic violations rather than real ones. |
| D18 | **The run-twice byte-identical container assertion is the primary test.** | Unit tests alone. | It is the only test that can actually prove idempotency, and idempotency is the property the whole rework exists to establish. |

## Modules and profiles

**28 modules**, numbered by run order; `NN` is order and nothing else. Membership authority is
`profiles/*.list`; the `profiles=` meta key is documentation that `devenv list` displays.

| range | modules | notes |
|---|---|---|
| 00–05 | preflight, base-packages | support check, XDG dirs, legacy source migration, the one base package list |
| 10–15 | shell, git | the profile region, 10 drop-in fragments, prompt, completion cache; git config **set-if-absent, report-only by default** |
| 20–28 | lang-go, lang-rust, lang-node, lang-python, repo-dev | one module per toolchain; `repo-dev` is what this repository's own CI needs |
| 30–38 | containers, kubernetes, k8s-plugins, k9s-config, **auth-sso** | the headline work: the cluster tool set, the plugin roster, the shipped client layer, and the browser/login shims |
| 40–58 | iac, cloud, editors, media, headless-browser | `headless-browser` is in **no** profile |
| 65 | **ai** | Claude Code as a **base** install via its native installer; other agents opt-in |
| 70–85 | wsl, private, personal | `wsl` is a no-op unless the platform probe says otherwise; `private` is entirely environment-driven |
| 90–99 | doctor, purge-desktop, migrate, brew, summary | `purge-desktop` and `migrate` are in **no** profile |

**Profiles** (`minimal`, **`devops`** default, `full`, `ci`, `ai`, `private`, `personal`) are plain
lists of module names. `full` additionally turns on three feature gates, because a list cannot set
a variable — the runner does it, and only when the operator has not already set them.

`ci` is the container-test profile: everything a container can genuinely do — dotfiles, package
sources, release binaries — minus the daemon, the init system, the host integration and the
interactive login helpers.

## Library API

Twelve files, sourced only through `lib/common.sh`, which also loads `versions.env` with `set -a`
so every pin is exported into every module. Full contracts in [`lib/README.md`](../../lib/README.md).

| file | owns |
|---|---|
| `common.sh` | globals, per-run temp dir, `versions.env`, the `ERR`/`EXIT` traps |
| `log.sh` | `log_*`, `die`, `skip` — the only two functions in the library that exit |
| `run.sh` | **the gate**: `run`, `run_sudo`, `run_quiet`, `is_dry_run`, lazy sudo, `confirm`, `confirm_dangerous`, `changed` |
| `os.sh` | the detection contract below |
| `fs.sh` | every filesystem mutation: `write_if_changed` (the default writer), `write_once`, `write_managed`, `ensure_block_in_file`, `ensure_line_in_file`, `symlink_file`, `yaml_map_merge`, `backup_file`, the manifest |
| `net.sh` | `download`, `verify_sha256`, `gh_latest_tag`, `gh_release_install`, `deb_release_install`, `sh_installer_run` |
| `pkg.sh` | the one package policy; `pkg_remove`/`pkg_purge` are report-only |
| `repo.sh` | deb822 sources, armored keys with optional digest pinning, per-vendor suite resolution |
| `shell.sh` | the profile region, drop-ins, the completion cache and its shims |
| `lang.sh` | per-ecosystem idempotent install helpers, plugin bootstrap and roster install |
| `wsl.sh` | additive host-configuration merge; never a whole-file write |
| `registry.sh` | module discovery, meta parsing, plan resolution, execution, summary |

Library rules that are enforced rather than intended: no shebang and no strict-mode flags in a
library file (the caller owns its shell options), no `readonly` at file scope (the unit tests
source repeatedly in one shell), logging to stderr only (stdout is machine-readable output), a
contract comment above every function.

## Detection contract

`os_detect` runs at source time and exports the only OS facts a module may rely on:

```
OS_ID OS_ID_LIKE OS_FAMILY OS_FLAVOR OS_CODENAME OS_UPSTREAM_CODENAME
OS_VERSION_ID OS_VERSION_MAJOR OS_PRETTY OS_LIBC
OS_ARCH_DPKG OS_ARCH_UNAME OS_ARCH_GO OS_ARCH_RUST
IS_WSL WSL_VERSION HAS_WSLG HAS_WSL_INTEROP IS_CONTAINER HAS_SYSTEMD INIT_SYSTEM IS_HEADLESS
```

- Codename precedence is exact: own release codename → upstream codename key → family hint →
  a static derivative map → unsupported. A rolling release with no codename yields an empty
  upstream codename, and every vendor source takes its documented fallback branch.
- Architecture truth is the package manager's own answer, not the kernel's — correct for a
  32-bit userland on a 64-bit kernel. The other three spellings are derived from it.
- Platform facts come from the filesystem (E4), and the init system is probed **orthogonally** to
  the platform: the reference machine is virtualised *and* runs a full init system, which the
  predecessor's "virtualised implies legacy init" assumption got wrong.
- The release file is parsed key by key in a subshell. Sourcing it is banned and grepped for — it
  leaks a dozen names into the caller's shell.

## Idempotency mechanisms

| mechanism | where | guarantees |
|---|---|---|
| Content compare before write | `write_if_changed` | second run writes nothing, backs up nothing, prints nothing |
| Digest manifest | `write_managed` + `$DEVENV_STATE/manifest` | distinguishes "ours, unmodified" from "hand-edited"; makes uninstall honest |
| Delimited region replacement | `ensure_block_in_file` | one region, replaced in place, byte-identical on a second run; symlink-aware |
| Marker-matched lines | `ensure_line_in_file` | matches on the marker, never on the text — which is how two spellings of one line both landed in the reference machine's profile |
| Version gate before download | `gh_release_install` step 0 | already at the pinned version means **no network call at all** |
| Registered-name guard | `helm_plugin_ensure` | the plugin manager errors when a plugin is present, so the guard reads the registered name from its own listing |
| Package-set filter | `pkg_install` | installed names are filtered out; an empty remainder returns immediately, so the archive is never touched |
| Source content compare | `repo_add` | index refresh happens only when a source file actually changed |
| Create-once | `write_once`, `bashrc_ensure_local`, the SSO settings seed | operator-owned files are created once and never overwritten |

## Browser and login layer

The capability that makes "terminal-only" survivable. It installs **no browser and no binaries**.

| piece | shipped as | role |
|---|---|---|
| `open-url` | `config/bin/open-url` → `~/.local/bin` | the one opener; picks `wsl` \| `gui` \| `print` \| `command` at call time |
| four generic names | symlinks to `open-url` | catches the callers that ignore the browser variable and exec these directly; also shadows the terminal browser (E6) |
| `clip` / `clip-paste` | `config/bin/*` → `~/.local/bin` | executables, not shell functions — the multiplexer, a client plugin, a credential helper, cron and a service unit all need a real command |
| `detect.sh` | `config/lib/detect.sh` → `~/.local/lib/devops-env/` | the shared runtime probe, sourced by all three, deliberately separate from the module-side library |
| `sso-login`, `sso-kubeconfig-add`, `web` | `config/bin/*` | status across providers; render a credential stanza from operator-local settings; open a named bookmark |
| `55-sso.sh` | the tenth shell fragment | loads *after* the fragment that owns the browser variable |
| settings + bookmarks | `config/sso/*.example` | seeded once into the operator's config directory, mode 0600 — **the only two files on the machine that may hold a real host name** |

Three invariants, each load-bearing and each tested:

1. **Never write to stdout.** A cluster credential plugin's stdout is parsed as structured data; a
   URL there is a parse error. One consumer routes a child's stdout *and* stderr to nothing. So
   user-facing text goes to the controlling terminal, else stderr.
2. **Always exit 0.** One consumer treats non-zero as "no browser, try the next handler"; another
   aborts the login outright.
3. **Never block.** Anything that seizes the terminal deadlocks a parent that is holding it while
   waiting on a loopback callback.

Two provider-level rulings that shaped the templates: the loopback tunnel runs **from the laptop
toward the box** (the opposite direction was in one input design and would bind a port the
listener already holds), and the grant type lives **in the credential file**, not in a helper — the
redirect URL is part of the token-cache key while the grant type is not, so a helper that warms the
cache differently creates a second entry and a second login.

## Test strategy

| layer | what it proves | how |
|---|---|---|
| `make check` | syntax, lint and format, over `bin/`, `lib/`, `modules/`, `tests/` **and `config/`** — shipped shell code is linted like the rest | container-provided linters when none is on the path, so there is nothing to install |
| `tests/policy/rules.sh` (582 lines) | the rules a linter cannot express: one mutation gate, one package policy, no in-place editing under `$HOME`, no appending to a dotfile, no hardcoded architecture or codename in a URL, complete meta headers, a checksum or a stated exception per download, no pin outside the declaration file | grep rules; `--self-test` plants one synthetic violation per rule and asserts each still fires |
| `tests/policy/privacy.sh` (366 lines) | FR-027/028/029 — structural shapes only, and it excludes itself from its own scan because some patterns necessarily appear in it verbatim | `--self-test` against a planted violation *and* a clean control |
| `tests/unit/` | library behaviour with no network and no root: filesystem writers, detection, release resolution, registry | a small assertion harness |
| `tests/k9s-keys.sh` | no duplicate shortcut, no collision with a shortcut the client itself defines, no layout-dependent key, required fields present, no plugin that moves secret material somewhere it should not go | `bash` + `awk` only (E1) |
| `tests/docker/entry.sh` (440 lines) | **the assertion the whole rework rests on** | fingerprint → preview run → fingerprint (must match) → real run → fingerprint → real run again → fingerprint (must match); plus loading the profile twice yields no duplicated path entry |
| `tests/docker/matrix.sh` | the above on four release images | the newest, unreleased image is allowed to fail |

The fingerprint is a digest of the installed-package list, the shell profile, and a sorted hashed
listing of the drop-in directory, the package sources directory and both binary directories. The
first fingerprint is taken **before** the preview run, not after — an earlier draft took it after
and could not have detected a preview that mutated.

## Where the build diverged from the design

Recorded because the code is the truth and the design documents are not.

| # | Design said | What shipped | Why |
|---|---|---|---|
| V1 | Cluster-client shortcuts on `Shift-<digit>`, "the only free key space". | **Function keys F2–F9 + F12, plus one `Shift-<letter>`.** | Those chords resolve through a US-layout rune table, so on a German keyboard they misfire — one of them lands on the client's own filter key. Function keys carry no layout and the client binds none. |
| V2 | A validator written in an interpreted language, CI-only, with vendored schemas. | **`tests/k9s-keys.sh`, `bash` + `awk`, runs anywhere.** | Keeps E1 true for the test suite as well, and lets the operator run the gate on their own machine. |
| V3 | Library files `github.sh` and a mutation gate inside `log.sh`. | **`net.sh`** (it also owns the generic download path and the vendor-installer wrapper, neither GitHub-specific) and **`run.sh`** (the gate is a concern of its own). | Every function name is unchanged, and nothing outside `lib/` sources a file by name, so the split is invisible to callers. |
| V4 | Purge conflicting packages before installing the container engine; remove the wrong same-named data tool. | **Report only.** | E8 / FR-012. The operator installed them. `--allow-pkg-remove` exists and is still never implicit. |
| V5 | No AI-agent module; the agent CLI installed through the JavaScript package manager. | **`modules/65-ai.sh`, and the agent installed by its own native installer as a base install** in the default profile, install-if-absent, never updated by this repository. | Verified on the reference machine: the package manager had nothing, the native installer had five self-updating versions. The other agents became an opt-in profile. |
| V6 | Nothing covering a machine the predecessor had already provisioned. | **`modules/92-migrate.sh`**, in no profile: reports appended profile lines and the function that redefined the elevation command, comments them out only when the replacement fragment is already installed, parses the rewritten file before installing it, and deletes nothing. | The reference machine *is* such a machine. Reporting first was the only safe shape. |
| V7 | A desktop module, kept in reduced form. | **Deleted entirely, with its profile**, and `purge-desktop` added to remove the residue. | The terminal-only direction post-dates that decision. D15. |
| V8 | A separate executable to assign a per-context theme. | **Not built.** The module tolerates its absence and the global theme applies; the audit reports the gap. | The global theme covers the daily case; per-context assignment is a follow-up, and shipping a module that hard-depends on a missing file would have been worse. |
| V9 | `tools/bump-versions.sh`, `tools/gen-module-docs.sh` and a weekly drift workflow that re-probes every vendor suite. | **Not built.** There is no `tools/` directory; the `Makefile` targets guard on the script being present, the module table is hand-maintained, and the pin file documents the intended bump rule in prose. One CI workflow shipped, not two. | Follow-up work; nothing else depends on them, and a generated table that nobody regenerates is worse than one that is reviewed. |
| V10 | Documentation split by topic, with a page per layer. | **Ten pages shipped** — usage, configuration, modules, tools, SSO, the identity-provider side, safety, host notes, migration, development — and the README reduced to a front door that links them. | The house rule: a README is a front door, elaboration goes to a page. |

## Out of scope for this plan

- Per-context theme assignment (V8), and the version-bump, doc-generation and suite-drift
  automation (V9).
- A second architecture as a *tested* target. The mapping is complete and a missing artifact is an
  explicit skip, but there is no automation for it and nothing beyond that is claimed.
- Distribution families outside the two supported ones — refused, by design.
