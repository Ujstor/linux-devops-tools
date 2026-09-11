# Working on this repository

Nothing here is needed to *use* the repo: `install.sh` and `bin/devenv` depend on bash, curl,
git and coreutils and nothing else.

**Source of truth:** [`Makefile`](../Makefile) for targets, the header of
[`bin/devenv`](../bin/devenv) for the module contract, [`lib/README.md`](../lib/README.md) for
the library API. Verified 2026-09-10.

## Targets

```bash
make help
```

| target | what it runs | needs |
|---|---|---|
| `make lint-coverage` | every shell file in the checkout is on the lint list | git |
| `make syntax` | `bash -n` over every shipped script | nothing |
| `make lint` | `shellcheck -x -P . -S style` | shellcheck, or Docker |
| `make fmt` / `make fmt-check` | `shfmt -i 2 -ci -bn`, write / diff | shfmt, or Docker |
| **`make check`** | `lint-coverage syntax lint fmt-check` — **under a minute** | |
| `make lint-policy` | `tests/policy/rules.sh` | nothing |
| `make lint-privacy` | `tests/policy/privacy.sh` — the public-repo gate | nothing |
| `make lint-k9s` | `tests/k9s-keys.sh` — shipped key map and plugin safety | nothing |
| `make lint-docs` | `tests/policy/docs-drift.sh` — [modules.md](modules.md) vs the meta headers | nothing |
| `make lint-yaml` | `tests/policy/yaml-parse.sh` — every shipped YAML file parses | python3 + PyYAML |
| `make test-unit` | `tests/unit/run.sh` — no network, no root | nothing |
| `make test-bootstrap` | `tests/bootstrap.sh` — `curl \| bash` with no tty, no `BASH_SOURCE` | nothing |
| `make test-docker` | the container matrix: install twice, assert nothing changed | Docker + network |
| **`make test`** | all of the above | |
| `make bump` / `make bump-write` | `tools/bump-versions.sh` — pins with a newer upstream | network |
| `make clean` | remove bootstrap scratch from an interrupted install | |

`shellcheck` and `shfmt` come from containers when they are not on your `PATH`, so there is
nothing to install first. `USE_DOCKER=1` forces the container; `SHELLCHECK=`/`SHFMT=` point at
your own build.

```bash
IMAGES="debian:12 ubuntu:24.04" make test-docker    # a shorter matrix
PROFILE=ci bash tests/docker/matrix.sh              # a deeper, slower run
```

`SH_FILES` deliberately includes `config/` — `config/bin/*` become executables in
`~/.local/bin` and `config/bashrc.d/*` are sourced into every interactive shell. They are the
files that run most often, so a lint gate that skipped them would be the wrong gate.

> [!IMPORTANT]
> **No gate skips itself.** Every target above stops with `MISSING GATE: …` when the script it
> runs is not in the checkout, instead of printing `skip:` and exiting 0. A gate that is not
> there has not passed, and a green target that ran nothing is worse than no target — that is
> the same failure as a rule that greps a tree it cannot see. The same rule holds inside the
> gates: `rules.sh` refuses to run when its globs match no file, `privacy.sh` refuses when it
> collected no file, `yaml-parse.sh` refuses when it found no YAML, `run.sh` refuses when there
> is no test file, and a test file that makes no assertion fails.

There is no `make docs`: [docs/modules.md](modules.md) is written by hand, because its
"what it does" column is prose no `# meta: desc=` one-liner could carry. `make lint-docs`
keeps the machine-checkable half of it honest instead.

## CI, job by job

Every CI job is one `make` target, so anything CI catches can be reproduced with one command
before pushing. Each gate also proves itself against planted violations before it judges the
checkout, and each CI step asserts on the gate's **verdict line**, not only on its exit status.

| CI job | steps | run it locally |
|---|---|---|
| `shellcheck + shfmt` | `lint-coverage.sh --self-test`, `make check` | `make check` |
| `policy rules` | `rules.sh --self-test`, `make lint-policy` | `make lint-policy` |
| `public-repo gate` | `privacy.sh --self-test`, `make lint-privacy`, `rules.sh --rule old-name` | `make lint-privacy` |
| `yaml` | `yaml-parse.sh --self-test`, `make lint-yaml`, `make lint-k9s` | `make lint-yaml lint-k9s` |
| `docs match the modules` | `make lint-docs` | `make lint-docs` |
| `unit tests` | `make test-unit` | `make test-unit` |
| `curl \| bash survives` | `make test-bootstrap` | `make test-bootstrap` |
| `debian:12` … `ubuntu:26.04` | `docker run … tests/docker/entry.sh`, one image per leg | `IMAGES=debian:12 make test-docker` |
| `ci` | asserts every job is in its `needs`, and that every one of them **succeeded** | — |

`make test` is all of it except the container matrix's per-image parallelism. The `container`
legs are the one place CI calls `docker run` directly rather than through a target: it runs one
image per job for the log separation, with exactly the environment `tests/docker/matrix.sh`
passes (`SRC=/src`, `PROFILE=minimal`, `DRY_PROFILE=ci`, the checkout mounted read-only).

> [!TIP]
> `make test-docker` skips when Docker is not usable, because that is the right behaviour on a
> laptop. Anywhere the result is read as a gate, set `REQUIRE_DOCKER=1` and the skip becomes a
> failure.

## The linters

`tests/policy/rules.sh` proves a script is a well-formed **module of this repository**, which is
what shellcheck cannot express. `tests/policy/privacy.sh` is the public-repo gate.

```bash
bash tests/policy/rules.sh                # check the checkout
bash tests/policy/rules.sh --rule NAME    # one rule
bash tests/policy/rules.sh --list         # what each rule checks
bash tests/policy/rules.sh --self-test    # plant synthetic violations, assert every rule fires
```

`privacy.sh`, `yaml-parse.sh` and `lint-coverage.sh` take `--self-test` too. Every run of
`rules.sh` and `privacy.sh` prints what it actually looked at — `28 module(s), 12 lib(s),
3 executable(s)`, `scanning 131 file(s)` — before its verdict, because `clean` on its own does
not distinguish a gate that found nothing wrong from a gate that read nothing at all. Both
linters are described rule by rule in [docs/safety.md](safety.md).

A line ending in `# policy-allow: <rule>` is exempt from that one rule. Use it for a genuine,
commented exception — never to silence a class.

## The module contract

A module is an executable `modules/NN-name.sh`, mode 0755, run as a **child process** of
`bin/devenv` with the whole `DEVENV_*` environment exported into it. `NN` is run order and
nothing else: there is no dependency graph, and a module may never assume another module ran.
Every module must be individually runnable:

```bash
DEVENV_HOME=$PWD ./modules/36-k8s-plugins.sh
```

Shape, exactly:

```bash
#!/usr/bin/env bash
# meta: name=k8s-plugins
# meta: desc=krew, kubectl plugins and helm plugins
# meta: profiles=devops,full
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=kubectl
# meta: root=no
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

module_main() { … }
module_main "$@"
```

### The meta header

Parsed by `lib/registry.sh` with one `sed` over the first 40 lines. The file is never sourced or
executed to read it, and a trailing `# comment` on a meta line is stripped.

| key | required | values |
|---|---|---|
| `name=` | **yes** | the short name used by `--only`/`--skip` and `profiles/*.list`. Conventionally the filename stem without its number, so renumbering never invalidates a profile |
| `desc=` | **yes** | one line, lower case, no trailing period. Shown by `devenv list` and as the running section header |
| `profiles=` | no | advisory. **`profiles/*.list` is the authority**; this key is what `devenv list` displays. Empty means "never in a profile" |
| `os=` | no | `any` \| `debian` \| `ubuntu` \| `wsl` \| `!wsl` \| `!container` (default `any`) |
| `arch=` | no | comma-separated dpkg architectures (default any) |
| `needs=` | no | comma-separated commands that must be on `PATH` |
| `root=` | no | `yes` if the module calls `run_sudo` (default `no`) |

### Exit protocol

| status | meaning |
|---|---|
| `0` | did its work, or found nothing to do |
| `78` | precondition missing. Call `skip "reason"`, which exits 78 for you. Recorded as SKIP; the run continues. **The only way to bail out of a module that does not apply here** |
| anything else | failure. Recorded as FAIL; the run continues unless `--fail-fast` |

`module_gate` applies `os` → `arch` → `needs` → `root` *before* the module starts, so a module
body never has to check them. `root=yes` on a box with no usable sudo is a skip, not a failure —
this tool never demands a password up front.

### The library

One line pulls in everything; never source an individual `lib/` file:

```bash
source "${DEVENV_HOME:?}/lib/common.sh"
```

| concern | what you get |
|---|---|
| output | `log_info` `log_warn` `log_error` `log_success` `log_debug` `log_skip` · `log_step`/`log_step_end` · `die [CODE] MSG` · `skip REASON` |
| the gate | `run` · `run_quiet` · `run_sudo` · `as_root` (reads only) · `is_dry_run` · `have_root` · `confirm` · `confirm_dangerous Q OPTIN_VAR` · `changed WHAT…` |
| detection | `os_is_debian` `os_is_ubuntu` `os_is_wsl` `os_is_wsl2` `os_is_container` `os_has_systemd` `os_is_headless` · `have CMD` · `version_ge A B` · `require_arch ARCH…` |
| files | `ensure_dir` · `write_if_changed` (the default writer) · `write_once` · `write_managed` · `ensure_block_in_file` · `ensure_line_in_file` · `symlink_file` · `yaml_map_merge` · `backup_file` · `manifest_record` |
| packages | `pkg_install` · `pkg_install_optional` · `pkg_install_first` · `pkg_available` · `apt_or_release` · `pkg_conflicts_report`. `pkg_remove`/`pkg_purge` are **report-only** |
| apt repos | `repo_key` · `repo_add` · `repo_ensure_docker` / `_hashicorp` / `_kubernetes` / `_github_cli` / `_azure_cli` / `_trivy` |
| releases | `gh_release_install` · `deb_release_install` · `gh_latest_tag` · `download` · `verify_sha256` · `sh_installer_run` |
| shell | `bashrc_dropin NAME` (stdin) · `bashrc_ensure_hook` · `comp_cache` · `comp_shim` · `comp_complete_c` |
| languages | `go_install` · `cargo_install` · `uv_tool_install` · `npm_global_install` · `helm_plugin_ensure` · `krew_bootstrap` · `krew_install_plugins` |
| WSL | `wslconf_get` · `wslconf_set` · `wsl_win_root` · `wsl_restart_hint` |

`run` takes **argv**, never a pipeline or a redirection. Build the payload in
`"$(devenv_tmpdir)"` and install it with an argv-only command.

Scratch comes in two flavours and the difference is load-bearing. `devenv_tmpdir` /
`devenv_tmpfile` live under `$DEVENV_RUNDIR`, which is under `$TMPDIR`, which on a hardened
host is `/tmp` **mounted `noexec`** — fine to write, unpack and `install` from, impossible
to run. Anything that has to be **executed** (a downloaded installer binary, a vendor
`install.sh`, a `./configure` tree) goes in `"$(devenv_execdir)"`, which probes for a
filesystem that permits execution and falls back off `/tmp` when it must, saying so.
`tests/policy/rules.sh --rule noexec-scratch` enforces it; see
[lib/README.md](../lib/README.md#the-two-scratch-areas) for the full contract.

### The five rules

1. Every mutation goes through `run`/`run_sudo` or a `lib/fs.sh` writer.
2. Idempotent by construction — a second run writes, backs up and prints nothing.
3. Never destroy the user's work.
4. No pin outside `versions.env`, and every key there carries `# owner: <module>`.
5. Nothing private — placeholders only.

They are stated in full, with their rationale, in [docs/safety.md](safety.md), and each one has
a linter rule behind it.

## Adding a module

1. Pick a number that puts it in the right place in the run order; nothing else depends on it.
2. Write the meta header first — `devenv list` and the policy linter both read it.
3. Add its `name` to the `profiles/*.list` files that should ship it, and mirror that in
   `profiles=`. The list files win.
4. Put every version it needs in `versions.env` with an `# owner:` comment.
5. `make check && make lint-policy && make lint-privacy`.
6. `IMAGES="debian:12" make test-docker` — the second install must change nothing.
7. Add its row to [docs/modules.md](modules.md), and its tools to [docs/tools.md](tools.md).

## Adding a library function

Rules for `lib/`: no shebang, no `set -e` (they are sourced fragments), a
`# shellcheck shell=bash` directive, and a header comment saying what the file owns. The full
convention is [`lib/README.md`](../lib/README.md).
