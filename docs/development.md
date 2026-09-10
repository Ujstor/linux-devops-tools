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
| `make syntax` | `bash -n` over every shipped script | nothing |
| `make lint` | `shellcheck -x -P . -S style` | shellcheck, or Docker |
| `make fmt` / `make fmt-check` | `shfmt -i 2 -ci -bn`, write / diff | shfmt, or Docker |
| **`make check`** | `syntax lint fmt-check` — **under a minute** | |
| `make lint-policy` | `tests/policy/rules.sh` | nothing |
| `make lint-privacy` | `tests/policy/privacy.sh` — the public-repo gate | nothing |
| `make lint-k9s` | `tests/k9s-keys.sh` — shipped key map and plugin safety | nothing |
| `make test-unit` | `tests/unit/run.sh` — no network, no root | nothing |
| `make test-docker` | the container matrix: install twice, assert nothing changed | Docker + network |
| **`make test`** | all of the above | |
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

> [!NOTE]
> `make bump` and `make docs` reference `tools/bump-versions.sh` and `tools/gen-module-docs.sh`,
> which are not in this checkout — both targets print a skip. Until they land, `versions.env` is
> bumped by hand and [docs/modules.md](modules.md) is maintained by hand.

## The linters

`tests/policy/rules.sh` proves a script is a well-formed **module of this repository**, which is
what shellcheck cannot express. `tests/policy/privacy.sh` is the public-repo gate.

```bash
bash tests/policy/rules.sh                # check the checkout
bash tests/policy/rules.sh --rule NAME    # one rule
bash tests/policy/rules.sh --list         # what each rule checks
bash tests/policy/rules.sh --self-test    # plant synthetic violations, assert every rule fires
```

`privacy.sh` takes `--list` and `--self-test` (it has no `--rule`). Both linters are described
rule by rule in [docs/safety.md](safety.md).

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
