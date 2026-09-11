# Safety rules

These are enforced by `tests/policy/rules.sh`, `tests/policy/privacy.sh` and the container
matrix — not just promised.

**Source of truth:** `bash tests/policy/rules.sh --list` and
`bash tests/policy/privacy.sh --list`. Verified 2026-09-10.

## The seven rules

1. **Every mutation goes through one gate.** No bare `sudo`, no bare `apt-get`, no bare `curl`,
   no `sed -i` under `$HOME`, no `>>` into a dotfile. That single choke point is what makes
   `--dry-run` a true no-op rather than a best effort.
2. **Idempotent by construction.** A second run writes nothing, backs up nothing and prints
   nothing. Every writer compares before it writes; every installer version-gates before it
   downloads.
3. **Your work is never destroyed.** Conflicting packages are *reported*, not purged. Only files
   carrying this repository's marker are ever pruned. A symlinked dotfile is written through,
   never replaced.
4. **No pin outside `versions.env`,** and every key there names its owning module.
5. **Nothing private.** No real hostname, cluster, context, realm, client id, IP or kubeconfig
   content — in code, comments, examples, docs or tests.
6. **Root is asked for late.** A module that needs root and cannot get it skips with an
   explanation. Stock Debian without `sudo` is a supported situation; running as root directly
   works too.
7. **Checksums, or an explicit and justified exception,** for every downloaded artifact. Apt
   signing keys are fetched armored, validated as real OpenPGP keys, repaired when corrupt, and
   can be digest-pinned in `versions.env`.

## What it will never do

| never | instead |
|---|---|
| remove a package you installed | `pkg_remove`/`pkg_purge` are report-only; removal needs `--allow-pkg-remove` **and** a confirmation |
| replace a symlinked `~/.bashrc` | it writes *through* the symlink. `--adopt-bashrc` is the explicit opt-out, and it backs up first |
| delete a file you edited | the manifest stores a digest per file; a changed file is kept and reported by `uninstall` |
| touch `~/.bashrc.d/90-local.sh` | created empty once, then never again — not by `--prune`, not by `uninstall` |
| add you to the `docker` group implicitly | root-equivalent, so `--allow-docker-group` only |
| write `/etc/wsl.conf` implicitly | `--allow-wsl-conf` only, and never to "repair" `appendWindowsPath` |
| run `apt-get upgrade` | only with `--upgrade` / `DEVENV_UPGRADE=1` |
| open a browser flow during install | `auth-sso` installs helpers; **you** run `sso-login` afterwards |
| overwrite `~/.config/devops-env/*` | seeded once from `*.example`, then left alone forever |
| rewrite your git identity | `user.*`, `commit.gpgsign`, `credential.*`, `includeIf` schemes and `http.sslVerify` are never written. `doctor` warns about `http.sslVerify=false`; changing it is your call |
| edit `~/.tmux.conf` in place | it ships a sourceable snippet at `~/.config/devops-env/tmux/devenv-clipboard.conf` |
| merge your `KUBECONFIG` | any kubeconfig helper is opt-in and backs up before it writes |
| curl-pipe an external config repo | `nvim-config` and `tmux-config` are cloned and symlinked, and never updated over a dirty worktree |

## `--yes` is not `--force`

`--yes` answers **ordinary** questions. Anything system-wide and hard to undo goes through
`confirm_dangerous`, which *refuses* under `--yes` unless its own opt-in variable is set. The
full list is in [docs/configuration.md](configuration.md#privileged-hard-to-undo-steps).

## Skips are not failures

A module that cannot apply — wrong OS, wrong architecture, a missing prerequisite, or root it
cannot get — exits `78`, is recorded as a **SKIP**, and the run continues. The summary says why.
`--fail-fast` stops at a real failure; nothing stops at a skip.

## What the linters actually check

`tests/policy/rules.sh`:

| rule | what it proves |
|---|---|
| `strict-mode` | every executable starts `#!/usr/bin/env bash` and sets `-euo pipefail` |
| `lib-shape` | `lib/*.sh` are sourced fragments: no shebang, no `set -e`, a `shell=bash` directive |
| `meta-header` | every module has `name=`/`desc=`, valid `os=`/`root=`, and a unique name |
| `common-entrypoint` | a module sources `lib/common.sh`, never an individual lib file |
| `no-bare-sudo` | every privileged command goes through `run_sudo`/`as_root` |
| `no-bare-apt` | one apt policy: `pkg_*` only — never `apt-get`, `apt`, `nala`, `dpkg -i` |
| `no-bare-download` | every download goes through `lib/net.sh`, which verifies it |
| `no-sed-i` | in-place edits are what severed a symlinked `~/.bashrc` once already |
| `no-append-dotfile` | no `>>` into a dotfile |
| `no-rm-rf-unquoted` | no `rm -rf` with an unquoted variable |
| `no-os-release-source` | never source `/etc/os-release`, never call `lsb_release` |
| `no-hardcoded-arch-url` | no architecture or codename baked into a URL literal |
| `release-checksum` | every `gh_release_install` carries a checksum option, or `--no-verify` with a stated reason |
| `pin-defined` | every `*_VERSION`/`*_REF` a module reads exists in `versions.env` |
| `old-name` | **neither** former repository name appears outside the migration documents, and never in a URL or a checkout path |
| `exec-bit` | `modules/` and `bin/` are executable; `lib/` is not |
| `noexec-scratch` | nothing under `$DEVENV_RUNDIR` is executed or `chmod +x`-ed — `/tmp` is `noexec` on a hardened host, so a download that must **run** goes in `devenv_execdir` |

`tests/policy/privacy.sh` — this repository is public, so the gate is written **structurally**
(shapes, not a denylist of real values; a denylist naming the secrets would itself be the leak):

| rule | what it catches |
|---|---|
| `internal-host` | a hostname under `.local`, `.lan`, `.internal`, `.intranet`, `.corp` that is not an `*.example.*` placeholder |
| `private-ip` | an RFC1918 literal. Use the RFC5737 documentation ranges instead |
| `oidc-realm` | a Keycloak realm path that is not `REALM_PLACEHOLDER` or a variable |
| `client-secret` | an OIDC/OAuth client secret with a literal value |
| `kubeconfig-payload` | base64 CA / client key / token material, or a real `current-context` |
| `key-material` | a PEM private key or certificate block |
| `token-shape` | anything shaped like a real GitHub, GitLab, AWS or Slack token, or a JWT |
| `email` | an email address that is not an `example.com` placeholder |
| `secret-file` | a file that must never be committed at all: `sso.env`, `private.env`, a kubeconfig, a vault token, an SSH private key |

Both linters are self-testing: `--self-test` plants synthetic violations and asserts every rule
still fires, and both refuse to report `clean` when they collected no file to look at — a gate
that scanned nothing exits 0 exactly like a gate that scanned everything, so the run also prints
what it actually read (`28 module(s), 12 lib(s), 3 executable(s)`, `scanning 131 file(s)`) above
its verdict. A line ending in `# policy-allow: <rule>` is exempt from that one rule — for a
genuine, commented exception, never to silence a class.

## How idempotence is proven

`make test-docker` installs twice on `debian:12`, `debian:13`, `ubuntu:22.04` and `ubuntu:24.04`
(plus `ubuntu:26.04`, allowed to fail), fingerprinting the filesystem between the two runs and
diffing it. The dry-run check is the same idea inverted: fingerprint first, then run
`--dry-run`, then assert the fingerprint is byte-identical.

The fingerprint is the dpkg package list plus type, mode, size, mtime and a content digest for
everything under `$HOME`, `/etc`, `/usr/local` and `/opt`. A *file's* mtime counts on purpose —
rewriting a file with identical bytes is still a write, and idempotent means it must not have
happened. Only caches and container-volatile files are pruned; nothing this repository is
responsible for is.
