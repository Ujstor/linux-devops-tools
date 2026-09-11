# Modules

A module is an executable `modules/NN-name.sh`. `NN` is run order and nothing else — there is
no dependency graph, and every module is individually runnable. A **profile** is a plain list
of module names.

**Source of truth:** the `# meta:` headers in `modules/*.sh` (gates) and `profiles/*.list`
(membership). `devenv list` prints both as TSV — trust it over this page.

```bash
devenv list | column -t -s "$(printf '\t')"
```

## The table

Verified 2026-09-11 against `devenv list`.

| # | module | profiles | os | arch | needs | root | what it does |
|---|---|---|---|---|---|---|---|
| 00 | `preflight` | min, dev, full, ci | any | any | — | no | check the distribution is supported, create `$DEVENV_CONFIG`/`$DEVENV_CACHE`/`$DEVENV_STATE`, migrate legacy apt sources, install the bootstrap package set — asking for root only if something is actually missing |
| 05 | `base-packages` | min, dev, full, ci | any | any | — | **yes** | the one apt base list: build tools, network tools, `jq`, `ripgrep`, `fd`, `bat`, `tldr`, `bash-completion` |
| 10 | `shell` | min, dev, full, ci | any | any | — | no | the `~/.bashrc` managed block, the `~/.bashrc.d/` fragments, prompt, lazy completion cache, `fzf`/`zoxide`/`eza`/`yazi`/`starship`, and the `shell` entries of the [external config repo list](configuration.md#external-config-repos) (`mybash`, off by default) |
| 15 | `git` | min, dev, full, ci | any | amd64, arm64 | `git` | no | `~/.config/git/ignore`, `gh`, `git-delta`. Git config is **a plan by default** — see below |
| 20 | `lang-go` | min, dev, full, ci | any | any | — | **yes** | the Go toolchain to `/usr/local/go` plus the pinned `go install` tools |
| 21 | `lang-rust` | dev, full | any | any | — | no | `rustup`. Rust is kept as a language, not as a package manager |
| 22 | `lang-node` | dev, full | any | any | — | no | `nvm` at `~/.config/nvm`, lazily loaded so it costs nothing per shell. `mise` with `DEVENV_NODE_MANAGER=mise` |
| 23 | `lang-python` | min, dev, full, ci | any | any | — | no | `uv`, and every Python CLI as a `uv tool` — never `pip --user`, never touching PEP 668 |
| 28 | `repo-dev` | full | any | any | — | no | `shellcheck`, `shfmt`, `pre-commit` — what CI for *this* repository needs |
| 30 | `containers` | dev, full | **!container** | amd64, arm64 | — | **yes** | `docker-ce` from Docker's own repository, service start, and the docker-group question |
| 35 | `kubernetes` | dev, full, ci | any | amd64, arm64 | — | **yes** | `kubectl`, `helm`, `k9s`, `k3d`, `kind`, `argocd`, `cilium`, `hubble`, `virtctl`, `kustomize`, `kubeconform`, `velero`, `crictl`, `trivy`, `yq` |
| 36 | `k8s-plugins` | dev, full, ci | any | amd64, arm64 | `kubectl` | no | `krew` plus the kubectl plugin roster, and the Helm plugins (`diff`, `schema`, `unittest`, …) |
| 37 | `k9s-config` | dev, full, ci | any | amd64, arm64 | — | no | k9s plugins, hotkeys, aliases and skins, plus a skin that follows the current context |
| 38 | `auth-sso` | dev, full | any | amd64, arm64 | — | no | the `open-url` browser shim, `clip`/`clip-paste`, `sso-login`, `sso-kubeconfig-add`, `web`, and the config templates. **No browser, no new binaries** |
| 40 | `iac` | dev, full, ci | any | amd64, arm64 | — | **yes** | `terraform`, `tflint`, `terraform-docs`, OpenBao's `bao`, and the Ansible/security Python CLIs |
| 45 | `cloud` | dev, full, ci | any | amd64, arm64 | — | **yes** | `gh`, `glab`, `azure-cli`, `hcloud`, `crane`, Azure's `kubelogin` |
| 50 | `editors` | dev, full | any | any | — | no | Neovim from upstream, `tmux`, `~/.tmux-sessions/tmux-save-session.sh`, and the `editors` entries of the [external config repo list](configuration.md#external-config-repos) — cloned and symlinked, never curl-piped |
| 55 | `media` | full | any | any | — | **yes** | `ffmpeg`, ImageMagick, `poppler-utils`, 7-Zip — Yazi's preview stack, each independently useful on a server |
| 58 | `headless-browser` | **none** | !container | amd64, arm64 | `npx` | **yes** | Playwright's system dependency set, delegated to `npx playwright install-deps`. No browser UI |
| 65 | `ai` | dev, full, ai | any | any | — | no | **Claude Code** via its native installer (install-if-absent, never managed afterwards); `opencode` and `crush` when `INSTALL_AI_AGENTS=1` |
| 70 | `wsl` | min, dev, full | **wsl** | any | — | no | a no-op unless this really is WSL: `wslu`, the systemd question, the restart hint |
| 80 | `private` | private | any | any | — | no | internal tooling from a private git forge. Every host comes from the environment; nothing internal is committed here |
| 85 | `personal` | personal | any | any | — | no | the owner's own side-project CLIs, entirely env-driven |
| 90 | `doctor` | dev, full | any | any | — | no | read-only audit of shell, apt sources, kubernetes, SSO and WSL; `--fix` repairs only what is safe |
| 91 | `purge-desktop` | **none** | any | any | — | **yes** | report, and optionally remove, the compositor/browser/VNC residue an older provisioning left |
| 92 | `migrate` | **none** | any | any | — | no | report what `wsl2-config` left behind. Changes nothing unless asked |
| 95 | `brew` | full | any | any | — | no | audit-only: lists your Homebrew leaves and maps each to its apt/release equivalent |
| 99 | `summary` | min, dev, full, ci | any | any | — | no | what changed, what was skipped and why, and the exact next steps |

`min` = `minimal`, `dev` = `devops` (the default). Which tool comes from where, and what was
deliberately left out, is [docs/tools.md](tools.md).

## Gates

`os` → `arch` → `needs` → `root` are applied before a module starts. A gate that does not hold
is a **skip**, never a failure: nothing runs, the run continues, and the summary says why.

| gate value | meaning |
|---|---|
| `os=any` | runs everywhere |
| `os=!container` | skipped inside a container — there is no daemon or no udev to talk to |
| `os=wsl` | skipped unless `/run/WSL` or `/usr/lib/wsl` exists. **Never** `$WSL_DISTRO_NAME` |
| `arch=amd64,arm64` | an upstream asset exists for both. Anything else skips with a reason |
| `needs=kubectl` | that command must be on `PATH` |
| `root=yes` | the module calls `run_sudo`. **No usable sudo is a skip**, not a failure |

## The three that are in no profile

They are destructive, one-shot, or expensive, so they must be asked for by name:

```bash
devenv --only migrate                             # report; changes nothing
DEVENV_MIGRATE_APPLY=1 devenv --only migrate      # actually neutralise what it found
devenv --only purge-desktop                       # report; --allow-pkg-remove to remove
devenv --only headless-browser                    # Playwright's system deps
```

> [!NOTE]
> `--apply` is an argument of `migrate` and `git` when you execute the module file directly
> (`./modules/92-migrate.sh --apply`). `devenv` has no `--apply` flag — from the CLI, use
> `DEVENV_MIGRATE_APPLY=1` / `DEVENV_GIT_APPLY=1`.

## Modules that plan instead of doing

Two modules default to printing what they *would* change, because the thing they touch is
personal and hand-made:

| module | default | how to let it write |
|---|---|---|
| `git` | prints the diff between your `git config --global` and this repo's defaults, and keeps yours | `DEVENV_GIT_APPLY=1 devenv --only git` — still set-if-absent, and never `user.*`, `commit.gpgsign`, `credential.*`, an `includeIf` scheme or `http.sslVerify` |
| `migrate` | reports `wsl2-config` residue | `DEVENV_MIGRATE_APPLY=1 devenv --only migrate` |

`brew` and `doctor` never write at all unless you pass `INSTALL_HOMEBREW=1` / `--fix`.

## Adding one

The module-author contract — the meta header, the exit protocol (`0` / `78` / anything else),
the library API and the five rules — is [docs/development.md](development.md).
