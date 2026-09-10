# Configuration

Three layers, in the order they are decided:

1. **`versions.env`** — every pin in the repository. Export any key to override it for one run.
2. **Feature gates and `DEVENV_*` variables** — what a run is allowed to do.
3. **`~/.config/devops-env/` and `~/.bashrc.d/90-local.sh`** — your per-host settings, which
   the installer seeds once and then never touches again.

**Source of truth:** [`versions.env`](../versions.env) for pins, `bin/devenv --help` for flags.
Verified 2026-09-10.

## Pins

Every version lives in `versions.env` and nothing else pins anything. Every key carries an
`# owner: <module>` comment, so there are no orphan pins.

```bash
K9S_VERSION=v0.50.0 devenv --only kubernetes    # override for one run
```

A pin is the **upstream release tag, verbatim** — some projects prefix `v`, some do not, and
both forms appear on purpose. Three sentinel values are special:

| value | meaning |
|---|---|
| `latest` | resolved at install time from the `releases/latest` 302 header (no `api.github.com`, so no rate limit), asserted to be a real tag URL, cached 6 h |
| `apt` | not pinned here: the vendor's apt repository decides |
| `auto` | `K8S_MINOR` only — enables the three-tier `stable.txt` probe |

## Feature gates

All off by default. `--profile full` sets the first three; `--profile ai` sets
`INSTALL_AI_AGENTS`; `--extras` sets `KREW_EXTRAS` and `INSTALL_EXTRAS`. An explicit value in
the environment always wins over a profile's default.

| variable | effect |
|---|---|
| `KREW_EXTRAS=1` | the optional kubectl plugin roster |
| `INSTALL_PACKER=1` | Packer alongside Terraform |
| `INSTALL_EXTRAS=1` | the optional apt extras |
| `INSTALL_K8S_OPT=1` | `kor`, `kube-linter`, `kube-bench`, `nerdctl`, `kubeseal` |
| `INSTALL_AI_AGENTS=1` | `opencode` and `crush`. Claude Code is a base install and is not gated |
| `INSTALL_HOMEBREW=1` | actually install Homebrew instead of only auditing it (needs glibc ≥ 2.39) |
| `TMUX_FROM_SOURCE=1` | build tmux instead of taking the apt one |
| `ENABLE_NALA_ALIAS=1` | `alias apt='nala'` — an alias, never a function, and `sudo` is never redefined |
| `DEVENV_UPGRADE=1` | allow `apt-get upgrade` (same as `--upgrade`) |

## Privileged, hard-to-undo steps

`--yes` answers ordinary questions only. Each of these needs its own explicit opt-in, because
none of them is safe to imply:

| flag | variable | what it allows |
|---|---|---|
| `--allow-docker-group` | `DEVENV_ALLOW_DOCKER_GROUP=1` | adding your user to the `docker` group (root-equivalent) |
| `--allow-wsl-conf` | `DEVENV_ALLOW_WSL_CONF=1` | writing `/etc/wsl.conf` |
| `--allow-pkg-remove` | `DEVENV_ALLOW_PKG_REMOVE=1` | removing an apt package |
| — | `DEVENV_ALLOW_UNINSTALL_ALL=1` | `uninstall --all` without a prompt |
| — | `DEVENV_ALLOW_ROOT=1` | letting `install.sh` run as root |
| — | `DEVENV_ALLOW_DOWNGRADES=1` | letting apt move `kubectl` back a minor |

## Paths

| variable | default |
|---|---|
| `DEVENV_HOME` | `~/.local/share/linux-devops-tools` (the checkout) |
| `DEVENV_CONFIG` | `~/.config/devops-env` |
| `DEVENV_CACHE` | `~/.cache/devops-env` |
| `DEVENV_STATE` | `~/.local/state/devops-env` |
| `DEVENV_REPO` | `Ujstor/linux-devops-tools` |
| `DEVENV_REPO_URL` | `https://github.com/$DEVENV_REPO.git` |
| `DEVENV_REF` | `main` |

## Per-module behaviour switches

| variable | module | effect |
|---|---|---|
| `DEVENV_GIT_APPLY=1` | `git` | let it write git config. Still set-if-absent, still never `user.*` |
| `DEVENV_MIGRATE_APPLY=1` | `migrate` | neutralise what it found instead of only reporting |
| `DEVENV_INSTALL_MYBASH=1` | `shell` | clone `mybash` instead of only detecting it |
| `DEVENV_UV_FORCE=1` | `lang-python` | let `uv tool install --force` replace an existing shim |
| `DEVENV_NODE_MANAGER=mise` | `lang-node` | use mise instead of nvm |
| `DEVENV_DOCTOR_STRICT=1` | `doctor` | exit non-zero on a FAIL instead of only reporting |
| `DEVENV_PRUNE=1` (`--prune`) | `shell` | remove `~/.bashrc.d` fragments this repo no longer ships — marker-carrying files only, never `90-local.sh` |
| `DEVENV_ADOPT_BASHRC=1` (`--adopt-bashrc`) | `shell` | replace a symlinked `~/.bashrc` with a real file, after a backup |
| `--starship MODE` | `shell` | `upstream` \| `overlay` \| `adopt` \| `print` (default `print`) |
| `DEVENV_BACKUP_KEEP` | `lib/fs.sh` | how many timestamped backups to keep per file (default 5) |
| `NO_COLOR` / `DEVENV_NO_COLOR` | all | disable colour. Colour is off automatically when stderr is not a terminal |

## `~/.config/devops-env/`

Seeded once from the shipped `*.example` files and **never** overwritten. Mode 0600 for
anything that holds a hostname. Removed only by `devenv uninstall --all`.

| file | seeded by | what goes in it |
|---|---|---|
| `sso.env` | `auth-sso` | issuer URL, client id, kubeconfig contexts, Argo CD / OpenBao / GitLab hosts, browser and clipboard overrides. **The only place a real hostname is written** |
| `bookmarks` | `auth-sso` | names for `web <name>` |
| `kube/oidc-user.template.yaml` | `auth-sso` | the OIDC user block `sso-kubeconfig-add` renders |
| `tmux/devenv-clipboard.conf` | `auth-sso` | a sourceable tmux snippet — this repo never edits `~/.tmux.conf` in place |
| `private.env` | `private` | `DEVENV_PRIVATE_HOST` and the tool lists. Empty means the module no-ops |
| `personal.env` | you | the `personal` module reads it if it exists; it never writes a template |
| `shell.env` | you | sourced by `~/.bashrc.d/05-env.sh` on every interactive shell |
| `starship.toml` | you | an overlay merged into the shipped prompt, with `--starship overlay` |

All of them are gitignored. None of them is ever committed.

## The `bashrc.d` fragment model

Shell integration is **one** marker-fenced block in `~/.bashrc`:

```bash
# >>> linux-devops-tools >>>
# Managed block — edit ~/.bashrc.d/ instead. Remove with: devenv shell uninstall
[ -f "$HOME/.bashrc.d/00-init.bash" ] && . "$HOME/.bashrc.d/00-init.bash"
# <<< linux-devops-tools <<<
```

That block knows about exactly one file. Everything else is a **whole-file drop-in** beside it,
so a second run appends nothing and duplicates nothing, and nothing in this repository ever runs
`sed -i` on a dotfile. A symlinked `~/.bashrc` (hello, `mybash`) is written *through*, never
replaced.

`00-init.bash` sources `[0-9][0-9]-*.sh` in order — its own `.bash` extension is what stops it
sourcing itself.

| fragment | owns |
|---|---|
| `00-init.bash` | the loader; parses `/etc/os-release` once (never sources it) and exports `DEVENV_OS_ID`, `DEVENV_OS_LIKE`, `DEVENV_OS_CODENAME`, `DEVENV_IS_WSL` |
| `05-env.sh` | environment defaults; sources `~/.config/devops-env/shell.env` |
| `10-path.sh` | `PATH`, computed exactly once |
| `20-lang.sh` | Go, Rust, Python, and lazy `nvm` |
| `30-k8s.sh` | kubectl/kubecolor wiring, context helpers, the production guard |
| `40-shellui.sh` | fzf, starship, zoxide |
| `50-platform.sh` | browser and clipboard wiring |
| `55-sso.sh` | SSO helpers (owned by `auth-sso`, not `shell`) |
| `60-aliases.sh` | aliases and small helpers |
| `70-tools.sh` | per-tool `PATH` entries and hooks |
| **`90-local.sh`** | **yours.** Created empty once, never overwritten, never pruned, loaded last |

Knobs the fragments read, exported from `90-local.sh` or `shell.env`:

| variable | effect |
|---|---|
| `DEVENV_SKIP_FRAGMENTS="60-aliases.sh 70-tools.sh"` | skip fragments **by file name**. Distinct from `devenv --skip`, which takes module names |
| `DEVENV_DEBUG=1` | print each fragment's load time |
| `DEVENV_KUBE_GUARD=1` | confirm before a mutating `kubectl` on a context matching `KUBE_PROD_PATTERN` |
| `DEVENV_KEEP_GREP_ALIAS=1` | keep the stock `grep` alias instead of this repo's |
| `DEVENV_CLIP_BACKEND` | `auto` \| `wslclip` \| `wayland` \| `x11` \| `osc52` |
| `DEVENV_BROWSER_MODE` | `auto` \| `wsl` \| `gui` \| `print` \| `command` — see [docs/sso.md](sso.md) |
| `DEVENV_WSL_STRIP_WINPATH=1` | drop the Windows entries from `PATH` under WSL |

> [!NOTE]
> Skipping comes in two flavours and they are deliberately named apart. `devenv --skip` (exported
> as `DEVENV_SKIP`) takes **module** names and affects an install run. `DEVENV_SKIP_FRAGMENTS`
> takes **fragment file** names and affects your interactive shell. They were the same variable
> until the collision was found — exporting one used to silently change the other.
