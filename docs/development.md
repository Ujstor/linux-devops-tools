# Working on this repository

Nothing here is needed to *use* the repo: `install.sh` and `bin/devenv` depend on bash, curl,
git and coreutils and nothing else.

**Source of truth:** [`Makefile`](../Makefile) for targets, the header of
[`bin/devenv`](../bin/devenv) for the module contract, [`lib/README.md`](../lib/README.md) for
the library API, [`config/os-support.list`](../config/os-support.list) for the supported releases.
Verified 2026-10-06.

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
| `make lint-os-support` | `tests/policy/os-support.sh` (self-test, then the check) — `config/os-support.list` vs both CI matrices, `matrix.sh`'s default and, internally, the lab inventory | nothing |
| **`make check`** | `lint-coverage syntax lint fmt-check lint-os-support` — **under a minute** | |
| `make lint-policy` | `lint-os-support`, then `tests/policy/rules.sh` | nothing |
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
IMAGES="docker.io/library/debian:12 docker.io/library/almalinux:9" make test-docker   # a shorter matrix
PROFILE=devops bash tests/docker/matrix.sh          # the default set, what CI runs (slow)
bash tests/docker/matrix.sh --print-images          # the resolved image list, no Docker
```

With `IMAGES` unset the matrix is the image column of `config/os-support.list`. Images are
written **fully qualified** (`docker.io/library/…`, `docker.io/rockylinux/rockylinux:…`,
`docker.io/opensuse/leap:…`), so the string in both CIs and on a laptop names the same image and
no registry prefix is guessed.

`SH_FILES` deliberately includes `config/` — `config/bin/*` become executables in
`~/.local/bin`, `config/bashrc.d/*` are sourced into every interactive shell,
`config/external-repos.sh` is sourced by every run, and `config/tmux/tmux-save-session.sh` is
installed to `~/.tmux-sessions/` and run by hand. They are the files that run most often, so a
lint gate that skipped them would be the wrong gate.

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
| `policy rules` | `rules.sh --self-test`, `make lint-policy` (which runs `os-support.sh --self-test` and `os-support.sh` first) | `make lint-policy` |
| `public-repo gate` | `privacy.sh --self-test`, `make lint-privacy`, `rules.sh --rule old-name` | `make lint-privacy` |
| `yaml` | `yaml-parse.sh --self-test`, `make lint-yaml`, `make lint-k9s` | `make lint-yaml lint-k9s` |
| `docs match the modules` | `make lint-docs` | `make lint-docs` |
| `unit tests` | `make test-unit` | `make test-unit` |
| `curl \| bash survives` | `make test-bootstrap` | `make test-bootstrap` |
| `docker.io/library/debian:12` … `docker.io/library/archlinux:latest` | `docker run … tests/docker/entry.sh`, one leg per row of `config/os-support.list` — 13, every one a gate | `PROFILE=devops IMAGES=<image> make test-docker` |
| `ci` | asserts every job is in its `needs`, and that every one of them **succeeded** | — |

`make test` is all of it except the container matrix's per-image parallelism. The `container`
legs are the one place CI calls `docker run` directly rather than through a target: it runs one
image per job for the log separation, with exactly the environment `tests/docker/matrix.sh`
passes (`SRC=/src`, `DRY_PROFILE=ci`, the checkout mounted read-only) and `PROFILE=devops` — the
default set; `matrix.sh` itself defaults to `minimal`.

A CI matrix is resolved before the checkout exists, so both CIs carry a **copy** of the image
column. `make lint-os-support` fails the moment a copy, `matrix.sh`'s default or (internal variant
only) the lab inventory disagrees with the list. Adding a release is one row in
`config/os-support.list` plus the same image in both CI files, in one change.

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
`rules.sh` and `privacy.sh` prints what it actually looked at — `29 module(s), 17 lib(s),
4 family file(s), 3 executable(s)`, `scanning N file(s)` — before its verdict, because `clean` on its own does
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
| `family=` | no | comma list of `debian` \| `redhat` \| `suse` \| `arch` (default: every family). For a module that only *means* something on some families; elsewhere it is reported *not applicable on the <family> family*. A step inside a module that only applies to one family checks `os_family_is` and logs a skip instead |
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

`module_gate` applies `family` → `os` → `arch` → `needs` → `root` *before* the module starts, so a module
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
| detection | `os_family_is FAMILY…` · `os_is_debian` `os_is_ubuntu` (the Debian *flavour*, i.e. the archive layout) `os_is_wsl` `os_is_wsl2` `os_is_container` `os_has_systemd` `os_is_headless` · `have CMD` · `version_ge A B` · `require_arch ARCH…` · the `FAM_*` names — never hard-code a Debian path or group |
| files | `ensure_dir` · `write_if_changed` (the default writer) · `write_once` · `write_managed` · `ensure_block_in_file` · `ensure_line_in_file` · `symlink_file` · `yaml_map_merge` · `backup_file` · `manifest_record` · `fs_install` (an executable into a bin directory, relabelled under SELinux) |
| packages | `pkg_install` · `pkg_install_optional` · `pkg_install_first` · `pkg_install_local` · `pkg_available` · `pkg_upgrade_one` · `pkg_mark_manual` · `pkg_ensure_addon` · `pkg_names` · `pkg_hint` · `apt_or_release` · `pkg_conflicts_report`. `pkg_remove`/`pkg_purge` are **report-only** |
| package repos | `repo_key` · `repo_add` · `repo_add_rpm` · `repo_ensure_docker` / `_hashicorp` / `_kubernetes` / `_github_cli` / `_azure_cli` / `_trivy` — each returns 78 where the vendor publishes nothing for this family |
| releases | `gh_release_install` · `pkg_release_install` · `gh_latest_tag` · `http_ok` · `download` · `verify_sha256` · `sh_installer_run` |
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

## The family layer

Four Linux families run the same modules. Names are data, mechanisms are code: a module says
*what* it installs once, in Debian names, and the layer below decides how.

| file | owns |
|---|---|
| [`config/os-support.list`](../config/os-support.list) | **the** supported releases, one row each: `family distro release image lab`. Read by `lib/os.sh` (tested or untested) and `tests/docker/matrix.sh` (default images); `make lint-os-support` holds every copy to it |
| `lib/os.sh` | detection — `OS_FAMILY` (`debian` · `redhat` · `suse` · `arch`), `OS_DISTRO`, `OS_RELEASE` (the list's form), `OS_PKG_MGR`, `OS_SUPPORT` (`tested` · `untested` · empty), `OS_ARCH_RPM` — and `os_require_supported`, which refuses an unknown family before any change. `OS_FLAVOR` stays the Debian flavour, empty elsewhere: codename and deb822 paths key on it |
| `lib/family/<family>.sh` | the family's names as `FAM_*`: admin group, CA anchor dir, refresh command and bundle, package query, MAC, package fingerprint. Data only, the **identical key set** in all four, no empty value — `tests/unit/test_family.sh` fails on drift |
| `lib/pkg.sh` | the one package policy: translate the name, then dispatch to `_pkg_<mgr>_<op>`. Its public API is unchanged, so modules are too |
| `lib/pkg_{apt,dnf,zypper,pacman}.sh` | the backends — the only files that run a package manager. `pkg_apt.sh` is the former apt code, moved verbatim |
| [`config/packages.map`](../config/packages.map) | `debian-name redhat suse arch` per row; `=` the same name, `-` none on that family (a logged skip), `a,b` several packages. Never read on the Debian family |
| `lib/repo.sh` | vendor repositories: deb822 on Debian, a `.repo` file plus an explicit `rpm --import` on RedHat and SUSE, 78 on Arch |

Rules that hold on every family:

* **pacman never runs `-Sy` without `-u`.** `pkg_update` is a no-op there. A missing or stale
  index is a 78 with *re-run with --upgrade*; under `--upgrade` the first install of the run is
  one `pacman -Syu --needed <targets>`.
* **A package file is never a binary.** `pkg_release_install REPO PKG VERSION --deb PAT [--rpm
  PAT] [--tarball PAT]` replaced `deb_release_install`: the `.deb` on apt, the `.rpm` through
  `pkg_install_local` on dnf and zypper, the archive on pacman or where the release has no
  `.rpm`. Every pattern is written at the call site and checked against the pinned release's
  assets; nothing is guessed.
* **`http_ok` has three answers:** 0 published, 1 absent (404/410), 2 could not tell (timeout,
  5xx, 429, a rate-limit 403). Installers skip on 1 only and fail on 2, so a network blip is a
  visible failure rather than a skip the next run silently turns into an install. Boolean
  callers (`if http_ok …`) are unaffected.
* **An add-on repository is a reported change.** `pkg_ensure_addon` enables Ubuntu's `universe`,
  or CRB and EPEL on AlmaLinux/Rocky, and nothing elsewhere. `pkg_ensure_universe` is its alias.
* **SELinux stays enforcing.** `fs_install` relabels what it installs; the `no-selinux-relax`
  rule forbids everything else.
* **The linters know the families.** `no-bare-apt` covers apt, dpkg, dnf, yum, microdnf, zypper,
  pacman and rpm — the backends and `lib/repo.sh` are the only exemptions; `lib-shape` holds
  family files to data; `meta-header` validates `family=`.

Adding a release is a row in `config/os-support.list` plus its image in both CI files;
`make lint-os-support` names the copy that is missing. An unlisted release of a known family
already runs, untested — the row is what makes it a gate.

## Adding a module

1. Pick a number that puts it in the right place in the run order; nothing else depends on it.
2. Write the meta header first — `devenv list` and the policy linter both read it.
3. Add its `name` to the `profiles/*.list` files that should ship it, and mirror that in
   `profiles=`. The list files win.
4. Put every version it needs in `versions.env` with an `# owner:` comment.
5. Spell every package the Debian way, once, and give each new name a row in
   `config/packages.map`. A module never branches on the family for a package name.
6. `make check && make lint-policy && make lint-privacy`.
7. `IMAGES="docker.io/library/debian:12 docker.io/library/almalinux:9" make test-docker` — one
   apt and one rpm release; the second install must change nothing.
8. Add its row to [docs/modules.md](modules.md), and its tools to [docs/tools.md](tools.md) —
   with a [per-family source](tools.md#per-family-sources) where it differs.

## Adding a library function

Rules for `lib/`: no shebang, no `set -e` (they are sourced fragments), a
`# shellcheck shell=bash` directive, and a header comment saying what the file owns. The full
convention is [`lib/README.md`](../lib/README.md).
