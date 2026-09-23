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

It also installs all three config repos — [nvim-config](https://github.com/Ujstor/nvim-config),
[tmux-config](https://github.com/Ujstor/tmux-config) and
[mybash](https://github.com/Ujstor/mybash) — **for your user and for root**, so `sudo -i` is not
a bare shell with a tmux that has no plugins. See
[External config repos](docs/configuration.md#external-config-repos); `DEVENV_ROOT_CONFIGS=0`
skips the root half, `DEVENV_EXTREPO_MYBASH=0` skips mybash for both accounts.

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
| **`devops`** *(default)* | `minimal` + Rust, Node, containers, Kubernetes, the kubectl/krew roster, k9s config, auth/SSO, IaC, cloud CLIs, editors (with the tree-sitter CLI), Claude Code and opencode, doctor |
| `full` | `devops` + repo-dev tooling, Yazi's preview stack, a Homebrew audit — and turns on `KREW_EXTRAS`, `INSTALL_PACKER`, `INSTALL_EXTRAS` |
| `ci` | everything a container can actually do: dotfiles, apt repos, release binaries. No docker daemon, no systemd, no interactive login helpers |
| `ai` | the opt-in AI agent CLI (crush). Claude Code and opencode are **not** here — they are base installs in `devops` |
| `private` | internal tooling from a private git forge, entirely env-driven. Silently skips when the variables are unset |
| `personal` | the owner's own odds and ends |

`migrate`, `headless-browser` and `purge-desktop` are in **no** profile and must be asked for by
name. The full module table, with every gate, is [docs/modules.md](docs/modules.md).

## What gets installed

Every tool, grouped by job, each name linked to its source repository. The first table is the
default `devops` profile — what the one-liner installs. The second is everything that needs
`--profile full` or a switch of its own. How each tool is installed, pinned and verified is
[docs/tools.md](docs/tools.md).

| group | in the default profile |
|---|---|
| **Base system** | [curl](https://github.com/curl/curl), [wget](https://gitlab.com/gnuwget/wget), [git](https://github.com/git/git), tar, [xz](https://github.com/tukaani-project/xz), zip, unzip, build-essential, pkg-config, [CMake](https://github.com/Kitware/CMake), [bash-completion](https://github.com/scop/bash-completion), [less](https://github.com/gwsw/less), [vim](https://github.com/vim/vim), [htop](https://github.com/htop-dev/htop), [tree](https://gitlab.com/OldManProgrammer/unix-tree), [jq](https://github.com/jqlang/jq), [psmisc](https://gitlab.com/psmisc/psmisc), [net-tools](https://github.com/ecki/net-tools), [ripgrep](https://github.com/BurntSushi/ripgrep), [fd](https://github.com/sharkdp/fd), [bat](https://github.com/sharkdp/bat), [trash-cli](https://github.com/andreafrancia/trash-cli), [autojump](https://github.com/wting/autojump), [tealdeer](https://github.com/tealdeer-rs/tealdeer) (`tldr`), [nala](https://gitlab.com/volian/nala) |
| **Network** | `dig` and `nslookup` ([BIND 9](https://gitlab.isc.org/isc-projects/bind9)), [nmap](https://github.com/nmap/nmap), [mtr](https://github.com/traviscross/mtr), traceroute, [tcpdump](https://github.com/the-tcpdump-group/tcpdump), `ping` ([iputils](https://github.com/iputils/iputils)), `htpasswd` ([apache2-utils](https://github.com/apache/httpd)), [wireguard-tools](https://github.com/WireGuard/wireguard-tools), sshpass |
| **Shell** | [mybash](https://github.com/Ujstor/mybash), [starship](https://github.com/starship/starship), [fzf](https://github.com/junegunn/fzf), [zoxide](https://github.com/ajeetdsouza/zoxide), [eza](https://github.com/eza-community/eza), [gdu](https://github.com/dundee/gdu), [7-Zip](https://github.com/ip7z/7zip), and the symbols-only [Nerd Font](https://github.com/ryanoasis/nerd-fonts) on a machine with its own display (not WSL, not headless) |
| **Git** | [gh](https://github.com/cli/cli), [glab](https://gitlab.com/gitlab-org/cli), [delta](https://github.com/dandavison/delta) |
| **Editors** | [Neovim](https://github.com/neovim/neovim), the [tree-sitter](https://github.com/tree-sitter/tree-sitter) CLI that nvim-config compiles its parsers with, [tmux](https://github.com/tmux/tmux), the [nvim-config](https://github.com/Ujstor/nvim-config) and [tmux-config](https://github.com/Ujstor/tmux-config) checkouts (tmux-config with [TPM](https://github.com/tmux-plugins/tpm) and its plugins), and `tmux-save-session.sh` |
| **Languages** | [Go](https://github.com/golang/go) with [goimports](https://github.com/golang/tools), [swag](https://github.com/swaggo/swag), [templ](https://github.com/a-h/templ), [go-blueprint](https://github.com/Melkeydev/go-blueprint) and [golangci-lint](https://github.com/golangci/golangci-lint); Rust via [rustup](https://github.com/rust-lang/rustup); [Node.js](https://github.com/nodejs/node) via [nvm](https://github.com/nvm-sh/nvm); Python via [uv](https://github.com/astral-sh/uv) |
| **Python CLIs** | [Ansible](https://github.com/ansible/ansible), [ansible-lint](https://github.com/ansible/ansible-lint), [Checkov](https://github.com/bridgecrewio/checkov), [yamllint](https://github.com/adrienverge/yamllint), [detect-secrets](https://github.com/Yelp/detect-secrets), [MkDocs](https://github.com/mkdocs/mkdocs) with [Material](https://github.com/squidfunk/mkdocs-material) and [mike](https://github.com/jimporter/mike), [Spec Kit](https://github.com/github/spec-kit) (`specify`) — each one an isolated `uv tool` |
| **Containers** | Docker Engine, except inside a container — [dockerd](https://github.com/moby/moby), the [docker CLI](https://github.com/docker/cli), [containerd](https://github.com/containerd/containerd), [buildx](https://github.com/docker/buildx), [compose](https://github.com/docker/compose) — plus [dive](https://github.com/wagoodman/dive) and [crane](https://github.com/google/go-containerregistry) |
| **Kubernetes** | [kubectl](https://github.com/kubernetes/kubectl), [Helm](https://github.com/helm/helm), [k9s](https://github.com/derailed/k9s) with this repository's plugins and skins, [kubecolor](https://github.com/kubecolor/kubecolor), [k3d](https://github.com/k3d-io/k3d), [kind](https://github.com/kubernetes-sigs/kind), [kustomize](https://github.com/kubernetes-sigs/kustomize), [kubeconform](https://github.com/yannh/kubeconform), [cilium CLI](https://github.com/cilium/cilium-cli), [hubble](https://github.com/cilium/hubble), [argocd](https://github.com/argoproj/argo-cd), [virtctl](https://github.com/kubevirt/kubevirt), Azure's [kubelogin](https://github.com/Azure/kubelogin), [kubectl-pgo](https://github.com/CrunchyData/postgres-operator-client), [velero](https://github.com/velero-io/velero), [crictl](https://github.com/kubernetes-sigs/cri-tools), [yq](https://github.com/mikefarah/yq), [trivy](https://github.com/aquasecurity/trivy), [grpcurl](https://github.com/fullstorydev/grpcurl) |
| **kubectl plugins** | [krew](https://github.com/kubernetes-sigs/krew), and through it [ctx, ns](https://github.com/ahmetb/kubectx), [neat](https://github.com/itaysk/kubectl-neat), [tree](https://github.com/ahmetb/kubectl-tree), [stern](https://github.com/stern/stern), [node-shell](https://github.com/kvaps/kubectl-node-shell), [oidc-login](https://github.com/int128/kubelogin), [kyverno](https://github.com/kyverno/kyverno), [rook-ceph](https://github.com/rook/kubectl-rook-ceph), [virt](https://github.com/kubevirt/kubectl-virt-plugin), [cilium](https://github.com/bmcustodio/kubectl-cilium), [view-secret](https://github.com/elsesiy/kubectl-view-secret), [modify-secret](https://github.com/rajatjindal/kubectl-modify-secret), [get-all](https://github.com/stackitcloud/kubectl-get-all), [resource-capacity](https://github.com/robscott/kube-capacity), [whoami](https://github.com/rajatjindal/kubectl-whoami), [explore](https://github.com/keisku/kubectl-explore), [df-pv](https://github.com/yashbhutwala/kubectl-df-pv), [deprecations](https://github.com/kubepug/kubepug) |
| **Helm plugins** | [diff](https://github.com/databus23/helm-diff), [schema](https://github.com/losisin/helm-values-schema-json), [unittest](https://github.com/helm-unittest/helm-unittest), and the standalone [helm-docs](https://github.com/norwoodj/helm-docs) |
| **IaC** | [Terraform](https://github.com/hashicorp/terraform), [TFLint](https://github.com/terraform-linters/tflint), [terraform-docs](https://github.com/terraform-docs/terraform-docs), [OpenBao](https://github.com/openbao/openbao) (`bao`) |
| **Cloud** | [Azure CLI](https://github.com/Azure/azure-cli), [hcloud](https://github.com/hetznercloud/cli) |
| **AI agents** | [Claude Code](https://github.com/anthropics/claude-code), [opencode](https://github.com/anomalyco/opencode) |
| **Browser-less login** | this repository's own `open-url`, `clip`, `clip-paste`, `sso-login`, `sso-kubeconfig-add` and `web`, plus the `xdg-open`/`pbcopy` shims — [docs/sso.md](docs/sso.md) |
| **WSL only** | [wslu](https://github.com/wslutilities/wslu) |

| extra | how to get it |
|---|---|
| [yazi](https://github.com/sxyazi/yazi), [fastfetch](https://github.com/fastfetch-cli/fastfetch), [duf](https://github.com/muesli/duf), [black](https://github.com/psf/black), [multitail](https://github.com/folkertvanheusden/multitail), [ipmitool](https://codeberg.org/IPMITool/ipmitool), `puttygen` (putty-tools), the [OpenJDK 17](https://github.com/openjdk/jdk17u) JRE, [clang](https://github.com/llvm/llvm-project) and libclang | `--profile full`, or `--extras` |
| [rbac-tool](https://github.com/alcideio/rbac-tool), [rolesum](https://github.com/Ladicle/kubectl-rolesum), [lineage](https://github.com/tohjustin/kube-lineage), [status](https://github.com/bergerx/kubectl-status), [blame](https://github.com/knight42/kubectl-blame), [images](https://github.com/chenjiandongx/kubectl-images), [outdated](https://github.com/replicatedhq/outdated), [pv-migrate](https://github.com/utkuozdemir/pv-migrate), [browse-pvc](https://github.com/clbx/kubectl-browse-pvc), [konfig](https://github.com/corneliusweig/konfig), [gadget](https://github.com/inspektor-gadget/inspektor-gadget), [sniff](https://github.com/eldadru/ksniff), [popeye](https://github.com/derailed/popeye), [score](https://github.com/zegl/kube-score) — kubectl plugins; Helm [secrets](https://github.com/jkroepke/helm-secrets) and [helm-git](https://github.com/aslafy-z/helm-git) | `--profile full`, or `--extras` |
| [Packer](https://github.com/hashicorp/packer) | `--profile full` |
| [ffmpeg](https://github.com/FFmpeg/FFmpeg), [ImageMagick](https://github.com/ImageMagick/ImageMagick), [poppler-utils](https://gitlab.freedesktop.org/poppler/poppler), [ExifTool](https://github.com/exiftool/exiftool), [resvg](https://github.com/linebender/resvg) — Yazi's previewers | `--profile full` |
| [ShellCheck](https://github.com/koalaman/shellcheck), [shfmt](https://github.com/mvdan/sh), [pre-commit](https://github.com/pre-commit/pre-commit) — this repository's own CI tools | `--profile full` |
| [kor](https://github.com/yonahd/kor), [kube-linter](https://github.com/stackrox/kube-linter), [kube-bench](https://github.com/aquasecurity/kube-bench), [nerdctl](https://github.com/containerd/nerdctl), [kubeseal](https://github.com/bitnami/sealed-secrets) | `INSTALL_K8S_OPT=1` — not even `full` sets it |
| [crush](https://github.com/charmbracelet/crush) | `--profile ai` |
| [mise](https://github.com/jdx/mise), in place of nvm | `NODE_MANAGER=mise` |
| [qrencode](https://github.com/fukuchi/libqrencode), to show a login URL as a QR code | `DEVENV_BROWSER_QR=1` |
| [Playwright](https://github.com/microsoft/playwright)'s system libraries — no browser | `devenv --only headless-browser` |
| [Homebrew](https://github.com/Homebrew/brew) | `INSTALL_HOMEBREW=1 devenv --only brew` — `full` only audits an existing one |

The `private` and `personal` profiles install only what you configure for them, and nothing when
you have not.

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
  yours. `mybash` keeps its own path, `~/linuxtoolbox/mybash`.
* **`/root/.local/share/devops-env/repos/`** — the same checkouts again, for root, linked from
  root's own dotfiles. Root's copies never point into your home.
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
