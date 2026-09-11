# linux-devops-tools

One command turns a fresh **Debian** or **Ubuntu** box — a WSL2 distro, a VM, a cloud instance,
a container — into a terminal-only DevOps workstation: kubectl and its plugin roster, k9s with
its plugins and skins, Helm, Terraform, Docker, the cloud CLIs, Go/Rust/Node/Python, a curated
shell, and a way to finish **browser logins from a machine that has no browser**.

No desktop environment, no compositor, no GUI browser in any profile. A second run changes
nothing, and `--dry-run` is a true no-op.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash
```

That clones the repository to `~/.local/share/linux-devops-tools` and runs the default `devops`
profile. Nothing is installed system-wide until a module that needs root actually runs, and it
asks then — never up front.

```bash
# Look before you leap. Every mutation goes through one gate, so this changes nothing.
curl -fsSL .../install.sh | bash -s -- --dry-run

# From a checkout: the same code path, no clone.
git clone https://github.com/Ujstor/linux-devops-tools.git && cd linux-devops-tools
./install.sh --dry-run
./install.sh --profile minimal
```

Then:

```bash
exec bash -l          # pick up the shell integration
devenv --help
devenv doctor
```

Everyday commands, updating and uninstalling are [docs/usage.md](docs/usage.md).

## Profiles

A profile is a plain list of module names in `profiles/*.list`. Pick one with `--profile NAME`.

| profile | what you get |
|---|---|
| `minimal` | preflight, base packages, shell, git, Go, Python, WSL fixes, summary — a jump host where you only want the shell to feel right |
| **`devops`** *(default)* | `minimal` + Rust, Node, containers, Kubernetes, the kubectl/krew roster, k9s config, auth/SSO, IaC, cloud CLIs, editors, Claude Code, doctor |
| `full` | `devops` + repo-dev tooling, Yazi's preview stack, a Homebrew audit — and turns on `KREW_EXTRAS`, `INSTALL_PACKER`, `INSTALL_EXTRAS` |
| `ci` | everything a container can actually do: dotfiles, apt repos, release binaries. No docker daemon, no systemd, no interactive login helpers |
| `ai` | the opt-in AI agent CLIs (opencode, crush). Claude Code is **not** here — it is a base install in `devops` |
| `private` | internal tooling from a private git forge, entirely env-driven. Silently skips when the variables are unset |
| `personal` | the owner's own odds and ends |

`migrate`, `headless-browser` and `purge-desktop` are in **no** profile and must be asked for by
name. The full module table, with every gate, is [docs/modules.md](docs/modules.md).

## Supported systems

| distribution | codename | status |
|---|---|---|
| **Debian 12** | bookworm | supported, tested in CI |
| **Debian 13** | trixie | supported, tested in CI |
| **Ubuntu 22.04 LTS** | jammy | supported, tested in CI |
| **Ubuntu 24.04 LTS** | noble | supported, tested in CI |
| Ubuntu 26.04 LTS | — | best-effort; runs in CI but is allowed to fail |
| Debian testing/sid | — | runs; repositories with no suite for it take their fallback branch |
| Mint, LMDE, Pop!\_OS and other Debian derivatives | — | best-effort: the upstream codename is resolved and used for vendor repos |
| anything not Debian-family | — | **refused**, with a message that says so |

Bare metal, VM, WSL2 and container all run the same code: `os_detect` reports the environment and
modules gate themselves on it. There is no separate "WSL edition" — see [docs/wsl.md](docs/wsl.md).

**Architectures.** `amd64`/`x86_64` is what is built and tested; nothing else is claimed. `arm64`
is best-effort and honestly so: the architecture mapping is complete, modules declare
`arch=amd64,arm64` where an arm64 asset genuinely exists, and where an upstream publishes none
the installer **skips with a reason** instead of silently installing nothing. There is no arm64
CI job. `armhf`, `i386`, `ppc64el`, `riscv64` and `s390x` are detected and mapped, and nearly
everything with a release binary will skip; the shell layer still works.

## What it changes on your machine

* **`~/.bashrc`** — one marker-fenced block that sources `~/.bashrc.d/00-init.bash`. A symlinked
  `~/.bashrc` is written *through*, never replaced.
* **`~/.bashrc.d/`** — the shell fragments. `90-local.sh` is yours: created once, never
  overwritten, never pruned.
* **`~/.local/bin/`** — `open-url`, `clip`, `clip-paste`, `sso-login`, and the `xdg-open`/`pbcopy`
  shims that make browser-based SSO work without a browser.
* **`~/.config/devops-env/`** — `sso.env`, `bookmarks`, `private.env`, `external-repos.sh`,
  seeded once from the shipped examples, mode 0600 where a hostname is involved, then never
  touched again. Your real hostnames live here.
* **`~/.local/share/devops-env/repos/`** — the external config checkouts (`nvim-config`,
  `tmux-config`, and anything you add to `~/.config/devops-env/external-repos.sh`), plus the
  symlinks each one declares. Never cloned over a dirty worktree, never linked over a file of
  yours.
* **`~/.tmux-sessions/`** — `tmux-save-session.sh`, and the restore scripts it writes beside
  itself.
* **`~/.config/k9s/`** — plugins, hotkeys, aliases and skins; `config.yaml` is created once and
  then left to k9s.
* **`/etc/apt/sources.list.d/`** and **`/etc/apt/keyrings/`** — deb822 sources and armored keys
  for Docker, HashiCorp, Kubernetes, GitHub CLI, Azure CLI and Trivy.
* **`/usr/local/bin`, `/usr/local/go`** — release binaries and the Go toolchain. Shared, so
  `uninstall` lists them instead of removing them.
* **`~/.local/state/devops-env/`** — a manifest with a digest per installed file. That is what
  makes `devenv uninstall` honest: a file you edited afterwards is kept and reported, not deleted.

Every knob, path and override: [docs/configuration.md](docs/configuration.md). What this tool
will never do to your machine: [docs/safety.md](docs/safety.md).

## Documentation

| document | what is in it |
|---|---|
| [docs/usage.md](docs/usage.md) | everyday commands, `--only`/`--skip`/`list`, updating, uninstalling |
| [docs/configuration.md](docs/configuration.md) | `versions.env`, feature gates, `DEVENV_*`, `~/.config/devops-env/`, the `bashrc.d` fragment model |
| [docs/modules.md](docs/modules.md) | every module: number, profiles, gates, what it does |
| [docs/tools.md](docs/tools.md) | the tool catalog: what is installed, by which module, from where — and what was deliberately left out |
| [docs/sso.md](docs/sso.md) | logging in from a box with no browser: host modes, the callback problem, the `ssh -L` table, Keycloak→kubectl, Azure/AKS, GitHub, GitLab, Argo CD, OpenBao |
| [docs/keycloak-client.md](docs/keycloak-client.md) | the identity-provider side: client settings, redirect URIs, the `groups` mapper, API-server flags |
| [docs/safety.md](docs/safety.md) | the rules this repository holds itself to, and what it will never do |
| [docs/wsl.md](docs/wsl.md) | WSL-specific notes and the Windows-side `wsl.exe` reference |
| [docs/migration.md](docs/migration.md) | migrating from `wsl2-config`, and from this repository's own former name `devops-env-config` |
| [docs/development.md](docs/development.md) | working on this repo: `make` targets, the policy linters, the module contract |
| [lib/README.md](lib/README.md) | the shell library API |
| [`versions.env`](versions.env) | **every pin in the repository.** Nothing else pins anything |

## Coming from an older name

This repository has been `Ujstor/wsl2-config` and, after that, `Ujstor/devops-env-config`.
GitHub redirects the first — it was a real repository, renamed. The second was never a GitHub
repository at all, so there is nothing to redirect from and a one-liner still pointing at it
**404s** outright.

**From `wsl2-config`** — a set of curl-piped scripts for one WSL2 box. A machine those scripts
provisioned has residue worth cleaning up. Install this tool first, then — before changing
anything else — run the report:

```bash
devenv --only migrate        # reports only; DEVENV_MIGRATE_APPLY=1 makes it act
```

**From `devops-env-config`** — the same tool under a new name. The command is still `devenv`,
every `DEVENV_*` variable is unchanged, and nothing in `~/.config/devops-env/`,
`~/.cache/devops-env/` or `~/.local/state/devops-env/` moves. Two things do move: the checkout
(`~/.local/share/devops-env-config` → `~/.local/share/linux-devops-tools`) and the marker on the
managed `~/.bashrc` block. The marker takes care of itself — the block is re-fenced in place on
the next run, never duplicated. Re-run the installer above, then delete the old checkout:

```bash
rm -rf ~/.local/share/devops-env-config
```

[docs/migration.md](docs/migration.md) covers both, with the exact commands.
