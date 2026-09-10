#!/usr/bin/env bash
# meta: name=lang-node
# meta: desc=node via nvm (lazy-loaded), or mise when asked for
# meta: profiles=devops,full
# meta: os=any
# meta: needs=
# meta: root=no
#
# K7/D8. nvm stays; the 0.20 s per interactive shell that motivated replacing it
# with mise is removed by LAZY LOADING in ~/.bashrc.d/20-lang.sh, not by adding a
# third version manager to the default path.
#
# Two bugs from the old scripts/nvm.sh are fixed here:
#   1. It installed nvm into the DEFAULT $HOME/.nvm while ~/.bashrc exported
#      NVM_DIR=$HOME/.config/nvm. The two never met, so every new shell had no
#      node at all until nvm was re-sourced by hand. One directory, named once,
#      in versions.env (NVM_DIR_DEFAULT) and in ~/.bashrc.d/20-lang.sh.
#   2. It gated on `command -v nvm`, which is a SHELL FUNCTION defined by
#      nvm.sh. In a non-interactive script it is never defined, so the guard was
#      always false and the installer ran on every single run. The gate here is
#      the file, plus a recorded version.
#
# The installer is run with PROFILE=/dev/null so it cannot append its three lines
# to ~/.bashrc — ~/.bashrc.d/20-lang.sh owns that, whole-file (D4).
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

NVM_DIR="${NVM_DIR:-${NVM_DIR_DEFAULT:-$HOME/.config/nvm}}"
export NVM_DIR
NVM_STATE="${DEVENV_STATE:?}/nvm-version"
LEGACY_NVM="$HOME/.nvm"

# ---------------------------------------------------------------------------
# nvm
# ---------------------------------------------------------------------------

nvm_installed_version() {
  local v=''
  [ -s "$NVM_DIR/nvm.sh" ] || return 1
  [ -f "$NVM_STATE" ] || return 1
  read -r v <"$NVM_STATE" || v=''
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

install_nvm() {
  local want=${NVM_VERSION:?} cur
  if cur=$(nvm_installed_version) && [ "$cur" = "$want" ]; then
    log_skip "nvm is already $cur in $NVM_DIR"
    return 0
  fi

  # The nvm installer `exit 1`s when NVM_DIR is set to a NON-default path that
  # does not exist yet. Creating it first is the whole fix.
  ensure_dir "$NVM_DIR" || return 1

  sh_installer_run "https://raw.githubusercontent.com/nvm-sh/nvm/${want}/install.sh" \
    --reason "the URL is pinned to nvm's ${want} git tag, so its content is immutable; nvm-sh publishes no per-release digest for it" \
    --env "NVM_DIR=$NVM_DIR" --env PROFILE=/dev/null --env METHOD=script \
    || {
      log_error "the nvm installer failed"
      return 1
    }

  if is_dry_run; then
    changed "nvm $want"
    return 0
  fi
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    log_error "nvm reported success but $NVM_DIR/nvm.sh does not exist"
    return 1
  fi
  ensure_dir "$(dirname -- "$NVM_STATE")" || return 1
  printf '%s\n' "$want" | write_if_changed "$NVM_STATE" 0644
  changed "nvm $want"
  return 0
}

# install_node
#   nvm is a shell function, so it can only be used from a shell that sourced
#   nvm.sh. The work is done by a throwaway script under $DEVENV_RUNDIR, which
#   `run` executes (and merely prints under --dry-run).
install_node() {
  local want=${NODE_VERSION:?} script
  [ -s "$NVM_DIR/nvm.sh" ] || {
    log_skip "nvm is not installed — no node"
    return 0
  }

  if ! is_dry_run && [ -x "$NVM_DIR/versions/node/v$want/bin/node" ]; then
    log_skip "node v$want is already installed"
    return 0
  fi
  # A major-only pin such as 24 resolves to the newest 24.x; ask nvm whether it
  # already has one rather than guessing the patch level.
  if ! is_dry_run && [ -d "$NVM_DIR/versions/node" ]; then
    local found
    found=$(find "$NVM_DIR/versions/node" -maxdepth 1 -name "v${want}.*" -print -quit 2>/dev/null) || found=''
    if [ -n "$found" ]; then
      log_skip "node ${found##*/} satisfies the $want pin"
      return 0
    fi
  fi

  script=$(devenv_tmpfile) || return 1
  cat >"$script" <<'NVMRUN'
set -eu
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install "$1"
nvm alias default "$1"
NVMRUN
  run env "NVM_DIR=$NVM_DIR" bash "$script" "$want" || {
    log_warn "nvm could not install node $want"
    return 0
  }
  changed "node $want"
  return 0
}

# report_legacy_nvm
#   MUST-FIX S9/S3: the stale ~/.nvm from the old script is REPORTED. Its
#   versions/ directory can hold gigabytes of toolchains the user still wants, so
#   the move is offered, never taken.
report_legacy_nvm() {
  [ -d "$LEGACY_NVM" ] || return 0
  [ "$LEGACY_NVM" = "$NVM_DIR" ] && return 0
  log_warn "a second nvm install exists at $LEGACY_NVM (the old scripts/nvm.sh default)"
  log_warn "  the one this repo and ~/.bashrc.d/20-lang.sh use is $NVM_DIR"
  if [ -d "$LEGACY_NVM/versions/node" ]; then
    local n
    n=$(find "$LEGACY_NVM/versions/node" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    log_warn "  it still holds $n node toolchain(s)."
    log_warn "  To keep them:  mv $LEGACY_NVM/versions/node/* $NVM_DIR/versions/node/"
  fi
  log_warn "  Nothing is moved or deleted for you."
  return 0
}

# ---------------------------------------------------------------------------
# mise — the opt-in alternative (K7). Never on the default path.
# ---------------------------------------------------------------------------

install_mise() {
  local a rc=0
  case ${OS_ARCH_DPKG:-} in
    amd64) a=x64 ;;
    arm64) a=arm64 ;;
    *)
      log_skip "mise publishes no build for ${OS_ARCH_DPKG:-this architecture}"
      return 0
      ;;
  esac
  gh_release_install jdx/mise "mise-{tag}-linux-${a}-musl" mise "${MISE_VERSION:-latest}" \
    --checksum-asset SHASUMS256.txt --dest "$HOME/.local/bin" || rc=$?
  [ "$rc" = 78 ] && log_skip "no mise release asset for linux-$a"
  [ "$rc" = 0 ] || return 0
  log_info "mise is installed. ~/.bashrc.d/20-lang.sh activates it when nvm is absent,"
  log_info "  or when DEVENV_NODE_MANAGER=mise is exported (see ~/.config/devops-env/shell.env)."
  run "$HOME/.local/bin/mise" use -g "node@${NODE_VERSION:?}" || log_warn "mise could not install node"
  return 0
}

module_main() {
  log_step "node"

  case "${NODE_MANAGER:-nvm}" in
    mise)
      log_info "NODE_MANAGER=mise — installing mise instead of nvm"
      install_mise
      ;;
    nvm)
      install_nvm || {
        log_step_end
        return 1
      }
      install_node
      report_legacy_nvm
      ;;
    none)
      log_skip "NODE_MANAGER=none — no node version manager installed"
      ;;
    *)
      log_warn "unknown NODE_MANAGER='${NODE_MANAGER:-}' (use nvm|mise|none) — doing nothing"
      ;;
  esac

  # Reported, never removed. A distro nodejs on PATH shadows nvm's, and then
  # `npm -g` writes into /usr/lib/node_modules, which needs root and has no
  # uninstall story. lib/lang.sh refuses to install globals into such a prefix.
  pkg_conflicts_report \
    "a distro node is installed as well; ~/.bashrc.d/20-lang.sh only shims node/npm/npx when they are NOT already on PATH, so the distro one keeps winning" \
    nodejs npm || true

  log_step_end
  return 0
}

module_main "$@"
