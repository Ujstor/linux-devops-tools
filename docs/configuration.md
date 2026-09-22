# Configuration

Three layers, in the order they are decided:

1. **`versions.env`** — every pin in the repository. Export any key to override it for one run.
2. **Feature gates and `DEVENV_*` variables** — what a run is allowed to do.
3. **`~/.config/devops-env/` and `~/.bashrc.d/90-local.sh`** — your per-host settings, which
   the installer seeds once and then never touches again.

**Source of truth:** [`versions.env`](../versions.env) for pins, `bin/devenv --help` for flags.
Verified 2026-09-11.

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
| `INSTALL_AI_AGENTS=1` | `crush`. Claude Code and opencode are base installs and are not gated |
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
| `DEVENV_EXTREPO_<NAME>=0\|1` | `shell`, `editors` | turn one external config repo on or off for a run — see [External config repos](#external-config-repos) |
| `DEVENV_INSTALL_MYBASH=0` | `shell` | the older spelling of `DEVENV_EXTREPO_MYBASH=0`: leave `mybash` alone |
| `DEVENV_EXTREPO_POST=0` | `shell`, `editors`, `root-configs` | sync and symlink the external config repos, but do not run their own installers |
| `DEVENV_ROOT_CONFIGS=0` | `root-configs` | do not give root the same nvim/tmux/bash configuration |
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
| `external-repos.sh` | `shell`, `editors` | **your** external config repos. Seeded from `config/external-repos.sh.example` as pure comments; see below |
| `personal.env` | you | the `personal` module reads it if it exists; it never writes a template |
| `shell.env` | you | sourced by `~/.bashrc.d/05-env.sh` on every interactive shell |
| `starship.toml` | you | an overlay merged into the shipped prompt, with `--starship overlay` |

All of them are gitignored. None of them is ever committed.

## External config repos

The external git checkouts — `nvim-config`, `tmux-config`, `mybash` — are **one declarative
list**, not three hardcoded clones. No module knows a URL, a ref, a checkout path or a symlink
destination any more; each module only says *sync the entries I own*.

| file | what it is |
|---|---|
| [`config/external-repos.sh`](../config/external-repos.sh) | the three this repository ships |
| `~/.config/devops-env/external-repos.sh` | **yours.** Seeded once from `config/external-repos.sh.example`, never overwritten, never committed |

Both are plain bash, sourced in that order by `lib/extrepo.sh`, and both contain nothing but
`extrepo` calls. Sourcing yours second is what makes it powerful: a **new** name adds a
checkout, and a name that is already in the shipped list **replaces it in place**, keeping its
position. That is how you point `nvim-config` at your own fork without editing a module.

```bash
extrepo NAME url=… [ref=…] [dest=…] [link=…] [link_src=…] [post=…] [module=…] [enabled=0|1] [desc=…]
```

| field | meaning |
|---|---|
| `name` | the id, the default directory name, and the suffix of its switch (`my-nvim` → `DEVENV_EXTREPO_MY_NVIM`) |
| `url` | **required.** `https://`, `git@`, `ssh://`, `file://` or an absolute path |
| `ref` | branch or tag. Empty is the remote's default branch. Ours are pinned in `versions.env` |
| `dest` | where the checkout goes, **absolute**. Default `~/.local/share/devops-env/repos/<name>` (`$EXTREPO_ROOT`) |
| `link` | absolute path of a symlink to create. Empty means none |
| `link_src` | what inside the checkout `link` points at, relative to `dest`. Empty means the checkout directory itself |
| `post` | a command run **inside** the checkout once it is synced and linked — the checkout's own installer, for the part a symlink cannot do. Skipped under `--dry-run`, skipped when there is no checkout, and never fatal. `DEVENV_EXTREPO_POST=0` turns every one off |
| `module` | which module syncs it: `editors` (default) or `shell` |
| `enabled` | `1` or `0` (default `1`) |
| `desc` | one line, for the log |

The three shipped entries, and why each looks the way it does:

| entry | ref pin | module | link | `post=` | on? |
|---|---|---|---|---|---|
| `nvim-config` | `NVIM_CONFIG_REF` | `editors` | `~/.config/nvim` → the **checkout** (`init.lua` is at the repository root) | — | yes |
| `tmux-config` | `TMUX_CONFIG_REF` | `editors` | `~/.tmux.conf` → `.tmux.conf` **inside** the checkout | `./install.sh` | yes |
| `mybash` | `MYBASH_REF` | `shell` | **none** — its own `setup.sh` links all three of its dotfiles | `./setup.sh --config-only` | yes |

All three are on, so the one documented command installs all of them:

```bash
curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash
```

**Why two of them need a `post=`.** A symlink was never the whole install:

* `~/.tmux.conf` on its own is **inert**. Every `set -g @plugin` line in it is a no-op without
  `~/.tmux/plugins/tpm`, so there is no catppuccin theme, no `tmux-resurrect` and — the one
  people actually notice — no `tmux-yank`, which is what binds `y` in copy mode. The config
  itself prints a yellow *"TPM is not installed"* bar to say so. `prefix + q` / `prefix + a`
  also call `~/tmux.sh`, which nothing installed either. `post=./install.sh` puts TPM, every
  plugin and `~/tmux.sh` in place. It finds `~/.tmux.conf` already symlinked and says so
  (*"is a symlink … left alone"*) — that is the correct outcome, not an error.
* `mybash` was cloned but never activated, so its `.bashrc`, starship prompt and fastfetch
  config sat in `~/linuxtoolbox/mybash` doing nothing.

Running each repository's **own** installer, rather than a second copy of its logic here, keeps
one source of truth per repository. This is **not** the `curl … | bash` that was ruled out: the
repository is cloned first, the symlink is placed first, and only then is the script that is *in
the checkout* run. Both back up whatever they replace; tmux-config's leaves a symlink it did not
make alone, and mybash's records each backup so its `uninstall.sh` can put it back.

mybash's runs as `setup.sh --config-only`: it links its dotfiles and installs nothing. Its plain
`setup.sh` also installs starship, zoxide, fzf, eza and neovim — unpinned, from vendor scripts,
into `~/.local/bin` — and it runs before this repository installs the pinned, verified copies, so
those copies ended up shadowed, and a distro neovim landed next to the upstream one.

**`mybash` ships on since 2026-09-15**, reversing the older decision. That decision read *"its
`setup.sh` symlinks `~/.bashrc`, so running it where a `~/.bashrc` already exists is a data-loss
event"*, and the premise stopped being true: `link_file()` backs a real `~/.bashrc` up to
`~/.bashrc.bak` first, never overwrites an existing backup, and is a no-op when the link is
already right. Every `~/.bashrc.d` fragment here still works with it and without it, which is
what makes `DEVENV_EXTREPO_MYBASH=0` a real option rather than a broken one.

### root gets the same configuration

`sudo -i`, `sudo su -` and a root login shell read **root's** dotfiles, not yours — so on a box
configured only for your user, root gets a bare prompt, a tmux with no prefix and none of its
plugins, and a `vi` that is not neovim. The [`root-configs`](modules.md) module (52) closes that
gap: every **enabled** entry above is cloned under `/root/.local/share/devops-env/repos/` and
linked from root's dotfiles, with each entry's `post=` run under `sudo -H` so `HOME` is `/root`.

`dest=` is deliberately **not** mirrored. Root's checkouts always land under root's own home,
never at a path inside your home — that would break the moment your home is unmounted or
re-created, and would let a non-root user edit what root's login shell sources. A `link=` that
was not under `$HOME` is dropped rather than re-anchored, for the same reason.

One switch covers both accounts: `DEVENV_EXTREPO_MYBASH=0` turns mybash off for you *and* for
root. `DEVENV_ROOT_CONFIGS=0` skips the root half entirely.

Any entry, shipped or yours, can be switched for one run. The environment always wins over
`enabled=`, in **both** directions:

```bash
DEVENV_EXTREPO_MYBASH=0      devenv --only shell         # off
DEVENV_EXTREPO_NVIM_CONFIG=0 devenv --only editors       # off
DEVENV_EXTREPO_POST=0        devenv --only editors       # checkouts and symlinks, no installers
DEVENV_ROOT_CONFIGS=0        devenv                      # leave root's dotfiles alone
DEVENV_INSTALL_MYBASH=0      devenv --only shell         # the older spelling, still honoured
```

Nothing here can lose work of yours. A checkout with uncommitted changes is never updated — it
is reported and left. A symlink is placed only over nothing, over another symlink, or over an
**empty** directory; a real file or a non-empty directory is reported and left exactly as it is.
An unreachable repository warns and the run carries on: a GitHub outage does not stop the rest
of the module. Under `--dry-run` none of it writes anything.

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
