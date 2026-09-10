# shellcheck shell=bash
# lib/pkg.sh — the ONE apt policy.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# Rules that hold everywhere:
#   * `apt-get` only. `apt` is explicitly not a stable scripting interface, and
#     `nala` is a FRONT-END, used only when it already exists and only for
#     `pkg_upgrade` (K20). The old repo's usenala.sh redefined the `sudo` and `apt`
#     SHELL FUNCTIONS; that is gone and must never come back (SPEC 8).
#   * Never add a repository, backport or suite to obtain nala.
#   * MUST-FIX S9 / idempotency F17: this library NEVER removes a package the user
#     installed. `pkg_remove`/`pkg_purge` REPORT by default and act only behind an
#     explicit opt-in. Conflicts are detected and reported; the user decides.
#   * Every apt invocation goes through run_sudo, so --dry-run mutates nothing.

[ -n "${_DEVENV_PKG:-}" ] && return 0
_DEVENV_PKG=1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Keep the admin's conffiles. --force-confdef+--force-confold is the only safe
# unattended combination: it never asks and never overwrites a modified conffile.
_APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

# _apt_get ARG…   (private)
#   apt-get as root, with the non-interactive environment ATTACHED TO THE COMMAND
#   rather than merely exported into this shell.
#
#   THE EXPORTS ABOVE DO NOT SURVIVE sudo. `env_reset` is the default sudoers
#   policy on Debian and Ubuntu, and it drops every variable that is not in
#   `env_keep` — DEBIAN_FRONTEND and NEEDRESTART_MODE are not. So `run_sudo
#   apt-get install …` reaches root with an *interactive* debconf frontend, and on
#   Ubuntu 22.04 the first package that pulls tzdata stops dead on
#
#       1. Africa   2. America   …
#       Geographic area:
#
#   waiting for input that an unattended `--yes` install will never provide. That
#   is not theoretical: it hung the container matrix on ubuntu:22.04 until the run
#   was killed. Every apt-get in this file goes through here.
#
#   The exports are still needed for the unprivileged half of the library
#   (apt-cache, dpkg-query) and for a run that is already root.
#   Honours --dry-run through run_sudo. Returns apt-get's status.
_apt_get() {
  run_sudo env \
    DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    NEEDRESTART_MODE=a \
    apt-get "$@"
}

# pkg_update [--force]
#   Refreshes the apt index at most ONCE per run (state in $DEVENV_RUNDIR), unless
#   --force is given or a repo helper set NEED_APT_UPDATE=1.
#   Honours --dry-run. Returns apt-get's status; a failure is the caller's problem.
pkg_update() {
  local force=0
  [ "${1:-}" = --force ] && force=1
  if [ "${NEED_APT_UPDATE:-0}" = 1 ]; then force=1; fi
  local stamp="${DEVENV_RUNDIR:-/nonexistent}/apt-updated"
  if [ "$force" = 0 ] && [ -f "$stamp" ]; then
    log_debug "apt index already refreshed this run"
    return 0
  fi
  log_info "refreshing the apt package index"
  _apt_get update -qq || {
    log_warn "apt-get update reported an error — continuing with the cached index"
    return 0
  }
  [ -d "${DEVENV_RUNDIR:-}" ] && : >"$stamp"
  NEED_APT_UPDATE=0
  export NEED_APT_UPDATE
  return 0
}

# pkg_installed PKG
#   Returns 0 when PKG is installed (dpkg status "installed"). Read-only predicate.
pkg_installed() {
  local st
  st=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) || return 1
  [ "$st" = installed ]
}

# pkg_candidate_version PKG
#   Prints apt's candidate version for PKG, or nothing when there is none.
#   Returns 1 when there is no candidate. Read-only.
pkg_candidate_version() {
  local v
  have apt-cache || return 1
  # NO `exit` IN THE awk PROGRAM. `awk '/Candidate:/ {print $2; exit}'` closes the
  # pipe while apt-cache is still writing, apt-cache dies of SIGPIPE, and under
  # `set -o pipefail` — which EVERY module and bin/devenv set — the command
  # substitution's status is 141. This function then returned 1, `pkg_available`
  # answered "no candidate", and `pkg_install` SILENTLY DROPPED a package that is
  # perfectly installable. Reproduced on ubuntu 24.04, where mtr-tiny, traceroute,
  # tcpdump and sshpass were each dropped with "no installation candidate" while
  # `apt-cache policy` listed a candidate for all four.
  # Reading the whole stream and printing in END costs nothing and cannot SIGPIPE.
  v=$(apt-cache policy -- "$1" 2>/dev/null | awk '/Candidate:/ {v = $2} END {print v}') || return 1
  case ${v:-} in '' | '(none)') return 1 ;; esac
  printf '%s\n' "$v"
}

# pkg_available PKG
#   Returns 0 when PKG has an installation candidate in the configured archives.
pkg_available() { pkg_candidate_version "$1" >/dev/null 2>&1; }

# pkg_install PKG…
#   Installs the packages that are not installed yet and that HAVE a candidate.
#   Names with no candidate are dropped with one warning each (a Debian box must not
#   die because an Ubuntu-only package is in the list).
#   Returns 0 immediately when nothing is left to do — that is the idempotency
#   short-circuit that makes a second run silent.
#   Honours --dry-run. Returns apt-get's status on a real failure.
pkg_install() {
  local want=() p
  for p in "$@"; do
    [ -n "$p" ] || continue
    if pkg_installed "$p"; then
      log_debug "already installed: $p"
      continue
    fi
    if ! pkg_available "$p"; then
      log_warn "no installation candidate for '$p' on ${OS_ID:-this system} ${OS_CODENAME:-} — skipping it"
      continue
    fi
    want+=("$p")
  done
  [ ${#want[@]} -gt 0 ] || return 0
  pkg_update
  log_info "installing: ${want[*]}"
  _apt_get install "${_APT_OPTS[@]}" --no-install-recommends -- "${want[@]}" || return 1
  changed "apt install ${want[*]}"
  return 0
}

# pkg_install_optional PKG…
#   As pkg_install, but a failure is logged and swallowed: the module continues.
#   Always returns 0.
pkg_install_optional() {
  pkg_install "$@" || log_warn "optional packages failed to install: $*"
  return 0
}

# pkg_install_first PKG…
#   Installs the FIRST name that has a candidate and stops. This is how one call
#   covers `tealdeer` on trixie/noble and `tldr` on bookworm/jammy, or `7zip` and
#   `p7zip-full`. Returns 0 when one was installed or one is already present;
#   returns 1 when none of the names exists anywhere (the caller then falls back to
#   a release binary).
pkg_install_first() {
  local p
  for p in "$@"; do
    if pkg_installed "$p"; then
      log_debug "already installed: $p"
      return 0
    fi
  done
  for p in "$@"; do
    if pkg_available "$p"; then
      pkg_install "$p"
      return
    fi
  done
  log_debug "none of these packages has a candidate: $*"
  return 1
}

# pkg_install_local DEBFILE
#   Installs a local .deb.
#   idempotency F16: uses `apt-get install ./file.deb`, which resolves dependencies
#   UP FRONT and fails cleanly. `dpkg -i` followed by `apt-get -f install -y` is
#   forbidden here: it is allowed to REMOVE packages to repair the broken state it
#   created, unattended, after a third-party .deb.
#   Honours --dry-run. Returns non-zero when the install fails.
pkg_install_local() {
  local deb=${1:?pkg_install_local: DEBFILE required} abs
  [ -r "$deb" ] || {
    log_error "no such .deb: $deb"
    return 1
  }
  abs=$(readlink -f -- "$deb")
  pkg_update
  _apt_get install "${_APT_OPTS[@]}" -- "$abs" || {
    log_error "apt-get refused to install $abs (unsatisfiable dependencies)"
    return 1
  }
  changed "dpkg install $(basename -- "$abs")"
  return 0
}

# pkg_remove PKG…
#   MUST-FIX S9 / idempotency F17: REPORT-ONLY BY DEFAULT.
#   Prints which of PKG… are installed and the exact command to remove them, then
#   returns 0 WITHOUT removing anything. A bootstrapper must not delete packages the
#   user installed deliberately (neovim, yq, containerd, podman-docker were all on
#   the live box and all in the old scripts' purge lists).
#   Removal happens only when DEVENV_ALLOW_PKG_REMOVE=1 and confirm_dangerous agrees.
#   Always returns 0 so a module never fails over a conflict it only needed to report.
pkg_remove() { _pkg_remove_impl remove "$@"; }

# pkg_purge PKG…   — as pkg_remove, with --purge. Same report-only default.
pkg_purge() { _pkg_remove_impl purge "$@"; }

_pkg_remove_impl() {
  local mode=$1
  shift
  local present=() p
  for p in "$@"; do
    [ -n "$p" ] || continue
    if pkg_installed "$p"; then present+=("$p"); fi
  done
  [ ${#present[@]} -gt 0 ] || return 0
  log_warn "these packages conflict with what this module installs: ${present[*]}"
  log_warn "  linux-devops-tools does not remove packages you installed."
  log_warn "  To remove them yourself:  sudo apt-get $mode ${present[*]}"
  if ! confirm_dangerous "remove ${present[*]} now?" DEVENV_ALLOW_PKG_REMOVE; then
    return 0
  fi
  local verb=remove
  [ "$mode" = purge ] && verb=purge
  _apt_get "$verb" "${_APT_OPTS[@]}" -- "${present[@]}" || {
    log_error "apt-get $verb failed"
    return 0
  }
  changed "apt $verb ${present[*]}"
  return 0
}

# pkg_conflicts_report LABEL PKG…
#   Pure reporting: names the conflicting packages under LABEL and returns 0 when
#   there are none, 1 when there is at least one. Removes nothing, ever.
#   Use it in `90-doctor.sh` and wherever a module only needs to warn.
pkg_conflicts_report() {
  local label=${1:?pkg_conflicts_report: LABEL required}
  shift
  local present=() p
  for p in "$@"; do
    if pkg_installed "$p"; then present+=("$p"); fi
  done
  [ ${#present[@]} -gt 0 ] || return 0
  log_warn "$label: ${present[*]}"
  return 1
}

# pkg_upgrade
#   A full upgrade, and the ONE place `nala` may be used as a front-end.
#   Opt-in only: it no-ops unless DEVENV_UPGRADE=1 (`--upgrade`). "Install my tools"
#   must never pull a new kernel on someone's VM.
#   Honours --dry-run. Always returns 0.
pkg_upgrade() {
  if [ "${DEVENV_UPGRADE:-0}" != 1 ]; then
    log_debug "pkg_upgrade: not requested (--upgrade / DEVENV_UPGRADE=1)"
    return 0
  fi
  pkg_update --force
  if [ "${PKG_FRONTEND:-apt}" = nala ] && have nala; then
    run_sudo nala upgrade -y || log_warn "nala upgrade failed"
  else
    _apt_get upgrade "${_APT_OPTS[@]}" || log_warn "apt-get upgrade failed"
  fi
  changed "system upgrade"
  return 0
}

# pkg_ensure_universe
#   Ubuntu only: makes sure the `universe` component is enabled, because half the
#   catalog (wslu, tealdeer, resvg, …) lives there. deb822-aware: it edits nothing
#   when universe is already configured, and it installs
#   software-properties-common ONLY when `add-apt-repository` is genuinely needed.
#   idempotency F24e: the distro's own ubuntu.sources is backed up before any edit.
#   No-op on Debian. Honours --dry-run. Always returns 0.
pkg_ensure_universe() {
  os_is_ubuntu || return 0
  if apt-cache policy 2>/dev/null | grep -q '/universe'; then
    log_debug "universe is already enabled"
    return 0
  fi
  local src=/etc/apt/sources.list.d/ubuntu.sources
  if [ -f "$src" ] && grep -q '^Components:' "$src"; then
    local tmp
    tmp=$(devenv_tmpfile) || return 0
    awk '/^Components:/ && $0 !~ /universe/ { print $0 " universe"; next } { print }' "$src" >"$tmp"
    if ! cmp -s -- "$tmp" "$src"; then
      backup_file "$src" >/dev/null
      write_if_changed "$src" 0644 <"$tmp"
      NEED_APT_UPDATE=1
      export NEED_APT_UPDATE
      pkg_update --force
    fi
    return 0
  fi
  if ! have add-apt-repository; then
    pkg_install software-properties-common || return 0
  fi
  run_sudo add-apt-repository -y universe || log_warn "could not enable the universe component"
  NEED_APT_UPDATE=1
  export NEED_APT_UPDATE
  pkg_update --force
  return 0
}

# apt_or_release PKG BIN MIN_VERSION REPO ASSET_PATTERN [OPTS…]
#   K19, one runtime probe instead of a distro version matrix: install PKG from apt
#   when its CANDIDATE is >= MIN_VERSION, otherwise install the pinned GitHub release
#   binary. OPTS are passed to gh_release_install unchanged (checksum options
#   included) — so pass the release VERSION as --release-version, e.g.
#       apt_or_release fzf fzf 0.48.0 junegunn/fzf 'fzf-{version}-linux_{arch_go}.tar.gz' \
#           --release-version "$FZF_VERSION" --checksum-asset fzf_{version}_checksums.txt
#   Used for zoxide (min 0.9.0), fzf (0.48.0, the `fzf --bash` cutover) and
#   git-delta (0.16.0). eza is always the release tarball — it is absent from
#   bookworm and jammy entirely, so branching would buy nothing.
#   Returns 0, or gh_release_install's status (78 = no asset for this arch).
apt_or_release() {
  local pkg=${1:?apt_or_release: PKG required} bin=${2:?apt_or_release: BIN required}
  local minv=${3:?apt_or_release: MIN_VERSION required} repo=${4:?apt_or_release: REPO required}
  local pattern=${5:?apt_or_release: ASSET_PATTERN required}
  shift 5
  local relver=latest opts=()
  while [ $# -gt 0 ]; do
    case $1 in
      --release-version)
        relver=$2
        shift 2
        ;;
      *)
        opts+=("$1")
        shift
        ;;
    esac
  done
  local cand
  if cand=$(pkg_candidate_version "$pkg"); then
    if version_ge "$cand" "$minv"; then
      log_debug "$pkg: apt candidate $cand >= $minv"
      pkg_install "$pkg"
      return
    fi
    log_info "$pkg: apt has only $cand (< $minv) — using the pinned release binary"
  else
    log_info "$pkg: not in the archive — using the pinned release binary"
  fi
  gh_release_install "$repo" "$pattern" "$bin" "$relver" "${opts[@]}"
}
