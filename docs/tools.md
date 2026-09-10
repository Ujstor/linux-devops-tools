# The tool catalog

Everything this repository installs, which module owns it, where it comes from, and which profile
puts it on your box. It also lists what was deliberately **not** installed, with the reason — that
half is just as useful when you are wondering why your favourite thing is missing.

The authoritative machine-readable version of the module side is `devenv list`; the authoritative
version of every pin is [`versions.env`](../versions.env).

## How to read the tables

**Profile** — `min` = `minimal`, `dev` = `devops` (the default), `full`, `ci`, `opt` = a module
exists but the tool is behind a feature gate, `priv`/`pers` = the private/personal profiles.
A tool listed at `min` is in every richer profile too.

**Method** — how it is installed:

| code | meaning |
|---|---|
| `apt` | the distribution's own archive |
| `apt-v` | a vendor apt repository (deb822 `.sources` + an armored key in `/etc/apt/keyrings`) |
| `a/r` | apt when the candidate is new enough, otherwise a pinned release binary |
| `deb` | a `.deb` from the project's releases, installed with `apt-get install ./file.deb` |
| `rel` | a release binary or tarball, checksum-verified |
| `go` | `go install module@version` |
| `uv` | `uv tool install` — an isolated venv per tool |
| `cargo` | `cargo install` |
| `script` | the project's own installer, pinned and checksum-verified where the vendor allows it |

Every download is checksum-verified. Where an upstream publishes no checksum, the call site must say
so explicitly and give a reason — there is a policy test for it.

---

## Base, shell and editors

| tool | method | pin | module | profile | notes |
|---|---|---|---|---|---|
| ca-certificates, curl, wget, git, tar, xz-utils, unzip, zip | apt | — | `preflight`, `base-packages` | min | the bootstrap set, installed only when missing |
| build-essential, pkg-config, cmake | apt | — | `base-packages` | min | |
| psmisc, net-tools, tree, less, htop, jq, vim | apt | — | `base-packages` | min | |
| bash-completion | apt | — | `base-packages` | min | a **hard dependency** of the lazy completion cache |
| trash-cli, autojump | apt | — | `base-packages` | min | `autojump` is superseded by `zoxide`; a `j` → `z` alias keeps the muscle memory |
| ripgrep, fd-find, bat | apt | — | `base-packages` | min | Debian names the binaries `fdfind` and `batcat`; `~/.local/bin` symlinks fix that, and only when nothing else provides the name |
| tealdeer (`tldr`) | apt-first, else `rel` | `TEALDEER_VERSION` | `base-packages` | min | package name differs by release; the cache is seeded on install |
| bind9-dnsutils, nmap, mtr-tiny, traceroute, tcpdump, iputils-ping | apt | — | `base-packages` | dev | DNS and reachability are load-bearing on any fleet |
| apache2-utils | apt | — | `base-packages` | dev | `htpasswd`, for ingress basic-auth |
| wireguard-tools | apt | — | `base-packages` | dev | the **tools**, not `wireguard` — there is no kernel module under WSL |
| sshpass | apt | — | `base-packages` | dev | Ansible `--ask-pass` |
| multitail, ipmitool, putty-tools, openjdk-17-jre-headless | apt | — | `base-packages` | full | on-prem and out-of-band work |
| nala | apt | — | `base-packages` | dev | only when the archive already has a candidate. Never a backport, never a third-party repo, and it never redefines `sudo` |
| fzf | a/r ≥ 0.48 | `FZF_VERSION` | `shell` | min | 0.48 is where `fzf --bash` appeared; older archives take the release binary |
| zoxide | a/r ≥ 0.9.0 | `ZOXIDE_VERSION` | `shell` | min | bookworm and jammy ship 0.4.3 |
| eza | rel | `EZA_VERSION` | `shell` | min | absent from bookworm and jammy entirely, so always the tarball |
| starship | script | `STARSHIP_VERSION` | `shell` | min | prompt config is left alone if you already have one |
| 7-Zip (`7zz`) | apt-first | — | `shell` | dev | `7zip` or `p7zip-full`, whichever exists; `~/.local/bin/7z` symlink |
| gdu | apt, else `go` | `GO_TOOL_GDU` | `shell` | dev | packaged nearly everywhere — no reason to compile it |
| yazi | deb | `YAZI_VERSION` | `shell` | full | in no distribution archive |
| fastfetch | apt-first, else deb | `FASTFETCH_VERSION` | `shell` | full | absent from bookworm and noble |
| duf | apt | — | `shell` | full | |
| Nerd Font (symbols only) | rel | `NERD_FONT_VERSION` | `shell` | opt | **only** on a box that is neither WSL nor headless — everywhere else the glyphs are the terminal's job, on the machine you are actually looking at |
| git-delta | a/r ≥ 0.16 | `DELTA_VERSION` | `git` | dev | absent from bookworm |
| gh | apt-v | — | `git`, `cloud` | min | the suite is literally `stable`, so the source line is identical on both distributions |
| neovim | rel | `NEOVIM_VERSION` | `editors` | dev | always upstream: bookworm has 0.7.2 and noble 0.9.5, both too old for a modern Lua config |
| tmux | apt (or source with `TMUX_FROM_SOURCE=1`) | — | `editors` | dev | |
| `nvim-config`, `tmux-config` | git clone + symlink | `NVIM_CONFIG_REF`, `TMUX_CONFIG_REF` | `editors` | dev | cloned and symlinked, **never** curl-piped, and never updated over a dirty worktree |
| `mybash` | detect and report | `MYBASH_REF` | `shell` | dev | it owns `~/.bashrc` on a box that has it; re-running its setup is a data-loss event, so this repository only reports what it finds |

## Kubernetes core (module `kubernetes`)

| tool | method | pin | profile | notes |
|---|---|---|---|---|
| kubectl | apt-v (flat repo) | `K8S_MINOR` | dev | `pkgs.k8s.io` is a flat repository — one line, no distribution branch. A downgrade is refused rather than performed |
| helm | rel + published `.sha256sum` | `HELM_VERSION` | dev | pinned to 3.x on purpose; the `get-helm-3` script would happily walk into Helm 4 |
| k9s | deb, else tarball | `K9S_VERSION` | dev | the tarball is `k9s_Linux_…`, the `.deb` is `k9s_linux_…`. Both exist for every release |
| kubecolor | rel | `KUBECOLOR_VERSION` | dev | the `kubectl` alias is guarded by `command -v kubecolor` |
| k3d | script (`TAG=`) | `K3D_VERSION` | dev | |
| kind | rel | `KIND_VERSION` | dev | architecture-aware |
| cilium CLI | rel + `sha256sum` | `CILIUM_CLI_VERSION` | dev | the standalone CLI. **Not** the krew `cilium` plugin — both are installed, see below |
| hubble | rel | `HUBBLE_VERSION` | full | flow visibility |
| argocd | rel | `ARGOCD_VERSION` | dev | |
| virtctl | rel | `VIRTCTL_VERSION` | dev | must match the cluster's KubeVirt; a shipped k9s plugin calls it |
| kustomize | rel, tag filter `^kustomize/` | `KUSTOMIZE_VERSION` | full | a monorepo: `releases/latest` can point at a completely different component |
| kubeconform | rel | `KUBECONFORM_VERSION` | dev | |
| kubectl-pgo | rel | `KUBECTL_PGO_VERSION` | dev | Crunchy PGO's own CLI; not in the krew index |
| velero | rel | `VELERO_VERSION` | full | the repository was renamed upstream; release lookups follow redirects |
| crictl | rel | `CRICTL_VERSION` | full | k3s runs containerd |
| trivy | apt-v (suite `generic`) | — | dev | one identical source line on both distributions |
| dive | deb | `DIVE_VERSION` | full | the tag is `v0.13.1` and the asset drops the `v` — a good example of why there is exactly one tag rule |
| yq (mikefarah v4) | rel | `YQ_VERSION` | dev | the distro `yq` is a different program (a Python wrapper around `jq`). It is reported, never removed |
| kubelogin (Azure) | rel | `KUBELOGIN_VERSION` | dev | `convert-kubeconfig` for AKS. A **different project** from krew `oidc-login` |
| kor, kube-linter, kube-bench, nerdctl, kubeseal | rel/deb | pinned | opt | behind `INSTALL_K8S_OPT=1`; `full` does not turn these on |

## kubectl and Helm plugins (module `k8s-plugins`)

`krew` itself is pinned by `KREW_VERSION`. Plugin installation is a per-plugin loop: one plugin
failing is a warning, never a failed module.

**Always installed:**

```
ctx  ns  neat  tree  stern  node-shell  oidc-login  kyverno  rook-ceph  virt  cilium
view-secret  modify-secret  get-all  resource-capacity  whoami  explore  df-pv  deprecations
```

**With `KREW_EXTRAS=1` (set by the `full` profile):**

```
rbac-tool  rolesum  lineage  status  blame  images  outdated  pv-migrate  browse-pvc
konfig  gadget  sniff  popeye  score
```

Two pairs that look like duplicates and are not — do not "deduplicate" either:

* krew **`cilium`** and the standalone **`cilium` CLI**. Several shipped k9s plugins run
  `kubectl cilium …`; other work needs the standalone binary.
* krew **`virt`** and **`virtctl`**. Same story, and the version must track the cluster's KubeVirt.

`netshoot` is not a krew plugin here; it is a shell function, because that is all it ever was:

```bash
kdebug() { kubectl debug -it --image=nicolaka/netshoot "$@"; }
```

Helm plugins, guarded on the **registered** name (which is what `helm plugin list` shows):

| registered name | source | pin | profile |
|---|---|---|---|
| `diff` | `databus23/helm-diff` | `HELM_DIFF_VERSION` | dev |
| `schema` | `losisin/helm-values-schema-json` | `HELM_SCHEMA_VERSION` | dev — replaces the archived `schema-gen` |
| `unittest` | `helm-unittest/helm-unittest` | `HELM_UNITTEST_VERSION` | dev |
| `secrets` | `jkroepke/helm-secrets` | `HELM_SECRETS_VERSION` | full |
| `helm-git` | `aslafy-z/helm-git` | — | full |
| `helm-docs` | standalone binary, not a plugin | `HELM_DOCS_VERSION` | dev |

Refresh the whole plugin layer — krew, helm plugins and the k9s files — at any time:

```bash
devenv --only k8s-plugins
devenv --only k9s-config
```

## k9s (module `k9s-config`)

Not a tool but a configuration layer, and the reason several of the above exist:

| file | how it is written |
|---|---|
| `~/.config/k9s/plugins/*.yaml` | owned by this repository (`write_managed`, mode 0600). A hand-edit is detected and backed up, never silently clobbered |
| `~/.config/k9s/skins/*.yaml` | owned the same way; a skin follows the current context so a production cluster does not look like a lab one |
| `~/.config/k9s/hotkeys.yaml`, `aliases.yaml` | **merged** — only missing top-level keys are added, so your own entries survive |
| `~/.config/k9s/config.yaml` | created once, then left alone. k9s rewrites this file itself |
| `~/.config/k9s/plugins.yaml` | never touched |

Two constraints on the shipped plugins that are easy to get wrong if you add your own: no shortcut
may collide with a k9s built-in (`Shift-P` is Sort Namespace, for instance), and `Shift-<digit>`
is unusable because it resolves to a US-layout ASCII rune and misfires on any other keyboard.
Decoded secrets go to the pager and nowhere else — never to a file, never to a clipboard binary.

## IaC, cloud and containers

| tool | method | module | profile | notes |
|---|---|---|---|---|
| docker-ce + cli + containerd.io + buildx + compose | apt-v | `containers` | dev | conflicting packages are **reported**, not purged. Group membership is root-equivalent and needs `--allow-docker-group` |
| terraform | apt-v | `iac` | dev | `TERRAFORM_VERSION=apt` — the HashiCorp repository decides. The suite is verified before the source file is written |
| packer | apt-v | `iac` | full | behind `INSTALL_PACKER=1` |
| terraform-docs | rel | `iac` | dev | `TERRAFORM_DOCS_VERSION` |
| tflint | rel | `iac` | dev | `TFLINT_VERSION` |
| bao (OpenBao) | deb | `iac` | dev | `OPENBAO_VERSION`. The package is `openbao`, the binary is `bao` |
| ansible, ansible-lint | uv | `iac` | dev | installed `--with kubernetes --with netaddr --with jmespath`, or half the playbooks fail at runtime |
| checkov, yamllint, detect-secrets, pre-commit | uv | `lang-python`, `repo-dev` | dev | |
| mkdocs (+ mkdocs-material, mike) | uv `mkdocs --with mkdocs-material --with mike` | `iac` | dev | the theme ships no console script, so `mkdocs` is the tool and the theme is a `--with`; `mike` is an mkdocs plugin and needs the same venv |
| black | uv | `lang-python` | full | |
| specify-cli (Spec Kit) | uv `--from git+…` | `lang-python` | dev | `SPEC_KIT_REF` |
| gh | apt-v | `cloud` | min | |
| glab | deb from **gitlab.com** | `cloud` | dev | `GLAB_VERSION`. Released on GitLab, not GitHub — the GitHub feed is empty |
| azure-cli | apt-v, else uv | `cloud` | dev | no `trixie` build exists; the module maps newer suites to `noble` and finally skips with a reason |
| hcloud | go | `cloud` | dev | `GO_TOOL_HCLOUD` |
| crane | go | `cloud` | dev | `GO_TOOL_CRANE` |

## Language toolchains

| tool | method | pin | module | profile | notes |
|---|---|---|---|---|---|
| Go | tarball → `/usr/local/go` | `GO_VERSION` | `lang-go` | min | version-gated on `go env GOVERSION`; the module cache is never wiped |
| goimports, swag, templ, go-blueprint | go | `GO_TOOL_*` | `lang-go` | dev | |
| golangci-lint | rel | `GOLANGCI_LINT_VERSION` | `lang-go` | dev, full, ci | release binary, not `go install` |
| shfmt | go | `GO_TOOL_SHFMT` | `repo-dev` | full | |
| Rust (rustup) | script | `RUST_TOOLCHAIN` | `lang-rust` | dev | kept as a language, not as a package manager |
| Node via nvm | script | `NVM_VERSION`, `NODE_VERSION` | `lang-node` | dev | `NVM_DIR=~/.config/nvm`, lazily loaded so it costs nothing per shell |
| uv / uvx | script | `UV_VERSION` | `lang-python` | min | foundational: installed before any Python CLI |
| mise | script | `MISE_VERSION` | `lang-node` | opt | only when `NODE_MANAGER=mise` |

Python CLIs are **always** `uv tool install`. Nothing in this repository moves, renames or deletes
`EXTERNALLY-MANAGED`, and `pip --user` is not used anywhere.

## AI agents (module `ai`)

| tool | method | pin | profile |
|---|---|---|---|
| Claude Code | the vendor's native installer | `CLAUDE_CODE_CHANNEL` | **base** — in `devops` and `full` |
| opencode | vendor script | `OPENCODE_VERSION` | `ai` profile, or `INSTALL_AI_AGENTS=1` |
| crush | rel | `CRUSH_VERSION` | `ai` profile, or `INSTALL_AI_AGENTS=1` |

Claude Code is installed **if absent** and then left alone — it self-updates, and this repository
never runs `claude update`. It is not installed through npm.

## Media, WSL, private, personal

| tool | module | profile | note |
|---|---|---|---|
| ffmpeg, imagemagick, poppler-utils, resvg, 7-Zip | `media` | full | Yazi's preview stack. `resvg` is absent on half the targets and is skipped, never built |
| wslu | `wsl` | wsl only | present in the jammy/noble universe pockets only. The upstream third-party repository is dead and is never added |
| clipboard shims (`clip`, `clip-paste`, `pbcopy`, `pbpaste`) | `auth-sso` | dev | WSL → Wayland → X11 → OSC 52, resolved at call time |
| `open-url` and the `xdg-open` shims | `auth-sso` | dev | see [docs/sso.md](sso.md) |
| Playwright system dependencies | `headless-browser` | never in a profile | `devenv --only headless-browser`; the list is delegated to `npx playwright install-deps` rather than hardcoded |
| internal templaters and tooling | `private` | priv | every host comes from the environment; nothing internal is committed here, and the module skips silently when the variable is unset |
| superseedr, shellbeats | `personal` | pers | |

## Homebrew: where each leaf goes instead

`devenv --only brew` audits an existing Homebrew installation and prints this map. It installs
nothing unless `INSTALL_HOMEBREW=1`, and it refuses on a glibc older than 2.39 with the reason.

| brew leaf | new home |
|---|---|
| fd, ripgrep, jq, sshpass, poppler, sevenzip, imagemagick, ffmpeg | apt |
| fzf, zoxide | apt when new enough, else a pinned release binary |
| eza, tldr | release binary / apt (no longer `cargo install`) |
| grpcurl | release binary (`GRPCURL_VERSION`) |
| yazi | release `.deb` |
| resvg | apt where it exists, otherwise skipped |
| tree-sitter, tree-sitter-cli | dropped — `nvim-treesitter` compiles parsers with `cc`; the CLI is for authoring grammars |
| `font-symbols-only-nerd-font` | `~/.local/share/fonts` + `fc-cache`, and only on a non-WSL, non-headless box |

## Deliberately not installed

| item | why |
|---|---|
| any desktop environment, compositor (`picom`), VNC viewer, `mpv`, `autocutsel` | terminal-only. A compositor composites X11 windows and there are none |
| `brave-browser` or any GUI browser | 449 MB and a third-party repository for something that cannot run on half the target matrix. Browser logins are solved by `open-url` instead — [docs/sso.md](sso.md) |
| `vagrant` | no provider works under WSL2, and the estate provisions with Terraform and Ansible |
| `kubeval` | upstream says to use `kubeconform` |
| `kubent` | fully overlapped by the krew `deprecations` plugin |
| `helmfile` | a third orchestration model competing with Argo CD app-of-apps |
| `talosctl`, `flux`, `clusterctl`, `k3sup`, `polaris`, `kubescape`, `ctop` | not this stack, or fully covered by trivy/score/k9s |
| standalone `kubectx`/`kubens`/`stern`/`popeye` binaries | same upstream as the krew plugins; two install paths for one tool means version skew and a PATH-shadowing question. The short names are aliases |
| krew `snap` | its own index description is "delete half of the pods in a namespace or cluster". Not on a box holding fleet kubeconfigs |
| krew `ktop`, `view-allocations`, `access-matrix`, `who-can`, `rbac-lookup` | dead upstream or fully overlapped by k9s, `resource-capacity` and `rbac-tool` |
| `helm cm-push` | Helm pushes OCI natively |
| `pipx` | `uv` covers every case and brings its own CPython. Two Python installers is one too many |
| global `pytest` | a globally installed pytest tests nothing reproducibly — use `uv add --dev pytest` |
| `apt-transport-https` | a no-op transitional package since apt 1.5 |
| `firecracker` | no module installs it; documented, not shipped |
| `yq` (the distro one) as a replacement for mikefarah's | different program. Reported, never removed |

## Where the versions come from

One file: [`versions.env`](../versions.env). Nothing else pins anything, and every key carries an
`# owner: <module>` comment so there can be no orphan pins.

* Every `*_VERSION` is the **upstream tag, verbatim**. Some projects prefix with `v` and some do
  not; both appear in the file and neither is a mistake. Asset patterns get `{tag}` and `{version}`
  (the tag minus any component prefix and one leading `v`) so a call site never has to know which
  convention a project uses.
* `latest` resolves at install time from the `releases/latest` redirect — no GitHub API, so no rate
  limit — asserts the result really is a release tag, and caches it for six hours.
* `apt` means "not pinned here; the vendor's repository decides".
* `auto` (only `K8S_MINOR`) probes the upstream stable stream.

Override any of them for a single run:

```bash
K9S_VERSION=v0.50.9 devenv --only kubernetes
```

`make bump` resolves every floating pin to a concrete tag and rewrites one key at a time, leaving
comments and deliberately manual pins (`# pin-policy: manual`) alone.
