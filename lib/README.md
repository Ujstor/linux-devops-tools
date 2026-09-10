# `lib/` — the shared library

Everything in `lib/` is **sourced, never executed**. One line pulls in the whole API:

```bash
source "${DEVENV_HOME:?}/lib/common.sh"
```

`lib/common.sh` sets the globals, installs the traps, sources every other file in
dependency order and loads `versions.env`. Never source an individual file — the
include guards make it harmless, but only `common.sh` guarantees the ordering.

## Header and strict-mode convention

**Executables** — `install.sh`, `bin/*`, `modules/*.sh`, `tests/**/*.sh` — start with
exactly this, and are mode `0755`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"
```

**Library files** — `lib/*.sh` — have **no shebang**, are mode `0644`, and start with:

```bash
# shellcheck shell=bash
# lib/<name>.sh — one line saying what this file owns.
#   … why it is the way it is …

[ -n "${_DEVENV_<NAME>:-}" ] && return 0
_DEVENV_<NAME>=1
```

Rules that hold in every library file:

* **No `set -e`/`set -u` and no `set -o pipefail`.** The sourcing script owns the
  shell options; a library that changes them changes its caller.
* **No `readonly` at file scope.** The unit tests source the library repeatedly in
  one shell, and a `readonly` makes the second source a fatal error.
* **No `exit`.** `die` and `skip` (both in `log.sh`) are the only two functions in
  the entire library that exit, plus `require_arch`, which calls `skip` on purpose
  and says so in its contract.
* **Logging goes to stderr.** stdout is reserved for machine-readable output:
  `need_sudo`, `gh_latest_tag`, `comp_dir`, `print_plan`, `backup_file`, `repo_key`.
* **Every function carries a contract comment above it**: arguments, what it prints,
  what it returns, and what it does under `--dry-run`.
* **Predicates return 1 for "no".** Call them inside `if`, `&&` or `||`, never as the
  last statement of a function whose caller runs under `set -e`.

## The files

| file | owns | SPEC §5.3 name |
|---|---|---|
| `common.sh` | entry point, globals, tmpdirs, `versions.env`, traps | `common.sh` |
| `log.sh` | `log_*`, `die`, `skip`, colour | `log.sh` |
| `os.sh` | distro/arch/platform detection, the `OS_*`/`IS_*` contract | `os.sh` |
| `run.sh` | **the `--dry-run` gate**, `run`/`run_sudo`, sudo, `confirm`, `changed` | split out of `log.sh` + `os.sh` |
| `fs.sh` | every filesystem mutation, blocks, backups, manifest, YAML merge | `fs.sh` |
| `net.sh` | downloads, checksums, release-tag resolution, binary/`.deb` installs | `github.sh` |
| `pkg.sh` | the one apt policy | `pkg.sh` |
| `repo.sh` | deb822 sources, armored keyrings, suite resolution, per-vendor | `repo.sh` |
| `shell.sh` | `~/.bashrc` hook, `~/.bashrc.d` drop-ins, the completion cache | `shell.sh` |
| `lang.sh` | go / cargo / uv / npm / helm-plugin / krew install helpers | `lang.sh` |
| `wsl.sh` | `/etc/wsl.conf` additive merge, WSL helpers | `wsl.sh` |
| `registry.sh` | module discovery, `# meta:` parsing, plan, run, summary | `registry.sh` |

Two files are named differently from SPEC §5.3: `run.sh` holds the mutation gate that
SPEC listed under `log.sh`/`os.sh`, and `net.sh` is SPEC's `github.sh` (it also owns
the generic download path and `sh_installer_run`, neither of which is GitHub-specific).
**Every function name is exactly as SPEC §5.3 specifies**, and nothing outside `lib/`
sources a library file by name, so the split is invisible to callers.

`lib/awk/` holds standalone awk programs (`k9s-set-skin.awk`) and is not part of this
API.

## The rules the library exists to enforce

1. **One dry-run gate.** Every mutation goes through `run` / `run_sudo`, or consults
   `is_dry_run`. `--dry-run` must fingerprint-identically leave `$HOME` and `/etc`
   alone; that is the acceptance test, and it is only honest because there is exactly
   one gate.
2. **Idempotent by construction.** Writers compare content before writing. A second
   run takes no backup, writes no file and prints no line. No blind `>>` anywhere.
3. **Never destroy the user's work.** A symlinked `~/.bashrc` is written *through*,
   never replaced. Packages the user installed are reported, never removed. Files
   without this repo's marker are never pruned. `sso.env` is seeded once and never
   overwritten.
4. **Sudo is lazy.** Nothing asks for a password until a module that needs root
   actually runs. Running as root works. A box without `sudo` gets an actionable
   message and a skip, not an obscure failure.
5. **Supply chain.** Release binaries are SHA256-verified, or carry an explicit
   `--no-verify --no-verify-reason '<why>'`. Apt keys are validated before install and
   repaired when corrupt. `gpg` is never required.
6. **No `/etc/os-release` in anyone's shell.** It is parsed key by key, never sourced.

## Architecture support

`OS_ARCH_DPKG` (from `dpkg --print-architecture`) is the source of truth, and
`OS_ARCH_{GO,UNAME,RUST}` are derived from it, correctly, for every Debian
architecture. **Only `amd64` / `x86_64` is tested.** `arm64` is best-effort: where an
upstream publishes no arm64 asset, `gh_release_install` returns **78** and the module
logs a skip — it never silently installs nothing. Nothing beyond that is claimed.

## Adding a function

1. Put it in the file that owns that concern.
2. Write the contract comment first: args, stdout, exit codes, `--dry-run` behaviour.
3. Route every mutation through `run`/`run_sudo` or an existing `fs.sh` writer.
4. Make it a no-op when the machine is already in the desired state, and prove it by
   running the module twice.
5. `bash -n`, then `shellcheck -x -P . -S style`, then `shfmt -d -i 2 -ci -bn` —
   or just `make check`, which is the same three with the same flags. `-P .` is not
   optional: without it shellcheck cannot resolve a `# shellcheck source=lib/…`
   directive and reports SC1091 instead of following the file.
