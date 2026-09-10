# Migrating

This tool has answered to three names. Two migrations lead here, and they are nothing like each
other in size:

| you are coming from | what it was | what it costs you |
|---|---|---|
| **`devops-env-config`** | this repository under its previous name — same code, same `devenv` command | §1: one re-install, then delete two leftovers |
| **`wsl2-config`** | the curl-piped scripts this tool replaced, written for one WSL2 box | §2 onward: a report, then a series of separate decisions |

Nothing migrates automatically, in either direction. This page tells you what changed, what to run
on a machine the old thing touched, and what to clean up by hand.

---

## 1. From `devops-env-config`: the rename

The repository is now `Ujstor/linux-devops-tools`, matching its GitLab mirror. It carried the
name `devops-env-config` while it was being written, and that name was never a repository on
GitHub at all — which is why it does not redirect, it **404s**:

```bash
curl -fsSIL -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/Ujstor/devops-env-config/main/install.sh   # 404
curl -fsSIL -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh  # 200
```

An install one-liner, VM template or runbook still naming `devops-env-config` fetches nothing and
fails at the `curl`. Update it to the second URL.

**Nothing about the command changed.** It is still `devenv`, still `bin/devenv`, and every
`DEVENV_*` variable keeps its name — that prefix comes from the command, not from the repository.
Your own files stay exactly where they are:

| stays | why |
|---|---|
| `~/.config/devops-env/` — `sso.env`, `bookmarks`, `private.env`, `personal.env`, `shell.env` | named after the `devenv` command. **Your real hostnames live here — do not delete it** |
| `~/.cache/devops-env/`, `~/.local/state/devops-env/` | same, and the state directory is what makes `devenv uninstall` honest |
| `~/.bashrc.d/` and every fragment in it, `90-local.sh` included | fragment names never carried the repository name |
| `~/.local/bin/` — `open-url`, `clip`, `clip-paste`, `sso-login`, `web` | unchanged |

Two things do move:

| moves | from | to |
|---|---|---|
| the checkout (`$DEVENV_HOME`) | `~/.local/share/devops-env-config` | `~/.local/share/linux-devops-tools` |
| the `~/.bashrc` managed-block marker | `# >>> devops-env-config >>>` | `# >>> linux-devops-tools >>>` |

The marker is handled for you. Every **reader** in `lib/` accepts the pre-rename tag as well as
the current one, and no writer ever emits it again:

| a thing written before the rename | what happens on the next run |
|---|---|
| the `~/.bashrc` managed block | re-fenced in place under the new marker — **one** block, never two, and written *through* a symlinked `~/.bashrc` |
| a `~/.bashrc.d/` fragment carrying the old tag | still recognised as this repository's, so it is refreshed and prunable rather than stranded |
| the completion cache | still recognised, so it is refreshed instead of being rebuilt beside itself |
| `devenv uninstall` on a box that never re-ran the installer | removes the pre-rename block too |

So the whole migration is a re-install plus one `rm`:

```bash
# 1. Install under the new name. The clone lands in the new directory, and the
#    ~/.bashrc block is re-fenced in place.
curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash

# 2. Delete the old checkout. This is the one thing nothing does for you: the
#    installer clones the new path, it never moves or removes the old one.
rm -rf ~/.local/share/devops-env-config

# 3. Prove it.
grep -c 'devops-env-config' ~/.bashrc     # 0
ls -d ~/.local/share/devops-env-config    # No such file or directory
devenv version                            # answers from the new checkout
exec bash -l
```

If you are **not** re-installing — you want the tool off this box entirely — let the old checkout
uninstall itself while it is still there. It knows its own marker:

```bash
~/.local/share/devops-env-config/bin/devenv uninstall
rm -rf ~/.local/share/devops-env-config
```

And if the checkout is already gone while the old block is still in `~/.bashrc`, remove it by its
markers. `~/.bashrc` may be a **symlink** into another repository's worktree — the redirection
below writes *through* the link, and `mv` over it would sever it, which is exactly the damage
[§4](#4-what-the-old-scripts-did-that-this-one-deliberately-does-not) describes:

```bash
cp -aL ~/.bashrc ~/.bashrc.pre-rename.bak            # -L: the content, through the symlink
awk '/^# >>> devops-env-config >>>$/{drop=1}
     !drop{print}
     /^# <<< devops-env-config <<<$/{drop=0}' ~/.bashrc.pre-rename.bak >~/.bashrc.rewritten
cat ~/.bashrc.rewritten >~/.bashrc                   # writes THROUGH a symlink; never replaces it
rm -f ~/.bashrc.rewritten
```

Keep `~/.bashrc.pre-rename.bak` until a new login shell works.

Finally, if you have a git checkout of your own that you work in — not the one `install.sh`
maintains — point its remote at the new URL. GitHub redirects `wsl2-config`, but there is no
`devops-env-config` repository to redirect from:

```bash
git remote set-url origin https://github.com/Ujstor/linux-devops-tools.git
git fetch origin && git pull --ff-only
```

Nothing else on this page applies to you. The rest is about the `wsl2-config` scripts.

---

## 2. From `wsl2-config`: the short version

Everything from here down is about the predecessor scripts: an `install.sh` that curl-piped six
sub-scripts into `bash`, for one WSL2 box. What replaced them is a general Debian/Ubuntu
provisioning tool with one CLI, gated modules, profiles, a dry run that is a real no-op, and an
uninstall path.

```bash
# 1. Install the new tool, without changing anything yet.
curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash -s -- --dry-run

# 2. Find out what the old scripts left behind. Both of these only REPORT.
devenv --only migrate
devenv doctor

# 3. Do it for real.
devenv --profile devops

# 4. Optional, and each one is a separate decision:
DEVENV_MIGRATE_APPLY=1 devenv --only migrate   # neutralise the old leftovers
devenv doctor --fix                            # repair what is safe to repair
devenv --only purge-desktop                    # remove the compositor/browser/VNC residue
```

Nothing in step 2 changes anything at all. `migrate` is in no profile, so it never runs unless you
ask for it, and without `DEVENV_MIGRATE_APPLY=1` it only prints what it found and the command that
would deal with it. `doctor --fix` backs up every file it edits, honours `--dry-run`, and still
refuses to remove a package without `--allow-pkg-remove`.

Run the module directly if you prefer that to an environment variable:

```bash
~/.local/share/linux-devops-tools/modules/92-migrate.sh            # report
~/.local/share/linux-devops-tools/modules/92-migrate.sh --apply    # act
```

## 3. Structure: then and now

| `wsl2-config` | `linux-devops-tools` |
|---|---|
| `install.sh` curl-pipes six scripts from `raw.githubusercontent.com` | `install.sh` clones the repository once and hands over to `bin/devenv`; nothing is ever piped into `bash` from inside the run |
| `scripts/tools.sh` | modules `base-packages`, `shell`, `git`, `lang-*`, `cloud`, `ai` |
| `scripts/devops.sh` | modules `kubernetes`, `k8s-plugins`, `k9s-config`, `iac` |
| `scripts/docker.sh` | module `containers` |
| `scripts/nvm.sh` | module `lang-node` |
| `scripts/usenala.sh` | **gone.** `ENABLE_NALA_ALIAS=1` gives you `alias apt='nala'` and nothing else |
| `scripts/x11.sh` | **gone.** Terminal-only: no compositor, no X11 build dependencies, no source builds |
| `fix-repos.sh` | folded into the `doctor` module |
| versions scattered through the scripts | one file, [`versions.env`](../versions.env) |
| no dry run, no uninstall, no idempotency guarantee | `--dry-run`, `devenv uninstall`, and a second run that writes nothing |

There is no "WSL edition" any more. The same code runs on WSL2, a Proxmox VM, a cloud instance and a
container; `wsl`-specific work lives in one module that no-ops elsewhere.

## 4. What the old scripts did that this one deliberately does not

Every line below was doing damage, or was dead weight. Each is gone on purpose.

| Old behaviour | Why it is gone |
|---|---|
| `sudo apt upgrade -y` on every run | "install my tools" is not "upgrade my kernel". Now opt-in: `--upgrade` |
| `sudo chown -R $user:$user /home/$user` | unquoted, recursive over the whole home directory, rewrites the Go module cache and mounted Windows paths, and fixes a problem the installer never caused |
| `sed -i` on `~/.bashrc` | this is what replaced a symlinked `~/.bashrc` with a regular file and silently detached it from `mybash`. The new writer edits **through** a symlink and never uses `sed -i` |
| removing `EXTERNALLY-MANAGED` (PEP 668) | disables a system-wide safety marker for one package, and does not even last — a routine upgrade restores it. Python CLIs now go through `uv tool` |
| `go clean -modcache` every run | deletes a multi-gigabyte cache and forces a full re-download of everything |
| redefining `sudo()` and `apt()` as shell functions | privilege-adjacent indirection with a huge blast radius, inconsistent by argument position, and only present in interactive bash — so a command tested by hand behaves differently in a playbook |
| building `picom` from a redirecting fork with `sudo ninja install` | a compositor composites X11 windows; there are none on a terminal box. It also dropped unmanaged root-owned binaries into `/usr/local` with no uninstall path |
| ~30 X11 `-dev` packages | they existed only to build that compositor |
| installing `brave-browser` | 449 MB and a third-party apt repository for a browser that cannot run on half the target matrix. Under WSL the Windows browser is strictly better — it holds your profile, password manager, live sessions and FIDO2 key |
| `npm install -g @anthropic-ai/claude-code` | the wrong install path. Claude Code now comes from its native installer, is a **base** install, and is never touched again — it self-updates |
| `docker run --rm hello-world` as the docker test | pulls into root's store, needs a warm daemon, and proves nothing about *your* group membership, which is the thing that is actually broken until you log out |
| a `kubernetes.list` pinned to v1.29 | EOL. `K8S_MINOR` in `versions.env` decides now, with a downgrade guard |

## 5. On a box the old scripts already touched

Run `devenv doctor` first — it reports every item below with the exact path. Then work through the
ones that apply.

### 5.1 `~/.bashrc`

The old installer appended directly and repeatedly. You will typically find the `.cargo/env` line
twice, `~/.local/bin` on `PATH` three times, a legacy `# Go environment variables` block, nine
completion `source` lines and three nvm lines.

The new shell integration is **one** managed block:

```bash
# >>> linux-devops-tools >>>
# Managed block — edit ~/.bashrc.d/ instead. Remove with: devenv shell uninstall
[ -f "$HOME/.bashrc.d/00-init.bash" ] && . "$HOME/.bashrc.d/00-init.bash"
# <<< linux-devops-tools <<<
```

The `migrate` module (and `devenv doctor --fix`) offers a one-time migration that **comments the old
lines out** with a backup. It never deletes them, and it never uses `sed -i`.

If `~/.bashrc` is a symlink (`mybash`), it stays a symlink: the block is written through the link so
`mybash` keeps working, and you get a one-line diff you can upstream. `--adopt-bashrc` severs the
link into a real file instead, after a backup — only do that if you want to stop tracking `mybash`.

Anything of your own goes in `~/.bashrc.d/90-local.sh`, which is created once and then never
touched, never overwritten and never pruned.

### 5.2 The broken clipboard aliases

The old `~/.bashrc` carried:

```bash
# export BROWSER=chrome
alias pbcopy='clip.exe'
alias pbpaste='powershell.exe -Command Get-Clipboard'
```

On a WSL distro where the Windows PATH is not appended, **none of those names resolve** — the
aliases are already dead. They are replaced by real executables (`clip`, `clip-paste`, and
`pbcopy`/`pbpaste` symlinks to them) that resolve the Windows mount prefix at runtime, and fall back
to Wayland, X11 and finally OSC 52 for an SSH session. A real binary also works from `tmux`, a k9s
plugin, a kubeconfig `exec` block, `cron` and a systemd unit — a shell alias works in none of them.

`export BROWSER=chrome` would have fixed `az`, `gh` and `glab`, and done nothing for
`kubectl oidc-login`, `argocd` and `bao`, which ignore `$BROWSER` entirely. See
[docs/sso.md](sso.md).

### 5.3 Desktop residue

```bash
devenv --only purge-desktop      # reports first; acts behind explicit confirmation
```

It looks for `/usr/local/bin/{picom,picom-trans,compton,compton-trans}` (root-owned, not
apt-managed, no uninstall target), the `~/build/picom` checkout, `brave-browser` and its keyring,
`mpv`, `tigervnc-viewer`, `xtightvncviewer`, `autocutsel`, `alsa-utils` and the X11 `-dev` set that
only ever existed to build the compositor.

Nothing is removed without confirmation, and package removal additionally needs
`--allow-pkg-remove`. If you use any of those tools deliberately, say no — the module is not in any
profile precisely because it is a judgement call.

### 5.4 `nvm` in the wrong place

The old `scripts/nvm.sh` installed nvm into `~/.nvm`, while the shell config exported
`NVM_DIR=$HOME/.config/nvm`. If both exist, the doctor reports it and offers to move `versions/`
into the one the shell actually uses. nvm is now lazily loaded, so it costs nothing per shell.

### 5.5 The two different `kubelogin` binaries

Two unrelated projects ship a binary called `kubelogin`:

* **int128/kubelogin** — the Keycloak/OIDC credential plugin. Installed **only** through krew, as
  `kubectl oidc-login`. Never `go install` it: that writes `~/go/bin/kubelogin` and silently
  overwrites the other one.
* **Azure/kubelogin** — `kubelogin convert-kubeconfig` for AKS. Installed by the `cloud` module.

If `kubelogin convert-kubeconfig --help` fails, the wrong one is on your `PATH`. Reinstall Azure's:

```bash
go install github.com/Azure/kubelogin@latest
```

`devenv doctor` checks exactly this.

### 5.6 Two of everything on `PATH`

The old scripts installed some tools twice by different routes. The doctor reports each duplicate
with **both** paths — commonly `golangci-lint` in `/usr/local/bin` *and* `~/go/bin`, `fzf`/`jq`/`rg`/
`fd` from apt *and* Homebrew, and `nvim` from apt *and* `/usr/local/bin`. Removing one is your call;
nothing is removed for you.

Two specific ones worth knowing about:

* **`yq`** — the distro package is a Python wrapper around `jq` and is *not* a drop-in replacement
  for mikefarah's `yq` v4, which this repository installs to `/usr/local/bin`. Both can coexist; the
  doctor tells you which one wins on `PATH`.
* **Helm `schema-gen`** — archived upstream in 2021. It is replaced by `schema`
  (`losisin/helm-values-schema-json`). The old plugin is reported with the uninstall command; it is
  never uninstalled for you:

  ```bash
  helm plugin uninstall schema-gen
  ```

### 5.7 apt sources

`fix-repos.sh` used to patch one wrong Docker vendor path by hand. That check is now general: the
doctor finds a URI configured in both a `.list` and a `.sources`, legacy `archive_uri-*.list` files
left by `add-apt-repository`, a `docker` source pointing at the wrong distribution, a `Signed-By:`
keyring that is missing or zero bytes, and a Kubernetes repository pinned to an EOL minor. `--fix`
rewrites them through the same code the modules use.

Every source this repository writes is deb822 (`.sources`) with an armored key in
`/etc/apt/keyrings`. No `apt-key`, no dearmoring, no `gnupg` dependency.

## 6. If you cloned the old repository

GitHub redirects `wsl2-config` — it was a real repository that was renamed — so an existing clone
keeps working. The redirect is still not something to depend on, and it is worth knowing that the
in-between name, `devops-env-config`, has no redirect at all: it was never a GitHub repository, so
every URL under it 404s.

```bash
cd /path/to/wsl2-config
git remote set-url origin https://github.com/Ujstor/linux-devops-tools.git
git fetch origin && git checkout main && git pull --ff-only
```

There is no need to keep a working copy at all: `install.sh` maintains its own checkout at
`~/.local/share/linux-devops-tools`, and `devenv update` fast-forwards it.

If you scripted the old one-liner anywhere — a VM template, a cloud-init file, a runbook — update
the URL and add a profile:

```bash
# old
curl -sSL https://raw.githubusercontent.com/Ujstor/wsl2-config/main/install.sh | bash

# new
curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash -s -- --profile devops --yes
```

`--yes` answers ordinary questions only. Docker group membership, `/etc/wsl.conf` writes and package
removal each still require their own explicit opt-in, even under `--yes` — see
[docs/configuration.md](configuration.md#privileged-hard-to-undo-steps).

## 7. What this does not do

* It does not remove packages the old scripts installed. They are reported; you decide.
* It does not touch `~/.gitconfig` values that are already set — the `git` module is set-if-absent
  and reports the difference instead.
* It does not merge, reorder or clean `~/.kube/`. Kubeconfigs are read-only to this tool, apart from
  `sso-kubeconfig-add`, which is a separate, confirmed, backed-up command.
* It does not manage Claude Code after installing it, and never runs `claude update`.
* It does not delete anything in `~/.bashrc.d` that does not carry its own marker, and even then
  only with `--prune`.
