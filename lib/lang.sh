# shellcheck shell=bash
# lib/lang.sh — language package managers and plugin managers.
#
# devops-env-config :: shared library. Sourced by lib/common.sh only.
#
# D7/K17/MUST-FIX S12: Python CLIs are installed ONLY with `uv tool install`.
# pip --user, pipx and --break-system-packages are gone, and nothing here ever
# touches /usr/lib/python3.*/EXTERNALLY-MANAGED. PEP 668 stays enforced.
#
# K24: krew plugins are installed ONE AT A TIME after a single `krew update`,
# because krew's batch path returns non-zero when ANY plugin fails and under
# `set -e` one transient GitHub 5xx would kill the whole run.
#
# MUST-FIX P5: krew_upgrade_all / helm_plugin_update exist so the plugin layer can
# be refreshed later; the pins are not inert after the first install.

[ -n "${_DEVENV_LANG:-}" ] && return 0
_DEVENV_LANG=1

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------

# go_ensure_path
#   Puts the Go toolchain this repository manages (/usr/local/go/bin, overridable
#   with GOROOT_DIR) and $GOPATH/bin on PATH FOR THIS PROCESS ONLY.
#
#   WHY EVERY MODULE THAT WANTS `go` MUST CALL IT FIRST. A module runs as a child
#   of bin/devenv with the INVOKING SHELL's PATH. On a fresh box that PATH predates
#   the toolchain modules/20-lang-go.sh has just unpacked into /usr/local/go, so
#   `have go` is false in every later module — and hcloud, crane and shfmt are
#   never built, on ANY number of runs, until the user opens a new login shell.
#   That is not hypothetical: the container matrix reported
#       [ -- ] go is not installed — hcloud and crane need it
#   on run 1 AND run 2 of a `ci` install whose own lang-go module had just
#   succeeded. `~/.bashrc.d/10-path.sh` is what fixes the user's own shells; this
#   fixes the run that is happening now.
#
#   Prints nothing, mutates only this process's PATH, and is safe to call twice.
#   Returns 0 when `go` is callable afterwards, 1 when there is no Go anywhere.
go_ensure_path() {
  local root=${GOROOT_DIR:-/usr/local/go} gopath
  if [ -x "$root/bin/go" ]; then
    case ":$PATH:" in
      *":$root/bin:"*) ;;
      *)
        PATH="$root/bin:$PATH"
        export PATH
        ;;
    esac
  fi
  have go || return 1
  gopath=$(go env GOPATH 2>/dev/null) || gopath="$HOME/go"
  [ -n "$gopath" ] || return 0
  case ":$PATH:" in
    *":$gopath/bin:"*) ;;
    *)
      PATH="$gopath/bin:$PATH"
      export PATH
      ;;
  esac
  return 0
}

# go_install MODULE@VERSION [BIN]
#   Installs a Go tool with `go install`. BIN defaults to the last path element of
#   MODULE. Skips when $(go env GOPATH)/bin/BIN exists AND the version recorded in
#   $DEVENV_STATE/go-tools matches — `go version -m` is unreliable for tools built
#   from a pseudo-version, so the record is the source of truth.
#   NEVER runs `go clean -modcache` (deleting a multi-GB cache to install one tool).
#   GOFLAGS=-mod=mod, GOBIN deliberately unset so GOPATH/bin is used.
#   Honours --dry-run. Returns 0 when installed or skipped, 1 on a build failure.
go_install() {
  local spec=${1:?go_install: MODULE@VERSION required} bin=${2:-}
  have go || {
    log_skip "go is not installed — cannot install $spec"
    return 0
  }
  local module=${spec%@*} version=${spec##*@}
  [ -n "$bin" ] || bin=${module##*/}
  local gopath state line
  gopath=$(go env GOPATH 2>/dev/null) || gopath="$HOME/go"
  state="${DEVENV_STATE:?}/go-tools"
  if [ -x "$gopath/bin/$bin" ] && [ -f "$state" ]; then
    line=$(awk -F'\t' -v m="$module" '$1 == m {print $2; exit}' "$state") || line=''
    if [ "$line" = "$version" ]; then
      log_skip "$bin is already $version"
      return 0
    fi
  fi
  if is_dry_run; then
    log_dryrun "go install $spec"
    changed "$bin $version"
    return 0
  fi
  log_info "go install $spec"
  ensure_dir "$(dirname -- "$state")" || return 1
  run env GOFLAGS=-mod=mod GOBIN= go install "$spec" || {
    log_error "go install $spec failed"
    return 1
  }
  local tmp
  tmp=$(devenv_tmpfile) || return 1
  if [ -f "$state" ]; then awk -F'\t' -v m="$module" '$1 != m' "$state" >"$tmp"; fi
  printf '%s\t%s\n' "$module" "$version" >>"$tmp"
  run install -m 0644 -- "$tmp" "$state" || true
  changed "$bin $version"
  return 0
}

# ---------------------------------------------------------------------------
# Rust
# ---------------------------------------------------------------------------

# cargo_install CRATE [VERSION]
#   Installs a crate, skipping when `cargo install --list` already has it (at
#   VERSION, when one is given). Cargo is a LANGUAGE toolchain here, not a package
#   manager: eza and tealdeer were deliberately moved off it.
#   Honours --dry-run. Returns 0 when installed or skipped.
cargo_install() {
  local crate=${1:?cargo_install: CRATE required} version=${2:-}
  have cargo || {
    log_skip "cargo is not installed — cannot install $crate"
    return 0
  }
  local listed
  listed=$(cargo install --list 2>/dev/null | awk -v c="$crate" '$1 == c {print $2; exit}') || listed=''
  listed=${listed%:}
  listed=${listed#v}
  if [ -n "$listed" ]; then
    if [ -z "$version" ] || [ "$listed" = "${version#v}" ]; then
      log_skip "$crate is already installed ($listed)"
      return 0
    fi
  fi
  if [ -n "$version" ]; then
    run cargo install --locked "$crate" --version "${version#v}" || return 1
  else
    run cargo install --locked "$crate" || return 1
  fi
  changed "cargo $crate ${version:-latest}"
  return 0
}

# ---------------------------------------------------------------------------
# Python (uv only)
# ---------------------------------------------------------------------------

# uv_install
#   Installs uv into ~/.local/bin with the vendor installer, version-gated on
#   $UV_VERSION. uv is foundational: every Python CLI in this repo goes through it,
#   and it brings its own CPython so Debian 12's 3.11 stops mattering.
#   Honours --dry-run. Returns 0 when installed or already current.
uv_install() {
  local want=${UV_VERSION:-latest} cur
  if cur=$(bin_version uv --version); then
    if [ "$want" = latest ] || [ "${cur#v}" = "${want#v}" ]; then
      log_skip "uv is already ${cur}"
      return 0
    fi
  fi
  # The URL must carry the pinned version. https://astral.sh/uv/install.sh always
  # installs the LATEST uv, so with a pin of 0.12.12 and 0.12.13 upstream, the
  # short-circuit above could never match what the installer had just produced —
  # uv reinstalled itself on every run, forever, rewriting
  # ~/.config/uv/uv-receipt.json each time. astral publishes a per-version
  # installer at /uv/<version>/install.sh; use it whenever the pin is not `latest`.
  local url=https://astral.sh/uv/install.sh
  if [ "$want" != latest ]; then
    url="https://astral.sh/uv/${want#v}/install.sh"
  fi
  sh_installer_run "$url" \
    --reason "astral publishes the installer, not a stable per-release script digest; it verifies its own release artefacts" \
    --env "UV_INSTALL_DIR=$HOME/.local/bin" --env INSTALLER_NO_MODIFY_PATH=1 || return 1
  changed "uv $want"
  return 0
}

# uv_tool_install SPEC [--with PKG]…
#   Installs a Python CLI into its own venv. Idempotent via `uv tool list`.
#   K34, the single highest-risk detail of the Python migration: extra `--with`
#   packages must be named, because Ansible COLLECTIONS import them
#   (`kubernetes.core` needs `kubernetes`, `ansible.utils` needs `netaddr`).
#   `pip --user` satisfied that by accident, one shared prefix; per-tool venvs do not:
#       uv_tool_install ansible --with kubernetes --with netaddr --with jmespath
#   Honours --dry-run. Returns 0 when installed or already present.
uv_tool_install() {
  local spec=${1:?uv_tool_install: SPEC required}
  shift
  have uv || {
    log_skip "uv is not installed — cannot install $spec"
    return 0
  }
  local name=${spec%%[<>=@\[]*}
  name=${name##*/}
  if uv tool list 2>/dev/null | awk '{print $1}' | grep -qx -- "$name"; then
    log_skip "uv tool '$name' is already installed"
    return 0
  fi
  log_info "uv tool install $spec $*"
  run uv tool install "$spec" "$@" || {
    log_error "uv tool install $spec failed"
    return 1
  }
  changed "uv tool $name"
  return 0
}

# uv_tool_upgrade [NAME…]
#   Upgrades the named uv tools, or all of them when no name is given.
#   Opt-in path for MUST-FIX P5. Honours --dry-run. Always returns 0.
uv_tool_upgrade() {
  have uv || return 0
  if [ $# -eq 0 ]; then
    run uv tool upgrade --all || log_warn "uv tool upgrade --all reported an error"
  else
    local n
    for n in "$@"; do
      run uv tool upgrade "$n" || log_warn "uv tool upgrade $n failed"
    done
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Node
# ---------------------------------------------------------------------------

# npm_global_install SPEC
#   Installs a global npm package ONLY when npm exists and is nvm-owned (its path is
#   under $NVM_DIR). `sudo npm -g` is never run: it drops root-owned files into a
#   system prefix with no uninstall story.
#   Honours --dry-run. Always returns 0 — a missing npm is not a module failure.
npm_global_install() {
  local spec=${1:?npm_global_install: SPEC required} npmpath
  have npm || {
    log_skip "npm is not installed — skipping $spec"
    return 0
  }
  npmpath=$(command -v npm)
  case $npmpath in
    "${NVM_DIR:-$HOME/.config/nvm}"/*) ;;
    "$HOME"/*) ;;
    *)
      log_warn "npm at $npmpath is not user-owned — refusing to install $spec globally"
      log_warn "  (this repo never runs 'sudo npm -g'). Install it inside your project instead."
      return 0
      ;;
  esac
  local name=${spec%@*}
  if npm ls -g --depth=0 --parseable 2>/dev/null | grep -q "/${name##*/}\$"; then
    log_skip "npm package $name is already installed globally"
    return 0
  fi
  run npm install -g "$spec" || log_warn "npm install -g $spec failed"
  changed "npm -g $spec"
  return 0
}

# ---------------------------------------------------------------------------
# Helm plugins
# ---------------------------------------------------------------------------

# helm_plugin_ensure NAME URL [--version V]
#   Installs a helm plugin when it is not already registered.
#   The guard is the REGISTERED NAME — column 1 of `helm plugin list` — not the repo
#   name: `losisin/helm-values-schema-json` registers as `schema`, and
#   `aslafy-z/helm-git` registers as `helm-git`, not `git`. `helm plugin install`
#   exits non-zero when the plugin is already present (verified), so the guard is
#   what makes a second run succeed.
#   Honours --dry-run. Always returns 0 — one unavailable plugin must not fail 36.
helm_plugin_ensure() {
  local name=${1:?helm_plugin_ensure: NAME required} url=${2:?helm_plugin_ensure: URL required}
  shift 2
  local version=''
  while [ $# -gt 0 ]; do
    case $1 in
      --version)
        version=$2
        shift 2
        ;;
      *)
        log_error "helm_plugin_ensure: unknown option $1"
        return 0
        ;;
    esac
  done
  have helm || {
    log_skip "helm is not installed — skipping the '$name' plugin"
    return 0
  }
  if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$name"; then
    log_skip "helm plugin '$name' is already installed"
    return 0
  fi
  if [ -n "$version" ]; then
    run helm plugin install "$url" --version "$version" </dev/null \
      || log_warn "helm plugin install $url ($version) failed"
  else
    run helm plugin install "$url" </dev/null || log_warn "helm plugin install $url failed"
  fi
  changed "helm plugin $name"
  return 0
}

# helm_plugin_update [NAME…]
#   MUST-FIX P5: refreshes installed helm plugins (all of them when no name is given)
#   so a pinned plugin layer is not inert after the first install.
#   Honours --dry-run. Always returns 0.
helm_plugin_update() {
  have helm || return 0
  local n
  if [ $# -eq 0 ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      run helm plugin update "$n" || log_warn "helm plugin update $n failed"
    done < <(helm plugin list 2>/dev/null | awk 'NR>1 {print $1}')
    return 0
  fi
  for n in "$@"; do
    run helm plugin update "$n" || log_warn "helm plugin update $n failed"
  done
  return 0
}

# ---------------------------------------------------------------------------
# krew
# ---------------------------------------------------------------------------

# krew_root  — prints $KREW_ROOT or ~/.krew.
krew_root() { printf '%s\n' "${KREW_ROOT:-$HOME/.krew}"; }

# krew_bootstrap
#   Installs or updates krew itself, pinned to $KREW_VERSION.
#   Skips (log_skip + return 0, never a failure) when kubectl is absent.
#   Version-gated on `kubectl krew version`'s GitTag line. Uses the published
#   krew-linux_<arch>.tar.gz plus its .sha256 sidecar, unpacked in a temp dir, and
#   runs the installer with stdin closed.
#   Honours --dry-run. Returns 0 when installed or skipped, 1 on a hard failure.
krew_bootstrap() {
  have kubectl || {
    log_skip "kubectl is not installed — skipping krew"
    return 0
  }
  local want=${KREW_VERSION:-latest} tag cur root work asset url
  tag=$(gh_resolve_version kubernetes-sigs/krew "$want") || {
    log_warn "could not resolve a krew release — skipping krew"
    return 0
  }
  cur=$(kubectl krew version 2>/dev/null | awk '$1 == "GitTag" {print $2; exit}') || cur=''
  if [ -n "$cur" ] && [ "${cur#v}" = "$(tag_to_version "$tag")" ]; then
    log_skip "krew is already $cur"
    return 0
  fi
  asset="krew-linux_${OS_ARCH_GO:-amd64}.tar.gz"
  url="https://github.com/kubernetes-sigs/krew/releases/download/$tag/$asset"
  if is_dry_run; then
    log_dryrun "install krew $tag from $url"
    changed "krew $tag"
    return 0
  fi
  work=$(devenv_tmpdir) || return 1
  download "$url" "$work/$asset" || return 1
  if download "$url.sha256" "$work/$asset.sha256"; then
    verify_sha256 "$work/$asset" "$(awk '{print $1; exit}' "$work/$asset.sha256")" || return 1
  else
    log_warn "krew $tag publishes no .sha256 sidecar at $url.sha256 — installing unverified"
  fi
  run tar -xzf "$work/$asset" -C "$work" || return 1
  root=$(krew_root)
  export KREW_ROOT="$root"
  run "$work/krew-linux_${OS_ARCH_GO:-amd64}" install krew </dev/null || {
    log_error "krew self-install failed"
    return 1
  }
  log_success "installed krew $tag"
  changed "krew $tag"
  return 0
}

# krew_install_plugins PLUGIN…
#   K24: ONE `kubectl krew update`, then one `kubectl krew install --no-update-index
#   <plugin> </dev/null` per plugin, verified afterwards with `kubectl krew list`.
#   Failures are COLLECTED and warned about; the function still returns 0, because a
#   transient GitHub 5xx on one plugin must not abort a 18-plugin roster under `set -e`.
#   krew exits 0 for an already-installed plugin, so re-runs are free.
#   Honours --dry-run. Always returns 0.
krew_install_plugins() {
  [ $# -gt 0 ] || return 0
  have kubectl || {
    log_skip "kubectl is not installed — skipping krew plugins"
    return 0
  }
  local root
  root=$(krew_root)
  PATH="$root/bin:$PATH"
  export PATH KREW_ROOT="$root"
  kubectl krew version >/dev/null 2>&1 || {
    log_skip "krew is not installed — skipping krew plugins"
    return 0
  }
  if is_dry_run; then
    log_dryrun "kubectl krew update; install: $*"
    changed "krew plugins: $*"
    return 0
  fi
  run kubectl krew update </dev/null || log_warn "kubectl krew update failed — using the cached index"
  local installed p failed=()
  installed=$(kubectl krew list 2>/dev/null) || installed=''
  for p in "$@"; do
    [ -n "$p" ] || continue
    if printf '%s\n' "$installed" | grep -qx -- "$p"; then
      log_debug "krew plugin already installed: $p"
      continue
    fi
    log_info "kubectl krew install $p"
    if ! run kubectl krew install --no-update-index "$p" </dev/null; then
      failed+=("$p")
      continue
    fi
    changed "krew plugin $p"
  done
  installed=$(kubectl krew list 2>/dev/null) || installed=''
  local missing=()
  for p in "$@"; do
    [ -n "$p" ] || continue
    printf '%s\n' "$installed" | grep -qx -- "$p" || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_warn "these krew plugins are not installed: ${missing[*]}"
    log_warn "  retry with:  kubectl krew install ${missing[*]}"
  fi
  return 0
}

# krew_upgrade_all
#   MUST-FIX P5: `kubectl krew upgrade` for the whole installed set, so the plugin
#   layer can be refreshed without reinstalling anything.
#   Honours --dry-run. Always returns 0.
krew_upgrade_all() {
  have kubectl || return 0
  kubectl krew version >/dev/null 2>&1 || return 0
  run kubectl krew update </dev/null || log_warn "kubectl krew update failed"
  run kubectl krew upgrade </dev/null || log_warn "kubectl krew upgrade reported an error"
  changed "krew upgrade"
  return 0
}
