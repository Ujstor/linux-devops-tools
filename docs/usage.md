# Everyday use

**Source of truth:** `devenv --help` and `install.sh --help` on your checkout. This page is the
narrated version, verified 2026-09-10.

`devenv` lives at `~/.local/share/linux-devops-tools/bin/devenv`. The shell integration puts
`~/.local/bin` at the front of `PATH`; if `devenv` is still not found after `exec bash -l`:

```bash
ln -s ~/.local/share/linux-devops-tools/bin/devenv ~/.local/bin/devenv
```

## Commands

| command | what it does |
|---|---|
| `devenv` | run the resolved plan (the default is `install --profile devops`) |
| `devenv list` | every module with its profiles and gates, **TSV on stdout** |
| `devenv doctor [--fix]` | audit this machine; `--fix` prints the repair plan — doctor itself never changes anything |
| `devenv update` | fast-forward the checkout, then replay the last plan |
| `devenv uninstall [--all]` | remove the shell integration and the files this repo owns |
| `devenv shell install\|uninstall\|status` | just the `~/.bashrc` managed block |
| `devenv completions` | regenerate the lazy bash-completion cache |
| `devenv version` | checkout ref, `versions.env` digest, platform |

Every log line goes to **stderr**; only machine-readable output goes to stdout. So this is
always safe:

```bash
devenv list | column -t -s "$(printf '\t')"
devenv list | awk -F'\t' '$7=="yes"{print $1}'      # every module that wants root
```

## Choosing what runs

| flag | effect |
|---|---|
| `-p, --profile NAME` | which profile (default `devops`) |
| `-o, --only MODULES` | comma-separated; **replaces** the profile entirely |
| `-s, --skip MODULES` | comma-separated; subtracted from the plan |
| `-n, --dry-run` | print every mutating action, change nothing |
| `-y, --yes` | answer ordinary prompts with yes — never the dangerous ones |
| `--fail-fast` | stop at the first failing module (default: continue) |
| `--extras` | turn on `KREW_EXTRAS` and `INSTALL_EXTRAS` for this run |
| `--upgrade` | allow `apt-get upgrade`. Never implicit |

```bash
devenv --dry-run                       # a full plan, nothing touched
devenv --profile full --yes
devenv --only k9s-config
devenv --only k8s-plugins,k9s-config
devenv --skip containers
```

`--dry-run` is a true no-op, not a best effort: every mutation in the codebase goes through one
gate, and CI fingerprints `$HOME`, `/etc` and `/usr/local/bin` before a dry run and diffs it
after. See [docs/safety.md](safety.md).

## Bootstrapping and re-bootstrapping

`install.sh` consumes `--home`, `--repo`, `--ref`, `--no-update`, `--force-update` and `--help`,
and forwards everything else verbatim to `devenv`. Run from inside a checkout it clones nothing.

```bash
curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash -s -- --profile full
curl -fsSL .../install.sh | bash -s -- --ref v1.2.3
curl -fsSL .../install.sh | bash -s -- --home /opt/linux-devops-tools
```

It refuses to write to a directory that is not a checkout of this repository, and it refuses
`/`, your home directory, a bare top-level directory and a symlink — loudly, changing nothing.

## Updating

```bash
devenv update              # fast-forward the checkout, then replay the last plan
devenv update --ref v1.2.3 # a specific ref
devenv update --no-update  # replay the plan without fetching
```

`update` refuses a checkout with local modifications unless you pass `--force-update`, and it
re-execs the **new** `bin/devenv` after the fast-forward, so an update that changes the runner
takes effect in the same invocation. A tarball install (no `.git`) is updated by re-downloading;
a directory that is neither is left alone with a warning, and the plan is replayed anyway.

The layers that drift fastest have their own refresh paths, all idempotent:

```bash
devenv --only k8s-plugins     # krew upgrade + helm plugin update
devenv --only k9s-config      # re-apply plugins/hotkeys/skins
devenv --only lang-python     # uv tool upgrade
```

## Uninstalling

```bash
devenv shell uninstall     # just the ~/.bashrc managed block
devenv uninstall           # the block + every file this repo owns byte-for-byte
devenv uninstall --all     # also ~/.config/devops-env, the cache and the state
```

The manifest at `~/.local/state/devops-env/` records a digest per installed file. That is what
makes uninstall honest: a file you edited after installation is **kept and reported**, not
deleted. `uninstall` also never removes packages, never touches `/usr/local/bin` or
`/usr/local/go`, and never removes krew plugins or Go tools — it lists them so you can decide.

`--all` additionally needs `DEVENV_ALLOW_UNINSTALL_ALL=1` when you are running
non-interactively, and it refuses any path that is not safely under your home directory.

Then remove the checkout itself:

```bash
rm -rf ~/.local/share/linux-devops-tools
```

## After a run

```bash
exec bash -l          # pick up the shell integration
devenv doctor         # OK / WARN / FAIL per subsystem
open-url --mode       # wsl | gui | print
sso-login --status    # what is authenticated, and until when
```

`exec bash -l` comes first on purpose. A run's own `doctor` module is a child of the process you
started the install from, so it sees that shell's `PATH` — which predates `~/.bashrc.d/10-path.sh`
and the `~/.local/bin` the run just created. Doctor checks the filesystem as well and says which is
which ("`~/.local/bin` is on the PATH a new shell gets"), rather than failing over its own stale
environment; a `FAIL` there means the drop-in really is missing, not that you have not opened a new
shell yet.

Logging in from a box with no browser is [docs/sso.md](sso.md). Every knob that changes what a
run does is [docs/configuration.md](configuration.md).
